#!/usr/bin/env bash
#
# mkinitramfs.sh — build a self-contained initramfs for the hsched test VM.
#
# RHEL's qemu-kvm has no 9p/virtfs, so instead of sharing the host root we bake a
# tiny RAM rootfs: a handful of host binaries + their libs (gathered via ldd) +
# all built scx schedulers + a chosen /init script. Device nodes (/dev/console
# etc.) are created with the kernel's own usr/gen_init_cpio, which needs no root.
#
#   hsched/mkinitramfs.sh <init-script> <out.cpio.gz>
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/.." && pwd)"
INIT_SRC="${1:?usage: mkinitramfs.sh <init-script> <out.cpio.gz>}"
OUT="${2:?usage: mkinitramfs.sh <init-script> <out.cpio.gz>}"
GEN="$TREE/usr/gen_init_cpio"
[ -x "$GEN" ] || { echo "ERROR: $GEN missing — run 'make LLVM=1 usr/' in the tree." >&2; exit 1; }

# Host binaries the guest /init needs (busybox absent → use the real ones).
BINS=(/bin/bash /bin/sh /usr/bin/cat /usr/bin/ls /usr/bin/sleep /usr/bin/seq
      /usr/bin/kill /usr/bin/tail /usr/bin/head /usr/bin/mkdir /usr/bin/sync
      /usr/bin/tr /usr/bin/sort /usr/bin/cut /usr/bin/uname /usr/bin/timeout
      /usr/bin/nproc /usr/bin/env /usr/bin/grep /usr/bin/wc /usr/bin/awk
      /usr/bin/rm /usr/bin/cp /usr/bin/touch /bin/mount /sbin/halt)
# HSCHED_CC=1 adds a C compiler + make for the real make -j build test (M5).
# clang resolves to clang-19; its ~194M lib closure is gathered via ldd.
if [ "${HSCHED_CC:-0}" = 1 ]; then
    BINS+=(/usr/bin/clang /usr/bin/make)
fi
# All built scx schedulers (installed into the guest at /usr/local/bin).
SCX_BINS=()
for b in "$TREE"/tools/sched_ext/build/bin/*; do [ -x "$b" ] && SCX_BINS+=("$b"); done

# Resolve real paths, drop dups/missing.
resolve() { for f in "$@"; do [ -e "$f" ] && readlink -f "$f"; done | sort -u; }
mapfile -t REAL_BINS < <(resolve "${BINS[@]}")

# Gather shared-lib closure (incl. ELF interpreter) for every ELF we ship.
# IMPORTANT: clear LD_LIBRARY_PATH (vm.sh sets it for pahole) so libs resolve to
# their real system paths (/lib64/...), not to ~/.local — the guest has no ~/.local.
gather_libs() {
    for b in "$@"; do env -u LD_LIBRARY_PATH ldd "$b" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*'; done | sort -u
}
mapfile -t LIBS < <(gather_libs "${REAL_BINS[@]}" "${SCX_BINS[@]}")

SPEC="$(mktemp)"; trap 'rm -f "$SPEC"' EXIT
emit_dirs() {  # emit a `dir` line for every parent dir, shallow→deep, unique
    printf '%s\n' "$@" | while read -r p; do d="$(dirname "$p")"; while [ "$d" != "/" ]; do echo "$d"; d="$(dirname "$d")"; done; done \
        | sort -u | awk '{print length, $0}' | sort -n | cut -d' ' -f2-
}

{
    echo "# --- base dirs ---"
    for d in /proc /sys /dev /tmp /mnt /run /usr /usr/local /usr/local/bin; do echo "dir $d 0755 0 0"; done
    echo "# --- device nodes (no root needed) ---"
    echo "nod /dev/console 0600 0 0 c 5 1"
    echo "nod /dev/null    0666 0 0 c 1 3"
    echo "nod /dev/ttyS0   0660 0 0 c 4 64"
    echo "nod /dev/tty     0666 0 0 c 5 0"

    # collect every dir we will need from the file set
    ALLFILES=("${REAL_BINS[@]}" "${LIBS[@]}")
    echo "# --- parent dirs ---"
    emit_dirs "${ALLFILES[@]}" | while read -r d; do echo "dir $d 0755 0 0"; done

    echo "# --- host binaries (at original paths) ---"
    for b in "${REAL_BINS[@]}"; do echo "file $b $b 0755 0 0"; done
    echo "# --- shared libs + interpreter ---"
    for l in "${LIBS[@]}"; do echo "file $l $l 0755 0 0"; done
    echo "# --- scx schedulers -> /usr/local/bin ---"
    for s in "${SCX_BINS[@]}"; do echo "file /usr/local/bin/$(basename "$s") $s 0755 0 0"; done
    echo "# --- usr-merge compat symlinks (binaries live under /usr/* after readlink) ---"
    echo "slink /bin  /usr/bin  0777 0 0"
    echo "slink /sbin /usr/sbin 0777 0 0"
    echo "# --- init ---"
    echo "file /init $INIT_SRC 0755 0 0"
} > "$SPEC"

echo ">>> initramfs spec: ${#REAL_BINS[@]} bins, ${#SCX_BINS[@]} scx, ${#LIBS[@]} libs"
# -1 keeps build fast for the large (clang) image; boot-time decompression is
# unaffected by level. Small images compress in well under a second either way.
"$GEN" "$SPEC" | gzip "${HSCHED_GZ:--1}" > "$OUT"
echo ">>> wrote $OUT ($(du -h "$OUT" | cut -f1))"
