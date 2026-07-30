#!/system/bin/sh
##########################################################################
# wake.sh - stop Android suspending the device out from under Docker.
#
# Android autosleeps aggressively whenever nothing holds a wakelock, and a
# container is not something it knows to care about. Measured on raphael while
# a kernel build was running: 75 suspend/resume cycles in 30 seconds -- 2.5 per
# second. Everything long-running is affected, not just builds: the scheduler
# misses ticks, queue workers stall, and an SSH session over the tunnel drops
# with "closed by remote host" when cloudflared freezes mid-stream.
#
# The fix is the kernel's userspace wakelock interface. Writing a tag to
# /sys/power/wake_lock blocks suspend until the same tag is written to
# /sys/power/wake_unlock. The file is mode 660 system:AID_BLOCK_SUSPEND, so
# this needs root -- which is what we are.
#
# Locks are global and NOT nested: writing the tag twice is the same as once.
# So the state here is a mode, not a counter, and wake_sync() reconciles the
# kernel to it.
#
# Modes:
#   off     never hold it. Normal Android battery behaviour.
#   auto    hold it only while a container in wake.list is running. The point
#           of per-container: a phone that stays awake for a scratch container
#           you forgot to remove is worse than one that sleeps.
#   always  hold it unconditionally, even with Docker stopped.
##########################################################################

WAKE_TAG=docker                  # workload lock, driven by mode + watch list
WAKE_TAG_LIFE=docker-lifeline    # remote-access lock, held independently
WAKE_LOCK=/sys/power/wake_lock
WAKE_UNLOCK=/sys/power/wake_unlock
WAKE_MODE_F="$STATE/wake"        # contains off | auto | always
WAKE_LIST_F="$STATE/wake.list"   # one container name per line
WAKE_NOFLOOR_F="$STATE/wake.nofloor"   # exists = opt out of the lifeline lock

wake_supported() { [ -w "$WAKE_LOCK" ] && [ -w "$WAKE_UNLOCK" ]; }

wake_mode() {
    m=$(cat "$WAKE_MODE_F" 2>/dev/null)
    case "$m" in off|auto|always) echo "$m" ;; *) echo off ;; esac
}

# The kernel lists every held tag in this file, space separated, ours among
# others'. Split on whitespace and match a WHOLE token: `grep -w docker` also
# matches "docker-lifeline", because '-' counts as a word boundary. That made
# wake_acquire believe the workload lock was already held whenever only the
# lifeline was, so it silently never took it.
wake_tag_held() {
    tr ' \t' '\n\n' < "$WAKE_LOCK" 2>/dev/null | grep -qx -- "$1"
}
wake_held() { wake_tag_held "$WAKE_TAG"; }

wake_acquire() {
    wake_supported || return 1
    wake_held && return 0
    echo "$WAKE_TAG" > "$WAKE_LOCK" 2>/dev/null
}

wake_release() {
    wake_supported || return 1
    wake_held || return 0
    echo "$WAKE_TAG" > "$WAKE_UNLOCK" 2>/dev/null
}

wake_list() { [ -f "$WAKE_LIST_F" ] && grep -v '^[[:space:]]*$' "$WAKE_LIST_F" 2>/dev/null; }

wake_watching() { wake_list | grep -qx -- "$1"; }

wake_add() {
    [ -n "${1:-}" ] || return 1
    wake_watching "$1" || echo "$1" >> "$WAKE_LIST_F"
}

wake_rm() {
    [ -n "${1:-}" ] || return 1
    [ -f "$WAKE_LIST_F" ] || return 0
    grep -vx -- "$1" "$WAKE_LIST_F" > "$WAKE_LIST_F.tmp" 2>/dev/null
    mv -f "$WAKE_LIST_F.tmp" "$WAKE_LIST_F"
}

# Any watched container currently up? One `docker ps` for the whole list --
# this runs from the boot loop every 60s, and in_chroot_exec is not cheap.
#
# `for` over word-split output rather than `while read` down a pipe: the pipe
# puts the loop in a subshell, where an early exit sets the SUBSHELL's status
# and the caller has to reconstruct it. Container names cannot contain
# whitespace, so word splitting is safe here and the control flow stays plain.
wake_any_running() {
    wake_list | grep -q . || return 1
    running || return 1
    up=$(in_chroot_exec docker ps --format '{{.Names}}' 2>/dev/null) || return 1
    for n in $(wake_list); do
        echo "$up" | grep -qx -- "$n" && return 0
    done
    return 1
}

wake_should_hold() {
    case "$(wake_mode)" in
        always) return 0 ;;
        auto)   wake_any_running ;;
        *)      return 1 ;;
    esac
}

# ------------------------------------------------------------- the floor
#
# Learned the hard way. `auto` was watching exactly one container; that
# container finished and was auto-removed, so the lock was correctly released,
# the device went back to suspending ~2.5x/second, Wi-Fi dropped, cloudflared
# could not hold its edge connection, and the phone became unreachable by
# tunnel AND by adb. Recovering it needed physically walking to the device.
#
# So remote access gets its OWN lock, on a separate tag, that does not depend
# on any container being up. Kernel locks are per-tag, so releasing the
# workload lock can never take this one with it.
#
# The rule: if a way back in is supposed to exist, stay awake enough to serve
# it. Opt out with `dockerctl wake floor off` if you really want the device to
# sleep with sshd enabled.
wake_floor_wanted() {
    [ -f "$WAKE_NOFLOOR_F" ] && return 1
    [ -f "$STATE/sshd" ] && return 0             # a way in is configured
    tunnel_running 2>/dev/null && return 0       # or one is actually serving
    return 1
}

wake_floor_held() { wake_tag_held "$WAKE_TAG_LIFE"; }

wake_floor_sync() {
    wake_supported || return 1
    if wake_floor_wanted; then
        wake_floor_held || echo "$WAKE_TAG_LIFE" > "$WAKE_LOCK" 2>/dev/null
    else
        wake_floor_held && echo "$WAKE_TAG_LIFE" > "$WAKE_UNLOCK" 2>/dev/null
    fi
}

# Reconcile kernel state to the configured mode. Safe to call repeatedly.
wake_sync() {
    wake_supported || return 1
    if wake_should_hold; then wake_acquire; else wake_release; fi
    wake_floor_sync
}

wake_set() {
    case "${1:-}" in
        off|auto|always) echo "$1" > "$WAKE_MODE_F" ;;
        *) return 1 ;;
    esac
    wake_sync
}

wake_status() {
    if ! wake_supported; then
        bad "wakelock unsupported (no writable $WAKE_LOCK)"
        return 1
    fi
    say "  mode: $(wake_mode)"
    wake_held && ok "workload lock HELD" || warn "workload lock not held"
    if [ -f "$WAKE_NOFLOOR_F" ]; then
        warn "lifeline floor DISABLED - remote access can be suspended away"
    else
        wake_floor_held && ok "lifeline lock HELD (remote access stays reachable)" \
                        || say "  lifeline: not needed (no sshd, no tunnel)"
    fi
    if wake_held || wake_floor_held; then ok "device will NOT suspend"
    else warn "device may suspend"; fi
    n=$(wake_list | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && { say "  watching $n container(s):"; wake_list | sed 's/^/    /'; }
    return 0
}
