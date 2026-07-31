#!/system/bin/sh
# hermes.sh - Hermes Agent dashboard, as a container.  . lib.sh, mount.sh,
# daemon.sh, tunnel.sh first.
#
# Hermes (NousResearch/hermes-agent) is an agentic assistant with a web
# dashboard. This file does not install it -- it starts and stops a container
# built from the published image.
#
# IT RUNS IN DOCKER, NOT THE CHROOT, and that is a deliberate trade:
#   + one lifecycle, visible in Portainer and the container list
#   + the agent's shell tools act inside the container, so an agent running
#     commands as root cannot reach Android, /data/adb, or the tunnel
#     credentials. Give it HTTP tools instead of a host shell
#   - it DIES WITH DOCKER. sshd and cloudflared stayed chroot processes
#     precisely so they survive a dockerd fault; hermes does not, and must never
#     be treated as a way back in
#
# Two device-specific fixes are baked into the run arguments below. Neither is
# guessable from the upstream compose file and both cost hours to find.

HRM_CT=hermes
HRM_IMAGE="${HRM_IMAGE:-nousresearch/hermes-agent:v2026.7.20}"
HRM_PORT_DEFAULT=9119
HRM_PORT_F="$STATE/hermes.port"
HRM_STATE_F="$STATE/hermes"        # exists = keep it up / start it at boot
HRM_PASSWD=/root/hermes-passwd     # inside the chroot; see hermes_fixups

hermes_port() {
    p=$(cat "$HRM_PORT_F" 2>/dev/null | tr -dc '0-9')
    echo "${p:-$HRM_PORT_DEFAULT}"
}

hermes_enabled()  { [ -f "$HRM_STATE_F" ]; }
hermes_have_img() { in_chroot_exec docker image inspect "$HRM_IMAGE" >/dev/null 2>&1; }
hermes_have_ct()  { in_chroot_exec docker inspect "$HRM_CT" >/dev/null 2>&1; }
hermes_installed(){ hermes_have_img; }

# Test the LISTENER, not `docker ps`. The container reports "running" for the
# ~30 s its s6 tree spends syncing skills and loading 53 plugins, and it stayed
# "running" throughout a restart loop during which nothing was ever served.
hermes_running() {
    in_chroot "ss -ltn 2>/dev/null | grep -q ':$(hermes_port) '" >/dev/null 2>&1
}

# The image runs its services as the unprivileged `hermes` user (uid 10000), and
# on this kernel that uid CANNOT OPEN A SOCKET AT ALL:
#
#     uid 0                        -> bound
#     uid 10000                    -> PermissionError: Operation not permitted
#     uid 10000 --group-add 3003   -> PermissionError  (still)
#
# Android gates socket creation on `in_group_p(AID_INET) || capable(CAP_NET_RAW)`.
# Adding AID_INET (3003) is what rescued cloudflared, but it does not help here:
# s6-setuidgid re-initialises supplementary groups from the image's own group
# database, discarding whatever --group-add supplied.
#
# The failure surfaces as
#     ERROR: could not bind on any address out of [('127.0.0.1', 9119)]
# which reads as a port conflict. It is not -- nothing else holds the port.
#
# Both the entrypoint wrapper and the dashboard service gate the drop on
# `[ "$(id -u)" = 0 ]`, so the fix is to make `s6-setuidgid hermes` land on uid
# 0: override /etc/passwd so `hermes` IS uid 0. HERMES_UID=0 does NOT work --
# the stage2 hook's usermod cannot take a uid already owned by root, fails
# silently, and leaves files owned by 10000.
hermes_fixups() {
    in_chroot "
      [ -s $HRM_PASSWD ] && exit 0
      docker run --rm --entrypoint /bin/cat '$HRM_IMAGE' /etc/passwd > $HRM_PASSWD 2>/dev/null || exit 1
      sed -i 's/^hermes:x:10000:10000:/hermes:x:0:0:/' $HRM_PASSWD
      grep -q '^hermes:x:0:0:' $HRM_PASSWD
    " >/dev/null 2>&1
}

