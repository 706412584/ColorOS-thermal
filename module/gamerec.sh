#!/system/bin/sh
# oplus-cloud-block - 游戏记录
#
# 用法：
#   gamerec.sh start | stop | ensure     守护管理（stop 会先把当前这局写入记录）
#   gamerec.sh status                    KEY=VALUE 状态（供 WebUI）
#   gamerec.sh list                      输出全部记录（每行一局）
#   gamerec.sh clear | undo              清空（先另存，可恢复）/ 恢复上次清空
#   gamerec.sh on | off                  开关（持久保存在数据目录，模块更新不丢）
#
# 一局 = 游戏处于前台的时间。切到后台超过 GRACE 秒或进程退出就结束；
# 后台的时间不采样、不计入。前台累计不足 MIN_DUR 秒的不记录（误点打开）。
#
# 采样（每秒一次，只在游戏前台时）：
#   帧率   优先 SurfaceFlinger 合成帧计数（service call SurfaceFlinger 1013）的差值 / 时间差；
#          该接口不可用（ColorOS 16）时读高通显示驱动的 sde-crtc measured_fps；
#          两个都没有（部分天玑）时记录帧率为空，其余项照常
#   CPU    最后一个 cpufreq policy（超大核）与倒数第二个（中核）的 scaling_cur_freq
#   GPU    高通 /sys/class/kgsl/kgsl-3d0/gpuclk；
#          天玑 /sys/kernel/ged/hal/current_freqency（"loading kHz" 取第二列）
#          或 /proc/gpufreq/gpufreq_opp_freq。开局探测一次，选第一个读到值的。
#   温度   与 cpulimit.sh 同一套温区选择逻辑（skin-msm-therm → CPU 结温 → 外壳），
#          记录最高值
#   满频   msm_performance 上限节点处于解锁值（9999999）的时间占比
#   电量   开局与结束的 capacity
#
# 注意：mksh 算术是 32 位。频率按 MHz 累加，避免长局溢出。

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

