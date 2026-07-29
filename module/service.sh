#!/system/bin/sh
##########################################################################
# late_start. Runs after /data is decrypted, which matters because the whole
# rootfs lives on /data.
#
# The routing and firewall rules are re-applied unconditionally: netd rewrites
# its own rules on every connectivity change, and ours do not survive that.
# Starting the daemon is opt-in -- dockerd and containerd cost real battery.
##########################################################################
D=/data/adb/docker
. "$D/lib.sh"; . "$D/mount.sh"; . "$D/net.sh"; . "$D/daemon.sh"

sleep 40                       # let Android finish booting before competing for I/O
have_rootfs || exit 0
net_apply >> "$D/boot.log" 2>&1

[ -f "$D/autostart" ] || exit 0
daemon_start >> "$D/boot.log" 2>&1
# --restart=always containers (Portainer and anything you flag) come back by
# themselves once dockerd is up.

# netd rewrites its rules on every Wi-Fi/mobile transition, silently breaking
# container networking mid-session. Re-assert ours periodically; it is a no-op
# when they are already present.
[ -f "$D/no-netwatch" ] && exit 0
while true; do
    sleep 120
    net_check >/dev/null 2>&1 || net_apply >/dev/null 2>&1
done &
