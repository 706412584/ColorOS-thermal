#!/system/bin/sh
# oplus-cloud-block - 安装时检查（KernelSU / Magisk 安装流程会 source 本文件）
# 只提示，不中止安装：云控拦截在所有 ColorOS 机型都可用，只有温控性能依赖高通节点。

ui_print "- ColorOS 温控与云控"

ROM=$(getprop ro.build.version.oplusrom)
[ -z "$ROM" ] && ROM=$(getprop ro.build.version.opporom)
PLAT=$(getprop ro.board.platform)
SOC=$(getprop ro.soc.manufacturer)
ui_print "  机型：$(getprop ro.product.model)  平台：${PLAT:-?} ${SOC}"
ui_print "  系统：${ROM:-非 ColorOS}  Android $(getprop ro.build.version.release)"

if [ -z "$ROM" ]; then
  ui_print "! 未检测到 ColorOS / OxygenOS。"
  ui_print "! 本模块针对 ColorOS 设计，其他系统上的效果未知。"
fi

case "$PLAT$SOC" in
  *mt*|*mediatek*|*MTK*)
    # 天玑：走 cpufreq policy（放开被厂商钉死的 min/max 与 governor）。
    # 需要本机有可用的 governor；只有 powersave 的机器开了反而更慢，故不做。
    GB=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -f "$p/scaling_available_governors" ] && GB="$GB $(cat "$p/scaling_available_governors" 2>/dev/null)"
    done
    case " $GB " in
      *" schedutil "*|*" ondemand "*|*" interactive "*|*" conservative "*)
        ui_print "  温控性能：支持（联发科/天玑，解除厂商钉死的 CPU 频率）" ;;
      "") ui_print "! 温控性能：不支持本机（读不到 CPU 调频策略 cpufreq policy）" ;;
      *)  ui_print "! 温控性能：不支持本机（本机内核只提供 powersave 调频策略，"
          ui_print "!   解除钉频会让频率固定在最低档，故不改动）。云控拦截、内存面板、游戏记录照常可用。" ;;
    esac ;;
  *)
    if [ -e /sys/kernel/msm_performance/parameters/cpu_max_freq ] || [ -e /sys/module/msm_performance/parameters/cpu_max_freq ]; then
      ui_print "  温控性能：支持（高通 msm_performance 节点存在）"
    else
      ui_print "! 温控性能：不支持本机（没有可识别的 CPU 限频节点）。"
      ui_print "!   该功能会自动保持关闭，不会改动本机 CPU 频率。云控拦截、内存面板、游戏记录照常可用。"
    fi ;;
esac

ui_print "  出现账号登录异常、桌面卡片不显示时："
ui_print "  WebUI「工具」→「撤销模块全部改动」"

# 脚本加执行权限：zip 是在 Windows 上打的，不带 Unix 权限位，解压后 .sh 是 644。
# 之前 service.sh 用 [ -x ] 判断脚本在不在，644 时温控、游戏记录守护全都不会启动。
set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null
for f in "$MODPATH"/*.sh; do chmod 0755 "$f" 2>/dev/null; done
