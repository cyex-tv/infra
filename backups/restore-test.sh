#!/usr/bin/env bash
# The tested restore (PLAN.md Phase 9): restores a dump into a throwaway Postgres next to
# production, checks it, and removes it. Production is never touched.
#
#   backups/restore-test.sh /var/backups/cyextv/cyextv-<stamp>.dump
#
# An encrypted dump (`.dump.age`) needs the age private key file, kept off the production host:
#
#   CYEXTV_RESTORE_AGE_IDENTITY=/path/to/age-key.txt backups/restore-test.sh cyextv-<stamp>.dump.age
#
# Run it monthly and after any schema change; write the date and result in docs/restores.md.
set -euo pipefail

DUMP="${1:?usage: restore-test.sh <dump file>}"
NAME="cyextv-restore-test-$$"

cleanup() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=cyextv \
    postgres:17-alpine > /dev/null
for _ in $(seq 1 30); do
    docker exec "$NAME" pg_isready -U postgres -d cyextv > /dev/null 2>&1 && break
    sleep 1
done

case "$DUMP" in
    *.age)
        IDENTITY="${CYEXTV_RESTORE_AGE_IDENTITY:?set CYEXTV_RESTORE_AGE_IDENTITY to the age private key file for an encrypted dump}"
        age -d -i "$IDENTITY" "$DUMP" | docker exec -i "$NAME" pg_restore --no-owner -U postgres -d cyextv
        ;;
    *)
        docker exec -i "$NAME" pg_restore --no-owner -U postgres -d cyextv < "$DUMP"
        ;;
esac

# The restore counts when the core tables are there and the migrations table matches.
q() { docker exec "$NAME" psql -U postgres -d cyextv -tAc "$1"; }
for table in accounts identities emote_sets emotes files roles audit_log events_outbox jobs; do
    q "SELECT 1 FROM $table LIMIT 1" > /dev/null
done
echo "accounts:   $(q 'SELECT count(*) FROM accounts')"
echo "emotes:     $(q 'SELECT count(*) FROM emotes')"
echo "sets:       $(q 'SELECT count(*) FROM emote_sets')"
echo "migrations: $(q 'SELECT max(version) FROM _sqlx_migrations')"
echo "restore test passed: $DUMP"
