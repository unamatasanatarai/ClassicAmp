#!/usr/bin/env bash
# Live CPU / RAM monitor for this app only, with scrolling history.
#
#   scripts/monitor.sh [-n name] [-i seconds] [-l file.csv]
#     -n  process name            (default: APP_NAME from scripts/config.sh)
#     -i  sample interval, secs   (default: 1; decimals allowed, e.g. 0.5)
#     -l  also append samples to a CSV file: time,pid,cpu_pct,rss_mb
#   q or Ctrl-C quits.
#
# CPU% is exact per interval (delta of the process's CPU time / wall time; 100% = one core).
# RAM is resident memory (RSS). One `ps` per sample; `pgrep` only when the app (re)starts.

if ((BASH_VERSINFO[0] < 5)); then
    printf 'Needs bash 5+ (for EPOCHREALTIME). Try: /usr/local/bin/bash %s\n' "$0" >&2
    exit 1
fi

script_dir=${BASH_SOURCE[0]%/*}
[[ $script_dir == "${BASH_SOURCE[0]}" ]] && script_dir=.
name=""
interval=1
logfile=""
while getopts "n:i:l:h" opt; do
    case $opt in
        n) name=$OPTARG ;;
        i) interval=$OPTARG ;;
        l) logfile=$OPTARG ;;
        *) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
    esac
done
if [[ -z $name ]]; then
    # shellcheck source=/dev/null
    [[ -f $script_dir/config.sh ]] && source "$script_dir/config.sh"
    name=${APP_NAME:-ClassicAmp}
fi
[[ $interval =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "bad interval: $interval" >&2; exit 1; }
if [[ -n $logfile && ! -s $logfile ]]; then
    printf 'time,pid,cpu_pct,rss_mb\n' >"$logfile" || exit 1
fi

spark=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
cpu_hist=() ram_hist=()           # tenths of a percent / KB; "-" marks "not running"
pid="" last_cs=-1 last_us=0 peak_cpu=0 peak_ram=0 samples=0 events=""
shopt -s checkwinsize

cleanup() { printf '\e[?25h\e[?1049l'; exit 0; }
trap cleanup INT TERM EXIT
printf '\e[?1049h\e[?25l'          # alternate screen, hide cursor

# "1:02:03.45" / "02:03.45" -> centiseconds (sets $cs)
to_cs() {
    local t=$1 h=0 m s
    IFS=: read -r a b c <<<"$t"
    if [[ -n $c ]]; then h=$a m=$b s=$c; else m=$a s=$b; fi
    cs=$(( (10#$h * 3600 + 10#$m * 60) * 100 + 10#${s%.*} * 100 + 10#${s#*.} ))
}
# tenths -> "12.3" (sets $out)
fmt1() { printf -v out '%d.%d' $(($1 / 10)) $(($1 % 10)); }
# KB -> "123.4 MB" (sets $out)
fmt_mb() { local t=$(($1 * 10 / 1024)); printf -v out '%d.%d MB' $((t / 10)) $((t % 10)); }

# Renders history array named $1 into $graph, scaled lo..hi.
render() {
    local -n h=$1
    local lo=$2 hi=$3 v i span=$(($3 - $2))
    graph=""
    for v in "${h[@]}"; do
        if [[ $v == - ]]; then graph+=" "; continue; fi
        if ((span <= 0)); then i=0; else i=$(( (v - lo) * 7 / span )); fi
        ((i < 0)) && i=0; ((i > 7)) && i=7
        graph+=${spark[i]}
    done
}
# Window stats for history named $1 (sets min max avg n)
stats() {
    local -n h=$1
    local v sum=0
    min=-1 max=0 n=0
    for v in "${h[@]}"; do
        [[ $v == - ]] && continue
        ((n++, sum += v))
        ((v > max)) && max=$v
        ((min < 0 || v < min)) && min=$v
    done
    ((min < 0)) && min=0
    avg=$((n ? sum / n : 0))
}

while :; do
    width=$(( ${COLUMNS:-100} - 8 ))
    ((width < 20)) && width=20

    if [[ -z $pid ]]; then
        pid=$(pgrep -x "$name" | head -n1)
        if [[ -n $pid ]]; then
            last_cs=-1
            printf -v ts '%(%H:%M:%S)T' -1
            [[ -n $events ]] && events="restarted (pid $pid) at $ts"
        fi
    fi

    line=""
    [[ -n $pid ]] && line=$(ps -o time=,rss=,etime= -p "$pid" 2>/dev/null)
    now_us=${EPOCHREALTIME//[.,]/}   # "." or "," depending on locale

    if [[ -z $line ]]; then
        [[ -n $pid ]] && events="exited (pid $pid)"
        pid="" cpu="-" rss="-"
        status="waiting for $name to start…"
    else
        read -r cputime rss etime <<<"$line"
        to_cs "$cputime"
        if ((last_cs < 0)); then
            cpu=0
        else
            # tenths of a percent = dCPU(us) * 1000 / dWall(us)
            cpu=$(( (cs - last_cs) * 10000 * 1000 / (now_us - last_us) ))
        fi
        last_cs=$cs
        ((cpu > peak_cpu)) && peak_cpu=$cpu
        ((rss > peak_ram)) && peak_ram=$rss
        ((samples++))
        status="pid $pid   up $etime   samples $samples"
        events=${events:-started}
        if [[ -n $logfile ]]; then
            fmt1 "$cpu"; c=$out
            printf '%(%Y-%m-%dT%H:%M:%S)T,%s,%s,%d.%d\n' -1 "$pid" "$c" $((rss / 1024)) $((rss % 1024 * 10 / 1024)) >>"$logfile"
        fi
    fi
    last_us=$now_us

    cpu_hist+=("$cpu") ram_hist+=("$rss")
    ((${#cpu_hist[@]} > width)) && cpu_hist=("${cpu_hist[@]: -width}") ram_hist=("${ram_hist[@]: -width}")

    # CPU graph: 0 .. max(10%, window max). RAM graph: window min .. max.
    stats cpu_hist; c_min=$min c_max=$max c_avg=$avg
    top=$((c_max > 100 ? c_max : 100))
    render cpu_hist 0 "$top"; cpu_graph=$graph
    stats ram_hist; r_min=$min r_max=$max r_avg=$avg
    render ram_hist "$r_min" "$r_max"; ram_graph=$graph

    fmt1 "$top"; top_s=$out
    if [[ $cpu == - ]]; then cpu_s="  -  "; else fmt1 "$cpu"; cpu_s="$out%"; fi
    fmt1 "$c_avg"; ca=$out; fmt1 "$c_min"; cmn=$out; fmt1 "$c_max"; cmx=$out; fmt1 "$peak_cpu"; cpk=$out
    if [[ $rss == - ]]; then ram_s="  -  "; else fmt_mb "$rss"; ram_s=$out; fi
    fmt_mb "$r_avg"; ra=$out; fmt_mb "$r_min"; rmn=$out; fmt_mb "$r_max"; rmx=$out; fmt_mb "$peak_ram"; rpk=$out
    printf -v span '%ds' "$(( ${#cpu_hist[@]} * ${interval%.*} ))"
    [[ $interval == *.* ]] && span="${#cpu_hist[@]} samples"

    printf '\e[H\e[J'
    printf '\e[1m%s\e[0m   %s   every %ss   history %s%s\n\n' "$name" "$status" "$interval" "$span" "${logfile:+   log → $logfile}"
    printf '\e[1;36mCPU\e[0m  now \e[1m%-7s\e[0m avg %-6s min %-6s max %-6s peak %s%%   (100%% = 1 core)\n' "$cpu_s" "$ca%" "$cmn%" "$cmx%" "$cpk"
    printf '%6s%% ┤\e[36m%s\e[0m\n' "$top_s" "$cpu_graph"
    printf '%7s ┤\n\n' "0%"
    printf '\e[1;35mRAM\e[0m  now \e[1m%-10s\e[0m avg %-9s min %-9s max %-9s peak %s\n' "$ram_s" "$ra" "$rmn" "$rmx" "$rpk"
    printf '%8s ┤\e[35m%s\e[0m\n' "${rmx% MB}M" "$ram_graph"
    printf '%8s ┤\n\n' "${rmn% MB}M"
    printf '\e[2m%s   ·   q to quit\e[0m\n' "${events:-}"

    # Sleep for the interval, but quit immediately on "q". (No terminal on stdin: plain sleep.)
    if [[ -t 0 ]]; then
        if read -rsn1 -t "$interval" key && [[ $key == q ]]; then break; fi
    else
        sleep "$interval"
    fi
done
