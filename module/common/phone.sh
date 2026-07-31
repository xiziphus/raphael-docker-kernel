#!/system/bin/sh
# phone.sh - incoming-call detection and control.  . lib.sh first.
#
# Android exposes call state through dumpsys telephony.registry:
#   mCallState 0=idle 1=ringing 2=offhook
# and the ringing number through mCallIncomingNumber.
#
# WHY NOT JUST READ THE DIALER'S NOTIFICATION: an in-progress call notification
# is ONGOING/FOREGROUND_SERVICE, and relay.sh filters those out on purpose --
# they are fixtures, not events, and relaying them re-announces the same thing
# every poll. That filter is why only "Missed call" ever reached the desktop and
# never the ring itself. Reading call state directly gives an edge, not a state.

PH_STATE_F="$STATE/phone.callstate"    # last state we emitted for
PH_NUM_F="$STATE/phone.callnum"
PH_ON_F="$STATE/phone.alerts"          # exists = emit ring alerts

phone_alerts_on() { [ -f "$PH_ON_F" ]; }

phone_state() {
    dumpsys telephony.registry 2>/dev/null \
      | sed -n 's/.*mCallState=\([0-9]\).*/\1/p' | head -1
}

phone_number() {
    dumpsys telephony.registry 2>/dev/null \
      | sed -n 's/.*mCallIncomingNumber=\([^ ,]*\).*/\1/p' | head -1
}

# Resolve a number to a name. Two sources, because neither is reliable alone:
#   phone_lookup  - authoritative, but empty for anyone not in contacts
#   call_log.name - Android's own cached label, which also covers numbers that
#                   were named by the dialer's caller-ID rather than by contacts
# Falls back to the number, and finally to "Unknown" for a withheld caller.
# `content query` ignores --projection on some providers and returns the whole
# row, so a greedy match on "name=(.*)" swallows the following columns and you
# get "Anurag Kumar, number=+91-...". Cut at the first ", key=" that follows.
_col() { sed -n "s/^Row: 0 .*$1=//p" | sed 's/, [a-zA-Z_]*=.*$//' | head -1; }

phone_name() {
    n="${1:-}"
    [ -n "$n" ] || { echo "Unknown"; return; }
    nm=$(content query --uri "content://com.android.contacts/phone_lookup/$n" \
           --projection display_name 2>/dev/null | _col display_name)
    [ -n "$nm" ] && [ "$nm" != null ] && { echo "$nm"; return; }
    nm=$(content query --uri content://call_log/calls --projection name \
           --where "number='$n'" --sort "date DESC" 2>/dev/null | _col name)
    case "$nm" in ''|null) echo "$n" ;; *) echo "$nm" ;; esac
}

# Emit one record per RING EDGE. Called from relay_new, so it rides the poll
# the desktop already makes -- no second cursor, no second consumer.
phone_calls() {
    phone_alerts_on || return 0
    st=$(phone_state); [ -n "$st" ] || return 0
    last=$(cat "$PH_STATE_F" 2>/dev/null)
    echo "$st" > "$PH_STATE_F"
    [ "$st" = "$last" ] && return 0          # no transition, nothing to say

    if [ "$st" = 1 ]; then                   # idle/offhook -> RINGING
        num=$(phone_number)
        echo "$num" > "$PH_NUM_F"
        printf 'call\037%s\037%s\037ringing\n' "${num:-unknown}" "$(phone_name "$num")"
    elif [ "$last" = 1 ] && [ "$st" = 0 ]; then   # RINGING -> idle = unanswered
        num=$(cat "$PH_NUM_F" 2>/dev/null)
        printf 'call\037%s\037%s\037missed\n' "${num:-unknown}" "$(phone_name "$num")"
    fi
}

# KEYCODE_CALL (5) answers; KEYCODE_ENDCALL (6) rejects a ringing call and hangs
# up an active one. `cmd telecom` has no answer/reject verb -- checked.
phone_answer() { input keyevent 5 && ok "answered"; }
phone_reject() { input keyevent 6 && ok "rejected / hung up"; }

phone_set() {
    case "${1:-}" in
        on)  touch "$PH_ON_F"; phone_state > "$PH_STATE_F" 2>/dev/null
             ok "ring alerts ON" ;;
        off) rm -f "$PH_ON_F"; ok "ring alerts OFF" ;;
        *)   return 1 ;;
    esac
}

phone_status() {
    phone_alerts_on && ok "ring alerts enabled" || bad "ring alerts disabled"
    st=$(phone_state)
    case "${st:-}" in
        0) ok "idle" ;;
        1) num=$(phone_number); ok "RINGING from $(phone_name "$num") (${num:-withheld})" ;;
        2) ok "in a call" ;;
        *) bad "call state unavailable" ;;
    esac
}