MODDIR=${0%/*}
DATA=/data/adb/oplus-cloud-block-data
REC=$DATA/gamerec.log
REC_BAK=$DATA/gamerec.log.cleared
CUR=$DATA/gamerec.cur
OFF=$DATA/gamerec.off
PIDFILE=/data/adb/oplus-gamerec.pid
LOG=/data/adb/oplus-cloud-block.log
GAME_LIST_CACHE=/data/adb/oplus-cpulimit.games
GAMEPID=/proc/game_opt/game_pid
FREQ=/sys/kernel/msm_performance/parameters/cpu_max_freq
# 老内核（如 4.14）上同一个节点在 /sys/module 下
[ -e "$FREQ" ] || FREQ=/sys/module/msm_performance/parameters/cpu_max_freq
BATCAP=/sys/class/power_supply/battery/capacity
BATST=/sys/class/power_supply/battery/status
TOP_PROCS=/dev/cpuset/top-app/cgroup.procs

KEEP=50        # 保留最近 50 局
GRACE=30       # 切后台超过 30s 算结束
MIN_DUR=30     # 前台不足 30s 不记录
IDLE_SLEEP=2   # 没在玩时的检测间隔（秒）
NL='
'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [游戏记录] $*" >>"$LOG"; }

# ---------- 读取（全部用内建 read，不 fork） ----------
rd() { # $1 = 文件，结果放 RV
  RV=""; read -r RV 2>/dev/null <"$1"
}

# 进程 pid -> 包名（去掉 :子进程）
pid_pkg() {
  PK=""; IFS= read -r -d '' PK 2>/dev/null <"/proc/$1/cmdline"
  PK=${PK%%:*}
}

GAMES=""
load_games() {
  [ -f "$GAME_LIST_CACHE" ] || sh "$MODDIR/cpulimit.sh" buildgames >/dev/null 2>&1
  GAMES=$(cat "$GAME_LIST_CACHE" 2>/dev/null)
}

# 当前前台游戏的包名放进 FG（不是游戏则为空）
fg_game() {
  FG=""
  # ① 系统游戏检测：game_pid 只在游戏独占前台时置位
  rd "$GAMEPID"
  case "$RV" in
    *game_pid=*)
      local g=${RV#*game_pid=}; g=${g%%[!0-9]*}
      if [ -n "$g" ] && [ "$g" != "0" ]; then
        pid_pkg "$g"; [ -n "$PK" ] && { FG=$PK; return; }
      fi ;;
  esac
  # ② top-app cpuset 里有名单内的游戏
  [ -n "$GAMES" ] && [ -r "$TOP_PROCS" ] || return
  local pid
  while read -r pid; do
    pid_pkg "$pid"
    case "$PK" in *.*) ;; *) continue ;; esac
    case "$NL$GAMES$NL" in *"$NL$PK$NL"*) FG=$PK; return ;; esac
  done <"$TOP_PROCS"
}

# SurfaceFlinger 合成帧计数（十进制，32 位回绕由差值自然处理）。失败为空。
# 输出形如：Result: Parcel(0070d3b5    '..p.')  —— 模式里用 ? 代替括号（mksh 对 ( 敏感）
sf_frames() {
  SF=""
  local o; o=$(service call SurfaceFlinger 1013 2>/dev/null)
  o=${o#*Parcel?}; o=${o%% *}
  case "$o" in ''|*[!0-9a-fA-F]*) return ;; esac
  SF=$((16#$o))
}

# 帧率来源（开局选一次）：
#   sf  = SurfaceFlinger 1013 计数器（黑鲨等可用；ColorOS 16 / Android 16 上已移除，返回 Error）
#   drm = /sys/class/drm/sde-crtc-*/measured_fps（高通显示驱动，内容形如
#         "fps: 90.4 duration:500000 frame_count:46"，是最近一个统计窗口的屏幕刷新帧率）
#   none = 都没有，只记 CPU/GPU/温度
pick_fps_src() {
  sf_frames
  if [ -n "$SF" ]; then FPS_SRC=sf; return; fi
  DRM_FILES=""
  local f
  for f in /sys/class/drm/sde-crtc-*/measured_fps; do [ -r "$f" ] && DRM_FILES="$DRM_FILES $f"; done
  [ -n "$DRM_FILES" ] && FPS_SRC=drm || FPS_SRC=none
}

# 本拍帧率 ×10 放进 F10（取不到为空）。$1 = 距上一拍的厘秒数
fps_tick() {
  F10=""
  case "$FPS_SRC" in
    sf)
      sf_frames
      if [ -n "$SF" ] && [ -n "$PREV_SF" ]; then
        local df=$(( SF - PREV_SF ))
        [ "$df" -ge 0 ] && F10=$(( df * 1000 / $1 ))
      fi
      PREV_SF=$SF ;;
    drm)
      # 行形如 "fps: 88.7 duration:500000 frame_count:45"（duration 单位 μs）。
      # 多个 CRTC 取最大（游戏时只有主屏在刷新，其余为 0）。
      # 刷新率切换的瞬间 fps 字段会失真（实测 "fps: 52.1 … frame_count:46"，按计数应为 92）：
      # fps 字段与 frame_count 换算值相差超过 10% 时视为过渡噪点，丢弃该 CRTC 的读数。
      local f v dd cc best=-1 i d cf tol diff
      for f in $DRM_FILES; do
        v=""; dd=""; cc=""; read -r _ v dd cc 2>/dev/null <"$f"
        case "$v" in ''|*[!0-9.]*) continue ;; esac
        i=${v%%.*}; d=0; case "$v" in *.*) d=${v#*.}; d=${d%"${d#?}"} ;; esac
        v=$(( ${i:-0} * 10 + ${d:-0} ))
        dd=${dd#duration:}; cc=${cc#frame_count:}
        case "$dd$cc" in *[!0-9]*|'') ;; *)
          if [ "$dd" -gt 0 ] && [ "$cc" -gt 0 ]; then
            cf=$(( cc * 10000000 / dd ))           # 按计数换算的 fps×10
            diff=$(( v - cf )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            tol=$(( cf / 10 )); [ "$tol" -lt 30 ] && tol=30
            [ "$diff" -gt "$tol" ] && { F_NOISE=$(( F_NOISE + 1 )); continue; }
            # 两者一致时用计数换算值：fps 字段稳态时系统性偏低约 1.5%
            # （实测 "fps: 88.7 … frame_count:45" = 0.5s 内 45 帧 = 90fps，与游戏内显示的 89~90 吻合）
            v=$cf
          fi ;;
        esac
        [ "$v" -gt "$best" ] && best=$v
      done
      [ "$best" -ge 0 ] && F10=$best ;;
  esac
}

# 低于该值（×10）视为画面静止（加载/结算/暂停时屏幕不出新帧），不计入帧率统计
IDLE_F10=50

