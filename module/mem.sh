#!/system/bin/sh
# oplus-cloud-block - 内存 / CPU 面板
#
# 用法：
#   mem.sh overview        内存总览 + CPU 采样（供面板顶部显示）
#   mem.sh list            按应用聚合的内存/CPU 明细 + root 脚本进程（供列表渲染）
#   mem.sh clean           一键清理：am kill-all（只回收可安全杀死的后台）
#   mem.sh kill <pkg>      彻底停止某个应用（force-stop）
#   mem.sh killpid <pid>   停止某个 root 脚本进程（限 /data /sdcard 路径，防误杀）
#   mem.sh dropcaches      清 page cache —— 面板中默认不用，见下方说明
#   mem.sh limit <pid>     只限这次：进程及其现有子孙进后台 cpuset + nice 19 + ionice idle
#   mem.sh unlimit <pid>   解除单个进程的限制（按台账恢复）
#   mem.sh restoreall      按台账恢复所有被限制的进程（守护退出/卸载兜底）
#   mem.sh rule add <pid>  从该进程推导脚本路径，保存为规则并立即限制（每次启动都限）
#   mem.sh rule addpath <path>  直接按路径保存规则（没有脚本在跑时用）
#   mem.sh rule list       列已保存规则（RULE|<路径>）
#   mem.sh rule del <N>    删除第 N 条规则并恢复该规则已限制的进程
#   mem.sh guard           规则守护（常驻；无规则自动退出）
#   mem.sh ensure          看护循环调用：按需拉起/重启 guard
#
# 脚本限制设计：
#   * 规则按「脚本路径」保存，不按 PID —— 进程每次启动 PID 都会变。匹配三处：
#     argv0、解释器脚本参数（sh /path/x.sh）、进程 cwd（root 进程）。
#   * 命中后把进程和它当前的子孙一起移进 background cpuset（小核）并降优先级；
#     之后它 fork 的新进程继承 cgroup/nice，自动受限，不需要每轮重新写。
#   * 只对状态还是「未限制」的进程写入，已 nice=19 且两套 background cgroup 都在位的跳过。
#   * 限制前把 pid/starttime/原 cgroup 组/原 nice/来源记进 scriptlimit.state。
#     来源 auto（规则守护）在 guard 退出、ensure 重启、删规则时恢复；来源 once（只限这次）
#     只按 PID 解除，不会被删规则或 guard 重启误恢复。uninstall/restoreall 恢复全部。
#     PID 已被复用（starttime 不符）或进程已退出则跳过，杜绝"脚本退出了限制还留着"。
#   * 规则只允许 /data /sdcard /storage 下，排除 /data/adb（root 基础设施）、
#     /data/data、/data/system、/data/misc，防止把系统进程拖慢。
#
# 设计取舍（都有实测依据）：
#   * 主推 am kill-all：实测 zram 占用 3910MB -> 1256MB，MemAvailable 反而上升。
#   * 不做 drop_caches：实测 MemFree 0.9GB -> 10.5GB 很好看，但 MemAvailable
#     从 15.0GB 掉到 14.5GB —— 它清的是可回收缓存，纯属指标美化，还会让
#     应用重新读盘变慢。故仅在 dropcaches 子命令里保留，面板上标"不推荐"。
#   * 不杀 adj<=0 的进程（system_server/前台/systemui），杀了会自愈或坏体验。

PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
export PATH
# CLK_TCK 用于把 jiffies 换算成百分比；取不到就按 100 算（Android 常规值）
HZ=$(getconf CLK_TCK 2>/dev/null | tr -dc '0-9')
case "$HZ" in ''|0) HZ=100 ;; esac

# ---------- 系统级：内存总览 ----------
mem_stat() {
  awk '
    /^MemTotal:/     {t=$2}
    /^MemFree:/      {f=$2}
    /^MemAvailable:/ {a=$2}
    /^Cached:/       {c=$2}
    /^SwapTotal:/    {st=$2}
    END{printf "TOTAL=%d FREE=%d AVAIL=%d CACHED=%d SWAPTOTAL=%d\n", t, f, a, c, st}
  ' /proc/meminfo
}

# zram 实际占用（压缩后落盘量）
zram_used() {
  awk '/zram/{print int($4/1024)}' /proc/swaps 2>/dev/null
}

cmd_overview() {
  s=$(mem_stat)
  eval "$s"
  echo "MEMTOTAL_MB=$((TOTAL / 1024))"
  echo "MEMAVAIL_MB=$((AVAIL / 1024))"
  echo "MEMFREE_MB=$((FREE / 1024))"
  echo "CACHED_MB=$((CACHED / 1024))"
  echo "ZRAM_MB=$(zram_used)"
  echo "PROCS=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
  echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg)"
  # 内存压力（PSI）：some = 至少一个任务卡住的时间占比
  echo "PSI=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | cut -d= -f2)"
  echo "GEAR=$(cat /proc/oplus_healthinfo/cpu_info 2>/dev/null | tr -d '\n')"

  # 活跃进程数：直接统计处于 R（运行中）的进程，0 次 fork、瞬时完成。
  # 早先用两次采样求差，要 sleep 1 —— 而 overview 每 10s 自动刷新一次，
  # 那 1s 会周期性冻住主线程，不值得。
  r=0
  for p in /proc/[0-9]*; do
    read -r _ _ st _ 2>/dev/null <"$p/stat" || continue
    [ "$st" = "R" ] && r=$((r + 1))
  done
  echo "CPUBUSY=$r"
}

