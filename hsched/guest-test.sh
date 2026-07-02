#!/bin/bash
#
# guest-test.sh — one-shot /init inside the initramfs test VM (see mkinitramfs.sh
# + vm.sh selftest). Boots, loads scx_flatcg, asserts sched_ext activates, runs a
# little load, powers off. Prints HSCHED: markers the host greps for PASS/FAIL.
# Throwaway RAM guest — never touches the host.
#
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH

# /dev/console exists (baked in), but mount devtmpfs so the rest of /dev is live,
# then make sure our stdio is the serial console.
mount -t devtmpfs none /dev 2>/dev/null || true
exec >/dev/console 2>&1 </dev/console

mount -t proc    proc  /proc 2>/dev/null
mount -t sysfs   sysfs /sys  2>/dev/null
mount -t tmpfs   tmpfs /tmp  2>/dev/null
mount -t tmpfs   tmpfs /run  2>/dev/null
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
[ -w /sys/fs/cgroup/cgroup.subtree_control ] && echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

poweroff_now() { sync; echo o > /proc/sysrq-trigger 2>/dev/null; sleep 5; halt -f 2>/dev/null; }
trap poweroff_now EXIT

echo "HSCHED: kernel $(uname -r)"
echo "HSCHED: nr_cpus $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
echo "HSCHED: sched_ext sysfs = $(ls /sys/kernel/sched_ext 2>/dev/null | tr '\n' ' ')"

# scheduler to test comes from kernel cmdline token "scxbin=NAME" (default flatcg)
# parsed with bash builtins only (no sed in the initramfs)
SCXBIN=scx_flatcg
for tok in $(cat /proc/cmdline 2>/dev/null); do
    case "$tok" in scxbin=*) SCXBIN="${tok#scxbin=}" ;; esac
done
BIN=/usr/local/bin/$SCXBIN
[ -x "$BIN" ] || { echo "HSCHED: FAIL no $SCXBIN in initramfs"; echo "HSCHED: RESULT FAIL"; exit 0; }

echo "HSCHED: loading $SCXBIN ..."
"$BIN" >/tmp/flatcg.log 2>&1 &
SCXPID=$!

ok=FAIL
for i in $(seq 1 15); do
    st=$(cat /sys/kernel/sched_ext/state 2>/dev/null)
    if [ "$st" = "enabled" ]; then
        echo "HSCHED: sched_ext state=$st ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)"
        ok=PASS; break
    fi
    sleep 1
done

# prove tasks actually schedule under the BPF scheduler
( for c in 1 2 3 4; do (timeout 2 sh -c 'while :; do :; done') & done; wait ) 2>/dev/null
echo "HSCHED: workload ran under ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)"

kill "$SCXPID" 2>/dev/null; sleep 1
echo "HSCHED: scx_flatcg log tail: $(tail -2 /tmp/flatcg.log 2>/dev/null | tr '\n' '|')"
echo "HSCHED: RESULT $ok"
exit 0
