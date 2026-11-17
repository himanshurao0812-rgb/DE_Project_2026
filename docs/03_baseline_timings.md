# Baseline timings: Zomato Food Delivery Database

**Team T0122 · Checkpoint CP2 · Deliverable: `docs/03_baseline_timings.md`**
**Machine:** MacBook Pro 14-inch (M4 Pro) · **PostgreSQL:** 18.7 · **Database:** untuned (only PK and UNIQUE indexes, see `sql/01_schema.sql`)

## How the numbers were produced

Run from the project root, with the database loaded from `sql/02_load_data.sql`:

```bash
./benchmarks/run_benchmark.sh <your_database> baseline
```

The script runs each query 3 times with `EXPLAIN (ANALYZE, BUFFERS)` and writes:

- `benchmarks/results/baseline/summary.csv` (average, median, min, max, scan nodes for every query)
- `benchmarks/results/baseline/R01.txt` … `W05.txt` (raw plans of all 3 runs)

Write queries (W01 to W05) run inside `BEGIN; … ROLLBACK;`, so the data does not change. Close other heavy applications before measuring, and use the same laptop for Phase 3 and Phase 4.

All values below are the `Execution Time` lines of the raw plan files (ms). The average is the mean of the three runs and matches `summary.csv`.

## Timing table

| Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type and why it is slow or fast |
|---|---|---:|---:|---:|---:|---|
| R01: Home feed: open restaurants in Koramangala, best rated first | READ | 0.621 | 0.531 | 0.548 | 0.567 | Seq Scan on restaurants, small tables and a sort of 20 rows |
| R02: Dish search: available "paneer" dishes in Bengaluru | READ | 10.798 | 7.211 | 6.104 | 8.038 | Seq Scan on restaurants, Index Scan on menu_items, ILIKE cannot use the index |
| R03: Restaurant page: the menu of one restaurant, grouped by category | READ | 0.162 | 0.153 | 0.198 | 0.171 | Index Scan on menu_items (restaurant_id prefix of UNIQUE key), 18 rows |
| R04: "Your orders": a customer's last 10 orders with restaurant names | READ | 15.884 | 9.463 | 8.088 | 11.145 | Seq Scan on orders, no index on customer_id, reads all 150k rows |
| R05: Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes | READ | 7.091 | 6.278 | 6.159 | 6.509 | Parallel Seq Scan on orders, no index on status or accepted_at |
| R06: Restaurant partner app: all orders received by restaurant 217 on 15 June 2026 | READ | 11.422 | 10.668 | 9.429 | 10.506 | Parallel Seq Scan on orders, date(placed_at) hides the column from any index |
| R07: Restaurant partner app: units sold per dish in May 2026 | READ | 9.078 | 7.214 | 10.606 | 8.966 | Parallel Seq Scan on orders, then Index Scans on order_items and menu_items |
| R08: Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days | READ | 9.969 | 11.340 | 6.715 | 9.341 | Parallel Seq Scan on orders, window function over all matching rows |
| R09: Ops dashboard: average delivery time per city per month in 2026 | READ | 24.567 | 24.722 | 25.363 | 24.884 | Parallel Seq Scan on orders, EXTRACT(year) on the column blocks the index |
| R10: Customer support: deliveries in June 2026 that took more than 60 minutes | READ | 5.200 | 5.101 | 5.346 | 5.216 | Parallel Seq Scan on orders, delivered_at minus placed_at cannot use an index |
| R11: Delivery partner app: this week's earnings (delivery fees) for partner 150 | READ | 6.621 | 6.420 | 6.692 | 6.578 | Parallel Seq Scan on orders, no index on partner_id |
| R12: Dispatch: orders still waiting for a delivery partner, oldest first | READ | 9.965 | 7.725 | 7.738 | 8.476 | Seq Scan on orders, no index on partner_id IS NULL, sort of 50 rows |
| R13: Fleet team: active Bengaluru partners who have not been assigned any order since 25 June 2026 | READ | 8.922 | 9.116 | 8.942 | 8.993 | Seq Scan on delivery_partners and Seq Scan on orders (hashed subplan) |
| R14: Gold team: Gold members whose membership expires before July 2026 but who ordered in June 2026 | READ | 7.496 | 7.381 | 7.235 | 7.371 | Seq Scan on orders and on customers, hash semi join |
| R15: Marketing: coupon effectiveness (orders, total discount, average bill) | READ | 14.816 | 15.190 | 15.454 | 15.153 | Seq Scan on orders (130k delivered rows), hash join to coupons |
| R16: Payments team: failed payment attempts per method in the last 7 days | READ | 5.647 | 5.605 | 5.068 | 5.440 | Seq Scan on payments (137k rows), no index on payment_status or attempted_at |
| R17: Risk team: customers with 2 or more failed payment attempts (all time) | READ | 17.184 | 17.652 | 18.349 | 17.728 | Seq Scan on orders and on payments, hash join of full tables |
| R18: Review moderation: newest reviews that complain about cold food or late delivery | READ | 7.945 | 8.066 | 7.620 | 7.877 | Seq Scan on reviews, ILIKE '%cold%' cannot use an index |
| R19: Restaurant health report for Bengaluru: last order time, delivered orders and average food rating | READ | 4350.435 | 4335.202 | 4477.883 | 4387.840 | Seq Scan on orders and reviews inside 400 correlated subplans, about 60M row checks per subplan |
| R20: Growth: top 20 customers in Mumbai by total spend on delivered orders | READ | 23.319 | 21.958 | 21.057 | 22.111 | Seq Scan on orders (130k delivered rows) and on customers, hash join |
| R21: Growth: share of customers in each city who ordered at least twice in May 2026 | READ | 11.355 | 10.919 | 11.254 | 11.176 | Seq Scan on orders for May, then hash join to customers |
| R22: Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks | READ | 16.126 | 16.420 | 16.019 | 16.188 | Seq Scan on orders (15k rows in the range), hash join to restaurants |
| R23: Admin panel: "All orders", newest first, page 4,001 (25 rows per page) | READ | 37.038 | 37.890 | 36.807 | 37.245 | Seq Scan on orders, full sort of 150k rows on disk to skip 100k rows |
| R24: Bill page: one order with its items, restaurant and successful payment | READ | 6.830 | 6.820 | 7.069 | 6.906 | Index Scans on orders, restaurants, order_items, menu_items, but Seq Scan on payments |
| R25: Cuisine filter: open Chinese restaurants in Pune | READ | 0.283 | 0.277 | 0.272 | 0.277 | Seq Scan on restaurants (array filter), small tables |
| W01: Customer app: place a new order (header row) | WRITE | 0.811 | 0.508 | 0.507 | 0.609 | No scan, one INSERT plus 4 foreign key trigger checks |
| W02: Dispatch: assign partner 150 to the oldest accepted order that has no partner | WRITE | 9.124 | 8.725 | 11.692 | 9.847 | Seq Scan on orders to find the oldest match, then Index Scan on orders_pkey |
| W03: Restaurant partner app: desserts sold out, so hide them | WRITE | 0.160 | 0.530 | 0.547 | 0.412 | Index Scan on menu_items (restaurant_id prefix), 2 rows updated |
| W04: Nightly job: recompute every restaurant's rating from its reviews | WRITE | 21.859 | 19.630 | 16.100 | 19.196 | Seq Scan on reviews (39k rows) to aggregate, then Seq Scan on restaurants to update |
| W05: Nightly job: end Gold membership for expired plans | WRITE | 22.442 | 23.396 | 20.455 | 22.098 | Seq Scan on customers (25k rows), updates 1,230 rows |
| **Total (sum of all 30 averages)** | | | | | **4696.864** | |

