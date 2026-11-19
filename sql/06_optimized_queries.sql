-- =====================================================================
-- Zomato DBMS Project: optimized versions of the 30 queries (Phase 4)
--   Copy of queries/workload_30.sql. ONLY the queries that were rewritten
--   are changed; each rewritten query has a "REWRITTEN:" comment saying why.
--   Unchanged queries are kept verbatim so run_benchmark.sh can compare them.
--
-- RULES (README 4.1)
--   * Same rows as the original, except R13, where the original returns a
--     wrong (empty) result because of NULLs. See docs/04_optimization_report.md.
--   * Run with: ./benchmarks/run_benchmark.sh <db> optimized 3 sql/06_optimized_queries.sql
--   * Indexes used here are in sql/05_indexes.sql (apply that file first).
-- =====================================================================
SET search_path TO zomato;
BEGIN;

-- @R01
-- Home feed: open restaurants in Koramangala, best rated first
-- unchanged (served by idx_localities_name and idx_restaurants_locality_open_rating)
SELECT r.restaurant_id, r.name, r.cuisines, r.avg_cost_for_two, r.rating
FROM restaurants r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.locality_name = 'Koramangala'
  AND r.status = 'OPEN'
ORDER BY r.rating DESC NULLS LAST
LIMIT 20;

-- @R02
-- Dish search: available "paneer" dishes in Bengaluru
-- unchanged (served by idx_menu_items_name_trgm)
SELECT m.item_id, m.item_name, m.price, r.name AS restaurant
FROM menu_items m
JOIN restaurants r ON r.restaurant_id = m.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE l.city_id = 1
  AND m.is_available
  AND m.item_name ILIKE '%paneer%'
ORDER BY m.price
LIMIT 50;

-- @R03
-- Restaurant page: the menu of one restaurant, grouped by category
-- unchanged (already an Index Scan in the baseline)
SELECT category, item_name, price, is_veg, is_bestseller
FROM menu_items
WHERE restaurant_id = 217 AND is_available
ORDER BY category, is_bestseller DESC, item_name;

-- @R04
-- "Your orders": a customer's last 10 orders with restaurant names
-- unchanged (served by idx_orders_customer_placed)
SELECT o.order_id, r.name AS restaurant, o.status, o.total_amount, o.placed_at
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
WHERE o.customer_id = 1042
ORDER BY o.placed_at DESC
LIMIT 10;

-- @R05
-- Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes (checked at 23:59 on 30 Jun 2026)
-- unchanged (served by idx_orders_preparing_accepted)
SELECT order_id, restaurant_id, accepted_at
FROM orders
WHERE status = 'PREPARING'
  AND accepted_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '40 minutes'
ORDER BY accepted_at;

-- @R06
-- Restaurant partner app: all orders received by restaurant 217 on 15 June 2026
-- REWRITTEN: DATE(placed_at) = '...' applies a function to the column, so no index
-- can be used. Replaced with a half-open range on placed_at (sargable). Same rows,
-- assuming the session time zone is +05:30 (IST), which the original DATE() relied on.
SELECT order_id, status, item_total, placed_at
FROM orders
WHERE restaurant_id = 217
  AND placed_at >= TIMESTAMPTZ '2026-06-15 00:00:00+05:30'
  AND placed_at <  TIMESTAMPTZ '2026-06-16 00:00:00+05:30'
ORDER BY placed_at;

-- @R07
-- Restaurant partner app: units sold per dish in May 2026
-- unchanged (served by idx_orders_restaurant_placed)
SELECT m.item_name, sum(oi.quantity) AS units, sum(oi.quantity * oi.unit_price) AS sales
FROM order_items oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN menu_items m ON m.item_id  = oi.item_id
WHERE o.restaurant_id = 217
  AND o.status = 'DELIVERED'
  AND o.placed_at >= '2026-05-01' AND o.placed_at < '2026-06-01'
GROUP BY m.item_name
ORDER BY units DESC;

