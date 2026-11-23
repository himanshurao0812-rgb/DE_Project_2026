-- Section 4 of sql/08_partitioning.sql: verify pruning on the LARGE dataset.
-- Run while the tables are still named *_partitioned (before the rename used
-- to benchmark the unmodified workload).
SET search_path TO zomato;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders_partitioned
WHERE placed_at >= '2026-06-01' AND placed_at < '2026-07-01';

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_partitioned ORDER BY placed_at DESC OFFSET 100000 LIMIT 25;
