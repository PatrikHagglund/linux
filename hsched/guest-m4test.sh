#!/bin/bash
#
# guest-m4test.sh — M4 /init: per-entity proportional share.
#
# The 2010 design set utilization via per-entity quantum (1000/100/10 Hz ->
# ~90/9/1%). The modern equivalent is cgroup weight, which hsched honors via
# weighted vtime. Three saturated cgroups with cpu.weight 1000/100/10 should
# split CPU ~90/9/1%. Measures each cgroup's usage over a window. Throwaway guest.
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
echo "HSCHED: kernel $(uname -r)  nr_cpus $NCPU"

field() { local k v; while read -r k v; do [ "$k" = "$2" ] && { echo "$v"; return; }; done < "$1" 2>/dev/null; }

echo "+cpu" > "$CG/cgroup.subtree_control" 2>/dev/null
for g in A B C; do mkdir -p "$CG/$g" 2>/dev/null || fail "mkdir $g"; done
echo 1000 > "$CG/A/cpu.weight"; echo 100 > "$CG/B/cpu.weight"; echo 10 > "$CG/C/cpu.weight"
echo "HSCHED: weights A=$(cat $CG/A/cpu.weight) B=$(cat $CG/B/cpu.weight) C=$(cat $CG/C/cpu.weight)"

BIN=/usr/local/bin/scx_hsched
[ -x "$BIN" ] || fail "no scx_hsched"
"$BIN" >/tmp/hsched.log 2>&1 &      # default weighted vtime, no -F
SCXPID=$!
for i in $(seq 1 15); do [ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] && break; sleep 1; done
[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" = "enabled" ] || fail "did not enable: $(tail -2 /tmp/hsched.log|tr '\n' '|')"
echo "HSCHED: sched_ext enabled ops=$(cat /sys/kernel/sched_ext/root/ops)"

# saturate every cgroup: NCPU spinners each so all compete for all CPUs
for g in A B C; do
    ( echo $BASHPID > "$CG/$g/cgroup.procs" 2>/dev/null
      for n in $(seq 1 "$NCPU"); do timeout 6 bash -c 'while :; do :; done' & done
      wait ) &
done

sleep 1
a0=$(field "$CG/A/cpu.stat" usage_usec); b0=$(field "$CG/B/cpu.stat" usage_usec); c0=$(field "$CG/C/cpu.stat" usage_usec)
sleep 4
a1=$(field "$CG/A/cpu.stat" usage_usec); b1=$(field "$CG/B/cpu.stat" usage_usec); c1=$(field "$CG/C/cpu.stat" usage_usec)

da=$(( a1 - a0 )); db=$(( b1 - b0 )); dc=$(( c1 - c0 )); tot=$(( da + db + dc ))
[ "$tot" -gt 0 ] || fail "no CPU usage recorded (da=$da db=$db dc=$dc)"
pa=$(( da * 100 / tot )); pb=$(( db * 100 / tot )); pc=$(( dc * 100 / tot ))
echo "HSCHED: usage_usec  A=$da B=$db C=$dc"
echo "HSCHED: CPU split   A=${pa}% B=${pb}% C=${pc}%   (target ~90/9/1)"

# cleanup
for g in A B C; do for p in $(cat "$CG/$g/cgroup.procs" 2>/dev/null); do kill "$p" 2>/dev/null; done; done
sleep 1; kill "$SCXPID" 2>/dev/null; sleep 1

# accept if ordering holds and A dominates (weighted share working)
if [ "$da" -gt "$db" ] && [ "$db" -gt "$dc" ] && [ "$pa" -ge 75 ]; then
    echo "HSCHED: RESULT PASS"
else
    echo "HSCHED: RESULT FAIL"
fi
exit 0
