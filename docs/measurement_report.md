# Monday report, rollup and order placement — performance report

## Target

From the brief:

- **Monday report** (total spent, order count, trailing-12-month spend, running total, top 100):
  "in seconds on an ordinary laptop".
- **Low-stock rollup** through the category tree: "in a couple of seconds".
- **Flash sale:** about 400 orders in ten seconds on a single product, with no overselling.

## Method

- **Hardware / container spec:** Windows 11 Business 10.0.26300; Intel Core i7-10510U @ 1.80 GHz
  (4 cores, 8 threads); 31.8 GB RAM; Docker 29.9.3; PostgreSQL 18.7 in container `kloudkart-db`,
  `max_connections=500`, all other settings default (so `work_mem` is 4 MB). Data: the Evalu8
  bundle as loaded — 159,384 orders, 40,420 customers, 4,023 products.
- **What was timed:** for queries, PostgreSQL's own `Execution Time` from `EXPLAIN (ANALYZE)`:
  from the start to the end of executing the statement on the server, excluding sending the
  rows to the client. Writes ran inside a transaction that was rolled back. The refresh was
  timed with psql's `\timing` (client-side, call to completion). The flash sale was timed by
  `race_test.py` itself (wall clock from releasing 400 buyers to the last answer, including
  opening their connections).
- **Runs, warm or cold, and which figure is reported:** one warm-up run discarded, then 20
  runs per query on a warm cache. Reported: median, 95th percentile (nearest rank: the 19th of
  20) and worst. Refresh: 3 runs, all reported. Flash sale: 6 consecutive runs, range reported.
- **How to reproduce:** load the database, run `sql/00`–`sql/06`, then
  `.\scripts\measure_performance.ps1 -Stage before`; apply `sql/07_performance.sql`, then
  `.\scripts\measure_performance.ps1 -Stage after`. Raw figures and one full query plan per
  scenario: `evidence/performance_before.txt`, `evidence/performance_after.txt`. Refresh:
  `tests/test_refresh.sql`. Flash sale: `.\scripts\run_race_test.ps1` →
  `evidence/race_test_runs.txt`.

## Results

After the changes in `sql/07_performance.sql`.

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Monday report: every customer summary | 20 | 3.14 ms | 3.78 ms | 3.87 ms | Yes |
| Monday report: top 100 | 20 | 0.07 ms | 0.10 ms | 0.12 ms | Yes |
| Monday report: running total, every order | 20 | 9.63 ms | 10.09 ms | 13.14 ms | Yes |
| Monday report: monthly spend, trailing 12 | 20 | 7.09 ms | 9.40 ms | 10.68 ms | Yes |
| Low-stock rollup (live) | 20 | 5.99 ms | 6.86 ms | 11.03 ms | Yes |
| One customer's orders | 20 | 0.13 ms | 0.19 ms | 0.19 ms | n/a |
| Refresh the stored report | 3 | 3.32 s | — | 3.41 s | n/a (paid when nobody waits) |
| Flash sale: 400 buyers, 50 units | 6 | — | — | 3.04–4.24 s for all 400 | Yes: 50 sold, 0 errors, every run |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Customer summary | 447.75 ms | 3.14 ms | about 143× faster |
| Top 100 | 423.33 ms | 0.07 ms | about 6,000× faster |
| Running total, every order | 353.33 ms | 9.63 ms | about 37× faster |
| Monthly spend, trailing 12 | 396.19 ms | 7.09 ms | about 56× faster |
| One customer's orders | 7.70 ms | 0.13 ms | about 59× faster (index) |
| Low-stock rollup (not changed) | 6.89 ms | 5.99 ms | no change; the difference is run-to-run variation |
| Insert 1,000 orders (write cost) | 18.22 ms | 19.33 ms | about 6 % slower (index maintained on every insert) |
| Refresh the stored report | — | 3.15–3.41 s | new cost, scheduled before Adwoa starts |

All figures are medians except the refresh and flash-sale rows.

What changed, and why, from the "before" plans:

- **Report:** most of the time went on matching duplicate customers by email, grouping
  124,030 orders (the planner expected 200 groups) and a sort that spilled to disk. Storing the
  answer (ADR-002) removes all of that from the moment someone reads it.
- **Lookup:** a sequential scan read all 159,384 orders and discarded 159,375 ("Rows Removed
  by Filter"); an index on `orders(customer_id)` lets it read only the 9 that match.
- **Statistics:** `order_status_map` had never been analysed, so the planner guessed 435 rows
  for a 15-row table; `ANALYZE` fixed the estimate.

## Caveats

- **The 40-minute report was not reproduced.** On this extract the unoptimised report already
  ran in under half a second per part. Adwoa's 40 minutes most likely comes from how her current
  report is built, which I could not see; the gain claimed here is measured against my own plain
  version, not against hers.
- **Warm cache, one laptop, default memory settings.** Cold-start and production-server figures
  will differ. With more memory per sort (`work_mem`) the "before" sort would not spill to disk.
- **`EXPLAIN ANALYZE` adds a little timing overhead** and excludes sending rows to the client;
  reading 38,095 summary rows over a network adds time on top of 3.14 ms.
- **One outlier:** the "before" customer summary's worst run was 1,064.71 ms against a median of
  447.75 ms — background activity on the laptop. This is why medians are reported.
- **Refresh time grows with the number of orders.** It was not measured at larger volumes.
- **The flash sale was simulated** by `race_test.py` on one machine, not observed on Kloud Kart's
  server under real traffic.
