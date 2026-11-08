#!/system/bin/sh
# oplus-cloud-block - 诊断报告（用户反馈问题时导出，发给作者）
#
# 用法：sh diag.sh            生成报告到 /sdcard/Download/ColorOS温控与云控-诊断-时间.txt
#
# 只读：不改任何系统设置、不启停任何服务。
# 隐私：不收集账号、手机号、IMEI/序列号、应用列表、通讯录、位置；
#       模块日志里出现的包名只有本模块拦截/记录的那些。报告是纯文本，发出前可以自己打开看。

# 模块目录。用相对路径调用（cd 进去后 sh diag.sh）时 ${0%/*} 会是 "."，整份报告会失效 ——
# 所以取不到绝对路径时退回本模块的标准安装位置。
MODDIR=${0%/*}
case "$MODDIR" in
  /*) ;;
  *) MODDIR=/data/adb/modules/oplus-cloud-block ;;
esac
DATA=/data/adb/oplus-cloud-block-data
LOG=/data/adb/oplus-cloud-block.log
OUTDIR=/sdcard/Download

# sh diag.sh open：用系统文件管理打开「下载」目录，用户长按报告选「发送」发给 QQ/微信。
#
# 不做「从模块里直接分享」：分享是 root 发起的，系统不会把临时读取权限转给 QQ，
# 不管用媒体库地址还是管理器的 FileProvider，QQ 都提示「文件不存在」（Ace 2 Pro / Android 16 实测）。
# 从文件管理里发送时，分享由文件管理发起，授权正常。
if [ "$1" = open ]; then
  D=/storage/emulated/0/Download
  # ColorOS / OxygenOS 文件管理：能直接进到 Download
  r=$(am start -a oplus.intent.action.filemanager.BROWSER_FILE \
        -n com.coloros.filemanager/com.oplus.filebrowser.FileBrowserActivity \
        --es CurrentDir "$D" -f 0x10000000 2>&1)
  case "$r" in *Error*) ;; *) echo "OPEN=ok"; exit 0 ;; esac
  # 其他系统：AOSP 文件（DocumentsUI）打开 Download
  r=$(am start -a android.intent.action.VIEW -t vnd.android.document/directory \
        -d content://com.android.externalstorage.documents/document/primary%3ADownload -f 0x10000000 2>&1)
  case "$r" in *Error*) echo "OPEN=fail" ;; *) echo "OPEN=ok" ;; esac
  exit 0
fi
# 文件名带机型，方便一次收多台机器的报告时分辨（型号可能为空，回落到 device 名）
_m=$(getprop ro.product.model); [ -n "$_m" ] || _m=$(getprop ro.product.device)
[ -n "$_m" ] || _m=unknown
OUT="$OUTDIR/ColorOS温控与云控-诊断-${_m}-$(date +%Y%m%d-%H%M%S).txt"

sec() { echo; echo "===== $* ====="; }
# 打印文件内容；不存在就说明不存在（区分「没有」和「读不到」）
show() { if [ -e "$1" ]; then printf '%s = %s\n' "$1" "$(cat "$1" 2>&1 | head -c 600)"; else echo "$1 （不存在）"; fi; }

{
echo "ColorOS 温控与云控 · 诊断报告"
echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"

sec "设备"
for k in ro.product.model ro.product.marketname ro.product.device ro.board.platform \
         ro.soc.manufacturer ro.soc.model ro.hardware \
         ro.build.version.oplusrom ro.build.display.id ro.build.version.release \
         ro.build.version.sdk ro.build.version.security_patch; do
  printf '%-30s %s\n' "$k" "$(getprop $k)"
done
echo "内核：$(uname -r)"
echo "运行时间：$(cut -d' ' -f1 /proc/uptime) 秒"

sec "root 与模块"
echo "KernelSU：$(ksud -V 2>/dev/null || echo 无)"
echo "Magisk：$(magisk -v 2>/dev/null || echo 无)"
grep -E '^(version|versionCode)=' "$MODDIR/module.prop"
for f in disable remove update skip_mount; do [ -e "$MODDIR/$f" ] && echo "模块标记：$f"; done
ls -la "$MODDIR" 2>&1

sec "已安装的模块（找出别的调度/性能模块）"
# 用户的"被锁频"经常不是固件干的，而是同时装了别的调度模块（实测 PLK110 是 yumi 把
# 60 多个 App 挂 powersave、perf_ceil:0.70）。报告里不列出来，就只能靠猜。
# 只看模块目录名与各自 module.prop 的 name/id，不读任何配置内容。
for d in /data/adb/modules/*; do
  [ -d "$d" ] || continue
  b=${d##*/}
  [ -f "$d/disable" ] && s=已停用 || s=启用
  nm=""; [ -f "$d/module.prop" ] && nm=$(sed -n 's/^name=//p' "$d/module.prop" 2>/dev/null | head -1)
  id=""; [ -f "$d/module.prop" ] && id=$(sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null | head -1)
  printf '  %-28s %s  %s (%s)\n' "$b" "$s" "${nm:-无 name}" "${id:-无 id}"
done
ls -d /data/adb/modules_update/* 2>/dev/null | sed 's/^/  待更新：/'
# 常见"会改调度/频率"的第三方模块，单独点出来，省得看清单时漏掉
for k in yumi scene asoul opti perfmgr fas-rs encored uperf sched; do
  for d in /data/adb/modules/*$k*; do [ -d "$d" ] && echo "  ⚠ 疑似调度模块：${d##*/}"; done
done

sec "内核限频特性实测（不看 defconfig，直接问本机内核）"
# ★ 为什么要有这段：同一个 SoC 的不同机型、不同 ROM 版本，**加载的限频驱动不一样**
#   （实测 sm8850 仓里 canoe 开了 OPLUS_FEATURE_CEILING_FREE，而 kalama/mt6895 都没开）。
#   而 defconfig 是不可靠的线索：① 机型代号与 defconfig 目录名对不上（k6895v1_64 vs mt6895）
#   ② 公开的 defconfig 未必等于设备实际用的那份。
#   用途：拿到一份报告就知道「这台机到底有哪些限频器」，不用按机型猜。
#
# ★ 主判据：`/sys/module/<名字>` 目录是否存在 = 该驱动**此刻是否已加载进内核**。
#   这是最直接、最准的探针（零 fork，一次 [ -d ] 就够）：
#   驱动的 sysfs 目录由内核在模块加载时创建，加载了就有、没加载就没有。
#
# ★ 为什么**不用** /proc/config.gz（我原先的想法，实测被推翻）：
#   OPLUS 的这些限频驱动大多是 **vendor 侧独立 .ko**（`oplus_omrg` 实测是模块，
#   `/sys/module/oplus_omrg/` 存在），而 **config.gz 只反映主内核镜像的配置**，
#   **不含独立模块** —— PJA110 上 config.gz 里 `grep -i omrg` 是空，
#   但 oplus_omrg 明明加载着。所以拿 config.gz 判断限频驱动会**系统性漏报**。
#   （config.gz 对"主内核内建了什么"仍然有效，但不是我们要回答的问题。）
if [ -d /sys/module ]; then
  echo "── 限频/调度驱动是否已加载（看 /sys/module/<名>；空=未加载）"
  for m in oplus_omrg cpufreq_bouncing oplus_freqqos_monitor oplus_bsp_task_sched \
           oplus_bsp_frame_boost oplus_ipa_thermal oplus_omrg_trace horae \
           qti_cpufreq_cdev qti_devfreq_cdev thermal_pause msm_performance \
           mtk_fpsgo fpsgo mtk_core_ctl teeperf; do
    [ -d "/sys/module/$m" ] && printf '  %-26s 已加载\n' "$m"
  done
  echo "  （只列已加载的；没列出的就是本机没有/没加载）"
  echo "  已加载的 oplus* 模块总数：$(ls /sys/module 2>/dev/null | grep -c '^oplus')"
