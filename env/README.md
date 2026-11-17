# Env files

The compose file reads these from `/etc/cyextv/` on the host, owned by root and readable by the
Docker group only (`chmod 640`). Copy each `.example`, drop the `.example`, and fill in the values.
Real values never go in this repo or a chat.

| File | For | Needs |
|---|---|---|
| `db.env` | `tv-db` | a strong `POSTGRES_PASSWORD` |
| `api.env` | api | the database URL, OAuth clients, the owner, storage, the CDN URL |
| `events.env` | events | the database URL |
| `worker.env` | worker | the database URL, storage, the Cloudflare purge token |
| `check.env` | `monitoring/check.sh` | the alert webhook (`chmod 600`) |
| `backup.env` | `backups/backup.sh` | optional: the rclone remote and the age public key for encrypting dumps (`chmod 600`) |

The database URL points at the compose service: `postgres://cyextv:<password>@tv-db:5432/cyextv`.
