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
#   cpulimit.sh observe [包名]  只读枚举游戏 TID（不写 affinity）
#   cpulimit.sh recover   停止守护并恢复模块持有的事务资源
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

MODDIR=${CPULIMIT_MODDIR:-${0%/*}}
CONF="$MODDIR/cpulimit.conf"
# 路径集中定义，正常设备保持原值；测试可用 fake proc/sys 替换，避免碰真实节点。
PROC_ROOT=${CPULIMIT_PROC_ROOT:-/proc}
SYS_ROOT=${CPULIMIT_SYS_ROOT:-/sys}
CPU_ROOT=${CPULIMIT_CPU_ROOT:-$SYS_ROOT/devices/system/cpu}
THERMAL_ROOT=${CPULIMIT_THERMAL_ROOT:-$SYS_ROOT/class/thermal}
GAME_OPT=${CPULIMIT_GAME_OPT:-$PROC_ROOT/game_opt}
FREQ=${CPULIMIT_FREQ:-$SYS_ROOT/kernel/msm_performance/parameters/cpu_max_freq}
# 老内核（如 4.14）上同一个节点在 /sys/module 下
[ -e "$FREQ" ] || FREQ=${CPULIMIT_FREQ_ALT:-$SYS_ROOT/module/msm_performance/parameters/cpu_max_freq}
# 平台：高通走 msm_performance 节点，天玑走 cpufreq policy（见文档开头 MTK 段）。
# 以平台属性为准，不看节点在不在 —— 有些骁龙机的节点路径未知，误判成 MTK 会写错节点。
PLATFORM=$(getprop ro.board.platform 2>/dev/null)
SOC=$(getprop ro.soc.manufacturer 2>/dev/null)
case "$PLATFORM$SOC" in
  *mt*|*mediatek*|*MTK*) PLATFORM=mtk ;;
  *) PLATFORM=qcom ;;
esac
GAMEPID=${CPULIMIT_GAMEPID:-$GAME_OPT/game_pid}
TOP_PROCS=${CPULIMIT_TOP_PROCS:-/dev/cpuset/top-app/cgroup.procs}
PIDFILE=${CPULIMIT_PIDFILE:-/data/adb/oplus-cpulimit.pid}
PIDSTART="$PIDFILE.start"
CMD_LOCK=${CPULIMIT_CMD_LOCK:-/data/adb/oplus-cpulimit.cmdlock}
LOG=${CPULIMIT_LOG:-/data/adb/oplus-cloud-block.log}
DATA=${CPULIMIT_DATA:-/data/adb/oplus-cloud-block-data}
BAK="$DATA/cpu_max_freq.orig"
QCOM_ON="$DATA/qcom.on"
QCOM_TXN="$DATA/qcom.txn"
DAILY_ON="$DATA/daily.on"
DAILY_TXN="$DATA/daily.txn"
DAILY_BAK="$DATA/daily_cpu_max_freq.orig"
DAILY_MTK_BAK="$DATA/daily_mtk.orig"
SMART_PROFILES=${CPULIMIT_SMART_PROFILES:-$MODDIR/smartsched.profiles}
SMART_STATE_FILE=${CPULIMIT_SMART_STATE_FILE:-$DATA/smart.state}
AFF_RULES=${CPULIMIT_AFF_RULES:-$DATA/smartsched.rules}
AFF_TXN="$DATA/affinity.txn"
AFF_TASKSET=${CPULIMIT_TASKSET:-}
AFF_CAPS_KEY=""
AFF_SKIP_KEY=""
AFFINITY_VERIFIED=0

# 出厂兜底值（仅当备份缺失且当前值看起来是"被解除"状态时使用）
FACTORY="0:1900800 1:1900800 2:1900800 3:2323200 4:2323200 5:2323200 6:2323200 7:1843200"
UNLOCK="0:9999999 1:9999999 2:9999999 3:9999999 4:9999999 5:9999999 6:9999999 7:9999999"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CPU上限] $*" >>"$LOG"; }

# 单行 sysfs/proc 写入的统一校验。多值的高通集中节点不能用此函数，
# 因为内核可能按当前温度动态夹取回读值；它由 unlock_freq/restore_freq 单独验证。
write_checked() {
  local file=$1 value=$2 old got
  [ -e "$file" ] || return 1
  old=$(cat "$file" 2>/dev/null) || return 1
  printf '%s' "$value" >"$file" 2>/dev/null || return 1
  got=""; read -r got 2>/dev/null <"$file"
  if [ "$got" != "$value" ]; then
    printf '%s' "$old" >"$file" 2>/dev/null
    return 1
  fi
  return 0
}

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
SMART_ENABLE=0      # 智能调和默认关闭，升级后不改变旧行为
DAILY_PROFILE=auto  # auto = 有已验证日常档位才降顶；off = 始终系统中立
AFFINITY_ENABLE=0   # 只有显式游戏规则时才允许写 TID affinity
DAILY_WAIT=30       # 非性能持续多少秒后才尝试日常档位（代码常量，不在首版 UI 暴露）
# ---- 游戏热预算（默认全关，高通平台；v01.7.75） ----
# 现场证据（PJA110 实测吃鸡 20 分钟）：大核 3187MHz 尾部功耗把 CPU 温区推到 73~76°C，
# GPU 到 67°C 后厂商温控把 GPU 压到 475MHz、亮度落 8 档 —— 掉帧与变暗同源。
# 皮肤 52.5°C 远晚于这一切，按皮肤收回救不了 GPU。思路：把大核尾部热让给 GPU。
GAME_CPU_SWEET=off  # off | hw：游戏时大核钉在硬件原生上限（如 3187→2803），省尾部热
GPU_GUARD=off       # off | 1：GPU 过热保护，达到 GPU_GUARD_TEMP 降大核频率（仅高通 kgsl）
GPU_GUARD_TEMP=60000    # GPU 过热触发线，毫摄氏度。实测降档发生在 67°C，60 留提前量
GPU_GUARD_ACTION=sweet  # sweet=大核落稳健档；neutral=整体降频（更保守）
DISP_GUARD=off      # off | 1：防掉帧变暗（显示温控触发前主动降频）。
                    # 实测 PJA110：显示温度 49°C 触发 gear11 → 屏幕切 60Hz（帧率被 vsync 锁死）
                    # 并落 100nit 限亮档；彼时皮肤温区稳定 52+。本保护用皮肤做触发信号。
DISP_GUARD_TEMP=51500   # 防掉帧触发线。到线整体降频（显示红线不折中、最快降温），
                    # 降到线-HYST 且连续两拍才恢复。模块温区解析成 CPU 结温的机型不启用。
GAME_GPU_CAP=off    # off | kHz：实验性 GPU 上限（须在本机 available_frequencies 里）。
                    # 只降上限、不锁只读、不与温控抢写；厂商压得更低时让它压（保护优先）
SMART_STATE=NEUTRAL
SMART_REASON=initial
SMART_WANT=0
DAILY_SINCE=""
DAILY_CONFLICT=0
DAILY_PLAN=""
DAILY_MTK_PLAN=""
DAILY_DEVICE_KEY=""
DAILY_PROFILE_KEY=""
DAILY_PROFILE_RESULT=1
HOT_CLEAR_N=0
HOT_TH=""
SENSOR_CLEAR_N=0
# GPU 过热保护的运行态（守护内存，重启后按当前温度重判）
GPU_T=""
GPU_HOT_ON=0
GPU_CLEAR_N=0
# 防掉帧保护的运行态（信号 = 模块皮肤温区 T_NOW，零新增读）
DISP_HOT_ON=0
DISP_CLEAR_N=0
SWEET_STR=""
GPU_AVAIL_MAX=""
PERF_VERIFIED=0
DAILY_VERIFIED=0
AFFINITY_VERIFIED=0
LAST_ERROR=""
CTRL_PID=""
CTRL_START=""
APPLIED_CONF_SIG=""

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

# 先做字符串级范围检查，再交给 shell 整数比较，避免超大纯数字溢出后失效开放。
valid_uint_le() {
  local v=$1 max=$2
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  while [ "${v#0}" != "$v" ] && [ "$v" != 0 ]; do v=${v#0}; done
  [ "${#v}" -le 6 ] || return 1
  [ "$v" -le "$max" ] 2>/dev/null || return 1
  VALID_UINT=$v
}
valid_mC() {
  valid_uint_le "$1" 150000 || return 1
  [ "$VALID_UINT" -gt 0 ] || return 1
  VALID_MC=$VALID_UINT
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
      SMART_ENABLE) [ -n "$val" ] && SMART_ENABLE=$val ;;
      DAILY_PROFILE) [ -n "$val" ] && DAILY_PROFILE=$val ;;
      AFFINITY_ENABLE) [ -n "$val" ] && AFFINITY_ENABLE=$val ;;
      GAME_CPU_SWEET) [ -n "$val" ] && GAME_CPU_SWEET=$val ;;
      GPU_GUARD) [ -n "$val" ] && GPU_GUARD=$val ;;
      GPU_GUARD_TEMP) [ -n "$val" ] && GPU_GUARD_TEMP=$val ;;
      GPU_GUARD_ACTION) [ -n "$val" ] && GPU_GUARD_ACTION=$val ;;
      DISP_GUARD) [ -n "$val" ] && DISP_GUARD=$val ;;
      DISP_GUARD_TEMP) [ -n "$val" ] && DISP_GUARD_TEMP=$val ;;
      GAME_GPU_CAP) [ -n "$val" ] && GAME_GPU_CAP=$val ;;
    esac
  done <"$CONF"
  # 非数字、溢出或不合理的值回落默认，避免比较失败后误判为未达阈值。
  valid_mC "$TEMP" && TEMP=$VALID_MC || TEMP=55000
  valid_mC "$TEMP_CPU" && TEMP_CPU=$VALID_MC || TEMP_CPU=80000
  valid_uint_le "$HYST" 150000 && HYST=$VALID_UINT || HYST=3000
  [ "$HYST" -ge "$TEMP" ] && HYST=3000
  [ "$HYST" -ge "$TEMP_CPU" ] && HYST=3000
  # 极低的手写阈值与默认滞回冲突时，阈值本身也回退，保证清除阈值仍为正数。
  [ "$HYST" -ge "$TEMP" ] && TEMP=55000
  [ "$HYST" -ge "$TEMP_CPU" ] && TEMP_CPU=80000
  case "$SMART_ENABLE" in 0|1) ;; *) SMART_ENABLE=0 ;; esac
  case "$AFFINITY_ENABLE" in 0|1) ;; *) AFFINITY_ENABLE=0 ;; esac
  case "$DAILY_PROFILE" in auto|off) ;; *) DAILY_PROFILE=auto ;; esac
  case "$GAME_CPU_SWEET" in off|hw) ;; *) GAME_CPU_SWEET=off ;; esac
  case "$GPU_GUARD" in 1|on) GPU_GUARD=1 ;; *) GPU_GUARD=off ;; esac
  valid_mC "$GPU_GUARD_TEMP" && [ "$VALID_MC" -ge 40000 ] && GPU_GUARD_TEMP=$VALID_MC || GPU_GUARD_TEMP=60000
  case "$GPU_GUARD_ACTION" in sweet|neutral) ;; *) GPU_GUARD_ACTION=sweet ;; esac
  case "$DISP_GUARD" in 1|on) DISP_GUARD=1 ;; *) DISP_GUARD=off ;; esac
  valid_mC "$DISP_GUARD_TEMP" && [ "$VALID_MC" -ge 45000 ] && DISP_GUARD_TEMP=$VALID_MC || DISP_GUARD_TEMP=51500
  case "$GAME_GPU_CAP" in ''|off) GAME_GPU_CAP=off ;; esac
  case "$GAME_GPU_CAP" in *[!0-9]*) GAME_GPU_CAP=off ;; esac
  [ "$GAME_GPU_CAP" -le 100000000 ] 2>/dev/null && GAME_GPU_CAP=off
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
  for c in ${CPU_ROOT}/cpu[0-9]*; do
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
qcom_write_txn() {
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf 'qcom\n' >"$QCOM_TXN.tmp" 2>/dev/null || return 1
  mv -f "$QCOM_TXN.tmp" "$QCOM_TXN" 2>/dev/null
}

unlock_freq() {
  [ -e "$FREQ" ] || return 1
  qcom_write_txn || return 1
  chmod 644 "$FREQ" 2>/dev/null || return 1
  if ! printf '%s' "$UNLOCK" >"$FREQ" 2>/dev/null; then
    chmod 644 "$FREQ" 2>/dev/null
    return 1
  fi
  chmod 444 "$FREQ" 2>/dev/null || return 1
  is_unlocked
}

# 还原 = chmod 644 → 写出厂值 → 保持 644。
# 实测要点：
#   ① 只 chmod 644、不写值 → 节点保持 9999999、c7 仍是 3187200，**不还原**；
#     必须"写一个值"才会触发系统收回上限（写后 c7 从 3187200 掉回 ~2092800）。
#   ② 回读值可能是系统当时的策略值（如 2092800）而非写入的 1843200 —— 这是
#     正常的，节点由系统按温度动态夹取，c7 跟随系统值即为"出厂状态"。
#   ③ 写完保持 644，交还系统/厂商自主管理（不解锁时不应锁只读）。
restore_freq() {
  local rc=0
  chmod 644 "$FREQ" 2>/dev/null || rc=1
  printf '%s' "$(orig_value)" >"$FREQ" 2>/dev/null || rc=1
  chmod 644 "$FREQ" 2>/dev/null || rc=1
  return "$rc"
}

# ---- 游戏场景专用上限（第二层天花板）----
# 一检测到游戏，系统就往 ${GAME_OPT}/cpu_max_freq 写一组"游戏专用"上限
# （实测把大核压到 1843200，随温度还会收紧到 1478400），越过上面的 msm_performance。
# ${GAME_OPT}/disable_cpufreq_limit 是官方开关：写 1 = 禁用该限制。
# 实测写 1 后 game_opt/cpu_max_freq 立即变全 INT_MAX，c7 回到 3187200。
# 注意：不要用 `[ -w ]` 预判（toybox 对 /proc 伪文件可能误判为不可写）——直接写，失败也无害。
GAMEDIS=${GAME_OPT}/disable_cpufreq_limit
GAME_ON="$DATA/game_opt.on"
GAME_PREV="$DATA/game_opt.orig"
enable_game() {
  [ -e "$GAMEDIS" ] || return 1
  local cur=""
  read -r cur 2>/dev/null <"$GAMEDIS"
  case "$cur" in 0|1) ;; *) return 1 ;; esac
  if [ ! -f "$GAME_ON" ]; then
    # 先保存原值并建立所有权，再写入；异常中断也能按原值恢复。
    mkdir -p "$DATA" 2>/dev/null || return 1
    printf '%s' "$cur" >"$GAME_PREV.tmp" 2>/dev/null && mv -f "$GAME_PREV.tmp" "$GAME_PREV" 2>/dev/null || return 1
    : >"$GAME_ON" 2>/dev/null || return 1
  fi
  if ! printf '1' >"$GAMEDIS" 2>/dev/null; then disable_game; return 1; fi
  game_opt_ok || { disable_game; return 1; }
}
disable_game() {
  [ -f "$GAME_ON" ] || return 0
  local orig=""
  [ -f "$GAME_PREV" ] && read -r orig 2>/dev/null <"$GAME_PREV"
  case "$orig" in 0|1) ;; *) orig=0 ;; esac
  [ -e "$GAMEDIS" ] || return 1
  printf '%s' "$orig" >"$GAMEDIS" 2>/dev/null || return 1
  local now=""
  read -r now 2>/dev/null <"$GAMEDIS"
  [ "$now" = "$orig" ] || return 1
  rm -f "$GAME_ON" "$GAME_PREV"
}
game_opt_ok()  { local v=""; read -r v 2>/dev/null <"$GAMEDIS"; [ "$v" = "1" ]; }

# ==== 游戏热预算（高通 kgsl；默认全关） ====
# 三个独立开关（对外统称「游戏热预算」），全部只动"本模块已有所有权"的节点或纯降上限：
#   ① GAME_CPU_SWEET（稳健档）：msm 层写"每核硬件原生上限"而不是 9999999。
#      与完整解锁同一个节点、同一套事务/只读锁，不新增所有权；还原路径不变。
#   ② GPU_GUARD：读 kgsl 温度过热就降大核（皮肤信号太慢，实测降档时皮肤才 52.5°C）。
#   ③ GAME_GPU_CAP：写 kgsl devfreq max_freq。只降上限、不 chmod 锁死 ——
#      厂商温控要压得更低时必须让它压（保护优先），我们只在它放开后重新盖上。
GPU_SYS=${CPULIMIT_GPU_SYS:-/sys/class/kgsl/kgsl-3d0}
GPU_TEMPF=$GPU_SYS/temp
GPU_MAXF=$GPU_SYS/devfreq/max_freq
GPU_AVAIL=$GPU_SYS/devfreq/available_frequencies
GPU_PWL=$GPU_SYS/thermal_pwrlevel
GPU_BAK="$DATA/gpu_max.orig"
GPU_ON="$DATA/gpu.on"
GPU_TXN="$DATA/gpu.txn"

# ---- ① 大核稳健档（内部名 sweet，WebUI 称「稳健档」） ----
# SWEET_STR 形如 "0:2016000 1:2016000 … 7:2803200"（每核 cpuinfo_max_freq）。
# 拓扑读不全时稳健档不可用，调用方回退完整解锁（fail-safe）。
# ★ 不缓存（每次重建，8 次内建 read 零 fork）：实测 PJA110 的 cpuinfo_max_freq
#   是动态的 —— idle 读 3187200、游戏中被 oplus 压到 2803200（game_opt 甚至有
#   fake_cpu7_cpuinfo_max_freq 节点）。缓存会把 idle 值带进游戏，稳健档静默失效。
#   每次重建则游戏期间自然拿到 2803，厂商中途改值也会在下一拍自纠。
sweet_string() {
  local c id hw out=""
  for c in ${CPU_ROOT}/cpu[0-9]*; do
    [ -d "$c" ] || continue
    id=${c##*cpu}
    hw=""; read -r hw 2>/dev/null <"$c/cpufreq/cpuinfo_max_freq"
    case "$hw" in ''|*[!0-9]*) SWEET_STR=""; return 1 ;; esac
    [ "$hw" -gt 0 ] || { SWEET_STR=""; return 1; }
    out="$out${out:+ }$id:$hw"
  done
  [ -n "$out" ] || { SWEET_STR=""; return 1; }
  SWEET_STR=$out
  return 0
}

sweet_on() {
  # 注意：printf '%s' 写入无尾换行，read 在 EOF 无换行时返回非零但变量已赋值
  #（模块既有 write_checked 同样忽略 read 返回码），不能用 || return 判断。
  [ -n "$SWEET_STR" ] || return 1
  local v=""
  read -r v 2>/dev/null <"$FREQ"
  [ "$v" = "$SWEET_STR" ]
}

unlock_sweet() {
  [ -e "$FREQ" ] || return 1
  sweet_string || return 1
  qcom_write_txn || return 1
  chmod 644 "$FREQ" 2>/dev/null || return 1
  if ! printf '%s' "$SWEET_STR" >"$FREQ" 2>/dev/null; then
    chmod 644 "$FREQ" 2>/dev/null
    return 1
  fi
  chmod 444 "$FREQ" 2>/dev/null || return 1
  sweet_on
}

# ---- ② GPU 过热保护 ----
# 读毫摄氏度放 GPU_T；读不到给空（kgsl 不存在/天玑 → 保护不生效，如实静默）。
read_gpu_temp() {
  GPU_T=""
  read -r GPU_T 2>/dev/null <"$GPU_TEMPF"
  valid_mC "$GPU_T" && GPU_T=$VALID_MC || GPU_T=""
}

# 滞回与 HOT 同理念：降频后要降到 GPU_GUARD_TEMP-HYST 以下、连续两拍才恢复。
# 返回 0 = 降频中。守护每 5s 一拍，纯内建 read，无 fork。
update_gpu_hot() {
  if [ "$GPU_GUARD" != 1 ]; then GPU_HOT_ON=0; GPU_CLEAR_N=0; return 1; fi
  [ -n "$GPU_T" ] || return 1
  if [ "$GPU_HOT_ON" = 1 ]; then
    if [ "$GPU_T" -lt $((GPU_GUARD_TEMP - HYST)) ]; then
      GPU_CLEAR_N=$((GPU_CLEAR_N + 1))
      if [ "$GPU_CLEAR_N" -ge 2 ]; then
        GPU_HOT_ON=0; GPU_CLEAR_N=0
        log "GPU ${GPU_T} 低于 $((GPU_GUARD_TEMP - HYST))，GPU 过热保护解除，恢复性能状态"
        return 1
      fi
    else
      GPU_CLEAR_N=0
    fi
    return 0
  fi
  if [ "$GPU_T" -ge "$GPU_GUARD_TEMP" ]; then
    GPU_HOT_ON=1; GPU_CLEAR_N=0
    log "GPU ${GPU_T} 过热（${GPU_GUARD_TEMP}），大核降频"
    return 0
  fi
  return 1
}

# ---- ②b 防掉帧变暗（显示温控触发线） ----
# 信号 = 模块皮肤温区（T_NOW，每拍已读，零新增 fork）。为什么要显示保护：
# 显示温控的 gear 表在显示温度 49°C 落 gear11 → 屏幕切 60Hz（vsync 锁死游戏帧率）
# + 100nit 限亮，实测"第二局掉帧+变暗"的直接执行者。显示传感器走 HAL 不可 fork-free
# 读取，但实测 60Hz 卡窗口期间皮肤稳定 52+（前壳会跌回 47，咬不住）——皮肤是可靠信号。
# 只在模块温区级别是皮肤（ZONE_T=skin）时生效；解析成 CPU 结温的机型如实不启用。
update_disp_hot() {
  if [ "$DISP_GUARD" != 1 ]; then DISP_HOT_ON=0; DISP_CLEAR_N=0; return 1; fi
  [ -n "$T_NOW" ] && [ "$ZONE_T" = skin ] || return 1
  if [ "$DISP_HOT_ON" = 1 ]; then
    if [ "$T_NOW" -lt $((DISP_GUARD_TEMP - HYST)) ]; then
      DISP_CLEAR_N=$((DISP_CLEAR_N + 1))
      if [ "$DISP_CLEAR_N" -ge 2 ]; then
        DISP_HOT_ON=0; DISP_CLEAR_N=0
        log "机身 ${T_NOW} 低于 $((DISP_GUARD_TEMP - HYST))，防掉帧保护解除，恢复性能状态"
        return 1
      fi
    else
      DISP_CLEAR_N=0
    fi
    return 0
  fi
  if [ "$T_NOW" -ge "$DISP_GUARD_TEMP" ]; then
    DISP_HOT_ON=1; DISP_CLEAR_N=0
    log "机身 ${T_NOW} 达到防掉帧触发线 ${DISP_GUARD_TEMP}，整体降频加速降温"
    return 0
  fi
  return 1
}

# ---- ③ GPU 实验上限 ----
gpu_cap_wanted() { case "$GAME_GPU_CAP" in ''|off) return 1 ;; esac; return 0; }

# 可用档列表里的最高档 = 本机出厂 GPU 上限（还原兜底用）
gpu_avail_max() {
  GPU_AVAIL_MAX=""
  local f v m=""
  read -r f 2>/dev/null <"$GPU_AVAIL" || return 1
  for v in $f; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$m" ] || [ "$v" -gt "$m" ]; then m=$v; fi
  done
  [ -n "$m" ] || return 1
  GPU_AVAIL_MAX=$m
}

# 写入规则（只降不升、不锁只读、不跟温控抢）：
#   当前值 < 目标档 → 厂商温控正压着，让行不动（0 = 不视为失败）
#   当前值 = 目标档 → 已在位
#   当前值 > 目标档 → 写入并回读；回读不符 → 撤事务如实报错，绝不硬顶
gpu_apply_cap() {
  gpu_cap_wanted || return 0
  [ -e "$GPU_MAXF" ] || return 1
  local f="" cur=""
  read -r f 2>/dev/null <"$GPU_AVAIL"
  case " $f " in *" $GAME_GPU_CAP "*) ;; *)
    smart_fail "GPU 档 $GAME_GPU_CAP 不在本机可用档列表，拒绝写入"
    return 1 ;; esac
  read -r cur 2>/dev/null <"$GPU_MAXF"
  case "$cur" in ''|*[!0-9]*) cur="" ;; esac
  [ "$cur" = "$GAME_GPU_CAP" ] && return 0
  if [ -n "$cur" ] && [ "$cur" -lt "$GAME_GPU_CAP" ]; then return 0; fi
  if [ ! -s "$GPU_BAK" ]; then
    local orig=$cur
    [ -n "$orig" ] || { gpu_avail_max && orig=$GPU_AVAIL_MAX; }
    case "$orig" in ''|*[!0-9]*) orig="" ;; esac
    if [ -n "$orig" ] && [ "$orig" -gt "$GAME_GPU_CAP" ]; then
      mkdir -p "$DATA" 2>/dev/null
      printf '%s' "$orig" >"$GPU_BAK" 2>/dev/null
    fi
  fi
  mkdir -p "$DATA" 2>/dev/null
  printf 'gpu\n' >"$GPU_TXN.tmp" 2>/dev/null && mv -f "$GPU_TXN.tmp" "$GPU_TXN" 2>/dev/null
  if ! printf '%s' "$GAME_GPU_CAP" >"$GPU_MAXF" 2>/dev/null; then
    rm -f "$GPU_TXN" 2>/dev/null
    return 1
  fi
  local got=""
  read -r got 2>/dev/null <"$GPU_MAXF"
  if [ "$got" != "$GAME_GPU_CAP" ]; then
    rm -f "$GPU_TXN" 2>/dev/null
    smart_fail "GPU 上限写入未生效（回读 ${got:-空}），本机不支持该实验"
    return 1
  fi
  : >"$GPU_ON" 2>/dev/null
  return 0
}

# 还原：只在"当前值仍是我们写的目标档"时写回出厂上限；
# 厂商温控压得更低时留给它自己恢复（写回高值会对抗保护）。
gpu_restore_cap() {
  local cur="" bak=""
  if [ -f "$GPU_TXN" ] && [ ! -f "$GPU_ON" ]; then rm -f "$GPU_TXN"; fi
  [ -f "$GPU_ON" ] || return 0
  read -r cur 2>/dev/null <"$GPU_MAXF"
  case "$cur" in ''|*[!0-9]*) cur="" ;; esac
  [ -s "$GPU_BAK" ] && { read -r bak 2>/dev/null <"$GPU_BAK"; }
  case "$bak" in ''|*[!0-9]*) bak="" ;; esac
  [ -n "$bak" ] || { gpu_avail_max && bak=$GPU_AVAIL_MAX; }
  if [ -n "$cur" ] && [ -n "$bak" ] && [ "$cur" = "$GAME_GPU_CAP" ]; then
    printf '%s' "$bak" >"$GPU_MAXF" 2>/dev/null
  fi
  rm -f "$GPU_ON" "$GPU_TXN"
  return 0
}

# ==== 天玑（联发科）分支 ====
# 天玑没有 msm_performance 节点，出厂/厂商把频率钉在本机 policy 上：
#   scaling_min_freq == scaling_max_freq == cur_freq，governor=powersave。
#   从用户机上实测到的值看，它是**直接被钉死**的，不是温控收紧：
#   实测 PLC110 三簇分别钉在 1200000 / 1000000 / 800000，都远低于 hw_max；
#   游戏阈值（thermal 54°C）和 thermal_message.sconfig 都没动。
# 本模块只做「可逆地解钉」：把 min/max 放开到硬件上限、governor 换回 schedutil，
# 并备份原值；还原时写回原值。**不碰任何厂商温控/调度服务**（不 stop oplus_thermal、
# 不动 fpsgo / gbe / core_ctl）—— 唯一的保护仍是本模块按温度收回。
#
# ★ 与高通的差别，以及为什么天玑的"下限"必须算清楚：
#   天玑没有 msm_performance 那种集中式上限节点（也就没有 chmod 444 锁只读这一手），
#   各 policy 的 min/max 就是全部战场。所以：
#     ① 下限取该簇**最低可用频率**而不是硬件上限 —— 写 hw_max 等于"永远满频"，
#        失去 DVFS，静置也烫；我们要的是「恢复正常调频范围」。
#     ② governor 必须换掉 powersave（它会把频率死死压在 scaling_min_freq 上），
#        且必须确认本机存在可用 governor（见 mtk_can_unpin），否则宁可不做。
#     ③ 厂商若把 policy 写回去，下一个 tick 会再写一次（与高通路径同样处理）；
#        差别是天玑没有只读锁，能不能长期压住取决于厂商服务的重写频率。

# 优先使用的 governor（按此顺序挑本机可用的第一个）。
# ★ 不选 powersave：它会把频率死死压在 scaling_min_freq 上，等于换个法子钉死。
MTK_GOV_PREF="schedutil ondemand interactive conservative"

# 本机能不能把天玑从 pinned 状态解开。
# 判据：至少有一个 policy 的可用 governor 里存在 MTK_GOV_PREF 之一，且 hardware
# 上限可读。**必须有可换的 governor** —— 否则把 min 放开后 powersave 仍会
# 把频率压在最低档上，比原厂钉在 1200000 还慢，是负优化。
mtk_pick_gov() { # $1 = policy 号；输出可用的首选 governor（无则空）
  local avail g
  avail=$(mtk_read "$1" scaling_available_governors)
  [ -n "$avail" ] || return 1
  for g in $MTK_GOV_PREF; do
    case " $avail " in *" $g "*) printf '%s' "$g"; return 0 ;; esac
  done
  return 1
}
mtk_can_unpin() {
  local k
  for k in $(mtk_policies); do
    mtk_manageable "$k" && return 0
  done
  return 1
}
# 这个 policy 能不能安全解开。**没有可用 governor 或最低 OPP 的簇一律不碰**：
# 实测有些内核给部分簇只留 powersave，那种情况下写大 max、放开 min 之后
# powersave 会把频率钉在 min 上（比原厂更低），是负优化。
mtk_manageable() {
  mtk_pick_gov "$1" >/dev/null 2>&1 || return 1
  mtk_min_freq "$1" >/dev/null 2>&1
}

mtk_policies() { # 输出 policyN 列表（按编号）
  local p
  for p in ${CPU_ROOT}/cpufreq/policy*; do
    [ -f "$p/scaling_max_freq" ] && printf '%s\n' "${p##*/policy}"
  done
}
# 读某 policy 的某个值到 stdout
mtk_read() { local v=""; read -r v 2>/dev/null <"${CPU_ROOT}/cpufreq/policy$1/$2"; printf '%s' "$v"; }

