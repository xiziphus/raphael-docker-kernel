#!/system/bin/sh
##########################################################################
# sshd.sh - the way back in.
#
# sshd runs in the chroot, NOT in a container, on purpose: it must survive
# dockerd being stopped, broken, or mid-upgrade. That is exactly when you need
# a shell.
#
# The chroot has no network namespace of its own -- in_chroot is a plain
# busybox chroot -- so sshd binds Android's netstack directly. Loopback-only is
# therefore reachable through the Cloudflare tunnel and nothing else; binding
# the wildcard address puts it on the LAN as well.
#
# Two paths are better than one. The tunnel depends on the internet, on
# Cloudflare, and (until it moved) on Docker. The LAN path depends on none of
# those, so a Docker-level failure still leaves a shell to fix it from.
##########################################################################

SSH_PORT_DEFAULT=2222
SSH_CONF=/etc/ssh/sshd_config.d/99-android.conf
SSH_LAN_F="$STATE/sshlan"        # exists = also listen on the LAN
SSH_KEYS=/root/.ssh/authorized_keys

sshd_installed() { in_chroot 'test -x /usr/sbin/sshd' >/dev/null 2>&1; }
sshd_lan()       { [ -f "$SSH_LAN_F" ]; }

# Match the LISTENER, not the process name.
#
# `pgrep -x sshd` matches ANY sshd on the device, including one inside a
# container in its own namespace. During a recovery that is exactly what
# happened: a rescue container held :2222, the real sshd could not start because
# /run/sshd had the wrong ownership, and sshd_enable still printed
#     [ok] sshd on 0.0.0.0:2222 - LAN and tunnel
# because pgrep found the container's copy. Two layers each reported success on
# the strength of the other, and the fault only surfaced when that container was
# removed and every remote path went dark at once.
#
# A bound port is what callers actually care about, so test that instead.
sshd_running() {
    in_chroot "ss -ltn 'sport = :$(sshd_port)' 2>/dev/null | grep -q LISTEN" >/dev/null 2>&1
}

sshd_port() {
    p=$(in_chroot "grep -rhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
        | head -1 | awk '{print \$2}'" 2>/dev/null | tr -d '\r\n ')
    echo "${p:-$SSH_PORT_DEFAULT}"
}

sshd_install() {
    sshd_installed && return 0
    say "  installing openssh-server (needs network, may take a minute)"
    in_chroot 'export DEBIAN_FRONTEND=noninteractive
               apt-get update >/dev/null 2>&1
               apt-get install -y openssh-server >/dev/null 2>&1' || true
    sshd_installed
}

# Write OUR drop-in as the single source of truth for Port and ListenAddress,
# and neutralise any other drop-in that sets either.
#
# This is not tidiness. sshd treats repeated Port as additive, and
# `ListenAddress 0.0.0.0` plus `ListenAddress 127.0.0.1` on the same port means
# it tries to bind the loopback address twice -- the wildcard already covers it
# -- so sshd refuses to start. Two files each looking reasonable in isolation
# produce a daemon that will not run.
sshd_write_config() {
    port=$(sshd_port)
    if sshd_lan; then addr="0.0.0.0"; else addr="127.0.0.1"; fi

    in_chroot "
      mkdir -p /etc/ssh/sshd_config.d /run/sshd
      for f in /etc/ssh/sshd_config.d/*.conf; do
          [ -e \"\$f\" ] || continue
          [ \"\$f\" = '$SSH_CONF' ] && continue
          if grep -qsE '^[[:space:]]*(Port|ListenAddress)[[:space:]]' \"\$f\"; then
              mv -f \"\$f\" \"\$f.disabled-by-dockerctl\"
              echo \"  superseded \$(basename \"\$f\") (it set Port/ListenAddress)\"
          fi
      done
      cat > '$SSH_CONF' <<CONF
# Managed by dockerctl -- edits here are overwritten by 'dockerctl ssh'.
# (No backticks in this heredoc: the whole block is inside a double-quoted
# in_chroot argument, so the outer shell would run them as substitutions.)
Port $port
ListenAddress $addr
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
    "
}

# Restart rather than start: a config change is worthless until the listener is
# rebound. Established sessions survive - sshd forks per connection, so killing
# the listener does not drop the shell issuing the command.
sshd_restart() {
    if ! in_chroot '/usr/sbin/sshd -t' >/dev/null 2>&1; then
        bad "sshd config invalid - not restarting"
        in_chroot '/usr/sbin/sshd -t' 2>&1 | sed 's/^/    /'
        return 1
    fi
    in_chroot 'pkill -x sshd >/dev/null 2>&1; sleep 1; /usr/sbin/sshd'
    sshd_running
}

sshd_enable() {
    sshd_install || { bad "openssh-server not installed - check network and retry"; return 1; }
    sshd_write_config
    sshd_restart || return 1
    touch "$STATE/sshd"
    wake_floor_sync 2>/dev/null    # a way in now exists; stay awake for it
    port=$(sshd_port)
    if sshd_lan; then
        ok "sshd on 0.0.0.0:$port - LAN and tunnel"
        ip=$(lan_ip 2>/dev/null); [ -n "$ip" ] && say "  ssh -p $port root@$ip"
    else
        ok "sshd on 127.0.0.1:$port - tunnel only"
    fi
    in_chroot "test -s $SSH_KEYS" >/dev/null 2>&1 \
      || warn "no authorized_keys yet - nothing can log in until you add one"
}

sshd_disable() {
    rm -f "$STATE/sshd"
    in_chroot 'pkill -x sshd' >/dev/null 2>&1
    wake_floor_sync 2>/dev/null
    ok "sshd disabled"
}

sshd_set_lan() {
    case "${1:-}" in
        on)  touch "$SSH_LAN_F" ;;
        off) rm -f "$SSH_LAN_F" ;;
        *)   return 1 ;;
    esac
    # Only rewrite and bounce if it is supposed to be running; otherwise this
    # just records the preference for the next enable.
    if [ -f "$STATE/sshd" ] && sshd_installed; then
        sshd_write_config
        sshd_restart || return 1
    fi
    sshd_lan && ok "sshd will listen on the LAN" || ok "sshd loopback only"
}

sshd_status() {
    [ -f "$STATE/sshd" ] && ok "enabled at boot" || bad "not enabled at boot"
    sshd_installed || { bad "openssh-server NOT installed"; return 1; }
    sshd_running   && ok "running on $(sshd_lan && echo 0.0.0.0 || echo 127.0.0.1):$(sshd_port)" \
                   || bad "not running"
    n=$(in_chroot "grep -c . $SSH_KEYS 2>/dev/null" 2>/dev/null | tr -d '\r\n ')
    case "$n" in ''|0) bad "authorized_keys EMPTY - no login possible" ;;
                 *)    ok "$n authorized key(s)" ;; esac
    if sshd_lan; then
        ip=$(lan_ip 2>/dev/null)
        [ -n "$ip" ] && say "  ssh -p $(sshd_port) root@$ip"
    fi
}
