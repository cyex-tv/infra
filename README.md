# cyex.tv infra

Deployment, Cloudflare configuration, backups and runbooks for cyex.tv.

What lives here:
- the production compose for the api, events, worker, web, `tv-db`, `tv-s3` and `tv-cdn` containers;
- Cloudflare: the `cyex.tv` zone, DNS, the DNS-only `cdn.cyex.tv` record (self-hosted CDN, `docs/self-hosted-cdn.md`), tunnel hostnames;
- backups: the nightly `tv-db` dump, the CDN data folder, restore steps;
- runbooks: incidents, takedowns, restores.

cyex.tv is separate from cyex.app. Nothing here changes cyex-api's containers, config or Cloudflare rules.

No secrets in this repo; it is public. Values go in `.env` files on the host or in a secrets manager, and examples live in `*.example` files.

Status: Phase 9 in progress. See the plan in [cyex-tv/platform](https://github.com/cyex-tv/platform).

| Where | What |
|---|---|
| `compose/docker-compose.yaml` | `tv-db`, api, events and worker on their own network, ports on 127.0.0.1, resource limits |
| `env/` | the env files as examples; the real ones live in `/srv/cyex-tv/infra/env/` on the host (gitignored) |
| `scripts/` | `install.sh` (first install and updates), `preflight.sh` (env check), `smoke.sh` |
| `docs/deploy.md` | the host layout (`/srv/cyex-tv/infra`, `/srv/cyex-tv/platform`), first deploy, updates, rollback |
| `docs/tunnel.md` | the new tunnel hostnames (`api.cyex.tv`, `cyex.tv`), cyex.app untouched |
| `backups/` | the nightly dump with an off-host copy, and the restore test |
| `docs/monitoring.md`, `docs/incidents.md` | health, logs, alerts to build, the incident process |
| `docs/launch.md` | the launch checklist |

Licence: [AGPL-3.0](LICENSE).
