#!/bin/bash
#
# guest-init.sh — PID 1 inside the nested test VM (see hsched/vm.sh).
#
# The host root is mounted read-only over 9p, so we mount tmpfs over the dirs
# that must be writable, bring up the pseudo-filesystems, mount cgroup2 (for the
# hierarchical-scheduling tests), expose the kernel tree at /mnt/work, then drop
# into an interactive shell. Everything here is throwaway — nothing touches the
# host. To leave the VM: type 'poweroff -f' or kill qemu with Ctrl-A x.
#
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# pahole/scx libs live under the user's ~/.local on the (9p) host root:
export LD_LIBRARY_PATH=/home/uabpath/.local/lib:/home/uabpath/.local/lib64

echo "[guest-init] mounting pseudo-filesystems ..."
mount -t proc     proc     /proc      2>/dev/null
mount -t sysfs    sysfs    /sys       2>/dev/null
mount -t devtmpfs devtmpfs /dev       2>/dev/null || true
mount -t tmpfs    tmpfs    /tmp       2>/dev/null
mount -t tmpfs    tmpfs    /run       2>/dev/null
mount -t tmpfs    tmpfs    /var/tmp   2>/dev/null

echo "[guest-init] mounting cgroup2 (unified) at /sys/fs/cgroup ..."
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
# enable the cpu controller for child cgroups (needed by the hsched tests)
if [ -w /sys/fs/cgroup/cgroup.subtree_control ]; then
    echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

echo "[guest-init] mounting kernel tree (9p 'work') at /mnt/work ..."
mkdir -p /mnt/work
mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 work /mnt/work 2>/dev/null \
    && echo "[guest-init]   -> /mnt/work ready (scx binaries: /mnt/work/tools/sched_ext/build/bin)" \
    || echo "[guest-init]   -> WARN: could not mount work share"

cat <<'EOF'

  ============================================================
   hierarchical-scheduling test VM  (nested qemu-kvm guest)
  ------------------------------------------------------------
   kernel : $(uname -r)
   sched  : cat /sys/kernel/sched_ext/state   (after loading)
   load   : /mnt/work/tools/sched_ext/build/bin/scx_flatcg   # baseline
            (scx_hsched once built)
   cgroup : /sys/fs/cgroup   (cpu controller enabled)
   quit   : poweroff -f   (or host-side Ctrl-A x)
  ============================================================

EOF
uname -r
echo "sched_ext state: $(cat /sys/kernel/sched_ext/state 2>/dev/null || echo '(node not present)')"

exec /bin/bash -i
