#!/system/bin/sh
# oplus-cloud-block - CPU 上限解除（反降频）
#
# 用法：
#   cpulimit.sh start     按配置启动（幂等，已在跑则先停）
#   cpulimit.sh stop      停止并还原出厂上限
#   cpulimit.sh status    打印配置、当前三簇频率与温度
#   cpulimit.sh apply     运行中热重载（按新配置重设，不重启守护）
#   cpulimit.sh daemon    守护循环（内部用）
#   cpulimit.sh ensure    健康检查补启（供 service.sh 的看护循环调用）
#
# 原理：/sys/kernel/msm_performance/parameters/cpu_max_freq 是 Qualcomm 的
#   逐 CPU 频率上限表（经 freq_qos 施加，dmesg 可见
#   freq_qos_update_request <- set_cpu_max_freq [msm_performance]）。出厂把它压在
#   小核1900800/中核2323200/大核1843200（大核只有硬件上限的 58%）。
#   写大值(9999999)即解除出厂上限，立即生效、无需重启、无需挂载。
#
#   还原：写回「首次开启时备份的原值」。**必须剥掉尾部空白**，否则内核解析
#   会整串拒绝（sed: xwrite: Invalid argument）——这是踩过的坑。

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH

MODDIR=${0%/*}
CONF="$MODDIR/cpulimit.conf"
FREQ=/sys/kernel/msm_performance/parameters/cpu_max_freq
# 老内核（如 4.14）上同一个节点在 /sys/module 下
[ -e "$FREQ" ] || FREQ=/sys/module/msm_performance/parameters/cpu_max_freq
GAMEPID=/proc/game_opt/game_pid
TOP_PROCS=/dev/cpuset/top-app/cgroup.procs
PIDFILE=/data/adb/oplus-cpulimit.pid
LOG=/data/adb/oplus-cloud-block.log
DATA=/data/adb/oplus-cloud-block-data
BAK="$DATA/cpu_max_freq.orig"

# 出厂兜底值（仅当备份缺失且当前值看起来是"被解除"状态时使用）
FACTORY="0:1900800 1:1900800 2:1900800 3:2323200 4:2323200 5:2323200 6:2323200 7:1843200"
UNLOCK="0:9999999 1:9999999 2:9999999 3:9999999 4:9999999 5:9999999 6:9999999 7:9999999"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CPU上限] $*" >>"$LOG"; }

# ---- 默认配置 ----
ENABLE=1
TEMP=55000          # 触发收回的温度阈值（机身/外壳类温区），毫摄氏度。55000 = 55.0°C
TEMP_CPU=80000      # CPU 结温类温区的阈值，毫摄氏度。80000 = 80.0°C
                    # ★ 必须与 TEMP 分开：CPU 结温天然比机身高得多。实测静置 ~50°C、
                    #   满频可到 90°C+，而同期外壳只有 37~40°C。共用 55°C 会在刚开游戏几秒就收回。
ZONE=skin-msm-therm # 保护监视的温区（首选）。默认 skin-msm-therm（机身表面=体感温度）。
                    # 本机没有时按 ZONE_FALLBACK 依次找替补，实际用到的温区名放 ZONE_USED。
                    # 注意：不要用 shell_front/shell_back —— 实测游戏满频时它们仅 37~40°C
                    # （新机型上三个 shell_* 甚至同值、完全不动），用它们形同虚设。
                    # 替补优先 CPU 结温（cpu-0-*/cpullc-*/cpu_big*/soc_max，随负载真动），
                    # 此时阈值自动切到 TEMP_CPU。
MODE=game           # global = 全局常开；game = 仅检测到游戏时开
HYST=3000           # 滞回，毫摄氏度。降到 TEMP-HYST 以下才恢复，防震荡

# 去掉首尾空白和 \r，结果放 TRIMMED。用 shell 自带的分词，不 fork。
# 本机每 fork 一次约 30ms，原来每行 printf|cut|tr + printf|cut|sed，一次读配置要 0.6s。
CR=$(printf '\r')
trim() {
  set -f
  local IFS=" 	$CR"
  # shellcheck disable=SC2086
  set -- $1
  TRIMMED=$1
  set +f
}

load_conf() {
  [ -f "$CONF" ] || return 0
  local raw line key val
  while IFS= read -r raw || [ -n "$raw" ]; do
    line=${raw%%#*}
    case "$line" in *=*) ;; *) continue ;; esac
    trim "${line%%=*}"; key=$TRIMMED
    trim "${line#*=}"; val=$TRIMMED
    case "$key" in
      ENABLE)   [ -n "$val" ] && ENABLE=$val ;;
      TEMP)     [ -n "$val" ] && TEMP=$val ;;
      TEMP_CPU) [ -n "$val" ] && TEMP_CPU=$val ;;
      ZONE)     [ -n "$val" ] && ZONE=$val ;;
      MODE)     [ -n "$val" ] && MODE=$val ;;
      HYST)     [ -n "$val" ] && HYST=$val ;;
    esac
  done <"$CONF"
  # 非数字/不合理的值回落默认，避免 [ -ge ] 比较报错导致判定失效
  case "$TEMP" in ''|*[!0-9]*) TEMP=55000 ;; esac
  case "$TEMP_CPU" in ''|*[!0-9]*) TEMP_CPU=80000 ;; esac
  case "$HYST" in ''|*[!0-9]*) HYST=3000 ;; esac
  [ "$HYST" -ge "$TEMP" ] && HYST=3000
}