# 取该 policy 真正的最低 OPP。可用频率列表不保证排序，不能把第一项当最低值；
# 列表和 cpuinfo_min_freq 都不可用时返回失败，绝不回退到硬件最高频。
mtk_min_freq() {
  local k=$1 f lo="" hw
  hw=$(mtk_read "$k" cpuinfo_max_freq)
  for f in $(mtk_read "$k" scaling_available_frequencies); do
    case "$f" in ''|*[!0-9]*) continue ;; esac
    [ "$f" -gt 0 ] 2>/dev/null || continue
    if [ -z "$lo" ] || [ "$f" -lt "$lo" ]; then lo=$f; fi
  done
  if [ -z "$lo" ]; then
    lo=$(mtk_read "$k" cpuinfo_min_freq)
  fi
  case "$lo" in ''|*[!0-9]*) return 1 ;; esac
  [ "$lo" -gt 0 ] 2>/dev/null || return 1
  case "$hw" in ''|*[!0-9]*) return 1 ;; esac
  [ "$lo" -le "$hw" ] 2>/dev/null || return 1
  printf '%s' "$lo"
}

# 备份：原采样存成 "$MTK_BAK" 的每行 "pN hw min max gov"
MTK_BAK="$DATA/mtk_freq.orig"
# 标记本模块此刻"已把天玑频率解开"。用它而不是"看起来已解开"来驱动还原，
# 避免在本来就没被钉住的机型上每 5 秒无意义地重复写一遍同样的值。
MTK_ON="$DATA/mtk.on"
MTK_TXN="$DATA/mtk.txn"
# "已被厂商改回"只提示一次，避免每拍刷日志
MTK_REP="$DATA/mtk.repinned"
mtk_backup() {
  [ -s "$MTK_BAK" ] && return 0
  local k hw mn mx gv out=""
  for k in $(mtk_policies); do
    hw=$(mtk_read "$k" cpuinfo_max_freq); mn=$(mtk_read "$k" scaling_min_freq)
    mx=$(mtk_read "$k" scaling_max_freq); gv=$(mtk_read "$k" scaling_governor)
    case "$hw" in ''|*[!0-9]*) continue ;; esac
    out="$out$k $hw $mn $mx $gv
