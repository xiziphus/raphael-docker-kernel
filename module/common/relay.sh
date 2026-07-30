#!/system/bin/sh
##########################################################################
# relay.sh - emit new SMS and app notifications, once each, as TSV.
#
# No companion app and no notification-listener permission: with root both
# sources are already readable.
#
#   SMS            content://sms/inbox, cursored on the monotonic _id
#   notifications  dumpsys notification --noredact, deduplicated by content
#
# Output is one record per line, tab separated, safe to pipe over ssh:
#
#   sms<TAB>+911234567890<TAB><TAB>message text
#   app<TAB>com.whatsapp<TAB>Alice<TAB>message text
#
# The consumer is expected to be a poller (see tools/mac-notify-relay.sh).
# Polling rather than pushing because the phone cannot reliably reach the Mac
# -- its address moves too -- while the Mac already has authenticated ssh in.
##########################################################################

RELAY_SMS_CUR="$STATE/relay.sms"     # highest _id already emitted
RELAY_SEEN="$STATE/relay.seen"       # content hashes already emitted
RELAY_SEEN_MAX=400

# --------------------------------------------------------------------- SMS
#
# Cursor on _id, which is monotonic per row, rather than on date: a phone that
# has been offline receives several messages with the same delivery timestamp,
# and a date cursor drops all but one.
relay_sms() {
    last=$(cat "$RELAY_SMS_CUR" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac

    out=$(content query --uri content://sms/inbox \
            --projection _id:address:body \
            --where "_id>$last" --sort "_id ASC" 2>/dev/null)

    # First run: do not dump the entire inbox as notifications. Record the high
    # water mark and start reporting from the next message.
    if [ "$last" = 0 ]; then
        printf '%s\n' "$out" | sed -n 's/^Row: [0-9]* _id=\([0-9]*\).*/\1/p' \
            | sort -n | tail -1 > "$RELAY_SMS_CUR"
        return 0
    fi

    printf '%s\n' "$out" | while IFS= read -r line; do
        case "$line" in Row:*) ;; *) continue ;; esac
        id=$(printf '%s' "$line"   | sed -n 's/^Row: [0-9]* _id=\([0-9]*\),.*/\1/p')
        [ -n "$id" ] || continue
        # Field-anchored, not comma-split: message bodies contain commas.
        addr=$(printf '%s' "$line" | sed -n 's/.*, address=\(.*\), body=.*/\1/p')
        body=$(printf '%s' "$line" | sed -n 's/.*, body=\(.*\)$/\1/p' | tr '\n\t' '  ')
        printf 'sms\t%s\t\t%s\n' "${addr:-unknown}" "$body"
        printf '%s\n' "$id" > "$RELAY_SMS_CUR"
    done
}

# ----------------------------------------------------------- notifications
#
# Ongoing and foreground-service notifications are excluded. They are status
# displays -- the music player, the VPN, "USB debugging connected" -- that sit
# in the shade for hours and are not events. Relaying them means the Mac
# re-announces the same thing every poll, or announces it once and calls a
# permanent fixture "incoming".
relay_apps() {
    dumpsys notification --noredact 2>/dev/null | awk -F'\t' '
        /NotificationRecord\(/ {
            emit()
            pkg=""; title=""; text=""; skip=0
            if (match($0, /pkg=[a-zA-Z0-9._]+/))
                pkg=substr($0, RSTART+4, RLENGTH-4)
            if ($0 ~ /ONGOING_EVENT|FOREGROUND_SERVICE|GROUP_SUMMARY/) skip=1
            next
        }
        /android\.title=String \(/ {
            title=$0; sub(/.*android\.title=String \(/, "", title); sub(/\)[[:space:]]*$/, "", title)
            next
        }
        /android\.text=String \(/ {
            text=$0; sub(/.*android\.text=String \(/, "", text); sub(/\)[[:space:]]*$/, "", text)
            next
        }
        END { emit() }
        function emit() {
            if (pkg == "" || skip) return
            if (title == "" && text == "") return
            printf "app\t%s\t%s\t%s\n", pkg, title, text
        }
    ' | while IFS= read -r rec; do
        # Never relay our own notifications; that is a feedback loop.
        case "$rec" in *"raphael-"*) continue ;; esac
        h=$(printf '%s' "$rec" | cksum | tr -d ' ')
        grep -qx -- "$h" "$RELAY_SEEN" 2>/dev/null && continue
        printf '%s\n' "$h" >> "$RELAY_SEEN"
        printf '%s\n' "$rec"
    done

    # Bound the dedup file, keeping the most recent entries.
    if [ -f "$RELAY_SEEN" ] && [ "$(wc -l < "$RELAY_SEEN")" -gt "$RELAY_SEEN_MAX" ]; then
        tail -n "$RELAY_SEEN_MAX" "$RELAY_SEEN" > "$RELAY_SEEN.tmp"
        mv -f "$RELAY_SEEN.tmp" "$RELAY_SEEN"
    fi
}

relay_new() { relay_sms; relay_apps; }

relay_reset() {
    rm -f "$RELAY_SMS_CUR" "$RELAY_SEEN"
    relay_new >/dev/null 2>&1     # re-establish the high water mark silently
    ok "relay cursors reset"
}