-- @R08
-- Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days
-- unchanged (served by idx_orders_delivered_placed)
SELECT *
FROM (
    SELECT o.restaurant_id, oi.item_id, sum(oi.quantity) AS units,
           RANK() OVER (PARTITION BY o.restaurant_id ORDER BY sum(oi.quantity) DESC) AS rnk
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    JOIN restaurants r  ON r.restaurant_id = o.restaurant_id
    JOIN localities l   ON l.locality_id = r.locality_id
    WHERE l.city_id = 6
      AND o.status = 'DELIVERED'
      AND o.placed_at >= '2026-06-01'
    GROUP BY o.restaurant_id, oi.item_id
) t
WHERE rnk <= 3
ORDER BY restaurant_id, rnk;

-- @R09
-- Ops dashboard: average delivery time (minutes) per city per month in 2026
-- REWRITTEN: EXTRACT(YEAR FROM placed_at) = 2026 wraps the column in a function.
-- Replaced with a range on placed_at, which can use idx_orders_delivered_placed.
-- Same rows under the same +05:30 assumption as R06.
SELECT l.city_id, date_trunc('month', o.placed_at) AS month,
       round(avg(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60), 1) AS avg_minutes
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE o.status = 'DELIVERED'
  AND o.placed_at >= TIMESTAMPTZ '2026-01-01 00:00:00+05:30'
  AND o.placed_at <  TIMESTAMPTZ '2027-01-01 00:00:00+05:30'
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R10
-- Customer support: deliveries in June 2026 that took more than 60 minutes
-- unchanged (range on placed_at uses idx_orders_placed_at; the duration test is a
-- per-row filter and cannot be indexed, so it stays as it is)
SELECT order_id, customer_id, restaurant_id, placed_at, delivered_at
FROM orders
WHERE delivered_at - placed_at > interval '60 minutes'
  AND placed_at >= '2026-06-01' AND placed_at < '2026-07-01'
ORDER BY delivered_at - placed_at DESC
LIMIT 100;

-- @R11
-- Delivery partner app: this week's earnings (delivery fees) for partner 150
-- unchanged (served by idx_orders_partner_placed)
SELECT count(*) AS deliveries, sum(delivery_fee) AS fees_earned
FROM orders
WHERE partner_id = 150
  AND status = 'DELIVERED'
  AND placed_at >= '2026-06-22' AND placed_at < '2026-06-29';

-- @R12
-- Dispatch: orders still waiting for a delivery partner, oldest first
-- unchanged (served by idx_orders_unassigned_placed)
SELECT o.order_id, o.restaurant_id, o.status, o.placed_at
FROM orders o
WHERE o.partner_id IS NULL
  AND o.status IN ('PLACED', 'ACCEPTED')
ORDER BY o.placed_at
LIMIT 50;

-- @R13
-- Fleet team: active Bengaluru partners who have not been assigned any order since 25 June 2026
-- REWRITTEN (wrong-result fix): the original "partner_id NOT IN (SELECT partner_id ...)"
-- returns NO rows whenever the subquery produces a NULL. orders.partner_id is NULL for
-- unassigned orders, so once one of them falls after 25 June 2026 the NOT IN is
-- UNKNOWN for every partner and the list comes back empty. NOT EXISTS treats NULL as
-- "no match", so it returns the correct list.
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND NOT EXISTS (
        SELECT 1
        FROM orders o
        WHERE o.partner_id = p.partner_id
          AND o.placed_at >= '2026-06-25'
  );

-- @R14
-- Gold team: Gold members whose membership expires before July 2026 but who ordered in June 2026
-- unchanged (served by idx_customers_gold_expiry and idx_orders_customer_placed)
SELECT c.customer_id, c.full_name, c.gold_expires_on
FROM customers c
WHERE c.is_gold_member
  AND c.gold_expires_on < '2026-07-01'
  AND EXISTS (SELECT 1 FROM orders o
              WHERE o.customer_id = c.customer_id
                AND o.placed_at >= '2026-06-01' AND o.placed_at < '2026-07-01');

-- @R15
-- Marketing: coupon effectiveness (orders, total discount, average bill)
-- unchanged (served by idx_orders_coupon)
SELECT c.coupon_code, c.discount_pct, count(o.order_id) AS orders,
       coalesce(sum(o.discount), 0) AS total_discount, round(avg(o.total_amount), 2) AS avg_bill