"
  done
  [ -n "$out" ] || return 1
  mkdir -p "$DATA" 2>/dev/null
  printf '%s' "$out" >"$MTK_BAK" 2>/dev/null && log "已备份天玑原厂频率表 -> $MTK_BAK"
}
mtk_write_txn() {
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf 'mtk\n' >"$MTK_TXN.tmp" 2>/dev/null || return 1
  mv -f "$MTK_TXN.tmp" "$MTK_TXN" 2>/dev/null
}
# 该 policy 当前是否已被本模块解开（上限顶到硬件上限、governor 已非 powersave）。
# 不看下限：解开后下限是"最低可用频率"，本来就该远低于上限。
mtk_unlocked_one() { # $1 = policy 号
  local hw mn mx gv lo want
  hw=$(mtk_read "$1" cpuinfo_max_freq)
  mn=$(mtk_read "$1" scaling_min_freq)
  mx=$(mtk_read "$1" scaling_max_freq); gv=$(mtk_read "$1" scaling_governor)
  case "$hw$mn$mx" in ''|*[!0-9]*) return 1 ;; esac
  [ "$mx" = "$hw" ] || return 1
  lo=$(mtk_min_freq "$1") || return 1
  [ "$mn" = "$lo" ] || return 1
  want=$(mtk_pick_gov "$1") || return 1
  [ "$gv" = "$want" ] || return 1
  return 0
}
# 厂商/系统有没有把频率又改回钉死状态（用于"已解开过但被改回"的提示）。
# 同样只看能管的簇：不管的簇本来就是钉死的，不能拿它当"被改回"。
mtk_repinned() {
  local k mx hw
  for k in $(mtk_policies); do
    mtk_manageable "$k" || continue
    hw=$(mtk_read "$k" cpuinfo_max_freq); mx=$(mtk_read "$k" scaling_max_freq)
    case "$hw$mx" in ''|*[!0-9]*) continue ;; esac
    [ "$mx" -lt "$hw" ] 2>/dev/null && return 0
  done
  return 1
}
# 全机是否都已解开。只看**本模块能管**的簇（没有可用 governor 的簇不参与判定，
# 否则它永远"未解开"，会让守护每次 tick 都重写一遍、也会让状态永远显示待命）。
mtk_unlocked() {
  local k ok=1 n=0
  for k in $(mtk_policies); do
    mtk_manageable "$k" || continue
    n=$((n+1))
    mtk_unlocked_one "$k" || { ok=0; break; }
  done
  [ "$n" -gt 0 ] && [ "$ok" = 1 ]
}
mtk_unlock() {
  mtk_backup || return 1
  mtk_write_txn || return 1
  local k hw lo gv ok=0 failed=0
  for k in $(mtk_policies); do
    mtk_manageable "$k" || continue
    hw=$(mtk_read "$k" cpuinfo_max_freq)
    case "$hw" in ''|*[!0-9]*) continue ;; esac
    # ★ 下限不能也设成 hw_max：那等于"永远满频"，失去 DVFS，静置也烫。
    #   要的是「解除钉死、恢复正常调频范围」：下限取该簇最低可用频率。
    #   powersave governor 会强制跑在 scaling_min_freq 上，所以下限尤其重要。
    lo=$(mtk_min_freq "$k") || {
      log "跳过天玑 policy$k：没有可信的最低频率，不写入"
      continue
    }
    gv=$(mtk_pick_gov "$k") || continue
    # 顺序：先把范围放宽（max 抬高、min 压低），再换 governor。
    # 若先换 governor 再收 min，中间会出现 min>max 的非法区间被内核拒绝。
    if ! write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_max_freq" "$hw" \
      || ! write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_min_freq" "$lo" \
      || ! write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_governor" "$gv" \
      || ! mtk_unlocked_one "$k"; then
      failed=1
      log "天玑 policy$k 写入或回读失败，回滚本次解锁"
      break
    fi
    ok=1
  done
  if [ "$failed" = 1 ]; then
    mtk_restore
    [ "$?" = 0 ] && rm -f "$MTK_TXN"
    return 1
  fi
  [ "$ok" = 1 ]
}
mtk_restore() {
  [ -s "$MTK_BAK" ] || return 0
  local k hw mn mx gv rc=0
  while IFS=' ' read -r k hw mn mx gv; do
    [ -n "$k" ] || continue
    [ -d "${CPU_ROOT}/cpufreq/policy$k" ] || continue
    # 还原顺序：先换回 governor，再写 max，最后写 min。
    if [ -n "$gv" ]; then
      write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_governor" "$gv" || rc=1
    fi
    case "$mx" in ''|*[!0-9]*) ;; *) write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_max_freq" "$mx" || rc=1 ;; esac
    case "$mn" in ''|*[!0-9]*) ;; *) write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_min_freq" "$mn" || rc=1 ;; esac
  done <"$MTK_BAK"
  return "$rc"
}

# ---- 平台无关的「解锁 / 还原 / 是否已解锁」调度 ----
do_unlock()  { case "$PLATFORM" in mtk) mtk_unlock ;; *) unlock_freq ;; esac; }
do_restore() {
  local rc=0
  case "$PLATFORM" in
    mtk) mtk_restore; rc=$?; [ "$rc" = 0 ] && rm -f "$MTK_TXN" ;;
    *) restore_freq; rc=$?; [ "$rc" = 0 ] && rm -f "$QCOM_TXN" ;;
  esac
  return "$rc"
}

# 恢复性能资源和日常资源都从这里进入。affinity/daily 函数在相应功能加载后存在，
# 用 type 守卫生成旧配置或只 source 安全函数时也能执行。
restore_performance() {
  local rc=0
  if type restore_task_affinity >/dev/null 2>&1; then
    restore_task_affinity || rc=1
  fi
  case "$PLATFORM" in
    mtk)
      if [ -f "$MTK_ON" ] || [ -f "$MTK_TXN" ]; then
        mtk_restore || rc=1
        [ "$rc" = 0 ] && rm -f "$MTK_ON" "$MTK_TXN" "$MTK_REP"
      fi ;;
    *)
      if [ -f "$QCOM_ON" ] || [ -f "$QCOM_TXN" ]; then
        restore_freq || rc=1
        [ "$rc" = 0 ] && rm -f "$QCOM_ON" "$QCOM_TXN"
      fi ;;
  esac
  if [ -f "$GAME_ON" ]; then disable_game || rc=1; fi
  gpu_restore_cap || rc=1
  return "$rc"
}

restore_all_owned() {
  local rc=0
  if type restore_daily >/dev/null 2>&1; then restore_daily || rc=1; fi
  restore_performance || rc=1
  return "$rc"
}

# 本模块这层是否在位。高通看集中节点（完整解锁或稳健档都算在位）、天玑看各 policy。
# 注意：这 != "实际已满频"，仍要给用户看 CAPPED。
layer_on() {
  case "$PLATFORM" in
    mtk) mtk_unlocked ;;
    *) sweet_string; is_unlocked && node_readonly || { sweet_on && node_readonly; } ;;
  esac
}

# 只读锁是否在位（用权限位字符串判断，不依赖 -w —— root 下 -w 不可靠）
node_readonly() {
  case "$(ls -l "$FREQ" 2>/dev/null)" in
    -r--r--r--*) return 0 ;;
    *) return 1 ;;
  esac
}

is_unlocked() {
  local v ids id pair found
  v=$(sed 's/[[:space:]]*$//' "$FREQ" 2>/dev/null)
  ids=$(qcom_cpu_ids)
  # 没有可枚举 CPU 的旧环境保留兼容；有拓扑时必须每个 CPU 都是解锁值。
  if [ -z "$ids" ]; then
    case "$v" in *9999999*) return 0 ;; *) return 1 ;; esac
  fi
  for id in $ids; do
    found=0
    for pair in $v; do
      [ "${pair%%:*}" = "$id" ] || continue
      [ "${pair#*:}" = 9999999 ] || return 1
      found=1
    done
    [ "$found" = 1 ] || return 1
  done
  return 0
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
  for p in ${CPU_ROOT}/cpufreq/policy*; do
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
    for p in ${CPU_ROOT}/cpufreq/policy*; do
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

# 中核/大核的（最低）上限低于硬件上限吗。写入 CAPPED / CAP_INFO / CAP_FREQ。
# 小核不参与警告：PJA110 的 OMRG 会常态化限制小核，用户只关心游戏相关的中大核。
# CAP_FREQ 仍保留全部簇供诊断；只有多簇且最低频簇明确更小时才忽略它。
compute_capped() {
  CAPPED=0; CAP_INFO=""; CAP_FREQ=""
  local k hw v pct little little_hw max_hw count
  little=""; little_hw=""; max_hw=0; count=0
  for k in $CAP_KEYS; do
    hw=${k#*:}; k=${k%%:*}
    case "$hw" in ''|*[!0-9]*) continue ;; esac
    [ "$hw" -gt 0 ] || continue
    count=$((count + 1))
    if [ -z "$little_hw" ] || [ "$hw" -lt "$little_hw" ]; then little=$k; little_hw=$hw; fi
    [ "$hw" -le "$max_hw" ] || max_hw=$hw
  done
  if [ "$count" -le 1 ] || [ "$little_hw" -ge "$max_hw" ]; then little=""; fi
  for k in $(printf '%s\n' "$CAP_MIN" | awk '{print $1}' | sort -n); do
    hw=$(printf '%s\n' "$CAP_KEYS" | tr ' ' '\n' | sed -n "s/^$k://p")
    v=$(printf '%s\n' "$CAP_MIN" | sed -n "s/^$k //p")
    case "$hw$v" in ''|*[!0-9]*) continue ;; esac
    [ "$hw" -gt 0 ] || continue
    pct=$(awk -v a="$v" -v b="$hw" 'BEGIN{printf "%d%%", a*100/b}')
    CAP_FREQ="$CAP_FREQ $k:$v/$hw($pct)"
    [ "$v" -lt "$hw" ] || continue
    [ -n "$little" ] && [ "$k" = "$little" ] && continue
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
  for z in ${THERMAL_ROOT}/thermal_zone*; do
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

# 把配置里的 ZONE 归一化成「首选按名字查的温区名」，结果放 ZRESOLVE。
#   auto / 空            → skin-msm-therm（WebUI「自动(推荐)」的语义）
#   shell_front/back     → skin-msm-therm（旧版 WebUI 写的无效值；conf 注释里也写明
#                          「不要用手动选 shell_*，实测形同虚设」。WebUI 只在界面上把它
#                          迁成「自动」，conf 里的旧值会一直留着，所以这里必须一起兜住）
#   其他（含具体温区名） → 原样返回，交给 find_zone 按名字查
# gamerec.sh 用同一套规则（见那边的同名函数），两边才能保证选到同一个温区。
ZRESOLVE=""
zone_normalize() {
  case "$1" in
    ''|auto|shell_front|shell_back|shell_frame) ZRESOLVE=skin-msm-therm ;;
    *) ZRESOLVE=$1 ;;
  esac
}

