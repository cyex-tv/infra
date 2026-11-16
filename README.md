# cyex.tv infra

Deployment, Cloudflare configuration, backups and runbooks for cyex.tv.

What lives here:
- the production compose for the api, events, worker, web and `tv-db` containers;
- Cloudflare: the `cyex.tv` zone, DNS, the R2 bucket on `cdn.cyex.tv`, cache rules, tunnel hostnames;
- backups: the nightly `tv-db` dump, R2 versioning, restore steps;
- runbooks: incidents, takedowns, restores.

cyex.tv is separate from cyex.app. Nothing here changes cyex-api's containers, config or Cloudflare rules.

No secrets in this repo; it is public. Values go in `.env` files on the host or in a secrets manager, and examples live in `*.example` files.

Status: planned for Phase 9. See the plan in [cyex-tv/platform](https://github.com/cyex-tv/platform).

Licence: [AGPL-3.0](LICENSE).
