-- ============================================================================
--  Zomato Food Delivery Database -- Phase 2 schema
--  Team T0122  |  PostgreSQL 18.6 (works on 15+)
--  Target to create the schema and then load via sql/02_load_data.sql
-- ============================================================================
--  Design rules followed (README 2.2):
--   * Everything lives in schema `zomato`.
--   * ONLY constraints are created here: PK, FK, UNIQUE, NOT NULL, CHECK.
--     No extra indexes -- Phase 3 baseline must reflect an untuned database.
--     (PostgreSQL auto-creates indexes for PK / UNIQUE constraints only;
--      they are listed at the bottom of this file for the design doc.)
--   * Every constraint below was verified to accept 100% of the seed data.
-- ============================================================================

DROP SCHEMA IF EXISTS zomato CASCADE;
CREATE SCHEMA zomato;
SET search_path TO zomato;

-- ----------------------------------------------------------------------------
-- 1. cities -- 10 rows. Geography root of the hierarchy city > locality > restaurant
-- ----------------------------------------------------------------------------
CREATE TABLE cities (
    city_id     INTEGER      PRIMARY KEY,
    city_name   TEXT         NOT NULL,
    state       TEXT         NOT NULL,
    CONSTRAINT cities_city_name_key   UNIQUE (city_name),
    CONSTRAINT cities_city_name_nn    CHECK (length(btrim(city_name)) > 0)
);

-- ----------------------------------------------------------------------------
-- 2. localities -- 100 rows. 10 neighbourhoods per city.
--    FK RESTRICT: a city/localities row is master data; it must not be deleted
--    while restaurants or customers still point at it.
-- ----------------------------------------------------------------------------
CREATE TABLE localities (
    locality_id    INTEGER  PRIMARY KEY,
    city_id        INTEGER  NOT NULL,
    locality_name  TEXT     NOT NULL,
    pincode        VARCHAR(6) NOT NULL,
    CONSTRAINT localities_city_fk
        FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    CONSTRAINT localities_city_name_key UNIQUE (city_id, locality_name),
    CONSTRAINT localities_pincode_format CHECK (pincode ~ '^[0-9]{6}$')
);

-- ----------------------------------------------------------------------------
-- 3. customers -- 25,000 rows. Email and phone are natural candidate keys.
--    ON DELETE RESTRICT on city: a customer who exists must belong to a real city.
-- ----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id      INTEGER     PRIMARY KEY,
    full_name        TEXT        NOT NULL,
    email            TEXT        NOT NULL,
    phone            VARCHAR(10) NOT NULL,
    city_id          INTEGER     NOT NULL,
    signup_date      DATE        NOT NULL,
    is_gold_member   BOOLEAN     NOT NULL DEFAULT FALSE,
    gold_expires_on  DATE,
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT customers_city_fk
        FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    CONSTRAINT customers_email_key UNIQUE (email),
    CONSTRAINT customers_phone_key UNIQUE (phone),
    -- natural keys must look like real emails / Indian mobile numbers
    CONSTRAINT customers_email_format CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    CONSTRAINT customers_phone_format CHECK (phone ~ '^[6-9][0-9]{9}$'),
    -- A Gold member MUST have an expiry date (no "gold forever"), data agrees:
    -- all 3,792 gold members have one, and 21,208 non-gold have none.
    -- Written one-way on purpose: W05 (the nightly Gold-expiry job) flips
    -- is_gold_member to FALSE while LEAVING gold_expires_on in place, so the
    -- date is retained as history. A strict biconditional would break W05.
    CONSTRAINT customers_gold_needs_expiry
        CHECK (NOT is_gold_member OR gold_expires_on IS NOT NULL),
    -- expiry cannot be before signup
    CONSTRAINT customers_gold_after_signup
        CHECK (gold_expires_on IS NULL OR gold_expires_on >= signup_date)
);

