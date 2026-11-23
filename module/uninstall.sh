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
  # stop 失败时再走一次统一事务恢复（含 daily 和 TID affinity）。
  sh "$MODDIR/cpulimit.sh" recover >/dev/null 2>&1
fi
# 兜底：杀掉残留守护
PIDFILE=/data/adb/oplus-cpulimit.pid
if [ -f "$PIDFILE" ]; then
  p=$(cat "$PIDFILE" 2>/dev/null)
  case "$p" in
    ''|*[!0-9]*) ;;
    *) case "$(tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline")" in
         *cpulimit.sh*daemon*) kill -9 "$p" 2>/dev/null ;;
       esac ;;
  esac
  rm -f "$PIDFILE" "$PIDFILE.start"
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
MTK_TXN=/data/adb/oplus-cloud-block-data/mtk.txn
if [ -s "$MTK_BAK" ] && { [ -f "$MTK_ON" ] || [ -f "$MTK_TXN" ]; }; then
  while IFS=' ' read -r k hw mn mx gv; do
    [ -n "$k" ] || continue
    [ -d "/sys/devices/system/cpu/cpufreq/policy$k" ] || continue
    [ -n "$gv" ] && printf '%s' "$gv" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_governor" 2>/dev/null
    case "$mx" in ''|*[!0-9]*) ;; *) printf '%s' "$mx" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_max_freq" 2>/dev/null ;; esac
    case "$mn" in ''|*[!0-9]*) ;; *) printf '%s' "$mn" >"/sys/devices/system/cpu/cpufreq/policy$k/scaling_min_freq" 2>/dev/null ;; esac
  done <"$MTK_BAK"
  rm -f "$MTK_ON" "$MTK_TXN"
fi

# 兜底：只有节点仍是"我们写的值"（完整解锁 9999999，或甜点档 = 每核硬件原生上限）
# 才复位。stop 没生效时的保险 —— 两种值都要认，否则甜点档会被漏掉。
# 优先写本机首次开启时备份的原值；没有有效备份才用 Ace 2 Pro 实测的出厂值
# —— 不能无条件写死值，别的机型的出厂档位不一样。
FREQ=/sys/kernel/msm_performance/parameters/cpu_max_freq
# 老内核（如 4.14）上同一个节点在 /sys/module 下
[ -e "$FREQ" ] || FREQ=/sys/module/msm_performance/parameters/cpu_max_freq
BAK=/data/adb/oplus-cloud-block-data/cpu_max_freq.orig
QCOM_ON=/data/adb/oplus-cloud-block-data/qcom.on
QCOM_TXN=/data/adb/oplus-cloud-block-data/qcom.txn
SWEETQ=""
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  m=$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
  [ -n "$m" ] && SWEETQ="$SWEETQ${SWEETQ:+ }${c##*cpu}:$m"
done
ours_qcom() {
  case "$1" in *9999999*) return 0 ;; esac
  [ -n "$SWEETQ" ] && [ "$1" = "$SWEETQ" ] && return 0
  return 1
}
if [ -e "$FREQ" ] && { [ -f "$QCOM_ON" ] || [ -f "$QCOM_TXN" ]; } && [ -s "$BAK" ] && ours_qcom "$(sed 's/[[:space:]]*$//' "$FREQ" 2>/dev/null)"; then
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
if ! ours_qcom "$(sed 's/[[:space:]]*$//' "$FREQ" 2>/dev/null)"; then
  rm -f "$QCOM_ON" "$QCOM_TXN"
fi
# 兜底：GPU 实验上限（stop 已用模块逻辑还原；这里按 conf 里的实验档补保险）。
# 只在"当前值恰为实验档"时写回出厂最高档；厂商温控正压着更低值时不动它。
GPU_MAXF=/sys/class/kgsl/kgsl-3d0/devfreq/max_freq
GPU_AVAIL=/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies
GPU_ON=/data/adb/oplus-cloud-block-data/gpu.on
GPU_TXN=/data/adb/oplus-cloud-block-data/gpu.txn
GPU_BAK=/data/adb/oplus-cloud-block-data/gpu_max.orig
GPUCAP=$(sed -n 's/^GAME_GPU_CAP=//p' "$MODDIR/cpulimit.conf" 2>/dev/null | tail -1)
if [ -f "$GPU_ON" ] && [ -e "$GPU_MAXF" ] && [ -n "$GPUCAP" ] && [ "$GPUCAP" != off ]; then
  cur=$(cat "$GPU_MAXF" 2>/dev/null)
  bak=$(cat "$GPU_BAK" 2>/dev/null)
  case "$bak" in ''|*[!0-9]*)
    bak=$(printf '%s\n' $GPU_AVAIL 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  esac
  if [ "$cur" = "$GPUCAP" ] && [ -n "$bak" ]; then
    printf '%s' "$bak" > "$GPU_MAXF" 2>/dev/null
  fi
fi
rm -f "$GPU_ON" "$GPU_TXN"
GAME_ON=/data/adb/oplus-cloud-block-data/game_opt.on
GAME_PREV=/data/adb/oplus-cloud-block-data/game_opt.orig
if [ -f "$GAME_ON" ]; then
  orig=0
  [ -f "$GAME_PREV" ] && read -r orig <"$GAME_PREV"
  case "$orig" in 0|1) printf '%s' "$orig" > /proc/game_opt/disable_cpufreq_limit 2>/dev/null ;; esac
  rm -f "$GAME_ON" "$GAME_PREV"
fi
rm -f /data/adb/oplus-cpulimit.hot /data/adb/oplus-cpulimit.top

# 日志随模块删除（备份数据目录保留，含 CPU 原值与云控快照，便于重装后回滚）
rm -f "$LOG"
exit 0