# /proc/uptime 转厘秒
uptime_cs() {
  rd /proc/uptime
  local s=${RV%% *}
  local i=${s%.*} f=${s#*.}
  f=${f}00; f=${f%"${f#??}"}
  UT=$(( i * 100 + 10#$f ))
}

# 温区号（只在开局查一次）
find_zone() {
  local z zt
  for z in /sys/class/thermal/thermal_zone*; do
    zt=""; read -r zt 2>/dev/null <"$z/type"
    [ "$zt" = "$1" ] && { echo "$z/temp"; return; }
  done
}

# CPU 结温温区判定（与 cpulimit.sh 同一套规则，必须保持一致，否则两边读数对不上）
# ★ 排除 trip 点：cpu-hw-trip-0 = 95000 是门限值不是温度。
is_cpu_zone() {
  case "$1" in
    *trip*) return 1 ;;
    cpu-*|cpullc-*|cpu_big*|cpu_little*|cpuss*|soc_max|soc_top|mtktscpu|mtkts_cpu) return 0 ;;
  esac
  return 1
}
is_skin_zone() {
  case "$1" in
    skin-msm-therm|skin_ntc|shell_*|board_temp|ap_ntc) return 0 ;;
  esac
  return 1
}

# 保护温区（开局查一次）。三级：skin-msm-therm > CPU 结温家族 > 外壳家族。
# 与 cpulimit.sh 同序，这样"游戏记录里的最高温"和"触发收回的温度"是同一个温区。
pick_zone() {
  TZ_PATH=$(find_zone skin-msm-therm)
  [ -n "$TZ_PATH" ] && return
  local z zt
  for z in /sys/class/thermal/thermal_zone*; do
    zt=""; read -r zt 2>/dev/null <"$z/type"
    is_cpu_zone "$zt" && { TZ_PATH=$z/temp; return; }
  done
  for z in /sys/class/thermal/thermal_zone*; do
    zt=""; read -r zt 2>/dev/null <"$z/type"
    is_skin_zone "$zt" && { TZ_PATH=$z/temp; return; }
  done
}

# GPU 频率节点（开局探测一次，选第一个读得到非空值的）。
#   高通 kgsl   ：直接是 Hz（如 160000000）
#   天玑 ged    ："loading kHz"（如 "39 219000"）→ 取第二列，本身就是 kHz
#   天玑 gpufreq ：/proc/gpufreq/gpufreq_opp_freq 常是 kHz（如 800000）
# 记进 GPU_SRC（kgsl / ged / gpufreq / none），采样时据此换算成 MHz。
pick_gpu() {
  local v
  GPU_SRC=none; GPU_PATH=""
  for v in /sys/class/kgsl/kgsl-3d0/gpuclk; do
    rd "$v"; [ -n "$RV" ] && { GPU_SRC=kgsl; GPU_PATH=$v; return; }
  done
  for v in /sys/kernel/ged/hal/current_freqency; do
    rd "$v"; case "$RV" in *' '*) GPU_SRC=ged; GPU_PATH=$v; return ;; esac
  done
  for v in /proc/gpufreq/gpufreq_opp_freq /proc/gpufreq/gpufreq_cur_freq; do
    rd "$v"; [ -n "$RV" ] && { GPU_SRC=gpufreq; GPU_PATH=$v; return; }
  done
}

# 读一拍的 GPU 频率，MHz 放进 RV（取不到给空）。$1 = 输出变量名。
# 用 eval 回填是因为 mksh 没有引用传参；调用点只有下面一处，可控。
gpu_read() {
  local out=$1; eval "$out=''"
  [ "$GPU_SRC" = none ] && return
  rd "$GPU_PATH"
  local v=$RV
  case "$GPU_SRC" in
    kgsl)     case "$v" in ''|*[!0-9]*) return ;; esac; eval "$out=\$(( v / 1000000 ))" ;;
    ged)      case "$v" in *' '*) v=${v##* } ;; esac
              case "$v" in ''|*[!0-9]*) return ;; esac; eval "$out=\$(( v / 1000 ))" ;;
    gpufreq)  case "$v" in ''|*[!0-9]*) return ;; esac
              # 值可能是 Hz(>1e8) 也可能是 kHz；按量级判断
              if [ "$v" -gt 100000000 ]; then eval "$out=\$(( v / 1000000 ))"
              else eval "$out=\$(( v / 1000 ))"; fi ;;
  esac
}