# 在候选族里挑「读数最高」的温区。$1 = 判定函数名（is_cpu_zone / is_skin_zone）。
# 结果放 PZ_NUM / PZ_NAME / PZ_VAL；没有可用候选时返回 1。
#
# ★ 为什么不是「第一个命中的」—— 天玑 PLC110 实测（2026-11-07 诊断报告，内核 5.10.236）：
#   cpu 族共 14 个候选，soc_max 编号最小(z0)排第一，被"第一个"选中；
#   但它与 cpu_little1-4 / cpu_big1-6 / cpu_bigbig1-2 一起**13 个全部读 34000 恒定**
#   （驱动实例在、但没接数据），而真正有效的 soc_top(z19)=52597 永远轮不到。
#   后果：阈值 TEMP_CPU=80°C 面对 34°C 读数，要涨 46°C 才触发 → 保护形同虚设。
#   死值一律偏低（34k/33k/31k），真实结温 46~54k，所以「取最高」是稳的方向。
#
# ★ 为什么不用「短窗口采样看谁在动」：热质量大，正确温区短窗口也读不出变化。
#   实测 PJA110 上 skin-msm-therm（公认正确，游戏时确实涨到 55°C）
#   在 0.6 秒内三次读数完全一致 → 采样法会把它误判成死值。这条路已被实测否决。
pick_zone_hottest() {
  PZ_NUM=""; PZ_NAME=""; PZ_VAL=""
  local z zt2 tv best=""
  for z in ${THERMAL_ROOT}/thermal_zone*; do
    zt2=""; read -r zt2 2>/dev/null <"$z/type"
    [ -n "$zt2" ] || continue
    "$1" "$zt2" || continue
    tv=""; read -r tv 2>/dev/null <"$z/temp"
    # 剔除「不是温度」的读数：<=0、门限值以及超出 shell 整数范围的纯数字。
    valid_mC "$tv" || continue
    tv=$VALID_MC
    if [ -z "$best" ] || [ "$tv" -gt "$best" ]; then
      best=$tv; PZ_NUM=${z##*thermal_zone}; PZ_NAME=$zt2; PZ_VAL=$tv
    fi
  done
  [ -n "$PZ_NUM" ]
}

ZONE_NAME_C=""; ZONE_NUM_C=""; ZONE_USED=""; ZONE_T=""; T_NOW=""
read_temp() {
  local zt="" z zt2 zp
  [ -n "$ZONE_NUM_C" ] && read -r zt 2>/dev/null <"${THERMAL_ROOT}/thermal_zone$ZONE_NUM_C/type"
  if [ "$ZONE_NAME_C" != "$ZONE" ] || [ "$zt" != "$ZONE_USED" ]; then
    ZONE_NAME_C=$ZONE; ZONE_USED=""; ZONE_NUM_C=""
    # ① 用户配置的温区（按名字精确找），旧值/自动先归一化。
    #    注意只改本地变量 zp，不动 ZONE 本身 —— 状态里仍显示原值（如 ZONE=auto），
    #    否则 WebUI 读回会把「自动」标签误显示成「指定机身」。
    zone_normalize "$ZONE"; zp=$ZRESOLVE
    ZONE_NUM_C=$(find_zone "$zp")
    # 配置的温区本机没有 → 按「自动」处理（再试 skin-msm-therm）。
    # 少了这一步，配一个不存在的名字时这里会直接落到 ②（CPU 族优先），
    # 而 gamerec 固定 skin-msm-therm 优先 → 两边岔开。
    if [ -z "$ZONE_NUM_C" ] && [ "$zp" != skin-msm-therm ]; then
      zp=skin-msm-therm
      ZONE_NUM_C=$(find_zone "$zp")
    fi
    [ -n "$ZONE_NUM_C" ] && ZONE_USED=$zp
    # ② 扫全表替补：CPU 结温家族优先（取最高读数），其次机身/外壳家族。
    #    顺序必须与 gamerec.sh 的 pick_zone 完全一致。
    if [ -z "$ZONE_NUM_C" ]; then
      if pick_zone_hottest is_cpu_zone; then
        ZONE_NUM_C=$PZ_NUM; ZONE_USED=$PZ_NAME
      elif pick_zone_hottest is_skin_zone; then
        ZONE_NUM_C=$PZ_NUM; ZONE_USED=$PZ_NAME
      fi
    fi
    zone_class "$ZONE_USED"
  fi
  T_NOW=""
  [ -n "$ZONE_NUM_C" ] && read -r T_NOW 2>/dev/null <"${THERMAL_ROOT}/thermal_zone$ZONE_NUM_C/temp"
  if valid_mC "$T_NOW"; then T_NOW=$VALID_MC; else T_NOW=""; fi
}

# 温区属于哪一级 → 该用哪个阈值。结果放 ZONE_T（skin / cpu）。
zone_class() {
  if is_cpu_zone "$1"; then ZONE_T=cpu; else ZONE_T=skin; fi
}

# 给诊断/status 用：列出候选温区及读数，并标出实际选中的那个。
# 形如 "选中=z19:soc_top=52597 | 候选 z0:soc_max=34000 z19:soc_top=52597 ..."
zone_pick_note() {
  local z zt2 tv out="" n
  for z in ${THERMAL_ROOT}/thermal_zone*; do
    zt2=""; read -r zt2 2>/dev/null <"$z/type"
    [ -n "$zt2" ] || continue
    is_cpu_zone "$zt2" || is_skin_zone "$zt2" || continue
    tv=""; read -r tv 2>/dev/null <"$z/temp"
    n=${z##*thermal_zone}
    if [ "$n" = "$ZONE_NUM_C" ]; then
      printf '%s[选中 z%s:%s=%s]' "$out" "$n" "$zt2" "$tv"
    else
      printf '%s z%s:%s=%s' "$out" "$n" "$zt2" "$tv"
    fi
    out=" |"
  done
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
  [ -n "$zn" ] && read -r tv 2>/dev/null <"${THERMAL_ROOT}/thermal_zone$zn/temp"
  printf '%s' "$tv"
}

# ---- 过热滞回 ----
# 超过 TEMP 收回后打标记，必须降到 TEMP-HYST 以下才清标记、允许再解锁，
# 避免温度在阈值附近时每 5s 来回切换。标记只在状态切换时写，不会频繁写闪存。
HOT_FLAG=${CPULIMIT_HOT_FLAG:-/data/adb/oplus-cpulimit.hot}
is_hot() { [ -f "$HOT_FLAG" ]; }
# 根据 T_NOW 更新标记；返回 0 = 处于过热保护中。
# 阈值用 EFF_TEMP（由应该解锁判定算好：温区级别的基础阈值 + 前台游戏的单独阈值）。
update_hot() {
  local th=${HOT_TH:-${EFF_TEMP:-${TEMP:-55000}}}
  if is_hot; then
    if [ "$T_NOW" -lt $((th - HYST)) ] 2>/dev/null; then
      HOT_CLEAR_N=$((HOT_CLEAR_N + 1))
      # 智能模式要求连续两次低温；旧模式保留原来的单次清除行为。
      if [ "$SMART_ENABLE" != 1 ] || [ "$HOT_CLEAR_N" -ge 2 ]; then
        rm -f "$HOT_FLAG"
        HOT_TH=""
        HOT_CLEAR_N=0
        log "$ZONE_USED 降到 ${T_NOW}，低于 $((th - HYST))，解除过热保护"
        return 1
      fi
    else
      HOT_CLEAR_N=0
    fi
    return 0
  fi
  HOT_CLEAR_N=0
  HOT_TH=""
  th=${EFF_TEMP:-${TEMP:-55000}}
  if [ "$T_NOW" -ge "$th" ] 2>/dev/null; then
    HOT_TH=$th
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
GAME_LIST_CACHE=${CPULIMIT_GAME_LIST_CACHE:-/data/adb/oplus-cpulimit.games}
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
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"${PROC_ROOT}/$g/cmdline"; nm=${nm%%:*}
    [ -n "$nm" ] && { GAME_FG=$nm; return 0; }
  fi
  [ -r "$TOP_PROCS" ] || return 1
  [ -f "$GAME_LIST_CACHE" ] || build_game_list
  local games="" l pid
  while read -r l; do [ -n "$l" ] && games="$games$NL$l"; done 2>/dev/null <"$GAME_LIST_CACHE"
  [ -n "$games" ] || return 1
  while read -r pid; do
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"${PROC_ROOT}/$pid/cmdline"; nm=${nm%%:*}
    case "$nm" in *.*) ;; *) continue ;; esac
    case "$games$NL" in *"$NL$nm$NL"*) GAME_FG=$nm; return 0 ;; esac
  done <"$TOP_PROCS"
  return 1
}

# 守护用：带宽限的前台判定。短暂切出去（回个微信、下拉通知栏）GAME_GRACE 秒内
# 仍按游戏在前台处理，避免满频来回切换。GAME_SEEN 只在守护进程内存里，WebUI 查询不带宽限。
GAME_GRACE=15
GAME_SEEN=""; GAME_LAST=""
up_s() { local u=""; read -r u _ 2>/dev/null <"${PROC_ROOT}/uptime"; UP=${u%%.*}; }
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
  local k v nv
  while IFS='=' read -r k v; do
    [ "$k" = "$1" ] || continue
    v=${v%"$CR"}
    case "$v" in ''|*[!0-9-]*) return 0 ;; esac
    case "$v" in
      -*) nv=${v#-}; valid_uint_le "$nv" 20000 || return 0; v=-$VALID_UINT ;;
      *) valid_uint_le "$v" 150000 || return 0; v=$VALID_UINT ;;
    esac
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
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"${PROC_ROOT}/$pid/cmdline"
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
  # 每游戏负偏移也不能把过热清除阈值压到零或负数。
  [ "$EFF_TEMP" -le "$HYST" ] && EFF_TEMP=$((HYST + 1))
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
  # 本模块这层是否在位（节点=解锁值），以及中核/大核是否顶到硬件上限。
  # 两者要分开说：节点在位 ≠ 中大核满频；小核限制不再触发额外警告。
  # 天玑没有集中节点，layer_on 会逐 policy 判断；高通仍看节点+只读锁。
  local unl="否"; layer_on && unl="是"
  # 天玑特有的第三种情况：本模块写过（有 mtk.on 标记），但厂商服务又把上限改回去了。
  # 这时既不是"未解开"也不是"被别的链路压"，要单独说，否则用户以为模块没生效。
  local mtk_lost=0
  if [ "$PLATFORM" = mtk ] && [ -f "$MTK_ON" ] && mtk_repinned; then mtk_lost=1; fi
  # 复用 status 已经采过的那份（CAP_FREQ 非空即为已采样），避免一次 status 采两遍、
  # 两次结果还可能不一样（别的链路在翻转），导致同屏数据自相矛盾。
  [ -n "$CAP_FREQ" ] || { sample_caps; compute_capped; }
  local cap=$CAP_INFO full="否"; [ "$CAPPED" = 0 ] && full="是"

  # ★ 本模式下现在是否「应该」满频。不满足时频率被压是设计如此
  #（如「仅游戏」模式没开游戏，节点本来就被还原成出厂值），
  # 不能报「被压」—— 否则用户一打开 WebUI（游戏必然不在前台）就看到
  # 「待命（本层未解除），且实际频率被压」，自相矛盾还以为模块坏了。
  local want=1 cur=""
  case "$MODE" in
    game) [ -n "$GAME_FG" ] || want=0 ;;
    apps) cur=$(top_pkg)
          if [ -z "$cur" ] || ! app_selected "$cur"; then want=0; fi ;;
  esac

  if [ "$t" -ge "$EFF_TEMP" ] 2>/dev/null; then
    echo "$wn $(mC "$t") 已超阈值 $(mC "$EFF_TEMP")，已收回保护"; return
  fi
  if is_hot; then
    echo "过热保护中 · $wn $(mC "$t")，降到 $(mC $((EFF_TEMP - HYST))) 以下恢复"; return
  fi
  # 防掉帧：接近屏幕降档红线，已整体降频加速降温
  if [ "$DISP_GUARD" = 1 ] && [ -n "$t" ] && [ "$t" -ge "$DISP_GUARD_TEMP" ] 2>/dev/null; then
    echo "机身 $(mC "$t") 接近屏幕降档线（掉帧/变暗），已整体降频加速降温"; return
  fi
  # GPU 过热降频（只在高通且有 kgsl 温度时才有意义）
  if [ "$GPU_GUARD" = 1 ]; then
    read_gpu_temp
    if [ -n "$GPU_T" ] && [ "$GPU_T" -ge "$GPU_GUARD_TEMP" ]; then
      echo "GPU $(mC "$GPU_T") 过热（触发线 $(mC "$GPU_GUARD_TEMP")），已降大核频率"; return
    fi
  fi
  # 只有「本应满频」时，才把实际情况（含被别的链路压着）报出来。
  # 文案里的数字要和 status 的 CAP_FREQ 一致（同一个 $cap，来自同一次采样）。
  if [ "$want" = 1 ]; then
    if [ "$mtk_lost" = 1 ]; then
      echo "厂商服务把频率改回了原厂值（$cap），守护会继续解除"; return
    fi
    if [ "$unl" = 是 ] && [ "$full" = 否 ]; then
      echo "中核/大核未满频（$cap）"; return
    fi
    if [ "$unl" = 否 ] && [ "$full" = 否 ]; then
      echo "本应满频，但本层未解除且频率被压（$cap）"; return
    fi
  fi
  case "$MODE" in
    game)
      # WebUI 打开时游戏必然不在前台；守护有 15 秒宽限，所以刚切出来时仍是满频
      if [ -n "$GAME_FG" ]; then echo "游戏 $GAME_FG 在前台，已满频（阈值 $(mC "$EFF_TEMP")）"
      elif [ "$unl" = 是 ]; then echo "游戏刚切到后台，15 秒内收回"
      else echo "待命 · 游戏在前台时满频"; fi ;;
    apps)
      if [ -z "$cur" ]; then echo "待命 · 取不到前台应用"
      elif app_selected "$cur"; then
        [ "$full" = 是 ] && echo "前台 $cur 已勾选，已满频" || echo "前台 $cur 已勾选，但实际频率被压（$cap）"
      else echo "待命 · 前台 $cur 不在已选列表"; fi ;;
    *)
      if [ "$PLATFORM" = mtk ]; then
        # 天玑：解开的是"钉死"，不是"锁最高频"，所以满/不满取决于负载，不能报"已满频"。
        [ "$full" = 是 ] && echo "全局模式，钉频已解除" || echo "全局模式，钉频已解除（当前负载下频率在 $cap 一带）"
      else
        [ "$full" = 是 ] && echo "全局模式，已满频" || echo "全局模式，但实际频率被压（$cap）"
      fi ;;
  esac
}

