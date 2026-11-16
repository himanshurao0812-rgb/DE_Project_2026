# Phase 2 — Schema Design

**Zomato Food Delivery Database · Team T0122 · PostgreSQL 18.6**
Companion files: [`sql/01_schema.sql`](../sql/01_schema.sql) · [`sql/02_load_data.sql`](../sql/02_load_data.sql) · [`diagrams/er_diagram.png`](../diagrams/er_diagram.png)

> **Status: pending verification on PostgreSQL 18.6.** The DDL in `sql/01_schema.sql` loads **all 640,094 rows of the seed data with zero errors** on a clean PostgreSQL 18 database, and **all 30 workload queries (R01–R25, W01–W05) execute without error** against it. Every number quoted below was produced by running the DDL, not estimated.

---

## 1. How the schema was derived

No `CREATE TABLE` statements were supplied, so the schema was reverse-engineered from the 11 CSV exports in three passes:

1. **Shape pass** — headers, row counts, and value domains of every column (`awk`/Python over the CSVs) to fix column names, types and candidate keys.
2. **Dependency pass** — which values repeat (→ foreign keys), which columns are unique (→ natural keys), which columns go empty and *when* (→ NULL-ability rules tied to `status`).
3. **Constraint pass** — every rule the business states or the data implies was written as a CHECK, then the load was re-run; any rejection was investigated as either *my constraint is wrong* or *the data has a problem* (both cases occurred — §7).

Guiding principle: **constraints must accept 100% of real data.** A constraint that rejects a legitimate row is a bug in the schema, not in the data.

---

## 2. Entity–relationship model

**Diagram:** `diagrams/er_diagram.png` (source: `diagrams/er_diagram.dot`, rendered with Graphviz). Mermaid source is in §9 so it can be pasted into any Markdown viewer.

### 2.1 Cardinalities

| Relationship | Cardinality | Enforced by |
|---|---|---|
| cities → localities | 1 : N (10 cities × 10 localities) | `localities.city_id` NOT NULL FK |
| cities → customers | 1 : N | `customers.city_id` NOT NULL FK |
| cities → delivery_partners | 1 : N (riders belong to a city, not a locality) | `delivery_partners.city_id` NOT NULL FK |
| localities → restaurants | 1 : N | `restaurants.locality_id` NOT NULL FK |
| restaurants → menu_items | 1 : N (a dish belongs to exactly one kitchen) | `menu_items.restaurant_id` NOT NULL FK |
| customers → orders | 1 : N | `orders.customer_id` NOT NULL FK |
| restaurants → orders | 1 : N | `orders.restaurant_id` NOT NULL FK |
| delivery_partners → orders | 1 : **0..N** (nullable — 13,538 orders have no rider) | `orders.partner_id` NULLABLE FK |
| coupons → orders | 1 : **0..N** (only 20,208 orders used a coupon) | `orders.coupon_code` NULLABLE FK |
| orders → order_items | 1 : N (2.5 lines per order on average) | `order_items.order_id` FK, composite PK |
| menu_items → order_items | 1 : N | `order_items.item_id` FK |
| orders → payments | 1 : **0..N** — **not** 1:1 (6,965 orders have 2 attempts) | `payments.order_id` FK, **no** UNIQUE |
| orders → reviews | 1 : **0..1** (a review exists only for a delivered order) | `reviews.order_id` FK + **UNIQUE** |
| customers → reviews | 1 : N | `reviews.customer_id` FK (derived, kept) |
| restaurants → reviews | 1 : N | `reviews.restaurant_id` FK (derived, kept) |

### 2.2 The three M:N relationships, resolved

`orders`, `order_items` and `payments` are associative/fact tables that resolve many-to-many relationships:

- **customer ⇄ restaurant** is M:N, resolved by **`orders`** (the central fact table).
- **order ⇄ menu_item** is M:N ("an order contains many dishes, a dish appears in many orders"), resolved by **`order_items`** with the composite key `(order_id, item_id)`.
- **order ⇄ payment** is 1:N because retries are real — the same order can be attempted twice.

---

## 3. Data dictionary

Conventions: all money is `NUMERIC` (never `float`/`double` — binary floating point cannot represent 0.10 exactly and would break the bill identity check). All event times are `TIMESTAMPTZ` because the CSVs carry a `+05:30` offset. Surrogate ids are `INTEGER` where the source fits in 4 bytes, and `BIGINT` for `orders`/`payments`/`order_items` keys because Phase 5 will grow them 20×.

