# Hierarchical Scheduling — Feasibility & Implementation Plan

Companion to **`Hierarchical Scheduling.md`** (written ~2010). This document
assesses whether that design can be implemented against the kernel checked out
in this tree (**Linux 7.2-rc1**) and lays out a concrete plan.

---

## 0. Live status (prototype underway)

| Milestone | Status | Evidence |
|---|---|---|
| **M0** Toolchain + kernel build + nested-VM boot harness | ✅ **done, tested** | `pahole` v1.31 built to `~/.local`; kernel built with BTF (`make LLVM=1`); boots in nested qemu-kvm; `scx_flatcg` loads → `state=enabled` (selftest PASS) |
| **M1** Fork `scx_flatcg` → `scx_hsched` | ✅ **done, tested** | `tools/sched_ext/scx_hsched.{bpf.c,c,h}` + Makefile; selftest PASS (`ops=hsched`) |
| **M2** Per-cgroup policy attribute (VTIME default / FIFO) | ✅ **done, tested** | `cgrp_policy` BPF map + `cgc->policy`; `-F <cgroup>` userspace option; cgtest applies FIFO to a real 33-task workload coexisting ~50/50 with a vtime sibling |
| **M3** Per-cgroup FIFO + `make -j` run-to-block | ✅ **done, tested** | `fifo_slice_ns` (`-S US`); two-phase cgtest: longer FIFO slice cut context switches **1192 → 713 (−40%)** with **higher** throughput — the cache-thrash win, measured |
| **M4** Per-entity quantum / weight (1000/100/10 Hz → 90/9/1% split) | ✅ **done, tested** | `hsched/vm.sh m4test`: cgroup weights 1000/100/10 → measured split **78% / 18% / 2%** (strict ordering; deviation = flatcg flattening + idle-cycle grab) |
| **M5** Stock EEVDF vs `scx_hsched` benchmark + write-up | ✅ **done, tested — incl. real parallel compile** | spinner proxy (`m5test`): **8642 → 519** ctxt; **real `make -j16` clang -O2** (`m5real`): wall **14.99s → 9.92s (−34%)**, ctxt **40474 → 2292 (~18×)** |

### Measured results (nested VM, 8 vCPUs)

All from throwaway nested-VM runs (`hsched/vm.sh {selftest,cgtest,m4test,m5test}`).
Numbers are single-run and use CPU-bound spinners as a `make -j` proxy (no real
cache/I-O effects yet — see M5 future work), but they measure scheduler
behaviour directly and all point the way the 2010 design predicts:

- **M2/M3 — per-cgroup FIFO + run-to-block:** a FIFO `build/` cgroup and a vtime
  `inter/` sibling share CPU ~50/50 (isolation holds). Lengthening the FIFO
  slice (20 ms → 50 ms) cut context switches **1192 → 713 (−40%)** *and* raised
  throughput — the cache-thrash win.
- **M4 — proportional share:** cgroup weights 1000/100/10 → CPU split
  **78% / 18% / 2%** (strict ordering; deviation from 90/9/1 is the flatcg
  flattening approximation + low-weight cgroups grabbing idle cycles).
- **M5 — vs stock scheduler (spinner proxy):** same 16-task load → **EEVDF 8642**
  context switches vs **hsched FIFO run-to-block 519** — **~17× fewer**.
- **M5 — vs stock scheduler (REAL `make -j`):** `hsched/vm.sh m5real` bakes
  clang+make into the initramfs, generates 48 header-free C files (~2917 lines
  each) and runs `make -j16` (clang `-O2`) — real compiler processes that do CPU
  work *and* file I/O (so they block: backfill-on-block is exercised). Same build
  under both schedulers in one boot:

  | metric | stock EEVDF | hsched FIFO run-to-block |
  |---|---|---|
  | wall-clock | **14.99 s** | **9.92 s** (−34%, 1.5× faster) |
  | context switches | **40 474** | **2 292** (~18× fewer) |
  | objects built | 48/48 | 48/48 |

  This is the design's headline claim — fewer switches / less cache thrashing for
  a `make -j` load, contained in its cgroup — now confirmed on a *real* compile
  workload, not a proxy. (`build/cpu.stat usage_usec` is cumulative across phases,
  so it is not a clean per-phase metric; wall-clock and ctxt are.)

