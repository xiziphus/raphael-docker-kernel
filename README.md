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
| Networking | bridge, NAT egress, **published ports reachable from the LAN** |
| Tested workload | ERPNext — 11 containers (MariaDB, 2× Redis, Frappe backend, websocket, scheduler, 2× queue workers, nginx) |

ERPNext idles at **~534 MB** across all eleven containers and answers HTTP 200
from another machine on the network.

## Install

You need an unlocked bootloader and KernelSU already working.

1. Install a recent **KernelSU-Next** manager. It does not have to match the
   kernel's version — a v3.1.0 manager drives a v3.2.0 kernel fine.
2. KernelSU app → **Modules** → install `raphael-docker-kernel-vX.Y.Z.zip`.
3. Answer the prompts with the volume keys.
4. Reboot.
5. `su -c 'dockerctl setup'` — one-time, downloads Debian and Docker (~550 MB).
6. `su -c 'dockerctl start'`

For a web UI: `su -c 'dockerctl ui start'`, then
`su -c 'dockerctl ui admin YOUR-PASSWORD'` and open `http://127.0.0.1:9000`.

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

## One command for everything

```
dockerctl status              what is running
dockerctl doctor --fix        check every prerequisite, repair what it can
dockerctl start | stop        the daemon
dockerctl setup               one-time Debian + Docker install
dockerctl ui start            Portainer on :9000
dockerctl ui admin <pw>       create the UI login
dockerctl shell               a shell in the Debian chroot
dockerctl ps / run / compose  passed straight to docker
```

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
