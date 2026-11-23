# large_fixes — raw evidence for report §5 and §6

All files here are real `EXPLAIN (ANALYZE, BUFFERS)` output measured on
23 Nov 2026, PostgreSQL 18.7, MacBook Pro 14-inch (M4 Pro), on the faculty
large dataset (3,000,000 orders). Nothing here is synthetic or estimated.

| File | What it is | How it was produced |
|---|---|---|
| `R09_workmem_256MB.txt` / `.sql` | Original R09 text, 3 runs with `SET work_mem='256MB'` on `zomato_large` | `psql -d zomato_large -f R09_workmem_256MB.sql` |
| `R19_rewritten.txt` / `.sql` | Kartik's Phase 4 R19 rewrite (verbatim from `sql/06_optimized_queries.sql`), 3 runs on `zomato_large` | `psql -d zomato_large -f R19_rewritten.sql` |
| `R23_keyset_demo.txt` / `.sh` | Optional NEW keyset-paging query (given R23 untouched), 3 runs on `zomato_large`; cursor = last row of page 4,000 | `bash R23_keyset_demo.sh zomato_large` |
| `R19_unindexed_sample.sql` / `.txt` | **Labelled SAMPLE**: original R19 SubPlans with only the outer set limited to 100 of 8,000 restaurants, 3 runs on `zomato_large_before`. Used ONLY for the disclosed estimate in report §1 — NOT a full-run measurement and NOT in any total. | `psql -d zomato_large_before -f R19_unindexed_sample.sql` |
| `partition_pruning_plans.txt` / `.sql` | One-month count (prunes to 1 of 19 partitions) and the OFFSET query (scans all 18) on `zomato_large_part`, before the tables were renamed for the workload run | `psql -d zomato_large_part -f partition_pruning.sql` |
| `city_distribution.txt` | Measured orders per city, used for the shard-balance numbers in report §7 | `SELECT l.city_id, c.city_name, count(*), round(100.0*count(*)/3000000,1) FROM zomato.orders o JOIN zomato.restaurants r ON r.restaurant_id=o.restaurant_id JOIN zomato.localities l ON l.locality_id=r.locality_id JOIN zomato.cities c ON c.city_id=l.city_id GROUP BY 1,2 ORDER BY 3 DESC;` |

The partitioned workload run itself is in `../large_partitioned/`; the
rename step kept the flat originals as `*_flat` so foreign keys stayed valid
and `queries/workload_30.sql` ran unmodified.