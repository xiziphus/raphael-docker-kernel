#!/system/bin/sh
##########################################################################
# Runs as root when you tap ACTION on this module in the KernelSU manager.
#
# This exists so the whole thing is usable WITHOUT a shell. Every dockerctl
# instruction needs root, and root means either granting your terminal app in
# the manager or using adb -- neither of which is obvious, and both of which
# fail with a bare "su: inaccessible or not found" that explains nothing.
# Tapping a button needs no grant at all.
##########################################################################
D=/data/adb/docker
. "$D/lib.sh"; . "$D/mount.sh"; . "$D/net.sh"; . "$D/daemon.sh"
. "$D/ui.sh"; . "$D/setup.sh"; . "$D/doctor.sh"

T="${TMPDIR:-/data/local/tmp}"
choose() {   # 0 = VOL+, 1 = VOL-, and 1 (no) if nobody answers
  # Bounded, because getevent blocks forever. An unanswered prompt used to hang
  # the installer indefinitely -- fine when you are holding the phone, useless
  # when the screen is off or the install was kicked off over adb. Defaulting to
  # NO on timeout is the safe direction: every prompt here is opt-in, so silence
  # declines rather than flashes anything.
  while true; do
    timeout 120 getevent -lc 1 2>&1 | grep VOLUME | grep " DOWN" > "$TMPDIR/evt" || {
      echo "    no answer in 120s - assuming NO"; return 1; }
    grep -q VOLUMEUP   "$TMPDIR/evt" && return 0
    grep -q VOLUMEDOWN "$TMPDIR/evt" && return 1
  done
}
ask() { echo ""; echo "  $1"; echo "    VOL+ = yes    VOL- = no"; choose; }

echo "  Docker for Android"
echo "  =================================="
kernel_ok=1
for ns in user pid ipc; do [ -e "/proc/self/ns/$ns" ] || kernel_ok=0; done
grep -qE '^pids[[:space:]]' /proc/cgroups 2>/dev/null || kernel_ok=0

if [ "$kernel_ok" = 0 ]; then
  echo "  [FAIL] this kernel cannot run containers."
  echo "         Reinstall the module to patch your boot image, then reboot."
  exit 1
fi
echo "  [ok]   kernel is container-capable"

if ! have_rootfs; then
  echo "  [--]   Debian not installed yet"
  if ask "Download Debian and install Docker now? (~550 MB)"; then do_setup; fi
  exit 0
fi
echo "  [ok]   rootfs present"

if running; then
  echo "  [ok]   dockerd running"
  in_chroot 'docker ps --format "  {{.Names}}  {{.Status}}"' 2>/dev/null
  if ask "Open the web UI in your browser?"; then
    ui_start; am start -a android.intent.action.VIEW -d http://127.0.0.1:9000 >/dev/null 2>&1
  elif ask "Stop Docker?"; then
    daemon_stop
  fi
else
  echo "  [--]   dockerd stopped"
  if ask "Start Docker now?"; then
    daemon_start
    ask "Start the web UI too?" && ui_start
  fi
fi

ask "Run a full check and repair anything broken?" && do_doctor --fix
echo ""
echo "  done."
