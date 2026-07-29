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
    _ifaces=$(uplinks)
    [ -n "$_ifaces" ] || { warn "no uplink with a default route"; return 1; }

    # Return path: replies are un-NAT'd back to a container address and then
    # need the bridge route, which exists only in table main.
    ip rule del to "$POOL" lookup main 2>/dev/null
    ip rule add to "$POOL" lookup main priority 11400 2>/dev/null

    # Egress: one rule per uplink, Wi-Fi first. A table with no default route
    # falls through to the next rule, so Wi-Fi <-> mobile failover is automatic.
    _p=11500
    for i in $_ifaces; do
        ip rule del from "$POOL" lookup "$i" 2>/dev/null
        ip rule add from "$POOL" lookup "$i" priority "$_p" 2>/dev/null
        _p=$((_p+1))
    done

    # FORWARD reaches Android's tetherctrl_FORWARD -- which ends in "DROP all"
    # because tethering is off -- before anything Docker installs. Jump ahead of
    # it. Matching on subnet rather than interface covers docker0 and every
    # br-<id> that compose creates. Docker's own DOCKER chain still decides
    # which published ports are reachable, so this exposes nothing extra.
    iptables -D FORWARD -s "$POOL" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$POOL" -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -s "$POOL" -j ACCEPT 2>/dev/null
    iptables -I FORWARD 2 -d "$POOL" -j ACCEPT 2>/dev/null
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
