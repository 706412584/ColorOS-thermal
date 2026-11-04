#!/system/bin/sh
# oplus-cloud-block - 云控残留清理工具（强制先备份，可完整回滚）
#
# 用法：
#   sh cloudclean.sh status              查看当前云控残留文件
#   sh cloudclean.sh backup [标签]       只备份，不动任何文件
#   sh cloudclean.sh clean  [--deep]     备份 → 校验 → 清理（备份不成功就不删）
#   sh cloudclean.sh list                列出所有快照
#   sh cloudclean.sh verify [快照名]     逐个文件校验 sha256
#   sh cloudclean.sh restore [快照名]    从快照恢复（默认最新），恢复前会先把现状也备份一份
#
# 设计约束：
#   1. clean 一定先 backup 且 verify 通过才动手；任何一步失败即中止，不删任何文件。
#   2. 只动 shared_prefs 下的云控白名单，绝不触碰 databases/、files/、账号与支付相关 prefs。
#   3. restore 会把 uid/gid/mode/SELinux 上下文一并还原（上下文含本机 per-app 类别号 c151，
#      从备份里读，不写死）。
#   4. 删除/恢复前 force-stop 宿主进程，否则内存里的值会回写覆盖。

set -f  # 关 glob：目标文件名含 ? 会被当通配符

DATA=/data/adb/oplus-cloud-block-data
BK=$DATA/backup
PKG=com.heytap.htms
SP=/data/data/$PKG/shared_prefs
LOG=/data/adb/oplus-cloud-block.log

# 默认清理清单：云控通道自身的配置与计数。
# 刻意排除：
#   auth_config.xml / en_session_key_info.xml / alipay_* / $oplus_pay_*
#   com.*.nearme.gamecenter*.xml / drs_*
#   msp_ipc_rate_limit_strategy?@?*:{keychain,kit_pay,servicelocation,kit_hlog}
# 那些是账号、支付、游戏联运、存储治理，删了会毁登录。
TARGETS='CloudClient.xml
cloud_ctrl_pilot_dual_run.xml
cloudctrl_monitor.xml
cloudctrl_monitor_meta.xml
cloudctrl_sdk_metrics_scheduler.xml
cloudctrl_v3_readback_config.xml
gateway_command.xml
dcc_sp.xml
kit_update_controller.xml
msp_ipc_rate_limit_strategy?@?com.heytap.htms.xml
msp_ipc_rate_limit_strategy?@?com.heytap.htms:cloud_control_report.xml
msp_ipc_rate_limit_strategy?@?com.heytap.htms:kit_sync_load.xml'

# 深度清理（--deep 才动）：预下载频率统计，含大量游戏条目，删了只是重置计数
DEEP_TARGETS='com.cloudclient.predownload.xml'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cloudclean] $*" >>"$LOG" 2>/dev/null; }

# 文件名含 ? 与 :，备份时转成安全名，避免 glob / 引号 / cp 的各种坑
safe_name() { printf '%s' "$1" | sed 's/?/_Q_/g; s/:/_C_/g'; }

# 从快照 manifest 里取出某备份名对应的原名（restore 后无法反推，只能查表）
# manifest 行格式：原名|备份名|sha256|uid|gid|mode|context|size

snap_list() {
  [ -d "$BK" ] || return 0
  # 注意：脚本顶部有 set -f（关 glob，防止文件名里的 ? 被当通配符），
  # 所以这里不能用 "$BK"/* 展开，改成 ls 逐项拼路径。
  for name in $(ls -1 "$BK" 2>/dev/null); do
    d="$BK/$name"
    [ -d "$d" ] || continue
    n=$(wc -l <"$d/manifest.txt" 2>/dev/null || echo 0)
    s=$(du -sk "$d" 2>/dev/null | cut -f1)
    printf '  %-32s %3s 个文件  %6s KB\n' "$name" "$n" "${s:-?}"
  done
}

latest_snap() {
  ls -1 "$BK" 2>/dev/null | sort | tail -1
}

# 取某快照的 info 行
snap_info() {
  [ -f "$1/info.txt" ] && sed -n 's/^/    /p' "$1/info.txt"
}

# ---------- backup ----------
# 注意：toybox sh 的函数变量是全局的（没有 local），
# 所以每个函数都必须用自己的变量名前缀，否则会踩掉调用方的值。
# 这里统一用 bsnap / vsnap / rsnap，只有 SNAP 是刻意对外输出的。
do_backup() {
  tag=${1:-manual}
  ts=$(date '+%Y%m%d-%H%M%S')
  bsnap="$BK/$ts-$tag"

  if [ ! -d "$SP" ]; then
    echo "错误：找不到 $SP（宿主包未安装或数据目录被清）"
    return 1
  fi

  mkdir -p "$bsnap/files" || { echo "错误：无法创建 $bsnap"; return 1; }

  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "tag=$tag"
    echo "device=$(getprop ro.product.model)"
    echo "rom=$(getprop ro.build.display.id)"
    echo "android=$(getprop ro.build.version.release)"
    echo "htms_uid=$(stat -c '%u' "/data/data/$PKG" 2>/dev/null)"
    echo "htms_dir_ctx=$(stat -c '%C' "/data/data/$PKG" 2>/dev/null)"
  } >"$bsnap/info.txt"

  : >"$bsnap/manifest.txt"

  list="$TARGETS"
  [ "$DEEP" = "1" ] && list="$TARGETS
