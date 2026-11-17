#!/usr/bin/env bash
# The v1 alerts (PLAN.md Phase 9, docs/monitoring.md). Run every 5 minutes from cron, as a user
# in the docker group:
#   */5 * * * * /srv/cyex-tv/infra/monitoring/check.sh >> /var/log/cyextv-check.log 2>&1
#
# Each check is either ok or failing. A failing check alerts once when it starts and once when it
# clears, not every run. Alerts go to CYEXTV_ALERT_WEBHOOK (a Discord or Slack-compatible
# incoming webhook taking {"content": "..."}), read from ${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}/check.env if present.
# Without a webhook the alerts are only logged.
set -uo pipefail

ENV_DIR="${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}"
[ -r "$ENV_DIR/check.env" ] && . "$ENV_DIR/check.env"
WEBHOOK="${CYEXTV_ALERT_WEBHOOK:-}"
STATE="${CYEXTV_CHECK_STATE:-/var/lib/cyextv-check}"
DUE_MAX="${CYEXTV_DUE_MAX:-100}"
DISK_MAX="${CYEXTV_DISK_MAX:-80}"
DISK_PATH="${CYEXTV_DISK_PATH:-/var/lib/docker}"
# R2 usage against the free tier (optional): an account API token with Account Analytics: Read.
CF_ACCOUNT="${CYEXTV_CF_ACCOUNT_ID:-}"
CF_TOKEN="${CYEXTV_CF_ANALYTICS_TOKEN:-}"
R2_WARN_PCT="${CYEXTV_R2_WARN_PCT:-80}"
mkdir -p "$STATE"

now() { date -u +%FT%TZ; }

notify() {
    echo "$(now) $1"
    [ -z "$WEBHOOK" ] && return
    local body
    body=$(printf '%s' "cyex.tv: $1" | sed 's/\/\\/g; s/"/\\"/g')
    curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"content\":\"$body\"}" "$WEBHOOK" > /dev/null \
        || echo "$(now) the webhook refused the alert" >&2
}

# report NAME ok|fail MESSAGE: alerts on a change only. A check must fail twice in a row (two
# runs, about 10 minutes) before it alerts, so one slow scrape doesn't page anyone.
report() {
    local name=$1 result=$2 message=$3 file="$STATE/$1"
    local before
    before=$(cat "$file" 2>/dev/null || echo ok)
    case "$result:$before" in
        ok:ok) ;;
        ok:*) [ "$before" = alerted ] && notify "resolved: $name"; echo ok > "$file" ;;
        fail:ok) echo pending > "$file" ;;
        fail:pending) notify "FAILING: $name: $message"; echo alerted > "$file" ;;
        fail:alerted) ;;
    esac
}

container() {
    docker ps -q --filter label=com.docker.compose.project=cyex-tv \
        --filter "label=com.docker.compose.service=$1" | head -n 1
}

# 1. The api, the events service and the website answer.
if curl -fs -m 5 http://127.0.0.1:8080/health/ready > /dev/null; then
    report api ok ""
else
    report api fail "http://127.0.0.1:8080/health/ready does not answer"
fi
if curl -fs -m 5 http://127.0.0.1:8081/health > /dev/null; then
    report events ok ""
else
    report events fail "http://127.0.0.1:8081/health does not answer"
fi

if curl -fs -m 5 http://127.0.0.1:8082/developers > /dev/null; then
    report web ok ""
else
    report web fail "the website (http://127.0.0.1:8082) does not answer"
fi

# 2. The worker keeps up: due jobs from its metrics (CYEX_TV_METRICS_BIND=0.0.0.0:9100).
worker=$(container worker)
if [ -z "$worker" ]; then
    report worker fail "the worker container is not running"
