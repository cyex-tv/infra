# Deploying cyex.tv

## Layout on the host

| Path | What |
|---|---|
| `/srv/cyex-tv/infra` | this repo, cloned |
| `/srv/cyex-tv/infra/env` | the real env files (`db.env`, `api.env`, `events.env`, `worker.env`, `check.env`, optionally `backup.env` and `compose.env`). Gitignored (`env/*.env`), directory `750` and files `640`, `root:docker`. Never committed |
| `/srv/cyex-tv/platform` | the cyex-tv/platform checkout the images build from |

`CYEXTV_ENV_DIR` overrides the env location everywhere (compose, install, preflight, the cron
scripts); the default is `/srv/cyex-tv/infra/env`. Compose reads each file as
`${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}/<name>.env`.

## The short way

On the host, as a user in the `docker` group:
```bash
sudo mkdir -p /srv/cyex-tv && sudo chown "$USER" /srv/cyex-tv
git clone https://github.com/cyex-tv/infra /srv/cyex-tv/infra
# Put your filled env files in /srv/cyex-tv/infra/env/ (from env/*.env.example; see env/README.md)
sudo /srv/cyex-tv/infra/scripts/install.sh
```
Files made elsewhere can be copied in by passing their folder: `sudo scripts/install.sh <folder>`
copies them into the env dir. The script clones or updates the platform next to this repo
(`/srv/cyex-tv/platform`), sets the permissions, refuses to go on if an env file is tracked by git
or readable by everyone, runs `scripts/preflight.sh`, builds and starts everything, waits for it to
answer, and installs the backup and check cron jobs. It's safe to run again for an update. Then add
the tunnel hostnames (`docs/tunnel.md`), run `scripts/smoke.sh` from anywhere, and do
`docs/first-sweep.md`.

The env files stay in `env/`; there is nothing to delete afterwards.

## By hand

First time, on the host (as a user in the `docker` group):

1. Check out both repos under `/srv/cyex-tv`:
   ```bash
   git clone https://github.com/cyex-tv/platform /srv/cyex-tv/platform
   git clone https://github.com/cyex-tv/infra /srv/cyex-tv/infra
   ```
2. Put the env files in `/srv/cyex-tv/infra/env/` (see `env/README.md`): directory `750`, files
   `640`, owned by root, group `docker`. `git -C /srv/cyex-tv/infra status` must not list them.
3. Start it:
   ```bash
   cd /srv/cyex-tv/infra
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
/srv/cyex-tv/infra/scripts/deploy.sh
```
It pulls both repos, builds the new images while the old containers keep serving, then swaps only
the containers that changed and checks that api, events and web answer. The Rust compiler gets 2
cores (`CYEXTV_BUILD_JOBS=4 scripts/deploy.sh` for more) and keeps its compiled dependencies
between builds, so a normal deploy compiles only what changed: the site stays responsive during
the build, and the swap itself is a few seconds per service. A failed build changes nothing.

Avoid `docker compose up -d --build` for updates: it builds with every core while the site runs
on the same machine.

Migrations are forward-only and additive within v1, so the api can start on the new schema
while the old events and worker are still running for a moment.

## Rolling back

Check out the previous platform commit (`git -C /srv/cyex-tv/platform checkout <commit>`) and run
`scripts/deploy.sh --no-pull`. A migration is never rolled back by hand; if one is wrong, a new
forward migration fixes it.
