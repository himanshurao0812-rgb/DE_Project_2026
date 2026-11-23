-- ============================================================================
--  Phase 5 / CP4 -- partitioning, sharding and replica design
--  Owner: Kunal.  Due: Mon 23 Nov 2026, 11:59 PM.
--  Sections 0 and 4 filled 23 Nov 2026 from measured runs on the faculty large
--  dataset (benchmarks/results/{large,large_partitioned}/).
-- ============================================================================
--  WHY PARTITION AT ALL?
--  orders grows 20x: 150,000 -> ~3,000,000 rows; order_items 375,000 -> 7.5 M;
--  payments 137,378 -> ~2.7 M. The complaints that survive indexing are the
--  ones that touch a *time window* (R09, R10, R21, R22, R23) or the *whole
--  table* (R19, R23). Partitioning by time gives the planner a way to touch
--  only the partitions a query needs (partition pruning).
-- ============================================================================

SET search_path TO zomato;

-- ---------------------------------------------------------------------------
-- 0. Measured on the faculty large dataset, 23 Nov 2026 (3 runs per query,
--    averages; sources: benchmarks/results/{optimized,large,large_partitioned})
-- ---------------------------------------------------------------------------
-- | Query | Small data (150k) | Large data (3M) | After partitioning | Target |
-- |-------|------------------:|----------------:|-------------------:|--------|
-- | R09   |            27.539 |         385.807 |            449.831 | 2000 ms |
-- | R10   |             1.019 |           9.898 |              9.579 | 1000 ms |
-- | R21   |             4.992 |         107.557 |            120.805 | 2000 ms |
-- | R22   |             3.037 |          48.307 |             81.500 | 2000 ms |
-- | R23   |             9.649 |           7.288 |            341.961 | 200 ms |
-- | R19   |            18.536 |        1014.939 |           3750.346 | 2000 ms |
--
-- MEASURED CONCLUSION (docs/05_scalability_report.md §6): partitioning made
-- this read-heavy workload SLOWER overall (4272.9 -> 7955.9 ms total). Pruning
-- works (R21: 1 partition, R22: 2), but Phase 4 indexes already serve those
-- queries; R09's EXTRACT(YEAR) filter cannot prune; R23 regresses 47x (no
-- global placed_at index) and R19 3.7x (19 local indexes per probe). Wins are
-- on writes: W01 2.6x, W04/W05 8-21% faster. Ship indexes only; keep
-- partitioning for lifecycle management (DETACH/DROP old months).

-- ---------------------------------------------------------------------------
-- 1. ORDERS partitioned BY RANGE (placed_at), one partition per month.
--    The workload's date filters are all "a month" or "a range of months"
--    (R06 = one day, R07/R21 = one month, R09/R22 = a window), so monthly
--    range partitions prune cleanly.
-- ---------------------------------------------------------------------------
CREATE TABLE orders_partitioned (
    order_id       BIGINT        NOT NULL,
    customer_id    INTEGER       NOT NULL,
    restaurant_id  INTEGER       NOT NULL,
    partner_id     INTEGER,
    coupon_code    TEXT,
    placed_at      TIMESTAMPTZ   NOT NULL,
    accepted_at    TIMESTAMPTZ,
    picked_up_at   TIMESTAMPTZ,
    delivered_at   TIMESTAMPTZ,
    distance_km    NUMERIC(4,1)  NOT NULL,
    item_total     NUMERIC(10,2) NOT NULL,
    delivery_fee   NUMERIC(10,2) NOT NULL,
    discount       NUMERIC(10,2) NOT NULL,
    total_amount   NUMERIC(10,2) NOT NULL,
    status         TEXT          NOT NULL,
    -- a partitioned table's primary key MUST include the partition key
    CONSTRAINT orders_partitioned_pkey PRIMARY KEY (order_id, placed_at)
) PARTITION BY RANGE (placed_at);

-- 18 months of seed data (Jan 2025 - Jun 2026) + a DEFAULT catch-all so a load
-- can never fail because a partition is missing.
DO $$
DECLARE
    m date := DATE '2025-01-01';
BEGIN
    WHILE m < DATE '2026-07-01' LOOP
        EXECUTE format(
            'CREATE TABLE orders_%s PARTITION OF orders_partitioned
             FOR VALUES FROM (%L) TO (%L)',
            to_char(m, 'YYYY_MM'),
            m::timestamptz,
            (m + interval '1 month')::timestamptz
        );
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;