FROM coupons c
LEFT JOIN orders o ON o.coupon_code = c.coupon_code AND o.status = 'DELIVERED'
GROUP BY c.coupon_code, c.discount_pct
ORDER BY orders DESC;

-- @R16
-- Payments team: failed payment attempts per method in the last 7 days
-- unchanged (served by idx_payments_failed_attempted)
SELECT method, count(*) AS failed_attempts
FROM payments
WHERE payment_status = 'FAILED'
  AND attempted_at >= '2026-06-24'
GROUP BY method
ORDER BY failed_attempts DESC;

-- @R17
-- Risk team: customers with 2 or more failed payment attempts (all time)
-- unchanged (served by idx_payments_failed_order)
SELECT o.customer_id, count(*) AS failed_attempts
FROM payments p
JOIN orders o ON o.order_id = p.order_id
WHERE p.payment_status = 'FAILED'
GROUP BY o.customer_id
HAVING count(*) >= 2
ORDER BY failed_attempts DESC, o.customer_id;

-- @R18
-- Review moderation: newest reviews that complain about cold food or late delivery
-- unchanged (served by idx_reviews_text_trgm)
SELECT review_id, restaurant_id, food_rating, review_text, created_at
FROM reviews
WHERE review_text ILIKE '%cold%' OR review_text ILIKE '%late%'
ORDER BY created_at DESC
LIMIT 50;

-- @R19
-- Restaurant health report for Bengaluru: last order time, delivered orders and average food rating
-- REWRITTEN: the original ran three correlated subqueries per restaurant, so each
-- restaurant re-scanned orders and reviews. This version aggregates each table once
-- (GROUP BY restaurant_id, limited to Bengaluru) and joins the results back.
-- Output columns, NULL handling (no orders -> last_order_at NULL, delivered 0,
-- no reviews -> rating NULL) and ordering are the same as the original.
WITH bengaluru AS (
    SELECT r.restaurant_id, r.name
    FROM restaurants r
    JOIN localities l ON l.locality_id = r.locality_id
    WHERE l.city_id = 1
),
order_stats AS (
    SELECT o.restaurant_id,
           max(o.placed_at) AS last_order_at,
           count(*) FILTER (WHERE o.status = 'DELIVERED') AS delivered_orders
    FROM orders o
    JOIN bengaluru b ON b.restaurant_id = o.restaurant_id
    GROUP BY o.restaurant_id
),
review_stats AS (
    SELECT v.restaurant_id,
           round(avg(v.food_rating), 2) AS avg_food_rating
    FROM reviews v
    JOIN bengaluru b ON b.restaurant_id = v.restaurant_id
    GROUP BY v.restaurant_id
)
SELECT b.restaurant_id, b.name,
       os.last_order_at,
       coalesce(os.delivered_orders, 0) AS delivered_orders,
       rs.avg_food_rating
FROM bengaluru b
LEFT JOIN order_stats  os ON os.restaurant_id = b.restaurant_id
LEFT JOIN review_stats rs ON rs.restaurant_id = b.restaurant_id
ORDER BY last_order_at DESC NULLS LAST;

-- @R20
-- Growth: top 20 customers in Mumbai by total spend on delivered orders
-- unchanged (served by idx_orders_customer_delivered and idx_customers_city)
SELECT c.customer_id, c.full_name, count(*) AS orders, sum(o.total_amount) AS lifetime_spend
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE c.city_id = 2 AND o.status = 'DELIVERED'
GROUP BY c.customer_id, c.full_name
ORDER BY lifetime_spend DESC
LIMIT 20;

-- @R21
-- Growth: share of customers in each city who ordered at least twice in May 2026
-- unchanged (served by idx_orders_placed_at, index only scan)
WITH may AS (
    SELECT customer_id, count(*) AS n
    FROM orders
    WHERE placed_at >= '2026-05-01' AND placed_at < '2026-06-01'
    GROUP BY customer_id
)
SELECT c.city_id,
       count(*) AS ordering_customers,
       count(*) FILTER (WHERE may.n >= 2) AS repeat_customers,
       round(100.0 * count(*) FILTER (WHERE may.n >= 2) / count(*), 1) AS repeat_pct
