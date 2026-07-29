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

choose() {   # 0 = VOL+, 1 = VOL-, and 1 (no) if nobody answers
  # Bounded, because getevent blocks forever. An unanswered prompt used to hang
  # the installer indefinitely -- fine when you are holding the phone, useless
  # when the screen is off or the install was kicked off over adb. Defaulting to
  # NO on timeout is the safe direction: every prompt here is opt-in, so silence
  # declines rather than flashes anything.
  while true; do
    timeout 120 getevent -lc 1 2>&1 | grep VOLUME | grep " DOWN" > "$TMPDIR/evt" || {
      ui_print "    no answer in 120s - assuming NO"; return 1; }
    grep -q VOLUMEUP   "$TMPDIR/evt" && return 0
    grep -q VOLUMEDOWN "$TMPDIR/evt" && return 1
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

# --- Android version guard --------------------------------------------------
# This kernel is built from the ROM tree's 16.2 branch. The same tree carries a
# separate 17.0 branch because the kernel genuinely differs between releases,
# and Android's userspace expectations move with it -- netbpfload alone gates on
# the API level and demands eBPF features accordingly. Installing an A16 kernel
# under an A17 userspace is a plausible bootloop, so make it a deliberate act
# rather than a surprise.
SDK=$(getprop ro.build.version.sdk)
REL=$(getprop ro.build.version.release)
ui_print "  android: $REL (sdk $SDK)"
if [ "$SDK" != "36" ]; then
  ui_print " "
  ui_print "  !! This build targets Android 16 (sdk 36). You are on sdk $SDK."
  ui_print "  !! Expect a bootloop. Build from the tree's 17.0 branch instead"
  ui_print "  !! if you are on Android 17 - see docs/BUILDING.md."
  if ask "Continue anyway? You have a boot backup either way."; then
    ui_print "    continuing at your own risk"
  else
    abort "  Aborted."
  fi
fi

MB=/data/adb/ksu/bin/magiskboot
[ -x "$MB" ] || MB=/data/adb/magisk/magiskboot
[ -x "$MB" ] || abort "  magiskboot not found (need KernelSU or Magisk)."

# --- payload integrity ------------------------------------------------------
# A zip can unpack cleanly and still hold a truncated Image.gz -- an interrupted
# download is the ordinary way that happens. Flashing one is a brick, so verify
# before anything else touches the boot partition.
EXPECT="$MODPATH/kernel/Image.gz.sha256"
if [ -f "$EXPECT" ]; then
  WANT=$(cat "$EXPECT")
  GOT=$(sha256sum "$MODPATH/kernel/Image.gz" 2>/dev/null | cut -d" " -f1)
  if [ -z "$GOT" ]; then
    ui_print "  [warn] could not hash the payload; skipping integrity check"
  elif [ "$WANT" != "$GOT" ]; then
    ui_print "  expected $WANT"
    ui_print "  got      $GOT"
    abort "  PAYLOAD CORRUPT - download the zip again. Nothing was changed."
  else
    ui_print "  payload: sha256 verified"
  fi
else
  ui_print "  [warn] no payload hash in this zip; integrity unverified"
fi

mkdir -p "$STATE"

# --- kernel -----------------------------------------------------------------
if kernel_is_capable; then
  ui_print "  kernel: already container-capable - skipping kernel flash"
else
  ui_print "  kernel: current kernel cannot run containers"
  if ask "Patch your boot image with the Docker kernel?"; then
    # Losing power part-way through writing the boot partition leaves an
    # unbootable device, so refuse on a low battery unless it is charging.
    BATT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 100)
    CHG=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo Unknown)
    ui_print "    battery: ${BATT}% ($CHG)"
    case "$CHG" in
      Charging|Full) ;;
      *) [ "$BATT" -ge 20 ] || abort "  battery below 20% and not charging - refusing to flash." ;;
    esac

    # The work needs room for a copy of the boot image plus the repacked one,
    # and the backup is kept on /data. Running out mid-write is the same failure
    # as losing power.
    PARTSZ=$(blockdev --getsize64 "$BOOTDEV" 2>/dev/null || echo 67108864)
    NEEDKB=$(( (PARTSZ * 3) / 1024 ))
    FREEKB=$(df /data 2>/dev/null | tail -1 | awk "{print \$4}")
    if [ -n "$FREEKB" ] && [ "$FREEKB" -lt "$NEEDKB" ]; then
      abort "  not enough free space on /data (need ~$((NEEDKB/1024))MB, have $((FREEKB/1024))MB)."
    fi

    W="$TMPDIR/bootwork"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || abort "  tmp failed"

    ui_print "    reading current boot partition..."
    dd if="$BOOTDEV" of="$W/orig.img" bs=1048576 2>/dev/null || abort "  could not read boot"
    [ -s "$W/orig.img" ] || abort "  boot image read was empty"
    # A boot image must start with the Android magic. If it does not, this is
    # not the partition we think it is and unpacking would produce nonsense.
    head -c 8 "$W/orig.img" | grep -q "ANDROID!" || abort "  $BOOTDEV is not an Android boot image."

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

    NEWSZ=$(stat -c %s "$W/new.img" 2>/dev/null || echo 0)
    if [ "$NEWSZ" -gt "$PARTSZ" ]; then
      abort "  repacked image ($NEWSZ) exceeds the boot partition ($PARTSZ) - NOT flashing."
    fi

    ui_print "    writing to $BOOTDEV ..."
    dd if="$W/new.img" of="$BOOTDEV" bs=1048576 2>/dev/null || abort "  WRITE FAILED - restore with: dd if=$BK of=$BOOTDEV"
    sync

    # Read the partition back and compare. dd can report success while the
    # write is short or silently corrupted, and finding that out at the next
    # boot is far too late.
    ui_print "    verifying the write..."
    dd if="$BOOTDEV" of="$W/back.img" bs=1048576 count=$(( (NEWSZ + 1048575) / 1048576 )) 2>/dev/null
    WH=$(sha256sum "$W/new.img"  2>/dev/null | cut -d" " -f1)
    RH=$(dd if="$W/back.img" bs=1 count="$NEWSZ" 2>/dev/null | sha256sum 2>/dev/null | cut -d" " -f1)
    if [ -n "$WH" ] && [ -n "$RH" ] && [ "$WH" != "$RH" ]; then
      ui_print "  !! readback MISMATCH - restoring your backup"
      dd if="$BK" of="$BOOTDEV" bs=1048576 2>/dev/null; sync
      abort "  write did not verify; your original kernel has been restored."
    fi
    ui_print "    write verified"
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
# The WebUI lives in the module directory; KernelSU detects webroot/ on its own
# and shows an open-in-browser button, no module.prop flag required.
[ -d "$MODPATH/webroot" ] && set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
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
