#!/system/bin/sh
# One-time: install a Debian rootfs and Docker into it.  . lib.sh, mount.sh first.
MIRROR="https://images.linuxcontainers.org/images/debian/bookworm/arm64/default"

fetch() {  # fetch <url> <dest> -- Android ships curl; busybox wget is the fallback
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$2" "$1"
    else
        $BB wget -O "$2" "$1"
    fi
}

do_setup() {
    _src="${1:-}"
    if have_rootfs; then
        bad "$ROOT is already populated."
        say "  To reinstall:  dockerctl stop && rm -rf $ROOT && dockerctl setup"
        return 1
    fi

    if [ -z "$_src" ]; then
        say "== locating latest Debian bookworm arm64 rootfs =="
        _stamp=$(fetch "$MIRROR/" /dev/stdout 2>/dev/null \
                 | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -u | tail -1)
        [ -n "$_stamp" ] || {
            bad "could not reach the image server."
            say "  Download rootfs.tar.xz on a PC, push it, and pass the path:"
            say "    adb push rootfs.tar.xz /data/local/tmp/"
            say "    su -c 'dockerctl setup /data/local/tmp/rootfs.tar.xz'"
            return 1; }
        _src=/data/local/tmp/rootfs.tar.xz
        say "== downloading $_stamp (~90 MB) =="
        fetch "$MIRROR/$_stamp/rootfs.tar.xz" "$_src" || { bad "download failed"; return 1; }
    fi
    [ -s "$_src" ] || { bad "not found: $_src"; return 1; }

    say "== extracting to $ROOT (~450 MB) =="
    mkdir -p "$ROOT"
    ( cd "$ROOT" && $BB tar -xJf "$_src" ) || { bad "extract failed"; return 1; }

    say "== installing Docker =="
    in_chroot '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      # apparmor ships a postinst that cannot succeed here: Android uses SELinux
      # and this kernel has no AppArmor LSM. Docker does not need it, so let the
      # failure through and reconcile the rest of the dpkg state afterwards.
      apt-get install -y docker.io iptables || true
      dpkg --configure -a 2>/dev/null || true
      docker --version
    '
    # asu: Android root from inside the chroot. Installed here so an ssh
    # session can reach dumpsys, content, pm and the boot partition.
    if [ -f "$STATE/asu" ]; then
        cp -f "$STATE/asu" "$ROOT/usr/local/bin/asu" && chmod 755 "$ROOT/usr/local/bin/asu"
        ok "asu installed (Android root from the chroot)"
    fi

    say ""
    ok "setup complete"
    say "  dockerctl start        # start the daemon"
    say "  dockerctl ui start     # web UI on :9000"
}
