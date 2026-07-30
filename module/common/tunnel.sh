#!/system/bin/sh
# Cloudflare Tunnel.  . lib.sh, mount.sh, daemon.sh first.
#
# cloudflared dials OUT to Cloudflare's edge and traffic is proxied back down
# that connection. Nothing listens for inbound connections, so this works behind
# CGNAT, needs no port forwarding, and -- usefully here -- sidesteps the fact
# that published bridge ports are not reachable from the LAN on this device.
#
# It runs as a PLAIN PROCESS IN THE CHROOT, not as a container.
#
# That was not the original design and the reason for the change is worth
# recording. As a container the tunnel died with dockerd, which is precisely
# when you need it: a Docker-level fault took out the only remote path to the
# device at the same moment it took out Docker. Recovery required physical
# access. Worse, a stray `tunnel quick` had silently replaced the named tunnel
# with an ephemeral one, and because both are "a running cloudflared container"
# nothing noticed for eleven hours.
#
# As a host process it survives `dockerctl stop`, a dockerd crash, and a Docker
# upgrade -- and the boot loop supervises it, so a dead tunnel comes back
# without anyone watching.
#
# Root in the chroot can open sockets despite Android's paranoid networking:
# the check is `in_group_p(AID_INET) || capable(CAP_NET_RAW)` and root has
# CAP_NET_RAW. (The old container needed --user 0:0 --group-add 3003 only
# because the cloudflared image runs as uid 65532, which has neither.)

CF_TOKENF="$STATE/cf-token"
CF_MODE_F="$STATE/tunnel.mode"     # named | token | quick | off
CF_ARG_F="$STATE/tunnel.arg"       # quick: the local URL. token: unused.
CF_DIR=/opt/cloudflared            # inside the chroot
CF_BIN=/usr/local/bin/cloudflared  # inside the chroot
CF_LOG=/var/log/cloudflared.log    # inside the chroot
CF_PID=/run/cloudflared.pid        # inside the chroot
CF_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64

tunnel_mode() {
    m=$(cat "$CF_MODE_F" 2>/dev/null)
    case "$m" in named|token|quick) echo "$m" ;; *) echo off ;; esac
}

tunnel_installed() { in_chroot "test -x $CF_BIN" >/dev/null 2>&1; }

# Existing config.yml files say `credentials-file: /etc/cloudflared/<id>.json`,
# because as a container $CF_DIR was bind-mounted there. Run as a host process
# that path does not exist and cloudflared exits with
#   Tunnel credentials file '/etc/cloudflared/<id>.json' doesn't exist
# Symlink rather than rewrite the config: /etc/cloudflared is cloudflared's own
# default location, so this makes both spellings work and leaves a config the
# user may have copied from a PC untouched.
tunnel_paths_fixup() {
    in_chroot "
      [ -e /etc/cloudflared ] && exit 0
      [ -d $CF_DIR ] || exit 0
      ln -s $CF_DIR /etc/cloudflared
    " >/dev/null 2>&1
    return 0
}

tunnel_install() {
    tunnel_installed && return 0
    say "  fetching cloudflared (arm64)..."
    # Not in Debian's archive, so straight from the release. -f so a 404 fails
    # loudly instead of leaving an HTML error page marked executable.
    in_chroot "curl -fsSL -o $CF_BIN.tmp '$CF_URL' && chmod 755 $CF_BIN.tmp && mv -f $CF_BIN.tmp $CF_BIN" \
        >/dev/null 2>&1
    if tunnel_installed; then
        ok "cloudflared $(in_chroot "$CF_BIN --version" 2>/dev/null | awk '{print $3}')"
    else
        bad "could not install cloudflared - check network"
        return 1
    fi
}

# True if a tunnel is serving. Checks the process first, then falls back to a
# container so a device that has not migrated yet still reports correctly.
tunnel_running() {
    in_chroot 'pgrep -x cloudflared >/dev/null' >/dev/null 2>&1 && return 0
    running || return 1
    [ -n "$(in_chroot_exec docker ps -q --filter name=^cloudflared$ 2>/dev/null)" ]
}

tunnel_kill() {
    in_chroot "pkill -x cloudflared >/dev/null 2>&1; rm -f $CF_PID" >/dev/null 2>&1
    # Remove any container left over from the pre-migration layout.
    running && in_chroot_exec docker rm -f cloudflared >/dev/null 2>&1
    return 0
}

