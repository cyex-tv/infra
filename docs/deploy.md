# Deploying cyex.tv

## The short way

On the host, as a user in the `docker` group:
```bash
git clone https://github.com/cyex-tv/infra /opt/cyextv/infra
# Copy your filled env files to /opt/cyextv/etc-cyextv/ (db, api, events, worker, check .env)
cd /opt/cyextv && sudo infra/scripts/install.sh /opt/cyextv/etc-cyextv
```
It clones the platform next to it, installs the env files to `/etc/cyextv`, runs
`scripts/preflight.sh`, builds and starts everything, waits for it to answer, and installs the
backup and check cron jobs. It's safe to run again for an update. Then add the tunnel
hostnames (`docs/tunnel.md`), run `scripts/smoke.sh` from anywhere, and do
`docs/first-sweep.md`.

Delete `/opt/cyextv/etc-cyextv` once it ran: the installed copies are in `/etc/cyextv`.

## By hand

First time, on the host (as a user in the `docker` group):

1. Check out both repos next to each other, for example in `/opt/cyextv`:
   ```bash
   git clone https://github.com/cyex-tv/platform /opt/cyextv/platform
   git clone https://github.com/cyex-tv/infra /opt/cyextv/infra
   ```
2. Put the env files in `/etc/cyextv/` (see `env/README.md`), `chmod 640`, owned by root, group `docker`.
3. Start it:
   ```bash
   cd /opt/cyextv/infra
   docker compose -f compose/docker-compose.yaml up -d --build
   ```
   The api runs the database migrations on start.
4. Add the tunnel hostnames (`docs/tunnel.md`).
5. Check:
   ```bash
   curl -fs http://127.0.0.1:8080/health/ready
   curl -fs https://api.cyex.tv/health
   ```
6. Install the nightly backup (`backups/backup.sh`) and run the restore test once
   (`backups/restore-test.sh`); write the result in `docs/restores.md`.
7. Install the alert check (`docs/monitoring.md`).

## Updating

```bash
cd /opt/cyextv/platform && git pull
cd /opt/cyextv/infra && git pull
docker compose -f compose/docker-compose.yaml up -d --build
```

Migrations are forward-only and additive within v1, so the api can start on the new schema
while the old events and worker are still running for a moment.

## Rolling back

Check out the previous platform commit and run `up -d --build` again. A migration is never
rolled back by hand; if one is wrong, a new forward migration fixes it.