# ---- 智能调和状态机 ----
# 日常 profile 格式：机型|ROM（* 表示任意）|平台|频率表。
# 高通表为 cpu:max，天玑表为 policy:max；文件默认不提供任何未实测数值。
load_smart_profiles() {
  local model rom pm pr pp spec sig key
  if [ -z "$DAILY_DEVICE_KEY" ]; then
    model=$(getprop ro.product.model 2>/dev/null)
    rom=$(getprop ro.build.version.oplusrom 2>/dev/null)
    [ -n "$rom" ] || rom=$(getprop ro.build.version.opporom 2>/dev/null)
    DAILY_DEVICE_KEY="$model|$rom|$PLATFORM"
  fi
  sig=$(file_sig "$SMART_PROFILES")
  key="$DAILY_DEVICE_KEY|$PLATFORM|$SMART_PROFILES|${sig:-missing}"
  if [ "$key" = "$DAILY_PROFILE_KEY" ]; then return "$DAILY_PROFILE_RESULT"; fi
  DAILY_PROFILE_KEY=$key; DAILY_PROFILE_RESULT=1; DAILY_SPEC=""
  [ -f "$SMART_PROFILES" ] || return 1
  # ★ mksh 兼容：未加引号的 | 在参数展开模式里被 mksh 解析坏（实测 ${K%%|*} 返回空），
  #   必须给模式里的竖线加引号。这个 bug 让所有机型的日常档位匹配静默失败。
  model=${DAILY_DEVICE_KEY%%'|'*}; rom=${DAILY_DEVICE_KEY#*'|'}; rom=${rom%'|'*}
  while IFS='|' read -r pm pr pp spec; do
    case "$pm" in ''|\#*) continue ;; esac
    spec=${spec%"$CR"}
    [ "$pm" = "$model" ] || continue
    [ "$pp" = "$PLATFORM" ] || continue
    { [ "$pr" = "*" ] || [ "$pr" = "$rom" ]; } || continue
    case "$spec" in '') return 1 ;; esac
    DAILY_SPEC=$spec; DAILY_PROFILE_RESULT=0
    return 0
  done <"$SMART_PROFILES"
  return 1
}

qcom_cpu_ids() {
  local c id
  for c in "${CPU_ROOT}"/cpu[0-9]*; do
    [ -d "$c" ] || continue
    id=${c##*cpu}
    case "$id" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$id"
  done
}

build_daily_plan_qcom() {
  DAILY_PLAN=""
  local ids id pair cpu f found hw
  ids=$(qcom_cpu_ids)
  [ -n "$ids" ] || return 1
  # 先拒绝未知 CPU、重复项和非法数字，再按本机 CPU 顺序生成完整表。
  for pair in $DAILY_SPEC; do
    case "$pair" in *:*) ;; *) return 1 ;; esac
    cpu=${pair%%:*}; f=${pair#*:}
    case "$cpu$f" in ''|*[!0-9]*) return 1 ;; esac
    found=0
    for id in $ids; do [ "$id" = "$cpu" ] && found=1; done
    [ "$found" = 1 ] || return 1
  done
  for id in $ids; do
    found=""
    for pair in $DAILY_SPEC; do
      cpu=${pair%%:*}; f=${pair#*:}
      [ "$cpu" = "$id" ] || continue
      [ -z "$found" ] || return 1
      case "$f" in ''|*[!0-9]*) return 1 ;; esac
      [ "$f" -gt 0 ] 2>/dev/null || return 1
      hw=""; read -r hw 2>/dev/null <"${CPU_ROOT}/cpu$id/cpufreq/cpuinfo_max_freq"
      case "$hw" in ''|*[!0-9]*) ;; *) [ "$f" -le "$hw" ] || return 1 ;; esac
      found=$f
    done
    [ -n "$found" ] || return 1
    DAILY_PLAN="$DAILY_PLAN${DAILY_PLAN:+ }$id:$found"
  done
  [ -n "$DAILY_PLAN" ]
}

build_daily_plan_mtk() {
  DAILY_MTK_PLAN=""
  local pair k f mn mx gv opp ok seen
  for pair in $DAILY_SPEC; do
    case "$pair" in *:*) ;; *) return 1 ;; esac
    k=${pair%%:*}; f=${pair#*:}
    case "$k$f" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "${CPU_ROOT}/cpufreq/policy$k" ] || return 1
    mn=$(mtk_read "$k" scaling_min_freq); mx=$(mtk_read "$k" scaling_max_freq)
    gv=$(mtk_read "$k" scaling_governor)
    case "$mn$mx" in ''|*[!0-9]*) return 1 ;; esac
    [ "$mn" -lt "$mx" ] 2>/dev/null || return 1
    [ "$gv" != powersave ] && [ -n "$gv" ] || return 1
    [ "$f" -ge "$mn" ] && [ "$f" -le "$mx" ] 2>/dev/null || return 1
    ok=0
    for opp in $(mtk_read "$k" scaling_available_frequencies); do
      [ "$opp" = "$f" ] && ok=1
    done
    [ "$ok" = 1 ] || return 1
    case " $DAILY_MTK_PLAN " in *" $k:"*) return 1 ;; esac
    DAILY_MTK_PLAN="$DAILY_MTK_PLAN${DAILY_MTK_PLAN:+ }$k:$f"
  done
  [ -n "$DAILY_MTK_PLAN" ]
}

daily_profile_available() {
  load_smart_profiles || return 1
  case "$PLATFORM" in
    mtk) build_daily_plan_mtk ;;
    *) build_daily_plan_qcom ;;
  esac
}

verify_daily_qcom() {
  local cur pair id target got found
  cur=$(cat "$FREQ" 2>/dev/null)
  [ -n "$cur" ] || return 1
  for pair in $DAILY_PLAN; do
    id=${pair%%:*}; target=${pair#*:}; got=""
    for found in $cur; do
      [ "${found%%:*}" = "$id" ] && got=${found#*:}
    done
    case "$got" in ''|*[!0-9]*) return 1 ;; esac
    [ "$got" = "$target" ] || return 1
  done
  return 0
}

verify_daily_mtk() {
  local pair k target
  for pair in $DAILY_MTK_PLAN; do
    k=${pair%%:*}; target=${pair#*:}
    [ "$(mtk_read "$k" scaling_max_freq)" = "$target" ] || return 1
  done
  return 0
}

daily_load_applied_plan() {
  [ -s "$DAILY_ON" ] || return 1
  local saved
  saved=$(cat "$DAILY_ON" 2>/dev/null)
  [ -n "$saved" ] || return 1
  case "$PLATFORM" in
    mtk) DAILY_MTK_PLAN=$saved ;;
    *) DAILY_PLAN=$saved ;;
  esac
  return 0
}

verify_daily() {
  case "$PLATFORM" in mtk) verify_daily_mtk ;; *) verify_daily_qcom ;; esac
}

daily_write_txn() {
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s\n' "$PLATFORM" >"$DAILY_TXN.tmp" 2>/dev/null || return 1
  mv -f "$DAILY_TXN.tmp" "$DAILY_TXN" 2>/dev/null
}

daily_backup_qcom() {
  local cur
  cur=$(sed 's/[[:space:]]*$//' "$FREQ" 2>/dev/null)
  case "$cur" in ''|*9999999*) return 1 ;; esac
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s' "$cur" >"$DAILY_BAK.tmp" 2>/dev/null || return 1
  mv -f "$DAILY_BAK.tmp" "$DAILY_BAK" 2>/dev/null
}

apply_daily_qcom() {
  build_daily_plan_qcom || return 1
  daily_backup_qcom || return 1
  daily_write_txn || return 1
  chmod 644 "$FREQ" 2>/dev/null || { restore_daily; return 1; }
  printf '%s' "$DAILY_PLAN" >"$FREQ" 2>/dev/null || { restore_daily; return 1; }
  # ★ 锁 444 防 OMRG 抢写：实测不锁时 oplus-omrg 内核线程 4~6 秒就把节点改回
  #   出厂调度值（2016000/2803200/2841600），verify 失败 → daily_conflict。
  #   日常档的语义就是"压制"，锁住低档与 PERF 解锁锁住高档是同一套防抢写机制。
  #   进游戏走 restore_daily（先解锁再还原）→ enter_performance 写满频，无冲突。
  chmod 444 "$FREQ" 2>/dev/null || { restore_daily; return 1; }
  verify_daily_qcom || { restore_daily; return 1; }
  printf '%s\n' "$DAILY_PLAN" >"$DAILY_ON.tmp" 2>/dev/null && mv -f "$DAILY_ON.tmp" "$DAILY_ON" 2>/dev/null || { restore_daily; return 1; }
  rm -f "$DAILY_TXN"
  DAILY_CONFLICT=0
  return 0
}

apply_daily_mtk() {
  build_daily_plan_mtk || return 1
  local pair k f mn mx gv out=""
  for pair in $DAILY_MTK_PLAN; do
    k=${pair%%:*}
    mn=$(mtk_read "$k" scaling_min_freq); mx=$(mtk_read "$k" scaling_max_freq)
    gv=$(mtk_read "$k" scaling_governor)
    out="$out$k $mn $mx $gv
"
  done
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s' "$out" >"$DAILY_MTK_BAK.tmp" 2>/dev/null || return 1
  mv -f "$DAILY_MTK_BAK.tmp" "$DAILY_MTK_BAK" 2>/dev/null || return 1
  daily_write_txn || return 1
  for pair in $DAILY_MTK_PLAN; do
    k=${pair%%:*}; f=${pair#*:}
    write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_max_freq" "$f" || {
      restore_daily
      return 1
    }
  done
  verify_daily_mtk || { restore_daily; return 1; }
  printf '%s\n' "$DAILY_MTK_PLAN" >"$DAILY_ON.tmp" 2>/dev/null && mv -f "$DAILY_ON.tmp" "$DAILY_ON" 2>/dev/null || { restore_daily; return 1; }
  rm -f "$DAILY_TXN"
  DAILY_CONFLICT=0
  return 0
}

# 已验证的 daily 被外部改写时放弃所有权，不覆盖第三方的新值。
daily_conflict_abandon() {
  DAILY_CONFLICT=1
  DAILY_VERIFIED=0
  rm -f "$DAILY_ON" "$DAILY_TXN"
  smart_fail "日常档位被外部服务改写，已停止争夺并保持当前系统值"
}

apply_daily() {
  if [ -f "$DAILY_ON" ]; then
    daily_load_applied_plan
    if verify_daily; then
      rm -f "$DAILY_TXN"
      DAILY_VERIFIED=1
      return 0
    fi
    daily_conflict_abandon
    return 2
  fi
  if [ -f "$DAILY_TXN" ]; then restore_daily || return 1; fi
  case "$PLATFORM" in mtk) apply_daily_mtk ;; *) apply_daily_qcom ;; esac
}

restore_daily() {
  [ -f "$DAILY_ON" ] || [ -f "$DAILY_TXN" ] || return 0
  local kind rc=0 orig k mn mx gv
  kind=$(cat "$DAILY_TXN" 2>/dev/null)
  [ -n "$kind" ] || kind=$PLATFORM
  # 已完成 daily 的外部改写不属于本模块，放弃所有权而不是覆盖；txn 仍在则按失败事务回滚。
  # 使用应用时保存的目标表，不能因当前 profile 失效或外部降顶而跳过冲突检查。
  if [ -f "$DAILY_ON" ] && [ ! -f "$DAILY_TXN" ] && daily_load_applied_plan && ! verify_daily; then
    daily_conflict_abandon
    return 0
  fi
  case "$kind" in
    mtk)
      [ -s "$DAILY_MTK_BAK" ] || return 1
      while IFS=' ' read -r k mn mx gv; do
        [ -n "$k" ] || continue
        write_checked "${CPU_ROOT}/cpufreq/policy$k/scaling_max_freq" "$mx" || rc=1
      done <"$DAILY_MTK_BAK" ;;
    *)
      [ -s "$DAILY_BAK" ] || return 1
      orig=$(cat "$DAILY_BAK" 2>/dev/null)
      # 日常档在位时节点是 444 只读锁，必须先解锁才能写原值；写完保持 644 交还系统。
      chmod 644 "$FREQ" 2>/dev/null || rc=1
      printf '%s' "$orig" >"$FREQ" 2>/dev/null || rc=1
      chmod 644 "$FREQ" 2>/dev/null || rc=1 ;;
  esac
  if [ "$rc" = 0 ]; then
    rm -f "$DAILY_ON" "$DAILY_TXN"
    DAILY_VERIFIED=0
  fi
  return "$rc"
}

# ---- 逐 TID affinity：能力探测与只读观测 ----
aff_norm_mask() {
  local m=$1
  m=${m#0x}; m=${m#0X}
  while [ "${m#0}" != "$m" ] && [ "$m" != 0 ]; do m=${m#0}; done
  case "$m" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  # mksh 算术为 32 位；首版只接受最多 27 位的非负小 mask，超大拓扑宁可不支持。
  [ "${#m}" -le 7 ] || return 1
  AFF_NMASK=$m
}
aff_mask_value() {
  aff_norm_mask "$1" || return 1
  AFF_MVAL=$((16#$AFF_NMASK))
}
aff_mask_multi() {
  aff_mask_value "$1" || return 1
  [ "$AFF_MVAL" -gt 0 ] && [ $((AFF_MVAL & (AFF_MVAL - 1))) -ne 0 ]
}
aff_mask_from_list() {
  local list=$1 part s e v=0
  for part in $(printf '%s' "$list" | tr ',' ' '); do
    case "$part" in
      *-*) s=${part%-*}; e=${part#*-} ;;
      *) s=$part; e=$part ;;
    esac
    case "$s$e" in ''|*[!0-9]*) return 1 ;; esac
    [ "$s" -le "$e" ] 2>/dev/null || return 1
    while [ "$s" -le "$e" ]; do
      [ "$s" -le 27 ] || return 1
      v=$((v | (1 << s)))
      s=$((s + 1))
    done
  done
  [ "$v" -gt 0 ] || return 1
  printf '%x' "$v"
}

aff_read_task() {
  local base="${PROC_ROOT}/$1/task/$2" line v
  AFF_COMM=""; AFF_MASK=""; AFF_LIST=""
  read -r AFF_COMM 2>/dev/null <"$base/comm" || return 1
  while IFS= read -r line; do
    case "$line" in
      Cpus_allowed:*) v=${line#Cpus_allowed:}; trim "$v"; AFF_MASK=$TRIMMED ;;
      Cpus_allowed_list:*) v=${line#Cpus_allowed_list:}; trim "$v"; AFF_LIST=$TRIMMED ;;
    esac
  done <"$base/status" 2>/dev/null
  aff_norm_mask "$AFF_MASK" || return 1
  AFF_MASK=$AFF_NMASK
  [ -n "$AFF_LIST" ]
}

aff_task_stats() {
  local rest
  rest=$(sed 's/^.*) //' "${PROC_ROOT}/$1/task/$2/stat" 2>/dev/null)
  [ -n "$rest" ] || return 1
  set -- $rest
  [ "$#" -ge 37 ] || return 1
  AFF_UT=${12}; AFF_ST=${13}; AFF_CPU=${37}
  case "$AFF_UT$AFF_ST$AFF_CPU" in ''|*[!0-9]*) return 1 ;; esac
  AFF_JIFFIES=$(awk -v a="$AFF_UT" -v b="$AFF_ST" 'BEGIN{printf "%.0f", a+b}')
}

aff_pid_for_pkg() {
  AFF_PID=""
  local p nm
  for p in "${PROC_ROOT}"/[0-9]*; do
    [ -d "$p" ] || continue
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"$p/cmdline" || continue
    nm=${nm%%:*}
    [ "$nm" = "$1" ] || continue
    AFF_PID=${p##*/}
    return 0
  done
  return 1
}

aff_game_pid() {
  AFF_PID=""
  local g nm
  g=$(game_pid_val)
  case "$g" in ''|*[!0-9]*) ;; *)
    nm=""; IFS= read -r -d '' nm 2>/dev/null <"${PROC_ROOT}/$g/cmdline"
    nm=${nm%%:*}
    [ "$nm" = "$1" ] && { AFF_PID=$g; return 0; } ;;
  esac
  aff_pid_for_pkg "$1"
}

