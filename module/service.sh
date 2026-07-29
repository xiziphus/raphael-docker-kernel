#!/system/bin/sh
##########################################################################
# late_start. Runs after /data is decrypted, which matters because the whole
# rootfs lives on /data.
#
# Routing and firewall rules are re-applied unconditionally: netd rewrites its
# own rules on every connectivity change and ours do not survive that.
# Starting the daemon is opt-in -- dockerd and containerd cost real battery.
##########################################################################
D=/data/adb/docker
. "$D/lib.sh"; . "$D/mount.sh"; . "$D/net.sh"; . "$D/daemon.sh"

have_rootfs || exit 0

# Wait for an uplink rather than sleeping a fixed interval and hoping. At boot
# Wi-Fi typically associates well after late_start, so a fixed delay applied the
# rules against no network at all and container networking came up broken.
# Cap the wait so a genuinely offline boot still proceeds.
i=0
while [ "$i" -lt 90 ]; do
    [ -n "$(uplinks)" ] && break
    sleep 2
    i=$((i+1))
done

net_apply >> "$D/boot.log" 2>&1

[ -f "$D/autostart" ] || exit 0
daemon_start >> "$D/boot.log" 2>&1
# --restart=always containers come back by themselves once dockerd is up.

# netd rewrites its rules on every Wi-Fi/mobile transition, silently breaking
# container networking mid-session. Re-assert ours; a no-op when already
# present. Failures are logged rather than discarded so this stays diagnosable.
[ -f "$D/no-netwatch" ] && exit 0
while true; do
    sleep 60
    net_check >/dev/null 2>&1 || net_apply >> "$D/boot.log" 2>&1
done &