FROM may
JOIN customers c ON c.customer_id = may.customer_id
GROUP BY c.city_id
ORDER BY c.city_id;

-- @R22
-- Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks
-- unchanged (served by idx_orders_placed_at and idx_restaurants_locality)
SELECT EXTRACT(ISODOW FROM o.placed_at) AS weekday, EXTRACT(HOUR FROM o.placed_at) AS hour, count(*) AS orders
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE l.city_id = 1
  AND o.placed_at >= TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '8 weeks'
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R23
-- Admin panel: "All orders", newest first, page 4,001 (25 rows per page)
-- unchanged. Not rewritten to keyset pagination: the request is "page 4,001", which is
-- a row offset, not a cursor from the previous page. Served by idx_orders_placed_at
-- (Index Only Scan). OFFSET still skips 100,000 index entries (see the report).
SELECT order_id, customer_id, restaurant_id, status, total_amount, placed_at
FROM orders
ORDER BY placed_at DESC
OFFSET 100000
LIMIT 25;

-- @R24
-- Bill page: one order with its items, restaurant and successful payment
-- unchanged (served by idx_payments_success_order, and the order/item primary keys)
SELECT o.order_id, o.placed_at, r.name AS restaurant, m.item_name, oi.quantity, oi.unit_price,
       o.total_amount, p.method
FROM orders o
JOIN restaurants r  ON r.restaurant_id = o.restaurant_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN menu_items m   ON m.item_id = oi.item_id
LEFT JOIN payments p ON p.order_id = o.order_id AND p.payment_status = 'SUCCESS'
WHERE o.order_id = 123457;

-- @R25
-- Cuisine filter: open Chinese restaurants in Pune
-- REWRITTEN: 'Chinese' = ANY (r.cuisines) cannot use the GIN index on cuisines.
-- "cuisines @> ARRAY['Chinese']" is the same test ("the array contains 'Chinese'")
-- and can use idx_restaurants_cuisines.
SELECT r.restaurant_id, r.name, r.cuisines, r.rating
FROM restaurants r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 6
  AND r.status = 'OPEN'
  AND r.cuisines @> ARRAY['Chinese']::text[]
ORDER BY r.rating DESC NULLS LAST;

-- @W01
-- Customer app: place a new order (header row)
-- unchanged (the new indexes add a small write cost; see the report)
INSERT INTO orders (order_id, customer_id, restaurant_id, placed_at, distance_km,
                    item_total, delivery_fee, discount, total_amount, status)
VALUES (90000001, 1042, 217, '2026-07-01 13:05:00+05:30', 3.2, 540.00, 25.00, 0.00, 565.00, 'PLACED');

-- @W02
-- Dispatch: assign partner 150 to the oldest accepted order that has no partner
-- unchanged (the subquery is served by idx_orders_unassigned_placed)
UPDATE orders
SET partner_id = 150, status = 'PREPARING'
WHERE order_id = (SELECT order_id FROM orders
                  WHERE partner_id IS NULL AND status = 'ACCEPTED'
                  ORDER BY placed_at
                  LIMIT 1);

-- @W03
-- Restaurant partner app: desserts sold out, so hide them
-- unchanged (served by the menu_items UNIQUE(restaurant_id, item_name) index)
UPDATE menu_items
SET is_available = FALSE
WHERE restaurant_id = 217 AND category = 'Desserts';

-- @W04
-- Nightly job: recompute every restaurant's rating from its reviews
-- unchanged (the aggregate reads idx_reviews_restaurant as an Index Only Scan)
UPDATE restaurants r
SET rating = s.avg_rating, rating_count = s.n
FROM (SELECT restaurant_id, round(avg(food_rating), 1) AS avg_rating, count(*) AS n
      FROM reviews GROUP BY restaurant_id) s
WHERE s.restaurant_id = r.restaurant_id;

-- @W05
-- Nightly job: end Gold membership for customers whose plan has expired
-- unchanged (served by idx_customers_gold_expiry)
UPDATE customers
SET is_gold_member = FALSE
WHERE is_gold_member
  AND gold_expires_on < '2026-07-01';

-- @END
ROLLBACK;
