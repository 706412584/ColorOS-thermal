#!/system/bin/sh
# oplus-cloud-block - 每次开机重新应用禁用清单。
#
# 在 late_start 阶段运行。此时 PackageManager 可能尚未就绪，
# 因此先等待 boot_completed，再轮询直到 pm 可用。
#
# 行为约定：
#   - 幂等：已禁用的包保持不动
#   - 未安装的包静默跳过（清单可跨 ROM 版本共用）
#   - 从不主动启用任何包，只会调用 disable-user

MODDIR=${0%/*}
LIST="$MODDIR/packages.txt"
LOG=/data/adb/oplus-cloud-block.log
BOOT_TIMEOUT=180
PM_TIMEOUT=120

# 限制日志体积（单次轮转）
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
  tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }

log "---- 开机自检开始（内核 $(uname -r)）----"

if [ ! -f "$LIST" ]; then
  log "错误：找不到清单文件 $LIST"
  exit 1
fi

# 1. 等待开机完成
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  i=$((i + 1))
  [ "$i" -ge "$BOOT_TIMEOUT" ] && { log "错误：等待开机完成超时（${BOOT_TIMEOUT}s）"; exit 1; }
  sleep 1
done
log "开机完成，等待 ${i}s"

# 2. 等待 PackageManager 响应
i=0
while ! pm list packages >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge "$PM_TIMEOUT" ] && { log "错误：PackageManager 在 ${PM_TIMEOUT}s 内不可用"; exit 1; }
  sleep 1
done

# 3. 一次性快照当前状态，避免每个包都调用一次 pm
INSTALLED=$(pm list packages --user 0 2>/dev/null)
DISABLED=$(pm list packages -d --user 0 2>/dev/null)

changed=0
skipped=0
missing=0

while IFS= read -r raw || [ -n "$raw" ]; do
  line=${raw%%#*}
  entry=$(printf '%s' "$line" | tr -d ' \t\r\n')
  [ -n "$entry" ] || continue

  # 清单行支持两种形式：
  #   com.example.pkg                         -> 禁用整个包（pm disable-user）
  #   com.example.pkg/com.example.Class       -> 只禁用该组件（pm disable）
  # 组件级用于那些「云控和账号/支付共用同一个包」的情况，禁包会连带毁掉
  # 登录/支付；只关云控通道即可。
  case "$entry" in
    */*) pkg=${entry%%/*} ;;
    *)   pkg=$entry ;;
  esac

  case "$INSTALLED" in
    *"package:$pkg"*)
      ;;
    *)
      log "跳过（未安装）：$pkg"
      missing=$((missing + 1))
      continue
      ;;
  esac

  # 组件级：包本身保持启用，只关单个组件。
  # 注意 disable-user 对组件无效（返回 default，不写入），必须用 disable。
  if [ "$pkg" != "$entry" ]; then
    if pm disable --user 0 "$entry" </dev/null >/dev/null 2>&1; then
      log "已禁用组件：$entry"
      changed=$((changed + 1))
    else
      log "错误：禁用组件失败 $entry"
    fi
    continue
  fi

  case "$DISABLED" in
    *"package:$pkg"*)
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  # 必须重定向 </dev/null：pm 会继承循环的 stdin（即清单文件），
  # 当 stdin 不是 tty/管道时 binder 调用会报 "Failed transaction"。
  if pm disable-user --user 0 "$pkg" </dev/null >/dev/null 2>&1; then
    log "已禁用：$pkg"
    changed=$((changed + 1))
  else
    log "错误：禁用失败 $pkg"
  fi
done <"$LIST"

log "---- 完成：新禁用=$changed 原本已禁用=$skipped 未安装=$missing ----"

# 重新读取，报告当前实际禁用的总数
FINAL=$(pm list packages -d --user 0 2>/dev/null | grep -c 'package:' 2>/dev/null)
log "当前用户 0 已禁用包总数：${FINAL:-未知}"

# 4. 启动 CPU 上限解除守护（若 cpulimit.conf 中 ENABLE=1）
#    解除的是 /sys/kernel/msm_performance/parameters/cpu_max_freq 这个出厂上限
#    （大核被压到 1843200=硬件 58%），以及游戏场景的 /proc/game_opt 上限。
#    写入立即生效、无需重启。守护内含温度保护：按 skin-msm-therm(机身) 判定，
#    超阈值自动收回，降温后恢复。
if [ -x "$MODDIR/cpulimit.sh" ]; then
  log "启动 CPU 上限解除守护"
  OUT=$(sh "$MODDIR/cpulimit.sh" start 2>&1)
  log "CPU上限：$OUT"

  if [ ! -f "$MODDIR/no_watchdog" ]; then
    (
      trap 'exit 0' TERM INT
      while :; do
        sleep 120
        sh "$MODDIR/cpulimit.sh" ensure >/dev/null 2>&1
      done
    ) &
    log "CPU上限看护循环已启动（每 120s 检查一次）"
  fi
fi
