#!/bin/bash
# ERPNext all-in-one start script for Railway (https://github.com/aalfath/erpnext-railway-template)
# Runs nginx, gunicorn, socketio, one RQ worker and the scheduler in one container,
# because Railway volumes can't be shared between services.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITE="${SITE_NAME:-erp.local}"
export PORT="${PORT:-8080}"

# 1. As root (RAILWAY_RUN_UID=0): make the volume writable for the frappe user, then drop privileges.
if [ "$(id -u)" = "0" ]; then
  rm -rf "$BENCH/sites/lost+found"
  if [ "$(stat -c %u "$BENCH/sites")" != "1000" ]; then chown -R frappe:root "$BENCH/sites"; fi
  chown -R frappe:root "$BENCH/logs" /etc/nginx/conf.d 2>/dev/null || true
  exec runuser -u frappe -- bash "$0" "$@"
fi

cd "$BENCH"
umask 0002
# Re-open stdout/stderr as pipes owned by frappe, so nginx can open /dev/stdout and /dev/stderr.
exec > >(cat) 2> >(cat >&2)
log() { echo "[erpnext-railway] $*"; }

: "${DB_HOST:?DB_HOST is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
: "${REDIS_URL:?REDIS_URL is required}"
DB_PORT="${DB_PORT:-3306}"

# 2. Bench files that upstream keeps in the shared sites volume.
ls -1 apps > sites/apps.txt
rm -rf sites/assets && ln -s "$BENCH/assets" sites/assets
[ -f sites/common_site_config.json ] || echo '{}' > sites/common_site_config.json

wait_for() { # host port name
  local i
  for i in $(seq 1 90); do
    if env/bin/python -c "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3)" "$1" "$2" 2>/dev/null; then
      log "$3 is reachable"; return 0
    fi
    sleep 2
  done
  log "$3 at $1:$2 not reachable"; exit 1
}
wait_for "$DB_HOST" "$DB_PORT" MariaDB
REDIS_HOSTPORT="${REDIS_URL##*@}"; REDIS_HOSTPORT="${REDIS_HOSTPORT#redis://}"; REDIS_HOSTPORT="${REDIS_HOSTPORT%%/*}"
wait_for "${REDIS_HOSTPORT%:*}" "${REDIS_HOSTPORT##*:}" Redis

bench set-config -g db_host "$DB_HOST" >/dev/null
bench set-config -gp db_port "$DB_PORT" >/dev/null
bench set-config -g redis_cache "$REDIS_URL" >/dev/null
bench set-config -g redis_queue "$REDIS_URL" >/dev/null
bench set-config -g redis_socketio "$REDIS_URL" >/dev/null
bench set-config -gp socketio_port 9000 >/dev/null
# socketio authenticates sessions by calling the backend; keep that call on loopback.
bench set-config -g webserver_host 127.0.0.1 >/dev/null
bench set-config -gp webserver_port 8000 >/dev/null

# While the site is being created or migrated (minutes), serve a holding page on PORT so Railway's
# health check (300 s by default) passes and visitors see what's happening.
SETUP_PID=""
setup_page_start() {
  [ -n "$SETUP_PID" ] && return 0
  cat > /tmp/nginx-setup.conf <<NGINX
worker_processes 1;
pid /tmp/nginx-setup.pid;
error_log stderr;
events { worker_connections 64; }
http {
  access_log off;
  server {
    listen $PORT;
    location = /api/method/ping { default_type application/json; return 200 '{"message":"pong"}'; }
    location / {
      default_type text/html;
      add_header Retry-After 30 always;
      return 503 '<!doctype html><meta http-equiv="refresh" content="20"><title>ERPNext is starting</title><p style="font-family:sans-serif;margin:3em">ERPNext is being set up (first start or upgrade). This takes a few minutes; the page reloads by itself.</p>';
    }
  }
}
NGINX
  nginx -c /tmp/nginx-setup.conf -g 'daemon off;' & SETUP_PID=$!
}
setup_page_stop() {
  [ -z "$SETUP_PID" ] && return 0
  kill -TERM "$SETUP_PID" 2>/dev/null; wait "$SETUP_PID" 2>/dev/null; SETUP_PID=""
}

