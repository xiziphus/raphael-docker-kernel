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

PH_ON_F="$STATE/phone.alerts"          # exists = relay call notifications

phone_alerts_on() { [ -f "$PH_ON_F" ]; }

phone_set() {
    case "${1:-}" in
        on)  touch "$PH_ON_F"; ok "ring alerts ON" ;;
        off) rm -f "$PH_ON_F"; ok "ring alerts OFF" ;;
        *)   return 1 ;;
    esac
}

# Live call state. NOT telephony.registry: mCallState there stayed 0 across
# three real incoming calls and every precise field read -1. That is the legacy
# telephony state, which modern Android no longer drives now that calls run
# through the telecom stack and ConnectionService. dumpsys telecom does carry
# it -- CallAudioModeStateMachine logs a timestamped "Enter RINGING" per call.
phone_state() {
    last=$(dumpsys telecom 2>/dev/null \
           | sed -n 's/.* - Enter \([A-Z_]*\)$/\1/p' | tail -1)
    case "$last" in
        RINGING)              echo ringing ;;
        CALL|VOIP|TONE_HOLD)  echo incall ;;
        UNFOCUSED|'')         echo idle ;;
        *)                    echo "$last" ;;
    esac
}

# KEYCODE_CALL (5) answers; KEYCODE_ENDCALL (6) rejects a ringing call and hangs
# up an active one. `cmd telecom` has no answer or reject verb -- checked.
phone_answer() { input keyevent 5 && ok "answered"; }
phone_reject() { input keyevent 6 && ok "rejected / hung up"; }

phone_status() {
    phone_alerts_on && ok "ring alerts enabled" || bad "ring alerts disabled"
    st=$(phone_state)
    case "$st" in
        idle)    ok "idle" ;;
        ringing) warn "RINGING now" ;;
        incall)  ok "in a call" ;;
        *)       bad "call state unavailable" ;;
    esac
    say "  alerts come from the call packages' own notifications (Truecaller,"
    say "  dialer) -- they resolve names that contacts lookup cannot."
}