# 超大核 / 中核 policy 路径（开局查一次）
find_policies() {
  P_BIG=""; P_MID=""
  local p
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    P_MID=$P_BIG; P_BIG=$p
  done
}

# ---------- 一局的累计量 ----------
reset_session() {
  S_PKG=$1
  S_START=$(date +%s)
  S_DUR=0; S_N=0; S_FSUM=0; S_FMIN=""; S_FMAX=0
  S_BSUM=0; S_BMAX=0; S_MSUM=0; S_GSUM=0; S_GMAX=0; S_GN=0
  S_TMAX=""; S_UNL=0; S_CHG=0
  rd "$BATCAP"; S_BAT0=$RV
  rd "$BATST"; [ "$RV" = "Charging" ] && S_CHG=1
  # 帧率直方图（按整数 fps），用于 1% Low
  local k; for k in $S_HKEYS; do unset "H_$k"; done
  S_HKEYS=""
  TZ_PATH=""; pick_zone
  find_policies
  pick_gpu
  pick_fps_src
  PREV_SF=""; PREV_UT=""; S_FN=0; S_IDLE=0; F_NOISE=0
  S_HZ=0; HZ_NOW=""; HZ_CAND=""; hi_reset; curve_reset
  echo "$S_PKG|$S_START" >"$CUR" 2>/dev/null
  log "开始记录：$S_PKG（帧率来源 $FPS_SRC，GPU 来源 $GPU_SRC，温区 ${TZ_PATH:-无}）"
}

# ---------- 刷新率档位 ----------
# 游戏大厅常跑 60Hz、对局才切到 90/120Hz。只按整局平均会把大厅算进去，
# 和游戏内帧率显示对不上。所以另外统计「最高刷新率档位」那段时间（= 对局）的帧率，
# 该段内的掉帧照样计入，不会美化。
# 当前刷新率来自 dumpsys display（约 50ms），每 5 拍读一次。
hi_reset() {
  local k; for k in $S_GKEYS; do unset "G_$k"; done
  S_GKEYS=""; S_HN=0; S_HSUM=0; S_HMIN=""; S_HMAX=0; S_HDUR=0
  S_JANK=0; S_JRUN=0; S_JMAX=0
}

# ---------- 曲线 ----------
# 每 CURVE_STEP 拍汇总成一个点：平均帧率×10,最低帧率,机身温度(0.1°C),大核MHz。
# 一局 25 分钟约 150 个点、3KB；只保留最近 KEEP 局的曲线文件。
CURVE_DIR=$DATA/curve
CURVE_STEP=10
CURVE_TMP=$DATA/gamerec.curve.tmp
curve_reset() { C_N=0; C_FN=0; C_FSUM=0; C_FMIN=""; C_T=""; C_B=0; : >"$CURVE_TMP" 2>/dev/null; }
# 在 sample 里每拍调用：$1 = 本拍帧率×10（静止/取不到为空）$2 = 温度 mC $3 = 大核 MHz
curve_add() {
  C_N=$(( C_N + 1 ))
  if [ -n "$1" ]; then
    C_FN=$(( C_FN + 1 )); C_FSUM=$(( C_FSUM + $1 ))
    [ -z "$C_FMIN" ] || [ "$1" -lt "$C_FMIN" ] && C_FMIN=$1
  fi
  [ -n "$2" ] && { [ -z "$C_T" ] || [ "$2" -gt "$C_T" ]; } && C_T=$2
  [ "$3" -gt "$C_B" ] && C_B=$3
  [ "$C_N" -ge "$CURVE_STEP" ] || return
  local fa="" fm="" t=""
  [ "$C_FN" -gt 0 ] && { fa=$(( C_FSUM / C_FN )); fm=$(( C_FMIN / 10 )); }
  [ -n "$C_T" ] && t=$(( C_T / 100 ))
  echo "$fa,$fm,$t,$C_B" >>"$CURVE_TMP"
  C_N=0; C_FN=0; C_FSUM=0; C_FMIN=""; C_T=""; C_B=0
}
curve_save() { # $1 = 开局时间戳
  [ -s "$CURVE_TMP" ] || return
  mkdir -p "$CURVE_DIR" 2>/dev/null
  mv -f "$CURVE_TMP" "$CURVE_DIR/$1.csv"
  # 只留最近 KEEP 局（文件名是时间戳，按名字排序 = 按时间）
  local n; n=$(ls -1 "$CURVE_DIR" 2>/dev/null | grep -c '\.csv$')
  [ "$n" -gt "$KEEP" ] && ls -1 "$CURVE_DIR" | grep '\.csv$' | sort | head -n $(( n - KEEP )) \
    | while read -r f; do rm -f "$CURVE_DIR/$f"; done
}
hz_poll() {
  local r; r=$(dumpsys display 2>/dev/null | grep -m1 -o 'renderFrameRate [0-9]*')
  r=${r##* }
  case "$r" in ''|*[!0-9]*) HZ_NOW=""; return ;; esac
  HZ_NOW=$r
  if [ "$r" -gt "$S_HZ" ]; then
    # 升档需连续两次读到才采纳，防止切换瞬间的毛刺把已有的对局数据清掉
    if [ "$S_HZ" -eq 0 ] || [ "$r" = "$HZ_CAND" ]; then
      S_HZ=$r; HZ_CAND=""; hi_reset
    else
      HZ_CAND=$r
    fi
  else
    HZ_CAND=""
  fi
}