# 3. Create the site on first start; migrate when the image version changes.
VERSION="$(ls -1 apps | while read -r a; do printf '%s=%s ' "$a" "$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "apps/$a/$a/__init__.py")"; done)"
if [ ! -f "sites/$SITE/.railway-installed" ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required for the first start}"
  log "Creating site $SITE (first start, takes a few minutes)"
  setup_page_start
  bench new-site "$SITE" --force \
    --mariadb-user-host-login-scope='%' \
    --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext --set-default
  bench --site "$SITE" scheduler enable
  # Job types are stamped in the install timezone (Asia/Kolkata); if the setup wizard later picks a
  # timezone west of it, every job's first run lands hours in the future. Backdate so they run on the next tick.
  bench --site "$SITE" mariadb -e "UPDATE \`tabScheduled Job Type\` SET creation='2000-01-01' WHERE name > '' AND last_execution IS NULL"
  echo "$VERSION" > "sites/$SITE/.railway-version"
  touch "sites/$SITE/.railway-installed"
elif [ "$(cat "sites/$SITE/.railway-version" 2>/dev/null)" != "$VERSION" ]; then
  log "App versions changed ($VERSION), running bench migrate"
  setup_page_start
  bench --site "$SITE" migrate
  echo "$VERSION" > "sites/$SITE/.railway-version"
fi
bench use "$SITE" >/dev/null
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  bench --site "$SITE" set-config host_name "https://$RAILWAY_PUBLIC_DOMAIN" >/dev/null
fi

# 4. nginx config from the image template; Origin follows the request host so socketio accepts it.
export BACKEND=127.0.0.1:8000 SOCKETIO=127.0.0.1:9000 NGINX_LISTEN_PORT="$PORT" \
  UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-0.0.0.0/0}" UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
  UPSTREAM_REAL_IP_RECURSIVE=off FRAPPE_SITE_NAME_HEADER="$SITE" PROXY_READ_TIMEOUT=120 \
  CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
# shellcheck disable=SC2016
envsubst '${BACKEND} ${SOCKETIO} ${NGINX_LISTEN_PORT} ${UPSTREAM_REAL_IP_ADDRESS} ${UPSTREAM_REAL_IP_HEADER} ${UPSTREAM_REAL_IP_RECURSIVE} ${FRAPPE_SITE_NAME_HEADER} ${PROXY_READ_TIMEOUT} ${CLIENT_MAX_BODY_SIZE}' \
  < /templates/nginx/frappe.conf.template \
  | sed 's#proxy_set_header Origin .*#proxy_set_header Origin $proxy_x_forwarded_proto://$host;#' \
  > /etc/nginx/conf.d/frappe.conf
sed -e "s/^worker_processes .*/worker_processes ${NGINX_WORKERS:-2};/" -e '/^worker_cpu_affinity/d' /etc/nginx/nginx.conf > /tmp/nginx.conf

setup_page_stop

# 5. Run every process; if one exits, stop the rest so Railway restarts the container.
pids=()
start() { log "starting $1"; shift; "$@" & pids+=($!); }
trap 'kill -TERM "${pids[@]}" 2>/dev/null; wait "${pids[@]}"; exit 0' TERM INT
start gunicorn env/bin/gunicorn --chdir="$BENCH/sites" --bind=127.0.0.1:8000 \
  --threads="${GUNICORN_THREADS:-4}" --workers="${GUNICORN_WORKERS:-2}" --worker-class=gthread \
  --worker-tmp-dir=/dev/shm --timeout=120 --preload frappe.app:application
start socketio node "$BENCH/apps/frappe/socketio.js"
start worker bench worker --queue long,default,short
start scheduler bench schedule
start nginx nginx -c /tmp/nginx.conf -g 'daemon off;'
set +e
wait -n "${pids[@]}"
code=$?
log "a process exited with code $code, stopping the container"
kill -TERM "${pids[@]}" 2>/dev/null
wait "${pids[@]}"
exit 1