hermes_create() {
    hermes_fixups || { bad "could not build the passwd override"; return 1; }
    # --network host: published bridge ports are not LAN-reachable on this
    # device, and the dashboard refuses any Host header but the interface it
    # bound to, so a bridge address would be rejected anyway.
    #
    # The `dashboard` subcommand is MANDATORY. With no command the image runs
    # bare `hermes`, which is the INTERACTIVE CHAT: with no tty it exits at once
    # and the container restart-loops every ~25 s, logging no error at all.
    in_chroot "docker rm -f $HRM_CT >/dev/null 2>&1
      docker run -d --name $HRM_CT --network host --restart unless-stopped \
        -v $HRM_PASSWD:/etc/passwd:ro \
        -v /root/.hermes:/opt/data \
        -e TZ=\${TZ:-UTC} --memory 2g \
        '$HRM_IMAGE' dashboard --host 127.0.0.1 --port $(hermes_port) --no-open" >/dev/null 2>&1
}

hermes_start() {
    running || { bad "dockerd is not running - dockerctl start"; return 1; }
    hermes_have_img || { bad "image $HRM_IMAGE not present - see docs/HERMES.md"; return 1; }
    # Record the intent even when it is already up. Returning early without
    # touching the flag left `dockerctl hermes on` reporting [ok] while json
    # still said hermes=off, so the WebUI toggle sprang back to off and the
    # boot supervisor would not have restarted it.
    hermes_running && { touch "$HRM_STATE_F"; ok "already listening on 127.0.0.1:$(hermes_port)"; return 0; }

    if hermes_have_ct; then in_chroot_exec docker start "$HRM_CT" >/dev/null 2>&1
    else hermes_create || { bad "could not create the container"; return 1; }; fi

    # s6 init, skill sync and plugin discovery take well over a minute here.
    i=0
    while [ $i -lt 40 ]; do hermes_running && break; sleep 3; i=$((i+1)); done

    if hermes_running; then
        touch "$HRM_STATE_F"
        ok "hermes dashboard on 127.0.0.1:$(hermes_port)"
        hermes_hint
    else
        bad "did not come up - dockerctl hermes log"
        return 1
    fi
}

hermes_stop() {
    rm -f "$HRM_STATE_F"
    in_chroot_exec docker stop "$HRM_CT" >/dev/null 2>&1
    sleep 1
    hermes_running && { bad "still listening on :$(hermes_port)"; return 1; }
    ok "hermes dashboard stopped"
}

# The restart policy covers a crash, but not `dockerctl stop` then start, and
# not a boot where dockerd comes up after this first ran.
hermes_supervise() {
    hermes_enabled || return 0
    running || return 0
    hermes_running && return 0
    hermes_start >/dev/null 2>&1
}

# Print the ingress stanza rather than editing config.yml. The Host rewrite is
# the non-obvious half: without it the origin returns 400 "Invalid Host header"
# (anti-DNS-rebinding, GHSA-ppp5-vxwm-4cf7), which reads as a tunnel fault.
#
# cloudflared does NOT reload ingress on SIGHUP -- verified on 2026.7.3, no
# reload line appears in its log and the new hostname keeps returning the
# catch-all 404. Restart it.
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
        say "        dockerctl tunnel named        # SIGHUP will not reload it"
    fi
}

hermes_log() { in_chroot_exec docker logs --tail "${1:-40}" "$HRM_CT" 2>&1; }

hermes_status() {
    hermes_have_img || { bad "image not present ($HRM_IMAGE)"; return 1; }
    hermes_enabled && ok "enabled" || bad "not enabled"
    running || { bad "dockerd stopped - hermes cannot run"; return 1; }
    st=$(in_chroot_exec docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$HRM_CT" 2>/dev/null)
    [ -n "$st" ] && say "  container: $st"
    if hermes_running; then
        ok "listening on 127.0.0.1:$(hermes_port)"
        hermes_hint
    else
        bad "not listening"
    fi
}
