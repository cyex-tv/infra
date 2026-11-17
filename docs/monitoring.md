# Monitoring

What PLAN.md Phase 9 asks for, and how far it is.

## There now
- **Health:** `GET /health` (the process is up) and `GET /health/ready` (the database answers)
  on the api; `GET /health` on events. The compose health checks use them.
- **Logs:** every service logs JSON to stdout (`CYEX_TV_LOG_FORMAT=json`); the compose keeps
  5 × 20 MB per container. Errors carry `level=ERROR`.
- **Queue depth:** `SELECT count(*) FROM jobs WHERE state = 'queued' AND run_after <= now()`
  and failed jobs: `SELECT kind, count(*) FROM jobs WHERE state = 'failed' GROUP BY kind`.

## Still to build (Phase 9)
- Error tracking (for example a self-hosted GlitchTip, so no data leaves for a third party).
- Request metrics from the api (counts and latency per route).
- Alerts, at least:
  - the events service failing its health check for 2 minutes;
  - more than 100 due jobs for 10 minutes (the worker is stuck or too slow);
  - R2 errors in the worker's log (`storage answered`);
  - `tv-db` disk over 80 %.

A small check script on cron that runs the queries and `curl`s, and posts to a webhook, is
enough for v1.