# 持久化开关（stop 必须写 ENABLE=0，否则看护循环 120s 后会按 ENABLE=1 重新拉起）
set_enable() { # $1 = 0|1
  if [ ! -f "$CONF" ]; then
    echo "ENABLE=$1" >"$CONF"
  elif grep -q '^ENABLE=' "$CONF" 2>/dev/null; then
    sed -i "s/^ENABLE=.*/ENABLE=$1/" "$CONF"
  else
    { echo "ENABLE=$1"; cat "$CONF"; } >"$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
  fi
}

# ---- 原值备份 ----
# 备份内容必须是"有效的出厂值"：空串或含 9999999（已解锁状态）都不算，
# 否则以后的"还原"会写空值（内核拒收）或写回解锁值（等于没还原）。
valid_orig() { case "$1" in ''|*9999999*) return 1 ;; *) return 0 ;; esac; }

ensure_backup() {
  if [ -f "$BAK" ]; then
    valid_orig "$(cat "$BAK" 2>/dev/null)" && return 0
    rm -f "$BAK"; log "备份内容无效，已丢弃"
  fi
  local cur; cur=$(sed 's/[[:space:]]*$//' "$FREQ" 2>/dev/null)
  if ! valid_orig "$cur"; then
    log "当前上限为空或已是解锁值，跳过备份（还原时用出厂兜底值）"
    return 0
  fi
  mkdir -p "$DATA" 2>/dev/null
  printf '%s' "$cur" >"$BAK" 2>/dev/null && log "已备份出厂上限 -> $BAK"
}

# 读取备份原值（剥尾部空白；缺失或无效用出厂兜底）
orig_value() {
  local v; v=$(sed 's/[[:space:]]*$//' "$BAK" 2>/dev/null)
  if valid_orig "$v"; then printf '%s' "$v"; else factory_value; fi
}

# 没有有效备份时的兜底。写死的 FACTORY 是 Ace 2 Pro（PJA110）实测值，只在本机型用；
# 其他机型用每个核心的硬件上限（cpuinfo_max_freq）—— 不会把别的机型压到比出厂更低。
factory_value() {
  case "$(getprop ro.product.model)" in
    PJA110) printf '%s' "$FACTORY"; return ;;
  esac
  local c n out="" m
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*cpu}; m=""
    read -r m 2>/dev/null <"$c/cpufreq/cpuinfo_max_freq"
    [ -n "$m" ] && out="$out${out:+ }$n:$m"
  done
  printf '%s' "${out:-$FACTORY}"
}

# ---- 写上限 ----
# 关键：写完立刻 chmod 444。实测厂商服务会每 10~25s 抢写这个节点
# （曾观察到被写回 1843200 甚至 2476800），不设只读就会来回拉锯、
# 且有"被压住"的空窗。设 444 后厂商（非 root）改不动，实测 60s 稳定。
#   解锁：chmod 644 → 写 9999999 → chmod 444（锁死，防抢写）
#   还原：chmod 644 → 写出厂值 → 保持 644（交还厂商自主管理）
unlock_freq() {
  chmod 644 "$FREQ" 2>/dev/null
  printf '%s' "$UNLOCK" >"$FREQ" 2>/dev/null
  chmod 444 "$FREQ" 2>/dev/null
}

# 还原 = chmod 644 → 写出厂值 → 保持 644。
# 实测要点：
#   ① 只 chmod 644、不写值 → 节点保持 9999999、c7 仍是 3187200，**不还原**；
#     必须"写一个值"才会触发系统收回上限（写后 c7 从 3187200 掉回 ~2092800）。
#   ② 回读值可能是系统当时的策略值（如 2092800）而非写入的 1843200 —— 这是
#     正常的，节点由系统按温度动态夹取，c7 跟随系统值即为"出厂状态"。
#   ③ 写完保持 644，交还系统/厂商自主管理（不解锁时不应锁只读）。
restore_freq() {
  chmod 644 "$FREQ" 2>/dev/null
  printf '%s' "$(orig_value)" >"$FREQ" 2>/dev/null
  chmod 644 "$FREQ" 2>/dev/null
}

# ---- 游戏场景专用上限（第二层天花板）----
# 一检测到游戏，系统就往 /proc/game_opt/cpu_max_freq 写一组"游戏专用"上限
# （实测把大核压到 1843200，随温度还会收紧到 1478400），越过上面的 msm_performance。
# /proc/game_opt/disable_cpufreq_limit 是官方开关：写 1 = 禁用该限制。
# 实测写 1 后 game_opt/cpu_max_freq 立即变全 INT_MAX，c7 回到 3187200。
# 注意：不要用 `[ -w ]` 预判（toybox 对 /proc 伪文件可能误判为不可写）——直接写，失败也无害。
GAMEDIS=/proc/game_opt/disable_cpufreq_limit
enable_game()  { printf '1' >"$GAMEDIS" 2>/dev/null; }
disable_game() { printf '0' >"$GAMEDIS" 2>/dev/null; }
game_opt_ok()  { local v=""; read -r v 2>/dev/null <"$GAMEDIS"; [ "$v" = "1" ]; }

# 只读锁是否在位（用权限位字符串判断，不依赖 -w —— root 下 -w 不可靠）
node_readonly() {
  case "$(ls -l "$FREQ" 2>/dev/null)" in
    -r--r--r--*) return 0 ;;
    *) return 1 ;;
  esac
}

is_unlocked() {
  local v=""; read -r v 2>/dev/null <"$FREQ"
  case "$v" in *9999999*) return 0 ;; *) return 1 ;; esac
}

# 本模块这层是否已在位（节点=解锁值 且 只读锁在）。守护的判断仍以此为准 ——
# 每 5 秒一拍，这里绝不能 fork，所以只用内建 read + 权限位字符串。
# 注意：这 != "实际已满频"。节点在位但实际频率被别的链路压着是可能的
#（实测 Ace 2 Pro 的 OMRG、PLK110 都出现过），所以给用户看的文案不能只凭它。

