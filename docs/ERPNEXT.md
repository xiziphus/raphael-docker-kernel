# Running ERPNext on this phone

Written for someone — human or AI — arriving with **no prior context**. Read the
"What you are working with" section before touching anything; several things
here behave unlike a normal Docker host and will waste your time otherwise.

## What you are working with

A Xiaomi Redmi K20 Pro (`raphael`) running Android 16, with a custom kernel that
provides container support, and Debian in a **chroot** at `/data/debian` where
`dockerd` runs.

You reach it over adb from a computer:

```sh
adb devices                       # confirm the phone is listed
adb shell 'su -c "dockerctl status"'
```

Everything goes through `dockerctl`, which enters the chroot for you.
**There is no `docker` binary in Android** — `dockerctl` is the entry point, and
any unrecognised subcommand is passed straight to `docker` inside the chroot:

```sh
adb shell 'su -c "dockerctl ps"'
adb shell 'su -c "dockerctl logs erpnext_backend_1"'
adb shell 'su -c "dockerctl shell \"cd /opt/erpnext && ls\""'   # run a command in Debian
```

### Five things that will bite you

1. **Quoting.** You are nesting shell inside `adb shell` inside `su -c` inside
   `dockerctl shell`. Parentheses and quotes break easily and the errors are
   misleading. **Write a script, push it, and run it** rather than fighting
   quotes — this is the single biggest time-saver:
   ```sh
   adb push job.sh /data/local/tmp/
   adb shell 'su -c "cp /data/local/tmp/job.sh /data/debian/host-tmp/ && \
                     chmod 755 /data/debian/host-tmp/job.sh && \
                     dockerctl shell /host-tmp/job.sh"'
   ```
   `/data/debian/host-tmp/` is visible as `/host-tmp/` inside the chroot.

2. **`dockerctl shell` with no argument opens an interactive shell and will hang
   forever** in a non-interactive context. Always pass a command.

3. **`docker exec` DOES NOT WORK.** Containers are entered with `MS_MOVE` +
   `chroot` instead of `pivot_root` (`DOCKER_RAMDISK=1`), which is the only way
   they start inside a chroot at all. The cost is that an exec'd process lands
   at the mount-namespace root — Android's `/` — not the container's rootfs:
   ```
   $ docker exec c ls /
   adb_keys  apex  bin  bootstrap-apex      <- Android, not the container
   ```
   Anything you would normally do with `exec`, do with `docker run` against the
   same volumes and network instead. This also means exec gives you a view of
   Android's filesystem, which is the opposite of isolation.

4. **Android paranoid networking.** Creating a network socket requires the
   `inet` group (GID 3003) or `CAP_NET_RAW`. Containers whose image runs as a
   non-root user fail with `socket: operation not permitted`. Fix by adding
   `--user 0:0 --group-add 3003` to `docker run`.

5. **Published ports are not reachable from the LAN.** `-p 8080:80` works on the
   phone but not from other machines. Use `--network=host`, or a Cloudflare
   tunnel (`dockerctl tunnel quick <url>`).

6. **Memory is tight.** ~5.4 GB total, shared with Android. ERPNext's eleven
   containers idle around 534 MB but the *install* is much heavier. Do not run
   other large workloads while a site is being created.

## Where ERPNext lives

```
/data/debian/opt/erpnext/pwd.yml     the compose file (upstream frappe_docker)
```

Inside the chroot that path is `/opt/erpnext/pwd.yml`. Eleven services: `backend`
(gunicorn), `frontend` (nginx, publishes 8080), `websocket`, `scheduler`,
`queue-short`, `queue-long`, `db` (MariaDB), `redis-cache`, `redis-queue`, plus
one-shot `configurator` and `create-site` which exit 0 when done.

Default credentials from upstream's compose: **`Administrator` / `admin`**.
The site is named `frontend`.

`erpnext_db_1` reporting `(unhealthy)` is **normal and not a fault** — MariaDB
11.8's healthcheck misbehaves under compose v1. The site works regardless.

## Reset ERPNext completely

Destroys the database and all site data.