### 3.1 `cities` — 10 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `city_id` | `INTEGER` | NO | PK | |
| `city_name` | `TEXT` | NO | UNIQUE | natural key — 10 distinct, no duplicates |
| `state` | `TEXT` | NO | | |

### 3.2 `localities` — 100 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `locality_id` | `INTEGER` | NO | PK | |
| `city_id` | `INTEGER` | NO | FK → `cities` | RESTRICT |
| `locality_name` | `TEXT` | NO | UNIQUE with `city_id` | names are unique globally in this data, but the *business* key is (city, name) |
| `pincode` | `VARCHAR(6)` | NO | | Indian PIN codes have exactly 6 digits → CHECK regex, not a number (leading zeros matter) |

### 3.3 `customers` — 25,000 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `customer_id` | `INTEGER` | NO | PK | |
| `full_name` | `TEXT` | NO | | |
| `email` | `TEXT` | NO | UNIQUE | 25,000 distinct case-insensitively; `TEXT` not `VARCHAR(n)` — PostgreSQL has no storage/perf benefit from `VARCHAR(n)` and an arbitrary length limit would reject future valid data |
| `phone` | `VARCHAR(10)` | NO | UNIQUE | all 25,000 are exactly 10 digits starting 9 → `VARCHAR(10)` + regex |
| `city_id` | `INTEGER` | NO | FK → `cities` | RESTRICT |
| `signup_date` | `DATE` | NO | | no time component in source |
| `is_gold_member` | `BOOLEAN` | NO | | `t`/`f` → `BOOLEAN` |
| `gold_expires_on` | `DATE` | **YES** | | NULL for all 21,208 non-gold; set for all 3,792 gold |
| `is_active` | `BOOLEAN` | NO | | |

### 3.4 `restaurants` — 2,500 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `restaurant_id` | `INTEGER` | NO | PK | |
| `name` | `TEXT` | NO | | 2,500 distinct |
| `locality_id` | `INTEGER` | NO | FK → `localities` | RESTRICT |
| `cuisines` | `TEXT[]` | NO | | source is a Python/PostgREST-style array literal `{Desserts,Mughlai}` / `{"Fast Food","North Indian"}`. Stored as **`text[]`** because R25 needs `'Chinese' = ANY (r.cuisines)`. A separate `restaurant_cuisines` table would be purer 1NF but would force R25 to be rewritten — forbidden |
| `avg_cost_for_two` | `NUMERIC(8,2)` | NO | | money |
| `rating` | `NUMERIC(2,1)` | **YES** | | **124 restaurants are unrated** (110 of them OPEN) — a new restaurant has no rating, so NOT NULL would be wrong |
| `rating_count` | `INTEGER` | NO | | 0 allowed |
| `opens_at`, `closes_at` | `TIME` | NO | | clock times, no date, no zone |
| `is_pure_veg` | `BOOLEAN` | NO | | derived from the menu (see §6) |
| `status` | `TEXT` | NO | | domain: `OPEN` (2,232), `TEMPORARILY_CLOSED` (158), `DELISTED` (110) |
| `onboarded_on` | `DATE` | NO | | |

### 3.5 `menu_items` — 50,000 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `item_id` | `INTEGER` | NO | PK | |
| `restaurant_id` | `INTEGER` | NO | FK → `restaurants` | **CASCADE** |
| `item_name` | `TEXT` | NO | UNIQUE with `restaurant_id` | no duplicate dish on one menu (verified 0) |
| `category` | `TEXT` | NO | | domain of exactly 6: Starters, Main Course, Breads, Rice, Desserts, Beverages |
| `price` | `NUMERIC(8,2)` | NO | | 28.00 – 588.00 |
| `is_veg`, `is_bestseller`, `is_available` | `BOOLEAN` | NO | | |

### 3.6 `delivery_partners` — 2,000 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `partner_id` | `INTEGER` | NO | PK | |
| `full_name` | `TEXT` | NO | | |
| `phone` | `VARCHAR(10)` | NO | UNIQUE | |
| `city_id` | `INTEGER` | NO | FK → `cities` | RESTRICT |
| `vehicle_type` | `TEXT` | NO | | 4 values: BIKE 872, SCOOTER 601, EV 269, BICYCLE 258 |
| `joined_on` | `DATE` | NO | | |
| `rating` | `NUMERIC(2,1)` | NO | | 3.4 – 5.0 |
| `status` | `TEXT` | NO | | ACTIVE 1,763, INACTIVE 178, BLOCKED 59 |

