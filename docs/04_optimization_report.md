# Phase 4: Optimization Report

**Team T0122 · Zomato Food Delivery Database · Checkpoint CP3 (due Thu 19 Nov 2026)**

**Environment:** MacBook Pro 14-inch (M4 Pro), PostgreSQL 18.7, database `zomato_test` loaded from `seed_data.zip`. Schema and load passed with all 11 row counts matching the README. Each timing is the average of 3 runs (`run_benchmark.sh`). Raw plans are in `benchmarks/results/baseline/` and `benchmarks/results/optimized/`.

Files this report refers to:

- `sql/05_indexes.sql` (Kunal): 23 indexes, all created successfully
- `sql/06_optimized_queries.sql` (Kartik): 30 queries, 5 rewritten (R06, R09, R13, R19, R25)
- `benchmarks/results/optimized/summary.csv`: measured results (30 rows)

---

## 1. Results for all 30 queries

Improvement % = (before − after) / before × 100. A negative value means the query got slower.

"Same result?" means the optimized query returns the same rows as the original. For the rewritten queries this was checked by comparing row count and an MD5 checksum over all rows. For the unchanged queries the SQL text is identical, so the result is identical by definition: indexes change how rows are found, not which rows are returned.

| Query | Before (ms) | After (ms) | Improvement | Scan types after the change | Same result? |
|-------|------------:|-----------:|------------:|-----------------------------|:------------:|
| R01 | 0.567 | 0.100 | 82.4% | Bitmap Index Scan on idx_restaurants_locality_open_rating | Yes (unchanged SQL) |
| R02 | 8.038 | 4.334 | 46.1% | Seq Scan on restaurants and localities; ILIKE still scans menu_items | Yes (unchanged SQL) |
| R03 | 0.171 | 0.092 | 46.2% | Index Scan on menu_items (unchanged) | Yes (unchanged SQL) |
| R04 | 11.145 | 0.265 | 97.6% | Bitmap Index Scan on idx_orders_customer_placed | Yes (unchanged SQL) |
| R05 | 6.509 | 0.085 | 98.7% | Index Scan on idx_orders_preparing_accepted | Yes (unchanged SQL) |
| R06 | 10.506 | 0.072 | 99.3% | Index Scan on idx_orders_restaurant_placed | Yes (rewritten; checksum match, 1 row) |
| R07 | 8.966 | 0.227 | 97.5% | Bitmap Index Scan on idx_orders_restaurant_placed | Yes (unchanged SQL) |
| R08 | 9.341 | 5.547 | 40.6% | Index Scan on idx_orders_delivered_placed | Yes (unchanged SQL) |
| R09 | 24.884 | 27.539 | −10.7% | Index Scan on idx_orders_delivered_placed (slower, see section 3) | Yes (rewritten; checksum match, 60 rows) |
| R10 | 5.216 | 1.019 | 80.5% | Index Scan on idx_orders_placed_at | Yes (unchanged SQL) |
| R11 | 6.578 | 0.053 | 99.2% | Index Scan on idx_orders_partner_placed | Yes (unchanged SQL) |
| R12 | 8.476 | 0.041 | 99.5% | Index Scan on idx_orders_unassigned_placed | Yes (unchanged SQL) |
| R13 | 8.993 | 0.793 | n/a (result changed) | Anti join using idx_orders_placed_at and idx_delivery_partners_city_active | **No, changed on purpose** (0 rows → 129 rows, section 2) |
| R14 | 7.371 | 3.393 | 54.0% | Index Only Scan on idx_orders_placed_at; Bitmap Index Scan on idx_customers_gold_expiry | Yes (unchanged SQL) |
| R15 | 15.153 | 11.848 | 21.8% | Index Scan on idx_orders_coupon | Yes (unchanged SQL) |
| R16 | 5.440 | 0.116 | 97.9% | Index Scan on idx_payments_failed_attempted | Yes (unchanged SQL) |
| R17 | 17.728 | 19.881 | −12.1% | Seq Scan on orders; Index Only Scan on idx_payments_failed_order (slower, see section 3) | Yes (unchanged SQL) |
| R18 | 7.877 | 2.721 | 65.5% | Bitmap Index Scan on idx_reviews_text_trgm | Yes (unchanged SQL) |
| R19 | 4,387.840 | 18.536 | 99.6% | Index Only Scan on idx_reviews_restaurant; restaurant and localities still seq scanned (small tables) | Yes (rewritten; checksum match, 400 rows) |
| R20 | 22.111 | 7.802 | 64.7% | Index Only Scan on idx_orders_customer_delivered | Yes (unchanged SQL) |
| R21 | 11.176 | 4.992 | 55.3% | Index Only Scan on idx_orders_placed_at | Yes (unchanged SQL) |
| R22 | 16.188 | 3.037 | 81.2% | Index Only Scan on idx_orders_restaurant_placed | Yes (unchanged SQL) |
| R23 | 37.245 | 9.649 | 74.1% | Index Only Scan on idx_orders_placed_at | Yes (unchanged SQL) |
| R24 | 6.906 | 0.093 | 98.7% | Index Scan on idx_payments_success_order | Yes (unchanged SQL) |
| R25 | 0.277 | 0.517 | −86.6% | Bitmap Index Scan on idx_restaurants_cuisines (slower, see section 3) | Yes (rewritten; checksum match, 62 rows) |
| W01 | 0.609 | 2.988 | −390.6% | No scan (INSERT; write overhead, section 4) | Not applicable (write) |
| W02 | 9.847 | 1.606 | 83.7% | Index Scan on idx_orders_unassigned_placed | Yes (unchanged SQL) |
| W03 | 0.412 | 2.435 | −491.0% | Index Scan on menu_items (plan unchanged, section 4) | Not applicable (write) |
| W04 | 19.196 | 27.104 | −41.2% | Seq Scan on restaurants and reviews (slower, section 4) | Not applicable (write) |
| W05 | 22.098 | 17.369 | 21.4% | Bitmap Index Scan on idx_customers_gold_expiry | Not applicable (write) |
| **Total (sum of all 30)** | **4,696.864** | **174.254** | **96.3%** | | |

