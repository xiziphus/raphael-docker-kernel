#!/system/bin/sh
# Chroot mount lifecycle.  . lib.sh first.

mount_chroot() {
    have_rootfs || { bad "no rootfs at $ROOT - run 'dockerctl setup'"; return 1; }

    # The chroot root must itself be a MOUNT POINT, not just a directory.
    # Docker unpacks every layer inside a private mount namespace and starts by
    # calling mount("", "/", NULL, MS_REC|MS_SLAVE, NULL). On a plain directory
    # that returns EINVAL and the pull dies with
    #   failed to register layer: ... remount /, flags: 0x84000
    mounted "$ROOT" || $BB mount --bind "$ROOT" "$ROOT" || return 1
    $BB mount --make-rprivate "$ROOT" 2>/dev/null

    # /dev must be its OWN tmpfs. /data is mounted nodev, so device nodes
    # created there exist but cannot be opened. tmpfs carries no nodev.
    _m tmpfs tmpfs dev mode=755
    for spec in "null 1 3" "zero 1 5" "full 1 7" "random 1 8" "urandom 1 9" "tty 5 0"; do
        set -- $spec
        [ -e "$ROOT/dev/$1" ] || $BB mknod -m 666 "$ROOT/dev/$1" c "$2" "$3" 2>/dev/null
    done

    _m proc   proc   proc
    _m sysfs  sysfs  sys
    _m devpts devpts dev/pts
    _m tmpfs  tmpfs  dev/shm mode=1777
    _m tmpfs  tmpfs  run     mode=755

    # Docker reads and writes the cgroup2 unified hierarchy. Android already
    # mounts it; rbind rather than remount so we inherit exactly what it set up.
    mkdir -p "$ROOT/sys/fs/cgroup" 2>/dev/null
    mounted "$ROOT/sys/fs/cgroup" || \
        $BB mount --rbind /sys/fs/cgroup "$ROOT/sys/fs/cgroup" 2>/dev/null

    ln -sf /proc/self/fd   "$ROOT/dev/fd"     2>/dev/null
    ln -sf /proc/self/fd/0 "$ROOT/dev/stdin"  2>/dev/null
    ln -sf /proc/self/fd/1 "$ROOT/dev/stdout" 2>/dev/null
    ln -sf /proc/self/fd/2 "$ROOT/dev/stderr" 2>/dev/null

    # Debian ships /etc/resolv.conf as a symlink to
    # /run/systemd/resolve/stub-resolv.conf. We mount an empty tmpfs on /run and
    # run no systemd-resolved, so that link dangles and writing THROUGH it fails
    # with ENOENT. Replace the link with a real file.
    rm -f "$ROOT/etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOT/etc/resolv.conf"
    [ -s "$ROOT/etc/hostname" ] || echo raphael > "$ROOT/etc/hostname"
    grep -q raphael "$ROOT/etc/hosts" 2>/dev/null || \
        printf '127.0.0.1 localhost\n127.0.1.1 raphael\n' > "$ROOT/etc/hosts"
    return 0
}

_m() {  # _m <type> <src> <relative-target> [opts]
    _t="$ROOT/$3"
    mkdir -p "$_t" 2>/dev/null
    mounted "$_t" && return 0
    if [ -n "${4:-}" ]; then $BB mount -t "$1" -o "$4" "$2" "$_t" 2>/dev/null
    else                     $BB mount -t "$1" "$2" "$_t" 2>/dev/null; fi
}

umount_chroot() {
    # Deepest first, or the parent unmount fails with EBUSY.
    grep -o " $ROOT[^ ]* " /proc/mounts 2>/dev/null | tr -d ' ' \
      | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- \
      | while read -r m; do $BB umount -l "$m" 2>/dev/null; done
}

# chroot inherits Android's PATH (/system/bin:/vendor/bin:...), none of which
# exists inside Debian, so /etc/profile fails with "id: command not found".
# Every entry point below sets a Debian PATH explicitly.
CPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

in_chroot() {          # run a command STRING (internal callers, heredocs)
    mount_chroot >/dev/null || return 1
    if [ "$#" -eq 0 ]; then
        PATH=$CPATH $BB chroot "$ROOT" /bin/bash -l
    else
        PATH=$CPATH $BB chroot "$ROOT" /bin/bash -c "export PATH=$CPATH; $*"
    fi
}

in_chroot_exec() {     # run a command preserving ARGV exactly
    # Needed for passthrough: `dockerctl ps --format "{{.Names}} {{.Image}}"`
    # must reach docker as ONE --format argument. Flattening argv into a string
    # splits it on spaces and docker rejects the extras.
    mount_chroot >/dev/null || return 1
    PATH=$CPATH $BB chroot "$ROOT" /usr/bin/env "PATH=$CPATH" "$@"
}
