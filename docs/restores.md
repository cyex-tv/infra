# Restore tests

Every run of `backups/restore-test.sh`: when, which dump, the counts it printed, pass or fail.

The scripts run from `/srv/cyex-tv/infra` (backup cron, restore test); the env files they and the
stack read are in `/srv/cyex-tv/infra/env` (`CYEXTV_ENV_DIR`), see `env/README.md`.

| Date | Dump | Accounts | Emotes | Sets | Migration | Result |
|---|---|---|---|---|---|---|