fi

# 补充判据：符号表（能查到"编进去了但没加载"的驱动；也能看到
# `/sys/module` 里没有的内部符号，如导出给别人的函数）。
KS_HEAD=$(head -1 /proc/kallsyms 2>/dev/null)
if [ -n "$KS_HEAD" ]; then
  echo "  ── 符号表补充（约 $(wc -l < /proc/kallsyms) 个符号；看导出函数在不在）"
  # 注：kptr_restrict=2 时地址被抹成 0，但**符号名仍在** → 只判符号存在则不受影响，
  # 不涉及内存布局，可安全外发。这里只挑"驱动级"特征符号，避免刷屏。
  for sym in cb_ceiling_free cb_cap omrg_update_freq_range omrg_check_thermal_limit \
             omrg_idle omrg_thermal_limit; do
    n=$(grep -c "$sym" /proc/kallsyms 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && printf '    %-30s %s\n' "$sym" "$n"
  done
  echo "    （上面没列出的 = 该符号不在符号表里）"
fi

sec "拦截清单（packages.txt 有效行）"
sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$MODDIR/packages.txt" 2>&1

sec "拦截项实际状态"
INSTALLED=$(pm list packages --user 0 2>/dev/null)
DISABLED=$(pm list packages -d --user 0 2>/dev/null)
for p in com.oplus.ota com.oplus.romupdate com.oplus.cota com.oplus.sau com.oplus.sauhelper \
         com.oplus.statistics.rom com.oplus.pantanal.ums com.heytap.htms com.heytap.mcs \
         com.oplus.metis com.heytap.openid com.heytap.cloud com.oplus.athena com.oplus.obrain \
         com.oplus.deepthinker com.platform.usercenter com.heytap.usercenter; do
  case "$INSTALLED" in *"package:$p"*) ;; *) printf '  %-32s 未安装\n' "$p"; continue ;; esac
  case "$DISABLED" in *"package:$p"*) s=已禁用 ;; *) s=启用 ;; esac
  printf '  %-32s %s\n' "$p" "$s"
done
echo "htms 被禁用的组件："
dumpsys package com.heytap.htms 2>/dev/null | sed -n '/disabledComponents:/,/enabledComponents:/p' | sed 's/^/  /'

sec "组件拦截复核（只在这里现场试一次 pm disable，不写任何东西）"
# 有些机型上 pm disable 组件会失败（报告里出现过「错误：禁用组件失败」），
# 但只报一句「失败」没法判断是"组件不存在"还是"被系统拒绝"。
# 这里对每个云控组件分别列出：组件在不在包里、单独执行 pm disable 的真实返回。
# pm disable 是幂等的、且这些组件本来就是要禁的，所以现场执行不改变最终状态。
#   组件是否在包里：用整包 dumpsys 的输出做固定字符串匹配。
#   不要用 `dumpsys package <包>/<组件>`：AOSP 不支持这种参数，只会返回
#   "Unable to find package"，会让这一列永远显示"组件不存在"（踩过）。
#   也不要用 grep 'A\|B'：toybox 的 grep 不支持 \| 交替，同样永远匹配不上。
hcomps=$(dumpsys package com.heytap.htms 2>/dev/null)
echo "  整包 dumpsys 输出行数：$(printf '%s\n' "$hcomps" | grep -c '' 2>/dev/null)"
for cmp in com.heytap.msp.cloudctrl.ipc.CloudCtrlService \
           com.heytap.cloudconfig.v3.kit.ipc.CloudCtrlV3Service \
           com.heytap.msp.cloudctrlreport.service.CloudConfigReportService \
           com.heytap.msp.v2.ipcchannel.provider.MspCoreProvider; do
  e="com.heytap.htms/$cmp"
  case "$hcomps" in *"$cmp"*) incomp="在包里" ;; *) incomp="不在包里" ;; esac
  out=$(pm disable --user 0 "$e" </dev/null 2>&1)
  printf '  %-72s %-8s | pm: %s\n' "$cmp" "$incomp" "$(printf '%s' "$out" | head -1)"
done

sec "温控性能配置"
grep -v '^#' "$MODDIR/cpulimit.conf" 2>&1
echo "指定应用："; cat "$MODDIR/cpulimit.apps" 2>/dev/null | sed 's/^/  /'
echo "按游戏阈值："; cat "$DATA/gametemp.conf" 2>/dev/null | sed 's/^/  /'
sh "$MODDIR/cpulimit.sh" status 2>&1

sec "CPU 频率（每个 policy）"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  echo "$p: cpus=$(cat $p/related_cpus 2>/dev/null) gov=$(cat $p/scaling_governor 2>/dev/null)"
  echo "    cur=$(cat $p/scaling_cur_freq 2>/dev/null) min=$(cat $p/scaling_min_freq 2>/dev/null) max=$(cat $p/scaling_max_freq 2>/dev/null) hw_max=$(cat $p/cpuinfo_max_freq 2>/dev/null)"
  echo "    available_governors=$(cat $p/scaling_available_governors 2>/dev/null)"
done

sec "频率是否被钉住 / 是否在动（连续 6 次 × 1 秒）"
# 单次读数不能作结论：实测 Ace 2 Pro 的 scaling_max_freq 会持续跳动。
# 这里连采 6 次，同时给「被钉住」和「在动」两种结论提供依据。
# 也顺带看 cur 是否恒等于 min —— 恒等 = 调速器退化成 powersave（天玑报告里出现过）。
i=0
while [ $i -lt 6 ]; do
  line=""
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    nm=${p##*/policy}
    line="$line ${nm}:$(cat $p/scaling_cur_freq 2>/dev/null)/$(cat $p/scaling_max_freq 2>/dev/null)"
  done
  echo "  t+${i}s$line"
  i=$((i + 1)); [ $i -lt 6 ] && sleep 1
done

sec "谁在限制频率（冷却设备 + 厂商限频开关）"
# cooling device 的 cur_state 非 0 = 有温控在主动限频；全 0 说明限频在别的链路。
n=0; n0=0
for c in /sys/class/thermal/cooling_device*; do
  [ -e "$c/type" ] || continue
  t=""; read -r t 2>/dev/null <"$c/type"
  case "$t" in *cpufreq*|*cpu*|*thermal*|*devfreq*|*gpu*|*gpufreq*) ;; *) continue ;; esac
  cs=""; read -r cs 2>/dev/null <"$c/cur_state"
  ms=""; read -r ms 2>/dev/null <"$c/max_state"
  printf '  %-12s %-24s cur=%s max=%s\n' "${c##*/}" "$t" "$cs" "$ms"
  [ "$cs" != "0" ] && n0=$((n0 + 1))
  n=$((n + 1)); [ $n -ge 25 ] && break