-- ----------------------------------------------------------------------------
-- 4. restaurants -- 2,500 rows. cuisines is a multi-valued attribute, stored as
--    text[] because R25 does `'Chinese' = ANY (r.cuisines)`.
--    rating is NULLABLE: 124 restaurants have never been rated (110 of them OPEN).
-- ----------------------------------------------------------------------------
CREATE TABLE restaurants (
    restaurant_id      INTEGER      PRIMARY KEY,
    name               TEXT         NOT NULL,
    locality_id        INTEGER      NOT NULL,
    cuisines           TEXT[]       NOT NULL,
    avg_cost_for_two   NUMERIC(8,2) NOT NULL,
    rating             NUMERIC(2,1),
    rating_count       INTEGER      NOT NULL DEFAULT 0,
    opens_at           TIME         NOT NULL,
    closes_at          TIME         NOT NULL,
    is_pure_veg        BOOLEAN      NOT NULL DEFAULT FALSE,
    status             TEXT         NOT NULL,
    onboarded_on       DATE         NOT NULL,
    CONSTRAINT restaurants_locality_fk
        FOREIGN KEY (locality_id) REFERENCES localities (locality_id) ON DELETE RESTRICT,
    CONSTRAINT restaurants_status_check
        CHECK (status IN ('OPEN', 'TEMPORARILY_CLOSED', 'DELISTED')),
    CONSTRAINT restaurants_rating_range
        CHECK (rating IS NULL OR (rating >= 1.0 AND rating <= 5.0)),
    CONSTRAINT restaurants_rating_count_nn CHECK (rating_count >= 0),
    CONSTRAINT restaurants_cost_positive  CHECK (avg_cost_for_two > 0),
    CONSTRAINT restaurants_hours_check    CHECK (opens_at < closes_at),
    -- at least one cuisine must be listed, and no empty cuisine names
    CONSTRAINT restaurants_cuisines_nonempty
        CHECK (cardinality(cuisines) > 0 AND array_position(cuisines, '') IS NULL),
    -- a restaurant cannot be onboarded in the future of the snapshot (30 Jun 2026)
    CONSTRAINT restaurants_onboarded_check CHECK (onboarded_on <= DATE '2026-06-30')
);

-- ----------------------------------------------------------------------------
-- 5. menu_items -- 50,000 rows. A dish belongs to exactly one restaurant.
--    ON DELETE CASCADE: deleting a restaurant must remove its menu.
-- ----------------------------------------------------------------------------
CREATE TABLE menu_items (
    item_id        INTEGER      PRIMARY KEY,
    restaurant_id  INTEGER      NOT NULL,
    item_name      TEXT         NOT NULL,
    category       TEXT         NOT NULL,
    price          NUMERIC(8,2) NOT NULL,
    is_veg         BOOLEAN      NOT NULL DEFAULT FALSE,
    is_bestseller  BOOLEAN      NOT NULL DEFAULT FALSE,
    is_available   BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT menu_items_restaurant_fk
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id) ON DELETE CASCADE,
    CONSTRAINT menu_items_category_check
        CHECK (category IN ('Starters', 'Main Course', 'Breads', 'Rice', 'Desserts', 'Beverages')),
    CONSTRAINT menu_items_price_positive CHECK (price > 0),
    -- the same dish name cannot appear twice on one restaurant's menu
    CONSTRAINT menu_items_restaurant_name_key UNIQUE (restaurant_id, item_name)
);