# ---------- 应用级明细 ----------
# 为了面板渲染方便，这里输出机器可解析的行：
#   A|<pkg>|<rss_kb>|<adj>|<proc_count>
# CPU 侧输出：C|<pkg-or-name>|<permille>|0|1
# 列出明细。
#
# 性能要点：本机 870+ 进程。若每个进程都 fork 出 tr/awk/cat（旧写法），
# 实测 100 个进程就花 6s，全量约 50s —— 而 ksu.exec 是同步阻塞的，
# 主线程会整体冻住。这里改成全用 shell 内建读取，做到零 fork：
#   cmdline  -> IFS= read -r -d '' （NUL 分隔，取首个名字）
#   内存     -> read < /proc/PID/statm（第 2 字段 resident 页数 × 4KB）
#   oom adj  -> read < /proc/PID/oom_score_adj
cmd_list() {
  T=/data/local/tmp/.ml.$$
  : >"$T.acc"; : >"$T.r"
  # 零 fork 扫描。A 类行 "pid key rss_kb adj"（包名形态进程）；R 类行 "pid 完整cmdline"。
  # ★ cmdline 是 NUL 分隔数组，read -d '' 只能拿 argv0（实测 "sh /data/x.sh" 只读到
  #   "sh"，sh 包装的脚本进程全部漏扫）。argv0 是解释器时才二次 tr 读全参，控制 fork 成本。
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    IFS= read -r -d '' cmd 2>/dev/null <"$p/cmdline" || continue
    [ -n "$cmd" ] || continue
    case "$cmd" in
      sh|bash|toybox|busybox|/system/bin/sh|/system/xbin/su|su)
        full=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        [ -n "$full" ] && cmd=${full% } ;;
    esac
    # root 脚本/裸进程（R 类）：cmdline 是 /data /sdcard /storage 路径，或参数里带
    # 这些路径（sh 包装）。root 手起的破解工具、后台脚本烧 CPU 在这里抓到。
    # /data/adb 是 root 管理器与模块基础设施（KernelSU busybox、模块守护），两种
    # 形态都排除防误杀；/system /vendor /odm 路径照旧跳过。
    case "$cmd" in
      /data/adb/*|/data/dalvik*|/data/misc/*|/data/system/*) continue ;;
      *" /data/adb/"*|*" /data/dalvik"*|*" /data/misc/"*) continue ;;
    esac
    r_hit=0
    case "$cmd" in
      /data/*|/sdcard/*|/storage/*) r_hit=1 ;;
      *" /data/"*|*" /sdcard/"*|*" /storage/"*) r_hit=1 ;;
    esac
    if [ "$r_hit" = 1 ]; then
      echo "$pid $cmd" >>"$T.r"
      continue
    fi
    key=${cmd%%:*}                                # :sub 进程归到主包
    case "$key" in *.*) ;; *) continue ;; esac    # 只保留包名形态
    read -r _sz res _rest 2>/dev/null <"$p/statm" || continue
    [ -n "$res" ] || continue
    read -r adj 2>/dev/null <"$p/oom_score_adj"
    # 必须用 echo：Android 的 sh 里 printf 是外部程序（非内建），
    # 逐进程调用会让扫描从 56ms 涨到 2000ms。
    echo "$pid $key $((res * 4)) ${adj:-0}" >>"$T.acc"
  done 2>/dev/null

  : >"$T.out"

  # 1) 内存按包聚合（1 次 awk）
  awk '{rss[$2]+=$3; if($4+0>v[$2])v[$2]=$4+0; n[$2]++}
       END{for(k in rss) printf "A|%s|%d|%d|%d\n", k, rss[k], v[k], n[k]}' "$T.acc"     | sort -t'|' -k3 -rn >>"$T.out"

  # 2) CPU：两次快照求差，再用 pid->key 映射聚合（1 次 awk 三文件 join）
  #    采样窗 600ms —— 分辨率够用（非零进程至少 1 tick=10ms 才会被记到），
  #    而 sleep 1 会让用户感觉"点了没反应"。
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{print $1, $14+$15}' >"$T.s1"
  sleep 0.6
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{print $1, $14+$15}' >"$T.s2"
  # PERM = 千分比（= jiffies / (HZ * 采样秒数) * 1000，HZ*0.6 已约掉成 60/100）
  awk -v hz="$HZ" '
    FILENAME==ARGV[1] { key[$1]=$2; next }      # pid -> key
    FILENAME==ARGV[2] { a[$1]=$2;    next }     # 快照1
    { if (($1 in a) && ($1 in key)) { d=$2-a[$1]; if (d>0) c[key[$1]]+=d } }
    END { for (k in c) printf "C|%s|%d|0|1\n", k, int(c[k]*1000/(hz*0.6)) }
  ' "$T.acc" "$T.s1" "$T.s2" | sort -t'|' -k3 -rn | head -25 >>"$T.out"
  # 3) R 类：root 脚本进程（R|pid|cmdline|cpu千分比），按 CPU 排序全量输出。
  #    cmdline 含空格，输出列用 | 分隔后由 WebUI join 还原。
  awk -v hz="$HZ" '
    FILENAME==ARGV[1] { cmd[$1]=$0; sub(/^[0-9]+ /,"",cmd[$1]); next }
    FILENAME==ARGV[2] { a[$1]=$2;    next }
    { if (($1 in a) && ($1 in cmd)) { d=$2-a[$1]; if (d>0) c[$1]=d } }
    END { for (pid in cmd) printf "R|%d|%s|%d\n", pid, cmd[pid], int(c[pid]*1000/(hz*0.6)) }
  ' "$T.r" "$T.s1" "$T.s2" | sort -t'|' -k4 -rn >>"$T.out"

  cat "$T.out" 2>/dev/null
  rm -f "$T.acc" "$T.r" "$T.s1" "$T.s2" "$T.out"
}


# ---------- 清理动作 ----------
cmd_clean() {
  before_a=$(mem_stat | tr ' ' '\n' | awk -F= '/AVAIL/{print int($2/1024)}')
  before_z=$(zram_used)
  before_p=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')

  # 只动可以安全回收的后台；前台/系统进程由 adj 语义保护，不会碰
  am kill-all 2>&1 | grep -v '^$' | head -3

  sleep 3
  after_a=$(mem_stat | tr ' ' '\n' | awk -F= '/AVAIL/{print int($2/1024)}')
  after_z=$(zram_used)
  after_p=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')

  d=$((after_a - before_a))
  [ "$d" -ge 0 ] && dtxt="+${d}" || dtxt="${d}"
  echo "已清理后台进程"
  echo "  可用内存 ${before_a}MB -> ${after_a}MB (${dtxt}MB)"
  echo "  zram 占用 ${before_z}MB -> ${after_z}MB"
  echo "  进程数 ${before_p} -> ${after_p}"
  echo "提示：系统会自动重新拉起需要的应用，这是正常行为。"
}

cmd_kill() {
  pkg="$1"
  [ -n "$pkg" ] || { echo "用法：mem.sh kill <包名>"; exit 1; }
  # 只允许包名字符：参数要拼进 grep 正则和 am 命令
  case "$pkg" in
    *[!A-Za-z0-9._]*|*..*|.*) echo "不是合法包名：$pkg"; exit 1 ;;
    *.*) ;;
    *) echo "不是合法包名：$pkg"; exit 1 ;;
  esac
  # 先尝试温和回收，不行再 force-stop
  am kill "$pkg" >/dev/null 2>&1
  sleep 1
  # 精确匹配包名或其 ":子进程"，前缀匹配会把 com.foo 误认成 com.foobar
  if ps -A -o NAME 2>/dev/null | grep -qE "^${pkg}(:|\$)"; then
    am force-stop --user 0 "$pkg" >/dev/null 2>&1
    sleep 1
  fi
  if ps -A -o NAME 2>/dev/null | grep -qE "^${pkg}(:|\$)"; then
    echo "已请求停止 $pkg（可能仍有常驻服务）"
  else
    echo "已停止 $pkg"
  fi
}

cmd_killpid() {
  pid="$1"
  case "$pid" in ''|*[!0-9]*) echo "不是合法 PID"; exit 1 ;; esac
  [ -d "/proc/$pid" ] || { echo "进程 $pid 已不存在"; exit 0; }
  # 安全校验（防 PID 复用后误杀）：目标必须是 /data /sdcard /storage 路径的
  # 脚本进程（直接路径或 sh 包装均可）；/data/adb 基础设施拒绝。
  # 读全 cmdline（NUL 分隔数组 → 空格）；单进程一次 tr，成本可忽略
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
  cmd=${cmd% }
  case "$cmd" in
    /data/adb/*|*" /data/adb/"*) echo "拒绝：root 基础设施进程"; exit 1 ;;
  esac
  case "$cmd" in
    /data/*|/sdcard/*|/storage/*) ;;
    *" /data/"*|*" /sdcard/"*|*" /storage/"*) ;;
    *) echo "拒绝：目标不是数据分区脚本进程"; exit 1 ;;
  esac
  kill -9 "$pid" 2>/dev/null && echo "已停止 $pid：$cmd" || echo "停止失败 $pid"
}

cmd_dropcaches() {
  before_f=$(mem_stat | tr ' ' '\n' | awk -F= '/FREE/{print int($2/1024)}')
  before_a=$(mem_stat | tr ' ' '\n' | awk -F= '/AVAIL/{print int($2/1024)}')
  echo 3 >/proc/sys/vm/drop_caches 2>/dev/null
  sleep 2
  after_f=$(mem_stat | tr ' ' '\n' | awk -F= '/FREE/{print int($2/1024)}')
  after_a=$(mem_stat | tr ' ' '\n' | awk -F= '/AVAIL/{print int($2/1024)}')
  echo "已清空文件缓存"
  echo "  空闲内存 ${before_f}MB -> ${after_f}MB"
  echo "  可用内存 ${before_a}MB -> ${after_a}MB"
  echo "注意：可用内存通常反而下降——清掉的是本来就可回收的缓存，"
  echo "      还会让应用重新读盘变慢。一般不需要用。"
}

# ---------- 脚本限制：规则 + 守护 ----------
# 数据目录可用 MEM_DATA 覆盖（沙盒测试）。PROC_ROOT / MEM_CS_PROCS / MEM_CT_PROCS 同理。
DATA=${MEM_DATA:-/data/adb/oplus-cloud-block-data}
RULES=$DATA/scriptlimit.rules
SELF=${MEM_SELF:-$0}
GUARD_PID=$DATA/scriptlimit.pid
GUARD_START=$GUARD_PID.start
GUARD_SIG=$GUARD_PID.script
PROC_ROOT=${PROC_ROOT:-/proc}
CS_ROOT=${MEM_CS_ROOT:-/dev/cpuset}
CT_ROOT=${MEM_CT_ROOT:-/dev/cpuctl}
CS_PROCS=${MEM_CS_PROCS:-$CS_ROOT/background/cgroup.procs}
CT_PROCS=${MEM_CT_PROCS:-$CT_ROOT/background/cgroup.procs}
# 受限进程台账：pid starttime 原cpuset组 原cpu组 原nice 触发规则
# 守护退出/删规则/卸载时按它恢复，进程已退出或 PID 被复用则跳过，杜绝"脚本退出了限制还留着"。
STATE=$DATA/scriptlimit.state
MEMLOG=${MEM_LOG:-/data/adb/oplus-cloud-block.log}
memlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [脚本限制] $*" >>"$MEMLOG"; }

NL='
'
TAB='	'

# 规则路径白名单校验。只允许数据分区下的脚本/目录；/data/adb 是 root 基础设施，
# /data/data、/data/system、/data/misc 是应用与系统私有数据，误加规则会把系统拖慢。
path_ok() {
  _pk=$1
  [ -n "$_pk" ] || return 1
  [ "${#_pk}" -lt 512 ] || return 1
  case "$_pk" in /*) ;; *) return 1 ;; esac
  case "$_pk" in *'|'*|*"$NL"*|*"$TAB"*) return 1 ;; esac
  case "$_pk" in
    /data/adb|/data/adb/*|/data/data|/data/data/*|/data/system|/data/system/*) return 1 ;;
    /data/misc|/data/misc/*|/data/dalvik*|/data/vendor|/data/vendor/*) return 1 ;;
  esac
  case "$_pk" in /data/*|/sdcard/*|/storage/*) return 0 ;; esac
  return 1
}

# 规则以 | 连接缓存在变量里，扫描时纯 shell 内建匹配，不逐进程开文件。
# HAS_DIR_RULE：是否有目录规则。只有目录规则才需要读进程 cwd（文件规则的 cwd
# 永远不可能等于该文件），能省掉每轮几百次 readlink。测试可用 MEM_DIR_RULES 强制。
RULES_TEXT=""
HAS_DIR_RULE=0
load_rules() {
  RULES_TEXT=""
  HAS_DIR_RULE=0
  _dircheck=${MEM_DIR_RULES:-auto}
  [ "$_dircheck" = 1 ] && HAS_DIR_RULE=1
  # 用 -r 而不是 -s：刚写完的规则文件在某些文件系统上 size 缓存可能滞后。
  [ -r "$RULES" ] || return 1
  while IFS= read -r _line; do
    case "$_line" in ''|'#'*) continue ;; esac
    RULES_TEXT="$RULES_TEXT|$_line"
    if [ "$_dircheck" = auto ] && [ -d "$_line" ]; then HAS_DIR_RULE=1; fi
  done <"$RULES"
  case "$RULES_TEXT" in ''|'|') RULES_TEXT=""; return 1 ;; esac
  RULES_TEXT=${RULES_TEXT#|}
  return 0
}

# 文本是否等于某条规则或在其目录下（前缀匹配必须带 /，避免 /data/x 命中 /data/xy）
field_match() {
  _fm_r=$RULES_TEXT
  while [ -n "$_fm_r" ]; do
    case "$_fm_r" in
      *'|'*) _fm_p=${_fm_r%%'|'*}; _fm_r=${_fm_r#*'|'} ;;
      *)     _fm_p=$_fm_r; _fm_r="" ;;
    esac
    case "$1" in "$_fm_p"|"$_fm_p"/*) return 0 ;; esac
  done
  return 1
}

proc_starttime() {
  _st=""; IFS= read -r _st 2>/dev/null <"$PROC_ROOT/$1/stat" || return 1
  _rest=${_st#*') '}
  set -- $_rest
  echo "${20}"
}

proc_uid() {
  while IFS= read -r _l; do
    case "$_l" in
      Uid:*) set -- $_l; echo "$2"; return 0 ;;
    esac
  done 2>/dev/null <"$PROC_ROOT/$1/status"
  return 1
}

# 读一次 stat：nice=原字段19，num_threads=20；移除 "pid (comm) " 后为 ${17}/${18}。
# 必须写 ${17}：$17 在 shell 里会解析成 ${1} 后跟字面 7。
proc_nice_threads() {
  _st=""; IFS= read -r _st 2>/dev/null <"$PROC_ROOT/$1/stat" || return 1
  _rest=${_st#*') '}
  set -- $_rest
  PN_NICE=${17}
  PN_NT=${18}
  return 0
}

# cpuset 与 cpu 两套 cgroup 是否都已在 background（缺任一套都要补写）。
in_background() {
  _cs=0; _cpu=0
  while IFS= read -r _l; do
    case "$_l" in *:*:*) ;; *) continue ;; esac
    _h=${_l#*:}
    _c=${_h%%:*}
    _path=${_h#*:}
    case "$_c" in *cpuset*) case "$_path" in */background) _cs=1 ;; esac ;; esac
    case ",$_c," in *,cpu,*) case "$_path" in */background) _cpu=1 ;; esac ;; esac
  done 2>/dev/null <"$PROC_ROOT/$1/cgroup"
  [ "$_cs" = 1 ] && [ "$_cpu" = 1 ]
}

