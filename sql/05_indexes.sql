-- ============================================================================
--  Zomato Food Delivery Database -- Phase 4: indexes (checkpoint CP3)
--  Team T0122 | PostgreSQL 18.6 (works on 15+)
--  Run AFTER sql/01_schema.sql and sql/02_load_data.sql, on the same database.
--
--  Rules (README 4.1 / 4.2):
--   * Every index has a comment: which queries it serves and why this type and
--     column order.
--   * No data is changed, no server settings are changed.
--   * Uses IF NOT EXISTS so the script can be re-run.
--   * The baseline (Phase 3) numbers in benchmarks/results/baseline/ were taken
--     WITHOUT these indexes. Keep the baseline as it is; re-run the benchmark
--     with this file applied to get the "optimized" numbers.
--
--  Notes on scans seen in the baseline (benchmarks/results/baseline/summary.csv):
--   almost every slow query runs "Seq Scan on orders" (150,000 rows). The
--   indexes below are chosen to turn those into index scans on the rows the
--   query actually needs.
-- ============================================================================

SET search_path TO zomato;

-- pg_trgm lets a GIN index answer LIKE / ILIKE '%text%' (used by R02 and R18).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ----------------------------------------------------------------------------
-- A. Locality, restaurant and menu lookups (R01, R02, R08, R09, R19, R22, R25)
-- ----------------------------------------------------------------------------

-- R01 filters localities by name, then joins restaurants on locality_id.
-- The UNIQUE(city_id, locality_name) index cannot be used for a name-only
-- filter because city_id is its leading column, so this one is needed.
CREATE INDEX IF NOT EXISTS idx_localities_name
    ON localities (locality_name);

-- R02, R08, R09, R19, R22, R25 join restaurants to localities and filter by city.
-- Plain B-tree on the foreign key. (FK side is never indexed automatically.)
CREATE INDEX IF NOT EXISTS idx_localities_city
    ON localities (city_id);

CREATE INDEX IF NOT EXISTS idx_restaurants_locality
    ON restaurants (locality_id);

-- R01: "open restaurants in one locality, best rated first".
-- Partial index (WHERE status = 'OPEN') because R01 always filters on OPEN and
-- the index stays smaller. Column order: locality_id (equality) first, then
-- rating (the ORDER BY). NULLS LAST matches the query, so the rated restaurants
-- come out in order without a sort step.
CREATE INDEX IF NOT EXISTS idx_restaurants_locality_open_rating
    ON restaurants (locality_id, rating DESC NULLS LAST)
    WHERE status = 'OPEN';

-- R25: "'Chinese' = ANY (cuisines)" cannot use a GIN index. R25 is rewritten in
-- sql/06_optimized_queries.sql to "cuisines @> ARRAY['Chinese']", which can.
-- GIN is the right type for arrays: it indexes every element of the array.
CREATE INDEX IF NOT EXISTS idx_restaurants_cuisines
    ON restaurants USING gin (cuisines);

-- R02: "item_name ILIKE '%paneer%'". A B-tree cannot help a leading-wildcard
-- pattern. A GIN trigram index splits the name into 3-letter pieces, so the
-- pattern becomes an index lookup instead of a scan of 50,000 rows.
CREATE INDEX IF NOT EXISTS idx_menu_items_name_trgm
    ON menu_items USING gin (item_name gin_trgm_ops);

-- ----------------------------------------------------------------------------
-- B. Orders by customer (R04, R14, R20)
-- ----------------------------------------------------------------------------

-- R04: "a customer's last 10 orders". Equality on customer_id first, then
-- placed_at DESC matches ORDER BY ... DESC, so the LIMIT 10 stops after 10
-- index entries. Also serves R14 (orders by customer in June) and the FK side.
CREATE INDEX IF NOT EXISTS idx_orders_customer_placed
    ON orders (customer_id, placed_at DESC);

-- R20: "top 20 Mumbai customers by delivered spend". Partial on DELIVERED (the
-- query filters on it) and INCLUDE (total_amount) so the SUM can be read from
-- the index itself (Index Only Scan) without touching the table.
CREATE INDEX IF NOT EXISTS idx_orders_customer_delivered
    ON orders (customer_id) INCLUDE (total_amount)
    WHERE status = 'DELIVERED';

-- ----------------------------------------------------------------------------
-- C. Orders by restaurant (R06, R07, R19)
-- ----------------------------------------------------------------------------

-- R06 (one restaurant, one day), R07 (one restaurant, one month, delivered),
-- and the correlated subqueries in R19 (max(placed_at) and counts per
-- restaurant) all start with restaurant_id equality, then filter or sort on
-- placed_at. This also covers the FK side of orders.restaurant_id.
CREATE INDEX IF NOT EXISTS idx_orders_restaurant_placed
    ON orders (restaurant_id, placed_at);

-- ----------------------------------------------------------------------------
-- D. Orders by time (R05, R08, R09, R10, R21, R22, R23)
-- ----------------------------------------------------------------------------

-- R10, R21, R22 and R23 filter on a range of placed_at. R23 is "newest first,
-- OFFSET 100000, LIMIT 25": with a DESC index the planner walks the index in
-- order and stops early. INCLUDE puts the columns R21 and R23 read into the
-- index, so they are Index Only Scans and the table pages are not read.
-- Caveat (reported in docs/04_optimization_report.md): OFFSET still has to
-- skip 100,000 index entries, so R23 gets faster but does not become constant.
CREATE INDEX IF NOT EXISTS idx_orders_placed_at
    ON orders (placed_at DESC)
    INCLUDE (order_id, customer_id, restaurant_id, status, total_amount);

