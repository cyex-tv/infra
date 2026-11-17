#!/usr/bin/env bash
# Nightly tv-db dump (PLAN.md Phase 9): kept on the host for 14 days and copied off it.
#
# Run from cron or a systemd timer as a user in the docker group, e.g. at 03:30 every night:
#   30 3 * * * /opt/cyextv/infra/backups/backup.sh >> /var/log/cyextv-backup.log 2>&1
#
# Off-host copy: an rclone remote named in CYEXTV_BACKUP_REMOTE (for example
# `r2-backups:cyex-tv-backups`, a separate bucket with its own token, not the CDN bucket).
# Without it the dump stays on the host only, and the script says so.
#
# Encryption: set CYEXTV_BACKUP_AGE_RECIPIENT to an `age` public key (age1...) and only the
# encrypted `.dump.age` is uploaded. The private key stays off the host (see backups/restore-test.sh).
# Without it the plain dump is uploaded as before, and the script warns loudly.
#
# Settings are read from the environment, and from /etc/cyextv/backup.env if that file exists
# (see env/backup.env.example); the file wins.
set -euo pipefail

ENV_FILE="${CYEXTV_BACKUP_ENV:-/etc/cyextv/backup.env}"
if [ -r "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

DIR="${CYEXTV_BACKUP_DIR:-/var/backups/cyextv}"
KEEP_DAYS="${CYEXTV_BACKUP_KEEP_DAYS:-14}"
REMOTE="${CYEXTV_BACKUP_REMOTE:-}"
AGE_RECIPIENT="${CYEXTV_BACKUP_AGE_RECIPIENT:-}"
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

UPLOAD="$FILE"
if [ -n "$AGE_RECIPIENT" ]; then
    command -v age > /dev/null || { echo "$(date -u +%FT%TZ) ERROR: CYEXTV_BACKUP_AGE_RECIPIENT is set but age is not installed" >&2; exit 1; }
    age -r "$AGE_RECIPIENT" -o "$FILE.age.partial" "$FILE"
    mv "$FILE.age.partial" "$FILE.age"
    chmod 600 "$FILE.age"
    UPLOAD="$FILE.age"
    echo "$(date -u +%FT%TZ) encrypted to $UPLOAD"
else
    echo "$(date -u +%FT%TZ) WARNING: CYEXTV_BACKUP_AGE_RECIPIENT not set; the dump is NOT encrypted before upload" >&2
fi

if [ -n "$REMOTE" ]; then
    rclone copy --immutable "$UPLOAD" "$REMOTE/"
    echo "$(date -u +%FT%TZ) copied $(basename "$UPLOAD") to $REMOTE"
else
    echo "$(date -u +%FT%TZ) WARNING: CYEXTV_BACKUP_REMOTE not set; the dump is on this host only" >&2
fi

find "$DIR" \( -name 'cyextv-*.dump' -o -name 'cyextv-*.dump.age' \) -mtime +"$KEEP_DAYS" -delete
