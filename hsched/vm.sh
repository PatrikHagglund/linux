#!/usr/bin/env bash
#
# hsched/vm.sh — build & boot the hierarchical-scheduling kernel in a NESTED VM.
#
# This server (seroiuts00835) runs an old 4.18 host kernel with no sched_ext, is
# shared, and we are not root. So we NEVER boot the new kernel on the host — we
# boot the freshly built 7.2 bzImage inside a qemu-kvm guest, with the host
# filesystem shared read-only over 9p (instant userland, no disk image). A panic
# or scheduler lockup only kills the guest; Ctrl-A x (or Ctrl-C) returns you here.
#
# Prereqs (already satisfied on this box as of setup):
#   - pahole v1.31 built into ~/.local         (DEBUG_INFO_BTF needs it)
#   - clang 19, bpftool, llvm-strip in PATH     (kernel via LLVM=1; BPF prog)
#   - /usr/libexec/qemu-kvm + /dev/kvm usable as our user
#
# Usage:
#   hsched/vm.sh env           # print the tool env (pahole) and exit
#   hsched/vm.sh kernel        # build the kernel (make LLVM=1)
#   hsched/vm.sh scx           # build tools/sched_ext (the scx schedulers)
#   hsched/vm.sh boot          # boot bzImage in qemu, host / as 9p root
#   hsched/vm.sh all           # kernel + scx, then boot
#
set -euo pipefail

# --- locate the kernel tree (parent of this script's dir) -------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/.." && pwd)"
cd "$TREE"

# --- tool env: pahole from ~/.local, build with clang -----------------------
export PATH="$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib:$HOME/.local/lib64:${LD_LIBRARY_PATH:-}"
JOBS="$(nproc)"
MAKE=(make LLVM=1 "-j$JOBS")

QEMU="${QEMU:-/usr/libexec/qemu-kvm}"
SMP="${SMP:-8}"          # guest vCPUs — keep < host 16 so scheduling is meaningful
MEM="${MEM:-8G}"
BZIMAGE="arch/x86/boot/bzImage"

need_pahole() {
    command -v pahole >/dev/null 2>&1 || {
        echo "ERROR: pahole not found in PATH ($HOME/.local/bin). Build dwarves first." >&2
        exit 1
    }
    echo "using pahole: $(pahole --version)  ($(command -v pahole))"
}

cmd_env() {
    need_pahole
    echo "tree:   $TREE"
    echo "make:   ${MAKE[*]}"
    echo "qemu:   $QEMU   smp=$SMP mem=$MEM"
}

cmd_kernel() {
    need_pahole
    [ -f .config ] || { echo "ERROR: no .config — run the M0 config steps first." >&2; exit 1; }
    echo ">>> building kernel ($JOBS jobs, clang) ..."
    "${MAKE[@]}"
    echo ">>> built $BZIMAGE"
    ls -lh "$BZIMAGE"
}

cmd_scx() {
    need_pahole
    echo ">>> building tools/sched_ext ..."
    "${MAKE[@]}" -C tools/sched_ext
    echo ">>> scx binaries:"
    ls -1 tools/sched_ext/build/bin/ 2>/dev/null || echo "(check tools/sched_ext build output)"
}

# RHEL qemu-kvm has no 9p/virtfs, so we boot a self-contained initramfs instead
# of sharing the host root. INITRD is (re)built from the chosen init script.
INITRD="${INITRD:-$TREE/hsched/initramfs.cpio.gz}"

build_initrd() {  # $1 = init script
    "$HERE/mkinitramfs.sh" "$1" "$INITRD"
}

cmd_boot() {
    [ -f "$BZIMAGE" ] || { echo "ERROR: $BZIMAGE missing — run '$0 kernel' first." >&2; exit 1; }
    [ -w /dev/kvm ]  || echo "WARN: /dev/kvm not writable; VM will be slow (no KVM accel)."
    build_initrd "$HERE/guest-init.sh"
    echo ">>> booting $BZIMAGE in qemu (smp=$SMP mem=$MEM). Exit guest: 'poweroff -f' or Ctrl-A x."
    exec "$QEMU" -enable-kvm -cpu host -smp "$SMP" -m "$MEM" -nographic \
        -kernel "$BZIMAGE" -initrd "$INITRD" \
        -append "console=ttyS0 rdinit=/init nokaslr"
}

