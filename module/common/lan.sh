#!/system/bin/sh
##########################################################################
# lan.sh - make the phone findable on the LAN after DHCP moves it.
#
# The address is not stable. Over one session this device was .67, then .72,
# then .85, and each move silently broke every saved bookmark, ssh config entry
# and port scan. Worse, when the tunnel is also down there is no way left to
# find the phone at all except walking to it.
#
# So: record the current address, and push it into the notification shade where
# it is readable without any working connection. `cmd notification post` reuses
# a notification by tag, so re-posting updates the existing one in place rather
# than stacking duplicates.
#
# Caveat worth knowing: notifications posted this way are dismissible. There is
# no ongoing/no-clear flag exposed through `cmd notification`, so a swipe
# removes it until the next publish.
##########################################################################

LAN_STATE_F="$STATE/lanwatch"     # exists = publish automatically
LAN_IP_F="$STATE/lan.ip"          # last published address
LAN_TAG=raphael-lan               # notification tag; reused so it updates

lan_enabled() { [ -f "$LAN_STATE_F" ]; }

# Every global IPv4 with its interface, minus everything that is not a LAN:
# docker bridges, per-compose br-*, veth pairs, and tun* (a VPN app). rmnet_* is
# mobile data - real, but not an address anyone can reach the phone on.
lan_all() {
    ip -4 -o addr show scope global 2>/dev/null | awk '
        { split($4, a, "/"); dev=$2; ip=a[1]
          if (dev ~ /^(docker|br-|veth|tun|lo)/) next
          print dev "\t" ip }'
}

# One address to show. Wi-Fi first: it is the one a laptop on the same network
# can actually use.
lan_primary() {
    lan_all | awk '$1 ~ /^wlan/ {print $2; found=1; exit} END {if (!found) exit 1}' \
      || lan_all | awk '$1 !~ /^rmnet/ {print $2; exit}'
}

lan_ip() { lan_primary 2>/dev/null; }

# Posting requires the Android side, not the chroot - `cmd` is an Android
# binary. Failure is not fatal: the address is still written to disk.
lan_notify() {
    ip="${1:-unknown}"; extra="${2:-}"
    cmd notification post -S bigtext -t "Docker on raphael" "$LAN_TAG" \
        "LAN  $ip
$extra" >/dev/null 2>&1
}

# force=1 publishes even when the toggle is off (the WebUI's manual button).
lan_publish() {
    force="${1:-0}"
    [ "$force" = 1 ] || lan_enabled || return 0

    ip=$(lan_ip)
    [ -n "$ip" ] || { say "  no LAN address (no Wi-Fi?)"; return 1; }

    n=0
    running && n=$(in_chroot_exec docker ps -q 2>/dev/null | grep -c . || echo 0)
    b=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    w=$(wake_held 2>/dev/null && echo "awake" || echo "may sleep")

    lan_notify "$ip" "$n containers · ${b}% $s · $w"
    printf '%s\n' "$ip" > "$LAN_IP_F"
    echo "$ip"
}

# Only notify when it actually changed - the boot loop calls this every 60s and
# a notification that re-posts every minute is spam, not information.
lan_watch_tick() {
    lan_enabled || return 0
    ip=$(lan_ip) || return 0
    [ -n "$ip" ] || return 0
    [ "$ip" = "$(cat "$LAN_IP_F" 2>/dev/null)" ] && return 0
    lan_publish 1 >/dev/null
}

lan_status() {
    ip=$(lan_ip)
    say "  address : ${ip:-none}"
    say "  last    : $(cat "$LAN_IP_F" 2>/dev/null || echo never published)"
    lan_enabled && ok "auto-publish ON (notifies when the address changes)" \
                || bad "auto-publish OFF"
    say "  all interfaces:"
    lan_all | sed 's/^/    /'
}