done
echo "  → 非 0 的冷却设备数：$n0（0 = 温控没在主动限频，限频另有来源）"

sec "限频节点探测（高通 / 联发科 / 厂商）"
# 高通
show /sys/kernel/msm_performance/parameters/cpu_max_freq
show /sys/kernel/msm_performance/parameters/cpu_min_freq
show /sys/module/msm_performance/parameters/cpu_max_freq
# 高通新平台（SM8750/SM8850）：lmh 频率限制、散热 cooling device、walt
for f in /sys/kernel/lmh_stats_*/dcvsh_freq_limit /sys/kernel/lmh_stats_*/lmh_freq_limit; do
  [ -e "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
done
show /proc/sys/walt/sched_max_freq_partial_halt
show /proc/sys/walt/sched_max_freq_halt
# 联发科：PPM（老平台）/ FPSGO / CPU 调频驱动
show /proc/ppm/enabled
show /proc/ppm/policy_status
show /proc/ppm/policy/hard_userlimit_max_cpu_freq
show /proc/ppm/policy/userlimit_max_cpu_freq
show /proc/cpufreq/cpufreq_power_mode
show /proc/cpufreq/cpufreq_sched_disable
ls -d /sys/kernel/fpsgo /sys/module/mtk_fpsgo 2>/dev/null
ls /proc/perfmgr 2>/dev/null | head -30 | sed 's/^/  perfmgr: /'
ls /sys/devices/system/cpu/cpufreq/ 2>/dev/null | tr '\n' ' '; echo
# OPLUS 通用
show /proc/game_opt/game_pid
show /proc/game_opt/cpu_max_freq
show /proc/game_opt/disable_cpufreq_limit
ls /proc/game_opt 2>/dev/null | tr '\n' ' '; echo
ls -d /sys/module/oplus_omrg /proc/oplus_omrg 2>/dev/null

sec "天玑专项（fpsgo / gbe / core_ctl / fbt / thermal_message / GED / dvfsrc）"
# 现代天玑（Dimensity 8000 系起）没有 /proc/ppm，真正干活的节点在这几处。
# 以前的报告里这一段全空白，导致「天玑有救吗」这个问题一直没法回答。
# 全部只读；不存在的直接跳过，不给一堆「不存在」刷屏。
zprobe() { # $1 = 路径
  [ -e "$1" ] || return 0
  v=$(head -c 120 "$1" 2>/dev/null | tr '\n' ' ')
  printf '  %-58s = %s\n' "$1" "$v"
}
echo "── FPSGO（联发科稳帧核心）"
for f in /sys/kernel/fpsgo/common/fpsgo_status /sys/kernel/fpsgo/common/fpsgo_enable \
         /sys/kernel/fpsgo/common/fpsgo_game_enable /sys/kernel/fpsgo/fstb/fpsgo_status \
         /sys/kernel/fpsgo/fstb/fstb_soft_level /sys/kernel/fpsgo/fstb/fstb_self_ctrl_fps_enable_by_pid; do zprobe "$f"; done
[ -d /sys/kernel/fpsgo ] && { echo "  /sys/kernel/fpsgo 子项："; ls /sys/kernel/fpsgo 2>/dev/null | tr '\n' ' '; echo; }

# 全量枚举 fpsgo 下所有可读文件（含各子目录一层）。
# ★ 动机：天玑上「游戏记录」的帧率一直是空的 —— SurfaceFlinger 1013 已被 Android 16 移除、
#   高通那条 /sys/class/drm/sde-crtc-*/measured_fps 天玑没有，所以想从 fpsgo 找真实帧率/帧计数。
#   但事先不知道哪个节点带 fps，猜名字会一直猜不中 → 直接把现场全带回来。
#   注意排除 write-only/开关类会阻塞的节点：只读普通文件，跳过目录与 /proc 式特殊文件。
if [ -d /sys/kernel/fpsgo ]; then
  echo "  ── fpsgo 全量探测（找真实帧率节点用；空值=不可读或本来为空）"
  for d in /sys/kernel/fpsgo /sys/kernel/fpsgo/*/; do
    [ -d "$d" ] || continue
    for f in "$d"*; do
      [ -f "$f" ] || continue
      [ -s "$f" ] || continue
      v=$(head -c 100 "$f" 2>/dev/null | tr '\n' ' ')
      [ -n "$v" ] && printf '    %-56s = %s\n' "${f#/sys/kernel/fpsgo/}" "$v"
    done
  done
  echo "  ── 其他可能的帧率来源（供天玑用）"
  for f in /proc/fpsgo/fps /proc/mtk_fpsgo/fps /sys/kernel/fpsgo/xgf/xgf_fps \
           /sys/kernel/fpsgo/composer/fps /sys/kernel/fpsgo/minitop/fps; do
    [ -e "$f" ] && zprobe "$f"
  done
fi
echo "── GBE（联发科游戏加速引擎）+ 游戏态温控余量"
for f in /sys/kernel/gbe/gbe_enable1 /sys/kernel/gbe/gbe_enable2 /sys/kernel/gbe/gbe_thrm_hdrm_thrs \
         /sys/kernel/gbe/gbe2_fg_pid /sys/kernel/gbe/thermal_remove; do zprobe "$f"; done
[ -d /sys/kernel/gbe ] || echo "  /sys/kernel/gbe （不存在）"
echo "── 核心控制 / FBT 提频 / 频率投票"
for f in /sys/module/mtk_core_ctl/parameters/policy_enable /sys/module/mtk_core_ctl/parameters/enable \
         /sys/module/fbt_cpu/parameters/floor_bound /sys/module/fbt_cpu/parameters/rescue_percent \
         /sys/module/fbt_cpu/parameters/rescue_enhance_f /sys/module/mtk_perf_ioctl_magt/parameters/enable; do zprobe "$f"; done
for d in /sys/devices/system/cpu/cpu*/core_ctl; do
  [ -d "$d" ] || continue
  echo "  $d: enable=$(cat $d/enable 2>/dev/null) min=$(cat $d/min_cpus 2>/dev/null) max=$(cat $d/max_cpus 2>/dev/null)"
  break
done
echo "── 温控档位（thermal_message 是联发科的档位机；sconfig 数字越大越凉）"
for f in /sys/class/thermal/thermal_message/sconfig /sys/class/thermal/thermal_message/balance_mode \
         /sys/class/thermal/thermal_message/boost_mode /sys/kernel/thermal/sports_mode; do zprobe "$f"; done
echo "── DVFSRC（内存总线）/ 频率 QoS"
for f in /sys/class/devfreq/mtk-dvfsrc-devfreq/cur_freq /sys/class/devfreq/mtk-dvfsrc-devfreq/governor \
         /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp; do zprobe "$f"; done
ls -d /sys/devices/platform/soc/*dvfsrc* 2>/dev/null | head -5 | sed 's/^/  /'
echo "── Mali GPU / GED HAL"
for f in /sys/kernel/ged/hal/gpu_boost_level /sys/kernel/ged/hal/dvfs_margin_value \
         /sys/kernel/ged/hal/loading_base_dvfs_step /sys/kernel/ged/hal/frame_base_optimize \
         /sys/kernel/ged/hal/current_freqency /sys/kernel/ged/hal/custom_boost_gpu_freq \
         /sys/class/misc/mali0/device/dvfs_period; do zprobe "$f"; done
echo "── PPM（只有老平台才有；新平台全不存在是正常的）"
show /proc/ppm/policy/ut_fix_core_num
echo "── 相关内核模块（天玑）"
ls /sys/module 2>/dev/null | grep -iE '^(fpsgo|mtk_|ged|fbt|thermal_|oplus_|sched|teeperf|cpufreq)' | tr '\n' ' '; echo

sec "限频节点搜索（按名字找，节点换了位置也能发现）"
# 新内核/新芯片上节点可能改路径或改名，上面的固定路径会全是「不存在」。
# 这里按文件名在几个常见根目录下找，只读取值，不写入。
# 跳过 debugfs/tracing：里面有读取会阻塞的节点。
echo "内核模块（性能/调频相关）："
ls /sys/module 2>/dev/null | grep -iE 'perf|freq|ppm|fpsgo|game|omrg|horae|thermal|sched|walt|boost' | tr '\n' ' '; echo
for root in /sys/kernel /sys/module /proc; do
  find "$root" -maxdepth 4 \( -path /sys/kernel/debug -o -path /sys/kernel/tracing -o -path '/proc/[0-9]*' \) -prune -o \
    -type f \( -iname '*max_freq*' -o -iname '*min_freq*' -o -iname '*freq_limit*' -o -iname '*limit_freq*' \
               -o -iname '*cpufreq_limit*' -o -iname '*freq_max*' -o -iname '*userlimit*' \) -print 2>/dev/null
done | grep -v '^/sys/devices' | head -60 | while read -r f; do
  printf '  %s = %s\n' "$f" "$(head -c 160 "$f" 2>/dev/null | tr '\n' ' ')"
done

sec "CPU 调度 / cpuset / uclamp（判断频率被谁夹住的现场）"
# 只读。cpuset 的 cpus 范围决定游戏进程能跑哪些核；uclamp 决定它的下限/上限需求。
for d in /dev/cpuset/top-app /dev/cpuset/top-app/heavy /dev/cpuset/foreground /dev/cpuset/foreground/boost \
         /dev/cpuset/restricted /dev/cpuset/background; do
  [ -e "$d/cpus" ] || continue
  echo "  $d/cpus = $(cat $d/cpus 2>/dev/null)"
done
ls /dev/cpuset 2>/dev/null | tr '\n' ' '; echo
for f in /dev/cpuctl/top-app/cpu.uclamp.min /dev/cpuctl/top-app/cpu.uclamp.max \
         /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive /dev/cpuctl/foreground/cpu.uclamp.min \
         /dev/cpuctl/foreground/cpu.uclamp.max; do
  [ -e "$f" ] && echo "  $f = $(cat $f 2>/dev/null)"
done
echo "  当前前台进程的 cpuset（取 top-app 前 3 个）："
n=0
while read -r pid; do
  nm=""; IFS= read -r -d '' nm 2>/dev/null <"/proc/$pid/cmdline"; nm=${nm%%:*}
  echo "    pid $pid $nm"
  n=$((n + 1)); [ $n -ge 3 ] && break
done < /dev/cpuset/top-app/cgroup.procs 2>/dev/null

sec "ColorOS 温控配置与属性（判断有没有独立的限频链路）"
# Ace 2 Pro（PJA110）上查实：降频来自 /odm 的档位表 + oplus_omrg，不是温度。
# 天玑那台 policy 全是 powersave、cur=min=max，症状很像同一类"非温度限频"。
# 这里只读地看一眼有没有同样的配置源；不改任何东西（/odm 是只读 erofs）。
for f in /odm/etc/temperature_profile/sys_thermal_control_config.xml \
         /odm/etc/ThermalServiceConfig/sys_thermal_config.xml \
         /data/oplus/os/bpm/sys_cpulimit_config.xml; do
  if [ -e "$f" ]; then
    echo "  $f 存在，大小 $(wc -c <"$f" 2>/dev/null) 字节"
    grep -oE '<level index="[0-9]+" maxCpuFreq="[^"]*"' "$f" 2>/dev/null | head -14 | sed 's/^/     /'
    grep -oE 'aging_thermal_control_enable_item[^/]*|aging_cpu_level_item[^/]*|safety_thermal_level_item[^/]*' "$f" 2>/dev/null | head -5 | sed 's/^/     /'
  else
    echo "  $f （不存在）"
  fi
done
echo "  ── 相关属性"
for k in persist.sys.aging.2.0 ro.runtime.agingbootcheck sys.thermal.enable persist.sys.aging \
         ro.oplus.image.my_engineering.type persist.sys.mms.use_integrated_memory_reclaim; do
  v=$(getprop $k 2>/dev/null); [ -n "$v" ] && printf '     %-46s = %s\n' "$k" "$v"
done
echo "  ── 厂商限频/温控服务是否在跑"
for svc in horae oplus_thermal thermal-engine-v2 thermald mi_thermald thermalservice; do
  ps -A 2>/dev/null | grep -q "[ /]$svc" && echo "     运行中：$svc"
done
ps -A 2>/dev/null | grep -iE 'horae|thermal' | head -8 | sed 's/^/     /'
echo "  ── dumpsys horae（能读就说明有这条链路）"
dumpsys horae 2>/dev/null | head -20 | sed 's/^/     /' || echo "     （无）"
echo "  ── oplus_omrg 导出节点（Ace 2 Pro 上就是它经 freq_qos 施加 CPU 上限）"
for f in /sys/devices/platform/soc/soc:oplus-omrg/oplus-omrg0/ruler_enable \
         /sys/devices/platform/soc/soc:oplus-omrg/oplus-omrg0/ruler_freq_dev_list; do
  show "$f"
done

sec "限频链路取证（只读；临开内核 trace，约 10 秒，读完立即关闭并还原缓冲）"
# 为什么要有这一段：Ace 2 Pro 实测证明「解除 msm_performance 上限」只解掉一层。
# 第二层是内核线程 oplus-omrg 按设备树规则推的状态机，与温度无关：
#   state=0 → 大核 max 1459200 / state=1 → 1785600 / state=2 → 2016000
#   同一时刻 omrg_thermal_limit 与 omrg_idle 命中 0 次（不走温控、不走空闲）
#   我们把节点写 9999999 解锁后，policy0 的上限**仍然**是 1459200。
# 所以这里要回答两个问题：
#   ① 到底是谁在给 CPU 设上限（调用者名字）
#   ② 是不是温控干的
#
# 采集三组事件，覆盖不同平台：
#   power/cpu_frequency_limits  内核通用（所有平台都有）：每次有人改 CPU 上下限都记一条，带调用者
#   schedwalt/update_cpu_capacity  高通的 WALT 调度器：给出 thermal_cap 与 arch_capacity，
#                               两者相等即证明"上限不是温控给的"；另给 max_freq / max_possible_freq
#   oplus_omrg_trace            OPLUS 专有（部分机型有）：状态机 state → 频率
#   thermal/*                   热限与 trip 点（有就抓，没有很正常）
#   devfreq_frequency           内存总线/GH 等 devfreq 频率变化
#
# ⚠️ 输出必须聚合。原始 trace 8 秒就有 4 万行 / 6MB（其中 binder_ux_task 占 8 千行是噪声），
#    原样倒出来报告会变成几 MB，用户根本发不动。所以这里只出统计与少量样本。
# ⚠️ 只写 tracing（内核内存），不改任何 sysfs 限制节点；结束时 trace 关、缓冲还原。
CAP_TR=/sys/kernel/tracing
[ -d "$CAP_TR/events" ] || CAP_TR=/sys/kernel/debug/tracing
if [ -d "$CAP_TR/events" ]; then
  _buf0=$(cat "$CAP_TR/buffer_size_kb" 2>/dev/null)
  echo "  trace 挂载：$CAP_TR（缓冲原值 ${_buf0:-?}）"
  # 逐个尝试开启；本机没有的事件就跳过（不同平台事件集不同）
  CAP_EV=""
  for e in power/cpu_frequency_limits schedwalt/update_cpu_capacity schedwalt/halt_cpus \
           power/pm_qos_update_request power/devfreq_frequency devfreq/devfreq_frequency \
           thermal/thermal_power_cpu_limit thermal/thermal_zone_trip thermal/cdev_update \
           oplus_omrg_trace/omrg_update_freq_range oplus_omrg_trace/omrg_cpu_policy_adjust \
           oplus_omrg_trace/omrg_thermal_limit oplus_omrg_trace/omrg_idle; do
    [ -e "$CAP_TR/events/$e/enable" ] && CAP_EV="$CAP_EV $e"
  done
  echo "  可用事件：$(printf '%s' "$CAP_EV" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')"
  if [ -n "$CAP_EV" ]; then
    echo 16384 > "$CAP_TR/buffer_size_kb" 2>/dev/null
    : > "$CAP_TR/trace" 2>/dev/null
    for e in $CAP_EV; do echo 1 > "$CAP_TR/events/$e/enable" 2>/dev/null; done
    echo 1 > "$CAP_TR/tracing_on" 2>/dev/null
    echo "  正在采样 10 秒（期间请保持屏幕亮着、不要操作，最好就在出问题时的那种状态）…"
    sleep 10
    echo 0 > "$CAP_TR/tracing_on" 2>/dev/null
    for e in $CAP_EV; do echo 0 > "$CAP_TR/events/$e/enable" 2>/dev/null; done
    _tl="$CAP_TR/trace"

    echo "  ── 各事件采样到的条数"
    for e in $CAP_EV; do
      _k=${e##*/}
      printf '     %-28s %s\n' "$_k" "$(grep -c "$_k" "$_tl" 2>/dev/null)"
    done

    # ① 谁在设上限：cpu_frequency_limits 的调用者 + 目标值（最关键的证据）
    if grep -q cpu_frequency_limits "$_tl" 2>/dev/null; then
      echo "  ── 谁在给 CPU 设上限（调用者 → 设定值，次数降序）"
      grep cpu_frequency_limits "$_tl" 2>/dev/null \
        | sed -E 's/^ *([^ ]+)-[0-9]+ +\[[0-9]+\] [^ ]+ +([0-9.]+): cpu_frequency_limits: (min=[0-9]+ max=[0-9]+ cpu_id=[0-9]+).*/\1 => \3/' \
        | sort | uniq -c | sort -rn | head -14 | sed 's/^/     /'
      echo "  ── 按调用者汇总（谁设得最频繁）"
      grep cpu_frequency_limits "$_tl" 2>/dev/null \
        | sed -E 's/^ *([^ ]+)-[0-9]+ +\[[0-9]+\].*/\1/' \
        | sort | uniq -c | sort -rn | head -8 | sed 's/^/     /'
      echo "  → 出现 oplus-omrg / kworker / thermal* 等名字，就是限频发起者"
    fi

    # ② 是不是温控：thermal_cap vs arch_capacity
    if grep -q update_cpu_capacity "$_tl" 2>/dev/null; then
      echo "  ── WALT 调度器看到的容量与上限（thermal_cap = arch_capacity 即"不是温控"）"
      grep update_cpu_capacity "$_tl" 2>/dev/null \
        | grep -oE 'cpu=[0-9]+ arch_capacity=[0-9]+ thermal_cap=[0-9]+ fmax_capacity=[0-9]+ max_freq=[0-9]+ max_possible_freq=[0-9]+' \
        | sort -u | head -10 | sed 's/^/     /'
      echo "     （max_freq < max_possible_freq = 确实有上限；thermal_cap = arch_capacity = 上限不是温控给的）"
    fi

    # ③ OPLUS 的 OMRG 状态机（部分机型才有）
    if grep -q omrg_update_freq_range "$_tl" 2>/dev/null; then
      echo "  ── OMRG 状态机「state → 频率上限」（次数降序）"
      grep -oE 'state=[0-9]+ min_freq=[0-9]+ max_freq=[0-9]+' "$_tl" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -8 | sed 's/^/     /'
      echo "  ── OMRG 是否走温控 / 空闲路径"
      echo "     thermal_limit=$(grep -c omrg_thermal_limit "$_tl" 2>/dev/null)  idle=$(grep -c omrg_idle "$_tl" 2>/dev/null)（都为 0 = 与温度、空闲无关）"
      echo "  ── 最近 10 条 OMRG 频率范围变更（含调用者）"
      grep omrg_update_freq_range "$_tl" 2>/dev/null | tail -10 | sed 's/^/     /'
    fi

    # ④ 热限 / trip 点：非 0 就说明温控确实在动手
    _th=$(grep -c thermal_power_cpu_limit "$_tl" 2>/dev/null)
    _tp=$(grep -c thermal_zone_trip "$_tl" 2>/dev/null)
    echo "  ── 温控是否在主动限频：thermal_power_cpu_limit=$_th  thermal_zone_trip=$_tp"
    [ "$_th" != "0" ] && { echo "     ⚠️ 有热限事件，样本："; grep thermal_power_cpu_limit "$_tl" 2>/dev/null | tail -5 | sed 's/^/     /'; }
    [ "$_tp" != "0" ] && { echo "     触发过温区 trip："; grep thermal_zone_trip "$_tl" 2>/dev/null | tail -5 | sed 's/^/     /'; }

    # ⑤ devfreq（内存总线等）
    if grep -q devfreq_frequency "$_tl" 2>/dev/null; then
      echo "  ── devfreq 频率变化（前 8 种）"
      grep devfreq_frequency "$_tl" 2>/dev/null | grep -oE 'dev_name="[^"]*"|freq=[0-9]+' | sort | uniq -c | sort -rn | head -8 | sed 's/^/     /'
    fi

    echo "  trace 原始体积：$(wc -c <"$_tl" 2>/dev/null) 字节 / $(wc -l <"$_tl" 2>/dev/null) 行（已在上面聚合，不随报告发出）"
    : > "$_tl" 2>/dev/null
    [ -n "$_buf0" ] && echo "$_buf0" > "$CAP_TR/buffer_size_kb" 2>/dev/null
    echo "  trace 已关闭，缓冲已还原为 ${_buf0:-原值}"
  else
    echo "  本机没有任何可用的事件，跳过"
  fi