# 返回 0 = 这个进程还需要限制（nice 不是 19 或 cgroup 不在 background）
need_limit() {
  _nl=$1
  proc_nice_threads "$_nl" || return 1
  [ "$PN_NICE" = 19 ] || return 0
  in_background "$_nl" && return 1
  return 0
}

# ---------- 受限台账：退出/删规则/卸载时恢复 ----------
# 解析进程当前所在的 cpuset / cpu 组名（取路径第一段，如 top-app）。
proc_groups() {
  _pg_cs=""; _pg_ct=""
  while IFS= read -r _pg_l; do
    case "$_pg_l" in *:*:*) ;; *) continue ;; esac
    _pg_h=${_pg_l#*:}
    _pg_c=${_pg_h%%:*}
    _pg_path=${_pg_h#*:}
    _pg_g=${_pg_path#/}
    _pg_g=${_pg_g%%/*}
    case "$_pg_c" in *cpuset*) _pg_cs=$_pg_g ;; esac
    case ",$_pg_c," in *,cpu,*) _pg_ct=$_pg_g ;; esac
  done 2>/dev/null <"$PROC_ROOT/$1/cgroup"
  echo "${_pg_cs:-top-app} ${_pg_ct:-top-app}"
}

# 只恢复到认识的组；组名异常时退回 top-app，避免把进程写进无效 cgroup。
valid_group() {
  case "$1" in
    top-app|foreground|background|system-background|restricted|display|foreground_window) return 0 ;;
  esac
  return 1
}

clean_state_pid() {
  [ -r "$STATE" ] || return 0
  awk -v p="$1" '$1 != p' "$STATE" >"$STATE.tmp" 2>/dev/null
  mv -f "$STATE.tmp" "$STATE"
}

# 限制前记录原状态（组名 + nice + 来源）。必须写在 limit_one 之前，否则读到的是已限制值。
# 来源 auto = 规则守护限制的（删规则/守护退出时可恢复）；once = 用户"只限这次"（只按 PID 解除）。
record_limit() {
  _rl_pid=$1
  _rl_src=$2
  _rl_st=$(proc_starttime "$_rl_pid")
  [ -n "$_rl_st" ] || return 0
  set -- $(proc_groups "$_rl_pid")
  _rl_cs=$1; _rl_ct=$2
  _rl_nice=""
  proc_nice_threads "$_rl_pid" && _rl_nice=$PN_NICE
  case "$_rl_nice" in ''|*[!0-9-]*) _rl_nice=0 ;; esac
  clean_state_pid "$_rl_pid"
  echo "$_rl_pid $_rl_st $_rl_cs $_rl_ct $_rl_nice $_rl_src" >>"$STATE"
}

# 恢复单个进程：写回原 cgroup 组、nice 调回原值、ionice 复原。
# starttime 不符说明 PID 已被复用，绝不碰。
restore_one() {
  _r_pid=$1; _r_st=$2; _r_cs=$3; _r_ct=$4; _r_nice=$5
  [ -d "$PROC_ROOT/$_r_pid" ] || return 0
  [ "$(proc_starttime "$_r_pid")" = "$_r_st" ] || return 0
  valid_group "$_r_cs" || _r_cs=top-app
  valid_group "$_r_ct" || _r_ct=top-app
  [ -w "$CS_ROOT/$_r_cs/cgroup.procs" ] && echo "$_r_pid" >"$CS_ROOT/$_r_cs/cgroup.procs" 2>/dev/null
  [ -w "$CT_ROOT/$_r_ct/cgroup.procs" ] && echo "$_r_pid" >"$CT_ROOT/$_r_ct/cgroup.procs" 2>/dev/null
  # 只把"仍是 19（我们限制时的值）"的 nice 恢复为 0；被别的工具改过就不碰。
  # 不依赖台账里的原 nice：限制/记录之间若有竞态，用原值会算出错误增量。
  _r_cur=""
  proc_nice_threads "$_r_pid" && _r_cur=$PN_NICE
  case "$_r_cur" in ''|*[!0-9-]*) _r_cur=0 ;; esac
  _r_d=0
  [ "$_r_cur" = 19 ] && _r_d=-19
  for _rt in "$PROC_ROOT/$_r_pid"/task/*; do
    [ -d "$_rt" ] || continue
    _rtid=${_rt##*/}
    [ "$_r_d" -ne 0 ] && renice -n "$_r_d" -p "$_rtid" >/dev/null 2>&1
    ionice -c 2 -p "$_rtid" >/dev/null 2>&1
  done
  return 0
}

restore_all() {
  if [ ! -s "$STATE" ]; then
    rm -f "$STATE"
    return 0
  fi
  _ra_n=0
  while IFS=' ' read -r _a_pid _a_st _a_cs _a_ct _a_nice _a_src; do
    case "$_a_pid" in ''|*[!0-9]*) continue ;; esac
    [ -d "$PROC_ROOT/$_a_pid" ] || continue
    restore_one "$_a_pid" "$_a_st" "$_a_cs" "$_a_ct" "$_a_nice"
    _ra_n=$((_ra_n + 1))
  done <"$STATE"
  rm -f "$STATE"
  [ "$_ra_n" -gt 0 ] && memlog "已恢复 ${_ra_n} 个进程的调度限制"
  return 0
}

# 只恢复某一类来源的记录，其余保留：rule del / guard 退出只动 auto，
# 用户"只限这次"的 once 记录保留到进程退出或手动 unlimit。
restore_source() {
  [ -s "$STATE" ] || return 0
  _rs=$1
  : >"$STATE.keep"
  while IFS=' ' read -r _a_pid _a_st _a_cs _a_ct _a_nice _a_src; do
    case "$_a_pid" in ''|*[!0-9]*) continue ;; esac
    if [ "$_a_src" = "$_rs" ]; then
      [ -d "$PROC_ROOT/$_a_pid" ] && restore_one "$_a_pid" "$_a_st" "$_a_cs" "$_a_ct" "$_a_nice"
    else
      echo "$_a_pid $_a_st $_a_cs $_a_ct $_a_nice $_a_src" >>"$STATE.keep"
    fi
  done <"$STATE"
  mv -f "$STATE.keep" "$STATE" 2>/dev/null
  [ -s "$STATE" ] || rm -f "$STATE"
}

