-- Labelled SAMPLE of the ORIGINAL R19 on zomato_large_before (NO Phase 4 indexes).
-- Only the outer row source is limited to the first 100 restaurant_id values in
-- city 1 (deterministic); the three correlated SubPlans are EXACTLY as in
-- queries/workload_30.sql. This is NOT the workload query and NOT a full-run
-- measurement -- it is a sampled diagnostic used to estimate the full R19 cost.
SET search_path TO zomato;

\echo '=== R19 unindexed SAMPLE (100 of 8000 restaurants), run 1 of 3 ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.restaurant_id, r.name,
       (SELECT max(o.placed_at) FROM orders o WHERE o.restaurant_id = r.restaurant_id) AS last_order_at,
       (SELECT count(*) FROM orders o WHERE o.restaurant_id = r.restaurant_id AND o.status = 'DELIVERED') AS delivered_orders,
       (SELECT round(avg(v.food_rating), 2) FROM reviews v WHERE v.restaurant_id = r.restaurant_id) AS avg_food_rating
FROM (SELECT r2.* FROM restaurants r2 JOIN localities l2 ON l2.locality_id = r2.locality_id
      WHERE l2.city_id = 1 ORDER BY r2.restaurant_id LIMIT 100) r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 1
ORDER BY last_order_at DESC NULLS LAST;

\echo '=== R19 unindexed SAMPLE (100 of 8000 restaurants), run 2 of 3 ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.restaurant_id, r.name,
       (SELECT max(o.placed_at) FROM orders o WHERE o.restaurant_id = r.restaurant_id) AS last_order_at,
       (SELECT count(*) FROM orders o WHERE o.restaurant_id = r.restaurant_id AND o.status = 'DELIVERED') AS delivered_orders,
       (SELECT round(avg(v.food_rating), 2) FROM reviews v WHERE v.restaurant_id = r.restaurant_id) AS avg_food_rating
FROM (SELECT r2.* FROM restaurants r2 JOIN localities l2 ON l2.locality_id = r2.locality_id
      WHERE l2.city_id = 1 ORDER BY r2.restaurant_id LIMIT 100) r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 1
ORDER BY last_order_at DESC NULLS LAST;

\echo '=== R19 unindexed SAMPLE (100 of 8000 restaurants), run 3 of 3 ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.restaurant_id, r.name,
       (SELECT max(o.placed_at) FROM orders o WHERE o.restaurant_id = r.restaurant_id) AS last_order_at,
       (SELECT count(*) FROM orders o WHERE o.restaurant_id = r.restaurant_id AND o.status = 'DELIVERED') AS delivered_orders,
       (SELECT round(avg(v.food_rating), 2) FROM reviews v WHERE v.restaurant_id = r.restaurant_id) AS avg_food_rating
FROM (SELECT r2.* FROM restaurants r2 JOIN localities l2 ON l2.locality_id = r2.locality_id
      WHERE l2.city_id = 1 ORDER BY r2.restaurant_id LIMIT 100) r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 1
ORDER BY last_order_at DESC NULLS LAST;
