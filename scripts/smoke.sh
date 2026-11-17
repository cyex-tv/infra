#!/usr/bin/env bash
# The public smoke test after a deploy. Runs from any machine with bash and curl:
#   scripts/smoke.sh
# Every line is PASS or FAIL with what was expected. Exit 1 if anything failed.
set -uo pipefail
API="${API:-https://api.cyex.tv}"
SITE="${SITE:-https://cyex.tv}"
CDN="${CDN:-https://cdn.cyex.tv}"
failed=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@"; }

# Health
[ "$(code "$API/health")" = 200 ] && pass "api /health" || fail "api /health (want 200)"
[ "$(code "$API/health/ready")" = 200 ] && pass "api /health/ready (database reachable)" \
    || fail "api /health/ready (want 200: is tv-db up?)"

# Website
[ "$(code "$SITE/")" = 200 ] && pass "site /" || fail "site / (want 200)"
[ "$(code "$SITE/developers")" = 200 ] && pass "site /developers" || fail "site /developers (want 200)"
www=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "https://www.${SITE#https://}/emotes")
[[ "$www" == "301 $SITE/emotes"* ]] && pass "www redirects to $SITE" \
    || fail "www.${SITE#https://} (want 301 to $SITE/emotes, got: $www)"

# Public reads
body=$(curl -fs -m 15 "$API/v1/sets/global") && [[ "$body" == *'"emotes"'* ]] \
    && pass "REST /v1/sets/global" || fail "REST /v1/sets/global (want 200 with emotes)"
gql=$(curl -s -m 15 -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}' "$API/v1/gql")
[[ "$gql" == *'"__typename":"Query"'* ]] && pass "GraphQL /v1/gql" || fail "GraphQL /v1/gql (got: ${gql:0:120})"

# CORS for the site
allow=$(curl -s -o /dev/null -D - -m 15 -X OPTIONS "$API/v1/gql" \
    -H "Origin: $SITE" -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
[ "$allow" = "$SITE" ] && pass "CORS lets $SITE call the API" || fail "CORS for $SITE (got: ${allow:-none})"

# Sign-in redirects: the OAuth clients are configured.
for p in twitch kick; do
    loc=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "$API/v1/auth/$p/login")
    case "$p:$loc" in
        twitch:"302 https://id.twitch.tv/oauth2/authorize?"*client_id=[^\&]*) pass "sign-in with Twitch redirects to Twitch" ;;
        kick:"302 https://id.kick.com/oauth/authorize?"*client_id=[^\&]*) pass "sign-in with Kick redirects to Kick" ;;
        *) fail "sign-in with $p (want 302 to its consent page with a client_id; got: ${loc:0:100}; 503 means the client isn't configured)" ;;
    esac
done

# The event socket upgrades (101).
ws=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --http1.1 "$API/v1/events" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: c21va2UtdGVzdC1rZXkxMg==')
[ "$ws" = 101 ] && pass "event socket upgrades" || fail "event socket (want 101, got $ws: is the /v1/events tunnel rule first?)"

# The CDN
[ "$(code "$CDN/emotes/smoke-test/2x.webp")" = 404 ] && pass "CDN /emotes reaches R2" \
    || fail "CDN /emotes (want 404 for a missing file)"
[ "$(code "$CDN/originals/smoke-test")" = 403 ] && pass "CDN /originals is blocked" \
    || fail "CDN /originals (want 403: the WAF rule)"
cors=$(curl -s -o /dev/null -D - -m 15 -H 'Origin: https://www.twitch.tv' "$CDN/emotes/smoke-test/2x.webp" \
    | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)
[ "$cors" = '*' ] && pass "CDN CORS" || fail "CDN CORS (want *, got: ${cors:-none})"

echo
[ "$failed" = 0 ] && echo "smoke: all passed" || echo "smoke: something failed (above)"
exit "$failed"