The 30-query total dropped by 96.3%. Most of the gain comes from R19, which alone accounts for 4,369 ms of the 4,523 ms saved.

**Top five improvements by time saved:** R19 (−4,369.3 ms), R23 (−27.6 ms), R20 (−14.3 ms), R22 (−13.2 ms), R04 (−10.9 ms).

---

## 2. The wrong-result query: R13

**The problem reported (P6):** the fleet team's idle-partner list came back empty.

**Confirmed in the raw baseline plan** (`benchmarks/results/baseline/R13.txt`): the original query returns **0 rows**. The plan shows a `NOT (ANY (partner_id = …))` filter over a hashed subplan. The subplan returns 1,648 orders, and some of them have a NULL `partner_id`. A NULL in that list makes the `NOT IN` test unknown for every partner, so all partners are filtered out.

**The fix:** Kartik's rewrite uses `NOT EXISTS`, which treats NULL as "no matching row". The optimized plan (`benchmarks/results/optimized/R13.txt`) is a Hash Right Anti Join and returns **129 rows**, out of 285 active Bengaluru partners. The 129 partners are the ones with no order since 25 June 2026.

This output change is intended, because the original result was wrong. The business should confirm that the 129 partners are the list the fleet team needs.

---

## 3. Queries that got slower

- **R09 (−10.7%):** the planner now uses `idx_orders_delivered_placed` for the 2026 range. Most delivered orders fall in that range, so reading the index and then the table costs more than a sequential scan. Option: drop that partial index, or keep the original `EXTRACT` filter for this query.
- **R17 (−12.1%):** the join with orders is still a Seq Scan on orders. The new index on failed payments is used, but it does not remove the scan that dominates the cost.
- **R25 (−86.6%):** the GIN index on `cuisines` is used, but `restaurants` has only 2,500 rows, so a sequential scan was already cheap. At this size the index only adds overhead. The absolute difference is 0.24 ms.

---

## 4. Write overhead and index storage