### 3.7 `coupons` — 30 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `coupon_code` | `TEXT` | NO | **PK (natural)** | e.g. `DINNER150`; it is the identifier the app sends, and R15 joins on it — no surrogate id needed |
| `discount_pct` | `INTEGER` | NO | | 20–60; whole percent |
| `max_discount` | `NUMERIC(8,2)` | NO | | money cap |
| `min_order_value` | `NUMERIC(8,2)` | NO | | money floor |
| `valid_from`, `valid_to` | `DATE` | NO | | |

### 3.8 `orders` — 150,000 rows (fact table)

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `order_id` | `BIGINT` | NO | PK | source max is 150,000; W01 inserts `90000001` → must exceed `INTEGER` comfort and survive 20× growth |
| `customer_id` | `INTEGER` | NO | FK → `customers` | RESTRICT |
| `restaurant_id` | `INTEGER` | NO | FK → `restaurants` | RESTRICT |
| `partner_id` | `INTEGER` | **YES** | FK → `delivery_partners` | SET NULL; NULL for 13,538 orders |
| `coupon_code` | `TEXT` | **YES** | FK → `coupons` | SET NULL; NULL when no coupon |
| `placed_at` | `TIMESTAMPTZ` | NO | | |
| `accepted_at` | `TIMESTAMPTZ` | **YES** | | NULL for 13,501 |
| `picked_up_at` | `TIMESTAMPTZ` | **YES** | | NULL for 19,549 |
| `delivered_at` | `TIMESTAMPTZ` | **YES** | | NULL for 19,587 — exactly the non-`DELIVERED` orders |
| `distance_km` | `NUMERIC(4,1)` | NO | | 1.0 – 9.5, one decimal |
| `item_total` | `NUMERIC(10,2)` | NO | | money |
| `delivery_fee` | `NUMERIC(10,2)` | NO | | money; free (0.00) for Gold |
| `discount` | `NUMERIC(10,2)` | NO | | 0.00 when no coupon |
| `total_amount` | `NUMERIC(10,2)` | NO | | **derived** — see §6 |
| `status` | `TEXT` | NO | | 7 values: DELIVERED 130,413 · CANCELLED_BY_CUSTOMER 12,014 · CANCELLED_BY_RESTAURANT 7,423 · OUT_FOR_DELIVERY 38 · PLACED 38 · ACCEPTED 37 · PREPARING 37 |

### 3.9 `order_items` — 375,000 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `order_id` | `BIGINT` | NO | **PK**, FK → `orders` | CASCADE |
| `item_id` | `INTEGER` | NO | **PK**, FK → `menu_items` | RESTRICT |
| `quantity` | `SMALLINT` | NO | | only 1, 2 or 3 (125,000 each) → `SMALLINT` is the honest type, and a 50-unit CHECK blocks fat-finger entries |
| `unit_price` | `NUMERIC(8,2)` | NO | | **price at order time**, not today's menu price |

**Composite PK justification:** `order_items` has no id column in the export. `(order_id, item_id)` is unique in the data (375,000 rows, 375,000 distinct pairs, **0 duplicates**), and it is semantically right: a dish cannot appear twice in one order — you increase `quantity` instead. Using a surrogate `order_item_id` would invent a key the application never sees.

### 3.10 `payments` — 137,378 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `payment_id` | `BIGINT` | NO | PK | |
| `order_id` | `BIGINT` | NO | FK → `orders` (**not unique**) | CASCADE; 123,448 orders paid once, **6,965 paid twice** |
| `amount` | `NUMERIC(10,2)` | NO | | equals the order's `total_amount` for all 137,378 rows (0 mismatches) |
| `method` | `TEXT` | NO | | UPI 62,083 · CARD 30,678 · COD 29,051 · WALLET 15,566 |
| `payment_status` | `TEXT` | NO | | SUCCESS 129,109 · FAILED 6,965 · REFUNDED 1,304 |
| `attempted_at` | `TIMESTAMPTZ` | NO | | |

### 3.11 `reviews` — 39,186 rows

