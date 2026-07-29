#!/system/bin/sh
# dockerd lifecycle.  . lib.sh and mount.sh first.

daemon_start() {
    running && { ok "dockerd already running"; return 0; }
    mount_chroot >/dev/null || return 1
    net_apply

    in_chroot '
      mkdir -p /var/log /var/lib/docker
      # pkill leaves a pidfile and a containerd socket behind; dockerd then
      # either refuses to start ("pid file found") or hangs dialling a dead
      # containerd and force-shuts-down. Clear the runtime state every time.
      rm -rf /var/run/docker /var/run/docker.sock /var/run/docker.pid /run/docker.pid 2>/dev/null
      mkdir -p /var/run/docker

      # pivot_root(2) is defined against the MOUNT NAMESPACE root, which inside
      # a chroot is still Android /. runc therefore fails with
      #   error jailing process inside rootfs: pivot_root .: invalid argument
      # DOCKER_RAMDISK makes it use MS_MOVE + chroot instead. Upstream ships
      # this for initramfs roots, which have the same property.
      export DOCKER_RAMDISK=1

      nohup dockerd --host=unix:///var/run/docker.sock \
        --exec-opt native.cgroupdriver=cgroupfs \
        >> /var/log/dockerd.log 2>&1 &

      for i in $(seq 1 90); do [ -S /var/run/docker.sock ] && break; sleep 1; done
      [ -S /var/run/docker.sock ] || { echo "dockerd failed; see $ROOT/var/log/dockerd.log"; exit 1; }
    ' || return 1

    ok "dockerd started"
    vpn_holds_root && warn "a VPN app is capturing uid 0 into tun0 - image pulls may fail intermittently"
    return 0
}

daemon_stop() {
    running || { ok "dockerd not running"; return 0; }
    in_chroot 'docker ps -q 2>/dev/null | xargs -r docker stop -t 10' >/dev/null 2>&1
    pkill -x dockerd 2>/dev/null
    pkill -x containerd 2>/dev/null
    pkill -f containerd-shim 2>/dev/null
    sleep 3
    ok "dockerd stopped"
}
