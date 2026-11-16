# Phase 1 — Problem Understanding

**Zomato Food Delivery Database (Team T0122)** · Phase 1 · contributes 2 marks to *Query Execution*

Zomato runs delivery in 10 cities × 10 localities. We inherit 11 data exports (~150,000 orders, Jan 2025 – Jun 2026) with **no documented schema**, and product teams have filed 10 complaints covering the 25 read queries (R01–R25) and 5 write queries (W01–W05) that matter most. Phase 1 translates those complaints into business needs, owners and performance targets; later phases measure and fix them.

## Problems, stakeholders and classification

| # | What the business actually needs | Stakeholder affected | Class |
|---|----------------------------------|----------------------|-------|
| **P1** | When a hungry user opens the app at lunch/dinner peak, the home feed must show nearby restaurants (filtered by locality, cuisine, open-now, rating) and a single restaurant page must render its menu immediately. Waiting seconds loses the order. | **Customer** | Customer-facing / **real-time** |
| **P2** | As a user types "paneer" or "biryani", matching dishes from all 50,000 menu items must appear keystroke-by-keystroke. Search is a discovery channel; a slow box means the user never finds the dish. | **Customer** (Search team) | Customer-facing / **real-time** |
| **P3** | A user must be able to open "your orders" (last 10 orders with restaurant names) and any past bill (order + items + restaurant + successful payment) instantly, whenever they want to reorder or dispute. | **Customer** (Support-adjacent) | Customer-facing / **real-time** |
| **P4** | A restaurant owner must see **today's** incoming orders the moment they arrive, and per-dish units/sales for a day, month or the last 30 days, so they can plan kitchen prep and flag bestsellers. | **Restaurant partner** | **Real-time** for today's order list; **analytics** for dish-wise rollups (R07, R08) |
| **P5** | Dispatch must keep a live board of orders with no rider assigned and orders stuck in PREPARING > 40 min, refreshed every few seconds, and must assign a rider / accept a new order in milliseconds. A stale board means cold food. | **Dispatch / Ops; delivery partner** | **Real-time**, high-frequency polling + writes |
| **P6** | Fleet wants the list of ACTIVE riders in a city who got **no order** in the last few days, so idle capacity can be re-allocated. Today the list comes back **empty**, so the team is flying blind. This is a **wrong result, not just a slow one**. | **Fleet / Ops** | Reporting, but first a **correctness bug** |
| **P7** | Payments wants failed attempts per method in the last 7 days (gateway health) and risk wants customers with ≥2 failures ever (fraud/abuse signals), refreshed continuously so a broken gateway is caught within minutes. | **Payments / Risk** | **Real-time / near-real-time** analytics |
| **P8** | Gold wants members whose plan expires soon but who are still ordering (win-back), and Marketing wants coupon ROI (orders, discount given, average bill), top spenders per city and repeat-purchase share — all currently **timing out**. | **Gold team; Marketing / Growth** | **Reporting / analytics** |
| **P9** | Support agents on a live call must find deliveries that crossed 60 minutes and reviews mentioning "cold" or "late", newest first, within a second or two. | **Support / CX** | **Ad-hoc reporting**, interactive latency |
| **P10** | Leadership needs delivery-time trends per city per month, per-restaurant health (last order, delivered count, avg food rating), weekday×hour order heatmaps, a pageable admin order list, and a nightly rating recompute — and order volume will grow **20×** next year. | **Ops / Leadership; Admin** | **Reporting / analytics** (R23 admin paging is user-facing) |

### Why the classification matters
- **Real-time / customer-facing (P1–P5, P7)** → target **≤ 100 ms** for customer queries, **≤ 200 ms** for partner/dispatch screens, because these run many times per second and a human is waiting.
- **Reporting / analytics (P8–P10)** → target **≤ 2 s** for an interactive report and **≤ 30 s** for a nightly batch; correctness and stability matter more than a few milliseconds.
- **P6 is neither**: it is a logical defect that must be fixed before any timing is meaningful.

## Assumptions

1. **Workload size.** 150,000 orders over 18 months ≈ 8,300 orders/month. Phase 5's "20×" therefore means ≈ 3 million orders, 7.5 M order_items and ~2.7 M payments.
2. **No targets were given by the product teams**, so the latency targets above (100 ms / 200 ms / 2 s / 30 s) are our own SLAs, stated here so Phase 4 can be judged against them.
3. **Data is a frozen snapshot** at 30 Jun 2026, 23:59 IST; the given queries use fixed literal dates, so all timings and results are reproducible. All timestamps are `timestamptz` in Asia/Kolkata.
4. **One order may have several payment attempts.** Verified: 6,965 orders have more than one attempt, and the final successful attempt is the one that matters — so `payments.order_id` is *not* unique.
5. **Lifecycle columns are NULL until the order reaches that stage.** 13,538 orders have no `partner_id` (cancelled or still open), so any `NOT IN (subquery on partner_id)` silently returns nothing. **This is the cause of P6, and we have reproduced it:** against our loaded schema, R13 as given returns **0 rows**, while the semantically correct `NOT EXISTS` form returns **132 rows** for the 285 ACTIVE Bengaluru partners, because the subquery contains **206 NULL `partner_id` rows**. P6 is therefore a *correctness* defect, not a performance one — it must be reported and fixed, and any "speed-up" on a query returning nothing would be a false victory.
6. **Only `DELIVERED` means realised revenue.** 19,437 orders were cancelled (12,014 by customer, 7,423 by restaurant), which is why most reports filter `status = 'DELIVERED'`; cancelled rows must never be counted as sales.
7. **Prices are historical.** `order_items.unit_price` is the price at order time, not today's `menu_items.price`; revenue attribution must use it and not re-join current prices.
8. **Denormalised columns are deliberate caches.** `orders.total_amount`, `restaurants.rating`/`rating_count`, `is_pure_veg` and `reviews.customer_id`/`restaurant_id` are derived values kept for read speed; W04/W05 are the jobs that refresh them. We will justify keeping them in Phase 2 instead of normalising them away.
9. **We may not change any query's result.** Phase 4 only adds indexes, rewrites plans and optionally partitions — the answer set of all 30 queries must stay identical.
