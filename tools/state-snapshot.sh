#!/bin/bash
# state-snapshot - capture the Docker/ERPNext state of this device into a git repo.
#
# Runs INSIDE the Debian chroot (ssh raphael). Each run refreshes every tracked
# file and commits, so `git log`/`git diff` show exactly what changed between
# snapshots and any earlier state can be checked out again.
#
#   state-snapshot                 snapshot with an auto message
#   state-snapshot "before X"      snapshot with your own message
#
# Secrets (DB password, tunnel credentials) ARE tracked on purpose - this repo
# is the recovery source. Keep it off any public remote.

set -u

REPO=/opt/state
SITE=${SITE:-frontend}
IMAGE=${IMAGE:-erpnext-india:v16}
NET=${NET:-erpnext_frappe_network}
MSG=${1:-}

say() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "no docker in PATH"
command -v git    >/dev/null || die "no git in PATH"

mkdir -p "$REPO"/{manifest/inspect,compose,cloudflared,site,db,volumes} || die "mkdir failed"
cd "$REPO" || die "cd failed"

if [ ! -d .git ]; then
    git init -q
    git config user.email "state@raphael.local"
    git config user.name  "raphael state snapshot"
    printf '*.tmp\n' > .gitignore
fi

# ---------------------------------------------------------------- manifests
say "manifests"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sort > manifest/containers.txt
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}'   | sort > manifest/images.txt
docker volume ls --format '{{.Name}}'                                   | sort > manifest/volumes.txt
docker network ls --format '{{.Name}}\t{{.Driver}}'                     | sort > manifest/networks.txt
docker info --format 'server={{.ServerVersion}} storage={{.Driver}} runtime={{.DefaultRuntime}}' \
    > manifest/docker-info.txt 2>/dev/null
{ uname -a; echo; cat /etc/debian_version 2>/dev/null; } > manifest/kernel.txt

# Per-container inspect: the useful diff when something "just stopped working".
# Volatile fields are stripped so an unchanged container produces no commit noise.
rm -f manifest/inspect/*.json
for c in $(docker ps -a --format '{{.Names}}'); do
    docker inspect "$c" 2>/dev/null \
      | sed -E 's/"(StartedAt|FinishedAt|CreatedAt|Created)": *"[^"]*"/"\1": "<ts>"/g' \
      > "manifest/inspect/$c.json"
done

# ------------------------------------------------------------------ configs
say "configs"
[ -f /opt/erpnext/pwd.yml ]      && cp /opt/erpnext/pwd.yml      compose/pwd.yml
[ -d /opt/cloudflared ]          && cp -f /opt/cloudflared/*     cloudflared/ 2>/dev/null

# site_config.json holds the DB credentials needed to restore.
docker run --rm -v erpnext_sites:/s --entrypoint cat alpine \
    "/s/$SITE/site_config.json" > site/site_config.json 2>/dev/null \
    || rm -f site/site_config.json

# --------------------------------------------------------------- database
# Uncompressed SQL on purpose: git deltas it well, so N snapshots cost far less
# than N copies. Compressed dumps are opaque blobs to git.
if [ -s site/site_config.json ]; then
    say "database"
    DBN=$(sed -n 's/.*"db_name": *"\([^"]*\)".*/\1/p'     site/site_config.json)
    DBU=$(sed -n 's/.*"db_user": *"\([^"]*\)".*/\1/p'     site/site_config.json)
    DBP=$(sed -n 's/.*"db_password": *"\([^"]*\)".*/\1/p' site/site_config.json)
    [ -n "$DBN" ] && docker run --rm --network "$NET" mariadb:11.8 \
        mariadb-dump -hdb -u"$DBU" -p"$DBP" --single-transaction --quick \
        --skip-dump-date --databases "$DBN" > db/$SITE.sql.tmp 2>db/err.tmp
    if [ -s db/$SITE.sql.tmp ]; then
        mv db/$SITE.sql.tmp db/$SITE.sql
        rm -f db/err.tmp
    else
        say "  ! dump failed: $(tail -1 db/err.tmp 2>/dev/null)"
        rm -f db/$SITE.sql.tmp
    fi
fi

# ---------------------------------------------------------------- volumes
# Small volumes only. erpnext_db-data is NOT tarred - the SQL dump above is the
# consistent, restorable form of it; a tar of a live datadir is neither.
say "volumes"
for v in erpnext_sites portainer_data; do
    docker volume inspect "$v" >/dev/null 2>&1 || continue
    docker run --rm -v "$v":/v -v "$REPO/volumes":/out alpine \
        tar czf "/out/$v.tar.gz" --exclude=./assets --exclude='*/private/backups/*' -C /v . 2>/dev/null
done

# ------------------------------------------------------------------ commit
git add -A
if git diff --cached --quiet; then
    say "no changes since last snapshot"
    git log -1 --format='  HEAD %h %s' 2>/dev/null
    exit 0
fi

STAMP=$(date '+%Y-%m-%d %H:%M')
[ -n "$MSG" ] || MSG="snapshot"
git commit -q -m "$MSG ($STAMP)" -m "$(git diff --cached --stat | tail -1)"
say "committed"
git log -1 --format='  %h %s'
git count-objects -vH | sed -n 's/^size-pack: /  repo size: /p'