## Scan types

Scan types come from the plan of the last run. Write one line per query on why it is slow or fast on this untuned schema.

- R01: Seq Scan on restaurants and localities. Both tables are small and the status filter keeps most rows, so it is fast.
- R02: Seq Scan on restaurants and localities, Index Scan on menu_items. The ILIKE '%paneer%' pattern cannot use the index, so every menu row for the city's restaurants is checked.
- R03: Index Scan on menu_items_restaurant_name_key. The UNIQUE key starts with restaurant_id, so the 20 rows are found directly.
- R04: Seq Scan on orders. There is no index on customer_id, so all 150k rows are read to find 9 orders.
- R05: Parallel Seq Scan on orders. No index on status or accepted_at, so the full table is read.
- R06: Parallel Seq Scan on orders. date(placed_at) wraps the column, so an index on placed_at could not be used.
- R07: Parallel Seq Scan on orders, then Index Scans on order_items and menu_items. The date and restaurant filters have no index.
- R08: Parallel Seq Scan on orders. The date and status filters have no index, and the window function runs on all matches.
- R09: Parallel Seq Scan on orders. EXTRACT(year FROM placed_at) hides the column, and the whole table is aggregated.
- R10: Parallel Seq Scan on orders. The delivery-time expression cannot be indexed, so every row is checked.
- R11: Parallel Seq Scan on orders. There is no index on partner_id.
- R12: Seq Scan on orders. There is no index on partner_id or status, so all 150k rows are checked to find 75.
- R13: Seq Scan on delivery_partners, and Seq Scan on orders inside the hashed subplan. The NOT IN list needs the full orders table.
- R14: Seq Scan on orders and customers, combined with a hash semi join. Both date and Gold-status filters have no index.
- R15: Seq Scan on orders, hash right join to coupons. No index on status or coupon_code.
- R16: Seq Scan on payments. No index on payment_status or attempted_at, so all 137k rows are read to find 82.
- R17: Seq Scan on orders and payments, hash join. Both full tables are read for all-time failed payments.
- R18: Seq Scan on reviews. ILIKE '%cold%' and '%late%' cannot use a B-tree index.
- R19: Seq Scan on orders and reviews inside three correlated subplans that run 400 times each. Each run scans all 150k orders, about 60M row checks per subplan, so this is the slowest query at about 4.4 seconds.
- R20: Seq Scan on orders and customers, hash join. The delivered filter and city filter have no index.
- R21: Seq Scan on orders for May, then hash join to customers. No index on placed_at.
- R22: Seq Scan on orders for the 8-week range, then hash join to restaurants and localities.
- R23: Seq Scan on orders, then an external merge sort of 150k rows on disk. OFFSET 100000 forces the database to sort and skip most of the table.
- R24: Index Scans on orders, restaurants, order_items and menu_items, so these lookups are fast. The payments lookup is a Seq Scan over 137k rows and is the main cost.
- R25: Seq Scan on restaurants and localities. The cuisine array filter is applied to all 2,500 rows, but the tables are small.
- W01: No scan. One INSERT with four foreign key checks (customer, restaurant, partner, coupon).
- W02: Seq Scan on orders to find the oldest unassigned accepted order, then Index Scan on orders_pkey to update it.
- W03: Index Scan on menu_items_restaurant_name_key. Restaurant 217 is found directly and 2 dessert rows are updated.
- W04: Seq Scan on reviews to aggregate ratings, then a hash join that updates every restaurant (2,390 rows).
- W05: Seq Scan on customers. There is no index on is_gold_member or gold_expires_on, so all 25k rows are checked.
