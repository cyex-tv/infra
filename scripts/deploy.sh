#!/usr/bin/env bash
# Updates cyex.tv with as little slowdown as possible. Run from the infra checkout, as a user in
# the docker group:
#   scripts/deploy.sh            pull both repos, build, swap
#   scripts/deploy.sh --no-pull  build and swap what is checked out (a rollback: check out the
#                                older platform commit first)
# It:
#   1. pulls cyex-tv/platform and this repo (fast-forward only);
#   2. builds the new images while the old containers keep serving. The Rust compiler gets
#      CYEXTV_BUILD_JOBS cores (default 2), so the live api, database and website keep the rest,
#      and cached dependencies mean only the changed crates compile (platform Dockerfile);
#   3. swaps only the containers whose image or settings changed (a few seconds each), so the
#      slow part, the build, happens while the old ones still serve;
#   4. checks api, events and web answer, and removes the old, untagged images.
# A build that fails changes nothing: the running containers stay as they were.
# With s3.env present the CDN profile is included, so tv-s3 and tv-cdn stay up to date too.
# Nothing here touches cyex-api's containers, network, env or tunnel rules.
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(dirname "$INFRA")"
PLATFORM="${PLATFORM_DIR:-$ROOT/platform}"
ENV_DIR="${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}"
JOBS="${CYEXTV_BUILD_JOBS:-2}"
PULL=1
[ "${1:-}" = "--no-pull" ] && PULL=0

step() { printf '\n== %s (%s)\n' "$1" "$(date +%T)"; }
die() { echo "deploy: $1" >&2; exit 1; }

args=(-f "$INFRA/compose/docker-compose.yaml")
[ -f "$ENV_DIR/compose.env" ] && args+=(--env-file "$ENV_DIR/compose.env")
[ -f "$ENV_DIR/s3.env" ] && args+=(--profile cdn)
compose() { PLATFORM_DIR="$PLATFORM" CYEXTV_ENV_DIR="$ENV_DIR" CARGO_BUILD_JOBS="$JOBS" docker compose "${args[@]}" "$@"; }

docker compose version > /dev/null 2>&1 || die "the Docker compose plugin is missing"
[ -d "$PLATFORM/.git" ] || die "no platform checkout at $PLATFORM (run scripts/install.sh first)"

if [ "$PULL" = 1 ]; then
    step "Pull"
    git -C "$INFRA" pull --ff-only
    git -C "$PLATFORM" pull --ff-only
fi
echo "platform $(git -C "$PLATFORM" rev-parse --short HEAD), infra $(git -C "$INFRA" rev-parse --short HEAD)"

step "Build (the site keeps running on the old images; $JOBS compiler cores)"
start=$(date +%s)
CYEX_TV_BUILD_SHA="$(git -C "$PLATFORM" rev-parse --short=12 HEAD)" compose build
echo "built in $(( $(date +%s) - start )) s"

step "Swap"
# Only containers whose image or settings changed are recreated; the rest keep running.
compose up -d --no-build

step "Check"
wait_for() {
    local name=$1 url=$2
    for _ in $(seq 1 60); do
        curl -fs -m 3 -o /dev/null "$url" && { echo "$name answers"; return 0; }
        sleep 2
    done
    echo "$name doesn't answer at $url; logs: docker compose -f compose/docker-compose.yaml logs $name" >&2
    return 1
}
ok=1
wait_for api http://127.0.0.1:8080/health/ready || ok=0
wait_for events http://127.0.0.1:8081/health || ok=0
wait_for web http://127.0.0.1:8082/developers || ok=0
[ "$ok" = 1 ] || die "a service didn't come back"

# The images the swap replaced are now untagged; the build cache (cargo and npm) is kept.
docker image prune -f > /dev/null
echo "deployed in $(( $(date +%s) - start )) s"
