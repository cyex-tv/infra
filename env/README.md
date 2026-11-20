# Env files

On the server the infra repo is at `/srv/cyex-tv/infra` and the real env files sit next to the
committed `*.env.example` files, in `/srv/cyex-tv/infra/env/` (override with `CYEXTV_ENV_DIR`). The
compose file, `scripts/install.sh`, `scripts/preflight.sh`, `monitoring/check.sh` and the backup
scripts all read from there. The platform checkout is `/srv/cyex-tv/platform`.

Copy each `.example`, drop the `.example`, and fill in the values. Real values never go in this
repo or a chat.

- `.gitignore` has `env/*.env` (and keeps `!env/*.env.example`), so `git add` skips them.
- Directory `750`, files `640`, owner `root`, group `docker`. `scripts/install.sh` sets this and
  refuses to run if a file is readable by everyone.
- `scripts/install.sh` and `scripts/preflight.sh` fail if `git ls-files env/` lists anything other
  than the examples and this README.

| File | For | Needs |
|---|---|---|
| `db.env` | `tv-db` | a strong `POSTGRES_PASSWORD` |
| `api.env` | api | the database URL, OAuth clients, the owner, storage, the CDN URL |
| `events.env` | events | the database URL |
| `worker.env` | worker | the database URL, storage, the Cloudflare purge token |
| `s3.env` | `tv-s3` and the bucket init | `ROOT_ACCESS_KEY` and `ROOT_SECRET_KEY`, the same pair as the S3 keys in `api.env` and `worker.env` |
| `cdn.env` | `tv-cdn` | optional: the CDN's rate limits, timeouts and host name (`cdn.env.example`) |
| `check.env` | `monitoring/check.sh` | the alert webhook |
| `backup.env` | `backups/backup.sh` | optional: the rclone remote and the age public key for encrypting dumps |

The database URL points at the compose service: `postgres://cyextv:<password>@tv-db:5432/cyextv`.