# 采一小段时间，得到每个 policy 的"最低上限"。
# ★ 为什么不能只读一次：别的链路（如 OMRG）会在 state=0/1/2 之间每秒翻转几百次，
#   单次快照有大约 1/10 的概率正好抓到它放开的瞬间，从而误报"没被压"
#   （实测连测 4 次里出现过 1 次 CAPPED=0，而上限一直是 1459200）。
#   取样本里的最小值才是稳定的结论。结果放 CAP_KEYS / CAP_MIN（"0 1459200" 这种行）。
# 不进守护循环，所以这里的 fork 可以接受。
CAP_KEYS=""; CAP_MIN=""
sample_caps() {
  CAP_KEYS=""; CAP_MIN=""; _cm_n=0
  local p k v hw
  # 先记录硬件上限与 keys
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    hw=""; read -r hw 2>/dev/null <"$p/cpuinfo_max_freq"
    case "$hw" in ''|*[!0-9]*) continue ;; esac
    [ "$hw" -gt 0 ] || continue
    CAP_KEYS="$CAP_KEYS ${p##*/policy}:$hw"
  done
  [ -n "$CAP_KEYS" ] || return
  # 采 10 次，每次记录各 policy 的 min。
  # 采样密度不够会漏掉低频被压的簇（实测 policy7 在 5 次里可能一直没被压到，
  # 而下一次采样就抓到了 57%），所以宁可多采几次。
  local i=0
  while [ $i -lt 10 ]; do
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$p" ] || continue
      k=${p##*/policy}
      case " $CAP_KEYS " in *" $k:"*) ;; *) continue ;; esac
      v=""; read -r v 2>/dev/null <"$p/scaling_max_freq"
      case "$v" in ''|*[!0-9]*) continue ;; esac
      cur=$(printf '%s\n' "$CAP_MIN" | sed -n "s/^$k //p")
      if [ -z "$cur" ] || [ "$v" -lt "$cur" ]; then
        CAP_MIN=$(printf '%s\n' "$CAP_MIN" | grep -v "^$k " ; echo "$k $v")
      fi
    done
    i=$((i+1)); [ $i -lt 10 ] && sleep 0.15
  done
}

# 任何 policy 的（最低）上限低于硬件上限吗。写入 CAPPED / CAP_INFO / CAP_FREQ。
# 输出按 policy 号排序，保证同一状态下的文本稳定（否则每次顺序不同，不好比对）。
compute_capped() {
  CAPPED=0; CAP_INFO=""; CAP_FREQ=""
  local k hw v pct
  for k in $(printf '%s\n' "$CAP_MIN" | awk '{print $1}' | sort -n); do
    hw=$(printf '%s\n' "$CAP_KEYS" | tr ' ' '\n' | sed -n "s/^$k://p")
    v=$(printf '%s\n' "$CAP_MIN" | sed -n "s/^$k //p")
    case "$hw$v" in ''|*[!0-9]*) continue ;; esac
    [ "$hw" -gt 0 ] || continue
    pct=$(awk -v a="$v" -v b="$hw" 'BEGIN{printf "%d%%", a*100/b}')
    CAP_FREQ="$CAP_FREQ $k:$v/$hw($pct)"
    [ "$v" -lt "$hw" ] || continue
    CAPPED=1
    CAP_INFO="$CAP_INFO $k:$pct"
  done
  CAP_INFO=${CAP_INFO# }
  CAP_FREQ=${CAP_FREQ# }
}

# ---- 温度 ----
# 全部用内建 read 读 sysfs，不 fork cat（本机温区很多，守护每 5s 一次）。
find_zone() { # $1 = type 名
  local z zt
  for z in /sys/class/thermal/thermal_zone*; do
    zt=""; read -r zt 2>/dev/null <"$z/type"
    [ "$zt" = "$1" ] && { echo "${z##*thermal_zone}"; return; }
  done
}

# 读保护温区（ZONE 指定，默认 skin-msm-therm），结果放进全局 T_NOW（读不到为空）。
# 注意：必须直接调用、不能 $(read_temp) —— 子 shell 里写的缓存会丢。
# 温区号缓存按 ZONE 名失效；缓存号的 type 对不上（温区重排）也会重查。
#
# ★ 替补分两级，级别决定阈值（这是关键，不能混）：
#   CPU 结温类 —— 随负载真实上升，保护有效。用它时阈值取 TEMP_CPU。
#     实测：静置 ~50°C，满频可到 90°C+。外壳同期只有 37~40°C。
#  机身/外壳类 —— 数值低且可能整台机同值不动（新机型上三个 shell_* 常同值死值）。
#     只在前者一个都没有时用，阈值取 TEMP。
#
# 三级顺序：用户配置的 ZONE > CPU 结温家族 > 机身/外壳家族。都找不到就读不到温度，
# 守护保守地不解锁（宁可不解锁，也不要拿死值假装有保护）。
#   skin-msm-therm：骁龙 8 Gen2 / Gen3 等（一加 Ace 2 Pro），机身表面
#   cpu-0-* / cpullc-*：骁龙 8 Elite Gen5 起的 CPU 结温
#   cpu_big* / cpu_little*：天玑 CPU 结温
#   skin_ntc / shell_* / board_temp：OPLUS 外壳、主板（数值低，兜底）
#
# CPU 结温温区判定。按前缀匹配，因为同一台机的名字是 cpu-0-0-0 / cpu-0-3-1 / cpullc-1-0
# （骁龙 8 Elite）或 cpu_big2 / cpu_little3（天玑），逐个枚举会漏。
# ★ 必须排除 trip 点：PLK110 上 cpu-hw-trip-0 = 95000 是"门限值"不是温度，
#   误选它会让模块永远以为 95°C、永不解锁。
is_cpu_zone() {
  case "$1" in
    *trip*) return 1 ;;
    cpu-*|cpullc-*|cpu_big*|cpu_little*|cpuss*|soc_max|soc_top|mtktscpu|mtkts_cpu) return 0 ;;
  esac
  return 1
}
# 机身/外壳类（数值低且可能整台机同值不动，只作最后兜底）
is_skin_zone() {
  case "$1" in
    skin-msm-therm|skin_ntc|shell_*|board_temp|ap_ntc) return 0 ;;
  esac
  return 1
}