| Column | Type | Null | Key | Notes |
|---|---|---|---|---|
| `review_id` | `INTEGER` | NO | PK | |
| `order_id` | `BIGINT` | NO | **UNIQUE**, FK → `orders` | CASCADE; one review per order (verified) |
| `customer_id` | `INTEGER` | NO | FK → `customers` | RESTRICT; derived, kept (§6) |
| `restaurant_id` | `INTEGER` | NO | FK → `restaurants` | RESTRICT; derived, kept (§6) |
| `food_rating` | `SMALLINT` | NO | | 1–5, never null |
| `delivery_rating` | `SMALLINT` | **YES** | | **NULL for 7,741 rows** — customers may rate the food and skip the delivery rating |
| `review_text` | `TEXT` | **YES** | | NULL for 21,405 rows (rating without a comment) |
| `created_at` | `TIMESTAMPTZ` | NO | | |

---

## 4. Keys, foreign keys and delete rules

| FK | Rule | Why this rule |
|---|---|---|
| `localities.city_id` | **RESTRICT** | Master geography. Deleting a city would orphan localities *and* silently invalidate every customer/report scoped to it. Cities are deactivated in the product, not deleted. |
| `customers.city_id` | **RESTRICT** | A customer must always belong to a serviceable city. |
| `restaurants.locality_id` | **RESTRICT** | You cannot remove a locality while a restaurant still trades there. |
| `menu_items.restaurant_id` | **CASCADE** | A menu has no independent existence — if a restaurant record is truly removed, its dishes must go with it (otherwise `menu_items` accumulates dead rows that R02 dish-search would surface). |
| `delivery_partners.city_id` | **RESTRICT** | Fleet must stay city-scoped for dispatch. |
| `orders.customer_id` | **RESTRICT** | **Financial history must never disappear.** Customers are deactivated via `is_active = FALSE`; a hard delete would destroy orders, payments and reviews. |
| `orders.restaurant_id` | **RESTRICT** | Same: a `DELISTED` restaurant keeps its orders for accounting and for R19's health report. |
| `orders.partner_id` | **SET NULL** | If a rider record is ever removed, the *order* must survive — it becomes unassigned again, exactly the state dispatch handles. Cascading here would delete revenue. |
| `orders.coupon_code` | **SET NULL** | Retiring an expired coupon must not delete or block historical orders; the `discount` column already preserves what was given away. |
| `order_items.order_id` | **CASCADE** | A line item is meaningless without its order (it is a weak entity). |
| `order_items.item_id` | **RESTRICT** | Never delete a dish that was ever sold — bills and R07 sales reports depend on it. Dishes are retired with `is_available = FALSE` (that is what W03 does). |
| `payments.order_id` | **CASCADE** | Payment attempts belong to the order. |
| `reviews.order_id` | **CASCADE** | A review without its order cannot be validated. |
| `reviews.customer_id`, `reviews.restaurant_id` | **RESTRICT** | Same protection as orders; and they are redundant copies of `orders` values, so blocking is safest. |

**Summary:** everything that carries money or history is `RESTRICT` or `SET NULL`; only true weak entities (`order_items`, `payments`, `reviews`, `menu_items`) cascade.

---

## 5. Constraints (45 CHECK · 15 FK · 11 PK · 7 UNIQUE)

The README asks for **at least 12 meaningful** CHECK/NOT NULL/UNIQUE constraints. The schema has **45 CHECK** constraints; the ones that encode a real business rule are listed here with the reason.

