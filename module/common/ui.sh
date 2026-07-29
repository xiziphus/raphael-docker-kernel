#!/system/bin/sh
# Portainer, the web UI.  . lib.sh, mount.sh, daemon.sh first.
IMG=portainer/portainer-ce:latest

ui_start() {
    running || { bad "dockerd is not running - 'dockerctl start' first"; return 1; }
    # --no-setup-token: without it Portainer demands a token from its own log
    # AND disables the init endpoint five minutes after startup, which turns
    # first-run into a race. 'dockerctl ui admin <pw>' creates the account
    # directly instead, so the token buys nothing here.
    in_chroot '
      docker volume create portainer_data >/dev/null 2>&1
      if docker ps -a --format "{{.Names}}" | grep -qx portainer; then
        docker start portainer >/dev/null 2>&1
      else
        docker run -d --name portainer --network=host --restart=always \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -v portainer_data:/data '"$IMG"' --no-setup-token >/dev/null
      fi
      sleep 6
    '
    ok "portainer: http://127.0.0.1:9000"
    for i in $(uplinks); do
        _a=$(ip -4 addr show "$i" 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
        [ -n "$_a" ] && say "         http://$_a:9000  (from your LAN)"
    done
}

ui_stop()   { in_chroot 'docker stop portainer >/dev/null 2>&1'; ok "portainer stopped"; }
ui_status() { in_chroot 'docker ps -a --filter name=portainer --format "  {{.Names}}  {{.Status}}"'; }

# Create the initial admin over the API. Avoids the browser dance entirely.
ui_admin() {
    _pw="$1"
    [ ${#_pw} -ge 12 ] || { bad "portainer requires a password of at least 12 characters"; return 1; }
    in_chroot "curl -s -o /dev/null -w '%{http_code}' -X POST \
        http://127.0.0.1:9000/api/users/admin/init \
        -H 'Content-Type: application/json' \
        -d '{\"Username\":\"admin\",\"Password\":\"$_pw\"}' --max-time 20" \
      | tr -d '\r' | while read -r code; do
          case "$code" in
            200|204) ok "admin created - log in as 'admin'" ;;
            409)     warn "an admin already exists; use the UI to change the password" ;;
            *)       bad "unexpected HTTP $code from Portainer" ;;
          esac
        done
}