ZONE_NAME_C=""; ZONE_NUM_C=""; ZONE_USED=""; ZONE_T=""; T_NOW=""
read_temp() {
  local zt="" z zt2
  [ -n "$ZONE_NUM_C" ] && read -r zt 2>/dev/null <"/sys/class/thermal/thermal_zone$ZONE_NUM_C/type"
  if [ "$ZONE_NAME_C" != "$ZONE" ] || [ "$zt" != "$ZONE_USED" ]; then
    ZONE_NAME_C=$ZONE; ZONE_USED=""; ZONE_NUM_C=""
    # ① 用户配置的温区（按名字精确找）
    ZONE_NUM_C=$(find_zone "$ZONE")
    [ -n "$ZONE_NUM_C" ] && ZONE_USED=$ZONE
    # ② 没有就扫全表：CPU 结温家族优先，其次机身/外壳家族
    if [ -z "$ZONE_NUM_C" ]; then
      for z in /sys/class/thermal/thermal_zone*; do
        zt2=""; read -r zt2 2>/dev/null <"$z/type"
        is_cpu_zone "$zt2" && { ZONE_NUM_C=${z##*thermal_zone}; ZONE_USED=$zt2; break; }
      done
      if [ -z "$ZONE_NUM_C" ]; then
        for z in /sys/class/thermal/thermal_zone*; do
          zt2=""; read -r zt2 2>/dev/null <"$z/type"
          is_skin_zone "$zt2" && { ZONE_NUM_C=${z##*thermal_zone}; ZONE_USED=$zt2; break; }
        done
      fi
    fi
    zone_class "$ZONE_USED"
  fi
  T_NOW=""
  [ -n "$ZONE_NUM_C" ] && read -r T_NOW 2>/dev/null <"/sys/class/thermal/thermal_zone$ZONE_NUM_C/temp"
  case "$T_NOW" in *[!0-9-]*) T_NOW="" ;; esac
}

# 温区属于哪一级 → 该用哪个阈值。结果放 ZONE_T（skin / cpu）。
zone_class() {
  if is_cpu_zone "$1"; then ZONE_T=cpu; else ZONE_T=skin; fi
}

# 当前生效的基础阈值放进 EFF_BASE：CPU 结温温区用 TEMP_CPU，其余用 TEMP。
# 不用 $(...) 取值：守护每 5s 一拍，本机每 fork 约 30ms，纯为取值不值得。
eff_base() {
  if [ "$ZONE_T" = cpu ]; then EFF_BASE=${TEMP_CPU:-80000}; else EFF_BASE=${TEMP:-55000}; fi
}
shell_temp() { read_temp; printf '%s' "$T_NOW"; }

# 读任意温区（按 type 名）
zone_temp() {
  local zn tv=""; zn=$(find_zone "$1")
  [ -n "$zn" ] && read -r tv 2>/dev/null <"/sys/class/thermal/thermal_zone$zn/temp"
  printf '%s' "$tv"
}

# ---- 过热滞回 ----
# 超过 TEMP 收回后打标记，必须降到 TEMP-HYST 以下才清标记、允许再解锁，
# 避免温度在阈值附近时每 5s 来回切换。标记只在状态切换时写，不会频繁写闪存。
HOT_FLAG=/data/adb/oplus-cpulimit.hot
is_hot() { [ -f "$HOT_FLAG" ]; }
# 根据 T_NOW 更新标记；返回 0 = 处于过热保护中。
# 阈值用 EFF_TEMP（由应该解锁判定算好：温区级别的基础阈值 + 前台游戏的单独阈值）。
update_hot() {
  local th=${EFF_TEMP:-${TEMP:-55000}}
  if is_hot; then
    if [ "$T_NOW" -lt $((th - HYST)) ] 2>/dev/null; then
      rm -f "$HOT_FLAG"; log "$ZONE_USED 降到 ${T_NOW}，低于 $((th - HYST))，解除过热保护"
      return 1
    fi
    return 0
  fi
  if [ "$T_NOW" -ge "$th" ] 2>/dev/null; then
    : >"$HOT_FLAG"; log "$ZONE_USED ${T_NOW} 达到阈值 ${th}${GAME_LAST:+（$GAME_LAST）}，进入过热保护"
    return 0
  fi
  return 1
}

# ---- 游戏检测 ----
# 注意：toybox 的 sed 不支持 `\?`（可选匹配），必须用 `[0-9-]*` 吞掉负号。
# 之前用 `\(-\?[0-9]*\)` 会导致模式失配、永远返回空 → 游戏检测永远为"无游戏"。
# 文件内容形如 "game_pid=-1 child_num=0"。用内建 read + 参数展开，不 fork sed。
game_pid_val() {
  local g=""; read -r g 2>/dev/null <"$GAMEPID"
  case "$g" in *game_pid=*) g=${g#*game_pid=}; g=${g%%[!0-9-]*} ;; *) g="" ;; esac
  echo "$g"
}
# 系统实时游戏检测（game_pid 仅当游戏独占前台时才置位；切到 WebUI 时会归零）
sys_game() {
  local g=""; read -r g 2>/dev/null <"$GAMEPID"
  case "$g" in *game_pid=*) ;; *) return 1 ;; esac
  g=${g#*game_pid=}; g=${g%%[!0-9-]*}
  [ -n "$g" ] && [ "$g" != "-1" ] && [ "$g" != "0" ]
}
# ColorOS 已识别的游戏名单：settings 里的 GC_SETTING_SYSTEM_KEY_GAMESPACE_GAME_LAUNCH_TIME_<pkg>
# （游戏空间记录过启动时间的应用）。
# 不再用 /data/oplus/uxicons/<pkg>/game_app.png：实测豆包、豆包输入法也有这个图标，
# 会被当成游戏 —— 输入法常驻后台，「仅游戏」模式就等于一直满频。
# 没进名单的游戏在独占前台时仍会被系统 game_pid 识别。
GAME_LIST_CACHE=/data/adb/oplus-cpulimit.games
build_game_list() {
  settings list global 2>/dev/null \
    | sed -n 's/^GC_SETTING_SYSTEM_KEY_GAMESPACE_GAME_LAUNCH_TIME_\([a-zA-Z0-9._]*\)=.*/\1/p' \
    | sort -u >"$GAME_LIST_CACHE.tmp" 2>/dev/null && mv -f "$GAME_LIST_CACHE.tmp" "$GAME_LIST_CACHE"
}
NL='
'
# 前台游戏的包名放进 GAME_FG（没有游戏在前台则为空，返回 1）：
#   ① 系统 game_pid（游戏独占前台时置位）
#   ② top-app cpuset 里有名单内的游戏
# 只认前台：王者这类游戏退到后台后进程常驻，以前只看进程在不在，
# 在桌面上也一直满频，白白耗电发热。全部用内建 read，不 fork。
game_fg() {
  GAME_FG=""
  local g=""; read -r g 2>/dev/null <"$GAMEPID"
  case "$g" in *game_pid=*) g=${g#*game_pid=}; g=${g%%[!0-9]*} ;; *) g="" ;; esac
  local nm
  if [ -n "$g" ] && [ "$g" != "0" ]; then
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"/proc/$g/cmdline"; nm=${nm%%:*}
    [ -n "$nm" ] && { GAME_FG=$nm; return 0; }
  fi
  [ -r "$TOP_PROCS" ] || return 1
  [ -f "$GAME_LIST_CACHE" ] || build_game_list
  local games="" l pid
  while read -r l; do [ -n "$l" ] && games="$games$NL$l"; done 2>/dev/null <"$GAME_LIST_CACHE"
  [ -n "$games" ] || return 1
  while read -r pid; do
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"/proc/$pid/cmdline"; nm=${nm%%:*}
    case "$nm" in *.*) ;; *) continue ;; esac
    case "$games$NL" in *"$NL$nm$NL"*) GAME_FG=$nm; return 0 ;; esac
  done <"$TOP_PROCS"
  return 1
}

