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

WAKE_TAG=docker
WAKE_LOCK=/sys/power/wake_lock
WAKE_UNLOCK=/sys/power/wake_unlock
WAKE_MODE_F="$STATE/wake"        # contains off | auto | always
WAKE_LIST_F="$STATE/wake.list"   # one container name per line

wake_supported() { [ -w "$WAKE_LOCK" ] && [ -w "$WAKE_UNLOCK" ]; }

wake_mode() {
    m=$(cat "$WAKE_MODE_F" 2>/dev/null)
    case "$m" in off|auto|always) echo "$m" ;; *) echo off ;; esac
}

# The kernel lists every held tag in this file, ours among others', so match
# the word rather than testing for a non-empty file.
wake_held() {
    grep -qw "$WAKE_TAG" "$WAKE_LOCK" 2>/dev/null
}

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

# Reconcile kernel state to the configured mode. Safe to call repeatedly.
wake_sync() {
    wake_supported || return 1
    if wake_should_hold; then wake_acquire; else wake_release; fi
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
    wake_held && ok "wakelock HELD - device will not suspend" \
              || warn "wakelock not held - device may suspend"
    n=$(wake_list | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && { say "  watching $n container(s):"; wake_list | sed 's/^/    /'; }
    return 0
}