```sh
cat > reset.sh <<'EOF'
#!/bin/bash
set -x
cd /opt/erpnext
docker-compose -f pwd.yml down -v
docker volume ls -q | grep -i erpnext | xargs -r docker volume rm
docker-compose -f pwd.yml up -d
EOF
adb push reset.sh /data/local/tmp/
adb shell 'su -c "cp /data/local/tmp/reset.sh /data/debian/host-tmp/ && \
                  chmod 755 /data/debian/host-tmp/reset.sh && \
                  dockerctl shell \"nohup /host-tmp/reset.sh > /opt/erpnext/reset.log 2>&1 &\""'
```

Then **wait for `create-site` to exit 0**. It takes 10-20 minutes on this
hardware — it is running database migrations for every DocType.

```sh
adb shell 'su -c "dockerctl ps -a --filter name=create-site --format {{.Status}}"'
adb shell 'su -c "dockerctl logs erpnext_create-site_1 2>&1 | tail -5"'
```

Do not proceed until it says `Exited (0)`. Anything you do before that races the
migration and fails confusingly.

## Install India Compliance

The GST / e-invoicing app. **Install it into the running site — do not rebuild
the image.**

`docker exec` cannot be used (see gotcha 3), so build an image containing the
app and point the stack at it:

```sh
# 1. fetch the app inside a throwaway container, then commit it
docker run --name ic-build frappe/erpnext:v16.30.0 \
  bash -c "cd /home/frappe/frappe-bench && \
           bench get-app --branch version-16 https://github.com/resilient-tech/india-compliance"
# docker commit INHERITS the build container's CMD. Reset it, or every service
# started from this image re-runs get-app and aborts, taking the site down.
docker commit --change 'CMD ["start.sh"]' --change 'USER frappe' \
              --change 'WORKDIR /home/frappe/frappe-bench' ic-build erpnext-india:v16
docker rm -f ic-build

# 2. point the frappe services at it (mariadb/redis lines untouched)
cd /opt/erpnext && cp -n pwd.yml pwd.yml.orig
sed -i 's#image: frappe/erpnext:v16.30.0#image: erpnext-india:v16#g' pwd.yml
docker-compose -f pwd.yml up -d

# 3. install into the site from a FRESH container, not an exec.
#    The compose network is erpnext_frappe_network, NOT erpnext_default.
docker run --rm -v erpnext_sites:/home/frappe/frappe-bench/sites \
  --network erpnext_frappe_network erpnext-india:v16 \
  bench --site frontend install-app india_compliance
```

Expect 10+ minutes. **If step 3 fails partway** the app is left half-installed:
it registers in `list-apps` but its custom fields were never created, and every
later `migrate` then dies with
`Field enable_audit_trail does not exist on Accounts Settings`.
`--skip-failing` does not help, because that is a DocType sync failure, not a
patch. Uninstall the app and install once, cleanly.

Verify:

```sh
adb shell 'su -c "dockerctl exec erpnext_backend_1 bench --site frontend list-apps"'
```

`frappe`, `erpnext` and `india_compliance` should all be listed.

Then finish setup in the browser: **GST Settings**, company GSTIN, and the
e-invoice / e-waybill credentials if you use them. That part is data entry and
cannot be scripted meaningfully.

### If `get-app` fails to reach GitHub

Almost always a VPN app on the phone capturing uid 0 into a `tun` interface with
no default route. `dockerctl doctor` reports it:

```
[warn] a VPN app holds uid 0 (tun0) - pulls may fail intermittently
```

Pause the VPN and retry.

## Reaching it

| From | How |
|---|---|
| The phone | `http://127.0.0.1:8080` |
| Your LAN | **does not work** for published ports — see gotcha 5 |
| Anywhere | `dockerctl tunnel quick http://127.0.0.1:8080` prints a public URL |

A quick tunnel's URL is random and dies with the container. For a stable
hostname create a named tunnel in the Cloudflare Zero Trust dashboard and use
`dockerctl tunnel token <token>`.

**Change the `Administrator` password before exposing it.** A tunnel puts it on
the public internet, and `admin` is upstream's default.

## Health checks

```sh
adb shell 'su -c "dockerctl doctor"'          # kernel, mounts, network, daemon
adb shell 'su -c "dockerctl ps"'
adb shell 'su -c "free -m"'                   # memory pressure
adb shell 'su -c "dockerctl logs erpnext_backend_1 2>&1 | tail -30"'
```

If Docker is not running at all: `dockerctl start`. If it is running but
containers cannot reach the network: `dockerctl net apply` — Android's `netd`
rewrites its routing rules on every connectivity change and ours have to be
re-asserted.
