#!/usr/bin/env bash
# Nightly tv-db dump (PLAN.md Phase 9): kept on the host for 14 days and copied off it.
#
# Run from cron or a systemd timer as a user in the docker group, e.g. at 03:30 every night:
#   30 3 * * * /opt/cyextv/infra/backups/backup.sh >> /var/log/cyextv-backup.log 2>&1
#
# Off-host copy: an rclone remote named in CYEXTV_BACKUP_REMOTE (for example
# `r2-backups:cyex-tv-backups`, a separate bucket with its own token, not the CDN bucket).
# Without it the dump stays on the host only, and the script says so.
set -euo pipefail

DIR="${CYEXTV_BACKUP_DIR:-/var/backups/cyextv}"
KEEP_DAYS="${CYEXTV_BACKUP_KEEP_DAYS:-14}"
REMOTE="${CYEXTV_BACKUP_REMOTE:-}"
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
FILE="$DIR/cyextv-$STAMP.dump"

mkdir -p "$DIR"
chmod 700 "$DIR"

# Custom format: compressed, and pg_restore can pick tables from it.
docker exec cyextv-db \
    sh -c 'pg_dump --format=custom --no-owner -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$FILE.partial"
mv "$FILE.partial" "$FILE"
chmod 600 "$FILE"

# A dump that pg_restore can't list is no backup.
docker exec -i cyextv-db pg_restore --list < "$FILE" > /dev/null
echo "$(date -u +%FT%TZ) dumped $(du -h "$FILE" | cut -f1) to $FILE"

if [ -n "$REMOTE" ]; then
    rclone copy --immutable "$FILE" "$REMOTE/"
    echo "$(date -u +%FT%TZ) copied to $REMOTE"
else
    echo "$(date -u +%FT%TZ) WARNING: CYEXTV_BACKUP_REMOTE not set; the dump is on this host only" >&2
fi

find "$DIR" -name 'cyextv-*.dump' -mtime +"$KEEP_DAYS" -delete
