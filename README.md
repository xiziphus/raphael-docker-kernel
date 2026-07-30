# raphael-docker-kernel

Real Docker on a Xiaomi Redmi K20 Pro / Mi 9T Pro (`raphael`), Android 16.

Not proot, not an emulator, not a VM. A container-capable kernel plus a Debian
chroot on `/data`, with `dockerd` running natively on the phone's own ARM64
silicon.

```
$ dockerctl run --rm hello-world
Hello from Docker!   (arm64v8)
```

## What actually runs

Verified on Project Infinity-X 3.11 / Android 16 / `4.14.356-openela-rc1-perf`:

| | |
|---|---|
| Docker | 20.10.24, runc 1.1.5 |
| Storage | `overlay2` on f2fs |
| cgroups | v2, `memory` + `pids` |
| Networking | bridge, NAT egress. **Published ports are phone-local**; use `--network=host` or a tunnel for LAN/remote |
| Tested workload | ERPNext — 11 containers (MariaDB, 2× Redis, Frappe backend, websocket, scheduler, 2× queue workers, nginx) |

ERPNext idles at **~534 MB** across all eleven containers and answers HTTP 200
from another machine on the network.

## Lineage

```
Linux 4.14 LTS
 └─ OpenELA 4.14.356                     post-EOL LTS continuation
     └─ raphael-resources/android_kernel_xiaomi_sm8150 @ 16.2
        the ROM's own tree · head 6035a52657a2 · 4.14.356-openela-rc1-perf
         ├─ drivers/kernelsu             KernelSU-Next, in-tree
         ├─ fs/susfs.c                   SUSFS, in-tree
         └─ + kernel/container.config    the only kernel change this project makes
```

**This project adds one config fragment.** It does not patch kernel source, and
it does not add KernelSU or SUSFS — both are already in that tree.

### Trees that do not work, and why

| Tree | Outcome |
|---|---|
| `LineageOS/android_kernel_xiaomi_sm8150 @ lineage-23.2` | Compiles, boots, reaches userspace, then reboots at `bpfloader`. Android 16's `netbpfload` needs eBPF backports only the ROM tree carries |
| `SOVIET-ANDROID/kernel_xiaomi_raphael` | The v1.0 lineage. Bootlooped on this ROM; superseded |

The LineageOS failure is worth one more line because it is invisible to the
obvious check: **every `CONFIG_BPF*` symbol is byte-identical between the two
trees.** The difference is 105 KB of missing `include/uapi/linux/bpf.h` and an
absent `kernel/bpf/btf.c`. A config diff cannot see a missing subsystem, which
is why the build script gates on *source* capability rather than config.
Full account in [docs/ANDROID-NOTES.md](docs/ANDROID-NOTES.md).

### Credits

