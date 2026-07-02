#!/usr/bin/env bash
#
# run-build.sh — one command to run a build under scx_hsched with a per-cgroup
# FIFO "run to block" slice (the make -j use case). Creates a build cgroup, loads
# scx_hsched -F on it, runs your command inside it, then cleans everything up and
# reports wall-clock + context switches.
#
#   sudo ./hsched/run-build.sh -- make -j"$(nproc)"
#   sudo ./hsched/run-build.sh -b -- make -j        # also run an EEVDF baseline
#   sudo ./hsched/run-build.sh -S 100000 -w 20 -- ./build.sh
#
# Options:
#   -S US   FIFO run-to-block slice in microseconds (default 50000 = 50ms)
#   -w N    cpu.weight for the build cgroup (default: leave systemd/default)
#   -b      first run the command once under the STOCK scheduler for comparison
#           (your command must be repeatable — e.g. include its own clean step)
#   -h      help
#
# Must run as root (loading sched_ext + moving tasks into a cgroup need it).
# If invoked via sudo, the build itself is dropped back to $SUDO_USER so build
# outputs keep normal ownership.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/.." && pwd)"
SCX="$TREE/tools/sched_ext/build/bin/scx_hsched"
SLICE_US=50000
WEIGHT=""
BASELINE=0

# print the leading comment block (lines 2.. up to the first non-comment line)
usage() { awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }
while getopts "S:w:bh" o; do case "$o" in
    S) SLICE_US=$OPTARG ;;
    w) WEIGHT=$OPTARG ;;
    b) BASELINE=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
esac; done
shift $((OPTIND-1))
if [ "${1:-}" = "--" ]; then shift; fi
[ $# -ge 1 ] || { echo "no build command given" >&2; usage 1; }
CMD=("$@")

[ "$(id -u)" -eq 0 ] || { echo "must run as root (try: sudo $0 ...)" >&2; exit 1; }
[ -x "$SCX" ] || { echo "scx_hsched not built at $SCX (run: make -C tools/sched_ext)" >&2; exit 1; }
CGROOT=$(awk '$3=="cgroup2"{print $2; exit}' /proc/mounts); CGROOT=${CGROOT:-/sys/fs/cgroup}
[ -w "$CGROOT/cgroup.subtree_control" ] || { echo "cgroup2 not writable at $CGROOT" >&2; exit 1; }

field() { local k v; while read -r k v; do [ "$k" = "$2" ] && { echo "$v"; return; }; done < "$1" 2>/dev/null; }
csnow() { local u _; read -r u _ < /proc/uptime; echo "${u%.*}${u#*.}"; }   # centiseconds

# put this shell into $1 then run "${@:2}", dropping to $SUDO_USER if present
run_cmd() {
    local cg=$1; shift
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && command -v setpriv >/dev/null; then
        bash -c 'echo $$ > "$1/cgroup.procs"; shift; exec setpriv --reuid "'"$SUDO_USER"'" \
                 --regid "'"$SUDO_USER"'" --init-groups "$@"' _ "$cg" "$@"
    else
        bash -c 'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' _ "$cg" "$@"
    fi
}

report() {   # label c0 t0 cgroup
    local lbl=$1 c0=$2 t0=$3 cg=$4 c1 t1 dt use
    c1=$(field /proc/stat ctxt); t1=$(csnow)
    use=$(field "$cg/cpu.stat" usage_usec); use=${use:-0}; dt=$(( t1 - t0 ))
    printf '  %-8s wall=%d.%02ds  ctxt_switches=%d  cgroup_cpu=%ds\n' \
        "$lbl" "$(( dt/100 ))" "$(( dt%100 ))" "$(( c1 - c0 ))" "$(( use/1000000 ))"
}

CG="$CGROOT/hsched-build.$$"
cleanup() {
    set +e
    [ -n "${SCXPID:-}" ] && kill "$SCXPID" 2>/dev/null
    for _ in $(seq 1 10); do
        [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" != enabled ] && break
        sleep 1
    done
    if [ -d "$CG" ]; then
        for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do kill "$p" 2>/dev/null; done
        rmdir "$CG" 2>/dev/null
    fi
    rm -f "/tmp/scx_hsched.$$.log"
}
trap cleanup EXIT INT TERM

# ensure the cpu controller is delegated, then make the build cgroup
if ! grep -qw cpu "$CGROOT/cgroup.subtree_control"; then
    echo +cpu > "$CGROOT/cgroup.subtree_control" 2>/dev/null || true
fi
mkdir -p "$CG"
if [ -n "$WEIGHT" ]; then echo "$WEIGHT" > "$CG/cpu.weight"; fi
echo "build cgroup: $CG   slice: ${SLICE_US}us${WEIGHT:+   weight: $WEIGHT}"

if [ "$BASELINE" = 1 ]; then
    echo "== baseline: stock scheduler =="
    c0=$(field /proc/stat ctxt); t0=$(csnow)
    run_cmd "$CG" "${CMD[@]}" || echo "  (baseline command exited non-zero)"
    report EEVDF "$c0" "$t0" "$CG"
    for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    sleep 1
fi

echo "== loading scx_hsched (FIFO run-to-block on build cgroup) =="
"$SCX" -F "$CG" -S "$SLICE_US" >"/tmp/scx_hsched.$$.log" 2>&1 &
SCXPID=$!
for _ in $(seq 1 15); do
    [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = enabled ] && break
    sleep 1
done
if [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" != enabled ]; then
    echo "scx_hsched failed to load:"; tail -5 "/tmp/scx_hsched.$$.log"; exit 1
fi
if grep -q -- '-> FIFO' "/tmp/scx_hsched.$$.log"; then echo "  build cgroup is FIFO run-to-block"; fi

echo "== build under scx_hsched =="
c0=$(field /proc/stat ctxt); t0=$(csnow)
run_cmd "$CG" "${CMD[@]}" || echo "  (build command exited non-zero)"
report HSCHED "$c0" "$t0" "$CG"

echo "done (scheduler + cgroup cleaned up on exit)."