else
  echo "  本机没有 tracefs（/sys/kernel/tracing 与 debug/tracing 都不在），跳过"
fi

sec "谁在实际生效（我们那层 vs OMRG 那层）"
# 纯读判定，不写任何节点。逻辑：
#   msm_performance 节点的 cpu0 值是"我们这层的天花板"，policy0 的 scaling_max_freq 是"最终生效值"。
#   scaling_max_freq 明显低于节点值 → 说明还有另一层在压（Ace 2 Pro 实测就是 OMRG）。
#   节点值 = 9999999 表示本模块已解锁这层。
_f=$(cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)
_n0=$(printf '%s\n' "$_f" | tr ' ' '\n' | sed -n 's/^0://p')
_p0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
# 最后一个 policy（不写死 policy7 —— 2 簇机没有 policy7，会显示"读不到"，看着像数据丢了）
# 实测 PMS110/canoe 只有 policy0(cpu0-5) 与 policy6(cpu6-7)。
_pN=""; _pNv=""
for _p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$_p" ] || continue
  _pN=${_p##*/policy}
  _pNv=$(cat "$_p/scaling_max_freq" 2>/dev/null)
done
# 出厂备份（模块首次开启时保存的原值）。节点值低于它 = 有别的东西在我们之后又压低了。
_bak=$(sed 's/[[:space:]]*$//' "$DATA/cpu_max_freq.orig" 2>/dev/null)
_b0=$(printf '%s\n' "$_bak" | tr ' ' '\n' | sed -n 's/^0://p')
echo "  出厂备份 cpu0           = ${_b0:-无备份}"
echo "  msm_performance 节点 cpu0 = ${_n0:-读不到}"
echo "  policy0 scaling_max_freq  = ${_p0:-读不到}   policy${_pN:-?} = ${_pNv:-读不到}"
if [ -n "$_b0" ] && [ -n "$_n0" ] && [ "$_n0" != "9999999" ] && [ "$_n0" -lt "$_b0" ] 2>/dev/null; then
  echo "  → ⚠️ 节点(${_n0}) 低于出厂备份(${_b0})：模块还原后又被别的链路压低了（非本模块所为）"
fi
case "$_n0" in
  9999999) _s="本模块这层已解锁" ;;
  '') _s="读不到" ;;
  *) _s="本模块这层未解锁（值 $_n0）" ;;
