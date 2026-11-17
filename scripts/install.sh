#!/usr/bin/env bash
# First install, or an update, of cyex.tv on the host. Run with sudo from the infra checkout:
#   sudo scripts/install.sh [env dir]
# The env dir (default ./etc-cyextv next to where you run it, else /etc/cyextv as it is) holds
# db.env, api.env, events.env, worker.env and optionally check.env. It:
#   1. checks the tools (docker with compose, git, curl);
#   2. clones or updates cyex-tv/platform next to this repo;
#   3. installs the env files to /etc/cyextv (root:docker, 640) and runs the preflight;
#   4. builds and starts the stack, and waits until api, events and web answer;
#   5. installs the nightly backup and the 5-minute check in the invoking user's crontab.
# Nothing here touches cyex-api's containers, network, env or tunnel rules.
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(dirname "$INFRA")"
PLATFORM="${PLATFORM_DIR:-$ROOT/platform}"
SRC="${1:-$PWD/etc-cyextv}"
ETC=/etc/cyextv
USER_NAME="${SUDO_USER:-$USER}"

step() { printf '\n== %s\n' "$1"; }
die() { echo "install: $1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo"

step "Tools"
command -v docker > /dev/null || die "Docker isn't installed (https://docs.docker.com/engine/install/)"
docker compose version > /dev/null 2>&1 || die "the Docker compose plugin is missing"
command -v git > /dev/null || die "git is missing (apt install git)"
command -v curl > /dev/null || die "curl is missing (apt install curl)"
command -v jq > /dev/null || echo "note: jq is missing; the optional R2 usage check needs it (apt install jq)"
command -v rclone > /dev/null || echo "note: rclone is missing; backups stay on this host until it's set up (docs/restores.md)"
id -nG "$USER_NAME" | grep -qw docker || echo "note: $USER_NAME isn't in the docker group; cron jobs need it (usermod -aG docker $USER_NAME)"
echo "ok"

step "Platform checkout ($PLATFORM)"
if [ -d "$PLATFORM/.git" ]; then
    sudo -u "$USER_NAME" git -C "$PLATFORM" pull --ff-only
else
    sudo -u "$USER_NAME" git clone https://github.com/cyex-tv/platform "$PLATFORM"
fi
git -C "$PLATFORM" log -1 --format='%h %s'

step "Env files ($ETC)"
mkdir -p "$ETC"
if [ -d "$SRC" ] && [ "$(cd "$SRC" && pwd)" != "$ETC" ]; then
    for f in db.env api.env events.env worker.env check.env; do
        [ -f "$SRC/$f" ] && install -m 640 -o root -g docker "$SRC/$f" "$ETC/$f" && echo "installed $f"
    done
else
    echo "using $ETC as it is"
fi
chown root:docker "$ETC"
chmod 750 "$ETC"
"$INFRA/scripts/preflight.sh" "$ETC" || die "the preflight failed; fix the env files and run this again"

step "Build and start (the first build takes a while)"
cd "$INFRA"
PLATFORM_DIR="$PLATFORM" docker compose -f compose/docker-compose.yaml up -d --build

step "Waiting for the services"
wait_for() {
    local name=$1 url=$2
    for _ in $(seq 1 60); do
        curl -fs -m 3 "$url" > /dev/null && { echo "$name answers"; return 0; }
        sleep 2
    done
    echo "$name doesn't answer at $url; logs: docker compose -f compose/docker-compose.yaml logs $name" >&2
    return 1
}
ok=1
wait_for api http://127.0.0.1:8080/health/ready || ok=0
wait_for events http://127.0.0.1:8081/health || ok=0
wait_for web http://127.0.0.1:8082/developers || ok=0
[ "$ok" = 1 ] || die "a service didn't start"

step "Cron: the nightly backup and the 5-minute check"
mkdir -p /var/backups/cyextv /var/lib/cyextv-check
chown "$USER_NAME" /var/backups/cyextv /var/lib/cyextv-check
touch /var/log/cyextv-backup.log /var/log/cyextv-check.log
chown "$USER_NAME" /var/log/cyextv-backup.log /var/log/cyextv-check.log
current=$(sudo -u "$USER_NAME" crontab -l 2>/dev/null || true)
add=""
grep -q 'backups/backup.sh' <<< "$current" \
    || add+="30 3 * * * $INFRA/backups/backup.sh >> /var/log/cyextv-backup.log 2>&1"$'\n'
grep -q 'monitoring/check.sh' <<< "$current" \
    || add+="*/5 * * * * $INFRA/monitoring/check.sh >> /var/log/cyextv-check.log 2>&1"$'\n'
if [ -n "$add" ]; then
    printf '%s\n%s' "$current" "$add" | sed '/^$/d' | sudo -u "$USER_NAME" crontab -
    echo "added to $USER_NAME's crontab"
else
    echo "already there"
fi

step "Done"
cat <<MSG
The stack runs on 127.0.0.1:8080 (api), 8081 (events) and 8082 (web).
Next:
  1. Tunnel hostnames: docs/tunnel.md (api.cyex.tv, cyex.tv, the www redirect).
  2. From anywhere: scripts/smoke.sh
  3. The first manual test: docs/first-sweep.md
MSG
