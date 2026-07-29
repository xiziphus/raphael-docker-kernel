#!/system/bin/sh
# Stop everything and drop the routing rules, but DELIBERATELY keep
# /data/debian: it holds your images, volumes and containers.
#   rm -rf /data/debian /data/adb/docker    <- to reclaim the space
[ -x /data/adb/docker/dockerctl ] && sh /data/adb/docker/dockerctl stop
[ -f /data/adb/docker/net.sh ] && { . /data/adb/docker/lib.sh; . /data/adb/docker/net.sh; net_clear; }
