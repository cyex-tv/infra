#!/usr/bin/env bash
# Checks the env files before a start: every required value set, no placeholders left, the
# database password the same everywhere, the R2 keys the same for api and worker.
#   scripts/preflight.sh [dir]     (default $CYEXTV_ENV_DIR, else /srv/cyex-tv/infra/env)
#   scripts/preflight.sh --git-only   just the "no env file is tracked by git" check
# Prints the names of what's wrong, never the values. Exit 1 if anything required is missing.
set -uo pipefail
INFRA="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
warn=0

# The real env files sit inside this git checkout (env/). Anything tracked there other than the
# examples and the README is a secret about to be committed: fail loudly.
tracked=$(git -c safe.directory="$INFRA" -C "$INFRA" ls-files env/ 2>/dev/null | grep -vE '^env/(README\.md|[^/]+\.example)$' || true)
if [ -n "$tracked" ]; then
    echo "FATAL    git tracks files in env/ that aren't examples (secrets in the repo?):" >&2
    echo "$tracked" | sed 's/^/           /' >&2
    echo "         remove them with: git rm --cached <file>, and rotate the secrets they held" >&2
    fail=1
fi
if [ "${1:-}" = "--git-only" ]; then exit "$fail"; fi
DIR="${1:-${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}}"

bad() { echo "MISSING  $1"; fail=1; }
soft() { echo "optional $1"; warn=1; }

# value FILE NAME: the last assignment of NAME in FILE, quotes stripped.
value() {
    [ -r "$DIR/$1" ] || return 1
    sed -n "s/^[[:space:]]*$2=//p" "$DIR/$1" | tail -n 1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

need() {
    local file=$1 name=$2 v
    if [ ! -r "$DIR/$file" ]; then bad "$file (the file itself)"; return; fi
    v=$(value "$file" "$name")
    if [ -z "$v" ]; then bad "$file: $name"
    elif [[ "$v" == *"<"* ]]; then bad "$file: $name still has a <placeholder>"
    fi
}

for f in db.env api.env events.env worker.env; do
    [ -r "$DIR/$f" ] || bad "$f (the file itself)"
done

need db.env POSTGRES_DB
need db.env POSTGRES_USER
need db.env POSTGRES_PASSWORD
for f in api.env events.env worker.env; do need "$f" CYEX_TV_DATABASE_URL; done
for n in CYEX_TV_TWITCH_CLIENT_ID CYEX_TV_TWITCH_CLIENT_SECRET CYEX_TV_KICK_CLIENT_ID \
    CYEX_TV_KICK_CLIENT_SECRET CYEX_TV_OWNER_IDS; do
    need api.env "$n"
done
for f in api.env worker.env; do
    for n in CYEX_TV_S3_ENDPOINT CYEX_TV_S3_BUCKET CYEX_TV_S3_ACCESS_KEY_ID \
        CYEX_TV_S3_SECRET_ACCESS_KEY; do
        need "$f" "$n"
    done
done

# The database URLs carry the same user, password and database as db.env.
if [ -r "$DIR/db.env" ]; then
    want="postgres://$(value db.env POSTGRES_USER):$(value db.env POSTGRES_PASSWORD)@tv-db:5432/$(value db.env POSTGRES_DB)"
    for f in api.env events.env worker.env; do
        [ -r "$DIR/$f" ] || continue
        [ "$(value "$f" CYEX_TV_DATABASE_URL)" = "$want" ] \
            || bad "$f: CYEX_TV_DATABASE_URL doesn't match db.env (user, password, host tv-db, database)"
    done
fi

# api and worker write to the same bucket with the same key.
for n in CYEX_TV_S3_ENDPOINT CYEX_TV_S3_BUCKET CYEX_TV_S3_ACCESS_KEY_ID CYEX_TV_S3_SECRET_ACCESS_KEY; do
    a=$(value api.env "$n"); w=$(value worker.env "$n")
    [ -n "$a" ] && [ -n "$w" ] && [ "$a" != "$w" ] && bad "api.env and worker.env differ in $n"
done

endpoint=$(value api.env CYEX_TV_S3_ENDPOINT)
[ -z "$endpoint" ] || [[ "$endpoint" =~ ^http://tv-s3:7070/?$ ]] \
    || [[ "$endpoint" =~ ^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com/?$ ]] \
    || bad "api.env: CYEX_TV_S3_ENDPOINT isn't http://tv-s3:7070 (self-hosted) or https://<32 hex account id>.r2.cloudflarestorage.com"
selfhosted=0
[[ "$endpoint" =~ ^http://tv-s3:7070/?$ ]] && selfhosted=1

# The self-hosted CDN has its own root keys, and they are the keys the api and worker use.
if [ "$selfhosted" = 1 ]; then
    need s3.env ROOT_ACCESS_KEY
    need s3.env ROOT_SECRET_KEY
    [ "$(value s3.env ROOT_ACCESS_KEY)" = "$(value api.env CYEX_TV_S3_ACCESS_KEY_ID)" ] \
        || bad "s3.env ROOT_ACCESS_KEY differs from api.env CYEX_TV_S3_ACCESS_KEY_ID"
    [ "$(value s3.env ROOT_SECRET_KEY)" = "$(value api.env CYEX_TV_S3_SECRET_ACCESS_KEY)" ] \
        || bad "s3.env ROOT_SECRET_KEY differs from api.env CYEX_TV_S3_SECRET_ACCESS_KEY"
fi
owners=$(value api.env CYEX_TV_OWNER_IDS)
[ -z "$owners" ] || [[ "$owners" =~ ^((twitch|kick):[0-9]+|[0-9A-Z]{26})(,((twitch|kick):[0-9]+|[0-9A-Z]{26}))*$ ]] \
    || bad "api.env: CYEX_TV_OWNER_IDS isn't twitch:<id>,kick:<id>"

# Optional, but say so. The purge only matters while cdn.cyex.tv sits behind Cloudflare's cache.
[ "$selfhosted" = 1 ] || [ -n "$(value worker.env CYEX_TV_CLOUDFLARE_PURGE_TOKEN)" ] \
    || soft "worker.env: CYEX_TV_CLOUDFLARE_PURGE_TOKEN (takedowns won't purge the CDN)"
[ "$selfhosted" = 1 ] || [ -n "$(value worker.env CYEX_TV_CLOUDFLARE_ZONE_ID)" ] \
    || soft "worker.env: CYEX_TV_CLOUDFLARE_ZONE_ID (takedowns won't purge the CDN)"
[ -r "$DIR/check.env" ] && [ -n "$(value check.env CYEXTV_ALERT_WEBHOOK)" ] \
    || soft "check.env: CYEXTV_ALERT_WEBHOOK (alerts only go to the log)"

# Secrets readable by everyone are a mistake.
for f in "$DIR"/*.env; do
    [ -e "$f" ] || continue
    perms=$(stat -c '%a' "$f" 2>/dev/null || echo 600)
    [ "${perms: -1}" = 0 ] || bad "$(basename "$f") is readable by everyone (chmod 640)"
done

if [ "$fail" = 0 ]; then
    echo "preflight: ok$([ "$warn" = 1 ] && echo ', with optional values missing (above)')"
else
    echo "preflight: fix the MISSING lines above, then run it again"
fi
exit "$fail"