cmd_selftest() {
    [ -f "$BZIMAGE" ] || { echo "ERROR: $BZIMAGE missing — run '$0 kernel' first." >&2; exit 1; }
    local scx="${1:-scx_flatcg}"                       # which scheduler to smoke-test
    local log="${HSCHED_LOG:-/tmp/hsched-selftest-$scx.log}"
    build_initrd "$HERE/guest-test.sh"
    echo ">>> unattended boot + sched_ext smoke test of '$scx' (timeout 120s), log: $log"
    timeout 120 "$QEMU" -enable-kvm -cpu host -smp "$SMP" -m "$MEM" -nographic -no-reboot \
        -kernel "$BZIMAGE" -initrd "$INITRD" \
        -append "console=ttyS0 rdinit=/init scxbin=$scx nokaslr" \
        > "$log" 2>&1 || true
    echo "----- HSCHED markers -----"
    grep "HSCHED:" "$log" || { echo "(no markers — see $log)"; tail -20 "$log"; }
    grep -q "HSCHED: RESULT PASS" "$log" && { echo ">>> SELFTEST PASS"; return 0; }
    echo ">>> SELFTEST FAIL"; return 1
}

cmd_cgtest() {
    [ -f "$BZIMAGE" ] || { echo "ERROR: $BZIMAGE missing — run '$0 kernel' first." >&2; exit 1; }
    local log="${HSCHED_LOG:-/tmp/hsched-cgtest.log}"
    build_initrd "$HERE/guest-cgtest.sh"
    echo ">>> unattended per-cgroup FIFO (M2/M3) test (timeout 75s), log: $log"
    timeout --kill-after=5 75 "$QEMU" -enable-kvm -cpu host -smp "$SMP" -m "$MEM" -nographic -no-reboot \
        -kernel "$BZIMAGE" -initrd "$INITRD" \
        -append "console=ttyS0 rdinit=/init nokaslr" \
        > "$log" 2>&1 || true
    echo "----- HSCHED markers -----"
    grep "HSCHED:" "$log" || { echo "(no markers — see $log)"; tail -20 "$log"; }
    grep -q "HSCHED: RESULT PASS" "$log" && { echo ">>> CGTEST PASS"; return 0; }
    echo ">>> CGTEST FAIL"; return 1
}

cmd_vmtest() {  # generic: boot an init script unattended, grep HSCHED markers
    local init="$1" log="$2" tmo="${3:-90}"
    [ -f "$BZIMAGE" ] || { echo "ERROR: $BZIMAGE missing — run '$0 kernel' first." >&2; exit 1; }
    build_initrd "$init"
    echo ">>> unattended VM test $(basename "$init") (timeout ${tmo}s), log: $log"
    timeout --kill-after=5 "$tmo" "$QEMU" -enable-kvm -cpu host -smp "$SMP" -m "$MEM" -nographic -no-reboot \
        -kernel "$BZIMAGE" -initrd "$INITRD" \
        -append "console=ttyS0 rdinit=/init nokaslr" > "$log" 2>&1 || true
    echo "----- HSCHED markers -----"; grep "HSCHED:" "$log" || { echo "(no markers — see $log)"; tail -20 "$log"; }
    grep -q "HSCHED: RESULT PASS" "$log" && { echo ">>> PASS"; return 0; }
    echo ">>> FAIL"; return 1
}

case "${1:-}" in
    env)      cmd_env ;;
    kernel)   cmd_kernel ;;
    scx)      cmd_scx ;;
    boot)     cmd_boot ;;
    selftest) cmd_selftest "${2:-scx_flatcg}" ;;
    cgtest)   cmd_cgtest ;;
    m4test)   cmd_vmtest "$HERE/guest-m4test.sh" "${HSCHED_LOG:-/tmp/hsched-m4.log}" 90 ;;
    m5test)   cmd_vmtest "$HERE/guest-m5test.sh" "${HSCHED_LOG:-/tmp/hsched-m5.log}" 90 ;;
    m5real)   export HSCHED_CC=1; MEM="${MEM_M5:-14G}"; cmd_vmtest "$HERE/guest-m5real.sh" "${HSCHED_LOG:-/tmp/hsched-m5real.log}" 240 ;;
    all)      cmd_kernel; cmd_scx; cmd_selftest "${2:-scx_flatcg}" ;;
    *) echo "usage: $0 {env|kernel|scx|boot|selftest [scx_name]|cgtest|m4test|all}"; exit 2 ;;
esac