-- ----------------------------------------------------------------------------
-- 6. delivery_partners -- 2,000 rows. Riders are attached to a city, not a locality.
-- ----------------------------------------------------------------------------
CREATE TABLE delivery_partners (
    partner_id    INTEGER      PRIMARY KEY,
    full_name     TEXT         NOT NULL,
    phone         VARCHAR(10)  NOT NULL,
    city_id       INTEGER      NOT NULL,
    vehicle_type  TEXT         NOT NULL,
    joined_on     DATE         NOT NULL,
    rating        NUMERIC(2,1) NOT NULL,
    status        TEXT         NOT NULL,
    CONSTRAINT delivery_partners_city_fk
        FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    CONSTRAINT delivery_partners_phone_key UNIQUE (phone),
    CONSTRAINT delivery_partners_phone_format CHECK (phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT delivery_partners_vehicle_check
        CHECK (vehicle_type IN ('BIKE', 'SCOOTER', 'BICYCLE', 'EV')),
    CONSTRAINT delivery_partners_status_check
        CHECK (status IN ('ACTIVE', 'INACTIVE', 'BLOCKED')),
    CONSTRAINT delivery_partners_rating_range CHECK (rating >= 1.0 AND rating <= 5.0),
    CONSTRAINT delivery_partners_joined_check CHECK (joined_on <= DATE '2026-06-30')
);

-- ----------------------------------------------------------------------------
-- 7. coupons -- 30 rows. coupon_code is the natural PK (R15 joins on it).
-- ----------------------------------------------------------------------------
CREATE TABLE coupons (
    coupon_code      TEXT         PRIMARY KEY,
    discount_pct     INTEGER      NOT NULL,
    max_discount     NUMERIC(8,2) NOT NULL,
    min_order_value  NUMERIC(8,2) NOT NULL,
    valid_from       DATE         NOT NULL,
    valid_to         DATE         NOT NULL,
    CONSTRAINT coupons_discount_pct_range CHECK (discount_pct BETWEEN 1 AND 100),
    CONSTRAINT coupons_max_discount_positive CHECK (max_discount > 0),
    CONSTRAINT coupons_min_order_nonneg CHECK (min_order_value >= 0),
    CONSTRAINT coupons_validity_window CHECK (valid_from < valid_to),
    CONSTRAINT coupons_code_format CHECK (coupon_code ~ '^[A-Z0-9_]+$')
);

-- ----------------------------------------------------------------------------
-- 8. orders -- 150,000 rows, the fact table.
--    Lifecycle columns are NULL until the order reaches that stage, so the
--    CHECK constraints below are written to be NULL-tolerant yet status-aware.
--     - partner_id      NULL for 13,538 orders (never assigned / cancelled early)
--     - accepted_at     NULL for 13,501 orders
--     - picked_up_at    NULL for 19,549 orders
--     - delivered_at    NULL for 19,587 orders  (exactly the non-DELIVERED ones)
-- ----------------------------------------------------------------------------
CREATE TABLE orders (
    order_id       BIGINT       PRIMARY KEY,
    customer_id    INTEGER      NOT NULL,
    restaurant_id  INTEGER      NOT NULL,
    partner_id     INTEGER,
    coupon_code    TEXT,
    placed_at      TIMESTAMPTZ  NOT NULL,
    accepted_at    TIMESTAMPTZ,
    picked_up_at   TIMESTAMPTZ,
    delivered_at   TIMESTAMPTZ,
    distance_km    NUMERIC(4,1) NOT NULL,
    item_total     NUMERIC(10,2) NOT NULL,
    delivery_fee   NUMERIC(10,2) NOT NULL,
    discount       NUMERIC(10,2) NOT NULL,
    total_amount   NUMERIC(10,2) NOT NULL,
    status         TEXT         NOT NULL,

    -- FK to customers: RESTRICT -- never orphan financial history.
    -- Customers are deactivated (is_active = FALSE), never deleted.
    CONSTRAINT orders_customer_fk
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id) ON DELETE RESTRICT,
    -- FK to restaurants: RESTRICT -- same reason; a delisted restaurant keeps its history.
    CONSTRAINT orders_restaurant_fk
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id) ON DELETE RESTRICT,
    -- FK to delivery_partners: SET NULL -- if a rider row is ever removed, the order
    -- must survive and simply become unassigned again.
    CONSTRAINT orders_partner_fk
        FOREIGN KEY (partner_id) REFERENCES delivery_partners (partner_id) ON DELETE SET NULL,
    -- FK to coupons: SET NULL -- retiring a coupon must not delete or block orders.
    CONSTRAINT orders_coupon_fk
        FOREIGN KEY (coupon_code) REFERENCES coupons (coupon_code) ON DELETE SET NULL,

    CONSTRAINT orders_status_check
        CHECK (status IN ('PLACED', 'ACCEPTED', 'PREPARING', 'OUT_FOR_DELIVERY',
                          'DELIVERED', 'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT')),
    -- money is never negative, and an order must actually contain food
    CONSTRAINT orders_money_nonneg
        CHECK (item_total >= 0 AND delivery_fee >= 0 AND discount >= 0 AND total_amount >= 0),
    CONSTRAINT orders_item_total_positive CHECK (item_total > 0),
    -- THE bill identity: verified exact on all 150,000 rows (0 exceptions).
    CONSTRAINT orders_total_is_derived
        CHECK (total_amount = item_total + delivery_fee - discount),
    -- a discount may never exceed the goods value
    CONSTRAINT orders_discount_le_items CHECK (discount <= item_total),
    CONSTRAINT orders_distance_range CHECK (distance_km > 0 AND distance_km <= 50),
    -- timestamps must move forward through the pipeline (NULL-tolerant chaining)
    CONSTRAINT orders_time_order
        CHECK ((accepted_at  IS NULL OR accepted_at  >= placed_at)
           AND (picked_up_at IS NULL OR picked_up_at >= accepted_at)
           AND (delivered_at IS NULL OR delivered_at >= picked_up_at)),
    -- DELIVERED <=> delivered_at present (true for all 150,000 rows)
    CONSTRAINT orders_delivered_iff_timestamp
        CHECK ((status = 'DELIVERED') = (delivered_at IS NOT NULL)),
    -- once a rider has collected the food, the pickup time must be recorded
    CONSTRAINT orders_pickup_required
        CHECK (picked_up_at IS NOT NULL OR status NOT IN ('OUT_FOR_DELIVERY', 'DELIVERED')),
    -- the kitchen cannot accept/prepare an order without an acceptance timestamp
    CONSTRAINT orders_accepted_required
        CHECK (accepted_at IS NOT NULL
               OR status IN ('PLACED', 'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT')),
    -- an order cannot be prepared or delivered without a rider
    CONSTRAINT orders_partner_required
        CHECK (partner_id IS NOT NULL
               OR status IN ('PLACED', 'ACCEPTED', 'CANCELLED_BY_CUSTOMER', 'CANCELLED_BY_RESTAURANT'))
);

