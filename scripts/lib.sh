# shellcheck shell=bash
# Sourced by backup.sh and verify-restore.sh. Kept to bash 3.2 features
# because the scripts also get run on a Mac.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

: "${PG_CONTAINER:=brv-postgres}"
: "${PG_USER:=app}"
: "${PG_DB:=appdb}"
: "${VERIFY_TABLES:=public.customers public.orders public.payments}"
: "${DATA_DIR:=$REPO_ROOT/data}"
: "${BACKUP_DIR:=$DATA_DIR/backups/primary}"
# Set SECONDARY_DIR to an empty string to run without a second copy.
: "${SECONDARY_DIR=$DATA_DIR/backups/secondary}"
: "${METRICS_DIR:=$DATA_DIR/metrics}"
: "${RETENTION_DAYS:=7}"
: "${MIN_KEEP:=3}"

# Same session settings on the source and on the restored copy, otherwise
# timestamps would print differently and the checksums could never match.
PSQL_OPTS="-c TimeZone=UTC -c DateStyle=ISO,MDY -c extra_float_digits=3"

log() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-brv}" "$*" >&2
}

die() {
  local code=$1
  shift
  log "$*"
  exit "$code"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 0 = matches the .sha256 next to it, 1 = does not match, 2 = no .sha256 file
checksum_ok() {
  local want got
  [ -f "$1.sha256" ] || return 2
  want=$(awk '{print $1; exit}' "$1.sha256")
  got=$(sha256_of "$1")
  [ -n "$want" ] && [ "$want" = "$got" ]
}

latest_backup() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -type f -name "${PG_DB}_*.dump" | sort | tail -n 1
}

# Age is taken from mtime. The newest MIN_KEEP files are never removed, so a
# long stretch of failed runs cannot rotate away the last good backups.
rotate_backups() {
  local dir=$1 days=$2 keep=$3 f
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name "${PG_DB}_*.dump" | sort -r | tail -n +"$((keep + 1))" |
    while IFS= read -r f; do
      if [ -n "$(find "$f" -mmin +"$((days * 1440))")" ]; then
        rm -f "$f" "$f.sha256" "${f%.dump}.manifest"
        log "rotated out $(basename "$f") from $dir"
      fi
    done
  find "$dir" -maxdepth 1 -name '.work.*' -mmin +1440 -exec rm -rf {} +
}

# node_exporter reads the directory at any moment, so the file has to appear
# in one piece. It runs as another user, hence the chmod (mktemp gives 0600).
write_prom() {
  local target=$1 tmp
  mkdir -p "$(dirname "$target")"
  tmp=$(mktemp "$target.XXXXXX") || return 1
  if cat >"$tmp" && chmod 644 "$tmp" && mv "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

gauge() {
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$2" "$1" "$1" "$3"
}

# Value of an unlabelled metric from an earlier .prom file, or the fallback.
prom_prev() {
  local v=
  if [ -f "$1" ]; then
    v=$(awk -v m="$2" '$1 == m {print $2; exit}' "$1")
  fi
  printf '%s' "${v:-$3}"
}

valid_table() {
  case $1 in
    "" | *[!A-Za-z0-9_.]*) return 1 ;;
  esac
  return 0
}

quote_table() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\./"."/g')"
}

psql_in() {
  docker exec -e PGOPTIONS="$PSQL_OPTS" "$1" \
    psql -U "$2" -d "$3" -X -A -t -F ' ' -v ON_ERROR_STOP=1 -c "$4"
}

# One line per table: name, row count, sha256 over all rows as text.
# Sorting by the row text makes it independent of physical order and of PKs.
control_manifest() {
  local t q
  for t in $VERIFY_TABLES; do
    valid_table "$t" || {
      log "bad table name in VERIFY_TABLES: $t"
      return 1
    }
    q=$(quote_table "$t")
    printf '%s ' "$t"
    psql_in "$1" "$2" "$3" "SELECT count(*), encode(sha256(convert_to(coalesce(string_agg(t::text, chr(10) ORDER BY t::text), ''), 'UTF8')), 'hex') FROM $q AS t" || return 1
  done
}
