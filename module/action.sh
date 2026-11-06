#!/system/bin/sh
# oplus-cloud-block - 手动执行（KernelSU 管理器的「操作」按钮）。
# 显示当前状态，并补上仍未禁用的项。

MODDIR=${0%/*}
LIST="$MODDIR/packages.txt"

echo "=== ColorOS 温控与云控 ==="
echo "清单：$LIST"
echo

if [ ! -f "$LIST" ]; then
  echo "错误：找不到清单文件"
  exit 1
fi

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
  #   com.example.pkg                    -> 禁用整个包
  #   com.example.pkg/com.example.Class  -> 只禁用该组件
  case "$entry" in
    */*) pkg=${entry%%/*} ;;
    *)   pkg=$entry ;;
  esac

  case "$INSTALLED" in
    *"package:$pkg"*)
      ;;
    *)
      printf '  %-30s 未安装\n' "$entry"
      missing=$((missing + 1))
      continue
      ;;
  esac

  # 组件级：包保持启用，只关这一个组件。
  # disable-user 对组件无效（返回 default 且不写入），必须用 disable。
  if [ "$pkg" != "$entry" ]; then
    if pm disable --user 0 "$entry" </dev/null >/dev/null 2>&1; then
      printf '  %-30s -> 已禁用组件\n' "${entry#*/}"
      changed=$((changed + 1))
    else
      printf '  %-30s -> 组件禁用失败\n' "${entry#*/}"
    fi
    continue
  fi

  case "$DISABLED" in
    *"package:$pkg"*)
      printf '  %-30s 已拦截\n' "$pkg"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  # </dev/null：pm 会继承本循环的 stdin（清单文件），
  # 不重定向会导致 binder 调用报 "Failed transaction"。
  if pm disable-user --user 0 "$pkg" </dev/null >/dev/null 2>&1; then
    printf '  %-30s -> 已禁用\n' "$pkg"
    changed=$((changed + 1))
  else
    printf '  %-30s -> 失败\n' "$pkg"
  fi
done <"$LIST"

echo
echo "本次新禁用：$changed | 原本已拦截：$skipped | 未安装：$missing"
echo
echo "恢复某个包：pm enable <包名>"
echo "恢复某个组件：pm enable <包名/类名>"

echo
if [ -f "$MODDIR/mem.sh" ]; then
  echo "=== 内存概览 ==="
  sh "$MODDIR/mem.sh" overview | while IFS='=' read -r k v; do
    case "$k" in
      MEMAVAIL_MB) printf '  可用内存 : %s MB\n' "$v" ;;
      MEMFREE_MB)  printf '  空闲     : %s MB\n' "$v" ;;
      ZRAM_MB)     printf '  zram 占用: %s MB\n' "$v" ;;
      PROCS)       printf '  进程数   : %s\n' "$v" ;;
      LOAD)        printf '  负载     : %s\n' "$v" ;;
    esac
  done
  echo "  一键清理：sh $MODDIR/mem.sh clean"
  echo
fi

echo
if [ -f "$MODDIR/cloudclean.sh" ]; then
  echo "=== 云控残留清理 ==="
  echo "查看残留：sh $MODDIR/cloudclean.sh status"
  echo "备份后清理（可完整回滚）：sh $MODDIR/cloudclean.sh clean"
  echo "回滚：sh $MODDIR/cloudclean.sh restore [快照名]"
fi

echo
if [ -f "$MODDIR/cpulimit.sh" ]; then
  sh "$MODDIR/cpulimit.sh" status 2>/dev/null | head -12
  echo
  echo "开关：sh $MODDIR/cpulimit.sh {start|stop}   配置：$MODDIR/cpulimit.conf"
fi
