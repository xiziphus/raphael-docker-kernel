#!/system/bin/sh
# Android-specific networking for Docker bridges.  . lib.sh first.
#
# Android does not use a conventional routing table. netd installs a table per
# network selected by fwmark/uid rules, and it DELETES the usual
# "32766: from all lookup main" rule -- the list ends at
# "32000: from all unreachable". Docker's bridge routes live in main, so without
# help they are never consulted and every container packet is dropped.
#
# netd rewrites its rules whenever connectivity changes, so this is re-applied
# at boot, on every daemon start, and by 'dockerctl doctor --fix'.

net_apply() {
    # These two do NOT depend on an uplink, so install them first and always.
    # At boot this function runs before Wi-Fi has associated; bailing early on a
    # missing uplink used to leave NOTHING installed, and the daemon then came
    # up with container networking silently broken.
    ip rule del to "$POOL" lookup main 2>/dev/null
    ip rule add to "$POOL" lookup main priority 11400 2>/dev/null

    iptables -D FORWARD -s "$POOL" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$POOL" -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -s "$POOL" -j ACCEPT 2>/dev/null
    iptables -I FORWARD 2 -d "$POOL" -j ACCEPT 2>/dev/null

    # Egress needs a live uplink. One rule per interface that owns a default
    # route, Wi-Fi first: a table with no default falls through to the next
    # rule, so Wi-Fi <-> mobile failover needs no reconfiguration.
    _ifaces=$(uplinks)
    if [ -z "$_ifaces" ]; then
        warn "no uplink yet - egress rules deferred until one appears"
        return 1
    fi
    _p=11500
    for i in $_ifaces; do
        ip rule del from "$POOL" lookup "$i" 2>/dev/null
        ip rule add from "$POOL" lookup "$i" priority "$_p" 2>/dev/null
        _p=$((_p+1))
    done
    return 0
}

net_check() {
    _r=0
    ip rule show 2>/dev/null | grep -q "to $POOL lookup main" \
        && ok "return-path rule" || { bad "return-path rule missing"; _r=1; }
    ip rule show 2>/dev/null | grep -q "from $POOL" \
        && ok "egress rule ($(uplinks | tr '\n' ' '))" || { bad "egress rule missing"; _r=1; }
    iptables -S FORWARD 2>/dev/null | grep -q -- "-s $POOL -j ACCEPT" \
        && ok "FORWARD accept" || { bad "FORWARD accept missing"; _r=1; }
    return $_r
}

net_clear() {
    ip rule del to "$POOL" lookup main 2>/dev/null
    for i in $(uplinks); do ip rule del from "$POOL" lookup "$i" 2>/dev/null; done
    iptables -D FORWARD -s "$POOL" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$POOL" -j ACCEPT 2>/dev/null
}
