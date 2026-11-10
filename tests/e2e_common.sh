# shellcheck shell=bash
# Helpers for the end-to-end scripts. Expects the compose stack to be up.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"
LOG_TAG=e2e

PROM_URL=http://127.0.0.1:${PROM_HOST_PORT:-19690}

pass() { printf 'ok    %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  exit 1
}

expect_eq() { # actual expected description
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
  pass "$3"
}

metric() { # file name
  awk -v m="$2" '$1 == m {print $2; exit}' "$1"
}

# Needs a clean slate, otherwise "newest backup" could be one from an earlier run.
reset_state() {
  rm -rf "$BACKUP_DIR" "$SECONDARY_DIR"
  rm -f "$METRICS_DIR"/*.prom
  mkdir -p "$BACKUP_DIR" "$SECONDARY_DIR" "$METRICS_DIR"
}

wait_until() { # description timeout_seconds command...
  local what=$1 limit=$2 t=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    t=$((t + 2))
    [ "$t" -le "$limit" ] || fail "timed out after ${limit}s waiting for: $what"
    sleep 2
  done
  pass "$what"
}

db_ready() { docker exec "$PG_CONTAINER" pg_isready -q -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB"; }
prom_ready() { curl -fsS "$PROM_URL/-/ready"; }

firing() { # alertname
  [ "$(curl -fsS "$PROM_URL/api/v1/alerts" |
    jq --arg n "$1" '[.data.alerts[] | select(.labels.alertname == $n and .state == "firing")] | length')" -gt 0 ]
}

not_firing() { ! firing "$1"; }

prom_value_is() { # query expected
  [ "$(curl -fsS --get "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    jq -r '.data.result[0].value[1] // empty')" = "$2" ]
}

any_firing() {
  [ "$(curl -fsS "$PROM_URL/api/v1/alerts" | jq '[.data.alerts[] | select(.state == "firing")] | length')" -gt 0 ]
}

no_firing_at_all() { ! any_firing; }