esac
echo "  → $_s"
if [ -n "$_n0" ] && [ -n "$_p0" ] && [ "$_n0" != "9999999" ] && [ "$_p0" -lt "$_n0" ] 2>/dev/null; then
  echo "  → ⚠️ policy0 的上限($_p0) 低于本模块节点($_n0)：另有一层在压，仅解本模块不够"
elif [ "$_n0" = "9999999" ] && [ -n "$_p0" ] && [ "$_p0" -lt 100000000 ] 2>/dev/null; then
  echo "  → ⚠️ 本层已解锁(9999999) 但 policy0 仍被压到 $_p0：限频来自另一条链路（见上面的 trace 取证）"
else
  echo "  → policy0 上限与节点一致，本模块这层是当前生效的限制"
fi

sec "压频源排查（按机型逐项看，找出到底是哪条链在压）"
# 上面 trace 给出"是谁、是不是温控"，这里给出"是什么配置/服务"。两者对照才能定位。
# 逐项检查，有的就打值、没有就跳过，最后给一句归纳。
_pk=""
for d in /sys/module/oplus_omrg /sys/devices/platform/soc/soc:oplus-omrg; do [ -e "$d" ] && _pk="$_pk oplus_omrg"; done
for m in cpufreq_bouncing thermal_config qti_cpufreq_cdev qti_devfreq_cdev horae_shell_temp \
         thermal_pause oplus_freqqos_monitor oplus_bsp_task_sched oplus_bsp_sched_assist sched_walt; do
  [ -d "/sys/module/$m" ] && _pk="$_pk $m"
