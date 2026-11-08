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

# --- 停游戏记录守护（记录文件在数据目录，保留）---
[ -f "$MODDIR/gamerec.sh" ] && sh "$MODDIR/gamerec.sh" stop >/dev/null 2>&1
for p in /proc/[0-9]*; do
  case "$(tr '\0' ' ' 2>/dev/null <"$p/cmdline")" in *gamerec.sh*daemon*) kill -9 "${p#/proc/}" 2>/dev/null ;; esac
done
rm -f /data/adb/oplus-gamerec.pid

# --- 还原 CPU 上限 ---
# 优先用模块自带的 stop（内含精确还原 + 撤销 chmod 444 锁）
if [ -f "$MODDIR/cpulimit.sh" ]; then
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
    cl=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline") || continue
    case "$cl" in *cpulimit.sh*daemon*) pids="$pids ${p#/proc/}" ;; esac
  done
  [ -z "$pids" ] && break
  kill -9 $pids 2>/dev/null
  sleep 0.3
done
# 兜底：天玑机型没有集中节点，按备份的天玑频率表逐 policy 还原（stop 已做过一次，
# 这里是"stop 没生效"时的保险）。备份不存在说明本模块从没解开过它，不动。
MTK_BAK=/data/adb/oplus-cloud-block-data/mtk_freq.orig
MTK_ON=/data/adb/oplus-cloud-block-data/mtk.on
if [ -s "$MTK_BAK" ] && [ -f "$MTK_ON" ]; then
  while IFS=' ' read -r k hw mn mx gv; do
    [ -n "$k" ] || continue
    [ -d "/sys/devices/system/cpu/cpufreq/policy$k" ] || continue
    [ -n "$gv" ] && printf '%s' "$gv" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_governor" 2>/dev/null
    case "$mx" in ''|*[!0-9]*) ;; *) printf '%s' "$mx" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_max_freq" 2>/dev/null ;; esac
    case "$mn" in ''|*[!0-9]*) ;; *) printf '%s' "$mn" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_min_freq" 2>/dev/null ;; esac
  done <"$MTK_BAK"
  rm -f "$MTK_ON"
fi

# 兜底：只有节点仍是解锁值（说明 stop 没生效）才复位。
# 优先写本机首次开启时备份的原值；没有有效备份才用 Ace 2 Pro 实测的出厂值
# —— 不能无条件写死值，别的机型的出厂档位不一样。
FREQ=/sys/kernel/msm_performance/parameters/cpu_max_freq
# 老内核（如 4.14）上同一个节点在 /sys/module 下
[ -e "$FREQ" ] || FREQ=/sys/module/msm_performance/parameters/cpu_max_freq
BAK=/data/adb/oplus-cloud-block-data/cpu_max_freq.orig
if [ -e "$FREQ" ] && grep -q 9999999 "$FREQ" 2>/dev/null; then
  ORIG=$(sed 's/[[:space:]]*$//' "$BAK" 2>/dev/null)
  case "$ORIG" in ''|*9999999*)
    if [ "$(getprop ro.product.model)" = PJA110 ]; then
      ORIG="0:1900800 1:1900800 2:1900800 3:2323200 4:2323200 5:2323200 6:2323200 7:1843200"
    else
      # 其他机型：每核硬件上限，不会把频率压到比出厂更低
      ORIG=""
      for c in /sys/devices/system/cpu/cpu[0-9]*; do
        m=$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$m" ] && ORIG="$ORIG${ORIG:+ }${c##*cpu}:$m"
      done
    fi ;;
  esac
  chmod 644 "$FREQ" 2>/dev/null
  printf '%s' "$ORIG" > "$FREQ" 2>/dev/null
fi
printf '0' > /proc/game_opt/disable_cpufreq_limit 2>/dev/null
rm -f /data/adb/oplus-cpulimit.hot /data/adb/oplus-cpulimit.top

# 日志随模块删除（备份数据目录保留，含 CPU 原值与云控快照，便于重装后回滚）
rm -f "$LOG"
exit 0
