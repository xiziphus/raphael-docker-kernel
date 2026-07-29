#!/system/bin/sh
# Diagnose, and optionally repair, every prerequisite.  Sourced by dockerctl.
#
# Exists because every failure in this stack surfaces far from its cause: a
# missing routing rule looks like a broken image pull, a nodev mount looks like
# a permissions bug, and a plain-directory chroot root looks like a corrupt
# layer. Check the causes directly.

do_doctor() {
    _fix=0; [ "${1:-}" = "--fix" ] && _fix=1
    _bad=0

    say "== kernel =="
    for ns in user pid ipc net mnt uts; do
        [ -e "/proc/self/ns/$ns" ] && ok "namespace $ns" || { bad "namespace $ns MISSING"; _bad=1; }
    done
    for cg in pids devices memory freezer; do
        grep -qE "^$cg[[:space:]]" /proc/cgroups 2>/dev/null \
            && ok "cgroup $cg" || { bad "cgroup $cg MISSING"; _bad=1; }
    done
    grep -qw overlay /proc/filesystems 2>/dev/null && ok "overlayfs" || { bad "overlayfs MISSING"; _bad=1; }
    if [ "$_bad" = 1 ]; then
        say ""
        bad "This kernel cannot run Docker. Flash the Docker-enabled boot image."
        return 1
    fi

    say ""
    say "== storage =="
    grep -qE " /data .*noexec" /proc/mounts 2>/dev/null \
        && { bad "/data is noexec"; _bad=1; } || ok "/data permits exec"
    have_rootfs && ok "rootfs at $ROOT" || { bad "no rootfs - run 'dockerctl setup'"; return 1; }

    say ""
    say "== mounts =="
    if mounted "$ROOT"; then ok "chroot root is a mount point"
    else
        bad "chroot root is NOT a mount point - image pulls will fail"
        [ "$_fix" = 1 ] && { mount_chroot >/dev/null && ok "  repaired"; } || _bad=1
    fi
    for m in proc sys dev dev/pts sys/fs/cgroup; do
        mounted "$ROOT/$m" && ok "$m" || {
            if [ "$_fix" = 1 ]; then mount_chroot >/dev/null; ok "$m (repaired)"
            else bad "$m not mounted"; _bad=1; fi; }
    done

    say ""
    say "== networking =="
    if ! net_check; then
        if [ "$_fix" = 1 ]; then net_apply && ok "repaired"; else _bad=1; fi
    fi
    vpn_holds_root && warn "a VPN app holds uid 0 (tun0) - pulls may fail intermittently"

    say ""
    say "== daemon =="
    if running; then
        ok "dockerd running"
        in_chroot 'docker info --format "  storage={{.Driver}} cgroup=v{{.CgroupVersion}} containers={{.Containers}} images={{.Images}}"' 2>/dev/null
    else
        bad "dockerd not running"
        [ "$_fix" = 1 ] && daemon_start || _bad=1
    fi

    say ""
    [ "$_bad" = 0 ] && ok "all checks passed" || \
        { warn "problems found - re-run with: dockerctl doctor --fix"; return 1; }
}