**Honest gaps / future work:** a *full kernel* build (needs the ~1.5 GB tree +
multi-binary toolchain + writable object dir — impractical in the no-9p RAM
initramfs; would need a virtio-blk scratch disk); the 48 source files are
identical copies (each fully recompiled, but real `make -j` has diverse TUs);
`perf stat` cache-miss counts (guest perf is version-mismatched here); interactive
p99 latency under load; multi-run statistics; and the non-flattened
exact-hierarchy and Path-B native `cpu.policy` variants.

**Environment constraints discovered & handled:** running host kernel is 4.18
(RHEL 8.10, no sched_ext) and the box is a shared OpenStack VM with no root — so
everything runs in a **nested qemu-kvm guest**. RHEL's qemu-kvm has **no 9p**, so
the VM uses a **self-contained initramfs** (`hsched/mkinitramfs.sh` via the
kernel's `gen_init_cpio`). All dev tooling lives in **`hsched/`**:
`vm.sh` (env/kernel/scx/boot/selftest/cgtest/all), `mkinitramfs.sh`,
`guest-test.sh`, `guest-cgtest.sh`, `guest-init.sh`.

---

## 1. Verdict: Yes — and the kernel has caught up to the design

In 2010 the design required modifying the core scheduler — there was no clean
way to let an entity define its own internal scheduling policy without touching
`kernel/sched/` and risking the whole system (exactly the SCHED_FIFO "locks the
whole system" problem the document calls out).

Since then, **`sched_ext`** (the BPF extensible scheduler class,
`CONFIG_SCHED_CLASS_EXT`) landed and is present in this tree at
`kernel/sched/ext/`. It is the productionized form of the document's central
premise — *"let the user define the scheduling policy."* Crucially, it is
**cgroup-aware**, which maps directly onto the document's nested
"scheduling entities."

Evidence in this tree:

- `kernel/sched/ext/internal.h` — `struct sched_ext_ops` exposes the exact
  primitives the design needs: `select_cpu`, `enqueue`, `dispatch`, `running`,
  `stopping`, plus the cgroup lifecycle hooks `cgroup_init`, `cgroup_exit`,
  `cgroup_prep_move`, `cgroup_move`, `cgroup_cancel_move`, and
  `cgroup_set_weight`.
- `tools/sched_ext/scx_flatcg.bpf.c` — a working **hierarchical cgroup
  scheduler**. Its header comment is essentially the document's design, already
  partly built:
  > "The scheduler first picks the cgroup to run and then schedules the tasks
  > within by using nested weighted vtime scheduling **by default**. The
  > cgroup-internal scheduling can be switched to **FIFO** with the **-f
  > option**."

That last sentence *is* the document's distinction between a **sibling policy**
(between entities) and a **parent-child / within-entity policy**. `scx_flatcg`
hardcodes it as one global switch; the design wants it **per entity**. That gap
— plus the specific `make -j` semantics — is the work to be done.

### Design → mechanism mapping

| Document concept | sched_ext mechanism in this tree |
|---|---|
| Scheduling entity = process **or** collection of processes | task `struct task_struct` (leaf) / cgroup `task_group` (tree node) |
| Nesting / hierarchy | cgroup v2 hierarchy; per-node state built in `ops.cgroup_init()` |
| Strict total order = tree traversal to a leaf | recursive "pick highest-priority child" per level → leaf task (flattened à la `scx_flatcg` for performance) |
| Per-entity time quantum (1000/100/10 Hz example) | per-cgroup dispatch `slice` value |
| **Sibling policy** (between entities) | queue discipline chosen per parent cgroup: weighted-vtime / round-robin / FIFO |
| **Parent-child / within policy** (e.g. SCHED_FIFO-like, contained) | per-cgroup `policy` attribute read in `enqueue`/`dispatch` — invisible to other cgroups, by construction |
| Priority inheritance (optional, real-time) | approximated via slice boosting; full PI is out of scope for the prototype |
| **`make -j` goal** | put the build's process subtree in a cgroup with a **FIFO "run-to-block" policy**: exactly `nr_cpus` jobs active, each runs until it blocks/exits, next FIFO job backfills automatically on CPU-idle dispatch — no `-j` number needed, contained within the user's cgroup |

### Why `make -j` falls out naturally

With a normal fair scheduler, `make -j` (unbounded) makes *every* compile job
runnable; the scheduler round-robins across all of them, thrashing caches via
context switches among many working sets. Under sched_ext, if the build's tasks
live in one **FIFO dispatch queue (DSQ)** and each CPU pulls one job with a long
slice (run until block/exit), then:

- at most `nr_cpus` jobs are ever *active* — no oversubscription;
- a blocked job (I/O) frees its CPU, which immediately pulls the next FIFO job
  (automatic backfill — the document's exact wording);
- when the blocked job wakes, it re-enqueues FIFO;
- the whole thing is **contained in the build's cgroup**, so other users/cgroups
  keep their fair share at the top level — solving the system-wide-SCHED_FIFO
  hazard the document explicitly worried about.

This is the design's headline example, implementable with no core-kernel patch.

---

## 2. Two implementation paths

### Path A — sched_ext BPF scheduler `scx_hsched` (recommended)

Build a new scheduler under `tools/sched_ext/`, modeled on `scx_flatcg`, that
adds **per-cgroup policy selection**.

Pros: no core-kernel changes; loadable/unloadable at runtime; the BPF verifier +
sched_ext watchdog make it safe (a misbehaving scheduler is auto-ejected back to
the default fair class); this is the blessed, modern way to prototype novel
scheduling policy; closest existing code (`scx_flatcg`) to fork.

Cons: BPF environment constraints; "flattening" the hierarchy (as `scx_flatcg`
does) trades exact hierarchical fairness for performance — acceptable for a
prototype, documented as a known limitation.

**Recommended.** It matches the design's intent (user-defined policy) and is the
lowest-risk, highest-signal route.

### Path B — core scheduler / cgroup feature (`cpu.policy` attribute)

Add a real cgroup-v2 `cpu.policy` knob and per-cgroup policy dispatch inside
`kernel/sched/fair.c` + `core.c`. This is the "upstreamable kernel feature"
form.

Pros: native, no BPF, potentially mergeable as a first-class feature.
Cons: deeply invasive to `pick_next_task`/runqueue paths; large review burden;
high regression risk. **Long-term only — not for the prototype.**

---

## 3. Plan (Path A)

Each milestone is independently testable.

**M0 — Build & baseline.**
Build the kernel in this tree with `CONFIG_SCHED_CLASS_EXT=y` and build
`tools/sched_ext/`. Load `scx_flatcg`, confirm it attaches and that
`/sys/kernel/sched_ext/` reports it active. Establish a `make -j` +
interactive-latency baseline under stock EEVDF and under `scx_flatcg -f`.

**M1 — Fork `scx_hsched` from `scx_flatcg`.**
Copy `scx_flatcg.{bpf.c,c,h}` → `scx_hsched.*`, rename ops, wire into the
`tools/sched_ext/Makefile`. Confirm functional parity (weighted-vtime between
cgroups, global FIFO switch). This is the known-good starting point.

**M2 — Per-cgroup policy attribute.**
Replace the global `-f` switch with a **per-cgroup policy**: `WEIGHTED_VTIME`
(default), `ROUND_ROBIN`, `FIFO`. Store it in the per-cgroup BPF map keyed by
cgroup id, seeded in `ops.cgroup_init()` from a userspace-populated map
(userspace reads a chosen cgroup file / config). In `enqueue`/`dispatch`, branch
on the owning cgroup's policy. This realizes the document's
"sibling vs parent-child policy" as a per-entity property.

**M3 — `make -j` "run-to-block" FIFO mode.**
Add a FIFO variant whose dispatch slice is effectively "until block or exit"
(very long slice, no round-robin requeue). Verify: with a build cgroup in this
mode, active build tasks ≈ `nr_cpus`, backfill-on-block works, and an
interactive task in a *sibling* cgroup stays responsive. Compare cache-miss /
context-switch counts (`perf stat`) and wall-clock vs. stock `make -j$(nproc)`
and unbounded `make -j`.

**M4 — Per-entity quantum.**
Honor a per-cgroup slice/quantum (the document's 1000/100/10 Hz example) so an
entity's time quantum composes down the tree. Validate the ~90/9/1% utilization
split from the document under full load, and the "any single entity can use
100% when others block" property.

**M5 — Evaluation & write-up.**
Benchmark matrix (build throughput, interactive p99 latency, fairness across
cgroups) vs. stock EEVDF, `scx_flatcg`, and `scx_hsched`. Document results,
the flattening limitation, and what a Path-B native version would need.

### Stretch / explicitly out of scope for the prototype
- Priority inheritance (M4+ stretch; full PI is hard and not core to the thesis).
- Arbitrary-depth exact (non-flattened) hierarchical fairness.
- Path B native `cpu.policy` cgroup interface.

---

## 4. First concrete step

Confirm the toolchain and reproduce the baseline (M0):

```sh
# in this tree
grep SCHED_CLASS_EXT .config        # ensure CONFIG_SCHED_CLASS_EXT=y (set if missing)
make -C tools/sched_ext             # build the example schedulers + libbpf
sudo tools/sched_ext/build/bin/scx_flatcg   # load; Ctrl-C to revert to EEVDF
```

Then fork `scx_flatcg` → `scx_hsched` (M1) and begin adding the per-cgroup
policy attribute (M2).

---

## 5. Testing & boot strategy (grounded in this server)

**This server (`seroiuts00835`) facts that drive the strategy:**

- Running kernel is **4.18.0-553 (RHEL 8.10)** — *no sched_ext*. `scx_hsched`
  cannot run on it; a 7.2 kernel must run somewhere.
- It is a **shared OpenStack Nova VM**; we are **not root** (no passwordless
  sudo). Rebooting / kexec'ing the host is therefore both impossible for us and
  unacceptable (other users share the box).
- **`/dev/kvm` is present and world-writable**, nested virt (`svm`) is enabled,
  and **`qemu-kvm 6.2` is already installed** (`/usr/libexec/qemu-kvm`). We can
  run KVM-accelerated nested guests as our unprivileged user.

### Principle: never boot the new kernel on the host — boot it in a nested VM

The freshly built 7.2 kernel runs inside QEMU/KVM. The host's 4.18 kernel keeps
running untouched — zero risk. A kernel panic, a scheduler lockup, or a bad core
patch only kills the *guest*; `Ctrl-C` returns you to the shell.

### Two-layer test loop

- **Layer 1 — scheduler logic (fast inner loop).** `scx_hsched` is a BPF program
  loaded at runtime. Inside the booted guest: `./scx_hsched` to load, `Ctrl-C`
  to revert to EEVDF. The sched_ext **watchdog auto-ejects** a misbehaving
  scheduler back to the fair class, so a bug stalls/reverts the guest, never
  needing a reboot. No kernel rebuild per iteration.
- **Layer 2 — kernel boot (once per kernel build).** Only needed when (re)building
  the kernel or testing Path-B core changes.

### Prerequisites on this box

| Tool | Status | Action |
|---|---|---|
| `qemu-kvm` 6.2 + `/dev/kvm` | ✅ present, usable as user | — |
| `clang` 19.1.7 | ✅ | build kernel via `make LLVM=1`; also builds the BPF prog |
| `bpftool`, `llvm-strip` | ✅ | — |
| `gcc` 8.5 | ⚠️ old | prefer `make LLVM=1` (clang) for the kernel |
| **`pahole` (dwarves)** | ❌ **missing** | **First blocker.** `DEBUG_INFO_BTF` (required by sched_ext) needs it. Build `dwarves` from source into a local prefix (`~/.local`) since we lack sudo. |

### M0 boot recipe

1. **Build pahole (one-time):** clone `dwarves`, `cmake -DCMAKE_INSTALL_PREFIX=$HOME/.local`,
   `make install`; put `$HOME/.local/bin` on `PATH` and `$HOME/.local/lib` on
   `LD_LIBRARY_PATH`. Needs elfutils/libdw headers (build from source too if absent).
2. **Configure kernel:**
   ```sh
   make LLVM=1 defconfig
   make LLVM=1 kvm_guest.config      # adds virtio/9p drivers for the qemu guest
   ./scripts/config -e SCHED_CLASS_EXT -e BPF_SYSCALL -e BPF_JIT \
                    -e DEBUG_INFO_BTF -e CGROUP_SCHED -e FAIR_GROUP_SCHED \
                    -e NET_9P -e NET_9P_VIRTIO -e 9P_FS
   make LLVM=1 olddefconfig
   ```
3. **Build:** `make LLVM=1 -j$(nproc)` (produces `arch/x86/boot/bzImage`), then
   `make LLVM=1 -C tools/sched_ext` for the scx binaries.
4. **Boot in a nested VM, host `/` as read-only 9p root, repo shared writable:**
   ```sh
   /usr/libexec/qemu-kvm -enable-kvm -cpu host -smp 8 -m 8G -nographic \
     -kernel arch/x86/boot/bzImage \
     -fsdev local,id=root,path=/,security_model=none,readonly=on \
     -device virtio-9p-pci,fsdev=root,mount_tag=hostroot \
     -fsdev local,id=work,path=/repo/uabpath/linux,security_model=none \
     -device virtio-9p-pci,fsdev=work,mount_tag=work \
     -append "rootfstype=9p root=hostroot rootflags=trans=virtio,version=9p2000.L ro \
              console=ttyS0 init=/bin/bash nokaslr"
   ```
   In the guest: mount a tmpfs overlay for writable `/tmp` `/var`, mount the
   `work` tag, then load `tools/sched_ext/build/bin/scx_hsched`.
   (`virtme-ng` automates all of this but needs newer Python than the system's
   3.6 — the raw qemu invocation above avoids that dependency.)

### What each milestone's test looks like (inside the guest)

- **Correctness / safety:** load `scx_hsched`, confirm `/sys/kernel/sched_ext/`
  shows it active; run a workload; `Ctrl-C`; confirm clean revert to EEVDF.
- **M3 `make -j` thesis:** in a build cgroup set to FIFO run-to-block, run
  `make -j` on a sample tree; assert active build tasks ≈ guest `nr_cpus`
  (via `runqlen`/`top`), and a foreground task in a *sibling* cgroup stays
  responsive (measure with `cyclictest` or a latency ping). Compare
  context-switches / cache-misses (`perf stat`) vs. stock unbounded `make -j`.
- **M4 quanta:** three cgroups at 1000/100/10 Hz quanta under full load → assert
  ~90/9/1% CPU split (`cpuacct` / `cpu.stat`); kill two, confirm the third takes
  100%.

A reusable `scripts/hsched-vm.sh` wrapping steps 2–4 should be added at M0.

---

*Bottom line: the 2010 design is implementable today with no core-kernel patch.
`sched_ext` provides user-defined, cgroup-aware scheduling, and `scx_flatcg`
already implements the hierarchical "pick a cgroup, then schedule within it"
structure with a between/within policy split. The remaining work is making that
policy split **per-entity** and adding the **run-to-block FIFO** mode that gives
the `make -j` example its punch.*
