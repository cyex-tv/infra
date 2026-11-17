# Launch checklist

PLAN.md Phase 9. Every box is ticked before cyex.tv is announced.

## The platform
- [ ] Production is up: `https://api.cyex.tv/health` and `/health/ready` answer `ok`.
- [ ] Sign-in works with a real Twitch account and a real Kick account, and linking both.
- [ ] An upload is transcoded and its files load from `https://cdn.cyex.tv/emotes/<hash>/2x.webp`.
- [ ] `originals/` is not public on the CDN (the WAF rule from the Phase 3 owner steps).
- [ ] A set change reaches a connected client in under a second.
- [ ] Rate limits are on, and the client IP comes from Cloudflare (`CYEX_TV_TRUST_CLOUDFLARE=true`).
- [ ] The owner (`CYEX_TV_OWNER_IDS`) is set, and moderators have their roles.

## Safety and the law
- [ ] Legal pages on cyex.tv: terms, rules for uploads.
- [ ] Privacy page (revFADP): what is stored (platform IDs, logins, display names, avatars; no
      email; no platform tokens kept), why, for how long, and who to ask.
- [ ] Contact page, and the takedown contact from `platform/docs/takedown.md` works.
- [ ] Kick's Developer Terms read; Twitch's Developer Agreement checked against what cyex.tv does.
- [ ] The CDN purge token is set, so takedowns purge.

## Operations
- [ ] The nightly backup runs, and its off-host copy exists.
- [ ] A restore was tested (`backups/restore-test.sh`), with the date in `docs/restores.md`.
- [ ] Alerts: the events service down, the worker queue growing, R2 errors.
- [ ] Resource limits per container, if cyex-api shares the host.
- [ ] The incident process (`docs/incidents.md`) is known to whoever is on call.

## For developers
- [ ] The public API docs are published (REST from `openapi.json`, GraphQL from the SDL).
