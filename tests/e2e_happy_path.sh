#!/usr/bin/env bash
# Backup, change the data, backup again, restore-verify the newest one, rotate,
# and check that Prometheus sees healthy metrics with nothing firing.
# Wipes ./data (backups and metrics).
set -euo pipefail

# shellcheck source=tests/e2e_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/e2e_common.sh"

wait_until "postgres is ready" 90 db_ready
wait_until "prometheus is ready" 90 prom_ready
reset_state

scripts/backup.sh
count() { find "$1" -maxdepth 1 -name 'appdb_*.dump' | wc -l | tr -d ' '; }
expect_eq "$(count "$BACKUP_DIR")" 1 "first backup is in the primary directory"
expect_eq "$(count "$SECONDARY_DIR")" 1 "first backup is in the second location"
first=$(basename "$(latest_backup "$BACKUP_DIR")")
expect_eq "$(metric "$METRICS_DIR/backup.prom" backup_last_run_success)" 1 "backup_last_run_success"
expect_eq "$(metric "$METRICS_DIR/backup.prom" backup_secondary_copy_success)" 1 "backup_secondary_copy_success"
[ "$(metric "$METRICS_DIR/backup.prom" backup_size_bytes)" -gt 1000 ] || fail "backup_size_bytes is suspiciously small"
pass "backup_size_bytes is set"

orders_before=$(psql_in "$PG_CONTAINER" "$PG_USER" "$PG_DB" "SELECT count(*) FROM orders")
scripts/add-orders.sh 250
sleep 1 # names carry seconds, two backups in the same second would collide
scripts/backup.sh
second=$(basename "$(latest_backup "$BACKUP_DIR")")
[ "$first" != "$second" ] || fail "second backup did not get a new name"
expect_eq "$(grep '^public.orders ' "$BACKUP_DIR/${second%.dump}.manifest" | cut -d' ' -f2)" "$((orders_before + 250))" "manifest of the newest backup has the new row count"

verify_log=$(mktemp)
scripts/verify-restore.sh 2>"$verify_log" || {
  cat "$verify_log" >&2
  fail "verification of a healthy backup failed"
}
grep -q "verifying $second" "$verify_log" || fail "verification did not pick the newest backup"
pass "verification picked $second and succeeded"
rm -f "$verify_log"
expect_eq "$(metric "$METRICS_DIR/restore_verification.prom" restore_verification_success)" 1 "restore_verification_success"
expect_eq "$(docker ps -a --filter label=brv.role=restore-verify --format '{{.Names}}' | wc -l | tr -d ' ')" 0 "no temporary container left behind"

# Pretend the first backup is old, the next run has to rotate it out of both places.
python3 - "$BACKUP_DIR/$first" "$SECONDARY_DIR/$first" <<'PY'
import os
import sys
old = os.path.getmtime(sys.argv[1]) - 3 * 86400
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY
sleep 1
RETENTION_DAYS=1 MIN_KEEP=1 scripts/backup.sh
for dir in "$BACKUP_DIR" "$SECONDARY_DIR"; do
  if [ -e "$dir/$first" ] || [ -e "$dir/$first.sha256" ] || [ -e "$dir/${first%.dump}.manifest" ]; then
    fail "$first was not rotated out of $dir"
  fi
done
expect_eq "$(count "$BACKUP_DIR")" 2 "rotation left the two newer backups in primary"
expect_eq "$(count "$SECONDARY_DIR")" 2 "rotation left the two newer backups in the second location"

wait_until "prometheus reports restore_verification_success 1" 60 prom_value_is restore_verification_success 1
wait_until "prometheus reports backup_secondary_copy_success 1" 60 prom_value_is backup_secondary_copy_success 1
wait_until "no alert is firing" 60 no_firing_at_all