# Start detached. nohup + & means the process reparents to init and outlives
# the chroot shell that launched it.
tunnel_spawn() {   # tunnel_spawn <args...>
    tunnel_install || return 1
    tunnel_paths_fixup
    tunnel_kill
    # `tunnel` is the subcommand; without it cloudflared prints
    # "use `cloudflared tunnel run` to start tunnel <id>" and exits. The
    # container form was `cloudflared tunnel --no-autoupdate <args>` because
    # the image entrypoint supplied the binary -- keep the arg order identical.
    in_chroot "mkdir -p /run /var/log
               nohup $CF_BIN tunnel --no-autoupdate $* >> $CF_LOG 2>&1 &
               echo \$! > $CF_PID" || return 1
    sleep 5
    if tunnel_running; then
        wake_floor_sync 2>/dev/null   # a way in exists now; do not sleep it away
        return 0
    fi
    bad "cloudflared did not stay up - last lines:"
    in_chroot "tail -5 $CF_LOG" 2>/dev/null | sed 's/^/    /'
    return 1
}

tunnel_named() {
    # A named tunnel run from a CREDENTIALS FILE rather than a token. The
    # difference matters: token-run tunnels take their ingress from the Zero
    # Trust dashboard, whereas this reads $CF_DIR/config.yml on the device, so
    # routes are editable here and survive without dashboard access.
    if ! in_chroot "test -f $CF_DIR/config.yml" >/dev/null 2>&1; then
        bad "no $CF_DIR/config.yml on the device"
        say "  create the tunnel on a PC, then copy its credentials json and a"
        say "  config.yml into /data/debian$CF_DIR"
        return 1
    fi
    echo named > "$CF_MODE_F"
    tunnel_spawn "--config $CF_DIR/config.yml run" || return 1
    ok "named tunnel up"
    in_chroot "grep -E '^[[:space:]]+- hostname:' $CF_DIR/config.yml" 2>/dev/null \
        | sed 's/.*hostname: /  https:\/\//'
}

tunnel_token() {  # a named tunnel created in the Cloudflare dashboard
    _t="${1:-}"
    [ -n "$_t" ] || { bad "usage: dockerctl tunnel token <token>"; return 1; }
    printf '%s' "$_t" > "$CF_TOKENF"; chmod 600 "$CF_TOKENF"
    echo token > "$CF_MODE_F"
    tunnel_spawn "run --token $_t" || return 1
    ok "tunnel up (routes come from the Zero Trust dashboard)"
}

tunnel_quick() {  # ephemeral trycloudflare.com URL, no account needed
    _u="${1:-http://127.0.0.1:8080}"
    printf '%s' "$_u" > "$CF_ARG_F"
    echo quick > "$CF_MODE_F"
    say "  starting a quick tunnel to $_u"
    tunnel_spawn "--url $_u" || return 1
    _n=0
    while [ "$_n" -lt 20 ]; do
        # Anchored to a hyphenated subdomain so it cannot match
        # api.trycloudflare.com, which appears in the log first.
        _url=$(in_chroot "grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' $CF_LOG" 2>/dev/null | tail -1)
        [ -n "$_url" ] && { ok "$_url"; return 0; }
        sleep 3; _n=$((_n+1))
    done
    warn "no URL yet - check: dockerctl tunnel log"
}

tunnel_stop() {
    echo off > "$CF_MODE_F"
    tunnel_kill
    wake_floor_sync 2>/dev/null
    ok "tunnel stopped"
}

# Restart whatever mode is configured. This is what the boot loop calls, so it
# must never start something the user turned off.
tunnel_supervise() {
    m=$(tunnel_mode)
    [ "$m" = off ] && return 0
    tunnel_running && return 0
    case "$m" in
        named) tunnel_spawn "--config $CF_DIR/config.yml run" ;;
        token) tunnel_spawn "run --token $(cat "$CF_TOKENF" 2>/dev/null)" ;;
        quick) tunnel_spawn "--url $(cat "$CF_ARG_F" 2>/dev/null)" ;;
    esac
}

tunnel_status() {
    say "  mode: $(tunnel_mode)"
    tunnel_running && ok "cloudflared running" || bad "cloudflared not running"
    in_chroot "pgrep -x cloudflared >/dev/null" >/dev/null 2>&1 \
        && say "  as a host process (survives dockerd)" \
        || { running && [ -n "$(in_chroot_exec docker ps -q --filter name=^cloudflared$ 2>/dev/null)" ] \
             && warn "still running as a CONTAINER - run 'dockerctl tunnel named' to migrate"; }
    case "$(tunnel_mode)" in
      named) in_chroot "grep -E '^[[:space:]]+- hostname:' $CF_DIR/config.yml" 2>/dev/null \
                 | sed 's/.*hostname: /  https:\/\//' ;;
      quick) _url=$(in_chroot "grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' $CF_LOG" 2>/dev/null | tail -1)
             [ -n "$_url" ] && say "  url: $_url" ;;
    esac
}

tunnel_log() { in_chroot "tail -${1:-40} $CF_LOG" 2>/dev/null; }
