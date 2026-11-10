#!/usr/bin/env bash
# Dump, checksum, note what the control tables look like, copy to the second
# location, rotate, and leave the result for node_exporter in backup.prom.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LOG_TAG=backup

prom=$METRICS_DIR/backup.prom
start=$SECONDS
ok=0
copy_ok=0
last_ts=$(prom_prev "$prom" backup_last_success_timestamp_seconds 0)
size=$(prom_prev "$prom" backup_size_bytes 0)
work=""

# shellcheck disable=SC2317 # only called through the EXIT trap
report() {
  local rc=$?
  trap - EXIT
  if [ -n "$work" ]; then rm -rf "$work"; fi
  {
    gauge backup_last_run_success "1 if the last run produced a verified dump in the primary directory." "$ok"
    gauge backup_last_success_timestamp_seconds "Unix time of the last successful backup." "$last_ts"
    gauge backup_size_bytes "Size of the newest dump." "$size"
    gauge backup_duration_seconds "Wall time of the last run." "$((SECONDS - start))"
    if [ -n "$SECONDARY_DIR" ]; then
      gauge backup_secondary_copy_success "1 if the newest dump was copied to the second location and its checksum matched there." "$copy_ok"
    fi
  } | write_prom "$prom" || log "could not write $prom"
  exit "$rc"
}
trap report EXIT

copy_backup() {
  local name=$1 tmp
  # No mkdir -p here on purpose. If the second disk is not mounted we want a
  # failure, not a quiet copy onto the first one.
  [ -d "$SECONDARY_DIR" ] || {
    log "$SECONDARY_DIR does not exist"
    return 1
  }
  tmp=$(mktemp -d "$SECONDARY_DIR/.work.XXXXXX") || return 1
  if cp -p "$BACKUP_DIR/$name.dump" "$BACKUP_DIR/$name.dump.sha256" "$BACKUP_DIR/$name.manifest" "$tmp/" &&
    checksum_ok "$tmp/$name.dump" &&
    mv "$tmp/$name.dump.sha256" "$tmp/$name.manifest" "$SECONDARY_DIR/" &&
    mv "$tmp/$name.dump" "$SECONDARY_DIR/"; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -qx true ||
  die 10 "container $PG_CONTAINER is not running"

mkdir -p "$BACKUP_DIR"
name=${PG_DB}_$(date -u +%Y%m%dT%H%M%SZ)
[ ! -e "$BACKUP_DIR/$name.dump" ] || die 14 "$name.dump already exists, refusing to overwrite"
work=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")

log "dumping $PG_DB from $PG_CONTAINER"
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --format=custom --compress=6 \
  >"$work/$name.dump" || die 11 "pg_dump failed"
[ -s "$work/$name.dump" ] || die 11 "pg_dump wrote an empty file"

printf '%s  %s\n' "$(sha256_of "$work/$name.dump")" "$name.dump" >"$work/$name.dump.sha256"
control_manifest "$PG_CONTAINER" "$PG_USER" "$PG_DB" >"$work/$name.manifest" ||
  die 12 "could not read the control tables"

# The dump goes last: verify-restore.sh finds backups by *.dump, so it must
# never see one whose checksum or manifest is not there yet.
mv "$work/$name.dump.sha256" "$work/$name.manifest" "$BACKUP_DIR/"
mv "$work/$name.dump" "$BACKUP_DIR/"

# Read it back from disk, the checksum above was taken before the move.
checksum_ok "$BACKUP_DIR/$name.dump" || die 11 "checksum of $name.dump does not match what is on disk"

size=$(wc -c <"$BACKUP_DIR/$name.dump" | tr -d ' ')
last_ts=$(date +%s)
ok=1
log "wrote $name.dump ($size bytes)"

rc=0
if [ -n "$SECONDARY_DIR" ]; then
  if copy_backup "$name"; then
    copy_ok=1
    log "copied to $SECONDARY_DIR"
  else
    log "copy to $SECONDARY_DIR failed"
    rc=13
  fi
fi

rotate_backups "$BACKUP_DIR" "$RETENTION_DAYS" "$MIN_KEEP"
if [ -n "$SECONDARY_DIR" ]; then rotate_backups "$SECONDARY_DIR" "$RETENTION_DAYS" "$MIN_KEEP"; fi

exit "$rc"
