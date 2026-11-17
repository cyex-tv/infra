# Monitoring

What PLAN.md Phase 9 asks for, and how far it is.

## Health
`GET /health` (the process is up) and `GET /health/ready` (the database answers) on the api;
`GET /health` on events. The compose health checks use them.

## Logs
Every service logs JSON to stdout (`CYEX_TV_LOG_FORMAT=json`); the compose keeps 5 × 20 MB per
container. Errors carry `level=ERROR`.

## Metrics
api, events and worker serve Prometheus metrics at `GET /metrics` on port 9100 inside the
`cyextv` network (`CYEX_TV_METRICS_BIND`). No port is published and no tunnel route points there.
Read one by hand:
```bash
docker exec cyex-tv-worker-1 curl -fs http://127.0.0.1:9100/metrics
```

| Metric | Where | What |
|---|---|---|
| `cyex_tv_http_requests_total` | api, events | requests by method, route pattern and status |
| `cyex_tv_http_request_duration_seconds` | api, events | histogram, same labels |
| `cyex_tv_hub_subscribers`, `cyex_tv_hub_topics` | api, events | live-update connections and topics |
| `cyex_tv_db_pool_connections`, `cyex_tv_db_pool_idle` | api, events | the database pool |
| `cyex_tv_jobs` | worker | jobs not done, by kind and state (`due`, `waiting`, `running`, `failed`) |
| `cyex_tv_jobs_finished_total`, `cyex_tv_job_duration_seconds` | worker | attempts by kind and outcome |
| `cyex_tv_metrics_db_up` | worker | whether the scrape reached `tv-db` |

A Prometheus and Grafana can scrape these later by joining the `cyextv` network; v1 doesn't need
them.

## Alerts
`monitoring/check.sh`, from cron every 5 minutes, posts to a webhook (`env/check.env.example`).
A check alerts after failing twice in a row (about 10 minutes), and again when it clears:

| Check | Fails when |
|---|---|
| `api` | `/health/ready` doesn't answer (the api or `tv-db` is down) |
| `events` | `/health` on events doesn't answer |
| `web` | the website doesn't answer on `/developers` |
| `worker` | the worker isn't running, or its metrics don't answer |
| `worker-db` | the worker can't reach `tv-db` |
| `queue` | more than 100 jobs are due (the worker is stuck or too slow) |
| `storage` | `storage answered` errors in the worker's log in the last 10 minutes (R2) |
| `disk` | the Docker disk is 80 % full or more |

Install:
```bash
sudo cp env/check.env.example /etc/cyextv/check.env && sudo chmod 600 /etc/cyextv/check.env
sudo mkdir -p /var/lib/cyextv-check && sudo chown "$USER" /var/lib/cyextv-check
( crontab -l 2>/dev/null; echo '*/5 * * * * /opt/cyextv/infra/monitoring/check.sh >> /var/log/cyextv-check.log 2>&1' ) | crontab -
```
Test the webhook once by stopping the events service for 10 minutes, or by setting
`CYEXTV_DUE_MAX=-1` for two runs.

## Still open
- Error tracking (for example a self-hosted GlitchTip, so no data leaves for a third party). The
  JSON logs and the `api` and `storage` checks cover v1.