done
echo "  本机存在的相关模块：${_pk:-（无）}"

echo "  ── horae（OPLUS 用户态温控；即使 ThrottlingLevel=0 也可能在限频）"
if ps -A 2>/dev/null | grep -q '[ /]horae'; then
  dumpsys horae 2>/dev/null | grep -m1 -E 'Temp:|ThrottlingLevel:|Config version:|Git version:' | sed 's/^/     /'
  echo "     /proc/shell-temp = $(cat /proc/shell-temp 2>/dev/null || echo 读不到)（horae 独占写）"
  for f in /sys/kernel/horae_shell_temp/* ; do [ -f "$f" ] && echo "     $f = $(head -c 100 "$f" 2>/dev/null | tr '\n' ' ')"; done
else
  echo "     未运行"
fi

echo "  ── thermal_config / qti cooling（SM8750 起的新温控链路）"
for f in /sys/module/thermal_config/parameters/*; do
  [ -f "$f" ] && echo "     ${f##*/} = $(head -c 120 "$f" 2>/dev/null | tr '\n' ' ')"
done
for d in /sys/devices/virtual/thermal/thermal_message /sys/class/thermal/thermal_message; do
  [ -d "$d" ] && { echo "     $d: $(ls $d 2>/dev/null | tr '\n' ' ')"; for f in "$d"/*; do [ -f "$f" ] && echo "       ${f##*/} = $(head -c 80 "$f" 2>/dev/null)"; done; }
done

echo "  ── 频率 QoS / WALT 侧的限制迹象"
for f in /proc/sys/walt/sched_max_freq_partial_halt /proc/sys/walt/sched_max_freq_halt \
         /proc/sys/walt/sched_fmax_cap /proc/sys/kernel/sched_util_clamp_min \
         /proc/sys/kernel/sched_util_clamp_max; do
  [ -e "$f" ] && echo "     $f = $(cat "$f" 2>/dev/null)"
done

echo "  ── 厂商限频服务的运行状态（停掉它们会解限频，但有风险，仅记录不操作）"
for svc in horae thermal-engine-v2 thermal-engine thermald mi_thermald oplus_thermal thermalservice; do
  ps -A 2>/dev/null | grep -q "[ /]$svc" && echo "     运行中：$svc"
done

echo "  ── 归纳"
if [ -z "$_pk" ]; then
  echo "     未发现已知的厂商限频模块；若仍被压，看上面的 trace「谁在设上限」那一段的调用者名字"
elif [ "${_pk#* oplus_omrg}" != "$_pk" ]; then
  echo "     本机有 oplus_omrg：优先看上面 trace 里的 OMRG 状态机（Ace 2 Pro 就是这条链）"
else
  echo "     本机没有 oplus_omrg，但存在其它限频相关模块（${_pk# }）；"
  echo "     结合上面 trace 的「谁在设上限」与「thermal_cap vs arch_capacity」两项判断是不是温控"