# 清理台账里已退出的进程，避免 once 记录无限累积。
state_prune() {
  [ -s "$STATE" ] || return 0
  : >"$STATE.tmp"
  while IFS=' ' read -r _sp_pid _sp_st _sp_cs _sp_ct _sp_nice _sp_src; do
    case "$_sp_pid" in ''|*[!0-9]*) continue ;; esac
    [ -d "$PROC_ROOT/$_sp_pid" ] && echo "$_sp_pid $_sp_st $_sp_cs $_sp_ct $_sp_nice $_sp_src" >>"$STATE.tmp"
  done <"$STATE"
  mv -f "$STATE.tmp" "$STATE" 2>/dev/null
  [ -s "$STATE" ] || rm -f "$STATE"
}

# 写后台 cgroup + 全部 TID 降优先级。toybox renice 的 -n 是增量，
# 40 会把任意 nice 夹到 19（实测设备行为）；进程已在 19 时是空操作。
limit_one() {
  _lp=$1
  [ -w "$CS_PROCS" ] && echo "$_lp" 2>/dev/null >"$CS_PROCS"
  [ -w "$CT_PROCS" ] && echo "$_lp" 2>/dev/null >"$CT_PROCS"
  for _t in "$PROC_ROOT/$_lp"/task/*; do
    [ -d "$_t" ] || continue
    _tid=${_t##*/}
    renice -n 40 -p "$_tid" >/dev/null 2>&1
    ionice -c 3 -p "$_tid" >/dev/null 2>&1
  done
  return 0
}