CREATE TABLE orders_default PARTITION OF orders_partitioned DEFAULT;

-- Partition-local indexes: identical to the Phase 4 indexes, but they are
-- built PER PARTITION, so each one is ~1/18 the size and stays in memory.
CREATE INDEX ON orders_partitioned (customer_id, placed_at DESC);
CREATE INDEX ON orders_partitioned (restaurant_id, placed_at);
CREATE INDEX ON orders_partitioned (placed_at) WHERE status = 'DELIVERED';

-- ---------------------------------------------------------------------------
-- 2. ORDER_ITEMS -- partitioned by HASH(order_id) into 8 partitions.
--    There is no date column, and queries always reach it through order_id
--    (R07, R08, R24), so hashing spreads the 7.5 M rows evenly and keeps
--    "all lines of one order" inside a single partition.
-- ---------------------------------------------------------------------------
CREATE TABLE order_items_partitioned (
    order_id    BIGINT       NOT NULL,
    item_id     INTEGER      NOT NULL,
    quantity    SMALLINT     NOT NULL,
    unit_price  NUMERIC(8,2) NOT NULL,
    CONSTRAINT order_items_partitioned_pkey PRIMARY KEY (order_id, item_id)
) PARTITION BY HASH (order_id);

DO $$
BEGIN
    FOR i IN 0..7 LOOP
        EXECUTE format(
            'CREATE TABLE order_items_p%s PARTITION OF order_items_partitioned
             FOR VALUES WITH (MODULUS 8, REMAINDER %s)', i, i);
    END LOOP;
END $$;

CREATE INDEX ON order_items_partitioned (item_id);

-- ---------------------------------------------------------------------------
-- 3. PAYMENTS -- also HASH(order_id), 4 partitions.
--    R16 filters by attempted_at only, so this one is a judgement call:
--    hash-by-order wins because R17/R24 look payments up per order.
-- ---------------------------------------------------------------------------
CREATE TABLE payments_partitioned (
    payment_id      BIGINT        NOT NULL,
    order_id        BIGINT        NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    method          TEXT          NOT NULL,
    payment_status  TEXT          NOT NULL,
    attempted_at    TIMESTAMPTZ   NOT NULL,
    CONSTRAINT payments_partitioned_pkey PRIMARY KEY (payment_id, order_id)
) PARTITION BY HASH (order_id);

DO $$
BEGIN
    FOR i IN 0..3 LOOP
        EXECUTE format(
            'CREATE TABLE payments_p%s PARTITION OF payments_partitioned
             FOR VALUES WITH (MODULUS 4, REMAINDER %s)', i, i);
    END LOOP;
END $$;

CREATE INDEX ON payments_partitioned (order_id, payment_status);
CREATE INDEX ON payments_partitioned (attempted_at) WHERE payment_status = 'FAILED';

-- ---------------------------------------------------------------------------
-- 4. VERIFY THAT PRUNING ACTUALLY HAPPENS
-- ---------------------------------------------------------------------------
-- Run on the LARGE dataset and paste both plans into docs/05_scalability_report.md.
--
--   EXPLAIN (ANALYZE, BUFFERS)
--   SELECT count(*) FROM orders_partitioned
--   WHERE placed_at >= '2026-06-01' AND placed_at < '2026-07-01';
--   -- EXPECT: "Partitions scanned: 1" (out of 19) and no Seq Scan on the rest.
--   -- NOTE: PostgreSQL 18 has no literal "Partitions scanned:" line; the proof
--   -- is that ONLY orders_2026_06 appears as a plan node (see measured plan below).
--
--   EXPLAIN (ANALYZE, BUFFERS)
--   SELECT * FROM orders_partitioned ORDER BY placed_at DESC OFFSET 100000 LIMIT 25;
--   -- EXPECT: this is the query partitioning does NOT save (R23 still walks
--   -- ~100k rows across many partitions). Say so honestly; the real fix is
--   -- keyset pagination or a separate "recent orders" partition strategy.
--
-- MEASURED 23 Nov 2026 on zomato_large_part (3,000,000 orders), PostgreSQL 18.7:
--   Finalize Aggregate  (cost=5338.00..5338.01 rows=1 width=8) (actual time=8.830..9.530 rows=1.00 loops=1)
--     Buffers: shared hit=2641
--     ->  Gather  (cost=5337.78..5337.99 rows=2 width=8) (actual time=8.777..9.527 rows=2.00 loops=1)
--           Workers Planned: 1
--           Workers Launched: 1
--           Buffers: shared hit=2641
--           ->  Partial Aggregate  (cost=4337.78..4337.79 rows=1 width=8) (actual time=7.527..7.527 rows=1.00 loops=2)
--                 Buffers: shared hit=2641
--                 ->  Parallel Seq Scan on orders_2026_06 orders_partitioned  (cost=0.00..4095.43 rows=96942 width=0) (actual time=0.006..5.747 rows=82417.50 loops=2)
--                       Filter: ((placed_at >= '2026-06-01 00:00:00+05:30'::timestamp with time zone) AND (placed_at < '2026-07-01 00:00:00+05:30'::timestamp with time zone))
--                       Buffers: shared hit=2641
--   Planning:
--     Buffers: shared hit=281 read=49 dirtied=1
--   Planning Time: 1.383 ms
--   Execution Time: 9.553 ms
--   Limit  (cost=339481.43..339484.34 rows=25 width=95) (actual time=311.788..348.817 rows=25.00 loops=1)
--     Buffers: shared hit=4190 read=44062 written=368, temp read=41963 written=78773
--     ->  Gather Merge  (cost=327834.78..677234.34 rows=3000001 width=95) (actual time=299.477..346.763 rows=100025.00 loops=1)
--           Workers Planned: 2
--           Workers Launched: 2
--           Buffers: shared hit=4190 read=44062 written=368, temp read=41963 written=78773
--           ->  Sort  (cost=326834.75..329959.76 rows=1250003 width=95) (actual time=291.106..292.827 rows=33688.00 loops=3)
--                 Sort Key: orders_partitioned.placed_at DESC
--                 Sort Method: external merge  Disk: 109168kB
--                 Buffers: shared hit=4190 read=44062 written=368, temp read=41963 written=78773
--                 Worker 0:  Sort Method: external merge  Disk: 101544kB
--                 Worker 1:  Sort Method: external merge  Disk: 104000kB
--                 ->  Parallel Append  (cost=0.00..72073.07 rows=1250003 width=95) (actual time=0.035..75.684 rows=1000000.00 loops=3)
--                       Buffers: shared hit=4114 read=44062 written=368
--                       ->  Parallel Seq Scan on orders_2025_01 orders_partitioned_1  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.050..6.720 rows=170330.00 loops=1)
--                             Buffers: shared read=2736
--                       ->  Parallel Seq Scan on orders_2025_03 orders_partitioned_3  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.051..7.209 rows=170330.00 loops=1)
--                             Buffers: shared hit=256 read=2480
--                       ->  Parallel Seq Scan on orders_2025_05 orders_partitioned_5  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.080..8.422 rows=170330.00 loops=1)
--                             Buffers: shared read=2736 written=5
--                       ->  Parallel Seq Scan on orders_2025_10 orders_partitioned_10  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.046..8.962 rows=170330.00 loops=1)
--                             Buffers: shared read=2736 written=5
--                       ->  Parallel Seq Scan on orders_2025_12 orders_partitioned_12  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.061..7.473 rows=170330.00 loops=1)
--                             Buffers: shared read=2736 written=99
--                       ->  Parallel Seq Scan on orders_2026_01 orders_partitioned_13  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.080..7.616 rows=170330.00 loops=1)
--                             Buffers: shared read=2736 written=65
--                       ->  Parallel Seq Scan on orders_2025_08 orders_partitioned_8  (cost=0.00..3737.94 rows=100194 width=95) (actual time=0.110..7.128 rows=170329.00 loops=1)
--                             Buffers: shared read=2736 written=28
--                       ->  Parallel Seq Scan on orders_2025_07 orders_partitioned_7  (cost=0.00..3736.94 rows=100194 width=95) (actual time=0.055..6.896 rows=170330.00 loops=1)
--                             Buffers: shared read=2735 written=18
--                       ->  Parallel Seq Scan on orders_2026_03 orders_partitioned_15  (cost=0.00..3736.94 rows=100194 width=95) (actual time=0.069..6.579 rows=170329.00 loops=1)
--                             Buffers: shared read=2735 written=6
--                       ->  Parallel Seq Scan on orders_2026_05 orders_partitioned_17  (cost=0.00..3736.94 rows=100194 width=95) (actual time=0.105..6.577 rows=170329.00 loops=1)
--                             Buffers: shared read=2735 written=52
--                       ->  Parallel Seq Scan on orders_2025_09 orders_partitioned_9  (cost=0.00..3617.62 rows=96962 width=95) (actual time=0.055..2.051 rows=54945.00 loops=3)
--                             Buffers: shared read=2648
--                       ->  Parallel Seq Scan on orders_2026_04 orders_partitioned_16  (cost=0.00..3616.62 rows=96962 width=95) (actual time=0.051..3.142 rows=82418.00 loops=2)
--                             Buffers: shared read=2647
--                       ->  Parallel Seq Scan on orders_2025_04 orders_partitioned_4  (cost=0.00..3616.62 rows=96962 width=95) (actual time=0.035..5.441 rows=164835.00 loops=1)
--                             Buffers: shared read=2647 written=14
--                       ->  Parallel Seq Scan on orders_2025_06 orders_partitioned_6  (cost=0.00..3616.62 rows=96962 width=95) (actual time=0.030..6.860 rows=164835.00 loops=1)
--                             Buffers: shared read=2647 written=41
--                       ->  Parallel Seq Scan on orders_2025_11 orders_partitioned_11  (cost=0.00..3616.62 rows=96962 width=95) (actual time=0.017..6.706 rows=164835.00 loops=1)
--                             Buffers: shared read=2647 written=35
--                       ->  Parallel Seq Scan on orders_2026_06 orders_partitioned_18  (cost=0.00..3610.62 rows=96962 width=95) (actual time=0.003..5.323 rows=164835.00 loops=1)
--                             Buffers: shared hit=2641
--                       ->  Parallel Seq Scan on orders_2025_02 orders_partitioned_2  (cost=0.00..3375.98 rows=90498 width=95) (actual time=0.028..5.593 rows=153846.00 loops=1)
--                             Buffers: shared read=2471
--                       ->  Parallel Seq Scan on orders_2026_02 orders_partitioned_14  (cost=0.00..3375.98 rows=90498 width=95) (actual time=0.004..7.144 rows=153846.00 loops=1)
--                             Buffers: shared hit=1217 read=1254
--                       ->  Parallel Seq Scan on orders_default orders_partitioned_19  (cost=0.00..0.00 rows=1 width=192) (actual time=0.000..0.000 rows=0.00 loops=1)
--   Planning:
--     Buffers: shared hit=2029 read=144 dirtied=49
--   Planning Time: 3.710 ms
--   Execution Time: 698.834 ms