fi

sec "cpufreq_bouncing（另一条会动的限频链，高通平台常见）"
# 实测 Ace 2 Pro 上它是 freq_qos 的"消费者"（freq_qos_check=Y），
# 真正的激进约束由 OMRG 经 freq_qos 推给它。这里只记录状态与每簇自己的档位。
_B=/sys/module/cpufreq_bouncing/parameters
if [ -d "$_B" ]; then
  for f in enable freq_qos_check core_ctl_check self_activate decay sleep_range_ms debug trace; do
    [ -e "$_B/$f" ] && printf '  %-18s = %s\n' "$f" "$(head -c 200 "$_B/$f" 2>/dev/null | tr '\n' ' ')"
  done
  echo "  ── 每簇的 ctl / limit_freq / max_freq（limit_freq 若明显低于 max_freq 就是它在压）"
  head -c 4000 "$_B/config" 2>/dev/null \
    | grep -E '^clus|^limit_freq|^max_freq|^min_freq|^ctl' | sed 's/^/    /' | head -24
else
  echo "  本机没有 /sys/module/cpufreq_bouncing（非 OPLUS 高通常见，跳过）"
fi

sec "温度（全部温区，标注模块会选哪个）"
# 用内建 read，不 fork cat：本机 100 多个温区，逐个 cat 要 3 秒。
# ★ 不再只打印名字像温度的那几个 —— 正是这个过滤让前两次报告漏掉了 CPU 结温
#   （cpu-0-3-1 / cpullc-1-0 这类名字不含 cpu 关键字之外的信息，但会被 *cpu* 命中，
#    真正漏掉的是 soc_max/cpu_big* 之外的命名）。这里全量打印。
# 同时标出模块的温区选择结果：MODULE_ZONE（首选名命中）/ ZONE_FALLBACK_USED。
pick_zone_diag() {
  local z t
  for z in /sys/class/thermal/thermal_zone*; do
    t=""; read -r t 2>/dev/null <"$z/type"
    [ "$t" = "skin-msm-therm" ] && { echo "skin-msm-therm|$t"; return; }
  done
  for z in /sys/class/thermal/thermal_zone*; do
    t=""; read -r t 2>/dev/null <"$z/type"
    case "$t" in *trip*) continue ;; esac
    case "$t" in
      cpu-*|cpullc-*|cpu_big*|cpu_little*|cpuss*|soc_max|soc_top|mtktscpu|mtkts_cpu) echo "cpu|$t"; return ;;
    esac
  done
  for z in /sys/class/thermal/thermal_zone*; do
    t=""; read -r t 2>/dev/null <"$z/type"
    case "$t" in
      skin-msm-therm|skin_ntc|shell_*|board_temp|ap_ntc) echo "skin|$t"; return ;;
    esac
  done
  echo "none|无"
}
pz=$(pick_zone_diag)
echo "  模块会用的温区：$pz（cpu = 阈值用 TEMP_CPU，skin = 阈值用 TEMP）"
echo
n=0
for z in /sys/class/thermal/thermal_zone*; do
  t=""; read -r t 2>/dev/null <"$z/type"
  [ -n "$t" ] || continue
  v=""; read -r v 2>/dev/null <"$z/temp"
  printf '  z%-3s %-22s = %s\n' "${z##*thermal_zone}" "$t" "$v"
  n=$((n + 1)); [ $n -ge 70 ] && { echo "  …（本机温区超过 70 个，其余省略）"; break; }
done

sec "与官方内核设备树比对（平台结构参照表）"
# 参照表由 OnePlusOSS 公开的内核设备树自动生成（见 module 里的 platform-ref.txt）。
# 作用：**不用实机、不用拆 ROM**，先知道"这个平台本该有哪些温区、分几簇"，
# 再和本机实际对照 —— 差出来的就是线索：
#   表里有、本机没有 → 该型号编译时没启用（正常，不同机型裁剪不同）
#   本机有、表里没有 → 驱动运行时注册的（如 oplus explorer），或参照表没覆盖到的机型
# 只读。参照表缺失时整段跳过，不影响报告其余部分。
REF="$MODDIR/platform-ref.txt"
PLAT=$(getprop ro.board.platform)
# 主键是 ro.board.platform（高通取平台代号 kalama/canoe/…，天玑取 SoC 编号）。
# 参照表里"未验证过代号"的平台再拿 ro.soc.model / ro.hardware 兜底匹配一次。
SOCMODEL=$(getprop ro.soc.model)
HARDWARE=$(getprop ro.hardware)
echo "ro.board.platform = ${PLAT:-未知}   ro.soc.model = ${SOCMODEL:-未知}"
if [ ! -f "$REF" ]; then
  echo "参照表缺失（$REF）—— 跳过比对"
elif [ -z "$PLAT" ] && [ -z "$SOCMODEL" ]; then
  echo "取不到 ro.board.platform / ro.soc.model —— 跳过比对"
else
  # 在参照表里按 aliases（第 2 列）找本机平台行；依次尝试三个属性，命中即用
  LINE=$(awk -F'\t' -v p="$PLAT" -v s="$SOCMODEL" -v h="$HARDWARE" '
    /^#/ { next }
    function hit(v,   n, a, i) {
      if (v == "") return 0
      n = split($2, a, ",")
      for (i = 1; i <= n; i++) if (a[i] == v) return 1
      return 0
    }
    { if (hit(p) || hit(s) || hit(tolower(h))) { print; exit } }
  ' "$REF" 2>/dev/null)
  if [ -z "$LINE" ]; then
    echo "参照表未收录本平台（$PLAT / ${SOCMODEL:-无}）。现已收录："
    awk -F'\t' '/^#/ { next } { printf "  %s (%s)\n", $1, $2 }' "$REF" 2>/dev/null
    echo "若这是新机型，把本报告发给作者即可补录。"
  else
    CANON=$(printf '%s' "$LINE" | cut -f1)
    CLU=$(printf '%s' "$LINE" | cut -f3)
    CPUS=$(printf '%s' "$LINE" | cut -f4)
    HW=$(printf '%s' "$LINE" | cut -f5)
    REFZ=$(printf '%s' "$LINE" | cut -f6)
    echo "命中平台：$CANON（参照表来自该平台官方内核设备树）"
    echo "  参照表：$CLU 个簇 / $CPUS 个 CPU / cpufreq-hw=$HW"
    # 本机实际
    echo "  本机实际："
    np=0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$p" ] || continue
      np=$((np + 1))
      echo "    $(basename "$p"): cpus=$(cat $p/related_cpus 2>/dev/null) hw=$(cat $p/cpuinfo_max_freq 2>/dev/null)"
    done
    [ "$np" = "$CLU" ] && echo "    ✓ 簇数与参照表一致（$np）" || echo "    ⚠ 簇数不一致：本机 $np，参照表 $CLU"
    # 温区差异
    ZFILE=/data/local/tmp/.diagz.$$
    for z in /sys/class/thermal/thermal_zone*; do
      t=""; read -r t 2>/dev/null <"$z/type"
      [ -n "$t" ] && echo "$t"
    done | sort -u >"$ZFILE"
    echo "  温区比对（参照表 $(printf '%s' "$REFZ" | wc -w) 项，本机 $(wc -l <"$ZFILE") 个）："
    # 本机有、参照表没有
    MISS=""
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case " $REFZ " in *" $t "*) ;; *) MISS="$MISS $t" ;; esac
    done <"$ZFILE"
    # 参照表有、本机没有（只看像温度的，过滤掉 cooling-map 之类噪声）
    ONLY=""
    for t in $REFZ; do
      grep -qxF "$t" "$ZFILE" 2>/dev/null && continue
      case "$t" in *ntc*|*therm*|*skin*|*shell*|*board*|*soc*|*cpu*|*gpu*|*batt*|*charg*|*pa|pa_*) ONLY="$ONLY $t" ;; esac
    done
    rm -f "$ZFILE"
    if [ -n "$MISS" ]; then
      echo "    本机有、参照表没有（多为驱动运行时注册，非异常）："
      printf '      %s\n' $MISS
    else
      echo "    ✓ 本机所有温区都能在参照表里找到"
    fi
    if [ -n "$ONLY" ]; then
      echo "    参照表有、本机没有（该型号未启用，正常；列出来供对照）："
      printf '      %s\n' $ONLY | head -20
      c=$(printf '%s\n' $ONLY | wc -l)
      [ "$c" -gt 20 ] && echo "      …（共 $c 项，只列前 20）"
    fi
  fi