| # | Constraint | Rule it enforces | Why the business needs it |
|---|---|---|---|
| 1 | `orders_total_is_derived` | `total_amount = item_total + delivery_fee - discount` | **The bill identity.** Verified exact on all 150,000 rows (0 exceptions). Catches a broken app or a partial write, and lets us trust `total_amount` in every revenue report. |
| 2 | `orders_time_order` | `placed_at ≤ accepted_at ≤ picked_up_at ≤ delivered_at` | The pipeline only moves forward. 0 violations in the data; a negative delivery time would poison R09/R10 averages. |
| 3 | `orders_delivered_iff_timestamp` | `(status='DELIVERED') = (delivered_at IS NOT NULL)` | Ties the *state* to the *timestamp*. True for all 150,000 rows. Without it, "delivered" orders with no time break every delivery-time report. |
| 4 | `orders_pickup_required` | `picked_up_at IS NOT NULL` once `OUT_FOR_DELIVERY`/`DELIVERED` | You cannot deliver food you never collected. |
| 5 | `orders_accepted_required` | `accepted_at` required beyond `PLACED`/cancelled | Kitchen cannot prepare without accepting. |
| 6 | `orders_partner_required` | rider required to be `PREPARING`/`OUT_FOR_DELIVERY`/`DELIVERED` | R05's kitchen-delay alert assumes a rider exists; also catches the dispatch bug class. |
| 7 | `orders_money_nonneg` | no negative `item_total`/`delivery_fee`/`discount`/`total_amount` | Negative totals = refunds-as-orders or injection. |
| 8 | `orders_item_total_positive` | `item_total > 0` | An order must contain food; a 0-rupee order would distort average-bill reports (R15, R20). |
| 9 | `orders_discount_le_items` | `discount ≤ item_total` | A coupon can make food free but must never make the bill negative. |
| 10 | `orders_distance_range` | `0 < distance_km ≤ 50` | Delivery is a 10-locality radius; 0 km is impossible and 900 km is a bad GPS read. |
| 11 | `orders_status_check` | one of the 7 lifecycle values | Prevents typo states (`DELIVERED `, `delivered`) that would silently vanish from reports. |
| 12 | `payments_cod_not_failed` | `COD` can never be `FAILED` | **Cross-column business rule:** cash has no gateway, so it cannot fail. Data proves it — COD attempts are only SUCCESS (28,751) or REFUNDED (300). Catches a wrong `method` mapping. |
| 13 | `payments_amount_positive` + `payments_method_check` + `payments_status_check` | amount > 0; 4 methods; 3 statuses | Money domain and enum safety for R16/R17. |
| 14 | `order_items_quantity_check` | `0 < quantity ≤ 50` | Data only has 1–3; 0 or 9,999 is a data-entry fault. |
| 15 | `order_items_unit_price_positive` | price > 0 | You cannot sell a dish for nothing; protects R07's `quantity × unit_price` sales figure. |
| 16 | `restaurants_rating_range` | `rating` between 1.0 and 5.0 (or NULL) | Star ratings are 1–5; data is 3.1–5.0. NULL still allowed for the 124 unrated. |
| 17 | `restaurants_hours_check` | `opens_at < closes_at` | A kitchen cannot close before it opens; guarantees "open-now" logic (R01/R25) is well-defined. |
| 18 | `restaurants_cost_positive` | `avg_cost_for_two > 0` | Drives the ₹ budget filter on the home feed. |
| 19 | `restaurants_cuisines_nonempty` | at least one cuisine, no empty string | R25 does `'Chinese' = ANY(cuisines)`; an empty array makes a restaurant invisible to every cuisine filter. |
| 20 | `restaurants_status_check` / `menu_items_category_check` / `delivery_partners_vehicle_check` / `delivery_partners_status_check` | closed value lists (3, 6, 4, 3 values) | These are enums in the product; the DB should reject invented values. |
| 21 | `delivery_partners_rating_range` | 1.0–5.0 | Same as restaurants. |
| 22 | `customers_gold_needs_expiry` | a Gold member **must** have `gold_expires_on` | No "Gold forever". All 3,792 gold members have a date. **Written one-way on purpose** — see §7.1. |
| 23 | `customers_gold_after_signup` | `gold_expires_on ≥ signup_date` | Prevents a membership expiring before the account existed. |
| 24 | `customers_email_format` / `customers_phone_format` / `delivery_partners_phone_format` | email regex; 10-digit Indian mobile starting 6–9 | Login is by email; dispatch calls the rider by phone. All 25,000 emails and all 27,000 phones obey this. |
| 25 | `localities_pincode_format` | `^[0-9]{6}$` | PIN codes are fixed-width; stored as text so leading zeros survive. |
| 26 | `coupons_validity_window` | `valid_from < valid_to` | An inverted window makes a coupon silently dead. |
| 27 | `coupons_discount_pct_range` | 1–100 | A 150% coupon is a giveaway bug. |
| 28 | `coupons_code_format` | `^[A-Z0-9_]+$` | Codes are typed by users; uppercase alphanumeric is the contract. |
| 29 | `reviews_food_rating_range` / `reviews_delivery_rating_range` | 1–5 | R19 averages `food_rating`; a 0 or 11 would skew it. |
| 30 | `reviews_text_not_blank` | `review_text` NULL or non-blank | NULL means "rated without comment" (21,405 rows); an empty string is a different, meaningless value that R18's `ILIKE` would have to special-case. |
| 31 | `reviews_order_key` (UNIQUE) | one review per order | 0 orders have two reviews; this makes "the review of an order" well-defined. |
| 32 | `menu_items_restaurant_name_key` (UNIQUE) | no duplicate dish per menu | Stops the menu screen showing "Paneer Tikka" twice. |
| 33 | `customers_email_key`, `customers_phone_key`, `delivery_partners_phone_key`, `cities_city_name_key` | natural keys unique | These are what the application actually looks rows up by; a duplicate email means two accounts can log in as one person. |

