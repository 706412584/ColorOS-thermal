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

case "$1" in
  overview)   cmd_overview ;;
  list)       cmd_list ;;
  clean)      cmd_clean ;;
  kill)       cmd_kill "$2" ;;
  killpid)    cmd_killpid "$2" ;;
  dropcaches) cmd_dropcaches ;;
  *) echo "用法：mem.sh {overview|list|clean|kill <pkg>|dropcaches}"; exit 1 ;;
esac
