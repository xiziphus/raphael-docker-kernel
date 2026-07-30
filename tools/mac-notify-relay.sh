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
LABEL=win.stratifyx.raphael.notify
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# argv rather than string interpolation: message bodies contain quotes,
# backslashes and apostrophes, and AppleScript string escaping is its own
# small nightmare. Passing them as arguments sidesteps all of it.
notify() {  # notify <title> <subtitle> <body>
    osascript -e 'on run argv
        display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
    end run' "$1" "$2" "$3" >/dev/null 2>&1
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
    fetch "$host" | while IFS=$'\t' read -r kind src title body; do
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