# 全局 pid:ppid 表，只在确有进程需要限制时才收集，常态扫描不付这份成本。
PPIDS=""
collect_ppids() {
  PPIDS=""
  for _cpp in "$PROC_ROOT"/[0-9]*; do
    _cpid=${_cpp##*/}
    _st=""; IFS= read -r _st 2>/dev/null <"$_cpp/stat" || continue
    _rest=${_st#*') '}
    set -- $_rest
    PPIDS="$PPIDS $_cpid:$2"
  done
}

# 命中的进程 + 现有子孙（fork 已发生的部分不会继承后来写入的 cgroup）。
expand_tree() {
  _all=$1
  collect_ppids
  _i=0
  while [ "$_i" -lt 6 ]; do
    _new=""
    for _e in $PPIDS; do
      _xp=${_e%%:*}; _xpp=${_e#*:}
      case " $_all " in *" $_xp "*) continue ;; esac
      case " $_all " in *" $_xpp "*) _new="$_new $_xp" ;; esac
    done
    [ -n "$_new" ] || break
    _all="$_all$_new"
    _i=$((_i + 1))
  done
  echo "$_all"
}

apply_tree() { # $1 = 命中进程集合（空格分隔）；$2 = 来源 auto|once
  _roots=$1
  _src=${2:-auto}
  _todo=0
  for _pid in $_roots; do
    need_limit "$_pid" && { _todo=1; break; }
  done
  [ "$_todo" = 1 ] || return 0
  _all=$(expand_tree "$_roots")
  _n=0
  for _pid in $_all; do
    if need_limit "$_pid"; then
      record_limit "$_pid" "$_src"
      limit_one "$_pid"
      _n=$((_n + 1))
    fi
  done
  [ "$_n" -gt 0 ] && memlog "已限制 ${_n} 个进程（规则命中：${_roots}）"
  return 0
}

# 一次性限制：只限这次（进程及其现有子孙），不保存规则。
cmd_limit() {
  _pid=$1
  case "$_pid" in ''|*[!0-9]*) echo "不是合法 PID"; return 1 ;; esac
  [ -d "$PROC_ROOT/$_pid" ] || { echo "进程 $_pid 已不存在"; return 1; }
  _cmd=$(tr '\0' ' ' 2>/dev/null <"$PROC_ROOT/$_pid/cmdline")
  _cmd=${_cmd% }
  case "$_cmd" in
    /data/adb/*|*" /data/adb/"*) echo "拒绝：root 基础设施进程"; return 1 ;;
    *oplus-cloud-block*|*"mem.sh"*) echo "拒绝：模块自身进程"; return 1 ;;
  esac
  case "$_cmd" in
    /data/*|/sdcard/*|/storage/*) ;;
    *" /data/"*|*" /sdcard/"*|*" /storage/"*) ;;
    *)
      # app_process / memfd 形态的破解核心 cmdline 里没有路径，工作目录才是脚本目录。
      proc_script_path "$_pid" >/dev/null || { echo "拒绝：目标不是数据分区脚本进程"; return 1; } ;;
  esac
  _target=$_pid
  apply_tree "$_target" once
  echo "已限制 PID $_target 及其现有子进程（后台 cpuset + nice 19 + ionice idle）"
}

# 从进程推导可保存的脚本路径：解释器脚本参数 > argv0 > cwd（仅 root 进程）。
# app_process / memfd 形态的破解核心 argv0 不是路径，cwd 才是脚本目录。
proc_script_path() {
  _pid=$1
  _a0=""; _a1=""
  { IFS= read -r -d '' _a0; IFS= read -r -d '' _a1; } 2>/dev/null <"$PROC_ROOT/$_pid/cmdline"
  case "$_a0" in
    sh|ash|bash|mksh|dash|/system/bin/sh|/system/xbin/sh|/system/bin/bash|toybox|busybox)
      if [ -n "$_a1" ] && path_ok "$_a1"; then echo "$_a1"; return 0; fi ;;
  esac
  [ -n "$_a0" ] && path_ok "$_a0" && { echo "$_a0"; return 0; }
  _uid=$(proc_uid "$_pid")
  if [ "$_uid" = 0 ]; then
    _cwd=$(readlink "$PROC_ROOT/$_pid/cwd" 2>/dev/null)
    [ -n "$_cwd" ] && path_ok "$_cwd" && { echo "$_cwd"; return 0; }
  fi
  return 1
}

cmd_rule() {
  _sub=$2
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null
  case "$_sub" in
    list)
      [ -r "$RULES" ] || return 0
      while IFS= read -r _line; do
        case "$_line" in ''|'#'*) continue ;; esac
        echo "RULE|$_line"
      done <"$RULES" ;;
    add)
      _pid=$3
      case "$_pid" in ''|*[!0-9]*) echo "不是合法 PID"; return 1 ;; esac
      [ -d "$PROC_ROOT/$_pid" ] || { echo "进程 $_pid 已不存在"; return 1; }
      _path=$(proc_script_path "$_pid") || { echo "无法从 PID $_pid 识别脚本路径（不是 /data、/sdcard、/storage 下的脚本）"; return 1; }
      if grep -qxF "$_path" "$RULES" 2>/dev/null; then
        echo "规则已存在：$_path"
      else
        echo "$_path" >>"$RULES"
        memlog "新增规则：$_path（来源 PID $_pid）"
        echo "已保存规则：$_path"
      fi
      # 立即生效：先把当前进程和子孙限了，再确保守护在跑（之后新启动的由守护接管）
      apply_tree "$_pid"
      cmd_ensure
      echo "RULE=$_path" ;;
    del)
      _n=$3
      case "$_n" in ''|*[!0-9]*) echo "用法：mem.sh rule del <序号>（1 起）"; return 1 ;; esac
      [ -r "$RULES" ] || { echo "没有规则"; return 1; }
      : >"$RULES.tmp"
      _i=0; _del=""
      while IFS= read -r _line; do
        _i=$((_i + 1))
        if [ "$_i" = "$_n" ]; then _del=$_line; continue; fi
        echo "$_line" >>"$RULES.tmp"
      done <"$RULES"
      if [ -n "$_del" ]; then
        mv -f "$RULES.tmp" "$RULES"
        # 删除规则 = 恢复所有规则守护限制的进程（不碰"只限这次"的 once 记录）。
        restore_source auto
        memlog "删除规则并恢复自动限制的进程：$_del"
        echo "已删除规则：$_del"
        echo "该规则已限制的进程已恢复；此后启动的进程不再受限。"
      else
        rm -f "$RULES.tmp"
        echo "没有第 $_n 条规则"
        return 1
      fi ;;
    addpath)
      _path=$3
      path_ok "$_path" || {
        echo "路径不允许：只支持 /data、/sdcard、/storage，且排除 /data/adb、/data/data、/data/system"
        return 1
      }
      if grep -qxF "$_path" "$RULES" 2>/dev/null; then
        echo "规则已存在：$_path"
      else
        echo "$_path" >>"$RULES"
        memlog "手动新增规则：$_path"
        echo "已保存规则：$_path"
      fi
      scan_rules
      cmd_ensure
      echo "RULE=$_path" ;;
    *) echo "用法：mem.sh rule {list|add <pid>|del <序号>}"; return 1 ;;
  esac
}

# ---- 守护 ----
file_sig() {
  if command -v cksum >/dev/null 2>&1; then cksum "$1" 2>/dev/null
  elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null
  else stat -c '%Y-%s' "$1" 2>/dev/null
  fi
}
script_sig() { file_sig "$1" 2>/dev/null | awk '{print $1}'; }

guard_alive() {
  [ -f "$GUARD_PID" ] || return 1
  _gp=$(cat "$GUARD_PID" 2>/dev/null)
  case "$_gp" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_gp" 2>/dev/null || return 1
  case "$(tr '\0' ' ' 2>/dev/null <"$PROC_ROOT/$_gp/cmdline")" in
    *mem.sh*guard*) ;;
    *) return 1 ;;
  esac
  if [ -f "$GUARD_START" ]; then
    _want=$(cat "$GUARD_START" 2>/dev/null)
    _now=$(proc_starttime "$_gp")
    [ -n "$_want" ] && [ "$_want" = "$_now" ] || return 1
  fi
  return 0
}

guard_stale() {
  [ -f "$GUARD_SIG" ] || return 1
  _cur=$(cat "$GUARD_SIG" 2>/dev/null)
  _now=$(script_sig "$SELF")
  [ -n "$_now" ] || return 1
  [ "$_cur" = "$_now" ] && return 1
  return 0
}

guard_stop() {
  if [ -f "$GUARD_PID" ]; then
    _op=$(cat "$GUARD_PID" 2>/dev/null)
    case "$_op" in
      ''|*[!0-9]*) ;;
      *)
        # PID 可能已被复用：只处理 cmdline 确实是本守护的进程。
        case "$(tr '\0' ' ' 2>/dev/null <"$PROC_ROOT/$_op/cmdline")" in
          *mem.sh*guard*)
            # 先 TERM 让它走 trap 恢复台账里的进程；2 秒不退再强杀。
            kill -TERM "$_op" 2>/dev/null
            _gi=0
            while [ "$_gi" -lt 20 ] && kill -0 "$_op" 2>/dev/null; do
              sleep 0.1
              _gi=$((_gi + 1))
            done
            kill -0 "$_op" 2>/dev/null && kill -9 "$_op" 2>/dev/null ;;
        esac ;;
    esac
  fi
  rm -f "$GUARD_PID" "$GUARD_START" "$GUARD_SIG"
}


# awk 预过滤给出的候选，再用 /proc 精确校验（argv0、解释器参数、root cwd）。
# 绝不凭 ps 表的粗匹配直接限制，避免把系统进程拖进 background。
verify_pid() {
  _vp_pid=$1
  _vp_p=$PROC_ROOT/$_vp_pid
  # 绝不动本模块自己的进程：指挥 addpath 时命令行里就带着目标路径，
  # 不排除会把执行命令的 shell 和刚拉起的 guard 一起限制。
  _vp_cmd=$(tr '\0' ' ' 2>/dev/null <"$_vp_p/cmdline")
  case "$_vp_cmd" in *oplus-cloud-block*|*"mem.sh"*) return 1 ;; esac
  _vp_a0=""; _vp_a1=""
  { IFS= read -r -d '' _vp_a0; IFS= read -r -d '' _vp_a1; } 2>/dev/null <"$_vp_p/cmdline"
  [ -n "$_vp_a0" ] || return 1
  field_match "$_vp_a0" && return 0
  [ -n "$_vp_a1" ] && field_match "$_vp_a1" && return 0
  # 什么时候值得读 cwd：绝对路径已直接比对过；包名形态跳过；
  # 剩下解释器和裸名（app_process、toybox 包装）才看工作目录。
  _vp_need=0
  case "$_vp_a0" in
    */*)
      case "${_vp_a0##*/}" in
        sh|ash|bash|mksh|dash|toybox|busybox|app_process|app_process32|app_process64) _vp_need=1 ;;
      esac ;;
    *.*) ;;
    *) _vp_need=1 ;;
  esac
  [ "$_vp_need" = 1 ] || return 1
  [ "$HAS_DIR_RULE" = 1 ] || return 1
  [ "$(proc_uid "$_vp_pid")" = 0 ] || return 1
  _vp_cwd=$(readlink "$_vp_p/cwd" 2>/dev/null)
  [ -n "$_vp_cwd" ] || return 1
  field_match "$_vp_cwd"
}

