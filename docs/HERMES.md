# Hermes Agent

[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) is an
AI assistant with tool calling, a CLI, and a web dashboard. It is **not part of
this project** and nothing here installs it — the module only provides a switch
for the dashboard once you have installed it yourself.

## Installing

```sh
ssh raphael
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Running as root it uses the FHS layout: code in `/usr/local/lib/hermes-agent`,
`hermes` on `PATH`, config in `/root/.hermes/`.

Two things about this environment specifically:

- **The setup wizard needs a terminal.** Piped from `curl`, the installer runs
  every runtime stage and then logs *"Setup wizard skipped (no terminal
  available)"*, stopping before the two stages that need your API keys. Run
  `ssh -t raphael 'hermes setup'` afterwards, or configure it in the dashboard.
- **`systemctl` exists in the chroot but systemd is not PID 1.** The installer
  guards its gateway service install on `command -v systemctl`, which is a false
  positive here — it will try, fail, and warn. Nothing breaks; it just means
  `hermes gateway` will not self-start. Supervise it the way `sshd` and
  `cloudflared` are supervised, from `service.sh`.

## The switch

```sh
dockerctl hermes on | off | status | log [n]
```

and a card in the WebUI, which hides itself when hermes is not installed.

`on` starts the dashboard and records the choice, so `service.sh` brings it back
at boot and restarts it if it dies — same 60-second supervise loop as the
tunnel. Like `sshd` and `cloudflared` it runs as a **plain process in the
chroot**, not a container, so it survives `dockerctl stop` and a dockerd crash.

`status` distinguishes *enabled* from *listening*, because the interesting
failure is the one where they disagree.

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
