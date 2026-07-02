#!/usr/bin/env bash
#
# fedora-install.sh — build & install this kernel + scx_hsched INSIDE a Fedora
# guest (e.g. Fedora 44 under GNOME Boxes), as an ADDITIONAL boot entry. The
# distro kernel is left untouched; the new one is added via BLS/GRUB and you
# pick it at boot.
#
# Run this from the root of a checkout of the 'hierarchical-scheduling' branch,
# INSIDE the Fedora VM:
#     git clone --depth 1 -b hierarchical-scheduling \
#         https://github.com/PatrikHagglund/linux.git
#     cd linux && ./hsched/fedora-install.sh
#
# It bases the config on the *running* Fedora kernel (so all the VM's hardware,
# Btrfs root, systemd and cgroup options are already correct) and just adds the
# sched_ext + BTF options scx needs.
#
set -euo pipefail
[ -f Makefile ] && grep -q "^NAME = " Makefile || { echo "run from the kernel source root" >&2; exit 1; }
JOBS="$(nproc)"

echo "== 1/5 build dependencies (dnf) =="
sudo dnf install -y \
    git make gcc flex bison bc rsync perl python3 \
    openssl-devel elfutils-libelf-devel ncurses-devel \
    dwarves \
    clang llvm bpftool libbpf-devel
# dwarves = pahole (required by CONFIG_DEBUG_INFO_BTF, which sched_ext needs).
# clang/llvm/bpftool build the BPF scheduler.

echo "== 2/5 configure (base on running Fedora kernel + enable sched_ext) =="
if [ -r "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" .config
else
    echo "WARN: /boot/config-$(uname -r) not found; falling back to fedora_defconfig/defconfig"
    make fedora_defconfig 2>/dev/null || make defconfig
fi
# sched_ext + BPF + BTF + cgroup CPU controller
./scripts/config \
    -e SCHED_CLASS_EXT -e BPF_SYSCALL -e BPF_JIT -e BPF_JIT_ALWAYS_ON \
    -e DEBUG_INFO -e DEBUG_INFO_BTF -e PAHOLE_HAS_SPLIT_BTF \
    -e CGROUPS -e CGROUP_SCHED -e FAIR_GROUP_SCHED -e CGROUP_BPF -e FTRACE
# Fedora configs point at Red Hat signing keys we don't have — clear them so the
# out-of-tree build doesn't fail looking for certificates.
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
./scripts/config -d MODULE_SIG_FORCE
# unique version string so it installs alongside the Fedora kernel
./scripts/config --set-str LOCALVERSION "-hsched"
./scripts/config -d LOCALVERSION_AUTO
make olddefconfig
echo "   config: SCHED_CLASS_EXT=$(./scripts/config -s SCHED_CLASS_EXT) DEBUG_INFO_BTF=$(./scripts/config -s DEBUG_INFO_BTF)"

echo "== 3/5 build kernel (-j$JOBS) — this is the slow part =="
make -j"$JOBS"

echo "== 4/5 install modules + kernel (adds a BLS/GRUB entry; distro kernel kept) =="
sudo make modules_install
sudo make install
echo "   installed kernel: $(make -s kernelrelease)"

echo "== 5/5 build the scx_hsched scheduler =="
make -C tools/sched_ext -j"$JOBS"
echo "   scheduler binary: $PWD/tools/sched_ext/build/bin/scx_hsched"

cat <<EOF

Done. Reboot and pick "$(make -s kernelrelease)" in the GRUB menu.
(If the VM uses UEFI Secure Boot, disable it first — this kernel is unsigned.)

After booting into it, see hsched/README-fedora.md for how to load the
scheduler and run a 'make -j' under a FIFO run-to-block cgroup.
EOF
