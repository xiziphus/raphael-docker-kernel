# Troubleshooting

Start here:

```sh
su -c 'dockerctl doctor --fix'
```

It checks kernel capabilities, storage, mounts, networking and the daemon, and
repairs what it can. Most problems below are things it already detects.

| Symptom | Cause | Fix |
|---|---|---|
| Module install aborts: "kernel cannot run Docker" | Kernel lacks namespaces/cgroups | Let the installer patch your boot image, then reboot |
| Device bootloops after flashing | Wrong kernel for your ROM | Restore `/data/adb/docker/boot-backup-*.img` via fastboot |
| `failed to register layer ... remount /, flags: 0x84000` | chroot root is not a mount point | `dockerctl doctor --fix` |
| `pivot_root .: invalid argument` | `DOCKER_RAMDISK` not set | `dockerctl restart` |
| Containers have no internet | Android's routing rules were rewritten | `dockerctl net apply` |
| Published ports unreachable from LAN | Same | `dockerctl net apply` |
| Image pulls fail with `network is unreachable` | A VPN app captured uid 0 | Pause the VPN, or exclude root from it |
| `docker: command not found` after reboot | Daemon not started | `dockerctl start`, or enable autostart |
| Everything worked, now nothing does | Wi-Fi ↔ mobile switch rewrote netd's rules | `dockerctl net apply` (the boot service also re-asserts every 120 s) |

## Recovering a bad flash

The installer backs up your boot partition before writing:

```
/data/adb/docker/boot-backup-<timestamp>.img
```

From a PC:

```sh
adb push boot-backup-*.img /sdcard/       # if you can still boot
fastboot flash boot boot-backup-*.img     # from fastboot
```

Keep a copy off the device. A backup that only exists on the phone is not a
backup.

## Logs

```
/data/debian/var/log/dockerd.log     the daemon
/data/adb/docker/boot.log            what the boot service did
dockerctl logs <container>           a container
```

## Memory

This is a phone. Android will reclaim memory under pressure and can kill
containers. `free -m` and `dockerctl stats` tell you where you stand; zram
absorbs a surprising amount.