# 每拍：时长/CPU/GPU/温度/满频按 S_N 计；帧率单独按 S_FN 计（取不到帧率的拍不影响其他项）
sample() {
  uptime_cs
  if [ -z "$PREV_UT" ]; then
    PREV_UT=$UT; [ "$FPS_SRC" = sf ] && sf_frames && PREV_SF=$SF
    return
  fi
  local dt=$(( UT - PREV_UT ))
  PREV_UT=$UT
  # 时间差异常（休眠/卡住）时丢弃这一拍，并重取帧计数基线
  if [ "$dt" -lt 50 ] || [ "$dt" -gt 300 ]; then
    [ "$FPS_SRC" = sf ] && sf_frames && PREV_SF=$SF
    return
  fi
  S_N=$(( S_N + 1 )); S_DUR=$(( S_DUR + dt ))
  [ $(( S_N % 5 )) -eq 1 ] && hz_poll
  fps_tick "$dt"
  local cf=""   # 本拍进曲线的帧率（静止不进）
  if [ -n "$F10" ] && [ "$F10" -lt "$IDLE_F10" ]; then
    S_IDLE=$(( S_IDLE + dt ))     # 画面静止：只计时，不进帧率统计
    S_JRUN=0
  elif [ -n "$F10" ]; then
    # 读数明显高于已知刷新率 = 刚切了档（如大厅 60 → 对局 90），立即重读，不等下一个 5 拍
    [ -n "$HZ_NOW" ] && [ "$F10" -gt $(( HZ_NOW * 10 + 30 )) ] && hz_poll
    # 读数不超过当前刷新率（统计窗口 ±1 帧的抖动）
    [ -n "$HZ_NOW" ] && [ "$F10" -gt $(( HZ_NOW * 10 )) ] && F10=$(( HZ_NOW * 10 ))
    local f=$(( F10 / 10 ))
    S_FN=$(( S_FN + 1 )); S_FSUM=$(( S_FSUM + F10 ))
    [ -z "$S_FMIN" ] || [ "$f" -lt "$S_FMIN" ] && S_FMIN=$f
    [ "$f" -gt "$S_FMAX" ] && S_FMAX=$f
    eval "[ -n \"\${H_$f}\" ] || S_HKEYS=\"\$S_HKEYS $f\"; H_$f=\$(( \${H_$f:-0} + 1 ))"
    # 对局段（最高刷新率档位）单独统计
    if [ "$S_HZ" -gt 0 ] && [ "$HZ_NOW" = "$S_HZ" ]; then
      S_HN=$(( S_HN + 1 )); S_HSUM=$(( S_HSUM + F10 )); S_HDUR=$(( S_HDUR + dt ))
      [ -z "$S_HMIN" ] || [ "$f" -lt "$S_HMIN" ] && S_HMIN=$f
      [ "$f" -gt "$S_HMAX" ] && S_HMAX=$f
      eval "[ -n \"\${G_$f}\" ] || S_GKEYS=\"\$S_GKEYS $f\"; G_$f=\$(( \${G_$f:-0} + 1 ))"
      # 卡顿：对局段里低于刷新率 90% 的秒数，以及最长连续卡顿
      if [ "$F10" -lt $(( S_HZ * 9 )) ]; then
        S_JANK=$(( S_JANK + 1 )); S_JRUN=$(( S_JRUN + 1 ))
        [ "$S_JRUN" -gt "$S_JMAX" ] && S_JMAX=$S_JRUN
      else
        S_JRUN=0
      fi
    else
      S_JRUN=0
    fi
    cf=$F10
  fi
  {
      rd "$P_BIG/scaling_cur_freq"; local b=$(( ${RV:-0} / 1000 ))
      S_BSUM=$(( S_BSUM + b )); [ "$b" -gt "$S_BMAX" ] && S_BMAX=$b
      if [ -n "$P_MID" ]; then rd "$P_MID/scaling_cur_freq"; S_MSUM=$(( S_MSUM + ${RV:-0} / 1000 )); fi
      gpu_read GMHZ
      if [ -n "$GMHZ" ]; then
        S_GSUM=$(( S_GSUM + GMHZ )); S_GN=$(( S_GN + 1 ))
        [ "$GMHZ" -gt "$S_GMAX" ] && S_GMAX=$GMHZ
      fi
      local tnow=""
      if [ -n "$TZ_PATH" ]; then
        rd "$TZ_PATH"
        case "$RV" in ''|*[!0-9-]*) ;; *) tnow=$RV; [ -z "$S_TMAX" ] || [ "$RV" -gt "$S_TMAX" ] && S_TMAX=$RV ;; esac
      fi
      rd "$FREQ"; case "$RV" in *9999999*) S_UNL=$(( S_UNL + 1 )) ;; esac
      curve_add "$cf" "$tnow" "$b"
  }
}

