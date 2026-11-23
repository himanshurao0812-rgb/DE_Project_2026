-- Scale-only problem: the ORIGINAL R19 runs three correlated subqueries per
-- restaurant. This is Kartik's Phase 4 rewrite from sql/06_optimized_queries.sql
-- (verbatim), measured on the LARGE dataset, 3 runs, to show the fix still works
-- at 20x. The original R19 remains the benchmarked workload query.
SET search_path TO zomato;
EXPLAIN (ANALYZE, BUFFERS)
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
EXPLAIN (ANALYZE, BUFFERS)
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
EXPLAIN (ANALYZE, BUFFERS)
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
