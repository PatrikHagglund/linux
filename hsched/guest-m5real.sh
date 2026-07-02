#!/bin/bash
#
# guest-m5real.sh — M5 REAL build /init: parallel C compilation as make -j load.
#
# Generates real C source and runs `make -j(2*nr_cpus)` (clang -O2 per file) under
# two schedulers in one boot:
#   Phase 1: stock EEVDF (no BPF scheduler)
#   Phase 2: scx_hsched, build cgroup FIFO + run-to-block (-S 50000)
# Reports wall-clock, context switches, and cgroup CPU usage per phase. Unlike the
# spinner proxy, compiler jobs do real CPU work AND file I/O (they block), so this
# also exercises backfill-on-block. Header-free sources (-nostdinc) avoid needing
# system headers in the initramfs. Throwaway RAM guest.
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
NCPU=$(nproc); JOBS=$(( NCPU * 2 ))
NFILES=$(( NCPU * 6 ))                 # ~6 translation units per CPU
CC=clang-19

field()  { local k v; while read -r k v; do [ "$k" = "$2" ] && { echo "$v"; return; }; done < "$1" 2>/dev/null; }
ctxt()   { field /proc/stat ctxt; }
# centiseconds from /proc/uptime (two decimals) -> integer, 10ms resolution
csnow()  { local u _; read -r u _ < /proc/uptime; echo "${u%.*}${u#*.}"; }

command -v "$CC" >/dev/null || fail "no $CC in initramfs (need HSCHED_CC=1)"
command -v make  >/dev/null || fail "no make in initramfs"
echo "HSCHED: kernel $(uname -r)  nr_cpus $NCPU  build: $NFILES files, make -j$JOBS, $CC -O2"

# --- generate a real (header-free) C translation unit, then fan out to NFILES ---
SRC=/tmp/src; mkdir -p "$SRC"
{
  echo "static int tbl[256];"
  for f in $(seq 1 18); do
    echo "int fn_${f}(int x){int s=x;"
    for i in $(seq 1 160); do echo "  s=(s*$(( i*7+1 )))^(s>>$(( i%13+1 )))+tbl[(s+$i)&255];"; done
    echo "  tbl[x&255]=s; return s;}"
  done
} > "$SRC/u0.c"
for n in $(seq 1 "$NFILES"); do cp "$SRC/u0.c" "$SRC/u$n.c"; done
rm -f "$SRC/u0.c"
cat > "$SRC/Makefile" <<EOF
SRCS := \$(wildcard u*.c)
OBJS := \$(SRCS:.c=.o)
all: \$(OBJS)
%.o: %.c
	$CC -c -O2 -nostdinc \$< -o \$@
EOF
echo "HSCHED: generated $(ls "$SRC"/u*.c | wc -l) source files (~$(wc -l < "$SRC/u1.c") lines each)"

# run `make -jJOBS` inside build/ cgroup; record wall (centiseconds) + ctxt delta
do_phase() {
    local label=$1
    rm -f "$SRC"/*.o
    local c0 t0 c1 t1 nobj
    c0=$(ctxt); t0=$(csnow)
    ( echo $BASHPID > "$CG/build/cgroup.procs" 2>/dev/null
      cd "$SRC" && make -j"$JOBS" >/tmp/make.log 2>&1 )
    t1=$(csnow); c1=$(ctxt)
    nobj=$(ls "$SRC"/*.o 2>/dev/null | wc -l)
    local wall=$(( t1 - t0 ))
    echo "HSCHED: $label wall=$(( wall/100 )).$(( wall%100 ))s ctxt_delta=$(( c1 - c0 )) objs=$nobj build_usec=$(field "$CG/build/cpu.stat" usage_usec)"
    BUILT=$nobj; LAST_WALL=$wall; LAST_CTXT=$(( c1 - c0 ))
}

echo "+cpu" > "$CG/cgroup.subtree_control" 2>/dev/null
mkdir -p "$CG/build" 2>/dev/null || fail "mkdir build"

echo "HSCHED: === Phase 1: stock EEVDF (no scx) ==="
do_phase EEVDF
E_WALL=$LAST_WALL; E_CTXT=$LAST_CTXT; E_OBJ=$BUILT
[ "$E_OBJ" = "$NFILES" ] || fail "EEVDF build incomplete ($E_OBJ/$NFILES): $(tail -2 /tmp/make.log|tr '\n' '|')"

echo "HSCHED: === Phase 2: scx_hsched FIFO run-to-block ==="
/usr/local/bin/scx_hsched -F "$CG/build" -S 50000 >/tmp/hsched.log 2>&1 &
SCXPID=$!
for i in $(seq 1 15); do [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] && break; sleep 1; done
[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] || fail "scx_hsched did not enable"
grep -q -- "-> FIFO" /tmp/hsched.log && echo "HSCHED: build/ -> FIFO run-to-block"
do_phase HSCHED
H_WALL=$LAST_WALL; H_CTXT=$LAST_CTXT; H_OBJ=$BUILT
kill "$SCXPID" 2>/dev/null; sleep 1

echo "HSCHED: COMPARISON wall_cs eevdf=$E_WALL hsched=$H_WALL | ctxt eevdf=$E_CTXT hsched=$H_CTXT"
if [ "$E_OBJ" = "$NFILES" ] && [ "$H_OBJ" = "$NFILES" ]; then
    echo "HSCHED: RESULT PASS"
else
    echo "HSCHED: RESULT FAIL"
fi
exit 0
