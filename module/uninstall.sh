#!/system/bin/sh
# oplus-cloud-block - 卸载钩子。
#
# 1) 停掉 CPU 上限解除守护，并还原出厂上限（必须做！否则卸载后设备会一直满频、
#    且失去温度保护，长期有烫手/过热风险）。同时把游戏场景的 disable_cpufreq_limit 复位。
# 2) 刻意不自动恢复被禁用的包：重启后 ROM 可能已合法启用其中一部分，
#    静默把 OTA 重新打开比保持禁用更糟。需要时请手动恢复：
#
#   for p in $(grep -v '^#' /data/adb/modules/oplus-cloud-block/packages.txt); do
#     pm enable "${p%% *}"
#   done

MODDIR=${0%/*}
LOG=/data/adb/oplus-cloud-block.log

# --- 还原 CPU 上限 ---
# 优先用模块自带的 stop（内含精确还原 + 撤销 chmod 444 锁）
if [ -x "$MODDIR/cpulimit.sh" ]; then
  sh "$MODDIR/cpulimit.sh" stop >/dev/null 2>&1
fi
# 兜底：杀掉残留守护
PIDFILE=/data/adb/oplus-cpulimit.pid
if [ -f "$PIDFILE" ]; then
  kill -9 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
  rm -f "$PIDFILE"
fi
for r in 1 2 3; do
  pids=""
  for p in /proc/[0-9]*; do
    cl=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
    case "$cl" in *cpulimit.sh*daemon*) pids="$pids ${p#/proc/}" ;; esac
  done
  [ -z "$pids" ] && break
  kill -9 $pids 2>/dev/null
  sleep 0.3
done
# 兜底：即使 stop 失败，也把节点复位（chmod 644 + 写出厂值）
FREQ=/sys/kernel/msm_performance/parameters/cpu_max_freq
if [ -e "$FREQ" ]; then
  chmod 644 "$FREQ" 2>/dev/null
  printf '%s' "0:1900800 1:1900800 2:1900800 3:2323200 4:2323200 5:2323200 6:2323200 7:1843200" > "$FREQ" 2>/dev/null
fi
printf '0' > /proc/game_opt/disable_cpufreq_limit 2>/dev/null

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 模块已卸载：CPU 上限已还原，游戏上限已复位，各包保持当前状态" >>"$LOG"
rm -f "$LOG"
exit 0
