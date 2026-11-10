#!/usr/bin/env bash
# Restores the newest backup into a throwaway Postgres and compares the result
# with the manifest taken when the backup was made. Usage: verify-restore.sh [dump]
#
# Exit codes: 0 ok, 10 no backup, 11 checksum/manifest problem, 12 restore failed,
# 13 restored data differs from the manifest, 14 second copy missing or different.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LOG_TAG=verify

prom=$METRICS_DIR/restore_verification.prom
start=$SECONDS
ok=0
last_success=$(prom_prev "$prom" restore_verification_last_success_timestamp_seconds 0)
container=""
work=""

# shellcheck disable=SC2317 # only called through the EXIT trap
report() {
  local rc=$? now
  trap - EXIT
  if [ -n "$container" ]; then
    docker rm -fv "$container" >/dev/null 2>&1 || log "could not remove $container, remove it by hand"
  fi
  if [ -n "$work" ]; then rm -rf "$work"; fi
  now=$(date +%s)
  if [ "$ok" = 1 ]; then last_success=$now; fi
  {
    gauge restore_verification_success "1 if the last verification restored the newest backup and the data matched." "$ok"
    gauge restore_verification_duration_seconds "Wall time of the last verification." "$((SECONDS - start))"
    gauge restore_verification_last_run_timestamp_seconds "Unix time the last verification finished." "$now"
    gauge restore_verification_last_success_timestamp_seconds "Unix time of the last successful verification." "$last_success"
  } | write_prom "$prom" || log "could not write $prom"
  exit "$rc"
}
trap report EXIT

# Containers left behind by a run that was killed. A live pid in the name
# means another verification is in progress, so those are left alone.
remove_leftovers() {
  local c
  for c in $(docker ps -a --filter label=brv.role=restore-verify --format '{{.Names}}'); do
    if ! kill -0 "${c##*-}" 2>/dev/null; then
      log "removing leftover $c"
      docker rm -fv "$c" >/dev/null || true
    fi
  done
}

dump=${1:-$(latest_backup "$BACKUP_DIR")}
{ [ -n "$dump" ] && [ -f "$dump" ]; } || die 10 "no backup found in $BACKUP_DIR"
manifest=${dump%.dump}.manifest
log "verifying $(basename "$dump")"

rc=0
checksum_ok "$dump" || rc=$?
case $rc in
  0) ;;
  2) die 11 "$(basename "$dump").sha256 is missing" ;;
  *) die 11 "checksum mismatch for $(basename "$dump")" ;;
esac
[ -f "$manifest" ] || die 11 "$(basename "$manifest") is missing"

# A second copy that quietly rotted is the usual way 3-2-1 fails, so look at it every time.
if [ -n "$SECONDARY_DIR" ]; then
  second=$SECONDARY_DIR/$(basename "$dump")
  [ -f "$second" ] || die 14 "$second is missing"
  [ "$(sha256_of "$second")" = "$(awk '{print $1; exit}' "$dump.sha256")" ] ||
    die 14 "checksum mismatch for the copy in $SECONDARY_DIR"
fi

image=${VERIFY_IMAGE:-}
if [ -z "$image" ]; then
  image=$(docker inspect -f '{{.Config.Image}}' "$PG_CONTAINER") ||
    die 12 "cannot tell which image to restore into, set VERIFY_IMAGE"
fi

remove_leftovers
work=$(mktemp -d)
container=brv-verify-$$

# No network on purpose: the restore target must not be able to reach the real database.
log "starting $container from $image"
docker run -d --name "$container" --label brv.role=restore-verify --network none \
  -e POSTGRES_PASSWORD=throwaway -e POSTGRES_DB=restore_check "$image" >/dev/null ||
  die 12 "could not start the temporary container"

# Over TCP, because during first start the image runs a server that listens on the socket only.
for _ in $(seq 1 60); do
  docker exec "$container" pg_isready -q -h 127.0.0.1 -U postgres -d restore_check && break
  sleep 1
done
docker exec "$container" pg_isready -q -h 127.0.0.1 -U postgres -d restore_check ||
  die 12 "temporary postgres did not become ready"

log "restoring"
docker exec -i "$container" pg_restore -U postgres -d restore_check \
  --no-owner --no-privileges --exit-on-error <"$dump" 2>"$work/restore.err" || {
  head -n 5 "$work/restore.err" >&2
  die 12 "pg_restore failed"
}

control_manifest "$container" postgres restore_check >"$work/actual" ||
  die 13 "could not read the control tables from the restored database"
if ! diff -u "$manifest" "$work/actual" >"$work/diff"; then
  sed 's/^/    /' "$work/diff" >&2
  die 13 "restored data does not match the manifest"
fi

ok=1
log "ok, $(wc -l <"$manifest" | tr -d ' ') tables match (rows and data checksum)"
