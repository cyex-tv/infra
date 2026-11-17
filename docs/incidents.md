# Incidents

The documented process PLAN.md Phase 9 asks for, until there is a status page.

## When something is wrong

1. **Look** (from `/opt/cyextv/infra`, with `C="docker compose -f compose/docker-compose.yaml"`):
   `$C ps` and `$C logs --since 30m <service>`.
   `curl -fs http://127.0.0.1:8080/health/ready` says whether the api reaches its database.
2. **Say so:** post in the cyex.tv announcements channel what's broken and that it's being
   looked at. Short, no blame, no guesses about the cause.
3. **Stop the harm first:** restart the one service (`$C restart <service>`),
   or roll back (`docs/deploy.md`). Never touch cyex-api's containers for a cyex.tv problem.
4. **Fix, then tell:** post when it's fixed and what users may notice (for example, emotes
   showing again after a refresh).
5. **Write it down:** a few lines in `docs/incidents/<yyyy-mm-dd>.md`: what happened, when, why,
   what changes so it doesn't again.

## What clients do on their own

- Chat clients keep the emotes they have and retry; nothing they show disappears because the
  api is down.
- The event socket sends `reconnect` on a planned restart; clients resume and replay what they
  missed (ADR 0005), within 24 h.

## Security incidents

A leaked secret: rotate it first (Twitch, Kick, R2, Cloudflare, the database password), then
look for misuse in the audit log and the access logs. Personal data exposed: the owner decides
on notifying users and the Swiss FDPIC (revFADP), within the legal deadlines.