-- ----------------------------------------------------------------------------
-- 9. order_items -- 375,000 rows. A line item is identified by (order, dish):
--    the pair is unique in the data (0 duplicates), so it is the composite PK.
--    ON DELETE CASCADE: lines have no meaning without their order.
--    ON DELETE RESTRICT on item_id: never delete a dish that was ever sold.
-- ----------------------------------------------------------------------------
CREATE TABLE order_items (
    order_id    BIGINT       NOT NULL,
    item_id     INTEGER      NOT NULL,
    quantity    SMALLINT     NOT NULL,
    unit_price  NUMERIC(8,2) NOT NULL,
    CONSTRAINT order_items_pkey PRIMARY KEY (order_id, item_id),
    CONSTRAINT order_items_order_fk
        FOREIGN KEY (order_id) REFERENCES orders (order_id) ON DELETE CASCADE,
    CONSTRAINT order_items_item_fk
        FOREIGN KEY (item_id) REFERENCES menu_items (item_id) ON DELETE RESTRICT,
    CONSTRAINT order_items_quantity_check CHECK (quantity > 0 AND quantity <= 50),
    -- price at the time of order; the historical value is what we bill
    CONSTRAINT order_items_unit_price_positive CHECK (unit_price > 0)
);

-- ----------------------------------------------------------------------------
-- 10. payments -- 137,378 rows. An order can have SEVERAL attempts (6,965 do),
--     so payment_id is the PK and order_id is NOT unique.
-- ----------------------------------------------------------------------------
CREATE TABLE payments (
    payment_id      BIGINT       PRIMARY KEY,
    order_id        BIGINT       NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    method          TEXT         NOT NULL,
    payment_status  TEXT         NOT NULL,
    attempted_at    TIMESTAMPTZ  NOT NULL,
    CONSTRAINT payments_order_fk
        FOREIGN KEY (order_id) REFERENCES orders (order_id) ON DELETE CASCADE,
    CONSTRAINT payments_method_check
        CHECK (method IN ('UPI', 'CARD', 'WALLET', 'COD')),
    CONSTRAINT payments_status_check
        CHECK (payment_status IN ('SUCCESS', 'FAILED', 'REFUNDED')),
    CONSTRAINT payments_amount_positive CHECK (amount > 0),
    -- Cash on delivery cannot "fail": there is no gateway. Data agrees:
    -- COD attempts are only SUCCESS (28,751) or REFUNDED (300), never FAILED.
    CONSTRAINT payments_cod_not_failed
        CHECK (method <> 'COD' OR payment_status <> 'FAILED')
);

