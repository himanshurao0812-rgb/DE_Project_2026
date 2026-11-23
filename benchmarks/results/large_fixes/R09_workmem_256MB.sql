-- Scale-only problem: R09 spills its sort to disk with the default work_mem.
-- Measure the same unmodified R09 text with a larger work_mem, 3 runs.
SET search_path TO zomato;
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT l.city_id, date_trunc('month', o.placed_at) AS month,
       round(avg(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60), 1) AS avg_minutes
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE o.status = 'DELIVERED'
  AND EXTRACT(YEAR FROM o.placed_at) = 2026
GROUP BY 1, 2
ORDER BY 1, 2;
EXPLAIN (ANALYZE, BUFFERS)
SELECT l.city_id, date_trunc('month', o.placed_at) AS month,
       round(avg(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60), 1) AS avg_minutes
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE o.status = 'DELIVERED'
  AND EXTRACT(YEAR FROM o.placed_at) = 2026
GROUP BY 1, 2
ORDER BY 1, 2;
EXPLAIN (ANALYZE, BUFFERS)
SELECT l.city_id, date_trunc('month', o.placed_at) AS month,
       round(avg(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60), 1) AS avg_minutes
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE o.status = 'DELIVERED'
  AND EXTRACT(YEAR FROM o.placed_at) = 2026
GROUP BY 1, 2
ORDER BY 1, 2;
