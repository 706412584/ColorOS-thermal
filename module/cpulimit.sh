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
GAMEPID=/proc/game_opt/game_pid
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
TEMP=55000          # 触发收回的温度阈值，毫摄氏度。55000 = 55.0°C
ZONE=skin-msm-therm # 保护监视的温区。默认 skin-msm-therm（机身表面=体感温度）。
                    # 注意：不要用 shell_front —— 实测游戏满频时 shell_front 仅 39.7°C
                    # 而机身已 54°C，用它会形同虚设。
MODE=game           # global = 全局常开；game = 仅检测到游戏时开
HYST=3000           # 滞回，毫摄氏度。降到 TEMP-HYST 以下才恢复，防震荡

load_conf() {
  [ -f "$CONF" ] || return 0
  while IFS= read -r raw; do
    line=${raw%%#*}
    key=$(printf '%s' "$line" | cut -d= -f1 | tr -d ' \t\r\n')
    val=$(printf '%s' "$line" | cut -d= -f2- | sed 's/^[ \t]*//; s/[ \t]*$//')
    case "$key" in
      ENABLE) [ -n "$val" ] && ENABLE=$val ;;
      TEMP)   [ -n "$val" ] && TEMP=$val ;;
      ZONE)   [ -n "$val" ] && ZONE=$val ;;
      MODE)   [ -n "$val" ] && MODE=$val ;;
      HYST)   [ -n "$val" ] && HYST=$val ;;
    esac
  done <"$CONF"
}

# ---- 原值备份 ----
ensure_backup() {
  [ -f "$BAK" ] && return 0
  mkdir -p "$DATA" 2>/dev/null
  cat "$FREQ" >"$BAK" 2>/dev/null
  [ -f "$BAK" ] && log "已备份出厂上限 -> $BAK"
}

# 读取备份原值（剥尾部空白；若缺失用出厂兜底）
orig_value() {
  if [ -f "$BAK" ]; then
    sed 's/[[:space:]]*$//' "$BAK" 2>/dev/null
  else
    printf '%s' "$FACTORY"
  fi
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
game_opt_ok()  { [ "$(cat "$GAMEDIS" 2>/dev/null)" = "1" ]; }

# 只读锁是否在位（用权限位字符串判断，不依赖 -w —— root 下 -w 不可靠）
node_readonly() {
  case "$(ls -l "$FREQ" 2>/dev/null)" in
    -r--r--r--*) return 0 ;;
    *) return 1 ;;
  esac
}

is_unlocked() {
  v=$(cat "$FREQ" 2>/dev/null)
  case "$v" in *9999999*) return 0 ;; *) return 1 ;; esac
}

# ---- 温度 ----
find_zone() { # $1 = type 名
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = "$1" ] && { echo "${z##*thermal_zone}"; return; }
  done
}

# 保护温区读数（ZONE 指定，默认 skin-msm-therm）
shell_temp() {
  local zn; zn=$(find_zone "$ZONE")
  [ -n "$zn" ] && cat "/sys/class/thermal/thermal_zone$zn/temp" 2>/dev/null
}

# 读任意温区（按 type 名）
zone_temp() {
  local zn; zn=$(find_zone "$1")
  [ -n "$zn" ] && cat "/sys/class/thermal/thermal_zone$zn/temp" 2>/dev/null
}

# ---- 游戏检测 ----
# 注意：toybox 的 sed 不支持 `\?`（可选匹配），必须用 `[0-9-]*` 吞掉负号。
# 之前用 `\(-\?[0-9]*\)` 会导致模式失配、永远返回空 → 游戏检测永远为"无游戏"。
game_pid_val() {
  sed -n 's/.*game_pid=\([0-9-]*\).*/\1/p' "$GAMEPID" 2>/dev/null | head -1
}
# 系统实时游戏检测（game_pid 仅当游戏独占前台时才置位；切到 WebUI 时会归零）
sys_game() {
  local g; g=$(game_pid_val)
  [ -n "$g" ] && [ "$g" != "-1" ]
}
# ColorOS 已识别的游戏名单（两个来源，任一命中即算）：
#   ① /data/oplus/uxicons/<pkg>/game_app.png（游戏空间收录过）
#   ② settings 里的 GC_SETTING_SYSTEM_KEY_GAMESPACE_GAME_LAUNCH_TIME_<pkg>（启动过）
GAME_ICON_DIR=/data/oplus/uxicons
GAME_LIST_CACHE=/data/adb/oplus-cpulimit.games
build_game_list() {
  {
    for d in "$GAME_ICON_DIR"/*/; do
      [ -f "$d/game_app.png" ] && basename "$d"
    done 2>/dev/null
    settings list global 2>/dev/null \
      | sed -n 's/^GC_SETTING_SYSTEM_KEY_GAMESPACE_GAME_LAUNCH_TIME_\([a-zA-Z0-9._]*\)=.*/\1/p'
  } | sort -u >"$GAME_LIST_CACHE" 2>/dev/null
}
pkg_is_game() { # $1 = 包名
  [ -n "$1" ] || return 1
  [ -f "$GAME_LIST_CACHE" ] || build_game_list
  grep -qxF "$1" "$GAME_LIST_CACHE" 2>/dev/null
}
# 综合判定（只看"游戏在不在跑"，不看前台 —— 否则在 WebUI 里查看时必然判为无游戏，形成悖论）：
#   ① 系统 game_pid 已置位（游戏独占前台时最快）
#   ② 名单内的游戏进程存在
game_running() {
  sys_game && return 0
  [ -f "$GAME_LIST_CACHE" ] || build_game_list
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if pidof "$pkg" >/dev/null 2>&1; then return 0; fi
  done <"$GAME_LIST_CACHE"
  return 1
}

