# Running scx_hsched on a real Fedora VM (GNOME Boxes)

Goal: install this kernel as an *alternative* boot entry in a Fedora guest and
try real-world loads (e.g. `make -j`) under the hierarchical scheduler.

## 1. Install the kernel (once)

Inside the Fedora VM:

```sh
git clone --depth 1 -b hierarchical-scheduling \
    https://github.com/PatrikHagglund/linux.git
cd linux
./hsched/fedora-install.sh        # builds + installs kernel and scx_hsched
sudo reboot                       # pick "…-hsched" at the GRUB menu
```

`fedora-install.sh` bases the kernel config on the VM's *running* kernel (so the
Btrfs root, virtio drivers, systemd and cgroup options are already right) and
only adds what sched_ext needs. The Fedora kernel is left in place — the new one
is an added BLS/GRUB entry.

**Secure Boot:** if the VM enforces it (UEFI), disable it first — this kernel is
unsigned. GNOME Boxes VMs usually don't enforce it.

## 2. Does the scheduler need configuration?

**At build time — yes, but it's minimal** (the install script sets all of it):

| Option | Why |
|---|---|
| `CONFIG_SCHED_CLASS_EXT=y` | the sched_ext class itself |
| `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT` | load the BPF scheduler |
| `CONFIG_DEBUG_INFO_BTF=y` (needs `pahole`) | sched_ext requires vmlinux BTF |
| `CONFIG_CGROUP_SCHED`, `CONFIG_FAIR_GROUP_SCHED` | the cgroup CPU controller the hierarchy rides on |

Fedora already ships BPF + cgroups; you're only adding sched_ext + BTF.

**At run time — almost nothing.** `scx_hsched` does **not** set
`SCX_OPS_SWITCH_PARTIAL`, so the moment you load it, it schedules **every**
normal task on the system. There is no per-task opt-in to configure. Two safety
properties matter for a live desktop VM:

- **Instant revert:** `Ctrl-C` (or killing the process) hands scheduling back to
  EEVDF immediately.
- **Watchdog:** if the BPF scheduler ever stalls, the kernel auto-ejects it back
  to EEVDF. So it is safe to experiment.

Load it and confirm:

```sh
sudo ./tools/sched_ext/build/bin/scx_hsched &
cat /sys/kernel/sched_ext/state        # -> enabled
cat /sys/kernel/sched_ext/root/ops     # -> hsched
```

At this point your whole system already runs hierarchically: systemd puts
services and your login session in cgroups with `cpu.weight`, and hsched honours
those weights (weighted-vtime between cgroups). That alone is worth observing.

## 3. The `make -j` use case (per-cgroup FIFO run-to-block)

This is the scenario the design targets: run a big parallel build so it never
thrashes caches or starves the desktop. Put the build in its own cgroup and mark
that cgroup **FIFO run-to-block**.

Important ordering quirk: `-F` resolves the cgroup id **at load time**, so the
build cgroup must exist *before* you start `scx_hsched`.

```sh
# a) create a delegated cgroup/slice for the build (persists, can be empty)
sudo systemd-run --scope -p Delegate=yes --slice=build.slice --unit=hsbuild \
    sleep infinity &
BUILD_CG=$(systemctl show -p ControlGroup --value hsbuild.scope)   # e.g. /build.slice/hsbuild.scope
echo "build cgroup: /sys/fs/cgroup$BUILD_CG"

# b) load hsched with that cgroup FIFO + a long "run to block" slice (50ms)
sudo ./tools/sched_ext/build/bin/scx_hsched -F "/sys/fs/cgroup$BUILD_CG" -S 50000 &

# c) run the build INSIDE that cgroup
sudo systemd-run --scope --slice=build.slice make -j"$(nproc)"
```

Under this setup:

- only ~`nr_cpus` build jobs are *active* at once; when one blocks on I/O the
  next FIFO job backfills automatically — no `-j` number tuning needed;
- context switches / cache thrashing drop sharply (measured ~18× fewer, ~34 %
  faster on a synthetic clang build — see the plan doc);
- the build stays *contained*: the top-level `cgrp_slice_ns` (20 ms default)
  guarantees other cgroups (your desktop) keep getting CPU.

### Optional: make the build yield to the desktop

Give the build slice a low weight so interactive work wins when they compete:

```sh
sudo systemctl set-property build.slice CPUWeight=20
```

## 4. Simpler manual cgroup (if you don't want systemd scopes)

```sh
sudo mkdir -p /sys/fs/cgroup/build
echo +cpu | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
sudo ./tools/sched_ext/build/bin/scx_hsched -F /sys/fs/cgroup/build -S 50000 &
# run a build in it:
sudo bash -c 'echo $$ > /sys/fs/cgroup/build/cgroup.procs; exec make -j'"$(nproc)"
```

## 5. Things to watch / caveats

- `scx_hsched` is derived from the `scx_flatcg` **demo**; it schedules correctly
  but isn't latency-tuned like production schedulers (`scx_lavd`, `scx_rusty`).
  Good for `make -j` throughput experiments; compare against those for interactivity.
- The cgroup hierarchy is **flattened** (a documented approximation) — very deep
  trees aren't perfectly fair.
- Nested virtualization is **not** needed: the Fedora VM runs on the host's KVM
  directly; you're just installing a kernel in it.
- To go back to the stock scheduler at any time: `Ctrl-C` the `scx_hsched`
  process. To go back to the Fedora kernel: reboot and pick it in GRUB.