elif ! metrics=$(docker exec "$worker" curl -fs -m 5 http://127.0.0.1:9100/metrics); then
    report worker fail "the worker's metrics do not answer"
else
    report worker ok ""
    due=$(printf '%s\n' "$metrics" | awk '/^cyex_tv_jobs\{.*state="due"/ { n += $2 } END { print n + 0 }')
    if [ "$due" -gt "$DUE_MAX" ]; then
        report queue fail "$due jobs are due (more than $DUE_MAX)"
    else
        report queue ok ""
    fi
    if printf '%s\n' "$metrics" | grep -q '^cyex_tv_metrics_db_up 0'; then
        report worker-db fail "the worker can't reach tv-db"
    else
        report worker-db ok ""
    fi
fi

# 3. R2 errors in the worker's log over the last 10 minutes.
if [ -n "$worker" ]; then
    errors=$(docker logs --since 10m "$worker" 2>&1 | grep -c 'storage answered' || true)
    if [ "$errors" -gt 0 ]; then
        report storage fail "$errors storage errors in the worker's log in 10 minutes"
    else
        report storage ok ""
    fi
fi

# 4. Disk.
used=$(df --output=pcent "$DISK_PATH" | tail -n 1 | tr -dc '0-9')
if [ "${used:-0}" -ge "$DISK_MAX" ]; then
    report disk fail "$DISK_PATH is ${used} % full"
else
    report disk ok ""
fi

# 5. R2 usage this month against the free tier, at most once an hour. The free tier is per
# Cloudflare account, so every bucket on the account counts. Needs jq.
r2_due() {
    local stamp="$STATE/r2-last"
    [ -f "$stamp" ] && [ "$(( $(date +%s) - $(cat "$stamp") ))" -lt 3600 ] && return 1
    date +%s > "$stamp"
}
if [ -n "$CF_ACCOUNT" ] && [ -n "$CF_TOKEN" ] && ! command -v jq > /dev/null; then
    echo "$(now) R2 usage: install jq (apt install jq) for this check" >&2
elif [ -n "$CF_ACCOUNT" ] && [ -n "$CF_TOKEN" ] && r2_due; then
    start="$(date -u +%Y-%m-01T00:00:00Z)"
    end="$(date -u +%FT%TZ)"
    query='query($a: String!, $s: Time!, $e: Time!) { viewer { accounts(filter: {accountTag: $a}) {
        storage: r2StorageAdaptiveGroups(limit: 1000, filter: {datetime_geq: $s, datetime_leq: $e}) {
            max { payloadSize metadataSize } dimensions { bucketName } }
        ops: r2OperationsAdaptiveGroups(limit: 1000, filter: {datetime_geq: $s, datetime_leq: $e}) {
            sum { requests } dimensions { actionType } } } } }'
    body=$(jq -n --arg q "$query" --arg a "$CF_ACCOUNT" --arg s "$start" --arg e "$end"         '{query: $q, variables: {a: $a, s: $s, e: $e}}')
    if answer=$(curl -fsS -m 20 -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json'             -d "$body" https://api.cloudflare.com/client/v4/graphql)         && [ "$(printf '%s' "$answer" | jq '.errors | length')" = 0 ]; then
        # Class A and B as R2's pricing page lists them; deletes and aborts are free.
        usage=$(printf '%s' "$answer" | jq -r '
            .data.viewer.accounts[0] as $acc
            | ([$acc.storage[] | .max.payloadSize + .max.metadataSize] | add // 0) as $bytes
            | ["ListBuckets","PutBucket","ListObjects","PutObject","CopyObject","CompleteMultipartUpload",
               "CreateMultipartUpload","ListMultipartUploads","UploadPart","UploadPartCopy","ListParts",
               "PutBucketEncryption","PutBucketCors","PutBucketLifecycleConfiguration",
               "LifecycleStorageTierTransition"] as $a
            | ["HeadBucket","HeadObject","GetObject","UsageSummary","GetBucketEncryption",
               "GetBucketLocation","GetBucketCors","GetBucketLifecycleConfiguration"] as $b
            | ([$acc.ops[] | select(.dimensions.actionType as $t | $a | index($t)) | .sum.requests] | add // 0) as $ca
            | ([$acc.ops[] | select(.dimensions.actionType as $t | $b | index($t)) | .sum.requests] | add // 0) as $cb
            | "\($bytes) \($ca) \($cb)"')
        read -r bytes class_a class_b <<< "$usage"
        echo "$(now) R2 this month: $(( bytes / 1000000 )) MB stored, $class_a class A, $class_b class B"
        over=""
        [ "$(( bytes * 100 / 10000000000 ))" -ge "$R2_WARN_PCT" ] && over="$over storage $(( bytes / 1000000 )) MB of 10 GB;"
        [ "$(( class_a * 100 / 1000000 ))" -ge "$R2_WARN_PCT" ] && over="$over $class_a of 1.000.000 class A operations;"
        [ "$(( class_b * 100 / 10000000 ))" -ge "$R2_WARN_PCT" ] && over="$over $class_b of 10.000.000 class B operations;"
        if [ -n "$over" ]; then
            report r2-usage fail "R2 is over ${R2_WARN_PCT} % of the free tier this month:$over"
            # Usage only grows within a month: alert on the first run, not the second.
            report r2-usage fail "R2 is over ${R2_WARN_PCT} % of the free tier this month:$over"
        else
            report r2-usage ok ""
        fi
    else
        echo "$(now) R2 usage: Cloudflare's analytics API refused or failed" >&2
    fi
fi