# 1% Low：帧率样本的第 1 百分位。$1 = 直方图前缀（H=整局 / G=对局段），$2 = 样本数
p1_low() {
  local pre=${1:-H} keys need=$(( (${2:-$S_FN} + 99) / 100 )) acc=0 k c
  [ "$pre" = G ] && keys=$S_GKEYS || keys=$S_HKEYS
  for k in $(printf '%s\n' $keys | sort -n); do
    eval "c=\${${pre}_$k:-0}"
    acc=$(( acc + c ))
    [ "$acc" -ge "$need" ] && { echo "$k"; return; }
  done
  echo 0
}

# 结束并写入一条记录
# 记录行（v1）：v1|开始时间|包名|时长s|平均fps×10|最低|最高|1%Low|大核均MHz|大核峰MHz|中核均MHz|GPU均MHz|GPU峰MHz|最高温mC|满频%|开局电量|结束电量|充电过
end_session() {
  [ -n "$S_PKG" ] || return
  local pkg=$S_PKG dur=$(( S_DUR / 100 ))
  S_PKG=""; rm -f "$CUR"
  if [ "$dur" -lt "$MIN_DUR" ] || [ "$S_N" -eq 0 ]; then
    log "结束：$pkg 前台 ${dur}s，不足 ${MIN_DUR}s，不记录"
    rm -f "$CURVE_TMP"
    return
  fi
  rd "$BATCAP"; local bat1=$RV
  rd "$BATST"; [ "$RV" = "Charging" ] && S_CHG=1
  local gavg="" ; [ "$S_GN" -gt 0 ] && gavg=$(( S_GSUM / S_GN ))
  local mavg="" ; [ -n "$P_MID" ] && mavg=$(( S_MSUM / S_N ))
  # 没有帧率来源时帧率四项留空（WebUI 显示 —）
  local favg="" p1="" fmax=""
  if [ "$S_FN" -gt 0 ]; then favg=$(( S_FSUM / S_FN )); p1=$(p1_low H "$S_FN"); fmax=$S_FMAX; fi
  # 对局段（最高刷新率档位）：样本太少（<30 拍）不单列
  local hz="" havg="" hmin="" hmax="" hp1="" hdur=""
  if [ "$S_HN" -ge 30 ]; then
    hz=$S_HZ; havg=$(( S_HSUM / S_HN )); hmin=$S_HMIN; hmax=$S_HMAX
    hp1=$(p1_low G "$S_HN"); hdur=$(( S_HDUR / 100 ))
  fi
  # 卡顿（只在有对局段时统计）：低于刷新率 90% 的秒数 | 最长连续卡顿秒数
  local jank="" jmax=""
  [ -n "$hz" ] && { jank=$S_JANK; jmax=$S_JMAX; }
  # v1 的 18 个字段保持不变；v2 追加：刷新率|对局均×10|对局最低|对局最高|对局1%Low|对局时长s|静止s
  # v3 再追加：卡顿秒数|最长连续卡顿秒数|有曲线(1/0)
  mkdir -p "$DATA" 2>/dev/null
  local hc=0; [ -s "$CURVE_TMP" ] && hc=1
  curve_save "$S_START"
  local line="v3|$S_START|$pkg|$dur|$favg|$S_FMIN|$fmax|$p1|$(( S_BSUM / S_N ))|$S_BMAX|$mavg|$gavg|$S_GMAX|$S_TMAX|$(( S_UNL * 100 / S_N ))|$S_BAT0|$bat1|$S_CHG|$hz|$havg|$hmin|$hmax|$hp1|$hdur|$(( S_IDLE / 100 ))|$jank|$jmax|$hc"
  echo "$line" >>"$REC"
  # 只保留最近 KEEP 局
  if [ "$(grep -c '' "$REC" 2>/dev/null)" -gt "$KEEP" ]; then
    tail -n "$KEEP" "$REC" >"$REC.tmp" && mv -f "$REC.tmp" "$REC"
  fi
  log "结束：$pkg 前台 ${dur}s，整局均 $([ -n "$favg" ] && echo "$(( favg / 10 ))fps" || echo "帧率不可用")$([ -n "$havg" ] && echo "，${hz}Hz 对局段 ${hdur}s 均 $(( havg / 10 ))fps")，静止 $(( S_IDLE / 100 ))s，过渡噪点 ${F_NOISE} 次"
}

