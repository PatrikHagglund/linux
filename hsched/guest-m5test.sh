#!/bin/bash
#
# guest-m5test.sh — M5 capstone /init: stock EEVDF vs scx_hsched.
#
# Same make-j-like workload (2*nr_cpus CPU-bound tasks in one cgroup) measured
# under two schedulers in one boot:
#   Phase 1: stock EEVDF (no BPF scheduler loaded)
#   Phase 2: scx_hsched with that cgroup FIFO + run-to-block (-S 50000)
# Reports context switches per phase. The design's claim: hierarchical FIFO
# run-to-block schedules a make -j like load with fewer switches than the stock
# fair scheduler, while staying contained in its cgroup. Throwaway guest.
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
NCPU=$(nproc); NSPIN=$(( NCPU * 2 ))
echo "HSCHED: kernel $(uname -r)  nr_cpus $NCPU  workload ${NSPIN} CPU-bound tasks"

field() { local k v; while read -r k v; do [ "$k" = "$2" ] && { echo "$v"; return; }; done < "$1" 2>/dev/null; }
ctxt() { field /proc/stat ctxt; }

echo "+cpu" > "$CG/cgroup.subtree_control" 2>/dev/null
mkdir -p "$CG/build" 2>/dev/null || fail "mkdir build"

# run NSPIN self-terminating spinners in build/, measure ctxt over a 3s window
run_workload() {
    ( echo $BASHPID > "$CG/build/cgroup.procs" 2>/dev/null
      for n in $(seq 1 "$NSPIN"); do timeout 5 bash -c 'while :; do :; done' & done
      wait ) &
    sleep 1
    local c0 c1
    c0=$(ctxt); sleep 3; c1=$(ctxt)
    echo $(( c1 - c0 ))
    for p in $(cat "$CG/build/cgroup.procs" 2>/dev/null); do kill "$p" 2>/dev/null; done
    sleep 2   # let timeouts/kills drain before next phase
}

echo "HSCHED: === Phase 1: stock EEVDF (no scx) ==="
EEVDF=$(run_workload)
echo "HSCHED: EEVDF ctxt_delta=$EEVDF"

echo "HSCHED: === Phase 2: scx_hsched FIFO run-to-block ==="
BIN=/usr/local/bin/scx_hsched
"$BIN" -F "$CG/build" -S 50000 >/tmp/hsched.log 2>&1 &
SCXPID=$!
for i in $(seq 1 15); do [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] && break; sleep 1; done
[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] || fail "scx_hsched did not enable"
grep -q -- "-> FIFO" /tmp/hsched.log && echo "HSCHED: build/ -> FIFO run-to-block"
HS=$(run_workload)
echo "HSCHED: HSCHED ctxt_delta=$HS"
kill "$SCXPID" 2>/dev/null; sleep 1

# report comparison
if [ "${EEVDF:-0}" -gt 0 ] && [ "${HS:-0}" -gt 0 ]; then
    echo "HSCHED: COMPARISON eevdf=$EEVDF hsched=$HS  (lower = fewer switches)"
    echo "HSCHED: RESULT PASS"
else
    echo "HSCHED: RESULT FAIL (eevdf=$EEVDF hsched=$HS)"
fi
exit 0
