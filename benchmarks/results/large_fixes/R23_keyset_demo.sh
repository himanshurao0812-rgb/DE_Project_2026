#!/usr/bin/env bash
# Optional NEW query (not a change to R23): keyset pagination demo on the large
# dataset. The cursor is the last row of page 4,000, fetched once; the page
# itself then needs no OFFSET. Ties on placed_at can shift a row or two at the
# page boundary vs the OFFSET form - noted honestly in the report.
set -euo pipefail
DB="${1:-zomato_large}"
OUT="/private/var/folders/5f/vp8y14rn613clj8w_h03v9lc0000gp/T/opencode/cp4"
CURSOR="$(psql -d "$DB" -X -Atc "SELECT placed_at FROM zomato.orders ORDER BY placed_at DESC OFFSET 99999 LIMIT 1;")"
echo "cursor (last row of page 4000): $CURSOR"
: > "$OUT/keyset_r23_demo.txt"
for i in 1 2 3; do
  echo "=== keyset run $i ===" >> "$OUT/keyset_r23_demo.txt"
  psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 >> "$OUT/keyset_r23_demo.txt" <<SQL
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, restaurant_id, status, total_amount, placed_at
FROM zomato.orders
WHERE placed_at < '$CURSOR'
ORDER BY placed_at DESC
LIMIT 25;
SQL
done
grep 'Execution Time' "$OUT/keyset_r23_demo.txt"