# 守护用：带宽限的前台判定。短暂切出去（回个微信、下拉通知栏）GAME_GRACE 秒内
# 仍按游戏在前台处理，避免满频来回切换。GAME_SEEN 只在守护进程内存里，WebUI 查询不带宽限。
GAME_GRACE=15
GAME_SEEN=""; GAME_LAST=""
up_s() { local u=""; read -r u _ 2>/dev/null </proc/uptime; UP=${u%%.*}; }
game_active() {
  up_s
  if game_fg; then GAME_LAST=$GAME_FG; GAME_SEEN=$UP; return 0; fi
  [ -n "$GAME_SEEN" ] && [ $(( UP - GAME_SEEN )) -lt "$GAME_GRACE" ]
}

# 按游戏单独设的温度阈值 = 在「当前温区级别的基础阈值」上再偏移。
# 不存绝对值的原因是：同一个"55°C"在机身温区(量程 30~60)和 CPU 结温(量程 50~95)上含义完全不同。
# 所以存差值 DELTA（毫摄氏度，正=更宽松），WebUI 读数直接映射成「机身 52.0°C / 60.0°C」这种相对值。
# 文件放数据目录（模块更新会整体替换模块目录，放这里不丢）。每行 "包名=差值" 或旧格式 "包名=绝对值"。
# 兼容旧格式：值落在 45000~65000 是旧版 WebUI 写的绝对值，换算成相对 55000 的差值
# （旧 UI 的可选范围就是 45~65、基准恒为 55，所以差值必然等于 v-55000，落在 ±10000 内）。
# ★ 不能把旧绝对值直接当阈值用：在 CPU 结温档上"55°C"意味着刚开始玩就收回，等于关不掉。
#   换算后意图不变（用户当初就是想比默认宽/紧几度），且换温区机器也合理。
GAMETEMP_FILE=$DATA/gametemp.conf
GAMETEMP_OLD_BASE=55000               # 旧版绝对值的隐含基准
BIGGEST_DELTA=15000                   # 单个游戏最多能放宽多少

game_temp() { # $1 = 包名；把 EFF_TEMP 改成「基础阈值 + 该游戏的差值」
  [ -n "$1" ] && [ -f "$GAMETEMP_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    [ "$k" = "$1" ] || continue
    v=${v%"$CR"}
    case "$v" in ''|*[!0-9-]*) return 0 ;; esac
    case "$v" in
      -*) ;;
      *) [ "$v" -ge 45000 ] && [ "$v" -le 65000 ] && v=$(( v - GAMETEMP_OLD_BASE )) ;;
    esac
    [ "$v" -gt "$BIGGEST_DELTA" ] && v=$BIGGEST_DELTA
    [ "$v" -lt -20000 ] && v=-20000
    EFF_TEMP=$(( EFF_BASE + v ))
    return 0
  done 2>/dev/null <"$GAMETEMP_FILE"
}

