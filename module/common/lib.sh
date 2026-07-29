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
# Emit the routing TABLE for every interface that owns a default route, Wi-Fi
# first. Two things this deliberately avoids:
#
#   - Looking tables up BY NAME ("ip route show table wlan0"). That depends on
#     netd's name map in /data/misc/net/rt_tables, which is not reliably
#     resolvable from the boot service; egress rules were silently never
#     installed as a result. Parsing "table all" yields the identifier directly
#     and `ip rule lookup` accepts a name or a number equally.
#   - dummy0, which also carries a default route and would blackhole every
#     container packet if it were ever chosen.
#
# Rules are installed for ALL of them: a table with no default route falls
# through to the next rule, so Wi-Fi <-> mobile failover is automatic.
uplinks() {
    ip -4 route show table all 2>/dev/null | awk '
        /^default/ {
            dev=""; tbl="";
            for (i = 1; i <= NF; i++) {
                if ($i == "dev")   dev = $(i+1);
                if ($i == "table") tbl = $(i+1);
            }
            if (tbl == "" || dev == "")      next;
            if (dev ~ /^(dummy|lo|tun)/)     next;
            print (dev ~ /^wlan/ ? 0 : 1) " " tbl;
        }' | sort -s -k1,1n | cut -d" " -f2 | awk "!seen[\$0]++"
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
