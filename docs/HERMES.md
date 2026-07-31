# Hermes Agent

[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) is an
AI assistant with tool calling, a CLI, and a web dashboard. It is **not part of
this project** and nothing here installs it — the module only provides a switch
for the dashboard once you have installed it yourself.

## Installing

**Use the published image, not the shell installer.** There is an official
`nousresearch/hermes-agent` image with an arm64 build, and on this device it is
strictly less work than the installer, which wants a repo clone, a Python venv,
a Node toolchain and a Vite build:

```sh
dockerctl pull nousresearch/hermes-agent:v2026.7.20
dockerctl hermes on
```

Config lives in `/root/.hermes` inside the chroot and is bind-mounted to
`/opt/data` in the container, so it survives image upgrades — and an existing
install from the shell installer can be adopted with no migration.

Pin the tag. `:latest` currently ships **zstd-compressed layers**, which Docker
20.10 cannot unpack; see [Pulling images](#pulling-images) below.

Configure API keys in the dashboard. If you use the shell installer instead,
note that piped from `curl` there is no terminal, so it logs *"Setup wizard
skipped"* and stops before the stages that need your keys — run
`ssh -t raphael 'hermes setup'` afterwards.

### Three things that will waste your afternoon

**The subcommand is mandatory.** With no command the image runs bare `hermes`,
which is the *interactive chat*. With no tty it exits immediately and the
container restart-loops every ~25 seconds **logging no error whatsoever** — the
only clue is a climbing `RestartCount`.

**It cannot open a socket as its own user.** The image drops to `hermes`
(uid 10000) via `s6-setuidgid`, and Android gates socket creation on
`in_group_p(AID_INET) || capable(CAP_NET_RAW)`. Measured:

| | |
|---|---|
| uid 0 | binds |
| uid 10000 | `PermissionError: Operation not permitted` |
| uid 10000 + `--group-add 3003` | still fails |

`--group-add` is what rescued cloudflared, and it does **not** work here —
`s6-setuidgid` re-initialises supplementary groups from the image's own group
database and discards it. The fix is a `/etc/passwd` override making `hermes`
uid 0, which `hermes.sh` builds automatically. `HERMES_UID=0` does not work:
the stage2 `usermod` cannot take a uid root already owns, and fails silently.

The symptom is the worst part —

```
ERROR: could not bind on any address out of [('127.0.0.1', 9119)]
```

— which reads as a port conflict. Nothing holds the port.

**OOM does not look like OOM.** With too small a `--memory` cap the kernel
reaps an s6 *child*, so Docker reports `OOMKilled=false` and a clean `exit=1`
while `dmesg` plainly shows `oom_reaper: reaped process … (s6-supervise)`.
Give it 2 GB.

## The switch

```sh
dockerctl hermes on | off | status | log [n]
```

and a card in the WebUI, which hides itself when hermes is not installed.

`on` starts the container and records the choice, so `service.sh` brings it back
at boot and the 60-second supervise loop restarts it if it dies.

`status` distinguishes *enabled* from *listening*, because the interesting
failure is the one where they disagree — and `hermes_running` tests the bound
port rather than `docker ps`, since the container reports `running` for the
minute-plus its s6 tree spends loading 53 plugins, and stayed `running`
throughout a restart loop that never served anything.

**Unlike `sshd` and `cloudflared`, this one dies with Docker.** Those are chroot
processes precisely so they survive a dockerd fault. Hermes is a container, so
it does not — never treat it as a way back in.

## It binds loopback only, on purpose

There is no LAN option and that is not an oversight:

1. Published bridge ports are not LAN-reachable on this device anyway.
2. The dashboard **rejects any `Host` header other than the interface it bound
   to** (anti-DNS-rebinding, `GHSA-ppp5-vxwm-4cf7`), so a LAN bind would need
   the LAN address fixed at start time — and DHCP moves it.
3. The agent runs shell commands as root, in a chroot holding your tunnel
   credentials, your `authorized_keys` and the container database. Loopback plus
   an authenticated tunnel is a deliberate posture.

## Publishing it through the tunnel

Add an ingress rule **above** the 404 catch-all:

```yaml
  - hostname: hermes.example.com
    service: http://127.0.0.1:9119
    originRequest:
      httpHostHeader: 127.0.0.1:9119
```

then publish DNS and restart the tunnel:

```sh
cloudflared tunnel route dns <tunnel> hermes.example.com
dockerctl tunnel named
```

**The `httpHostHeader` line is the part that is easy to miss.** Without it the
origin returns

```json
{"detail":"Invalid Host header. Dashboard requests must use the hostname the server was bound to."}
```

as a `400`, which reads like a tunnel misconfiguration and is not one. Rewriting
the Host at the tunnel does not reopen the rebinding hole the check defends
against: a browser on the device still connects directly and is still validated
against its own `Host`.

`dockerctl hermes status` prints this stanza when no rule for the port exists.

## What is exposed, and what is not

Measured through the tunnel, unauthenticated:

| Endpoint | |
|---|---|
| `/` | `200` — the UI shell loads |
| `/api/status` | `200` — version, gateway state, session counts |
| `/api/config`, `/api/env`, `/api/sessions`, `/api/models` | `401` |

So an anonymous visitor gets a login-less shell and some version metadata, not
your keys. Loading `/` sets no cookie and grants nothing.

Note that `/api/status` reports `auth_required: false` — that describes whether
an auth *provider* is configured, not whether the API is open. Verify with a
`curl` against a protected endpoint rather than trusting the flag.

**Tunnel hostnames are enumerable** through certificate-transparency logs, so
obscurity is not a control. If you want a second layer, either register the
dashboard for OAuth (`hermes dashboard register`, via Nous Portal) or put a
Cloudflare Access policy on the hostname.

## Costs on this device

- **Node 22 and a Vite build.** The installer pulls Node into
  `$HERMES_HOME/node`. The dashboard bundle must be built once —
  `cd /usr/local/lib/hermes-agent/web && npm install && npm run build` — and it
  emits to `hermes_cli/web_dist`, **not** `web/dist`. Checking the wrong path is
  why this looks unbuilt when it is not.
- **Do not install it over mobile data or on battery.** It is a repo clone, a
  Python venv, a Node toolchain and a web build. On this device the power guard
  will happily cut Docker, the tunnel and SSH out from under it mid-install.

## Pulling images

`:latest` ships **zstd-compressed layers** and Docker 20.10 cannot unpack them.
It downloads the blob, verifies the digest — correct, that is the *compressed*
blob — then feeds a zstd stream to a gzip reader:

```
failed to register layer: Error processing tar file(exit status 1):
archive/tar: invalid tar header
```

The error names tar, so it reads like a corrupt download. It is not; retrying
and switching registries both fail identically. Check the manifest before
chasing storage drivers:

```sh
docker manifest inspect <image>:<tag> | grep mediaType | sort | uniq -c
```

Anything `application/vnd.oci.image.layer.v1.tar+zstd` will not pull. Pin to a
tag that is all `+gzip`. This is not specific to Hermes — n8n's `:latest` has
the same problem — and it will get more common until Docker is upgraded.
