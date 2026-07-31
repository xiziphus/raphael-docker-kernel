#!/bin/bash
# mac-notify-relay - mirror the phone's SMS and app notifications onto macOS.
#
# Polls `dockerctl relay new` over ssh and posts each record as a native macOS
# notification. Nothing is installed on the phone beyond the module, and no
# notification-listener permission is granted to anything: with root, both the
# SMS provider and dumpsys are already readable.
#
#   ./mac-notify-relay.sh              poll forever
#   ./mac-notify-relay.sh --once       one pass, for testing
#
# Install as a login agent with --install (launchd, keeps running, restarts).

set -u
LAN_HOST=${LAN_HOST:-raphael-lan}     # tried first: fast, no Cloudflare hop
WAN_HOST=${WAN_HOST:-raphael}         # fallback: works off-network
INTERVAL=${INTERVAL:-10}
# Audible by default. If terminal-notifier's alert style is None -- which is
# how macOS registers a CLI tool that has never been configured -- notifications
# land silently in Notification Centre and never appear on screen, which looks
# exactly like the relay being broken. A sound makes delivery observable
# regardless. Set NOTIFY_SOUND= to silence.
NOTIFY_SOUND=${NOTIFY_SOUND-Ping}
LABEL=win.stratifyx.raphael.notify
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# Prefer terminal-notifier. `osascript ... display notification` is posted on
# behalf of Script Editor, so it is governed by Script Editor's notification
# permission -- and when that is off the call still returns 0 and displays
# NOTHING. Silent success is the worst possible failure here: the relay looks
# healthy, the cursor advances, and no notification ever appears.
# terminal-notifier ships its own bundle id, so it shows up in System Settings
# under its own name and can be allowed explicitly.
#
# In both cases the text goes as argv rather than interpolated into a script:
# message bodies contain quotes and apostrophes, and AppleScript escaping is
# its own small nightmare.
# Resolved by absolute path, not just $PATH. launchd gives an agent
# /usr/bin:/bin:/usr/sbin:/sbin and nothing else, so a Homebrew binary in
# /usr/local/bin or /opt/homebrew/bin is invisible to it. This bit us exactly
# once: the agent ran, polled, consumed the messages and advanced the cursor,
# found no terminal-notifier, fell back to osascript, and dropped every
# notification silently.
NOTIFIER=$(command -v terminal-notifier 2>/dev/null || true)
for c in /usr/local/bin/terminal-notifier /opt/homebrew/bin/terminal-notifier; do
    [ -n "$NOTIFIER" ] && break
    [ -x "$c" ] && NOTIFIER=$c
done

notify() {  # notify <title> <subtitle> <body>
    # Logged so a silent drop is diagnosable after the fact. Both backends
    # return 0 whether or not anything is displayed, so the log is the only
    # record of which path was taken.
    #
    # The BODY IS NEVER LOGGED. These are SMS: a single backlog replay after an
    # outage wrote live bank OTPs and account balances into a world-readable
    # file under /tmp. The log answers "did delivery work", which needs the
    # sender and a length -- not the text. Anything that reads logs later
    # (a backup, a crash report, a support bundle) would otherwise carry them.
    printf '%s  notify via %s: %s | %s chars\n' "$(date '+%H:%M:%S')" \
        "${NOTIFIER:-osascript}" "$1" "${#3}"
    if [ -n "$NOTIFIER" ]; then
        # NO -group. In terminal-notifier a group shows only ONE notification
        # at a time: each post REPLACES the previous one with the same group.
        # A burst of messages therefore collapsed into a single banner that was
        # overwritten faster than it could render, so nothing was seen.
        "$NOTIFIER" -title "$1" -subtitle "$2" -message "$3" \
                    ${NOTIFY_SOUND:+-sound "$NOTIFY_SOUND"} >/dev/null 2>&1
        # Bursts also get coalesced by Notification Centre itself; a small gap
        # keeps separate messages separate.
        sleep 0.4
    else
        osascript -e 'on run argv
            display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
        end run' "$1" "$2" "$3" >/dev/null 2>&1
    fi
}

reachable() { ssh -o ConnectTimeout=6 -o BatchMode=yes "$1" true >/dev/null 2>&1; }

pick_host() {
    reachable "$LAN_HOST" && { echo "$LAN_HOST"; return 0; }
    reachable "$WAN_HOST" && { echo "$WAN_HOST"; return 0; }
    return 1
}

# dockerctl lives on the Android side, not in the chroot the ssh session lands
# in, so it is reached through the asu helper.
fetch() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" 'asu "dockerctl relay new"' 2>/dev/null; }

pass() {
    host=$(pick_host) || return 1
    # US (\037), not tab: tab is IFS whitespace, so bash collapses consecutive
    # tabs and an empty field between them disappears, shifting every later
    # field left. That delivered SMS notifications with empty bodies.
    fetch "$host" | while IFS=$'\037' read -r kind src title body; do
        [ -n "${kind:-}" ] || continue
        case "$kind" in
            sms) notify "SMS · $src" "" "$body" ;;
            app) notify "${title:-$src}" "$src" "$body" ;;
            *)   continue ;;
        esac
    done
}

install_agent() {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$SELF</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.err</string>
  <key>StandardOutPath</key><string>/tmp/$LABEL.out</string>
</dict></plist>
PLIST
    launchctl unload "$PLIST" 2>/dev/null
    launchctl load  "$PLIST" && echo "installed and started: $LABEL"
    echo "  logs: /tmp/$LABEL.out  /tmp/$LABEL.err"
    echo "  stop: launchctl unload $PLIST"
}

case "${1:-}" in
    --install) install_agent; exit 0 ;;
    --once)    pass; exit 0 ;;
esac

# A missed poll is not an error worth reporting - the phone sleeps, Wi-Fi
# roams, the tunnel reconnects. Only say something when it has been down long
# enough to mean something.
misses=0
while true; do
    if pass; then
        [ "$misses" -ge 30 ] && notify "Phone reachable again" "" "notification relay resumed"
        misses=0
    else
        misses=$((misses+1))
        [ "$misses" = 30 ] && notify "Phone unreachable" "" "notification relay has been down for 5 minutes"
    fi
    sleep "$INTERVAL"
done
