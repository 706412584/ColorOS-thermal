#!/system/bin/sh
# oplus-cloud-block - 手动执行（root 管理器的「运行/操作」按钮）。
# 显示当前状态，并补上仍未禁用的项。

MODDIR=${0%/*}
LIST="$MODDIR/packages.txt"
CONF="$MODDIR/cpulimit.conf"
CPU="$MODDIR/cpulimit.sh"

# 黑名单模式：Magisk 进数字菜单；现代/未知管理器不再因白名单缺失被误判为无 WebUI。
# KernelSU Next 的显式组件和 extras 来自其 Shortcut.kt；exported=false，失败时回退管理器首页。
if [ "${1:-}" != "--menu" ]; then
  if pm path com.rifsxd.ksunext </dev/null >/dev/null 2>&1; then
    if am start -a android.intent.action.VIEW -d "kernelsu://webui/oplus-cloud-block" \
      -n "com.rifsxd.ksunext/com.rifsxd.ksunext.ui.webui.WebUIActivity" \
      --es id oplus-cloud-block --es name "ColorOS 温控与云控" --ez from_webui_shortcut true >/dev/null 2>&1; then
      echo "已请求 KernelSU Next 打开本模块 WebUI。"
      exit 0
    fi
  fi

  # 已核实带 WebUI 的管理器：官方 KSU、KSU Next、SukiSU Nova/旧 Ultra、FinaSU、
  # BakaSU/ReSukiSU、APatch、MMRL。只拉起首页，不盲试带 token 的内部 URI。
  webui_manager=""
  for pkg in com.rifsxd.ksunext me.weishu.kernelsu com.sukisu.nova com.sukisu.ultra \
    me.yuki.fina com.resukisu.resukisu me.bmax.apatch com.dergoogler.mmrl; do
    if pm path "$pkg" </dev/null >/dev/null 2>&1; then
      if monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
        webui_manager=$pkg
        break
      fi
    fi
  done
  if [ -n "$webui_manager" ]; then
    echo "已拉起支持 WebUI 的管理器：$webui_manager"
    echo "请进入本模块页面，点击 WebUI 调整温控性能。"
    exit 0
  fi

  # 新 fork 未列出包名时，按现代 WebUI 环境处理；保留强制终端菜单作为逃生口。
  if command -v ksud >/dev/null 2>&1 || command -v apd >/dev/null 2>&1 || [ -x /data/adb/apd ]; then
    echo "检测到 KernelSU/APatch 环境，请在本模块页面打开 WebUI。"
    echo "若当前管理器没有 WebUI，请执行：sh $MODDIR/action.sh --menu"
    exit 0
  fi
  if [ ! -d /data/adb/magisk ] && { ! command -v magisk >/dev/null 2>&1 || ! magisk --version >/dev/null 2>&1; }; then
    echo "未识别为 Magisk，按 WebUI 管理器处理。请在本模块页面打开 WebUI。"
    echo "若当前管理器没有 WebUI，请执行：sh $MODDIR/action.sh --menu"
    exit 0
  fi
fi

echo "=== ColorOS 温控与云控 · 终端数字菜单 ==="
echo "当前为 Magisk/终端环境，或通过 --menu 强制进入。"
echo
if [ -f "$CONF" ]; then
  cur_enable=$(sed -n 's/^ENABLE=//p' "$CONF" | tail -n 1)
  cur_mode=$(sed -n 's/^MODE=//p' "$CONF" | tail -n 1)
  echo "当前：ENABLE=${cur_enable:-1} MODE=${cur_mode:-game}"
fi
cat <<'MENU'
  1  仅游戏（推荐）
  2  全局常开
  3  指定应用（使用 cpulimit.apps）
  4  关闭温控并还原
  5  应用云控拦截清单
  0  退出（不做修改）
MENU
printf '请输入数字：'
if ! read -r choice; then
  echo
  echo "未读到输入，未做修改。"
  exit 2
fi

case "$choice" in
  1|2|3)
    [ "$choice" = 1 ] && new_mode=game
    [ "$choice" = 2 ] && new_mode=global
    [ "$choice" = 3 ] && new_mode=apps
    [ -f "$CPU" ] && [ -f "$CONF" ] || { echo "温控性能文件缺失，未做修改。"; exit 1; }
    if [ "$new_mode" = apps ] && { [ ! -f "$MODDIR/cpulimit.apps" ] || ! grep -q '[^[:space:]]' "$MODDIR/cpulimit.apps"; }; then
      echo "cpulimit.apps 为空，请先在文件里每行写一个包名。"
      exit 1
    fi
    if sh "$CPU" status 2>/dev/null | grep -q '^UNSUPPORTED=1$'; then
      echo "本机不支持温控性能，未做修改。"
      exit 1
    fi
    tmp="$CONF.action.tmp"
    sed -e 's/^ENABLE=.*/ENABLE=1/' -e "s/^MODE=.*/MODE=$new_mode/" "$CONF" >"$tmp" || exit 1
    grep -q '^ENABLE=' "$tmp" || printf '%s\n' 'ENABLE=1' >>"$tmp"
    grep -q '^MODE=' "$tmp" || printf '%s\n' "MODE=$new_mode" >>"$tmp"
    mv -f "$tmp" "$CONF" && sh "$CPU" apply
    exit $? ;;
  4)
    [ -f "$CPU" ] || { echo "温控性能脚本缺失，未做修改。"; exit 1; }
    sh "$CPU" stop
    exit $? ;;
  5) echo "继续应用云控拦截清单。" ;;
  0) echo "已退出，未做修改。"; exit 0 ;;
  *) echo "无效输入：$choice，未做修改。"; exit 1 ;;
esac

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