# ---- 前台应用 ----
# 守护用：勾选的应用是否在前台。读 top-app cpuset 的进程列表（内建 read，不跑 dumpsys），
# 进程名去掉 ":子进程" 后缀即包名。cpuset 不存在时退回 dumpsys。
app_match() {
  [ -f "$APPS_FILE" ] || return 1
  if [ ! -r "$TOP_PROCS" ]; then
    local cur; cur=$(top_pkg)
    [ -n "$cur" ] && app_selected "$cur"
    return
  fi
  local sel pid nm; sel=$(cat "$APPS_FILE" 2>/dev/null)
  [ -n "$sel" ] || return 1
  while read -r pid; do
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"/proc/$pid/cmdline"
    nm=${nm%%:*}
    case "$nm" in *.*) ;; *) continue ;; esac
    case "
$sel
" in *"
$nm
"*) return 0 ;; esac
  done <"$TOP_PROCS"
  return 1
}

# 取当前前台包名（仅 WebUI 显示原因时用；dumpsys 较重，不放进守护循环）
top_pkg() {
  local p
  p=$(dumpsys activity activities 2>/dev/null \
      | grep -m1 -E 'topResumedActivity|ResumedActivity' \
      | sed -n 's/.*u0 \([a-zA-Z0-9._]*\)\/.*/\1/p')
  [ -z "$p" ] && p=$(dumpsys window 2>/dev/null \
      | grep -m1 -E 'mCurrentFocus|mFocusedApp' \
      | sed -n 's/.* \([a-zA-Z0-9._]*\)\/.*/\1/p')
  printf '%s' "$p"
}

# 勾选的应用列表（每行一个包名，来自 cpulimit.conf 的 APPS=... 或 apps.txt）
APPS_FILE="$MODDIR/cpulimit.apps"
app_selected() { # $1 = 包名
  [ -f "$APPS_FILE" ] || return 1
  grep -qxF "$1" "$APPS_FILE" 2>/dev/null
}
# ---- 决策：现在应该解锁吗 ----
# 阈值只有一个计算入口，避免守护 / WebUI / 日志算出不同的值。
# 调用前需先 read_temp（tick 里做），这里直接用 T_NOW，避免一次 tick 读两遍温度。
# need_game = 调用方是否还要 GAME_LAST 来判断游戏（WebUI 的 why_state 走 game_fg 自己算）。
set_thresholds() {
  eff_base                                  # EFF_BASE = 按温区级别定的基础阈值
  EFF_TEMP=$EFF_BASE
  case "$MODE" in
    game) if [ "$1" = local ]; then game_active || return 1; fi
          game_temp "$GAME_LAST" ;;
    apps) if [ "$1" = local ]; then app_match || return 1; fi ;;
  esac
  return 0
}

should_unlock() {
  # 无温度读数 → 保守起见不解锁
  [ -n "$T_NOW" ] || return 1
  local want=0
  if ! set_thresholds local; then want=1; fi
  update_hot && return 1   # 过热保护中（含滞回），收回
  return $want
}

# 毫摄氏度 -> "xx.x°C"
mC() { awk -v v="$1" 'BEGIN{ if(v==""){print "?"; exit} printf "%.1f°C", v/1000 }'; }

# 说明"当前为何是/不是满频"，供 WebUI 显示（一行中文）
# 只读：不改过热标记（标记归守护管），否则 WebUI 刷新会和守护抢状态。
why_state() {
  read_temp
  local t=$T_NOW
  [ -n "$t" ] || { echo "读不到温度"; return; }
  GAME_LAST=""
  [ "$MODE" = game ] && game_fg && GAME_LAST=$GAME_FG
  set_thresholds web   # 不管前台条件，只算阈值
  local wn="机身"; [ "$ZONE_T" = cpu ] && wn="CPU"
  # 本模块这层是否在位（节点=解锁值），以及实际频率有没有真的顶到硬件上限。
  # 两者要分开说：节点在位 ≠ 实际满频。实测 Ace 2 Pro(OMRG) 与 PLK110 上都出现过
  # 「节点已是 9999999，但 scaling_max_freq 被压到 19%」，只报"已满频"就是骗用户。
  local unl="否"; is_unlocked && unl="是"
  # 复用 status 已经采过的那份（CAP_FREQ 非空即为已采样），避免一次 status 采两遍、
  # 两次结果还可能不一样（别的链路在翻转），导致同屏数据自相矛盾。
  [ -n "$CAP_FREQ" ] || { sample_caps; compute_capped; }
  local cap=$CAP_INFO full="否"; [ "$CAPPED" = 0 ] && full="是"
  if [ "$t" -ge "$EFF_TEMP" ] 2>/dev/null; then
    echo "$wn $(mC "$t") 已超阈值 $(mC "$EFF_TEMP")，已收回保护"; return
  fi
  if is_hot; then
    echo "过热保护中 · $wn $(mC "$t")，降到 $(mC $((EFF_TEMP - HYST))) 以下恢复"; return
  fi
  # 已经解锁但实际没顶到上限 → 别处还有一层在压，这条优先于下面的模式判定。
  # 文案里的数字要和 status 的 CAP_FREQ 一致（同一个 $cap，来自同一次采样）。
  if [ "$unl" = 是 ] && [ "$full" = 否 ]; then
    echo "本层已解除，但实际频率仍被压（$cap）· 另有链路在限制，不是本模块能解的"; return
  fi
  if [ "$unl" = 否 ] && [ "$full" = 否 ]; then
    echo "待命（本层未解除），且实际频率被压（$cap）"; return
  fi
  case "$MODE" in
    game)
      # WebUI 打开时游戏必然不在前台；守护有 15 秒宽限，所以刚切出来时仍是满频
      if [ -n "$GAME_FG" ]; then echo "游戏 $GAME_FG 在前台，已满频（阈值 $(mC "$EFF_TEMP")）"
      elif [ "$unl" = 是 ]; then echo "游戏刚切到后台，15 秒内收回"
      else echo "待命 · 游戏在前台时满频"; fi ;;
    apps)
      local cur; cur=$(top_pkg)
      if [ -z "$cur" ]; then echo "待命 · 取不到前台应用"
      elif app_selected "$cur"; then
        [ "$full" = 是 ] && echo "前台 $cur 已勾选，已满频" || echo "前台 $cur 已勾选，但实际频率被压（$cap）"
      else echo "待命 · 前台 $cur 不在已选列表"; fi ;;
    *)
      [ "$full" = 是 ] && echo "全局模式，已满频" || echo "全局模式，但实际频率被压（$cap）" ;;
  esac
}

