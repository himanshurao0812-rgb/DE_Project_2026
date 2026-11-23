# CP4 — run the large-dataset benchmark (Harsh)

**You produce:** `benchmarks/results/large/summary.csv` + `R01.txt … W05.txt`
**Due:** Mon 23 Nov 2026, **11:59 PM** · CP4 · feeds **4 marks** (large-dataset results) and **3 marks** (growth analysis)
**Himanshu** writes `docs/05_scalability_report.md` from your output.

---

## ⚠️ Blocker first

The **large dataset is released by faculty later** — it is not in the repo. Do this the moment it appears, not on 23 Nov. If it hasn't arrived by **21 Nov**, ask faculty; if it genuinely cannot be obtained, generate a scaled copy yourself (below) and **label it synthetic in the report**.

---

## Option A — the official large dataset (preferred)

```bash
cd DE_Project_2026
git pull origin main
# put the faculty's large dataset in large_data/  (already git-ignored)
ls large_data/            # 11 CSVs, same names as seed_data/

createdb zomato_large
psql -d zomato_large -f sql/01_schema.sql

# load the large CSVs (same script, different folder - copy it and change paths)
sed 's|seed_data/|large_data/|g' sql/02_load_data.sql > /tmp/large_load.sql
psql -d zomato_large -f /tmp/large_load.sql
```

**Verify the load before timing anything:**
```bash
psql -d zomato_large -c "SELECT count(*) FROM zomato.orders;"       # record this number
psql -d zomato_large -c "SELECT count(*) FROM zomato.order_items;"
psql -d zomato_large -c "SELECT min(placed_at), max(placed_at) FROM zomato.orders;"
```
Write those three numbers down — §1 of the report needs them.

## Option B — synthetic 20× (only if the dataset never arrives)

```bash
createdb zomato_large
psql -d zomato_large -f sql/01_schema.sql
psql -d zomato_large -f sql/02_load_data.sql     # start from the seed data

-- multiply orders 20x, shifting dates forward so partitions have data
INSERT INTO zomato.orders
SELECT order_id + (m * 1000000), customer_id, restaurant_id, partner_id, coupon_code,
       placed_at + (m * interval '1 month'), accepted_at + (m * interval '1 month'),
       picked_up_at + (m * interval '1 month'), delivered_at + (m * interval '1 month'),
       distance_km, item_total, delivery_fee, discount, total_amount, status
FROM zomato.orders, generate_series(1,19) AS m;

-- the child tables must be multiplied the SAME way, or the joins become wrong
-- (do order_items, payments, reviews equivalently, keying off the same m)
```
⚠️ Then state in the report: **"the large dataset was not released in time; results are from a 20× synthetic copy of the seed data, built by <method>."** Honest labelling keeps the growth-analysis marks; silent fabrication loses the whole phase.

---

## 1. Baseline on the large dataset (indexes OFF)

To measure the *unoptimized* large data, you need a database with only Phase 2 constraints:
```bash
./benchmarks/run_benchmark.sh zomato_large large_before
```
This shows how bad it gets at scale — **this is the number that motivates Phase 5** and the one your report's growth curve needs.

## 2. With Phase 4 indexes (the configuration you ship)

```bash
psql -d zomato_large -f sql/05_indexes.sql
psql -d zomato_large -c "ANALYZE;"
./benchmarks/run_benchmark.sh zomato_large large
```
→ `benchmarks/results/large/summary.csv` ← **this exact path is what the tracker checks**

## 3. With partitioning (only if time allows)

```bash
psql -d zomato_large -f sql/08_partitioning.sql
-- reload the data into orders_partitioned / order_items_partitioned / payments_partitioned
psql -d zomato_large -c "ANALYZE;"
./benchmarks/run_benchmark.sh zomato_large large_partitioned
```
Then copy the interesting plans (R09, R22, R23) into the report yourself — Himanshu needs the `Partitions scanned:` line.

## 4. Verify (2 min)
```bash
wc -l benchmarks/results/large/summary.csv                      # 31
ls benchmarks/results/large/*.txt | wc -l                       # 30
for f in benchmarks/results/large/*.txt; do echo -n "$f: "; grep -c "Execution Time" $f; done | grep -v ": 3$"
sort -t, -k3 -rn benchmarks/results/large/summary.csv | head -5   # the slowest queries
```

## 5. Commit
```bash
git add benchmarks/results/large/
git commit -m "CP4: large-dataset timings - 30 queries, 3 runs each, raw plans"
git push origin main
```

---

## Practical warnings for the large run

| Risk | What happens | What to do |
|---|---|---|
| **It takes hours** | 30 queries × 3 runs on 20× data, with some queries at >10 s each | Run it overnight or in one uninterrupted block; don't interrupt mid-run |
| **Disk space** | 20× data + 21 indexes + WAL can exceed 10 GB | Check `df -h` first; `VACUUM` after the load |
| **`work_mem` spills** | big sorts go to disk and inflate timings | Note it in the report as a *found problem*, then `SET work_mem='256MB'` and re-run those queries |
| **Laptop sleeps** | a partial run = useless CSV | Plug in, disable sleep, don't close the lid |
| **Different laptop than Phase 3/4** | before/after comparison is invalid | Use the **same** machine named in `team.json` |
| **Editing the workload** | forbidden | Never touch `queries/workload_30.sql` |