---

## 6. Normalisation analysis (1NF → 3NF/BCNF)

**1NF** — every attribute is atomic. The only debatable column is `restaurants.cuisines` (`text[]`), which is a multi-valued attribute. It is kept as an array **deliberately**, because R25 uses `'Chinese' = ANY (r.cuisines)` and Phase 4 forbids changing query results or the query text. PostgreSQL arrays are a first-class type; the strict-relational alternative (`restaurant_cuisines(restaurant_id, cuisine)`) is noted as a Phase 5 option if cuisine filtering ever needs its own index. All other columns hold exactly one value.

**2NF** — holds for every table because the only composite key is `order_items(order_id, item_id)`, and its non-key columns `quantity` and `unit_price` depend on **both** members: `unit_price` is the price of *that dish in that order*, not of the dish generally (the same dish can sell at different prices in different orders) and not of the order generally. No partial dependency exists. All other tables have single-column keys, so 2NF is automatic.

**3NF / BCNF** — for each table the functional dependencies are:

| Table | Functional dependencies | Normal form |
|---|---|---|
| `cities` | `city_id → city_name, state`; `city_name → city_id, state` | BCNF (both determinants are keys) |
| `localities` | `locality_id → city_id, locality_name, pincode`; `(city_id, locality_name) → locality_id, pincode` | BCNF |
| `customers` | `customer_id → all`; `email → customer_id`; `phone → customer_id` | BCNF (email/phone are candidate keys, enforced UNIQUE) |
| `restaurants` | `restaurant_id → all` | 3NF — see the `is_pure_veg` note below |
| `menu_items` | `item_id → all`; `(restaurant_id, item_name) → item_id, category, price, …` | BCNF |
| `delivery_partners` | `partner_id → all`; `phone → partner_id` | BCNF |
| `coupons` | `coupon_code → all` | BCNF |
| `orders` | `order_id → all` | 2NF/3NF by key — see the `total_amount` note below |
| `order_items` | `(order_id, item_id) → quantity, unit_price` | BCNF |
| `payments` | `payment_id → all` | BCNF (`order_id` is a non-unique FK, so it is *not* a determinant) |
| `reviews` | `review_id → all`; `order_id → review_id, …` | BCNF on its own attributes; the two copied columns are a deliberate denormalisation, not a transitive dependency of this table's key |

No table has a transitive dependency *within* its own attributes: `customers.state` does not exist (it is reached via `city_id`), and `restaurants.pincode` does not exist (reached via `locality_id`). That is the difference between this schema and the "quickly built" original the brief describes.

### 6.1 Derived / redundant columns — kept, with justification

The brief asks us to point out redundant columns and justify keeping them. There are four.

**1. `orders.total_amount` = `item_total + delivery_fee − discount`.**
Derived, provably (0 exceptions in 150,000 rows). **Kept** because: (a) it is read by R04, R15, R20, R23, R24 on nearly every screen, and computing it per row is extra arithmetic in the hottest queries; (b) it is an *invoice snapshot* — if a fee or discount rule changes, the historical bill must not change retroactively; (c) dropping it would require rewriting the given queries. We pin it with constraint #1 so it can never drift.

**2. `restaurants.rating` and `rating_count` (vs `reviews.food_rating`).**
Derived aggregates, refreshed by night job W04. **Kept** because R01 and R25 sort the home feed by `rating` over 2,500 rows, and aggregating 39,186 reviews at request time is exactly the P1 problem. **Honest finding:** in the seed snapshot these columns do **not** match the reviews — `rating` differs from `avg(food_rating)` by ≥0.05 for 2,154 of 2,273 rated restaurants, and `rating_count` differs from the review count for **2,390 of 2,390**. That is consistent with a nightly job that has never been run against this snapshot, and it is *why* W04 and W05 exist as maintenance jobs. We keep the columns as a cache but document that they are stale until W04 runs; no constraint can enforce equality because the refresh is asynchronous.

**3. `restaurants.is_pure_veg` (vs `menu_items.is_veg`).**
Derived: a restaurant is pure-veg iff every dish on its menu is veg. **Verified consistent** — all 500 `is_pure_veg` restaurants have zero non-veg dishes. **Kept** because it is a top-level feed filter and evaluating "all 20 dishes are veg" per restaurant per request is a correlated subquery on the home feed.