# ---- 执行一次决策 ----
# 仅状态变化时才写+记日志，避免每次 tick 都刷屏（实测节点会被厂商抢写，
# 值对但只读锁丢了也要补锁）。
tick() {
  read_temp
  local t=$T_NOW
  if should_unlock; then
    # 先判断值（内建 read，几乎零开销），值对了再查只读锁（ls fork 一次）
    if ! is_unlocked || ! node_readonly; then
      ensure_backup
      unlock_freq
      log "解锁（${ZONE_USED:-$ZONE} ${t} 阈值 ${EFF_TEMP:-${TEMP:-55000}} 模式 $MODE${GAME_LAST:+ 游戏 $GAME_LAST}）"
    fi
    # 游戏场景的第二层上限：确保也被禁用（系统会反复重置，需每次补写）
    game_opt_ok || { enable_game; log "禁用游戏上限（game_pid=$(game_pid_val)）"; }
  else
    if is_unlocked; then
      restore_freq
      log "收回（${ZONE_USED:-$ZONE} ${t} 阈值 ${EFF_TEMP:-${TEMP:-55000}} 模式 $MODE 前台游戏=${GAME_FG:-无}）"
    fi
    game_opt_ok && { disable_game; log "恢复游戏上限"; }
  fi
}

# ---- 守护 ----
list_daemons() {
  for p in /proc/[0-9]*; do
    cl=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline") || continue
    case "$cl" in *cpulimit.sh*daemon*) echo "${p#/proc/}" ;; esac
  done
}

kill_daemons() {
  r=0
  while [ "$r" -lt 5 ]; do
    pids=$(list_daemons); [ -z "$pids" ] && break
    kill -9 $pids 2>/dev/null; sleep 0.3; r=$((r + 1))
  done
}

stop_daemon() {
  if [ -f "$PIDFILE" ]; then
    op=$(cat "$PIDFILE" 2>/dev/null); [ -n "$op" ] && kill -9 "$op" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  kill_daemons
}

# 除了 pid 存活，还要核对 cmdline 是本守护：重启后 pidfile 里的旧 pid
# 可能已被别的进程复用，只看 kill -0 会误判"在跑"，开机 ensure 就不拉起了。
is_alive() {
  [ -f "$PIDFILE" ] || return 1
  p=$(cat "$PIDFILE" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  case "$(tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline")" in
    *cpulimit.sh*daemon*) return 0 ;;
  esac
  return 1
}

# 配置签名 = mtime + 大小（一次 stat，原来 cksum|awk 两次 fork）。WebUI 写配置会更新 mtime。
conf_sig() { stat -c '%Y-%s' "$CONF" 2>/dev/null; }

daemon() {
  MY=$$
  echo "$MY" >"$PIDFILE"
  echo -1000 >/proc/$MY/oom_score_adj 2>/dev/null
  LASTCONF=$(conf_sig)
  log "守护启动：pid=$MY ENABLE=$ENABLE TEMP=$TEMP MODE=$MODE"
  while :; do
    cur=$(cat "$PIDFILE" 2>/dev/null)
    [ "$cur" != "$MY" ] && { log "被新实例接管，退出 pid=$MY"; exit 0; }
    sig=$(conf_sig)
    if [ "$sig" != "$LASTCONF" ]; then
      ENABLE=1; TEMP=55000; TEMP_CPU=80000; ZONE=skin-msm-therm; MODE=game; HYST=3000
      load_conf
      if [ "$ENABLE" != "1" ]; then
        restore_freq; disable_game; rm -f "$HOT_FLAG"
        log "ENABLE!=1，已还原上限并退出"
        rm -f "$PIDFILE"; exit 0
      fi
      LASTCONF=$sig
      log "配置已更新：TEMP=$TEMP ZONE=$ZONE MODE=$MODE"
    fi
    tick
    sleep 5
  done
}

