#!/system/bin/sh
# oplus-cloud-block - 关闭开发者模式后保持 USB 调试 / 无线调试
#
# 用法：
#   adbkeep.sh on | off          保持 USB 调试（开关持久保存在数据目录，模块更新不丢）
#   adbkeep.sh wifi-on | wifi-off  保持无线调试
#   adbkeep.sh status            KEY=VALUE 状态（供 WebUI）
#   adbkeep.sh check             看护循环调用：开关打开时，发现被关就重新打开
#
# 只改 settings global 的 adb_enabled / adb_wifi_enabled，不碰开发者选项里的其他设置。
# 第一次打开时备份原值。关闭开关时不主动关调试（避免当场断开 adb），只是不再自动恢复。
#
# 无线调试的限制（Android 11+ 系统行为，实测 ColorOS 16）：
#   必须已连上 Wi-Fi，没连时写 1 会被系统立刻改回 0。所以只在 Wi-Fi 有 IP 时才去打开，
#   不会替用户打开 Wi-Fi。端口每次打开都会变，状态里会报当前 IP:端口。
#   电脑第一次连接要在手机「无线调试 → 使用配对码配对」配对一次。

# 环境变量覆盖只给沙盒测试用；模块内正常运行不设置，路径不变。
DATA=${ADBKEEP_DATA:-/data/adb/oplus-cloud-block-data}
FLAG=$DATA/adbkeep.on
WFLAG=$DATA/adbkeep.wifi
BAK=$DATA/adbkeep.orig
COOL=$DATA/adbkeep.cool
NOTE=$DATA/adbkeep.note
LOG=${ADBKEEP_LOG:-/data/adb/oplus-cloud-block.log}
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [调试保持] $*" >>"$LOG"; }

get() { settings get global "$1" 2>/dev/null; }
adb_on()  { [ "$(get adb_enabled)" = 1 ]; }
wifi_on() { [ "$(get adb_wifi_enabled)" = 1 ]; }
# 无线调试服务是否还在监听。service.adb.tls.port 由 adbd 分配，服务真正关闭时清空。
# settings 里的 adb_wifi_enabled 会被系统单独改成 0，此时端口和已连接会话仍在；
# 再写 1 会让系统重启无线调试、换端口，把正在用的 adb 连接踢掉（实测）。
tls_port() { P=$(getprop service.adb.tls.port 2>/dev/null); P=${P//[[:space:]]/}; [ -n "$P" ]; }

# 冷却检查：距离上次动作不足 N 秒则返回 1。避免系统反复关时每 15 秒重启一次无线调试。
cool_ok() {
  [ -f "$1" ] || return 0
  last=$(cat "$1" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s 2>/dev/null)
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ $((now - last)) -ge "$2" ] || return 1
  return 0
}
cool_set() { date +%s >"$1" 2>/dev/null; }
dev_on()  { [ "$(get development_settings_enabled)" = 1 ]; }
# Wi-Fi 是否已连上（wlan0 有 IPv4 地址）。结果放 WIP
wlan_ip() { WIP=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1); [ -n "$WIP" ]; }

backup() {
  mkdir -p "$DATA"
  [ -f "$BAK" ] && return
  { echo "adb_enabled=$(get adb_enabled)"
    echo "adb_wifi_enabled=$(get adb_wifi_enabled)"
    echo "development_settings_enabled=$(get development_settings_enabled)"; } >"$BAK"
}

keep_wifi() { # 返回 0 = 无线调试现在是开的
  wifi_on && return 0
  wlan_ip || return 1
  settings put global adb_wifi_enabled 1 2>/dev/null
  sleep 1
  wifi_on
}

case "$1" in
  on)
    backup; : >"$FLAG"
    adb_on || settings put global adb_enabled 1
    log "已开启：保持 USB 调试"
    echo "已开启保持 USB 调试（当前：$(adb_on && echo 开 || echo 关)）" ;;
  off)
    rm -f "$FLAG"; log "已关闭保持 USB 调试（不改当前状态）"
    echo "已关闭。USB 调试保持当前状态，不再自动恢复。" ;;
  wifi-on)
    backup; : >"$WFLAG"
    log "已开启：保持无线调试"
    if keep_wifi; then echo "已开启保持无线调试（$WIP:$(getprop service.adb.tls.port)）"
    else echo "已开启。当前没连 Wi-Fi，连上后会自动打开无线调试。"; fi ;;
  wifi-off)
    rm -f "$WFLAG" "$COOL" "$NOTE"; log "已关闭保持无线调试（不改当前状态）"
    echo "已关闭。无线调试保持当前状态，不再自动恢复。" ;;
  check)
    if [ -f "$FLAG" ] && ! adb_on; then
      settings put global adb_enabled 1 2>/dev/null
      if adb_on; then log "USB 调试被关闭，已重新打开（开发者模式：$(dev_on && echo 开 || echo 关)）"
      else log "USB 调试被关闭，重新打开失败"; fi
    fi
    if [ -f "$WFLAG" ] && ! wifi_on; then
      if tls_port; then
        # 设置值被系统改回 0，但无线调试服务仍在监听（端口还没回收，连接可用）。
        # 这里绝对不能写 1：每次写入都会重启无线调试并换端口，把已连接的 adb 踢掉。
        # 一小时只记一次，便于以后判断是哪个系统组件在改这个值。
        if cool_ok "$NOTE" 3600; then
          cool_set "$NOTE"
          log "无线调试设置值被改为 0，但服务仍在监听（端口 $P），未重开"
        fi
      elif wlan_ip; then
        # 服务确实停了（端口为空，没有可被踢掉的连接）才重开；
        # 5 分钟冷却，避免系统反复关闭时每 15 秒重启一次无线调试。
        if cool_ok "$COOL" 300; then
          cool_set "$COOL"
          keep_wifi && log "无线调试已打开（$WIP:$(getprop service.adb.tls.port)）"
        fi
      fi
    fi ;;
  status)
    [ -f "$FLAG" ] && echo "ENABLED=1" || echo "ENABLED=0"
    [ -f "$WFLAG" ] && echo "WIFI_KEEP=1" || echo "WIFI_KEEP=0"
    adb_on && echo "ADB=1" || echo "ADB=0"
    wifi_on && echo "WIFI_ADB=1" || echo "WIFI_ADB=0"
    dev_on && echo "DEV=1" || echo "DEV=0"
    wlan_ip && echo "WLAN_IP=$WIP" || echo "WLAN_IP="
    echo "TLS_PORT=$(getprop service.adb.tls.port)"
    ;;
  *) echo "用法：adbkeep.sh {on|off|wifi-on|wifi-off|status|check}"; exit 1 ;;
esac