| Write | Before (ms) | After (ms) | Change | Cause |
|-------|------------:|-----------:|-------:|-------|
| W01 INSERT into orders | 0.609 | 2.988 | +2.38 ms | orders now has 9 indexes to update per insert |
| W03 menu_items UPDATE | 0.412 | 2.435 | +2.02 ms | Plan is unchanged, so the cause is not determined yet. The timing is stable across 3 runs |
| W04 restaurants rating UPDATE | 19.196 | 27.104 | +7.9 ms | Probably the restaurants indexes, since `rating` is part of `idx_restaurants_locality_open_rating`. Not verified |
| W02 dispatch UPDATE | 9.847 | 1.606 | −8.2 ms (faster) | Partial index for unassigned orders |
| W05 Gold expiry UPDATE | 22.098 | 17.369 | −4.7 ms (faster) | Partial index on Gold expiry |

The writes that got slower are still fast in absolute terms (under 30 ms). W01 matters most, since it runs on every order placed. The 2.4 ms extra cost is acceptable for the 150,000-row seed data, but it should be checked again at 20× volume in Phase 5.

**Index storage (measured):**

| Object | Size |
|--------|-----:|
| orders (table) | 19 MB |
| idx_orders_placed_at | 8.9 MB |
| idx_orders_delivered_placed | 2.9 MB |
| idx_orders_customer_placed | 4.6 MB |
| idx_orders_partner_placed | 4.6 MB |
| idx_orders_restaurant_placed | 4.6 MB |
| idx_orders_customer_delivered | 4.0 MB |
| idx_orders_coupon | 0.2 MB |
| idx_orders_preparing_accepted | 16 kB |
| idx_orders_unassigned_placed | 16 kB |
| **All 9 orders indexes** | **about 29 MB** |

The nine indexes on orders together are about 1.5 times the size of the table. This is the main storage cost of the design, and it is worth noting in Phase 5 when the data grows 20×.

---

## 5. Plans for the five biggest improvements

The full plans for each of the three runs are in the raw files. Each file has the before and after plan side by side.

| Query | Before plan | After plan |
|-------|-------------|-----------|
| R19 | `benchmarks/results/baseline/R19.txt` | `benchmarks/results/optimized/R19.txt` |
| R23 | `benchmarks/results/baseline/R23.txt` | `benchmarks/results/optimized/R23.txt` |
| R20 | `benchmarks/results/baseline/R20.txt` | `benchmarks/results/optimized/R20.txt` |
| R22 | `benchmarks/results/baseline/R22.txt` | `benchmarks/results/optimized/R22.txt` |
| R04 | `benchmarks/results/baseline/R04.txt` | `benchmarks/results/optimized/R04.txt` |

The key change for each:

- **R19:** three correlated subqueries that scanned orders and reviews once per restaurant are replaced by one aggregate per table. The reviews aggregate is now an Index Only Scan.
- **R23:** the index on `placed_at DESC` with INCLUDE gives an Index Only Scan. OFFSET 100,000 still skips 100,000 index entries, so this query is faster but not constant time.
- **R20:** a partial covering index on delivered orders lets the SUM be read from the index.
- **R22:** the index on restaurant and placed time is used as an Index Only Scan.
- **R04:** the composite index `(customer_id, placed_at DESC)` answers the last-10 query from the index.

---

## 6. Queries that could not be sped up fully

- **R23:** see section 5. The offset is a row count, so the work still grows with the page number.
- **R10 (deliveries over 60 minutes):** improved from 5.2 ms to 1.0 ms by the June range index. The duration test is a per-row check that no index can serve.
- **R02 and R18 (text search):** the trigram indexes help (R02: 8.0 → 4.3 ms, R18: 7.9 → 2.7 ms), but both still scan the matching rows. Both are fine at this data size.

---

## 7. Checks completed

- **Row content:** the four rewritten queries that keep their result (R06, R09, R19, R25) match the original by row count and checksum. R13 changed on purpose, as explained in section 2.
- **Unchanged queries:** 25 queries have unchanged SQL text, so their results match.
- **Index storage:** measured in section 4.
- **Schema and load:** all 11 tables match the expected row counts, and the integrity checks found no problems.
- **Indexes:** all 23 were created by `sql/05_indexes.sql`.

Note: the checksums compare rows without regard to order. The rewritten queries keep their original `ORDER BY` clauses, so ordering is unchanged by construction, but it was not compared directly.