-- R08 ("last 30 days, delivered, Pune") and R09 (2026 delivered orders) read only
-- DELIVERED orders, which is most of the table. A partial index on placed_at
-- for DELIVERED rows is smaller than the full index for those queries.
CREATE INDEX IF NOT EXISTS idx_orders_delivered_placed
    ON orders (placed_at)
    WHERE status = 'DELIVERED';

-- R05: "PREPARING for more than 40 minutes". Only orders still in PREPARING are
-- of interest, and the range is on accepted_at, so the partial index holds only
-- those rows (a small share of the 150,000).
CREATE INDEX IF NOT EXISTS idx_orders_preparing_accepted
    ON orders (accepted_at)
    WHERE status = 'PREPARING';

-- ----------------------------------------------------------------------------
-- E. Dispatch and partner queries (R11, R12, R13, W02)
-- ----------------------------------------------------------------------------

-- R12 and W02 look for orders with no partner (partner_id IS NULL) and status
-- PLACED/ACCEPTED, sorted by placed_at. The partial index holds only those
-- orders (about 13,500 of 150,000, and fewer still at any moment in real use).
CREATE INDEX IF NOT EXISTS idx_orders_unassigned_placed
    ON orders (placed_at)
    WHERE partner_id IS NULL
      AND status IN ('PLACED', 'ACCEPTED');

-- R11 (one partner's deliveries in a week) and R13 (the NOT EXISTS anti-join,
-- which after the NULL fix needs to probe orders by partner_id quickly).
-- Not partial, because R13 must see all statuses to decide "never assigned".
CREATE INDEX IF NOT EXISTS idx_orders_partner_placed
    ON orders (partner_id, placed_at DESC);

-- R13: active Bengaluru partners. Partial on ACTIVE because the query always
-- filters on it. city_id is the leading column for the city equality.
CREATE INDEX IF NOT EXISTS idx_delivery_partners_city_active
    ON delivery_partners (city_id)
    WHERE status = 'ACTIVE';

-- ----------------------------------------------------------------------------
-- F. Customers and Gold membership (R14, R20, R21, W05)
-- ----------------------------------------------------------------------------

-- R20 and R21 filter customers by city_id, then join to orders.
CREATE INDEX IF NOT EXISTS idx_customers_city
    ON customers (city_id);

-- R14 (expiring Gold members) and W05 (nightly Gold expiry) filter on
-- gold_expires_on < date among Gold members only. The partial index keeps
-- the 21,208 non-Gold rows out of it.
CREATE INDEX IF NOT EXISTS idx_customers_gold_expiry
    ON customers (gold_expires_on)
    WHERE is_gold_member;

-- ----------------------------------------------------------------------------
-- G. Coupons (R15)
-- ----------------------------------------------------------------------------

-- R15 joins orders to coupons on coupon_code. Most orders have no coupon, so the
-- partial index only holds the orders that do. Also the FK side of
-- orders.coupon_code.
CREATE INDEX IF NOT EXISTS idx_orders_coupon
    ON orders (coupon_code)
    WHERE coupon_code IS NOT NULL;

-- ----------------------------------------------------------------------------
-- H. Payments (R16, R17, R24)
-- ----------------------------------------------------------------------------

-- R16: failed attempts in the last 7 days, per method. Range on attempted_at,
-- partial on FAILED (the only rows the query reads).
CREATE INDEX IF NOT EXISTS idx_payments_failed_attempted
    ON payments (attempted_at)
    WHERE payment_status = 'FAILED';

-- R17: failed attempts per customer. Joins to orders on order_id. The partial
-- index holds only the failed rows, indexed by the join key.
CREATE INDEX IF NOT EXISTS idx_payments_failed_order
    ON payments (order_id)
    WHERE payment_status = 'FAILED';

-- R24: the bill page looks up the SUCCESSFUL payment for one order. Partial on
-- SUCCESS, keyed on order_id, so the single matching row is one index probe.
CREATE INDEX IF NOT EXISTS idx_payments_success_order
    ON payments (order_id)
    WHERE payment_status = 'SUCCESS';

-- ----------------------------------------------------------------------------
-- I. Reviews (R18, R19, W04)
-- ----------------------------------------------------------------------------

-- R19 and W04 compute AVG(food_rating) per restaurant. Keyed on restaurant_id,
-- with food_rating INCLUDEd, so the average is computed from the index alone
-- (Index Only Scan). Also the FK side of reviews.restaurant_id.
CREATE INDEX IF NOT EXISTS idx_reviews_restaurant
    ON reviews (restaurant_id) INCLUDE (food_rating);

-- R18: "review_text ILIKE '%cold%' OR review_text ILIKE '%late%'". Same reason as
-- idx_menu_items_name_trgm: leading-wildcard pattern, so GIN trigram. Two
-- ILIKE predicates OR-ed together can be served by a BitmapOr over this index.
CREATE INDEX IF NOT EXISTS idx_reviews_text_trgm
    ON reviews USING gin (review_text gin_trgm_ops);

-- ----------------------------------------------------------------------------
-- J. Keep the planner's statistics current after the new indexes
-- ----------------------------------------------------------------------------
ANALYZE;