| | |
|---|---|
| Kernel tree | [raphael-resources/android_kernel_xiaomi_sm8150](https://github.com/raphael-resources/android_kernel_xiaomi_sm8150) |
| Root | [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next), in-tree |
| Hiding | [SUSFS](https://gitlab.com/simonpunk/susfs4ksu), in-tree |
| Toolchain | AOSP Clang 18.0.1 (r522817) |
| Recovery zip | [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) |
| Boot image tools | AOSP `mkbootimg`; `magiskboot` from [Magisk](https://github.com/topjohnwu/Magisk) |
| Rootfs | Debian 12 (bookworm) |
| Tunnel / UI | Cloudflare `cloudflared`, Portainer CE |
| Predecessor | [xiziphus/kernel_xiaomi_raphael_antigravity](https://github.com/xiziphus/kernel_xiaomi_raphael_antigravity) — build harness and failure history |

Builds identify as `antigravitykernel@antigravity` in `/proc/version`. That is
cosmetic: it does not affect `uname -r`, which the ROM matches against.

## Dependencies

Split by when you need them — most people need only the first group.

**To flash and run**

- `raphael` (Redmi K20 Pro / Mi 9T Pro) on an Android 16 ROM
- **KernelSU already working.** 4.14 is not GKI, so KernelSU must be *compiled
  into* the kernel — you cannot install a module to get root. If you have none,
  that is Path A above
- The KernelSU-Next manager app
- ~600 MB for the Debian rootfs, plus space for images, on `/data`
- A network connection for the one-time setup

**Fetched on-device, automatically**

`docker.io` and `iptables` at setup; `openssh-server` when you enable SSH; the
`cloudflared` arm64 binary when you start a tunnel — it is not in Debian's
archive, so it comes from Cloudflare's releases.

**To build the kernel yourself**

Docker, AOSP Clang 18.0.1 r522817, git, python3, ~40 GB — and a
**case-sensitive filesystem**. 4.14's netfilter ships both `xt_CONNMARK.h` and
`xt_connmark.h`; on a case-insensitive volume one silently overwrites the other
and the tree is quietly corrupt. See [docs/BUILDING.md](docs/BUILDING.md).

**On your computer — all optional**

Nothing here is needed to run Docker on the phone; it is for driving it from a
desktop. See [docs/DESKTOP.md](docs/DESKTOP.md).

| | For | Note |
|---|---|---|
| `ssh` | shell access | over the tunnel or the LAN |
| `cloudflared` | tunnel access | only for the `ssh1.…` path; LAN needs nothing |
| `terminal-notifier` | notification relay | macOS registers it with alert style **None**, so notifications are accepted, filed silently into Notification Centre, and never appear. Set it to Banners |
| `adb` | boot-partition backup | the chroot cannot see `/data`, so this is the only way |

## Which path applies to you

Everything hinges on one question: **do you already have KernelSU working?**

This is a 4.14 kernel, which is *not* GKI. KernelSU therefore has to be
**compiled into the kernel** — it cannot be added as a loadable module the way
it can on GKI 5.10+ devices. So if you have no root today, you cannot install a
KernelSU module to get it: you have to flash a kernel that already contains it.

Check by installing the **KernelSU-Next** manager app and opening it. It will
either report a version (you have root) or say it is not installed.

| Your situation | Path |
|---|---|
| **No root yet** | **A** — recovery zip, then the module zip |
| Any raphael ROM, **KernelSU already working** | **B** — just the zip |
| Running a LineageOS / SOVIET / other custom kernel, with root | **B** — the zip replaces whatever kernel you have |
| **Android 17** | **C** — build it yourself; this release is Android 16 only |

---

### Path A — no root yet

You need a KernelSU-enabled kernel before a KernelSU module can run. Flash the
**AnyKernel3** zip in a custom recovery (TWRP, OrangeFox):

```
1. Copy antigravity-docker-kernel-vX.Y.Z-AnyKernel3.zip to the phone
2. Boot to recovery -> Install -> select the zip
3. Reboot
```

It brings its own tools and does not need `/data` decrypted, so it works in
recovery where a KernelSU module cannot. It unpacks the boot image **already on
your device**, swaps in only the kernel, and writes it back — your ramdisk, DTB
and security patch level are untouched. It refuses to run on the wrong device or
the wrong Android version.

That kernel contains KernelSU, so now:

```
4. Install the KernelSU-Next manager app - it should report a version
5. KernelSU app -> Modules -> install raphael-docker-kernel-vX.Y.Z.zip
   (it sees the kernel is already capable and skips the kernel step)
6. Reboot, open the module, tap ACTION -> install Docker
```

*No recovery installed?* `fastboot flash boot boot-INFINITYX-3.11-ONLY.img` does
the same job, but **only** if you are on Infinity-X 3.11 exactly — that image
carries one device's ramdisk and `os_patch_level`, and on any other build it
will bootloop or make `/data` unreadable. Prefer the AnyKernel3 zip.

### Path B — you already have KernelSU

No PC needed at all.

```
1. KernelSU app -> Modules -> Install from storage
2. Pick raphael-docker-kernel-vX.Y.Z.zip
3. It asks: "Patch your boot image with the Docker kernel?"  -> VOL+ (yes)
   It asks: "Start Docker automatically at every boot?"      -> your choice
4. Reboot
5. Open the module in the KernelSU app -> tap ACTION -> install Docker (~550 MB)
6. Tap ACTION again any time to start/stop, open the web UI, or repair
```

This replaces **only the kernel**. Whatever you are running now — the ROM's own
kernel, a LineageOS build, SOVIET, anything — is swapped out while your ramdisk,
DTB and security patch level are kept exactly as they were. Your previous boot
image is saved to `/data/adb/docker/boot-backup-<timestamp>.img`.

Coming from a non-Infinity-X ROM is untested. The kernel is built from the
raphael tree and preserves your ramdisk, so it should work — but you have the
backup, and you should copy it off the phone before you start.

### Path C — Android 17

Do not install this release. It is built from the kernel tree's `16.2` branch;
Android 17 needs `17.0`. The installer will warn you and make you confirm.
See [docs/BUILDING.md](docs/BUILDING.md) — change the branch, build, then
`tools/make-zip.sh`.

## After it is installed

Everything runs through one command, or the ACTION button in the KernelSU app.

For the web UI: tap **ACTION** and choose the web UI, or from a shell
`su -c 'dockerctl ui start'` then `su -c 'dockerctl ui admin YOUR-PASSWORD'`,
and open `http://127.0.0.1:9000` on the phone.

### You need root for those commands

`dockerctl` manages mounts, routing rules and the boot partition, so it runs as
root. Two ways to get there:

- **No shell needed** — in the KernelSU manager, open this module and tap
  **Action**. It walks you through setup, start/stop, the web UI and repairs
  using the volume keys. This is the easiest path and needs no grant.
- **From a shell** — grant root to your terminal app (or **Shell** for `adb`)
  in the KernelSU manager first, under *SuperUser*. Without it, `su` fails with
  `inaccessible or not found`, which looks like the module is broken when it
  is not.

### It patches your boot image; it does not replace it

The installer reads your current boot partition, swaps in only the kernel, and
repacks. Your ramdisk, DTB, cmdline and **security patch level** are preserved.

That last one is not a detail. Android derives its file-based-encryption keys
from `os_patch_level`; flashing an image with someone else's value makes
`/data` unreadable and presents as data corruption. Shipping a prebuilt
`boot.img` cannot avoid this. Patching in place cannot cause it.

Your original boot image is backed up to
`/data/adb/docker/boot-backup-<timestamp>.img` before anything is written, and
the repacked kernel is verified to still carry the arm64 `ARMd` magic before
the write happens.

## What it can do

### Containers

Docker 20.10.24 with runc 1.1.5, `overlay2` on f2fs, cgroup v2 (`memory`,
`pids`). `run`, `build`, `compose` (v1), volumes, bridge and host networking,
restart policies. Images are arm64.

**`docker exec` does not work.** Containers are entered with `MS_MOVE` +
`chroot` rather than `pivot_root`, which cannot work inside a chroot, so an
exec'd process lands at Android's `/` instead of the container rootfs. Use
`docker run` against the same volumes and network. A corollary: every image
`HEALTHCHECK` is an exec, so containers with one report `(unhealthy)` forever
and `depends_on: condition: service_healthy` deadlocks.

### Networking

Android's `netd` installs a routing table per network selected by fwmark, and
deletes the usual `lookup main` rule, so Docker's bridge routes are never
consulted. Three rule classes fix it — per-uplink egress, return path, and a
`FORWARD` accept ahead of `tetherctrl_FORWARD`'s `DROP` — scoped to
`172.16.0.0/12` so every compose project's bridge is covered, with automatic
failover between Wi-Fi and mobile. `netd` rewrites its rules on any
connectivity change, so ours are re-asserted every 60 s.

**Published ports are not reachable from the LAN.** `-p 8080:80` works on the
phone itself. For anything else use `--network=host` or a tunnel.

### Remote access — three independent paths

| Path | Survives |
|---|---|
| SSH on loopback, via the tunnel | — |
| SSH on the LAN | tunnel down, Cloudflare down, no internet |
| Cloudflare tunnel | CGNAT, no port forwarding, no public IP |

**Both `sshd` and `cloudflared` run as chroot processes, not containers**, so
every path survives dockerd being stopped, crashed or mid-upgrade — which is
exactly when you need a shell. The boot service brings them up *before* Docker
and supervises them every 60 s.

`asu` gives an Android root shell from inside the chroot, so one SSH session
reaches the boot partition, `/data/adb`, `dumpsys` and `pm`.

### Staying alive

Android autosleeps whenever nothing holds a wakelock — measured at **75
suspend/resume cycles in 30 seconds** during an active build. Containers freeze,
schedulers miss ticks, and tunnels drop mid-stream.

- **Wakelock**: `off` / `auto` (only while a watched container runs) / `always`
- **Lifeline floor**: a *separate* lock held whenever SSH or a tunnel is up, so
  remote access can never be suspended away by the workload lock releasing
- **Battery guard**: on battery below a cutoff, stops containers → Docker →
  tunnel → SSH → *then* releases the locks, in that order, and says why
- **Status notification** in the shade: LAN address, container count, tunnel and
  SSH state, power
- **LAN address publishing** — DHCP moves the phone; this puts the current
  address somewhere readable when nothing can connect

### Managing it

Three surfaces, all equivalent:

```text
dockerctl setup                  one-time Debian + Docker install
dockerctl start | stop           the daemon (restores containers it stopped)
dockerctl status | doctor --fix  summary; check every prerequisite and repair
dockerctl net apply|check|clear  Android routing and firewall rules
dockerctl ui start|admin <pw>    Portainer on :9000
dockerctl tunnel named|token|quick|stop|status|log
dockerctl ssh on|off|lan on|off|status
dockerctl wake off|auto|always|add <ct>|rm <ct>|floor on|off|status
dockerctl power guard on|off|cutoff <pct>|notify on|off|stopall|status
dockerctl lan now|on|off|ip|status
dockerctl relay new|reset        new SMS and notifications, for the desktop
dockerctl shell                  a shell in the Debian chroot
dockerctl ps / run / compose     passed straight to docker
```

**Careful:** `dockerctl start` and `stop` control the *daemon*. To act on a
container use `dockerctl container start <name>` — the bare verbs are shadowed
and ignore their arguments.

A **WebUI** in the KernelSU manager covers the same ground with toggles, a
container list and per-container wakelock pills. An **ACTION menu** driven by
the volume keys covers setup, start/stop and repair for anyone with no shell.

### From a computer

See [docs/DESKTOP.md](docs/DESKTOP.md).

- **Notification relay** — mirrors the phone's SMS and app notifications onto
  macOS. No app installed on the phone, no notification-listener permission:
  with root, `content://sms/inbox` and `dumpsys notification` are already
  readable
- **State snapshots** — `tools/state-snapshot.sh` captures the running stack
  into a git repo on the device, so `git log` is the machine's history
- **SSH aliases** for the tunnel, the LAN and an Android root shell

`dockerctl doctor` exists because everything in this stack fails far from its
cause — a missing routing rule looks like a broken image pull, a `nodev` mount
looks like a permissions bug. It checks causes directly:

```
== networking ==
  [ok]   return-path rule
  [ok]   egress rule (wlan0 rmnet_data3 )
  [ok]   FORWARD accept
  [warn] a VPN app holds uid 0 (tun0) - pulls may fail intermittently
```

## Limits, honestly

- **No CPU or I/O limits.** cgroup v2 here exposes only `memory` and `pids`;
  Android keeps `cpu`, `cpuset` and `io` on v1 hierarchies and a controller can
  live on only one. `--memory` works, `--cpus` does not.
- **Weaker isolation than a normal Linux host.** `DOCKER_RAMDISK=1` is set so
  runc uses `MS_MOVE` + `chroot` instead of `pivot_root(2)`, which cannot work
  inside a chroot. Do not run untrusted images.
- **A VPN app can break image pulls.** Anything using Android's VPN API (ad
  blockers included) may capture uid 0 into a `tun` with no default route;
  dockerd then fails DNS with `network is unreachable`. `dockerctl doctor`
  detects and reports this.
- **Published ports are not reachable from your LAN.** `-p 8080:80` works on
  the phone itself but not from another machine, even though `docker-proxy` is
  bound, the DNAT rule is installed and nothing is dropping the packets. Root
  cause not yet found. Two things that *do* work: run the container with
  `--network=host` and it is reachable normally, or use a Cloudflare/Tailscale
  tunnel, which connects outbound and does not need inbound ports at all.
- **Autostart is off by default.** dockerd and containerd cost real battery.
  `touch /data/adb/docker/autostart` to enable.
- **Android may reclaim memory** under pressure and kill containers. This is a
  phone.

## If it goes wrong

Your original boot image is saved before anything is written:

```
/data/adb/docker/boot-backup-<timestamp>.img
```

Pull a copy off the device now, while everything works — a backup that only
exists on the phone is not a backup:

```sh
adb shell 'su -c "cp /data/adb/docker/boot-backup-*.img /sdcard/"'
adb pull /sdcard/boot-backup-*.img
```

To restore, from fastboot:

```sh
fastboot flash boot boot-backup-<timestamp>.img
```

The device is non-A/B, so there is a single `boot` partition and no slot to
worry about. Everything else lives in `/data/debian` and `/data/adb/docker`;
removing the module touches neither, so your images and containers survive.

## Device support

`raphael` only. The installer refuses to run on anything else — the kernel is
built from this device's tree and would not boot elsewhere.

## Snapshotting your stack

[`tools/state-snapshot.sh`](tools/state-snapshot.sh) captures the running state
— database dump, small volumes, compose file, tunnel config, and a full
`docker inspect` of every container — into a **git repo on the device**, so
`git log` becomes the machine's history and `git diff` shows what changed
between two points. Install it in the chroot as `/usr/local/bin/state-snapshot`
and run it before anything risky:

```sh
ssh raphael 'state-snapshot "before upgrading erpnext"'
```

It commits nothing when nothing changed, so running it often costs nothing. The
database is dumped **uncompressed** on purpose: git deltas plain SQL well, so a
15 MB dump across several snapshots packs to a couple of MB, whereas each
`.sql.gz` would be an opaque full-size blob.

Two things it deliberately does not do. It never tars `erpnext_db-data` — a tar
of a live datadir is neither consistent nor portable, and the SQL dump is the
restorable form. And it cannot see Android's `/data`, since the chroot has no
view of it, so `/data/adb/docker` and the boot partition still need adb.

That repo holds live credentials by design. Keep it off any public remote.

## Building it yourself

See [docs/BUILDING.md](docs/BUILDING.md). Short version: the kernel comes from
the ROM's own source tree, **not** LineageOS. A pristine 4.14 compiles and
boots and then dies in userspace at `bpfloader`, because Android 16's
`netbpfload` needs eBPF backports that only the ROM's tree carries. That one
took a long time to find; [docs/ANDROID-NOTES.md](docs/ANDROID-NOTES.md)
explains it and the other Android-specific obstacles.

## Licence

GPL-2.0, matching the Linux kernel. See [LICENSE](LICENSE).

Kernel source: [raphael-resources/android_kernel_xiaomi_sm8150](https://github.com/raphael-resources/android_kernel_xiaomi_sm8150) @ `16.2`.
KernelSU-Next and SUSFS are already in that tree; this project does not add them.