# ---- 命令 ----
cmd_status() {
  echo "=== CPU 上限解除 ==="
  if is_alive; then
    echo "状态：运行中（pid $(cat "$PIDFILE")）"
  else
    [ -f "$PIDFILE" ] && echo "状态：异常（残留 pidfile，守护已死）" || echo "状态：未运行"
  fi
  echo "配置：ENABLE=$ENABLE TEMP=${TEMP}/TEMP_CPU=${TEMP_CPU} ZONE=$ZONE MODE=$MODE HYST=$HYST"
  # 先采样，后面的"当前上限/capped 判定"都用这一份数据，避免同一份报告里自相矛盾
  sample_caps; compute_capped
  echo "当前上限：$(cat "$FREQ" 2>/dev/null)"
  echo "游戏上限：$(cat /proc/game_opt/cpu_max_freq 2>/dev/null || echo '—')  [disable_cpufreq_limit=$(cat "$GAMEDIS" 2>/dev/null)]"
  echo "出厂备份：$(orig_value)"
  echo
  echo "当前频率（上限 / 实际 / 硬件上限）："
  for c in 0 4 7; do
    printf '  cpu%-2s %8s / %8s / %8s\n' "$c" \
      "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq 2>/dev/null)" \
      "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)" \
      "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq 2>/dev/null)"
  done
  echo
  # ★ 实际有没有被压（本函数开头已 sample_caps + compute_capped）：
  #   只看我们那个节点是不够的 —— 节点可能是 9999999（我们这层解开了），
  #   而 scaling_max_freq 仍被别的链路压着。实测 Ace 2 Pro（OMRG）和 PLK110 都出现过，
  #   于是 WebUI 显示"已满频"但数字只有 19%，用户看到的正是这个矛盾。
  #   CAP_FREQ 给出每簇的实际最低上限/硬件上限（百分比），便于定位。
  echo "CAPPED=$CAPPED"
  echo "CAP_INFO=$CAP_INFO"
  echo "CAP_FREQ=$CAP_FREQ"
  echo
  read_temp
  echo "前台游戏 = $(game_fg && echo "$GAME_FG" || echo 无)"
  # 实际用于保护的温区（配置的温区本机没有时会换成替补），及该温区用哪个阈值
  echo "ZONE_USED=${ZONE_USED:-无}"
  echo "ZONE_T=${ZONE_T:-none}"
  eff_base; echo "EFF_TEMP=$EFF_BASE"
  echo "SKIN_TEMP=$T_NOW"
  echo "SHELL_TEMP=$(zone_temp shell_front)"
  echo "STATE_HINT=$(why_state)"
}

# start = 用户主动开启：写 ENABLE=1 持久化，再（重新）拉起守护。
# 开机由 service.sh 调 ensure，尊重配置里的 ENABLE，不会把用户关掉的功能重新打开。
cmd_start() {
  set_enable 1
  load_conf
  stop_daemon
  nohup sh "$0" daemon >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 15 ]; do
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
      echo "CPU 上限解除已启动（阈值 ${TEMP}，模式 $MODE）"
      exit 0
    fi
    sleep 0.2; i=$((i + 1))
  done
  echo "启动失败，请查看 $LOG"
  exit 1
}

# stop = 用户主动关闭：必须写 ENABLE=0，否则看护循环 120s 后的 ensure 和
# 下次开机都会按 ENABLE=1 重新拉起守护，用户以为关了其实又满频了。
cmd_stop() {
  set_enable 0
  stop_daemon
  restore_freq
  disable_game
  rm -f "$HOT_FLAG"
  log "已停止并还原出厂上限（含游戏上限），已写 ENABLE=0"
  echo "已停止，出厂上限已还原：$(cat "$FREQ" 2>/dev/null)"
}

cmd_apply() {
  load_conf
  # 配置是关闭状态时不能 tick（tick 会按条件解锁），交给 stop 走完整还原
  if [ "$ENABLE" != "1" ]; then cmd_stop; return; fi
  tick
  if ! is_alive; then
    nohup sh "$0" daemon >/dev/null 2>&1 &
    echo "已按新配置应用并（重新）启动守护（TEMP=$TEMP MODE=$MODE）"
  else
    echo "已热重载（TEMP=$TEMP MODE=$MODE）"
  fi
}

cmd_ensure() {
  load_conf
  if [ "$ENABLE" != "1" ]; then
    if is_alive || is_unlocked; then
      stop_daemon; restore_freq; disable_game; rm -f "$HOT_FLAG"
      log "ensure：配置已关闭，还原并停止"
    fi
    return 0
  fi
  is_alive && return 0
  log "ensure：守护不在，重新拉起"
  nohup sh "$0" daemon >/dev/null 2>&1 &
  sleep 1
}

# 本机没有高通 msm_performance 节点（联发科/天玑等）→ 温控性能不适用。
# 守护、开启、热重载都不执行，避免空转；status 如实报告，WebUI 据此提示。
if [ ! -e "$FREQ" ]; then
  case "$1" in
    status)
      echo "=== CPU 上限解除 ==="
      echo "状态：本机不支持"
      echo "UNSUPPORTED=1"
      echo "STATE_HINT=本机没有高通 msm_performance 限频节点（联发科/天玑机型没有），温控性能不可用"
      exit 0 ;;
    stop|ensure) exit 0 ;;
    *) echo "本机不支持温控性能：没有 $FREQ（联发科/天玑机型没有这个节点）"; exit 1 ;;
  esac
fi

case "$1" in
  daemon) load_conf; daemon ;;
  ensure) cmd_ensure ;;
  start|"") cmd_start ;;
  stop)  cmd_stop ;;
  status) load_conf; cmd_status ;;
  apply) cmd_apply ;;
  tick)  load_conf; tick; echo "tick done: $(cat "$FREQ")" ;;
  buildgames) build_game_list; echo "游戏名单 $(grep -c '' "$GAME_LIST_CACHE" 2>/dev/null) 个" ;;
  why)   load_conf; why_state ;;
  *) echo "用法：cpulimit.sh {start|stop|status|apply|tick}"; exit 1 ;;
esac
