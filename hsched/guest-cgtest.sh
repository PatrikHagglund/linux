#!/bin/bash
#
# guest-cgtest.sh — M2/M3 /init: per-cgroup FIFO + run-to-block demonstration.
#
# Two phases in one boot, same FIFO cgroup + same 2*nr_cpus CPU-bound workload:
#   A) default FIFO slice   B) long FIFO slice (-S, "run to block", M3)
# Measures system context switches (/proc/stat ctxt) over each window. The
# long-slice phase should switch far less often — the design's cache-thrash win.
# Also confirms a FIFO cgroup coexists with a vtime sibling. Throwaway guest.
#
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH

mount -t devtmpfs none /dev 2>/dev/null || true
exec >/dev/console 2>&1 </dev/console
mount -t proc    proc  /proc 2>/dev/null
mount -t sysfs   sysfs /sys  2>/dev/null
mount -t tmpfs   tmpfs /tmp  2>/dev/null
mount -t tmpfs   tmpfs /run  2>/dev/null
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true

poweroff_now() { sync; echo o > /proc/sysrq-trigger 2>/dev/null; sleep 5; halt -f 2>/dev/null; }
trap poweroff_now EXIT
fail() { echo "HSCHED: $*"; echo "HSCHED: RESULT FAIL"; exit 0; }

CG=/sys/fs/cgroup
NCPU=$(nproc)
NSPIN=$(( NCPU * 2 ))
echo "HSCHED: kernel $(uname -r)  nr_cpus $NCPU"

echo "+cpu" > "$CG/cgroup.subtree_control" 2>/dev/null
mkdir -p "$CG/build" "$CG/inter" 2>/dev/null || fail "cannot create cgroups"
echo "HSCHED: created cgroups build/ inter/"

BIN=/usr/local/bin/scx_hsched
[ -x "$BIN" ] || fail "no scx_hsched in initramfs"

# pure-bash field reader (gawk misbehaves in the minimal initramfs)
field() { local k v; while read -r k v; do [ "$k" = "$2" ] && { echo "$v"; return; }; done < "$1" 2>/dev/null; }
ctxt()  { field /proc/stat ctxt; }
busec() { field "$CG/build/cpu.stat" usage_usec; }
iusec() { field "$CG/inter/cpu.stat" usage_usec; }

# spawn 2*nr_cpus self-terminating spinners into build/, NCPU into inter/.
# subshells move themselves in first so children inherit the cgroup.
spawn() {
    local dur=$1
    ( echo $BASHPID > "$CG/build/cgroup.procs" 2>/dev/null
      for n in $(seq 1 "$NSPIN"); do timeout "$dur" bash -c 'while :; do :; done' & done
      wait ) &
    ( echo $BASHPID > "$CG/inter/cgroup.procs" 2>/dev/null
      for n in $(seq 1 "$NCPU"); do timeout "$dur" bash -c 'while :; do :; done' & done
      wait ) &
}

PASS=1
# run one phase; prints a marker with ctxt delta + cgroup usage
run_phase() {
    local label=$1; shift          # remaining args -> scx_hsched
    "$BIN" -F "$CG/build" "$@" >/tmp/hsched.log 2>&1 &
    local pid=$! i
    for i in $(seq 1 15); do
        [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] && break
        sleep 1
    done
    if [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" != "enabled" ]; then
        echo "HSCHED: $label FAILED to enable: $(tail -2 /tmp/hsched.log | tr '\n' '|')"
        kill "$pid" 2>/dev/null; PASS=0; return 1
    fi
    grep -q -- "-> FIFO" /tmp/hsched.log && echo "HSCHED: $label per-cgroup FIFO accepted"

    local u0 c0 c1 u1 procs
    u0=$(busec)
    spawn 4
    sleep 1                          # ramp
    c0=$(ctxt)
    sleep 3                          # measurement window
    c1=$(ctxt)
    u1=$(busec)
    procs=$(cat "$CG/build/cgroup.procs" 2>/dev/null | wc -l)
    echo "HSCHED: $label ctxt_delta=$(( c1 - c0 )) build_usec_delta=$(( u1 - u0 )) build_procs=$procs inter_usec=$(iusec) state=$(cat /sys/kernel/sched_ext/state)"
    [ "$procs" -ge 1 ] || PASS=0

    for p in $(cat "$CG/build/cgroup.procs" "$CG/inter/cgroup.procs" 2>/dev/null); do kill "$p" 2>/dev/null; done
    sleep 1
    kill "$pid" 2>/dev/null
    for i in $(seq 1 10); do
        [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" != "enabled" ] && break
        sleep 1
    done
    return 0
}

echo "HSCHED: === Phase A: default FIFO slice ==="
run_phase A_default
echo "HSCHED: === Phase B: run-to-block FIFO slice (-S 50000 = 50ms) ==="
run_phase B_runtoblock -S 50000

[ "$PASS" = 1 ] && echo "HSCHED: RESULT PASS" || echo "HSCHED: RESULT FAIL"
exit 0