# ---------- 守护 ----------
daemon() {
  MY=$$
  echo "$MY" >"$PIDFILE"
  echo -1000 >/proc/$MY/oom_score_adj 2>/dev/null
  trap 'end_session; rm -f "$PIDFILE"; exit 0' TERM INT
  S_PKG=""; S_HKEYS=""; BG=0; TICK=0
  rm -f "$CUR"
  # 开机/启动时重建一次游戏名单（新装的游戏才能被识别）
  sh "$MODDIR/cpulimit.sh" buildgames >/dev/null 2>&1
  load_games
  log "守护启动：pid=$MY"
  while :; do
    rd "$PIDFILE"; [ "$RV" != "$MY" ] && { end_session; exit 0; }
    TICK=$(( TICK + 1 ))
    fg_game
    if [ -n "$S_PKG" ]; then
      if [ "$FG" = "$S_PKG" ]; then
        BG=0; sample; sleep 1; continue
      fi
      # 不在前台：直接切到另一个游戏或进程没了 → 立即结束；否则进入后台宽限
      if [ -n "$FG" ] || ! pidof "$S_PKG" >/dev/null 2>&1; then
        end_session
      else
        BG=$(( BG + IDLE_SLEEP )); PREV_SF=""   # 回到前台后重新取基线，后台帧不计
        [ "$BG" -ge "$GRACE" ] && end_session
      fi
    fi
    if [ -z "$S_PKG" ] && [ -n "$FG" ]; then
      reset_session "$FG"; BG=0; sample; sleep 1; continue
    fi
    # 空闲时每 30 分钟刷新一次游戏名单
    if [ -z "$S_PKG" ] && [ $(( TICK % 900 )) -eq 0 ]; then
      sh "$MODDIR/cpulimit.sh" buildgames >/dev/null 2>&1; load_games
    fi
    sleep "$IDLE_SLEEP"
  done
}

is_alive() {
  rd "$PIDFILE"; local p=$RV
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  case "$(tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline")" in *gamerec.sh*daemon*) return 0 ;; esac
  return 1
}

# 先 TERM 让它把当前这局写进记录（trap 要等当前 sleep 结束，最多约 2s），再兜底 -9
stop_daemon() {
  if is_alive; then
    local p=$RV i=0
    kill "$p" 2>/dev/null
    while [ "$i" -lt 15 ] && kill -0 "$p" 2>/dev/null; do sleep 0.2; i=$(( i + 1 )); done
    kill -9 "$p" 2>/dev/null
  fi
  rm -f "$PIDFILE"
}

start_daemon() {
  stop_daemon
  nohup sh "$0" daemon >/dev/null 2>&1 &
}

