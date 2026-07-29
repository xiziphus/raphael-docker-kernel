#!/system/bin/sh
##########################################################################
# One zip: kernel + userspace.
#
# The kernel is installed by patching YOUR CURRENT boot image rather than by
# shipping a prebuilt one. A prebuilt boot.img necessarily carries the ramdisk,
# DTB and os_patch_level of whoever built it. Flashing someone else's ramdisk
# against your /vendor bootloops; flashing their os_patch_level is worse --
# Android derives FBE keys from it, so a mismatch makes /data unreadable and
# looks like data corruption. Patching in place cannot get any of that wrong.
##########################################################################
SKIPUNZIP=0
STATE=/data/adb/docker
BOOTDEV=/dev/block/by-name/boot

choose() {   # 0 = VOL+, 1 = VOL-
  while true; do
    /system/bin/getevent -lc 1 2>&1 | /system/bin/grep VOLUME | /system/bin/grep " DOWN" > "$TMPDIR/evt"
    /system/bin/grep -q VOLUMEUP   "$TMPDIR/evt" && return 0
    /system/bin/grep -q VOLUMEDOWN "$TMPDIR/evt" && return 1
  done
}
ask() { ui_print " "; ui_print "  $1"; ui_print "    VOL+ = yes    VOL- = no"; choose; }

kernel_is_capable() {
  [ -e /proc/self/ns/user ] && [ -e /proc/self/ns/pid ] && [ -e /proc/self/ns/ipc ] &&
  grep -qE '^pids[[:space:]]'    /proc/cgroups 2>/dev/null &&
  grep -qE '^devices[[:space:]]' /proc/cgroups 2>/dev/null &&
  grep -qw overlay /proc/filesystems 2>/dev/null
}

ui_print " "
ui_print "  Docker for Android - $(grep_prop version "$MODPATH/module.prop")"
ui_print "  =========================================="

# --- device guard -----------------------------------------------------------
DEV=$(getprop ro.product.device)
ui_print "  device: $DEV"
case "$DEV" in
  raphael|raphaelin) ;;
  *) ui_print " "
     ui_print "  This kernel is built for Xiaomi raphael"
     ui_print "  (Redmi K20 Pro / Mi 9T Pro). Yours is '$DEV'."
     abort "  Aborted - flashing it would not boot." ;;
esac

# A/B devices need slot handling this installer does not implement.
[ -z "$(getprop ro.boot.slot_suffix)" ] || abort "  A/B slot device - not supported by this installer."

MB=/data/adb/ksu/bin/magiskboot
[ -x "$MB" ] || MB=/data/adb/magisk/magiskboot
[ -x "$MB" ] || abort "  magiskboot not found (need KernelSU or Magisk)."

mkdir -p "$STATE"

# --- kernel -----------------------------------------------------------------
if kernel_is_capable; then
  ui_print "  kernel: already container-capable - skipping kernel flash"
else
  ui_print "  kernel: current kernel cannot run containers"
  if ask "Patch your boot image with the Docker kernel?"; then
    W="$TMPDIR/bootwork"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || abort "  tmp failed"

    ui_print "    reading current boot partition..."
    dd if="$BOOTDEV" of="$W/orig.img" bs=1048576 2>/dev/null || abort "  could not read boot"
    [ -s "$W/orig.img" ] || abort "  boot image read was empty"

    BK="$STATE/boot-backup-$(date +%Y%m%d-%H%M%S).img"
    cp "$W/orig.img" "$BK"
    ui_print "    backup saved: $BK"

    ui_print "    unpacking..."
    "$MB" unpack "$W/orig.img" >/dev/null 2>&1 || abort "  magiskboot unpack failed"

    cp -f "$MODPATH/kernel/Image.gz" "$W/kernel" || abort "  kernel missing from zip"

    ui_print "    repacking (your ramdisk, dtb and patch level are kept)..."
    "$MB" repack "$W/orig.img" "$W/new.img" >/dev/null 2>&1 || abort "  magiskboot repack failed"
    [ -s "$W/new.img" ] || abort "  repack produced an empty image"

    # Verify BEFORE writing. magiskboot stores the kernel decompressed and
    # re-applies KERNEL_FMT on repack; it detects an already-gzipped input and
    # does not double-compress, but that must be confirmed, not assumed -- a
    # double-compressed kernel is an unbootable brick.
    V="$W/verify"; mkdir -p "$V"; cd "$V"
    cp "$W/new.img" . || abort "  verify: copy failed"
    "$MB" unpack new.img >/dev/null 2>&1 || abort "  verify: repacked image is unreadable"
    # arm64 Image carries "ARMd" at offset 56. Its absence means the kernel got
    # mangled (double-compressed, truncated, or replaced by the wrong file).
    MAGIC=$(dd if=kernel bs=1 skip=56 count=4 2>/dev/null)
    [ "$MAGIC" = "ARMd" ] || abort "  verify: kernel is not a valid arm64 Image - NOT flashing"
    ui_print "    verified: arm64 kernel intact, ramdisk and dtb untouched"
    cd "$W"

    ui_print "    writing to $BOOTDEV ..."
    dd if="$W/new.img" of="$BOOTDEV" bs=1048576 2>/dev/null || abort "  WRITE FAILED - restore with: dd if=$BK of=$BOOTDEV"
    sync
    ui_print "    kernel installed"
    NEED_REBOOT=1
  else
    ui_print "    skipped - Docker will not work until the kernel is replaced"
    NEED_REBOOT=0
  fi
fi

# --- userspace --------------------------------------------------------------
cp -f "$MODPATH/common/"* "$STATE/"
chmod 755 "$STATE"/*
set_perm_recursive "$MODPATH" 0 0 0755 0755
ui_print "  tools installed: dockerctl"

if ask "Start Docker automatically at every boot?"; then
  touch "$STATE/autostart";  ui_print "    autostart ON"
else
  rm -f "$STATE/autostart"; ui_print "    autostart OFF"
fi

# Only offer the download when the kernel is ALREADY live. Running it now on a
# freshly patched boot image would install against the old kernel and fail in
# confusing ways.
if kernel_is_capable; then
  if ask "Download Debian and install Docker now? (~550 MB, several minutes)"; then
    ui_print "  ------------------------------------------"
    sh "$STATE/dockerctl" setup 2>&1 | while read -r l; do ui_print "  $l"; done
  else
    ui_print "    skipped"
  fi
fi

ui_print " "
ui_print "  =========================================="
if [ "${NEED_REBOOT:-0}" = 1 ]; then
  ui_print "  REBOOT, then run:"
  ui_print "    su -c 'dockerctl setup'      # one-time"
else
  ui_print "  Next:"
fi
ui_print "    su -c 'dockerctl start'"
ui_print "    su -c 'dockerctl ui start'   # web UI on :9000"
ui_print "    su -c 'dockerctl ui admin YOUR-PASSWORD'"
ui_print " "
ui_print "  Diagnose anything with:  dockerctl doctor --fix"
ui_print " "
