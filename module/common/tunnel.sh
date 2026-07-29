#!/system/bin/sh
# Cloudflare Tunnel.  . lib.sh, mount.sh, daemon.sh first.
#
# cloudflared dials OUT to Cloudflare's edge and traffic is proxied back down
# that connection. Nothing listens for inbound connections, so this works behind
# CGNAT, needs no port forwarding, and -- usefully here -- sidesteps the fact
# that published bridge ports are not reachable from the LAN on this device.
#
# It runs with --network=host so it can reach services on 127.0.0.1 whether they
# are host-networked or published.
CF_IMG=cloudflare/cloudflared:latest
CF_TOKENF="$STATE/cf-token"

tunnel_run() {   # tunnel_run <args...>
    in_chroot_exec docker rm -f cloudflared >/dev/null 2>&1
    # --user 0:0 --group-add 3003 are REQUIRED on Android, not hygiene.
    # Android enforces paranoid networking: creating an AF_INET socket needs
    # membership of the inet group (AID_INET = 3003) or CAP_NET_RAW. The
    # cloudflared image runs as "nonroot" (uid 65532), which has neither, so it
    # cannot open a socket at all and dies with
    #     dial udp 8.8.8.8:53: socket: operation not permitted
    # Images that happen to run as root are unaffected, which is why every other
    # container here worked without this.
    in_chroot "docker run -d --name cloudflared --network=host --restart=unless-stopped \
        --user 0:0 --group-add 3003 \
        $CF_IMG tunnel --no-autoupdate $* >/dev/null" || return 1
    sleep 6
    in_chroot_exec docker ps --filter name=cloudflared --format '  {{.Names}}  {{.Status}}'
}

tunnel_token() {  # a named tunnel created in the Cloudflare dashboard
    _t="$1"
    [ -n "$_t" ] || { bad "usage: dockerctl tunnel token <token>"; return 1; }
    printf '%s' "$_t" > "$CF_TOKENF"; chmod 600 "$CF_TOKENF"
    ok "token saved"
    tunnel_run "run --token $_t"
    say "  routes are configured in the Cloudflare Zero Trust dashboard"
}

tunnel_quick() {  # ephemeral trycloudflare.com URL, no account needed
    _u="${1:-http://127.0.0.1:8080}"
    say "  starting a quick tunnel to $_u"
    tunnel_run "--url $_u"
    say "  fetching the generated URL..."
    _n=0
    while [ "$_n" -lt 20 ]; do
        _url=$(in_chroot_exec docker logs cloudflared 2>&1 | grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' | head -1)
        [ -n "$_url" ] && { ok "$_url"; return 0; }
        sleep 3; _n=$((_n+1))
    done
    warn "no URL yet - check: dockerctl logs cloudflared"
}


CF_DIR=/opt/cloudflared     # inside the chroot

tunnel_named() {
    # A named tunnel run from a CREDENTIALS FILE rather than a token. The
    # difference matters: token-run tunnels take their ingress from the Zero
    # Trust dashboard, whereas this reads $CF_DIR/config.yml on the device, so
    # routes are editable here and survive without dashboard access.
    #
    # Expects, inside the chroot:
    #   /opt/cloudflared/config.yml       tunnel id + ingress rules
    #   /opt/cloudflared/<uuid>.json      credentials (chmod 600)
    if ! in_chroot_exec test -f "$CF_DIR/config.yml"; then
        bad "no $CF_DIR/config.yml on the device"
        say "  create the tunnel on a PC, then copy its credentials json and a"
        say "  config.yml into /data/debian$CF_DIR"
        return 1
    fi
    in_chroot_exec docker rm -f cloudflared >/dev/null 2>&1
    in_chroot "docker run -d --name cloudflared --network=host --restart=unless-stopped \
        --user 0:0 --group-add 3003 \
        -v $CF_DIR:/etc/cloudflared:ro \
        $CF_IMG tunnel --no-autoupdate --config /etc/cloudflared/config.yml run >/dev/null" || return 1
    sleep 8
    in_chroot_exec docker ps --filter name=cloudflared --format '  {{.Names}}  {{.Status}}'
    in_chroot_exec grep -E '^\s+- hostname:' "$CF_DIR/config.yml" 2>/dev/null | sed 's/.*hostname: /  https:\/\//'
}

tunnel_stop()   { in_chroot_exec docker rm -f cloudflared >/dev/null 2>&1; ok "tunnel stopped"; }
tunnel_status() {
    in_chroot_exec docker ps -a --filter name=cloudflared --format '  {{.Names}}  {{.Status}}' 2>/dev/null
    _url=$(in_chroot_exec docker logs cloudflared 2>&1 | grep -oE 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' | head -1)
    [ -n "$_url" ] && say "  url: $_url"
    [ -f "$CF_TOKENF" ] && say "  a named-tunnel token is stored"
}
