#!/usr/bin/env bash
# Adds orders and payments to the demo database so that two backups in a row differ.
# Usage: add-orders.sh [count]
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -X -q -v ON_ERROR_STOP=1 -v n="${1:-100}" <<'SQL'
WITH base AS (SELECT coalesce(max(id), 0) AS m FROM orders),
     new_orders AS (
       INSERT INTO orders (id, customer_id, amount_cents, status, placed_at)
       SELECT m + g, 1 + (m + g) % 2000, 500 + (m + g) % 9000, 'new', now()
       FROM base, generate_series(1, :n) AS g
       RETURNING id
     )
INSERT INTO payments (id, order_id, method, paid_at)
SELECT (SELECT coalesce(max(id), 0) FROM payments) + row_number() OVER (ORDER BY id), id, 'card', now()
FROM new_orders;
SQL
