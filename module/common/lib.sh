#!/system/bin/sh
# Shared helpers. Sourced by dockerctl and by service.sh.
# POSIX sh only -- Android's /system/bin/sh is mksh, not bash.

ROOT="${DOCKER_ROOT:-/data/debian}"
STATE=/data/adb/docker
POOL="${DOCKER_POOL:-172.16.0.0/12}"          # Docker's whole default pool
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox

say()  { echo "$*"; }
ok()   { echo "  [ok]   $*"; }
warn() { echo "  [warn] $*"; }
bad()  { echo "  [FAIL] $*"; }

# --- uplinks ---------------------------------------------------------------
# Android keeps a routing table per network. Return every interface that owns a
# default route, Wi-Fi first. Rules are installed for ALL of them: if a table
# has no default route the lookup falls through to the next rule, so switching
# between Wi-Fi and mobile data needs no reconfiguration.
uplinks() {
    for i in wlan0 rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 \
             rmnet_data4 rmnet_data5 rmnet_data6 rmnet_data7 eth0; do
        ip route show table "$i" 2>/dev/null | grep -q '^default' && echo "$i"
    done
}

# --- a VPN holding uid 0 breaks dockerd -------------------------------------
# Android allows one VPN. Apps like Blokada claim uid range 0-1000, which
# includes root, and route it into a tun with no default route -- dockerd then
# fails DNS with "connect: network is unreachable". Nothing we can fix from
# here; report it so the cause is obvious instead of looking like a Docker bug.
vpn_holds_root() {
    ip rule show 2>/dev/null | grep -q 'uidrange 0-' && \
    ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && return 0
    return 1
}

mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

running() { pgrep -x dockerd >/dev/null 2>&1; }

have_rootfs() { [ -x "$ROOT/usr/bin/env" ] || [ -x "$ROOT/bin/bash" ]; }