# 兜底扫描：逐个 /proc/PID/cmdline 读前两段（设备 ps 不支持所需字段时用）。
scan_from_proc() {
  _hits=""
  for _p in "$PROC_ROOT"/[0-9]*; do
    _pid=${_p##*/}
    [ "$_pid" = "$$" ] && continue
    _a0=""; _a1=""
    { IFS= read -r -d '' _a0; IFS= read -r -d '' _a1; } 2>/dev/null <"$_p/cmdline"
    [ -n "$_a0" ] || continue
    case "$_a0 $_a1" in *oplus-cloud-block*|*"mem.sh"*) continue ;; esac
    _hit=0
    field_match "$_a0" && _hit=1
    if [ "$_hit" = 0 ] && [ -n "$_a1" ]; then field_match "$_a1" && _hit=1; fi
    if [ "$_hit" = 0 ]; then
      _need=0
      case "$_a0" in
        */*)
          case "${_a0##*/}" in
            sh|ash|bash|mksh|dash|toybox|busybox|app_process|app_process32|app_process64) _need=1 ;;
          esac ;;
        *.*) ;;
        *) _need=1 ;;
      esac
      if [ "$_need" = 1 ] && [ "$HAS_DIR_RULE" = 1 ]; then
        _uid=$(proc_uid "$_pid")
        if [ "$_uid" = 0 ]; then
          _cwd=$(readlink "$_p/cwd" 2>/dev/null)
          [ -n "$_cwd" ] && field_match "$_cwd" && _hit=1
        fi
      fi
    fi
    [ "$_hit" = 1 ] && _hits="$_hits $_pid"
  done
  [ -n "$_hits" ] || return 0
  apply_tree "$_hits"
}

