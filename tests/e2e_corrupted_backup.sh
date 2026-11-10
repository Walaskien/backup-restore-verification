#!/usr/bin/env bash
# Three ways a backup can be bad. Each one has to fail the verification with
# its own exit code and put restore_verification_success at 0. The first also
# has to make Prometheus fire RestoreVerificationFailed, and a good backup
# afterwards has to clear it again. Wipes ./data (backups and metrics).
set -euo pipefail

# shellcheck source=tests/e2e_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/e2e_common.sh"

wait_until "postgres is ready" 90 db_ready
wait_until "prometheus is ready" 90 prom_ready
reset_state

scripts/backup.sh
good=$(latest_backup "$BACKUP_DIR")
prom=$METRICS_DIR/restore_verification.prom

scripts/verify-restore.sh
expect_eq "$(metric "$prom" restore_verification_success)" 1 "healthy backup verifies"
last_good=$(metric "$prom" restore_verification_last_success_timestamp_seconds)
wait_until "healthy state reaches prometheus" 60 prom_value_is restore_verification_success 1
not_firing RestoreVerificationFailed || fail "alert fires on a healthy backup"

# A "newer" copy of the good backup that the cases below then damage.
bad=appdb_29990101T000000Z
clone_good() {
  for dir in "$BACKUP_DIR" "$SECONDARY_DIR"; do
    cp "$good" "$dir/$bad.dump"
    cp "$good.sha256" "$dir/$bad.dump.sha256"
    cp "${good%.dump}.manifest" "$dir/$bad.manifest"
  done
}
reseal() { # recompute the checksum after the dump was changed, and refresh the second copy
  printf '%s  %s\n' "$(sha256_of "$BACKUP_DIR/$bad.dump")" "$bad.dump" >"$BACKUP_DIR/$bad.dump.sha256"
  cp "$BACKUP_DIR/$bad.dump" "$BACKUP_DIR/$bad.dump.sha256" "$SECONDARY_DIR/"
}
drop_bad() { rm -f "$BACKUP_DIR/$bad".* "$SECONDARY_DIR/$bad".*; }

check_fails() { # expected_exit description
  local rc=0
  scripts/verify-restore.sh 2>"$ROOT/data/last-verify.log" || rc=$?
  expect_eq "$rc" "$1" "$2: exit code"
  expect_eq "$(metric "$prom" restore_verification_success)" 0 "$2: restore_verification_success is 0"
  expect_eq "$(metric "$prom" restore_verification_last_success_timestamp_seconds)" "$last_good" "$2: last success timestamp not touched"
}

# 1. A few bytes flipped in storage. The checksum on file no longer matches.
clone_good
printf '\377\377\377\377' | dd of="$BACKUP_DIR/$bad.dump" bs=1 seek=5000 conv=notrunc 2>/dev/null
check_fails 11 "flipped bytes"
wait_until "RestoreVerificationFailed is firing" 60 firing RestoreVerificationFailed
drop_bad

# 2. Damaged before the checksum was taken (so the checksum is "right"): only an actual restore finds it.
clone_good
size=$(wc -c <"$good" | tr -d ' ')
head -c "$((size / 2))" "$good" >"$BACKUP_DIR/$bad.dump"
reseal
check_fails 12 "truncated dump with a matching checksum"
grep -q 'pg_restore failed' "$ROOT/data/last-verify.log" || fail "expected pg_restore to be the one that failed"
drop_bad

# 3. Restores cleanly but is not the data the manifest was taken from: a dump of
# a copy of the database that lost some payments.
docker exec -e PGOPTIONS="-c client_min_messages=warning" "$PG_CONTAINER" \
  psql -U "$PG_USER" -d postgres -X -q -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS appdb_forged" -c "CREATE DATABASE appdb_forged TEMPLATE $PG_DB"
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d appdb_forged -X -q -v ON_ERROR_STOP=1 \
  -c "DELETE FROM payments WHERE id % 10 = 0"
clone_good
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d appdb_forged --format=custom --compress=6 >"$BACKUP_DIR/$bad.dump"
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -X -q -c "DROP DATABASE appdb_forged"
reseal
check_fails 13 "dump that restores but holds different data"
grep -q '^    +public.payments ' "$ROOT/data/last-verify.log" || fail "diff in the log does not show the payments table"
drop_bad

# Back to a good backup: the failure has to go away on its own.
scripts/verify-restore.sh
expect_eq "$(metric "$prom" restore_verification_success)" 1 "good backup verifies again"
wait_until "RestoreVerificationFailed has cleared" 60 not_firing RestoreVerificationFailed
