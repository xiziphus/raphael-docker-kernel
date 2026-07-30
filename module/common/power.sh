#!/system/bin/sh
##########################################################################
# power.sh - battery guard and the status notification.
#
# A held wakelock defeats the phone's only defence against being left on. Run
# unplugged with the lifeline lock held and it will flatten itself, and when it
# dies it dies hard: containers killed mid-write, no clean shutdown, and a
# device that cannot be woken remotely to fix any of it.
#
# So below a threshold, on battery, stop the whole stack deliberately and say
# so. A phone with 15% left and nothing running is recoverable. A phone at 0%
# is a trip to wherever you left it.
#
# Notifications go through `cmd notification post`, which is an Android binary,
# so all of this runs on the Android side rather than in the chroot. Posting
# with a fixed tag replaces the previous notification instead of stacking.
# There is no ongoing/no-clear flag exposed there, so the status notification
# is dismissible and simply reappears on the next tick.
##########################################################################

PWR_LOW_F="$STATE/battery.min"       # threshold, percent. absent = default
PWR_GUARD_F="$STATE/battery.guard"   # exists = guard armed
PWR_NOTIFY_F="$STATE/notify"         # exists = keep a status notification
PWR_TRIPPED_F="$STATE/battery.tripped"
PWR_LOW_DEFAULT=20
NOTIFY_TAG_STATUS=raphael-status
NOTIFY_TAG_ALERT=raphael-alert

BATT=/sys/class/power_supply/battery

batt_pct()      { cat "$BATT/capacity" 2>/dev/null; }
batt_status()   { cat "$BATT/status" 2>/dev/null; }
batt_charging() { case "$(batt_status)" in Charging|Full) return 0 ;; *) return 1 ;; esac; }
pwr_threshold() {
    v=$(cat "$PWR_LOW_F" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) echo "$PWR_LOW_DEFAULT" ;; *) echo "$v" ;; esac
}
pwr_guard_on() { [ -f "$PWR_GUARD_F" ]; }
notify_on()    { [ -f "$PWR_NOTIFY_F" ]; }

notify_post() {  # notify_post <tag> <title> <body>
    cmd notification post -S bigtext -t "$2" "$1" "$3" >/dev/null 2>&1
}
notify_clear() { cmd notification cancel "$1" >/dev/null 2>&1; }

# The one-line summary that goes in the shade. Deliberately the things you
# cannot see from outside: is it reachable, will it stay awake, how much
# battery is left.
notify_status_post() {
    notify_on || return 0
    n=0; running && n=$(in_chroot_exec docker ps -q 2>/dev/null | grep -c . || echo 0)
    ip=$(lan_ip 2>/dev/null)
    w=$( { wake_held || wake_floor_held; } 2>/dev/null && echo awake || echo "may sleep")
    t=$(tunnel_running 2>/dev/null && echo up || echo down)
    s=$(sshd_running 2>/dev/null && echo up || echo down)
    notify_post "$NOTIFY_TAG_STATUS" "Docker · $n running · $(batt_pct)%" \
"LAN     ${ip:-none}
tunnel  $t     ssh  $s
power   $(batt_status) · $w"
}

# Stop everything, in the order that keeps the device useful longest: workloads
# first, then Docker, then the remote access that is only worth keeping while
# there is power to serve it. The wakelock goes last so the phone can finally
# sleep and stretch what is left.
pwr_stop_all() {
    reason="${1:-requested}"
    say "  stopping everything ($reason)"
    notify_post "$NOTIFY_TAG_ALERT" "Docker stopping — $reason" \
"Battery $(batt_pct)% and discharging.
Stopping containers, Docker, tunnel and SSH so the phone survives.
Plug in, then: dockerctl start"

    running && in_chroot 'docker ps -q 2>/dev/null | xargs -r docker stop -t 20' >/dev/null 2>&1
    daemon_stop >/dev/null 2>&1
    tunnel_stop >/dev/null 2>&1
    sshd_disable >/dev/null 2>&1

    # Only now release the locks: everything above needs the device awake to
    # shut down cleanly.
    rm -f "$WAKE_NOFLOOR_F"
    echo off > "$WAKE_MODE_F"
    wake_release; wake_floor_sync
    ok "everything stopped"
}

# Called from the boot loop. Arms once and latches, so a phone hovering at the
# threshold does not stop-start repeatedly.
pwr_tick() {
    notify_status_post

    pwr_guard_on || return 0
    p=$(batt_pct); [ -n "$p" ] || return 0

    if batt_charging; then
        # Recovered: re-arm for next time and say so once.
        if [ -f "$PWR_TRIPPED_F" ] && [ "$p" -gt "$(( $(pwr_threshold) + 10 ))" ]; then
            rm -f "$PWR_TRIPPED_F"
            notify_post "$NOTIFY_TAG_ALERT" "Docker guard re-armed" \
"Charging again at ${p}%. Start back up with: dockerctl start"
        fi
        return 0
    fi

    [ -f "$PWR_TRIPPED_F" ] && return 0
    [ "$p" -le "$(pwr_threshold)" ] || return 0

    touch "$PWR_TRIPPED_F"
    pwr_stop_all "battery ${p}%" >> "$STATE/boot.log" 2>&1
}

pwr_status() {
    say "  battery : $(batt_pct)% $(batt_status)"
    say "  cutoff  : $(pwr_threshold)%"
    pwr_guard_on && ok "guard ARMED - stops everything below cutoff on battery" \
                 || bad "guard off"
    [ -f "$PWR_TRIPPED_F" ] && warn "guard has TRIPPED - not restarted automatically"
    notify_on && ok "status notification on" || bad "status notification off"
}