scan_rules() {
  load_rules || return 0
  # MEM_SCAN_MODE=proc 供沙盒测试强制走逐进程读取；生产默认 auto。
  case "${MEM_SCAN_MODE:-auto}" in proc) scan_from_proc; return 0 ;; esac
  _scan_tmp=$DATA/.scriptlimit.scan
  _cand=$DATA/.scriptlimit.cand
  if ! ps -A -w -o PID,PPID,NICE,USER,ARGS >"$_scan_tmp" 2>/dev/null || [ ! -s "$_scan_tmp" ]; then
    scan_from_proc
    rm -f "$_scan_tmp"
    return 0
  fi
  # 一次 awk 从整张进程表筛出：H=疑似命中（ARGV 前 3 个参数或整串含规则），
  # C=root 的解释器/裸名进程（cwd 可能是脚本目录）。shell 只校验这两类候选。
  # 逐行 shell 解析 870 行实测占 80% 单核，awk 预处理后降到个位数。
  awk -v rf="$RULES" -v dircand="$HAS_DIR_RULE" '
    BEGIN { while ((getline line < rf) > 0) if (line != "" && line !~ /^#/) r[++rn] = line }
    NR > 1 && NF >= 5 {
      pid = $1; user = $4;
      args = "";
      for (i = 5; i <= NF; i++) args = args (i > 5 ? " " : "") $i;
      hit = 0;
      for (i = 5; i <= NF && i <= 7 && !hit; i++)
        for (j = 1; j <= rn; j++)
          if ($i == r[j] || substr($i, 1, length(r[j]) + 1) == r[j] "/") { hit = 1; break }
      if (!hit)
        for (j = 1; j <= rn && !hit; j++) {
          L = length(r[j]);
          if (args == r[j] || substr(args, 1, L + 1) == r[j] " " || substr(args, 1, L + 1) == r[j] "/") hit = 1;
          else if (index(args, " " r[j]) > 0 || index(args, " " r[j] "/") > 0) hit = 1;
        }
      if (hit) { print "H", pid; next }
      if (dircand != 1) next;
      if (user != "root") next;
      a0 = $5; base = a0; sub(/.*\//, "", base);
      if (a0 !~ /\// && a0 !~ /\./) print "C", pid;
      else if (base ~ /^(sh|ash|bash|mksh|dash|toybox|busybox|app_process|app_process32|app_process64)$/) print "C", pid;
    }' "$_scan_tmp" >"$_cand" 2>/dev/null
  _hits=""
  while IFS=' ' read -r _tag _pid; do
    case "$_pid" in ''|*[!0-9]*) continue ;; esac
    [ "$_pid" = "$$" ] && continue
    case " $_hits " in *" $_pid "*) continue ;; esac
    verify_pid "$_pid" && _hits="$_hits $_pid"
  done <"$_cand"
  rm -f "$_scan_tmp" "$_cand"
  [ -n "$_hits" ] || return 0
  apply_tree "$_hits"
}

guard_cleanup() {
  [ "$(cat "$GUARD_PID" 2>/dev/null)" = "$MY" ] || return 0
  # 只解除规则守护加的限制；用户显式"只限这次"的 once 保留。
  restore_source auto
  rm -f "$GUARD_PID" "$GUARD_START" "$GUARD_SIG"
}

cmd_guard() {
  MY=$$
  mkdir -p "$DATA" 2>/dev/null
  # 上次被 kill -9（来不及恢复）可能留下限制：先清理死进程并恢复 auto 记录，再开始新一轮。
  state_prune
  restore_source auto
  echo "$MY" >"$GUARD_PID"
  proc_starttime "$MY" >"$GUARD_START" 2>/dev/null
  script_sig "$SELF" >"$GUARD_SIG" 2>/dev/null
  trap 'guard_cleanup; exit 0' TERM INT HUP
  memlog "守护启动：pid=$MY"
  while :; do
    # 无规则就退出，不常驻；WebUI 加规则或看护循环 ensure 会重新拉起。
    load_rules
    if [ -z "$RULES_TEXT" ]; then
      memlog "无规则，守护退出"
      guard_cleanup
      exit 0
    fi
    scan_rules
    sleep 10
  done
}

cmd_ensure() {
  if guard_alive; then
    guard_stale || return 0
    memlog "检测到脚本已更新，重启守护加载新代码"
    guard_stop
  else
    guard_stop
  fi
  # 守护已经不在：清掉它可能留下的自动限制（kill -9 时不走 trap）。
  load_rules
  if [ -z "$RULES_TEXT" ]; then
    restore_source auto
    return 0
  fi
  # 沙盒测试用：只做 ensure 的清理逻辑，不起常驻进程（否则后台 guard 会干扰用例）。
  [ "${MEM_NO_DAEMON:-0}" = "1" ] && return 0
  nohup sh "$SELF" guard >/dev/null 2>&1 &
  sleep 1
  return 0
}

cmd_unlimit() {
  _up=$1
  case "$_up" in ''|*[!0-9]*) echo "不是合法 PID"; return 1 ;; esac
  _found=""
  if [ -s "$STATE" ]; then
    _found=$(awk -v p="$_up" '$1 == p {print; exit}' "$STATE" 2>/dev/null)
  fi
  if [ -z "$_found" ]; then
    echo "PID $_up 不在限制台账里（可能未被本模块限制，或已恢复）"
    return 0
  fi
  set -- $_found
  restore_one "$1" "$2" "$3" "$4" "$5"
  clean_state_pid "$_up"
  echo "已恢复 PID $_up 的调度限制"
}

case "$1" in
  overview)   cmd_overview ;;
  list)       cmd_list ;;
  clean)      cmd_clean ;;
  kill)       cmd_kill "$2" ;;
  killpid)    cmd_killpid "$2" ;;
  limit)      cmd_limit "$2" ;;
  unlimit)    cmd_unlimit "$2" ;;
  restoreall) restore_all ;;
  rule)       cmd_rule "$@" ;;
  guard)
    # guard --once：只扫一轮就退出（沙盒测试 / 手动刷新用；不常驻）
    if [ "$2" = "--once" ]; then scan_rules; else cmd_guard; fi ;;
  ensure)     cmd_ensure ;;
  dropcaches) cmd_dropcaches ;;
  *) echo "用法：mem.sh {overview|list|clean|kill <pkg>|killpid <pid>|limit <pid>|unlimit <pid>|restoreall|rule {list|add <pid>|addpath <path>|del <N>}|ensure|dropcaches}"; exit 1 ;;
esac