aff_rule_for_pkg() {
  AFF_RULE_COMM=""; AFF_RULE_MASK=""
  [ -f "$AFF_RULES" ] || return 1
  local pkg comm mask extra
  while IFS='|' read -r pkg comm mask extra; do
    case "$pkg" in ''|\#*) continue ;; esac
    [ "$pkg" = "$1" ] || continue
    [ -z "$extra" ] || return 1
    [ -z "$AFF_RULE_COMM" ] || return 1
    AFF_RULE_COMM=$comm; AFF_RULE_MASK=$mask
  done <"$AFF_RULES"
  [ -n "$AFF_RULE_COMM" ] && [ -n "$AFF_RULE_MASK" ]
}

probe_affinity_caps() {
  local pid=$1 tid=$2 target=$3 online oldmask oldval newval onval key
  if [ -z "$AFF_TASKSET" ]; then
    if command -v taskset >/dev/null 2>&1; then
      AFF_TASKSET=taskset
    elif command -v toybox >/dev/null 2>&1 && toybox taskset --help >/dev/null 2>&1; then
      AFF_TASKSET="toybox taskset"
    else
      return 1
    fi
  fi
  online=$(cat "$CPU_ROOT/online" 2>/dev/null)
  AFF_ONLINE_MASK=$(aff_mask_from_list "$online") || return 1
  aff_mask_multi "$target" || return 1
  newval=$AFF_MVAL
  oldmask=$AFF_MASK
  aff_mask_value "$oldmask" || return 1
  oldval=$AFF_MVAL
  aff_mask_value "$AFF_ONLINE_MASK" || return 1
  onval=$AFF_MVAL
  # 目标不能越过原 affinity 或在线 CPU；当前 Cpus_allowed 已包含有效 cpuset 约束。
  [ $((newval & ~oldval)) -eq 0 ] && [ $((newval & ~onval)) -eq 0 ] || return 1
  key="$pid|$tid|$oldmask|$target|$AFF_TASKSET"
  [ "$key" = "$AFF_CAPS_KEY" ] && return 0
  # 只写回当前相同 mask，验证 toybox/taskset 的 TID 参数和 SELinux 回读，不改变调度。
  $AFF_TASKSET -p "$oldmask" "$tid" >/dev/null 2>&1 || return 1
  aff_read_task "$pid" "$tid" || return 1
  [ "$AFF_MASK" = "$oldmask" ] || return 1
  AFF_CAPS_KEY=$key
  return 0
}

aff_tid_for_comm() {
  AFF_TID=""
  local p tid comm
  for p in "${PROC_ROOT}/$1/task/"[0-9]*; do
    [ -d "$p" ] || continue
    tid=${p##*/}
    read -r comm 2>/dev/null <"$p/comm" || continue
    [ "$comm" = "$2" ] || continue
    # 重名线程不能猜，必须让用户先用 observe 确认唯一目标。
    [ -z "$AFF_TID" ] || { AFF_TID=""; return 2; }
    AFF_TID=$tid
  done
  [ -n "$AFF_TID" ]
}

aff_txn_verify() {
  [ -s "$AFF_TXN" ] || return 1
  local pid ps tid ts old new pkg comm rulemask
  aff_norm_mask "$AFF_RULE_MASK" || return 1
  rulemask=$AFF_NMASK
  while IFS='|' read -r pid ps tid ts old new pkg comm; do
    [ -n "$pid$ps$tid$ts$old$new$pkg" ] || return 1
    [ "$pkg" = "$AFF_ACTIVE_PKG" ] || return 2
    [ "$(proc_starttime "$pid")" = "$ps" ] || return 2
    [ "$(proc_tid_starttime "$pid" "$tid")" = "$ts" ] || return 2
    aff_read_task "$pid" "$tid" || return 2
    [ "$AFF_MASK" = "$new" ] || return 3
    # 同局修改线程名或 mask 时，旧事务不能直接吞掉新规则；先恢复再重新应用。
    [ "$comm" = "$AFF_RULE_COMM" ] || return 2
    [ "$new" = "$rulemask" ] || return 2
  done <"$AFF_TXN"
  return 0
}

aff_conflict_drop() {
  local pid ps tid ts old new pkg comm
  pid=""; tid=""; new=""; pkg=""
  IFS='|' read -r pid ps tid ts old new pkg comm <"$AFF_TXN" 2>/dev/null
  AFF_SKIP_KEY="${pkg:-$AFF_ACTIVE_PKG}|${pid:-}|${tid:-}|${new:-}"
  rm -f "$AFF_TXN"
  AFFINITY_VERIFIED=0
  smart_fail "线程 affinity 被外部改写，已放弃所有权，不覆盖第三方值"
}

restore_task_affinity() {
  [ -f "$AFF_TXN" ] || { AFFINITY_VERIFIED=0; return 0; }
  if [ -z "$AFF_TASKSET" ]; then
    if command -v taskset >/dev/null 2>&1; then AFF_TASKSET=taskset
    elif command -v toybox >/dev/null 2>&1; then AFF_TASKSET="toybox taskset"
    else return 1; fi
  fi
  local pid ps tid ts old new pkg comm current remaining="" failed=0
  while IFS='|' read -r pid ps tid ts old new pkg comm; do
    [ -n "$pid$tid" ] || continue
    # PID/TID 已复用或线程已退出：原线程不再可恢复，绝不能碰新线程。
    if [ "$(proc_starttime "$pid")" != "$ps" ] \
      || [ "$(proc_tid_starttime "$pid" "$tid")" != "$ts" ]; then
      log "affinity 线程身份已变化，跳过恢复 pid=$pid tid=$tid"
      continue
    fi
    if ! aff_read_task "$pid" "$tid"; then
      # 身份已确认但状态暂时不可读时保留事务，下一次 ensure 再试；
      # 只有任务目录确实消失才允许丢弃。
      if [ -d "${PROC_ROOT}/$pid/task/$tid" ]; then
        remaining="$remaining$pid|$ps|$tid|$ts|$old|$new|$pkg|$comm
"
        failed=1
      fi
      continue
    fi
    current=$AFF_MASK
    if [ "$current" != "$new" ] && [ "${AFF_FORCE_RESTORE:-0}" != 1 ]; then
      log "affinity 当前值已被外部修改，放弃覆盖 pid=$pid tid=$tid"
      continue
    fi
    if ! $AFF_TASKSET -p "$old" "$tid" >/dev/null 2>&1; then
      remaining="$remaining$pid|$ps|$tid|$ts|$old|$new|$pkg|$comm
"
      failed=1
      continue
    fi
    aff_read_task "$pid" "$tid" || {
      remaining="$remaining$pid|$ps|$tid|$ts|$old|$new|$pkg|$comm
"
      failed=1
      continue
    }
    if [ "$AFF_MASK" != "$old" ]; then
      remaining="$remaining$pid|$ps|$tid|$ts|$old|$new|$pkg|$comm
"
      failed=1
    fi
  done <"$AFF_TXN"
  if [ "$failed" = 1 ]; then
    printf '%s' "$remaining" >"$AFF_TXN.tmp" 2>/dev/null && mv -f "$AFF_TXN.tmp" "$AFF_TXN"
    AFFINITY_VERIFIED=0
    return 1
  fi
  rm -f "$AFF_TXN"
  AFFINITY_VERIFIED=0
  AFF_CAPS_KEY=""
  return 0
}

rollback_task_affinity() {
  # 仅在刚完成本模块写入、且事务身份仍匹配的失败路径使用。
  AFF_FORCE_RESTORE=1
  restore_task_affinity
  local rc=$?
  AFF_FORCE_RESTORE=0
  return "$rc"
}

apply_configured_affinity() {
  AFFINITY_VERIFIED=0
  [ "$AFFINITY_ENABLE" = 1 ] || return 0
  if ! game_fg; then
    AFF_SKIP_KEY=""
    restore_task_affinity
    return 0
  fi
  AFF_ACTIVE_PKG=$GAME_FG
  local pid tid key target oldmask ps ts trc
  if ! aff_rule_for_pkg "$AFF_ACTIVE_PKG"; then
    AFF_SKIP_KEY=""
    restore_task_affinity
    return 0
  fi
  aff_norm_mask "$AFF_RULE_MASK" || { smart_fail "游戏规则 mask 非法"; return 0; }
  target=$AFF_NMASK
  if [ -s "$AFF_TXN" ]; then
    aff_txn_verify
    trc=$?
    case "$trc" in
      0) AFFINITY_VERIFIED=1; return 0 ;;
      2) restore_task_affinity || return 1 ;;
      3) aff_conflict_drop; return 0 ;;
      *) restore_task_affinity || return 1 ;;
    esac
  fi
  aff_game_pid "$AFF_ACTIVE_PKG" || return 0
  pid=$AFF_PID
  key="$AFF_ACTIVE_PKG|$pid|$AFF_RULE_COMM|$target"
  [ "$key" = "$AFF_SKIP_KEY" ] && return 0
  if ! aff_tid_for_comm "$pid" "$AFF_RULE_COMM"; then
    AFF_SKIP_KEY=$key
    smart_fail "游戏规则未匹配到唯一线程：$AFF_ACTIVE_PKG/$AFF_RULE_COMM"
    return 0
  fi
  tid=$AFF_TID
  aff_read_task "$pid" "$tid" || return 0
  oldmask=$AFF_MASK
  key="$AFF_ACTIVE_PKG|$pid|$tid|$target"
  [ "$key" = "$AFF_SKIP_KEY" ] && return 0
  if ! probe_affinity_caps "$pid" "$tid" "$target"; then
    AFF_SKIP_KEY=$key
    smart_fail "本机不允许该线程 affinity（能力、在线 CPU 或 mask 校验失败）"
    return 0
  fi
  if [ "$oldmask" = "$target" ]; then
    AFFINITY_VERIFIED=1
    return 0
  fi
  ps=$(proc_starttime "$pid"); ts=$(proc_tid_starttime "$pid" "$tid")
  [ -n "$ps" ] && [ -n "$ts" ] || return 1
  mkdir -p "$DATA" 2>/dev/null || return 1
  # 先落事务，再写调度；异常被杀后 ensure/stop 可据此恢复原 mask。
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$pid" "$ps" "$tid" "$ts" "$oldmask" "$target" "$AFF_ACTIVE_PKG" "$AFF_RULE_COMM" \
    >"$AFF_TXN.tmp" 2>/dev/null || return 1
  mv -f "$AFF_TXN.tmp" "$AFF_TXN" 2>/dev/null || return 1
  if ! $AFF_TASKSET -p "$target" "$tid" >/dev/null 2>&1; then
    rollback_task_affinity
    smart_fail "taskset 写入失败，已尝试恢复原 affinity"
    return 1
  fi
  aff_read_task "$pid" "$tid" || { rollback_task_affinity; smart_fail "affinity 写后读取失败"; return 1; }
  if [ "$AFF_MASK" != "$target" ]; then
    rollback_task_affinity
    smart_fail "affinity 写后回读不符，已尝试回滚"
    return 1
  fi
  AFF_SKIP_KEY=""
  AFFINITY_VERIFIED=1
  log "已应用线程 affinity：$AFF_ACTIVE_PKG tid=$tid mask=$oldmask->$target"
  return 0
}

aff_snapshot_tasks() {
  local pid=$1 p tid
  for p in "${PROC_ROOT}/$pid/task/"[0-9]*; do
    [ -d "$p" ] || continue
    tid=${p##*/}
    aff_read_task "$pid" "$tid" || continue
    aff_task_stats "$pid" "$tid" || continue
    case "$AFF_COMM" in *'|'*) continue ;; esac
    printf '%s|%s|%s|%s|%s|%s\n' "$pid" "$tid" "$AFF_COMM" "$AFF_CPU" "$AFF_MASK" "$AFF_JIFFIES"
  done
}

cmd_observe() {
  local pkg=${1:-} sec=${2:-1} pid f1 f2
  if [ -z "$pkg" ]; then game_fg && pkg=$GAME_FG; fi
  [ -n "$pkg" ] || { echo "没有可观测的前台游戏，也可指定包名"; return 1; }
  case "$sec" in 1|2|3|4|5) ;; *) sec=1 ;; esac
  aff_game_pid "$pkg" || { echo "找不到运行中的包：$pkg"; return 1; }
  pid=$AFF_PID
  mkdir -p "$DATA" 2>/dev/null || return 1
  f1="$DATA/aff.observe.$$.1"; f2="$DATA/aff.observe.$$.2"
  aff_snapshot_tasks "$pid" >"$f1"
  sleep "$sec"
  aff_snapshot_tasks "$pid" >"$f2"
  echo "TID|线程名|运行CPU|当前affinity|累计jiffies|增量jiffies"
  awk -F'|' 'NR==FNR { j[$2]=$6; next }
    { d=$6-j[$2]; if (d < 0 || j[$2] == "") d=0;
      printf "%s|%s|%s|%s|%s|%s\n", $2,$3,$4,$5,$6,d+0 }' "$f1" "$f2"
  rm -f "$f1" "$f2"
}

