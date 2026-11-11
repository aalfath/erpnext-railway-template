# ERPNext on Railway

Source for the ERPNext Railway template. Railway volumes can't be shared between services, while upstream
[frappe_docker](https://github.com/frappe/frappe_docker) runs backend, frontend, websocket, workers and scheduler as
separate containers on one shared `sites` volume. This template runs them all in one service instead.

- **ERPNext**: the official `frappe/erpnext` image. Its start command decodes [`start.sh`](start.sh) (inlined as base64,
  so the service needs no network fetch at boot) and runs it. The script:
  - runs as root only long enough to make the Railway volume at `/home/frappe/frappe-bench/sites` writable, then drops to the `frappe` user
  - writes the bench config (MariaDB, Redis, socketio), creates the site `erp.local` with ERPNext on first start, and runs `bench migrate` when the image version changes
  - serves a small "being set up" page on `PORT` while the site is created or migrated (so Railway's health check passes), then
  - starts nginx (on `PORT`), gunicorn, the socketio server, one worker for every queue and the scheduler. If any of them exits, the container exits and Railway restarts it
- **MariaDB**: the official `mariadb:11.8` image with the charset flags Frappe needs, plus a volume.
- **Redis**: the official `redis:7.4-alpine` image with a password and AOF persistence, used for cache, queue and socketio.

To regenerate the start command after editing `start.sh`:

```sh
echo "/bin/bash -c \"echo $(base64 -w0 start.sh) | base64 -d > /tmp/start.sh && exec bash /tmp/start.sh\""
```

| Variable (ERPNext service) | Purpose |
|---|---|
| `DB_HOST` | MariaDB private host |
| `DB_ROOT_PASSWORD` | MariaDB root password, used to create the site database |
| `REDIS_URL` | `redis://default:<password>@<host>:6379` |
| `ADMIN_PASSWORD` | Password of the `Administrator` user, set on first start |
| `RAILWAY_RUN_UID` | `0`, so the script can fix volume ownership before dropping to `frappe` |
| `PORT` | Port nginx listens on (8080) |
| `GUNICORN_WORKERS`, `GUNICORN_THREADS`, `NGINX_WORKERS` | Optional tuning (defaults 2, 4, 2) |

MIT licensed. ERPNext and Frappe are GPLv3 projects by Frappe Technologies.
