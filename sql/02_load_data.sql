-- ============================================================================
--  Zomato Food Delivery Database -- Phase 2 data load
--  Run from the REPOSITORY ROOT (the folder that contains seed_data/):
--      psql -d <your_database> -f sql/01_schema.sql
--      psql -d <your_database> -f sql/02_load_data.sql
--  \copy is a psql meta-command: it reads the CSV on the CLIENT machine, so the
--  paths below are relative to your current directory, not to the server.
-- ============================================================================

SET search_path TO zomato;
\timing on

-- Parents first, then children, so every foreign key is already satisfied.
-- Order: cities -> localities -> customers -> restaurants -> menu_items
--        -> delivery_partners -> coupons -> orders -> order_items
--        -> payments -> reviews

\copy zomato.cities            FROM 'seed_data/cities.csv'            WITH (FORMAT csv, HEADER true)
\copy zomato.localities        FROM 'seed_data/localities.csv'        WITH (FORMAT csv, HEADER true)
\copy zomato.customers         FROM 'seed_data/customers.csv'         WITH (FORMAT csv, HEADER true)
\copy zomato.restaurants       FROM 'seed_data/restaurants.csv'       WITH (FORMAT csv, HEADER true)
\copy zomato.menu_items        FROM 'seed_data/menu_items.csv'        WITH (FORMAT csv, HEADER true)
\copy zomato.delivery_partners FROM 'seed_data/delivery_partners.csv' WITH (FORMAT csv, HEADER true)
\copy zomato.coupons           FROM 'seed_data/coupons.csv'           WITH (FORMAT csv, HEADER true)
\copy zomato.orders            FROM 'seed_data/orders.csv'            WITH (FORMAT csv, HEADER true)
\copy zomato.order_items       FROM 'seed_data/order_items.csv'       WITH (FORMAT csv, HEADER true)
\copy zomato.payments          FROM 'seed_data/payments.csv'          WITH (FORMAT csv, HEADER true)
\copy zomato.reviews           FROM 'seed_data/reviews.csv'           WITH (FORMAT csv, HEADER true)

-- ============================================================================
--  Post-load verification (every statement must report the expected number)
-- ============================================================================
ANALYZE;

-- 1. Row counts: must match the seed-data brief exactly
SELECT 'cities'            AS table_name, count(*) AS rows,      10 AS expected FROM zomato.cities
UNION ALL SELECT 'localities',        count(*),     100 FROM zomato.localities
UNION ALL SELECT 'customers',         count(*),   25000 FROM zomato.customers
UNION ALL SELECT 'restaurants',       count(*),    2500 FROM zomato.restaurants
UNION ALL SELECT 'menu_items',        count(*),   50000 FROM zomato.menu_items
UNION ALL SELECT 'delivery_partners', count(*),    2000 FROM zomato.delivery_partners
UNION ALL SELECT 'coupons',           count(*),      30 FROM zomato.coupons
UNION ALL SELECT 'orders',            count(*),  150000 FROM zomato.orders
UNION ALL SELECT 'order_items',       count(*),  375000 FROM zomato.order_items
UNION ALL SELECT 'payments',          count(*),  137378 FROM zomato.payments
UNION ALL SELECT 'reviews',           count(*),   39186 FROM zomato.reviews
ORDER BY table_name;

-- 2. Money identity holds for every order (expect 0 rows)
SELECT count(*) AS orders_where_total_is_wrong
FROM zomato.orders
WHERE total_amount <> item_total + delivery_fee - discount;

-- 3. No orphan children (expect 0 everywhere; FKs already guarantee this,
--    this proves the FKs were actually created)
SELECT
  (SELECT count(*) FROM zomato.order_items oi LEFT JOIN zomato.orders o  ON o.order_id = oi.order_id  WHERE o.order_id  IS NULL) AS orphan_order_items,
  (SELECT count(*) FROM zomato.reviews     v  LEFT JOIN zomato.orders o  ON o.order_id = v.order_id   WHERE o.order_id  IS NULL) AS orphan_reviews,
  (SELECT count(*) FROM zomato.payments    p  LEFT JOIN zomato.orders o  ON o.order_id = p.order_id   WHERE o.order_id  IS NULL) AS orphan_payments,
  (SELECT count(*) FROM zomato.menu_items  m  LEFT JOIN zomato.restaurants r ON r.restaurant_id = m.restaurant_id WHERE r.restaurant_id IS NULL) AS orphan_menu_items;

-- 4. The status/nullability patterns the schema encodes
SELECT status,
       count(*)                                            AS orders,
       count(*) FILTER (WHERE partner_id    IS NULL)        AS null_partner,
       count(*) FILTER (WHERE accepted_at   IS NULL)        AS null_accepted,
       count(*) FILTER (WHERE picked_up_at  IS NULL)        AS null_picked_up,
       count(*) FILTER (WHERE delivered_at  IS NULL)        AS null_delivered
FROM zomato.orders
GROUP BY status
ORDER BY orders DESC;

-- 5. Derived-column consistency: reviews agree with their order (expect 0)
SELECT count(*) AS reviews_disagreeing_with_order
FROM zomato.reviews v
JOIN zomato.orders  o ON o.order_id = v.order_id
WHERE v.customer_id <> o.customer_id
   OR v.restaurant_id <> o.restaurant_id
   OR o.status <> 'DELIVERED';

-- 6. Payment attempts per order -- shows order_id is NOT unique in payments
SELECT attempts, count(*) AS orders FROM (
    SELECT order_id, count(*) AS attempts FROM zomato.payments GROUP BY order_id
) t GROUP BY attempts ORDER BY attempts;

-- 7. Constraint inventory (how many of each type we created)
SELECT contype, count(*) AS constraints
FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
WHERE n.nspname = 'zomato'
GROUP BY contype
ORDER BY contype;   -- c = CHECK, f = FOREIGN KEY, p = PRIMARY KEY, u = UNIQUE