smart_fail() {
  LAST_ERROR=$1
  log "$1"
}

smart_publish() {
  local text old
  text="STATE_VALID=1
CTRL_PID=$CTRL_PID
CTRL_START=$CTRL_START
APPLIED_CONF_SIG=$APPLIED_CONF_SIG
SMART_STATE=$SMART_STATE
SMART_REASON=$SMART_REASON
PERF_VERIFIED=$PERF_VERIFIED
DAILY_VERIFIED=$DAILY_VERIFIED
AFFINITY_VERIFIED=$AFFINITY_VERIFIED
LAST_ERROR=$LAST_ERROR"
  old=$(cat "$SMART_STATE_FILE" 2>/dev/null)
  [ "$old" = "$text" ] && return 0
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s\n' "$text" >"$SMART_STATE_FILE.tmp" 2>/dev/null || return 1
  mv -f "$SMART_STATE_FILE.tmp" "$SMART_STATE_FILE" 2>/dev/null
}

smart_invalidate() {
  CTRL_PID=""; CTRL_START=""; APPLIED_CONF_SIG=""
  SMART_STATE=NEUTRAL; SMART_REASON=stopped
  PERF_VERIFIED=0; DAILY_VERIFIED=0; AFFINITY_VERIFIED=0
  local text old
  text="STATE_VALID=0
CTRL_PID=
CTRL_START=
APPLIED_CONF_SIG=
SMART_STATE=NEUTRAL
SMART_REASON=stopped
PERF_VERIFIED=0
DAILY_VERIFIED=0
AFFINITY_VERIFIED=0
LAST_ERROR=${LAST_ERROR:-}"
  old=$(cat "$SMART_STATE_FILE" 2>/dev/null)
  [ "$old" = "$text" ] && return 0
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s\n' "$text" >"$SMART_STATE_FILE.tmp" 2>/dev/null || return 1
  mv -f "$SMART_STATE_FILE.tmp" "$SMART_STATE_FILE" 2>/dev/null
}

smart_decide() {
  local previous=$SMART_STATE elapsed
  SMART_WANT=0
  # 继续复用原来的范围判定、游戏 15 秒宽限和过热滞回。
  if should_unlock; then SMART_WANT=1; fi
  if [ -z "$T_NOW" ]; then
    DAILY_SINCE=""; SENSOR_CLEAR_N=0
    SMART_STATE=SENSOR_FAULT; SMART_REASON=sensor_fault
    return
  fi
  if [ "$previous" = SENSOR_FAULT ] && [ "$SMART_ENABLE" = 1 ]; then
    SENSOR_CLEAR_N=$((SENSOR_CLEAR_N + 1))
    if [ "$SENSOR_CLEAR_N" -lt 2 ]; then
      SMART_STATE=SENSOR_FAULT; SMART_REASON=sensor_recover_wait
      return
    fi
  fi
  SENSOR_CLEAR_N=0
  if is_hot; then
    DAILY_SINCE=""
    SMART_STATE=HOT; SMART_REASON=thermal_protection
    return
  fi
  if [ "$SMART_WANT" = 1 ]; then
    DAILY_SINCE=""
    # 过热降频：GPU 与防掉帧两路信号独立滞回，任一命中进 GPU_HOT。
    # 只挂在游戏前台分支里 —— 没游戏时不存在"降频让热"。
    local gpu_hit=0 disp_hit=0
    update_gpu_hot && gpu_hit=1
    update_disp_hot && disp_hit=1
    if [ "$gpu_hit" = 1 ] || [ "$disp_hit" = 1 ]; then
      SMART_STATE=GPU_HOT
      if [ "$disp_hit" = 1 ]; then SMART_REASON=disp_hot_yield
      else SMART_REASON=gpu_hot_yield; fi
      return
    fi
    SMART_STATE=PERF; SMART_REASON=scope_active
    return
  fi
  if [ "$SMART_ENABLE" != 1 ]; then
    DAILY_SINCE=""
    SMART_STATE=NEUTRAL; SMART_REASON=legacy_mode
    return
  fi
  if [ "$MODE" = global ]; then
    DAILY_SINCE=""
    SMART_STATE=NEUTRAL; SMART_REASON=global_scope
    return
  fi
  if [ "$DAILY_PROFILE" = off ]; then
    DAILY_SINCE=""
    SMART_STATE=NEUTRAL; SMART_REASON=daily_disabled
    return
  fi
  up_s
  if [ -z "$UP" ]; then
    SMART_STATE=NEUTRAL; SMART_REASON=clock_unavailable
    return
  fi
  if [ -z "$DAILY_SINCE" ]; then
    DAILY_SINCE=$UP
    SMART_STATE=NEUTRAL; SMART_REASON=wait_daily
    return
  fi
  elapsed=$((UP - DAILY_SINCE))
  if [ "$elapsed" -lt "$DAILY_WAIT" ]; then
    SMART_STATE=NEUTRAL; SMART_REASON=wait_daily
    return
  fi
  if [ "$DAILY_CONFLICT" = 1 ]; then
    SMART_STATE=NEUTRAL; SMART_REASON=daily_conflict
  elif daily_profile_available; then
    SMART_STATE=DAILY; SMART_REASON=verified_daily_profile
  else
    SMART_STATE=NEUTRAL; SMART_REASON=no_verified_daily
  fi
}

enter_performance() {
  local t=$T_NOW was_on
  PERF_VERIFIED=0; DAILY_VERIFIED=0; DAILY_CONFLICT=0
  if [ "$AFFINITY_ENABLE" != 1 ] && type restore_task_affinity >/dev/null 2>&1; then
    # 先处理禁用事务，避免后续频率操作失败时提前返回而留下旧 mask。
    restore_task_affinity || { smart_fail "关闭 affinity 后恢复原线程失败，未进入性能状态"; return 1; }
  fi
  if type restore_daily >/dev/null 2>&1 && { [ -f "$DAILY_ON" ] || [ -f "$DAILY_TXN" ]; }; then
    restore_daily || { smart_fail "日常档位恢复失败，未进入性能状态"; return 1; }
  fi
  case "$PLATFORM" in
    mtk)
      if ! mtk_unlocked; then
        was_on=0; [ -f "$MTK_ON" ] && was_on=1
        if ! mtk_unlock; then
          smart_fail "天玑频率解除失败，保持中立"
          return 1
        fi
        if ! : >"$MTK_ON" 2>/dev/null; then
          smart_fail "天玑所有权标记创建失败，保留事务供恢复"
          return 1
        fi
        rm -f "$MTK_TXN"
        if [ "$was_on" = 0 ]; then
          log "解锁（天玑 · ${ZONE_USED:-$ZONE} ${t} 阈值 ${EFF_TEMP:-${TEMP:-55000}} 模式 $MODE${GAME_LAST:+ 游戏 $GAME_LAST}）"
          rm -f "$MTK_REP"
        elif [ ! -f "$MTK_REP" ]; then
          log "天玑频率被厂商改回，已再次解除"
          : >"$MTK_REP" 2>/dev/null
        fi
      fi
      mtk_unlocked && PERF_VERIFIED=1 ;;
    *)
      if [ "$GAME_CPU_SWEET" = hw ] && sweet_string; then
        # 稳健档：同一节点写"每核硬件原生上限"，省出大核尾部热（3187→2803 一类）。
        if ! sweet_on || ! node_readonly; then
          ensure_backup
          if ! unlock_sweet; then
            smart_fail "大核稳健档写入或回读失败，保持中立"
            restore_freq
            return 1
          fi
          if ! : >"$QCOM_ON" 2>/dev/null; then
            restore_freq
            smart_fail "高通所有权标记创建失败，已尝试恢复频率"
            return 1
          fi
          rm -f "$QCOM_TXN"
          log "解锁（稳健档 · ${ZONE_USED:-$ZONE} ${t} 阈值 ${EFF_TEMP:-${TEMP:-55000}} 模式 $MODE${GAME_LAST:+ 游戏 $GAME_LAST}）"
        fi
        sweet_on && node_readonly && PERF_VERIFIED=1
      else
        if ! is_unlocked || ! node_readonly; then
          ensure_backup
          if ! unlock_freq; then
            smart_fail "高通频率解除写入或回读失败，保持中立"
            restore_freq
            return 1
          fi
          if ! : >"$QCOM_ON" 2>/dev/null; then
            restore_freq
            smart_fail "高通所有权标记创建失败，已尝试恢复频率"
            return 1
          fi
          rm -f "$QCOM_TXN"
          log "解锁（${ZONE_USED:-$ZONE} ${t} 阈值 ${EFF_TEMP:-${TEMP:-55000}} 模式 $MODE${GAME_LAST:+ 游戏 $GAME_LAST}）"
        fi
        is_unlocked && node_readonly && PERF_VERIFIED=1
      fi ;;
  esac
  if ! game_opt_ok; then
    if enable_game && game_opt_ok; then
      log "禁用游戏上限（game_pid=$(game_pid_val)）"
    else
      smart_fail "游戏场景上限开关不可用（频率层状态单独保留）"
    fi
  fi
  # GPU 实验上限：只降不升；配置改回 off 时也要在这里收回
  if gpu_cap_wanted; then
    gpu_apply_cap || true
  else
    gpu_restore_cap || true
  fi
  AFFINITY_VERIFIED=0
  if [ "$AFFINITY_ENABLE" = 1 ] && type apply_configured_affinity >/dev/null 2>&1; then
    apply_configured_affinity || true
  fi
  [ "$PERF_VERIFIED" = 1 ]
}

enter_neutral() {
  restore_all_owned || smart_fail "部分资源恢复失败，将在下次 tick/ensure 重试"
  PERF_VERIFIED=0; DAILY_VERIFIED=0; AFFINITY_VERIFIED=0
  return 0
}

enter_gpu_yield() {
  # 过热降频。显示红线命中 → 整体降频，不折中：60Hz/限亮直接锁死帧率与观感，
  # 只有最快降温才能把显示温度拉回恢复线（实测 46°C 自动回 90Hz），稳健档省的热不够快。
  if [ "$DISP_HOT_ON" = 1 ]; then
    enter_neutral
    return $?
  fi
  # GPU 过热保护：GPU 到触发线，把大核尾部热让给 GPU。
  # action=neutral → 整体降频（更保守）；sweet 不可用时同样退化为整体降频。
  if [ "$GPU_GUARD_ACTION" = neutral ]; then
    enter_neutral
    return $?
  fi
  if [ "$GAME_CPU_SWEET" = hw ]; then
    # 静态稳健档已把大核钉在硬件上限，降频无更低档可落，保持现状
    return 0
  fi
  if ! sweet_string; then
    smart_fail "大核稳健档不可用（读不全硬件上限），GPU 过热保护改为整体降频"
    enter_neutral
    return $?
  fi
  if ! sweet_on || ! node_readonly; then
    ensure_backup
    if ! unlock_sweet; then
      smart_fail "GPU 过热降大核频率失败，改为整体降频"
      enter_neutral
      return $?
    fi
    if ! : >"$QCOM_ON" 2>/dev/null; then
      smart_fail "高通所有权标记创建失败，GPU 过热保护未完成"
      return 1
    fi
    rm -f "$QCOM_TXN"
    log "GPU $(mC "$GPU_T") 过热：大核落稳健档（触发线 $(mC "$GPU_GUARD_TEMP")）"
  fi
  # 降频是刻意降性能换 GPU 不降档：如实标 0，游戏记录的满频占比才会反映降频时长。
  PERF_VERIFIED=0
  return 0
}

enter_daily() {
  local rc
  PERF_VERIFIED=0; AFFINITY_VERIFIED=0; DAILY_VERIFIED=0
  restore_performance || { smart_fail "进入日常前性能资源恢复失败"; return 1; }
  if ! type apply_daily >/dev/null 2>&1; then
    SMART_STATE=NEUTRAL; SMART_REASON=daily_unavailable
    smart_fail "本机没有可用的已验证日常档位，保持系统调度"
    return 1
  fi
  apply_daily
  rc=$?
  if [ "$rc" = 2 ]; then
    SMART_STATE=NEUTRAL; SMART_REASON=daily_conflict
    return 0
  fi
  if [ "$rc" != 0 ]; then
    SMART_STATE=NEUTRAL; SMART_REASON=daily_unavailable
    smart_fail "日常档位写入或回读失败，已回滚并保持系统调度"
    return 1
  fi
  DAILY_VERIFIED=1
  return 0
}

smart_transition() {
  case "$SMART_STATE" in
    PERF) enter_performance ;;
    GPU_HOT) enter_gpu_yield ;;
    DAILY) enter_daily ;;
    HOT|SENSOR_FAULT|NEUTRAL) enter_neutral ;;
    *) SMART_STATE=NEUTRAL; SMART_REASON=unknown_state; enter_neutral ;;
  esac
}

# ---- 执行一次决策 ----
tick() {
  LAST_ERROR=""
  read_temp
  read_gpu_temp
  smart_decide
  smart_transition
  smart_publish
}

# ---- 守护 ----
# /proc/PID/stat 的 comm 可能含空格和括号，先去掉到最后一个 ") " 的前缀；
# 余下字段第 20 项就是原始第 22 项 starttime。只在管理命令中调用，不进每拍循环。
proc_stat_starttime() {
  local rest
  rest=$(sed 's/^.*) //' "$1" 2>/dev/null)
  [ -n "$rest" ] || return 1
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s' "${20}"
}
proc_starttime() { proc_stat_starttime "${PROC_ROOT}/$1/stat"; }
proc_tid_starttime() { proc_stat_starttime "${PROC_ROOT}/$1/task/$2/stat"; }

list_daemons() {
  for p in "${PROC_ROOT}"/[0-9]*; do
    cl=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline") || continue
    case "$cl" in *cpulimit.sh*daemon*) echo "${p##*/}" ;; esac
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
    op=$(cat "$PIDFILE" 2>/dev/null)
    # 先核对 cmdline 和启动时间，PID 被复用时不能误杀无关进程。
    if is_alive; then kill -9 "$op" 2>/dev/null; fi
    rm -f "$PIDFILE" "$PIDSTART"
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
  case "$(tr '\0' ' ' 2>/dev/null <"${PROC_ROOT}/$p/cmdline")" in
    *cpulimit.sh*daemon*) ;;
    *) return 1 ;;
  esac
  # 旧版本没有 sidecar 时保留兼容；新实例必须同时匹配 starttime。
  if [ -f "$PIDSTART" ]; then
    local want now
    want=$(cat "$PIDSTART" 2>/dev/null)
    now=$(proc_starttime "$p")
    [ -n "$want" ] && [ "$want" = "$now" ] || return 1
  fi
  return 0
}

