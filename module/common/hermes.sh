#!/system/bin/sh
# hermes.sh - Hermes Agent dashboard.  . lib.sh, mount.sh, tunnel.sh first.
#
# Hermes is an agentic assistant (NousResearch/hermes-agent) installed into the
# chroot by its own installer. This file does not install it and deliberately
# never will: the installer is 3000+ lines that clones a repo, builds a venv and
# a web bundle, and wants a terminal. Wrapping that in a toggle would hide a
# ten-minute network operation behind something that looks instant. The switch
# only starts and stops the dashboard that the installer left behind.
#
# Like sshd and cloudflared it runs as a PLAIN PROCESS IN THE CHROOT, so it
# survives dockerd being stopped -- and so that the agent's shell tools see the
# chroot rather than a container.
#
# It binds LOOPBACK ONLY, and that is not adjustable from here. Three reasons,
# in increasing order of importance:
#   1. published bridge ports are not LAN-reachable on this device anyway;
#   2. the dashboard refuses any Host header other than the interface it bound
#      to (anti-DNS-rebinding, GHSA-ppp5-vxwm-4cf7) -- so a LAN bind would need
#      the LAN address baked in at start time, and DHCP moves it;
#   3. the agent runs shell commands as root in a chroot holding tunnel
#      credentials and the container database. Loopback plus a tunnel is a
#      deliberate choice, not an accident of configuration.
#
# Reaching it from outside therefore means adding an ingress rule to the tunnel
# with a Host rewrite -- see hermes_hint below, which prints the exact stanza.

HRM_BIN=/usr/local/bin/hermes       # inside the chroot
HRM_PORT_DEFAULT=9119
HRM_PORT_F="$STATE/hermes.port"
HRM_STATE_F="$STATE/hermes"         # exists = start it at boot / keep it up
HRM_LOG=/var/log/hermes-serve.log   # inside the chroot

hermes_port() {
    p=$(cat "$HRM_PORT_F" 2>/dev/null | tr -dc '0-9')
    echo "${p:-$HRM_PORT_DEFAULT}"
}

hermes_installed() { in_chroot "test -x $HRM_BIN" >/dev/null 2>&1; }
hermes_enabled()   { [ -f "$HRM_STATE_F" ]; }

# Match the listener, not the name. `pgrep -f hermes` also matches the agent
# CLI, a `hermes chat` session, and this very command line when it runs inside
# the chroot -- all of which would report a dashboard that is not there.
hermes_running() {
    in_chroot "ss -ltn 2>/dev/null | grep -q '127.0.0.1:$(hermes_port) '" >/dev/null 2>&1
}

# The installer builds the web bundle into hermes_cli/web_dist, NOT web/dist.
# Starting without it serves a blank page and logs nothing useful, so check.
hermes_built() {
    in_chroot 'test -f /usr/local/lib/hermes-agent/hermes_cli/web_dist/index.html' >/dev/null 2>&1
}

hermes_start() {
    hermes_installed || { bad "hermes not installed - see docs/HERMES.md"; return 1; }
    if ! hermes_built; then
        bad "web UI not built"
        say "  cd /usr/local/lib/hermes-agent/web && npm install && npm run build"
        return 1
    fi
    hermes_running && { ok "already running on 127.0.0.1:$(hermes_port)"; return 0; }

    port=$(hermes_port)
    # setsid: without it the server is a child of this shell and dies with the
    # WebUI's ksu.exec, which is a short-lived process.
    in_chroot "export PATH=/usr/local/bin:\$PATH
               mkdir -p /var/log
               setsid nohup $HRM_BIN dashboard --host 127.0.0.1 --port $port \
                   --skip-build --no-open >> $HRM_LOG 2>&1 < /dev/null &" || return 1

    i=0
    while [ $i -lt 20 ]; do
        hermes_running && break
        sleep 1; i=$((i+1))
    done
    if hermes_running; then
        touch "$HRM_STATE_F"
        ok "hermes dashboard on 127.0.0.1:$port"
        hermes_hint
    else
        bad "did not come up - dockerctl hermes log"
        return 1
    fi
}

hermes_stop() {
    rm -f "$HRM_STATE_F"
    in_chroot "pkill -f 'hermes dashboard'" >/dev/null 2>&1
    sleep 1
    hermes_running && { bad "still listening on 127.0.0.1:$(hermes_port)"; return 1; }
    ok "hermes dashboard stopped"
}

# Restart it if it is supposed to be up and is not. Called from the boot loop
# alongside tunnel_supervise.
hermes_supervise() {
    hermes_enabled || return 0
    hermes_running && return 0
    hermes_start >/dev/null 2>&1
}

# Print the ingress stanza rather than editing config.yml. The Host rewrite is
# the non-obvious half and silently omitting it yields a 400 from the origin
# that reads like a tunnel fault.
hermes_hint() {
    port=$(hermes_port)
    if in_chroot "grep -q ':$port' $CF_DIR/config.yml" >/dev/null 2>&1; then
        say "  tunnel: ingress rule present"
    else
        say "  to publish it, add to $CF_DIR/config.yml above the 404 catch-all:"
        say "      - hostname: hermes.example.com"
        say "        service: http://127.0.0.1:$port"
        say "        originRequest:"
        say "          httpHostHeader: 127.0.0.1:$port"
        say "  then: cloudflared tunnel route dns <tunnel> hermes.example.com"
    fi
}

hermes_log() { in_chroot "tail -n ${1:-40} $HRM_LOG" 2>/dev/null; }

hermes_status() {
    hermes_installed || { bad "not installed"; return 1; }
    hermes_enabled && ok "enabled" || bad "not enabled"
    hermes_built   || warn "web UI not built - it will serve a blank page"
    if hermes_running; then
        ok "listening on 127.0.0.1:$(hermes_port)"
        hermes_hint
    else
        bad "not running"
    fi
}