# ---- 前台应用 ----
# 取当前前台包名。优先 dumpsys（准确），失败退回 /proc 里最活跃的 app 进程。
TOP_FILE=/data/adb/oplus-cpulimit.top
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
app_match() {
  local cur; cur=$(top_pkg)
  [ -n "$cur" ] || return 1
  printf '%s' "$cur" >"$TOP_FILE" 2>/dev/null
  app_selected "$cur"
}

# ---- 决策：现在应该解锁吗 ----
should_unlock() {
  local t; t=$(shell_temp)
  # 无温度读数 → 保守起见不解锁
  [ -n "$t" ] || return 1
  if [ "$t" -ge "$TEMP" ] 2>/dev/null; then
    return 1        # 过热，收回
  fi
  case "$MODE" in
    game) game_running ;;
    apps) app_match ;;
    *)    return 0 ;;   # global：温度 OK 即解锁
  esac
}

# 毫摄氏度 -> "xx.x°C"
mC() { awk -v v="$1" 'BEGIN{ if(v==""){print "?"; exit} printf "%.1f°C", v/1000 }'; }

# 说明"当前为何是/不是满频"，供 WebUI 显示（一行中文）
why_state() {
  local t; t=$(shell_temp)
  [ -n "$t" ] || { echo "读不到温度"; return; }
  if [ "$t" -ge "$TEMP" ] 2>/dev/null; then
    echo "机身 $(mC "$t") 已超阈值 $(mC "$TEMP")，已收回保护"; return
  fi
  case "$MODE" in
    game)
      if game_running; then echo "检测到游戏运行，已满频"
      else echo "待命 · 未检测到游戏运行"; fi ;;
    apps)
      local cur; cur=$(top_pkg)
      if [ -z "$cur" ]; then echo "待命 · 取不到前台应用"
      elif app_selected "$cur"; then echo "前台 $cur 已勾选，已满频"
      else echo "待命 · 前台 $cur 不在已选列表"; fi ;;
    *)
      echo "全局模式，已满频" ;;
  esac
}

# ---- 执行一次决策 ----
# 仅状态变化时才写+记日志，避免每次 tick 都刷屏（实测节点会被厂商抢写，
# 值对但只读锁丢了也要补锁）。
tick() {
  local t; t=$(shell_temp)
  if should_unlock; then
    if ! is_unlocked || ! node_readonly; then
      ensure_backup
      unlock_freq
      log "解锁（${ZONE} ${t} 模式 $MODE）"
    fi
    # 游戏场景的第二层上限：确保也被禁用（系统会反复重置，需每次补写）
    game_opt_ok || { enable_game; log "禁用游戏上限（game_pid=$(game_pid_val)）"; }
  else
    if is_unlocked; then
      restore_freq
      log "收回（${ZONE} ${t} 阈值 ${TEMP} 模式 $MODE game=$(game_running && echo Y || echo N)）"
    fi
    game_opt_ok && { disable_game; log "恢复游戏上限"; }
  fi
}

# ---- 守护 ----
list_daemons() {
  for p in /proc/[0-9]*; do
    cl=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
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

is_alive() {
  [ -f "$PIDFILE" ] || return 1
  p=$(cat "$PIDFILE" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
}

conf_sig() { cksum "$CONF" 2>/dev/null | awk '{print $1"-"$2}'; }

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
      ENABLE=1; TEMP=55000; ZONE=skin-msm-therm; MODE=game; HYST=3000
      load_conf
      if [ "$ENABLE" != "1" ]; then
        restore_freq; disable_game
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
  echo "配置：ENABLE=$ENABLE TEMP=${TEMP}($ZONE) MODE=$MODE HYST=$HYST"
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
  echo "$ZONE = $(shell_temp)   游戏运行中 = $(game_running && echo 是 || echo 否)"
  echo "SKIN_TEMP=$(zone_temp skin-msm-therm)"
  echo "SHELL_TEMP=$(zone_temp shell_front)"
  echo "STATE_HINT=$(why_state)"
}

cmd_start() {
  load_conf
  if [ "$ENABLE" != "1" ]; then echo "配置中 ENABLE!=1，未启动。"; exit 0; fi
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

cmd_stop() {
  stop_daemon
  restore_freq
  disable_game
  log "已停止并还原出厂上限（含游戏上限）"
  echo "已停止，出厂上限已还原：$(cat "$FREQ" 2>/dev/null)"
}

cmd_apply() {
  load_conf
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
    if is_alive; then stop_daemon; restore_freq; log "ensure：配置已关闭，还原并停止"; fi
    return 0
  fi
  is_alive && return 0
  log "ensure：守护不在，重新拉起"
  nohup sh "$0" daemon >/dev/null 2>&1 &
  sleep 1
}

case "$1" in
  daemon) load_conf; daemon ;;
  ensure) cmd_ensure ;;
  start|"") cmd_start ;;
  stop)  cmd_stop ;;
  status) load_conf; cmd_status ;;
  apply) cmd_apply ;;
  tick)  load_conf; tick; echo "tick done: $(cat "$FREQ")" ;;
  why)   load_conf; why_state ;;
  *) echo "用法：cpulimit.sh {start|stop|status|apply|tick}"; exit 1 ;;
esac
