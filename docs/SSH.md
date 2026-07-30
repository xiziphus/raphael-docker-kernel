# Connecting over SSH

The phone runs a real `sshd`. Once it is on you can treat the device as an
ordinary Linux box — `ssh`, `scp`, `rsync`, port forwards, VS Code Remote, all
of it.

**`sshd` runs in the Debian chroot, not in a container.** That is deliberate: it
must survive dockerd being stopped, crashed or mid-upgrade, which is exactly
when you need a shell. Nothing on this page depends on Docker running.

## Where you land

There are three different roots on this device and it is worth knowing which
one you are in, because they cannot see each other's files.

| | You get | How |
|---|---|---|
| **Debian chroot** | `docker`, `apt`, `/opt`, your compose files | the default SSH landing |
| **Android** | boot partition, `/data`, `/data/adb`, `dumpsys`, `pm`, `dockerctl` | `asu` from the chroot — see [below](#getting-an-android-root-shell) |
| **A container** | that container's filesystem | `docker run`, not `docker exec` — exec is broken here, see the README |

`dockerctl` lives on the Android side, so from a plain SSH session it is
`asu "dockerctl status"`, not `dockerctl status`.

## 1. Put a key on the phone first

**Password login is disabled and there is no password to enable.** The config
sets `PasswordAuthentication no` and `PermitRootLogin prohibit-password`, so
your public key has to be in place *before* `sshd` is any use. Turning SSH on
without a key gets you a daemon that listens and rejects everything —
`dockerctl ssh status` will say so:

```
[bad]  authorized_keys EMPTY - no login possible
```

The file lives at `/root/.ssh/authorized_keys` inside the chroot, which is
`/data/debian/root/.ssh/authorized_keys` seen from Android. Pick whichever route
you have available.

**Over USB, from your computer:**

```sh
adb push ~/.ssh/id_ed25519.pub /sdcard/key.pub
adb shell su -c '
  mkdir -p /data/debian/root/.ssh
  cat /sdcard/key.pub >> /data/debian/root/.ssh/authorized_keys
  chmod 700 /data/debian/root/.ssh
  chmod 600 /data/debian/root/.ssh/authorized_keys
  rm /sdcard/key.pub'
```

**From the phone itself** — a KernelSU terminal, Termux with `su`, or the
`dockerctl shell` prompt — paste the key in the same place. Any root shell will
do; there is nothing special about `adb` beyond it being the one that works when
you cannot see the screen.

Those two `chmod`s are not decoration. sshd's `StrictModes` refuses a key file
that is group- or world-readable, and the refusal is logged somewhere you will
not look — from the client it is an ordinary `Permission denied (publickey)`.
It is the single most common reason a correct key does not work.

No key yet? `ssh-keygen -t ed25519` on your computer, then push the `.pub`.

## 2. Turn it on

```sh
dockerctl ssh on          # installs openssh-server if missing; loopback only
dockerctl ssh lan on      # also listen on the LAN
dockerctl ssh status
```

A healthy status is four `[ok]` lines:

```
[ok]   enabled at boot
[ok]   running on 0.0.0.0:2222
[ok]   1 authorized key(s)
```

Port 2222, not 22 — Android has its own ideas about low ports and there is no
reason to fight them. Change it by editing `Port` in
`/etc/ssh/sshd_config.d/99-android.conf` and re-running `dockerctl ssh on`.

**Loopback-only is still reachable through the tunnel.** The chroot has no
network namespace of its own, so `cloudflared` — which also runs in the chroot —
reaches `127.0.0.1:2222` directly. `lan on` is the extra path, not the only one.

## 3. Connect on the LAN

```sh
ssh -p 2222 root@192.168.1.85
```

The address is DHCP-assigned and it moves — over one session here it was `.67`,
then `.72`, then `.85`. Three ways to find the current one:

```sh
dockerctl lan ip          # if you already have a shell
dockerctl lan on          # publish it to the notification shade, permanently
```

…or read it off the phone's notification shade, which is the one that works when
nothing can connect. That is what the feature is for.

This path needs no Cloudflare, no internet and no client software beyond `ssh`.
It is the one to reach for when something else is broken.

## 4. Connect from anywhere, over the tunnel

The Cloudflare tunnel is not a forwarded TCP port — there is no host and port to
aim at. Cloudflare terminates the connection at its edge, so the client needs
`cloudflared` to bridge stdio into it:

```sh
brew install cloudflared          # or your platform's package
ssh -o ProxyCommand='cloudflared access ssh --hostname ssh1.example.com' root@ssh1.example.com
```

On the device side there has to be an `ssh://` ingress rule for that hostname:

```yaml
ingress:
  - hostname: ssh1.example.com
    service: ssh://127.0.0.1:2222
  - service: http_status:404          # the catch-all must stay last
```

then publish the DNS record once:

```sh
cloudflared tunnel route dns <tunnel-name> ssh1.example.com
```

`dockerctl tunnel status` and `dockerctl tunnel log 40` tell you whether the
device end is up. Note that a **quick** tunnel (`dockerctl tunnel quick`) gets a
random `trycloudflare.com` name and carries HTTP only — SSH needs a *named*
tunnel with the ingress rule above.

Because this path depends on Cloudflare being up, on the internet being up, and
on the tunnel process being alive, it is the convenient one rather than the
reliable one. Keep the LAN path enabled as well.

## The `~/.ssh/config` worth pasting

```sshconfig
# Through the Cloudflare tunnel - works from anywhere.
Host raphael
    HostName ssh1.example.com
    User root
    IdentityFile ~/.ssh/id_ed25519
    ProxyCommand cloudflared access ssh --hostname %h
    StrictHostKeyChecking accept-new

# Direct on the LAN - no Cloudflare, no tunnel client, no internet. Works when
# the tunnel or dockerd is broken. The address moves; see step 3.
Host raphael-lan
    HostName 192.168.1.85
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking accept-new

# Android root shell rather than the Debian chroot. Interactive only -
# RemoteCommand cannot be combined with a command argument; for one-offs use
# `ssh raphael 'asu "<command>"'`.
Host raphael-android
    HostName ssh1.example.com
    User root
    IdentityFile ~/.ssh/id_ed25519
    ProxyCommand cloudflared access ssh --hostname %h
    RequestTTY yes
    RemoteCommand /usr/local/bin/asu
```

Then `ssh raphael`, `ssh raphael-lan`, `ssh raphael-android`.

Both host aliases point at the same machine but present different host keys, so
they get separate `known_hosts` entries. That is normal and not a warning sign.

## Getting an Android root shell

An SSH session lands in Debian, which cannot see Android's `/`. `asu` bridges
it: `/proc/1/root` *is* init's root, and root in the ksu domain can traverse it.

```sh
ssh raphael 'asu "getprop ro.product.device"'
ssh raphael 'asu "dockerctl status"'
ssh raphael-android                          # interactive
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

## Copying files

`scp` and `rsync` work normally on the LAN path:

```sh
scp -P 2222 compose.yml root@192.168.1.85:/opt/
rsync -avz -e 'ssh -p 2222' ./site/ root@192.168.1.85:/opt/site/
```

Over the tunnel, `scp`/`rsync` inherit the `ProxyCommand` from `~/.ssh/config`,
so `scp compose.yml raphael:/opt/` works once the alias exists. `rsync` needs
`-e ssh` explicitly, and is worth it — the tunnel is slower than the LAN and
rsync sends only differences.

Both land in the **chroot's** filesystem. To get a file to Android's `/data`,
copy it to the chroot and move it with `asu`.

## When it does not work

Run `dockerctl ssh status` first — it separates the four things that can each
independently be wrong. Then, by symptom:

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | Key not in `authorized_keys`, or `.ssh` / `authorized_keys` permissions are not `700` / `600`. Check with `dockerctl ssh status` — it counts the keys |
| `Connection refused` on the LAN | `sshd` is loopback-only. `dockerctl ssh lan on` |
| `Host is down` / timeout on the LAN | Wrong address (DHCP moved it), or the phone is on mobile data with no Wi-Fi. Check `dockerctl lan ip` |
| Tunnel path hangs at `ProxyCommand` | `cloudflared` missing on *your* machine, or the tunnel is down — `dockerctl tunnel status` |
| Tunnel path gives an HTTP error | The hostname has no `ssh://` ingress rule, or it is a quick tunnel |
| Connects, then freezes mid-command | The device suspended. `dockerctl wake floor status` — the lifeline lock should be held whenever SSH is up |
| Everything was working, now nothing responds | The battery guard may have tripped and stopped SSH, the tunnel and Docker on purpose. There is a notification saying so. `dockerctl power status` |
| `sshd` will not start after an edit | Two config files each setting `Port` or `ListenAddress`. sshd treats repeated `Port` as additive and refuses to bind the same socket twice. `dockerctl ssh on` supersedes conflicting drop-ins for you; `sshd -t` in the chroot shows the error |

If you have lost every path at once, USB is the floor: `adb shell su -c
'dockerctl ssh lan on'` puts you back on the LAN without touching the screen.
