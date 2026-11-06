#!/system/bin/sh
# oplus-cloud-block - 撤销模块全部改动：解除本模块对系统做过的所有拦截
#
# 用法：sh restore.sh
#
# 做的事（只"恢复"，不删除任何数据）：
#   1. 把模块历史上禁用过的所有包和组件恢复成出厂默认状态（含旧版本的 MspCoreProvider）
#   2. 清空 packages.txt 的拦截项（先备份），重启后不会再被禁用
#   3. 关闭 CPU 上限解除并还原出厂上限
# 不做的事：
#   不 pm clear、不删 htms 数据、不重启。云控残留清理有自己的快照，需要时在 WebUI「回滚最近一次」。
#
# 适用：登录异常、桌面卡片/流体云不显示等，怀疑和本模块有关时。

MODDIR=${0%/*}
LIST="$MODDIR/packages.txt"
DATA=/data/adb/oplus-cloud-block-data
LOG=/data/adb/oplus-cloud-block.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [撤销全部改动] $*" >>"$LOG"; }

# 模块所有版本拦截过的全部条目（WebUI 清单 + 旧版本出现过的组件）
ALL='com.oplus.ota
com.oplus.romupdate
com.oplus.cota
com.oplus.sau
com.oplus.sauhelper
com.heytap.htms/com.heytap.msp.cloudctrl.ipc.CloudCtrlService
com.heytap.htms/com.heytap.cloudconfig.v3.kit.ipc.CloudCtrlV3Service
com.heytap.htms/com.heytap.msp.cloudctrlreport.service.CloudConfigReportService
com.heytap.htms/com.heytap.msp.v2.ipcchannel.provider.MspCoreProvider
com.oplus.statistics.rom
com.oplus.pantanal.ums
com.oplus.metis
com.heytap.mcs
com.heytap.openid
com.heytap.cloud
com.oplus.athena
com.oplus.obrain
com.oplus.atlas
com.oplus.deepthinker
com.oplus.apprecover
com.oplus.exsystemservice
com.oplus.olc
com.oplus.owkservice
com.heytap.tas
com.oplus.beaconlink'

echo "=== 撤销模块全部改动 ==="
log "开始"

# 清单里用户自己加的条目也一并恢复
if [ -f "$LIST" ]; then
  extra=$(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$LIST")
  ALL="$ALL
$extra"
fi

INSTALLED=$(pm list packages --user 0 2>/dev/null)
ok=0; skip=0
for e in $(printf '%s\n' "$ALL" | sort -u); do
  pkg=${e%%/*}
  case "$INSTALLED" in *"package:$pkg"*) ;; *) skip=$((skip + 1)); continue ;; esac
  # default-state = 恢复成出厂时的状态（不是强制启用）：系统本来就关着的组件不会被误开。
  # 老系统没有 default-state 时退回 pm enable。
  if pm default-state --user 0 "$e" </dev/null >/dev/null 2>&1      || pm enable --user 0 "$e" </dev/null >/dev/null 2>&1; then
    printf '  已启用 %s\n' "$e"; ok=$((ok + 1))
  else
    printf '  失败   %s\n' "$e"
  fi
done
echo "启用 $ok 项（未安装跳过 $skip 项）"
log "启用 $ok 项"

# 清单清空前备份，重启后 service.sh 不会再禁用
if [ -f "$LIST" ]; then
  mkdir -p "$DATA"
  b="$DATA/packages.txt.before-restore-$(date +%Y%m%d-%H%M%S)"
  cp -p "$LIST" "$b"
  {
    echo "# 已执行「撤销模块全部改动」（$(date '+%Y-%m-%d %H:%M:%S')），清单已清空。"
    echo "# 原清单备份：$b"
    echo "# 想重新拦截：在 WebUI 里勾选并点「应用」。"
  } >"$LIST"
  echo "拦截清单已清空，原清单备份在：$b"
fi

if [ -f "$MODDIR/cpulimit.sh" ]; then
  sh "$MODDIR/cpulimit.sh" stop
fi

echo
echo "完成。账号登录异常的话：打开 设置 → 账号，重新登录一次。"
log "完成"
