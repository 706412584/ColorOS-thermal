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

# 一次性迁移（v1.7.11）：旧版发布包默认禁用 com.oplus.pantanal.ums，会让桌面/主题卡片、流体云不显示。
# 新版默认不拦截它。本模块平时从不主动启用包，所以升级上来的用户它仍是禁用状态，这里恢复一次。
# 条件：当前被禁用 且 清单里没有它（用户在 WebUI 里主动勾选拦截的不动）。做完写标记，只执行一次。
MIG=/data/adb/oplus-cloud-block-data/migrate-1.7.11-pantanal.done
if [ ! -f "$MIG" ]; then
  P=com.oplus.pantanal.ums
  case "$DISABLED" in
    *"package:$P"*)
      # 只看去掉注释后的有效行（toybox grep 不支持 \| 交替，用 sed 先剥注释再整行匹配）
      if ! sed 's/#.*//; s/[[:space:]]//g' "$LIST" 2>/dev/null | grep -qxF "$P"; then
        if pm default-state --user 0 "$P" </dev/null >/dev/null 2>&1 \
           || pm enable --user 0 "$P" </dev/null >/dev/null 2>&1; then
          log "迁移：已恢复 $P（桌面卡片云配置，新版默认不拦截）"
          DISABLED=$(pm list packages -d --user 0 2>/dev/null)
        else
          log "迁移：恢复 $P 失败"
        fi
      fi ;;
  esac
  mkdir -p "${MIG%/*}" && : >"$MIG"
fi

changed=0
skipped=0
missing=0
comps=0

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
    # pm disable 对组件是幂等的，无法区分「新禁用」和「原本就禁用」，单独计数
    if pm disable --user 0 "$entry" </dev/null >/dev/null 2>&1; then
      comps=$((comps + 1))
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

log "---- 完成：新禁用=$changed 原本已禁用=$skipped 组件已确认禁用=$comps 未安装=$missing ----"

# 重新读取，报告当前实际禁用的总数
FINAL=$(pm list packages -d --user 0 2>/dev/null | grep -c 'package:' 2>/dev/null)
log "当前用户 0 已禁用包总数：${FINAL:-未知}"

# 4. 启动 CPU 上限解除守护（若 cpulimit.conf 中 ENABLE=1）
#    解除的是 /sys/kernel/msm_performance/parameters/cpu_max_freq 这个出厂上限
#    （大核被压到 1843200=硬件 58%），以及游戏场景的 /proc/game_opt 上限。
#    写入立即生效、无需重启。守护内含温度保护：按 skin-msm-therm(机身) 判定，
#    超阈值自动收回，降温后恢复。
if [ -f "$MODDIR/cpulimit.sh" ]; then
  # 用 ensure 而不是 start：start 会强制写 ENABLE=1，会把用户在 WebUI 里关掉的功能重新打开
  log "CPU 上限解除：按配置检查启动"
  sh "$MODDIR/cpulimit.sh" ensure >/dev/null 2>&1
fi

# 5. 游戏记录守护（开关在数据目录的 gamerec.off，WebUI 可切换）
if [ -f "$MODDIR/gamerec.sh" ]; then
  log "游戏记录：按开关检查启动"
  sh "$MODDIR/gamerec.sh" ensure >/dev/null 2>&1
fi

# 6. 保持 USB 调试 / 无线调试（WebUI 开关，默认关；开关文件在数据目录）
[ -f "$MODDIR/adbkeep.sh" ] && sh "$MODDIR/adbkeep.sh" check >/dev/null 2>&1

# 看护循环：每 120s 检查两个守护是否还在；保持 USB 调试打开时每 15s 查一次 adb 开关
# （开关没开时只是一次 [ -f ] 判断，不 fork）
if [ ! -f "$MODDIR/no_watchdog" ]; then
  (
    trap 'exit 0' TERM INT
    n=0
    while :; do
      sleep 15
      n=$((n + 1))
      if [ -f /data/adb/oplus-cloud-block-data/adbkeep.on ] || [ -f /data/adb/oplus-cloud-block-data/adbkeep.wifi ]; then
        sh "$MODDIR/adbkeep.sh" check >/dev/null 2>&1
      fi
      [ $((n % 8)) -eq 0 ] || continue
      [ -f "$MODDIR/cpulimit.sh" ] && sh "$MODDIR/cpulimit.sh" ensure >/dev/null 2>&1
      [ -f "$MODDIR/gamerec.sh" ] && sh "$MODDIR/gamerec.sh" ensure >/dev/null 2>&1
    done
  ) &
  log "看护循环已启动（守护每 120s 检查一次）"
fi