# 文件签名取内容摘要，不依赖秒级 mtime 或文件大小；同一秒等长修改也能被守护看到。
file_sig() {
  if command -v cksum >/dev/null 2>&1; then cksum "$1" 2>/dev/null
  elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null
  else stat -c '%Y-%s' "$1" 2>/dev/null
  fi
}
conf_sig() { file_sig "$CONF"; }

daemon_cleanup() {
  # 新实例已经接管 PIDFILE 时，旧实例绝不能恢复新实例刚写入的资源。
  [ "$(cat "$PIDFILE" 2>/dev/null)" = "$MY" ] || return 0
  restore_all_owned
  local rc=$?
  [ "$rc" = 0 ] || LAST_ERROR="部分资源恢复失败"
  smart_invalidate
  rm -f "$PIDFILE" "$PIDSTART"
}

daemon() {
  MY=$$
  echo "$MY" >"$PIDFILE"
  proc_starttime "$MY" >"$PIDSTART" 2>/dev/null
  echo -1000 >"${PROC_ROOT}/$MY/oom_score_adj" 2>/dev/null
  trap 'daemon_cleanup; exit 0' TERM INT HUP
  SMART_STATE=NEUTRAL; SMART_REASON=starting
  DAILY_SINCE=""; HOT_CLEAR_N=0; SENSOR_CLEAR_N=0
  GPU_T=""; GPU_HOT_ON=0; GPU_CLEAR_N=0
  DISP_HOT_ON=0; DISP_CLEAR_N=0
  LASTCONF=$(conf_sig)
  CTRL_PID=$MY
  CTRL_START=$(proc_starttime "$MY")
  APPLIED_CONF_SIG=$LASTCONF
  log "守护启动：pid=$MY ENABLE=$ENABLE TEMP=$TEMP MODE=$MODE SMART=$SMART_ENABLE"
  while :; do
    cur=$(cat "$PIDFILE" 2>/dev/null)
    [ "$cur" != "$MY" ] && { log "被新实例接管，退出 pid=$MY"; exit 0; }
    sig=$(conf_sig)
    if [ "$sig" != "$LASTCONF" ]; then
      ENABLE=1; TEMP=55000; TEMP_CPU=80000; ZONE=skin-msm-therm; MODE=game; HYST=3000
      SMART_ENABLE=0; DAILY_PROFILE=auto; AFFINITY_ENABLE=0
      GAME_CPU_SWEET=off; GPU_GUARD=off; GPU_GUARD_TEMP=60000
      GPU_GUARD_ACTION=sweet; GAME_GPU_CAP=off
      DISP_GUARD=off; DISP_GUARD_TEMP=51500
      load_conf
      if [ "$ENABLE" != "1" ]; then
        restore_all_owned; rm -f "$HOT_FLAG"
        smart_invalidate
        log "ENABLE!=1，已还原模块资源并退出"
        rm -f "$PIDFILE" "$PIDSTART"; exit 0
      fi
      LASTCONF=$sig
      APPLIED_CONF_SIG=$sig
      log "配置已更新：TEMP=$TEMP ZONE=$ZONE MODE=$MODE SMART=$SMART_ENABLE"
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
  # 机器可读的两行（WebUI 用；不要删或改格式）。
  # PLATFORM：mtk / qcom。LAYER_ON：本模块这一层现在是否在位
  #（高通 = 节点是解锁值且只读锁在；天玑 = 各 policy 上限已放开、governor 已换）。
  # WebUI 以前用「当前上限里有没有 9999999」猜，天玑没有这个节点，猜不出来。
  echo "PLATFORM=$PLATFORM"
  echo "配置：ENABLE=$ENABLE TEMP=${TEMP}/TEMP_CPU=${TEMP_CPU} ZONE=$ZONE MODE=$MODE HYST=$HYST SMART_ENABLE=$SMART_ENABLE DAILY_PROFILE=$DAILY_PROFILE AFFINITY_ENABLE=$AFFINITY_ENABLE GAME_CPU_SWEET=$GAME_CPU_SWEET GPU_GUARD=$GPU_GUARD GPU_GUARD_TEMP=$GPU_GUARD_TEMP GPU_GUARD_ACTION=$GPU_GUARD_ACTION DISP_GUARD=$DISP_GUARD DISP_GUARD_TEMP=$DISP_GUARD_TEMP GAME_GPU_CAP=$GAME_GPU_CAP"
  if is_alive && [ -f "$SMART_STATE_FILE" ]; then
    cat "$SMART_STATE_FILE"
  else
    echo "STATE_VALID=0"
    echo "CTRL_PID="
    echo "CTRL_START="
    echo "APPLIED_CONF_SIG="
    echo "SMART_STATE=NEUTRAL"
    echo "SMART_REASON=not_running"
    echo "PERF_VERIFIED=0"
    echo "DAILY_VERIFIED=0"
    echo "AFFINITY_VERIFIED=0"
    echo "LAST_ERROR="
  fi
  echo "CONF_SIG=$(conf_sig)"
  # 先采样，后面的"当前上限/capped 判定"都用这一份数据，避免同一份报告里自相矛盾
  sample_caps; compute_capped
  local lo=0; layer_on && lo=1
  echo "LAYER_ON=$lo"
  case "$PLATFORM" in
    mtk) echo "本层状态：$([ -f "$MTK_ON" ] && echo 已解开 || echo 未解开)（天玑：放开各 policy 的 min/max 与 governor）"
         echo "原厂备份：$([ -s "$MTK_BAK" ] && echo "有（$MTK_BAK）" || echo 无)" ;;
    *)   echo "当前上限：$(cat "$FREQ" 2>/dev/null)"
         echo "出厂备份：$(orig_value)" ;;
  esac
  echo "游戏上限：$(cat ${GAME_OPT}/cpu_max_freq 2>/dev/null || echo '—')  [disable_cpufreq_limit=$(cat "$GAMEDIS" 2>/dev/null)]"
  if [ -r "$GPU_TEMPF" ]; then
    echo "GPU：温度 $(cat "$GPU_TEMPF" 2>/dev/null) 上限 $(cat "$GPU_MAXF" 2>/dev/null) 热档 $(cat "$GPU_PWL" 2>/dev/null)$( [ -f "$GPU_ON" ] && echo ' 实验上限=持有中')"
  fi
  echo
  echo "当前频率（上限 / 实际 / 硬件上限）："
  # 按实际存在的 policy 列出（取每个 policy 的第一个 CPU 做标签），
  # 不再写死 0/4/7 —— 天玑/新平台的簇划分不一定相同（如纯 4+4 就没有 cpu7）。
  for p in ${CPU_ROOT}/cpufreq/policy*; do
    [ -d "$p" ] || continue
    c=""; read -r c 2>/dev/null <"$p/related_cpus"
    c=${c%% *}
    [ -n "$c" ] || c=${p##*/policy}
    printf '  cpu%-2s %8s / %8s / %8s\n' "$c" \
      "$(cat "$p/scaling_max_freq" 2>/dev/null)" \
      "$(cat "$p/scaling_cur_freq" 2>/dev/null)" \
      "$(cat "$p/cpuinfo_max_freq" 2>/dev/null)"
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
  # 候选温区现场：替补是"取读数最高"选出来的，把全部候选列出来便于核对选得对不对
  # （天玑上 cpu 族有 13 个 34000 死值，只看 ZONE_USED 看不出为什么选了这个）
  echo "ZONE_PICK=$(zone_pick_note)"
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
    if is_alive; then
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
  restore_all_owned
  local rc=$?
  if [ "$rc" = 0 ]; then LAST_ERROR=""; else LAST_ERROR="部分资源恢复失败"; fi
  smart_invalidate
  rm -f "$HOT_FLAG"
  if [ "$rc" = 0 ]; then
    log "已停止并还原模块持有的频率/调度资源，已写 ENABLE=0"
    case "$PLATFORM" in
      mtk) echo "已停止，天玑频率已还原为原厂 policy 设置" ;;
      *)   echo "已停止，出厂上限已还原：$(cat "$FREQ" 2>/dev/null)" ;;
    esac
  else
    log "停止时发现资源恢复失败，保留恢复标记供下次 ensure 重试"
    echo "已停止，但部分资源恢复失败；请再次执行恢复或查看 $LOG"
  fi
  return "$rc"
}

cmd_recover() {
  stop_daemon
  restore_all_owned
  local rc=$?
  if [ "$rc" = 0 ]; then LAST_ERROR=""; else LAST_ERROR="部分资源恢复失败"; fi
  smart_invalidate
  return "$rc"
}

cmd_apply() {
  load_conf
  # 配置是关闭状态时交给 stop 走完整还原。
  if [ "$ENABLE" != "1" ]; then cmd_stop; return; fi
  if ! is_alive; then
    nohup sh "$0" daemon >/dev/null 2>&1 &
    echo "已按新配置启动守护（TEMP=$TEMP MODE=$MODE SMART=$SMART_ENABLE）"
  else
    # 不在 WebUI 进程里直接 tick，避免与守护同时写同一批节点；mtime 会让守护下一拍重载。
    echo "配置已提交，守护将在下一拍应用（TEMP=$TEMP MODE=$MODE SMART=$SMART_ENABLE）"
  fi
}

cmd_ensure() {
  load_conf
  if [ "$ENABLE" != "1" ]; then
    if is_alive || [ -f "$MTK_ON" ] || [ -f "$MTK_TXN" ] || [ -f "$QCOM_ON" ] || [ -f "$QCOM_TXN" ] || [ -f "$DAILY_ON" ] || [ -f "$DAILY_TXN" ] || [ -f "$AFF_TXN" ] || [ -f "$GAME_ON" ] || [ -f "$GPU_ON" ] || [ -f "$GPU_TXN" ] || is_unlocked; then
      stop_daemon
      restore_all_owned
      rm -f "$HOT_FLAG"
      log "ensure：配置已关闭，还原并停止"
    fi
    smart_invalidate
    return 0
  fi
  is_alive && return 0
  log "ensure：守护不在，先恢复可能残留的资源再重新拉起"
  restore_all_owned
  smart_invalidate
  nohup sh "$0" daemon >/dev/null 2>&1 &
  sleep 1
}

# 测试可 source 函数而不执行平台门槛和命令分发；正常模块不设置该变量。
if [ "${CPULIMIT_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# 管理命令的短时互斥锁；守护不长期持有，避免 ensure 因守护运行而无法补启。
acquire_cmd_lock() {
  if mkdir "$CMD_LOCK" 2>/dev/null; then
    echo "$$" >"$CMD_LOCK/pid" 2>/dev/null
    return 0
  fi
  # 只清理明确已死亡的本模块命令留下的锁，不使用递归删除。
  local op=""
  [ -f "$CMD_LOCK/pid" ] && op=$(cat "$CMD_LOCK/pid" 2>/dev/null)
  case "$op" in ''|*[!0-9]*) return 1 ;; esac
  if ! kill -0 "$op" 2>/dev/null; then
    rm -f "$CMD_LOCK/pid" 2>/dev/null
    rmdir "$CMD_LOCK" 2>/dev/null || return 1
    mkdir "$CMD_LOCK" 2>/dev/null || return 1
    echo "$$" >"$CMD_LOCK/pid" 2>/dev/null
    return 0
  fi
  return 1
}
release_cmd_lock() {
  [ "$(cat "$CMD_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$CMD_LOCK/pid" 2>/dev/null
  rmdir "$CMD_LOCK" 2>/dev/null
}

# 平台适配门槛：
#   高通 —— 必须有 msm_performance 节点，否则无从下手，如实报「本机不支持」。
#   天玑 —— 必须有 cpufreq policy，否则同样不支持（极少见的阉割内核）。
# 两者都没有的机型不再空转：不开守护、不改频率；status 报 UNSUPPORTED，WebUI 据此提示。
UNSUPPORTED=
case "$PLATFORM" in
  mtk) if [ -z "$(mtk_policies)" ]; then
         UNSUPPORTED="本机没有可调的 CPU 频率策略（cpufreq policy），温控性能不可用"
       elif ! mtk_can_unpin; then
         # 没有可用的调频 governor：放开 min 后 powersave 会把频率压在最低档，
         # 比原厂钉在 1200000 还慢。宁可不做，也不做负优化。
         UNSUPPORTED="本机内核没有可用的调频策略（governor 仅 powersave），解除钉频会变成固定最低频，故不支持"
       fi ;;
  *)   [ -e "$FREQ" ] || UNSUPPORTED="本机没有高通 msm_performance 限频节点，温控性能不可用" ;;
esac
if [ -n "$UNSUPPORTED" ]; then
  case "$1" in
    status)
      echo "=== CPU 上限解除 ==="
      echo "平台：$PLATFORM"
      echo "状态：本机不支持"
      echo "UNSUPPORTED=1"
      echo "STATE_HINT=$UNSUPPORTED"
      exit 0 ;;
    stop|ensure|recover) cmd_recover; exit $? ;;
    observe) load_conf; cmd_observe "${2:-}" "${3:-1}"; exit $? ;;
    *) echo "本机不支持温控性能：$UNSUPPORTED"; exit 1 ;;
  esac
fi

case "${1:-}" in
  start|stop|apply|ensure|recover|"")
    if ! acquire_cmd_lock; then
      echo "另一个温控管理操作正在执行，请稍后重试"
      exit 1
    fi
    trap 'release_cmd_lock' EXIT
    ;;
esac

case "$1" in
  daemon) load_conf; daemon ;;
  ensure) cmd_ensure ;;
  start|"") cmd_start ;;
  stop)  cmd_stop ;;
  recover) cmd_recover ;;
  status) load_conf; cmd_status ;;
  apply) cmd_apply ;;
  tick)  load_conf; tick
         # 天玑没有 msm_performance 节点，回读那个路径会报错，按平台给不同的确认信息
         case "$PLATFORM" in
           mtk) k=0; for k in $(mtk_policies); do printf 'p%s=%s/%s ' "$k" "$(mtk_read "$k" scaling_max_freq)" "$(mtk_read "$k" scaling_governor)"; done; echo ;;
           *)   echo "tick done: $(cat "$FREQ" 2>/dev/null)" ;;
         esac ;;
  buildgames) build_game_list; echo "游戏名单 $(grep -c '' "$GAME_LIST_CACHE" 2>/dev/null) 个" ;;
  why)   load_conf; why_state ;;
  observe) load_conf; cmd_observe "${2:-}" "${3:-1}" ;;
  *) echo "用法：cpulimit.sh {start|stop|status|apply|tick|recover|observe [包名]}"; exit 1 ;;
esac