$DEEP_TARGETS"

  n=0
  miss=0
  for name in $list; do
    src="$SP/$name"
    if [ ! -f "$src" ]; then
      miss=$((miss + 1))
      continue
    fi

    sname=$(safe_name "$name")
    if ! cp -p "$src" "$bsnap/files/$sname" 2>/dev/null; then
      echo "错误：复制失败 $name"
      return 1
    fi

    h1=$(sha256sum "$src" 2>/dev/null | cut -d' ' -f1)
    h2=$(sha256sum "$bsnap/files/$sname" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$h1" ] || [ "$h1" != "$h2" ]; then
      echo "错误：备份校验不一致 $name"
      return 1
    fi

    info=$(stat -c '%u %g %a %C' "$src" 2>/dev/null)
    uid=${info%% *}; rest=${info#* }
    gid=${rest%% *};  rest=${rest#* }
    mode=${rest%% *}; ctx=${rest#* }
    size=$(stat -c '%s' "$src" 2>/dev/null)

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$name" "$sname" "$h1" "$uid" "$gid" "$mode" "$ctx" "$size" >>"$bsnap/manifest.txt"
    n=$((n + 1))
    printf '  备份 %-62s %6s B\n' "$name" "$size"
  done

  if [ "$n" -eq 0 ]; then
    echo "没有可备份的目标文件（可能已经清理过，或宿主数据目录不存在）"
    rmdir "$bsnap/files" "$bsnap" 2>/dev/null
    return 1
  fi

  echo
  echo "已备份 $n 个文件 -> $bsnap（跳过 $miss 个不存在的）"
  log "备份 $n 个文件 -> $bsnap"
  SNAP=$bsnap
  return 0
}

# ---------- verify ----------
do_verify() {
  vsnap=$1
  [ -n "$vsnap" ] || vsnap=$(latest_snap)
  [ -n "$vsnap" ] || { echo "没有可用快照"; return 1; }
  case "$vsnap" in /*) ;; *) vsnap="$BK/$vsnap" ;; esac
  [ -d "$vsnap" ] || { echo "错误：快照不存在 $vsnap"; return 1; }

  vok=0; vbad=0
  while IFS='|' read -r name sname hash uid gid mode ctx size; do
    [ -n "$name" ] || continue
    f="$vsnap/files/$sname"
    if [ ! -f "$f" ]; then
      printf '  缺失 %s\n' "$name"; vbad=$((vbad + 1)); continue
    fi
    h=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$h" = "$hash" ]; then
      vok=$((vok + 1))
    else
      printf '  损坏 %s（期望 %s 实际 %s）\n' "$name" "$hash" "$h"; vbad=$((vbad + 1))
    fi
  done <"$vsnap/manifest.txt"

  echo "校验结果：完好 $vok 个，异常 $vbad 个"
  [ "$vbad" -eq 0 ] && return 0 || return 1
}

# ---------- clean ----------
do_clean() {
  echo "=== 1. 备份 ==="
  do_backup "preclean" || { echo; echo "备份失败，已中止，未删除任何文件。"; return 1; }
  csnap=$SNAP

  echo
  echo "=== 2. 校验备份 ==="
  do_verify "$csnap" || { echo; echo "备份校验不通过，已中止，未删除任何文件。"; return 1; }

  echo
  echo "=== 3. 停止宿主进程 ==="
  am force-stop "$PKG" >/dev/null 2>&1
  sleep 1
  left=$(ps -A -o NAME 2>/dev/null | grep -c "^$PKG")
  echo "剩余 $PKG 进程：${left:-0}"

  echo
  echo "=== 4. 删除 ==="
  d=0; f=0
  while IFS='|' read -r name sname hash uid gid mode ctx size; do
    [ -n "$name" ] || continue
    if rm -f "$SP/$name" 2>/dev/null; then
      printf '  已删除 %s\n' "$name"; d=$((d + 1))
    else
      printf '  失败   %s\n' "$name"; f=$((f + 1))
    fi
  done <"$csnap/manifest.txt"

  echo
  echo "删除 $d 个，失败 $f 个"
  echo "快照保留在：$csnap"
  echo "回滚：sh $(basename "$0") restore $(basename "$csnap")"
  log "清理：删除 $d 失败 $f，快照 $csnap"
}

# ---------- restore ----------
do_restore() {
  rsnap=$1
  [ -n "$rsnap" ] || rsnap=$(latest_snap)
  [ -n "$rsnap" ] || { echo "没有可用快照"; return 1; }
  case "$rsnap" in /*) ;; *) rsnap="$BK/$rsnap" ;; esac
  [ -d "$rsnap" ] || { echo "错误：快照不存在 $rsnap"; return 1; }

  echo "=== 目标快照 ==="
  snap_info "$rsnap"
  echo

  echo "=== 1. 校验快照 ==="
  do_verify "$rsnap" || { echo; echo "快照损坏，已中止。"; return 1; }

  echo
  echo "=== 2. 先把当前状态另存一份（便于再次回退）==="
  do_backup "prerestore" >/dev/null 2>&1 && echo "  已另存：$SNAP" || echo "  当前无可备份文件（跳过）"

  echo
  echo "=== 3. 停止宿主进程 ==="
  am force-stop "$PKG" >/dev/null 2>&1
  sleep 1
  echo "已 force-stop $PKG"

  echo
  echo "=== 4. 还原文件（含归属/权限/SELinux 上下文）==="
  rok=0; rbad=0
  while IFS='|' read -r name sname hash uid gid mode ctx size; do
    [ -n "$name" ] || continue
    src="$rsnap/files/$sname"
    dst="$SP/$name"

    if [ ! -f "$src" ]; then
      printf '  缺失 %s\n' "$name"; rbad=$((rbad + 1)); continue
    fi

    if ! cp -p "$src" "$dst" 2>/dev/null; then
      printf '  复制失败 %s\n' "$name"; rbad=$((rbad + 1)); continue
    fi

    chown "$uid:$gid" "$dst" 2>/dev/null
    chmod "$mode" "$dst" 2>/dev/null
    chcon "$ctx" "$dst" 2>/dev/null

    h=$(sha256sum "$dst" 2>/dev/null | cut -d' ' -f1)
    if [ "$h" = "$hash" ]; then
      printf '  已还原 %-62s %s:%s %s\n' "$name" "$uid" "$gid" "$mode"
      rok=$((rok + 1))
    else
      printf '  校验不符 %s\n' "$name"; rbad=$((rbad + 1))
    fi
  done <"$rsnap/manifest.txt"

  echo
  echo "还原 $rok 个，异常 $rbad 个"
  log "恢复：成功 $rok 异常 $rbad，来源 $(basename "$rsnap")"
}

# ---------- status ----------
do_status() {
  echo "=== 宿主 ==="
  if [ -d "/data/data/$PKG" ]; then
    echo "  数据目录存在"
    echo "  归属：$(stat -c '%u:%g' "/data/data/$PKG" 2>/dev/null)"
    echo "  上下文：$(stat -c '%C' "/data/data/$PKG" 2>/dev/null)"
  else
    echo "  数据目录不存在（包未安装）"
  fi
  echo "  运行中进程：$(ps -A -o NAME 2>/dev/null | grep -c "^$PKG")"

  echo
  echo "=== 云控残留（默认清单）==="
  ex=0; mi=0
  for name in $TARGETS; do
    src="$SP/$name"
    if [ -f "$src" ]; then
      printf '  存在 %-62s %6s B  %s\n' "$name" "$(stat -c '%s' "$src")" "$(stat -c '%y' "$src" | cut -d. -f1)"
      ex=$((ex + 1))
    else
      mi=$((mi + 1))
    fi
  done
  echo "  -> 存在 $ex 个，已清 $mi 个"

  echo
  echo "=== 深度清单（--deep 才动）==="
  for name in $DEEP_TARGETS; do
    src="$SP/$name"
    [ -f "$src" ] && printf '  存在 %-40s %6s B\n' "$name" "$(stat -c '%s' "$src")"
  done

  echo
  echo "=== 快照 ==="
  if [ -d "$BK" ] && [ -n "$(ls -1 "$BK" 2>/dev/null)" ]; then
    snap_list
  else
    echo "  （无）"
  fi
}

# ---------- 入口 ----------
DEEP=0
cmd=$1
case "$cmd" in
  clean)
    shift
    for a in "$@"; do [ "$a" = "--deep" ] && DEEP=1; done
    do_clean ;;
  backup)
    shift
    do_backup "${1:-manual}" ;;
  verify)
    shift
    do_verify "$1" ;;
  restore)
    shift
    do_restore "$1" ;;
  list)
    echo "=== 快照列表（$BK）==="
    if [ -d "$BK" ] && [ -n "$(ls -1 "$BK" 2>/dev/null)" ]; then
      snap_list
      echo
      echo "最新：$(latest_snap)"
    else
      echo "  （无）"
    fi ;;
  status|"")
    do_status ;;
  *)
    echo "未知命令：$cmd"
    echo "用法：sh $0 {status|backup [标签]|clean [--deep]|list|verify [快照]|restore [快照]}"
    exit 1 ;;
esac