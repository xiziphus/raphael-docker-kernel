# Driving it from a computer

None of this is required. The phone is self-sufficient — the WebUI and the
ACTION menu cover everything. This is for when you would rather not pick the
phone up.

## SSH

`sshd` runs **in the chroot, not in a container**, so it survives dockerd being
stopped, crashed or upgraded. That is deliberate: a shell is most valuable
exactly when Docker is broken.

```sh
dockerctl ssh on              # installs openssh-server if missing, loopback only
dockerctl ssh lan on          # also listen on the LAN
dockerctl ssh status
```

Add your public key to `/root/.ssh/authorized_keys` inside the chroot
(`/data/debian/root/.ssh/` from Android). The directory must be `0700` and the
file `0600` or sshd's `StrictModes` refuses them and logs the reason nowhere
you will look.

Three host aliases worth having in `~/.ssh/config`:

```sshconfig
# Through the Cloudflare tunnel - works from anywhere.
Host raphael
    HostName ssh1.example.com
    User root
    IdentityFile ~/.ssh/your_key
    ProxyCommand cloudflared access ssh --hostname %h

# Direct on the LAN - no Cloudflare, no tunnel client, works when the tunnel
# or dockerd is broken. The address is DHCP-assigned and moves; the current
# one is in the notification shade, or `ssh raphael 'asu "dockerctl lan ip"'`.
Host raphael-lan
    HostName 192.168.1.x
    Port 2222
    User root
    IdentityFile ~/.ssh/your_key

# Android root shell rather than the Debian chroot.
Host raphael-android
    HostName ssh1.example.com
    User root
    IdentityFile ~/.ssh/your_key
    ProxyCommand cloudflared access ssh --hostname %h
    RequestTTY yes
    RemoteCommand /usr/local/bin/asu
```

### `asu` — Android root from inside the chroot

An SSH session lands in Debian, which cannot see Android's `/`. `asu` bridges
it: `/proc/1/root` *is* init's root, and root in the ksu domain can traverse it.

```sh
ssh raphael 'asu "getprop ro.product.device"'
ssh raphael 'asu "dockerctl status"'      # dockerctl is Android-side
ssh raphael-android                        # interactive
```

Two things make this less trivial than it looks. Android binaries cannot be
exec'd through `/proc/1/root/...` directly — their ELF interpreter is
`/system/bin/linker64`, an absolute path that resolves inside Debian — so `asu`
uses `chroot(1)` to make the paths mean what they say. And it rebuilds Android's
environment from `/init.environ.rc` and `/data/system/environ/classpath`,
because `content`, `cmd`, `pm` and `am` are `app_process` wrappers that need
`BOOTCLASSPATH`. Without it they start, find no runtime, and **exit 0 having
printed nothing** — success with empty output, which reads as "there is no
data".

## Notification relay

Mirrors the phone's incoming SMS and app notifications onto macOS.

Nothing is installed on the phone beyond this module, and no
notification-listener permission is granted to anything: with root,
`content://sms/inbox` and `dumpsys notification` are already readable.

```sh
brew install terminal-notifier
tools/mac-notify-relay.sh --once      # one pass, to test
tools/mac-notify-relay.sh --install   # launchd agent, starts at login
```

The Mac polls `dockerctl relay new` over SSH — LAN first, tunnel as fallback —
and posts each record natively.

### Set the alert style, or you will think it is broken

macOS registers a CLI notifier with alert style **None**. Notifications are then
accepted, filed silently into Notification Centre, and never appear on screen.
Every layer reports success: the poll works, the cursor advances, the notifier
exits 0. Nothing tells you they are being discarded.

**System Settings → Notifications → terminal-notifier → Banners.**

The relay plays a sound by default (`NOTIFY_SOUND=`, empty to silence) so
delivery is observable whatever the alert style is set to.

### Behaviour worth knowing

- **First run announces nothing.** It records a high-water mark rather than
  replaying your entire inbox. `dockerctl relay reset` to re-baseline
- **Ongoing notifications are filtered out** — music player, VPN, "USB debugging
  connected". They are fixtures, not events, and relaying them means
  re-announcing the same thing every poll
- **A text can arrive up to three times** — SMS provider, messaging app,
  caller-ID app. Android genuinely has separate sources
- Records use ASCII 31 as the field separator, not tab: tab is IFS whitespace,
  so `IFS=$'\t' read` collapses runs of it and an empty field silently shifts
  every later field left

## State snapshots

`tools/state-snapshot.sh` captures the running stack — database dump, small
volumes, compose file, tunnel config, and a `docker inspect` of every container
— into a git repo on the device. `git log` becomes the machine's history and
`git diff` shows what changed between two points.

```sh
ssh raphael 'state-snapshot "before upgrading erpnext"'
```

It commits nothing when nothing changed, so running it before anything risky is
free. The database is dumped **uncompressed** on purpose: git deltas plain SQL
well, so a 15 MB dump across several snapshots packs to a couple of MB, whereas
each `.sql.gz` would be an opaque full-size blob.

Two deliberate omissions. It never tars the database volume — a tar of a live
datadir is neither consistent nor portable, and the SQL dump is its restorable
form. And it cannot see Android's `/data`, so `/data/adb/docker` and the boot
partition still need `adb`.

**That repo holds live credentials by design.** Keep it off any public remote.

## Backing up the boot partition

The chroot cannot see `/data`, so this is the one thing that needs USB.

```sh
adb shell 'su -c "dd if=/dev/block/by-name/boot of=/sdcard/boot-backup.img"'
adb pull /sdcard/boot-backup.img
```

Worth doing after every kernel change. The module patches boot **in place**,
preserving your ramdisk and header, so the result is not byte-identical to any
build artifact — it cannot be reproduced, only restored from a copy.
