# Why Docker does not just work on Android

Every obstacle below produced a symptom that pointed somewhere else. They are
recorded here so nobody has to rediscover them.

## The kernel

Stock Android kernels ship without the namespaces and cgroup controllers
containers need. On this device `/proc/self/ns/` held only `cgroup mnt net uts`
— no `user`, `pid` or `ipc` — and `/proc/cgroups` had neither `pids` nor
`devices`. That part is a config fix ([kernel/container.config](../kernel/container.config)).

### The part that is not a config fix

A kernel built from `LineageOS/android_kernel_xiaomi_sm8150 @ lineage-23.2`
compiles cleanly, boots, reaches Android userspace — and then the device
reboots with:

```
ro.boot.bootreason = reboot,bpfloader-failed
```

The ROM sets `ro.bpf.kver_override=5.4.299`, so Android's `netbpfload` believes
it is on a 5.4 kernel and skips the `DEVMAP_HASH`→`HASH` downgrade it applies
only below 5.4. It then asks for `BPF_MAP_TYPE_DEVMAP_HASH` (25) and prog types
`CGROUP_SOCK_ADDR` (18) and `CGROUP_SOCKOPT` (25). A pristine 4.14 tops out at
map type 15 and prog type 14, so `BPF_MAP_CREATE` returns `-EINVAL`, the loader
aborts, and init reboots the device.

```
                        lineage-23.2      the ROM's tree
include/uapi/linux/bpf.h    30,242 B          135,278 B
BPF_PROG_TYPE_ entries            15                 36
kernel/bpf/btf.c              absent            present
```

**Every `CONFIG_BPF*` symbol was byte-identical between the two builds.** A
config diff cannot see a missing subsystem. This is why the build script gates
on *source* capability, not config.

## The chroot

**`/sdcard` is unusable.** It is FUSE and mounted `noexec`. The rootfs must live
on `/data`, which is `rw,nosuid,nodev` — crucially without `noexec`.

**proot cannot work.** It emulates via ptrace and cannot give Docker real
namespaces or cgroup writes.

**The chroot root must be a mount point, not a directory.** Docker unpacks each
image layer in a private mount namespace, starting with
`mount("", "/", NULL, MS_REC|MS_SLAVE, NULL)`. On a plain directory that
returns `EINVAL`:

```
failed to register layer: Error processing tar file(exit status 1):
remount /, flags: 0x84000: invalid argument
```

`0x84000` is exactly `MS_REC|MS_SLAVE`. Bind-mount the root onto itself.

**`/dev` must be its own tmpfs.** `/data` is `nodev`, so device nodes created
there exist but cannot be opened. tmpfs carries no `nodev`.

**`/etc/resolv.conf` is a dangling symlink** to
`/run/systemd/resolve/stub-resolv.conf`. With an empty tmpfs on `/run` and no
systemd-resolved, writing *through* it fails with `ENOENT`. Delete the link
first.

## runc

`pivot_root(2)` is defined against the **mount namespace** root, which inside a
chroot is still Android's `/`. Every container dies with:

```
error jailing process inside rootfs: pivot_root .: invalid argument
```

`DOCKER_RAMDISK=1` makes the runc executor use `MS_MOVE` + `chroot` instead.
Upstream ships that flag for initramfs roots, which have the same property.

Note that Debian's `runc` and `containerd` are ELF `ET_EXEC` — non-PIE. Android's
bionic linker rejects non-PIE binaries with `unexpected e_type: 2`, which is why
shipping prebuilt static `runc` into Android userspace never worked. Inside the
chroot they are loaded by the kernel's `binfmt_elf` instead, and it is a
non-issue.

## Networking — the hard part

Android does not use a conventional routing table. `netd` installs a table per
network (`wlan0`, `rmnet_data*`) selected by fwmark and uid rules, and it
**deletes the usual `32766: from all lookup main` rule**. The rule list ends at:

```
32000:	from all unreachable
```

Docker's bridge routes live in `main`. Without help they are never consulted and
every container packet is dropped. Three fixes are needed, and each one only
reveals the next:

1. **Egress** — `ip rule add from 172.16.0.0/12 lookup <uplink>`, or container
   packets have no default route.
2. **Return path** — `ip rule add to 172.16.0.0/12 lookup main`, or replies are
   un-NAT'd to a container address that nothing can route to.
3. **Forwarding** — `tetherctrl_FORWARD` ends in `DROP all` because tethering is
   off, and `FORWARD` reaches it before anything Docker installs. Insert ACCEPT
   rules ahead of it.

Two further details matter:

- Rules must be scoped to Docker's whole pool (`172.16.0.0/12`), not just
  `docker0`'s `/16`. Every compose project creates a new bridge on the next free
  `/16` behind a `br-<id>` interface.
- Install one egress rule **per uplink**. `wlan0` and `rmnet_data*` both carry
  default routes; pinning to `wlan0` breaks the moment you leave Wi-Fi. A
  routing table with no default route falls through to the next rule, so
  ordering the rules by preference gives automatic failover.

`netd` rewrites its rules on every connectivity change, so these must be
re-applied — `service.sh` re-asserts them at boot and every 120 s.

`CONFIG_BRIDGE_NETFILTER` is **not** required, despite Docker's
`check-config.sh` flagging it. It governs filtering of traffic *bridged* between
containers, not routed NAT.

## Storage

`overlay2` works on f2fs. Docker warns that f2fs is not a supported backing
filesystem; it functions regardless.