-- ---------------------------------------------------------------------------
-- 5. SHARDING DESIGN
-- ---------------------------------------------------------------------------
--  Partitioning speeds up ONE server. Sharding spreads load across servers.
--  Recommended: shard by CITY (city_id), because 9 of the 10 problem
--  statements are already city- or locality-scoped (R01 Koramangala,
--  R08/R25 Pune, R19/R22 Bengaluru, R20 Mumbai). City sharding keeps almost
--  every hot query single-shard.
--
--  | Shard | Cities                         | Why together          |
--  |-------|--------------------------------|-----------------------|
--  | S1    | 1 Bengaluru, 6 Pune, 5 Chennai | south + biggest metro |
--  | S2    | 2 Mumbai, 8 Ahmedabad, 9 Jaipur| west                  |
--  | S3    | 3 Delhi, 10 Lucknow            | north                 |
--  | S4    | 4 Hyderabad, 7 Kolkata         | rest                  |
--
--  Tables that follow the shard key (co-located, no cross-shard join):
--    orders, order_items, payments, reviews  -- reached through customer/restaurant
--  Tables that must be REPLICATED to every shard (small, read everywhere):
--    cities (10 rows), localities (100), coupons (30)
--  Cross-shard queries (must be handled or accepted):
--    R20/R21 (growth per city) -- run per shard, then merge in the app or a
--    rollup table, because GROUP BY city is naturally shard-local.
--
--  REPLICAS: the workload is 25 reads to 5 writes, so add
--    * 1 primary (all writes: W01-W05 for a city)
--    * 2 streaming read replicas per shard for the read workload
--    * accept that a read replica may be a few hundred ms stale -- R12/R05
--      (dispatch, kitchen delay) MUST go to the primary, because they are
--      real-time and a stale answer is worse than a slow one.
--
--  Validate all of this against your large-dataset numbers: if shard S1 cannot
--  hold its share of 3 M orders inside the latency targets, split Pune off.
-- ============================================================================