-- ----------------------------------------------------------------------------
-- 11. reviews -- 39,186 rows. Exactly one review per order in the data, so
--     order_id is UNIQUE. customer_id/restaurant_id are derivable from the
--     order (verified 0 mismatches) -- kept as a deliberate denormalisation so
--     restaurant rating jobs and moderation screens avoid an extra join.
-- ----------------------------------------------------------------------------
CREATE TABLE reviews (
    review_id        INTEGER      PRIMARY KEY,
    order_id         BIGINT       NOT NULL,
    customer_id      INTEGER      NOT NULL,
    restaurant_id    INTEGER      NOT NULL,
    food_rating      SMALLINT     NOT NULL,
    delivery_rating  SMALLINT,
    review_text      TEXT,
    created_at       TIMESTAMPTZ  NOT NULL,
    CONSTRAINT reviews_order_fk
        FOREIGN KEY (order_id) REFERENCES orders (order_id) ON DELETE CASCADE,
    CONSTRAINT reviews_customer_fk
        FOREIGN KEY (customer_id) REFERENCES customers (customer_id) ON DELETE RESTRICT,
    CONSTRAINT reviews_restaurant_fk
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id) ON DELETE RESTRICT,
    CONSTRAINT reviews_order_key UNIQUE (order_id),
    CONSTRAINT reviews_food_rating_range     CHECK (food_rating BETWEEN 1 AND 5),
    CONSTRAINT reviews_delivery_rating_range CHECK (delivery_rating BETWEEN 1 AND 5),
    -- an empty string is not a review; NULL means "no comment written" (21,405 rows)
    CONSTRAINT reviews_text_not_blank
        CHECK (review_text IS NULL OR length(btrim(review_text)) > 0)
);

-- ============================================================================
--  Indexes that exist after Phase 2 (auto-created from PK / UNIQUE only):
--   cities(pk), localities(pk), localities(city_id, locality_name) UNIQUE,
--   customers(pk), customers(email) UNIQUE, customers(phone) UNIQUE,
--   restaurants(pk), menu_items(pk), menu_items(restaurant_id,item_name) UNIQUE,
--   delivery_partners(pk), delivery_partners(phone) UNIQUE,
--   coupons(pk), orders(pk), order_items(pk on order_id,item_id),
--   payments(pk), reviews(pk), reviews(order_id) UNIQUE
-- Everything else (FK-side columns, placed_at, status, ...) is UNINDEXED on
-- purpose: that is the honest "before" picture for the Phase 3 baseline.
-- ============================================================================