**4. `reviews.customer_id` and `reviews.restaurant_id` (vs `orders`).**
Derived: both are determined by `reviews.order_id`. **Verified consistent** — 0 mismatches across 39,186 rows. **Kept** because R19 (`avg(food_rating)` per restaurant) and the moderation screen filter by restaurant/customer directly; without these columns every review aggregation would need an extra join to `orders`. The cost is the FK maintenance and the theoretical risk of disagreement, which we accept as a documented trade-off. (Foreign keys keep them pointing at *existing* rows; only the pairing could drift, and the nightly rating job is the enforcement point.)

---

## 7. Data problems found while loading (and how each was resolved)

### 7.1 A real constraint conflict — W05 broke my first version of the Gold rule
My initial `customers` table had the strict biconditional
`CHECK (is_gold_member = (gold_expires_on IS NOT NULL))`, which is exactly true for all 25,000 seed rows. The schema loaded fine — but running the workload **failed on W05**:

```
ERROR: new row for relation "customers" violates check constraint "customers_gold_expiry_consistent"
DETAIL: Failing row contains (22, …, f, 2026-03-14, t)
```

W05 (the nightly Gold-expiry job) sets `is_gold_member = FALSE` and **intentionally leaves `gold_expires_on` in place** so the expiry date survives as history. So the strict rule contradicts a required write path. **Resolution: the constraint was wrong, not the data.** It is now one-directional — `NOT is_gold_member OR gold_expires_on IS NOT NULL` ("Gold requires an expiry") — which still forbids "Gold forever" and now accepts W05. After the fix, all 30 queries run clean and W05 affects 1,230 rows. This is the single most valuable design finding of the phase and would have been invisible without running the workload.

### 7.2 Constraints verified to accept 100% of the data
| Rule | Result on seed data |
|---|---|
| `total_amount = item_total + delivery_fee − discount` | 150,000 / 150,000 pass, **0 exceptions** |
| `placed_at ≤ accepted_at ≤ picked_up_at ≤ delivered_at` | **0 violations** |
| `(status='DELIVERED') = (delivered_at IS NOT NULL)` | **0 violations** |
| Referential integrity (every FK value exists in its parent) | **0 orphans** across all 15 FKs |
| `(order_id, item_id)` unique in `order_items` | 375,000 rows / 375,000 distinct keys |
| `reviews.order_id` unique | 0 orders with two reviews |
| email / phone uniqueness (case-insensitive email) | 25,000 / 25,000 distinct each |
| `payments.amount = orders.total_amount` | 137,378 / 137,378 exact |
| coupon usage inside the coupon's validity window and ≥ `min_order_value`, `discount ≤ max_discount` | **0 violations** |
| `is_pure_veg` ⇒ no non-veg dish | 500 / 500 consistent |
| `reviews.customer_id`/`restaurant_id` vs their order | **0 mismatches** |

### 7.3 Two queries that legitimately return few or zero rows (not schema bugs)
- **R06 returns 0 rows**: restaurant 217 had no orders on 15 Jun 2026. It has 67 orders all-time and orders on 11, 12, 14 and 16 June — the seed data is simply sparse at one-restaurant-per-day granularity. Nothing is wrong.
- **R13 returns 0 rows — and this is the P6 defect, not a data problem.** `partner_id NOT IN (SELECT partner_id FROM orders WHERE placed_at >= '2026-06-25')` is empty because that subquery contains **206 NULLs** (unassigned orders), and `x NOT IN (…, NULL)` evaluates to `NULL`, never `TRUE`. Bengaluru has 285 ACTIVE partners; the corrected `NOT EXISTS` form returns **132 rows**. We record it here, keep the given query untouched for the Phase 3 baseline, and fix it result-identically in Phase 4.

---

## 8. Index inventory at the end of Phase 2

Per the brief, **only** constraints were created — no optional indexes — so the Phase 3 baseline measures an honestly untuned database. PostgreSQL auto-creates an index for each PK and UNIQUE constraint:

| Index (auto) | Table | Columns |
|---|---|---|
| `cities_pkey` | cities | `city_id` |
| `cities_city_name_key` | cities | `city_name` |
| `localities_pkey` | localities | `locality_id` |
| `localities_city_name_key` | localities | `(city_id, locality_name)` |
| `customers_pkey` | customers | `customer_id` |
| `customers_email_key` / `customers_phone_key` | customers | `email` / `phone` |
| `restaurants_pkey` | restaurants | `restaurant_id` |
| `menu_items_pkey` | menu_items | `item_id` |
| `menu_items_restaurant_name_key` | menu_items | `(restaurant_id, item_name)` |
| `delivery_partners_pkey` / `_phone_key` | delivery_partners | `partner_id` / `phone` |
| `coupons_pkey` | coupons | `coupon_code` |
| `orders_pkey` | orders | `order_id` |
| `order_items_pkey` | order_items | `(order_id, item_id)` |
| `payments_pkey` | payments | `payment_id` |
| `reviews_pkey` / `reviews_order_key` | reviews | `review_id` / `order_id` |

**Deliberately unindexed:** `orders.customer_id`, `orders.restaurant_id`, `orders.partner_id`, `orders.placed_at`, `orders.status`, `orders.coupon_code`, `payments.order_id`, `payments.attempted_at`, `restaurants.locality_id`, `reviews.restaurant_id` — all of these are candidates for Phase 4 and their absence is what makes the baseline slow.

---

## 9. Mermaid ER diagram (text source for the PNG)

```mermaid
erDiagram
    cities            ||--o{ localities        : "contains"
    cities            ||--o{ customers         : "lives in"
    cities            ||--o{ delivery_partners : "works in"
    localities        ||--o{ restaurants       : "located in"
    restaurants       ||--o{ menu_items        : "offers"
    customers         ||--o{ orders            : "places"
    restaurants       ||--o{ orders            : "receives"
    delivery_partners |o--o{ orders            : "delivers"
    coupons           |o--o{ orders            : "applied to"
    orders            ||--|{ order_items       : "contains"
    menu_items        ||--o{ order_items       : "appears in"
    orders            ||--o{ payments          : "attempted by"
    orders            ||--o| reviews           : "reviewed by"
    customers         ||--o{ reviews           : "writes"
    restaurants       ||--o{ reviews           : "is rated in"

    cities { int city_id PK  text city_name UK  text state }
    localities { int locality_id PK  int city_id FK  text locality_name  varchar pincode }
    customers { int customer_id PK  text full_name  text email UK  varchar phone UK  int city_id FK  date signup_date  bool is_gold_member  date gold_expires_on  bool is_active }
    restaurants { int restaurant_id PK  text name  int locality_id FK  text_array cuisines  numeric avg_cost_for_two  numeric rating  int rating_count  time opens_at  time closes_at  bool is_pure_veg  text status  date onboarded_on }
    menu_items { int item_id PK  int restaurant_id FK  text item_name  text category  numeric price  bool is_veg  bool is_bestseller  bool is_available }
    delivery_partners { int partner_id PK  text full_name  varchar phone UK  int city_id FK  text vehicle_type  date joined_on  numeric rating  text status }
    coupons { text coupon_code PK  int discount_pct  numeric max_discount  numeric min_order_value  date valid_from  date valid_to }
    orders { bigint order_id PK  int customer_id FK  int restaurant_id FK  int partner_id FK  text coupon_code FK  timestamptz placed_at  timestamptz accepted_at  timestamptz picked_up_at  timestamptz delivered_at  numeric distance_km  numeric item_total  numeric delivery_fee  numeric discount  numeric total_amount  text status }
    order_items { bigint order_id PK_FK  int item_id PK_FK  smallint quantity  numeric unit_price }
    payments { bigint payment_id PK  bigint order_id FK  numeric amount  text method  text payment_status  timestamptz attempted_at }
    reviews { int review_id PK  bigint order_id UK_FK  int customer_id FK  int restaurant_id FK  smallint food_rating  smallint delivery_rating  text review_text  timestamptz created_at }
```

---

## 10. How to reproduce (for the demo / viva)

```bash
# 1. Unzip the seed data in the repo root (never commit it - .gitignore covers it)
unzip -o seed_data.zip

# 2. Create an empty database and build the schema (drops any old zomato schema)
createdb zomato
psql -d zomato -f sql/01_schema.sql

# 3. Load the 11 CSVs in parent->child order and run the 7 integrity checks
psql -d zomato -f sql/02_load_data.sql

# 4. Proof that the schema satisfies the given workload (no errors expected)
psql -d zomato -f queries/workload_30.sql
```

Expected: 11 tables with counts 10 / 100 / 25,000 / 2,500 / 50,000 / 2,000 / 30 / 150,000 / 375,000 / 137,378 / 39,186, every integrity check returning 0, and 25 read result sets (two of them legitimately empty — R06 and R13, see §7.3).