fi

sec "GPU / 显示"
echo "── GPU 频率（高通 kgsl / 天玑 GED）"
show /sys/class/kgsl/kgsl-3d0/gpuclk
show /sys/class/kgsl/kgsl-3d0/max_gpuclk
show /proc/gpufreq/gpufreq_var_dump
show /proc/gpufreq/gpufreq_opp_freq
show /proc/gpufreq/gpufreq_cur_freq
show /proc/gpufreqv2/fix_target_opp_index
show /sys/kernel/ged/hal/current_freqency
show /sys/kernel/ged/hal/gpu_boost_level
show /sys/class/devfreq/*mali*/cur_freq
echo "── 刷新率与帧率来源（决定「游戏记录」能不能记到帧率）"
echo "SurfaceFlinger 1013：$(service call SurfaceFlinger 1013 2>&1 | head -1)"
for f in /sys/class/drm/sde-crtc-*/measured_fps; do [ -e "$f" ] && echo "  $f: $(cat $f 2>/dev/null)"; done
ls /sys/class/drm 2>/dev/null | tr '\n' ' '; echo
settings get system peak_refresh_rate 2>/dev/null | sed 's/^/  peak_refresh_rate = /'
settings get system min_refresh_rate 2>/dev/null | sed 's/^/  min_refresh_rate = /'
dumpsys display 2>/dev/null | grep -m3 -oE 'renderFrameRate [0-9.]+|refreshRate=[0-9.]+'

sec "游戏记录"
sh "$MODDIR/gamerec.sh" status 2>&1
echo "最近 5 局："; sh "$MODDIR/gamerec.sh" list 2>/dev/null | tail -5
echo "游戏名单：$(cat /data/adb/oplus-cpulimit.games 2>/dev/null | tr '\n' ' ')"

sec "守护进程"
# 先用内建 read 只看进程名是不是 sh，是才 fork tr 读完整命令行。
# 原来每个进程都 fork 一次 tr，本机 870 个进程要 20 秒，导出诊断因此要等 25 秒。
for p in /proc/[0-9]*; do
  c=""; IFS= read -r -d '' c 2>/dev/null <"$p/cmdline"
  case "$c" in sh|*/sh|setsid) ;; *) continue ;; esac
  c=$(tr '\0' ' ' 2>/dev/null <"$p/cmdline")
  case "$c" in *oplus-cloud-block*|*cpulimit.sh*|*gamerec.sh*|*adbkeep.sh*) echo "  pid ${p#/proc/}: $c" ;; esac
done

sec "守护起不来时的排查（残留 pidfile / 权限 / nohup 脱离）"
# 上一次报告里 PLK110 出现「状态：异常（残留 pidfile，守护已死）」——
# 日志显示守护确实启动过（打印了 pid），但进程列表里没有。可能是：
#   ① nohup 在该机型/该 KernelSU 版本下没能脱离父进程，service.sh 一退出就被回收
#   ② SELinux 拒绝（avc denied）
#   ③ 别的东西把它杀了
# 这里把三样都摆出来，下次报告就能直接定位是哪一种。
for pf in /data/adb/oplus-cpulimit.pid /data/adb/oplus-gamerec.pid; do
  [ -f "$pf" ] || { echo "  $pf （不存在）"; continue; }
  pid=$(cat "$pf" 2>/dev/null)
  printf '  %s = %s' "$pf" "$pid"
  case "$pid" in ''|*[!0-9]*) echo "（内容不是数字）" ;;
    *) if kill -0 "$pid" 2>/dev/null; then
         echo "（进程活着：$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | head -c 120)）"
       else
         echo "（进程已死 → 残留 pidfile）"
         [ -r "/proc/$pid/cmdline" ] && echo "     但 /proc/$pid 存在，命令行：$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | head -c 120)"
       fi ;;
  esac
done
echo "  → 守护脚本能否被 sh 执行："
for f in cpulimit.sh gamerec.sh adbkeep.sh; do
  [ -f "$MODDIR/$f" ] && printf '     %-14s %s\n' "$f" "$(ls -l "$MODDIR/$f" 2>/dev/null | awk '{print $1}')"
done
echo "  → setsid 是否可用（nohup 脱不掉父进程时的替代方案）：$(command -v setsid 2>/dev/null || echo 不可用)"
echo "  → 本模块的 SELinux 拒绝（最近 200 条 avc）："
logcat -d -b main,system,crash -t 4000 2>/dev/null \
  | grep -iE 'avc:.*denied' | grep -iE 'oplus-cloud-block|cpulimit|gamerec|su |magisk|ksu' | tail -n 25
dmesg 2>/dev/null | grep -iE 'avc:.*denied' | grep -iE 'cpulimit|gamerec|ksu' | tail -n 15
echo "  → 内核有没有杀进程记录（OOM/lowmemorykiller）："
dmesg 2>/dev/null | grep -iE 'killed process|oom-kill|lowmemorykiller' | tail -n 10

sec "内存"
grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
cat /proc/pressure/memory 2>/dev/null

sec "数据目录"
ls -la "$DATA" 2>&1 | head -40

sec "模块日志（最后 300 行）"
tail -n 300 "$LOG" 2>&1

sec "系统日志里和本模块/账号相关的报错（最近）"
logcat -d -b main,system,crash -t 3000 2>/dev/null \
  | grep -iE 'oplus-cloud-block|cpulimit|usercenter|htms.*(Exception|denied|fail)|AccountManager.*(error|fail)|pantanal' \
  | tail -n 80

echo
echo "===== 结束 ====="
} >"$OUT" 2>&1

echo "诊断报告已生成：$OUT"
echo "大小：$(wc -c <"$OUT") 字节"
echo "请把这个文件发给作者（酷安 @谋事在人成事在天 / QQ 706412584）。"