case "$1" in
  daemon) daemon ;;
  start)  [ -f "$OFF" ] && { echo "游戏记录已关闭"; exit 0; }; start_daemon; echo "游戏记录已启动" ;;
  stop)   stop_daemon; echo "游戏记录已停止" ;;
  ensure) if [ -f "$OFF" ]; then is_alive && stop_daemon; else is_alive || start_daemon; fi ;;
  on)     rm -f "$OFF"; is_alive || start_daemon; echo "已开启游戏记录" ;;
  off)    mkdir -p "$DATA"; : >"$OFF"; stop_daemon; echo "已关闭游戏记录（已有记录保留）" ;;
  status)
    if [ -f "$OFF" ]; then echo "ENABLED=0"; else echo "ENABLED=1"; fi
    is_alive && echo "RUNNING=1" || echo "RUNNING=0"
    rd "$CUR"; echo "CUR=$RV"
    echo "NOW=$(date +%s)"
    n=$(grep -cE '^v[123][|]' "$REC" 2>/dev/null); echo "COUNT=${n:-0}"
    [ -s "$REC_BAK" ] && echo "UNDO=1" || echo "UNDO=0"
    # 采样能力自查：哪一项读不到就说明本机节点不同，写进诊断/WebUI，不用靠猜
    TZ_PATH=""; pick_zone; GPU_SRC=x; pick_gpu; pick_fps_src
    echo "TZ_PATH=${TZ_PATH:-无}"
    echo "GPU_SRC=$GPU_SRC"
    echo "FPS_SRC=$FPS_SRC"
    ;;
  list)   grep -E '^v[123][|]' "$REC" 2>/dev/null ;;
  curve)
    # $2 = 开局时间戳（纯数字，防路径穿越）
    case "$2" in ''|*[!0-9]*) echo "用法：gamerec.sh curve <时间戳>"; exit 1 ;; esac
    cat "$CURVE_DIR/$2.csv" 2>/dev/null ;;
  gametemp)
    # 每个游戏单独的温度阈值，存 $DATA/gametemp.conf（cpulimit.sh 读取）
    # ★ 存的是「相对当前温区基础阈值的差值」（毫摄氏度，正=更宽松），不是绝对值。
    #   原因：同一个 55°C 在机身温区(量程 30~60)和 CPU 结温(量程 50~95)上含义完全不同，
    #   存绝对值就会在换温区时变成一个荒谬的阈值。
    #   gametemp                     列出（"包名=差值"）
    #   gametemp <包名> <差值>        设置（-20000~15000）
    #   gametemp <包名> del          删除（回到全局阈值）
    #   读到的旧格式（45000~65000 的绝对值）由 cpulimit.sh 换算成差值，这里原样列出、不改文件。
    GT=$DATA/gametemp.conf
    if [ -z "$2" ]; then cat "$GT" 2>/dev/null; exit 0; fi
    case "$2" in *[!A-Za-z0-9._]*|.*|*..*) echo "不是合法包名：$2"; exit 1 ;; esac
    mkdir -p "$DATA"
    { grep -v "^$2=" "$GT" 2>/dev/null; } >"$GT.tmp"
    if [ "$3" = del ]; then
      :
    else
      case "$3" in ''|*[!0-9-]*) echo "阈值必须是毫摄氏度整数"; rm -f "$GT.tmp"; exit 1 ;; esac
      case "$3" in -*) ;; *) [ "$3" -ge 45000 ] && [ "$3" -le 65000 ] && { echo "$2=$3" >>"$GT.tmp"; mv -f "$GT.tmp" "$GT"; echo "已设置 $2 = $3（旧版绝对值格式）"; exit 0; } ;; esac
      if [ "$3" -lt -20000 ] || [ "$3" -gt 15000 ]; then echo "差值超出 -20000~15000"; rm -f "$GT.tmp"; exit 1; fi
      echo "$2=$3" >>"$GT.tmp"
    fi
    mv -f "$GT.tmp" "$GT"
    [ "$3" = del ] && echo "已删除 $2 的单独阈值" || echo "已设置 $2 = $3"
    ;;
  clear)
    # 删除有风险：先另存为 .cleared，可用 undo 恢复
    if [ -s "$REC" ]; then
      mv -f "$REC" "$REC_BAK" && echo "已清空（可恢复）"
    else
      echo "没有记录"
    fi ;;
  undo)
    if [ -s "$REC_BAK" ]; then
      # 合并：清空后新产生的记录接在后面，再按保留条数截断
      cat "$REC_BAK" "$REC" 2>/dev/null | tail -n "$KEEP" >"$REC.tmp" && mv -f "$REC.tmp" "$REC" && rm -f "$REC_BAK"
      echo "已恢复"
    else
      echo "没有可恢复的记录"
    fi ;;
  *) echo "用法：gamerec.sh {start|stop|ensure|status|list|curve <时间戳>|gametemp [包名 毫摄氏度|del]|clear|undo|on|off}"; exit 1 ;;
esac
