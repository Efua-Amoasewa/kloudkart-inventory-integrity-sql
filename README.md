# Kloud Kart — inventory and order integrity on PostgreSQL

Work for the Kloud Kart Inventory & Order Management lab (DE03 SQL for Data Professionals).
Kloud Kart oversold stock it did not have, and its Monday customer report was too slow to use.
This repository stops the overselling, makes the report fast, rolls low stock up through a
category tree of any depth, and keeps an audit trail of every stock movement — all on the one
PostgreSQL server Kloud Kart already has, with no new infrastructure.

## Results at a glance

| Nana's requirement | Result | Evidence |
|---|---|---|
| No overselling | `race_test.py`, unmodified, passed 6 of 6 consecutive runs (400 buyers / 50 units: 50 sold, 0 errors) | [`evidence/race_test_runs.txt`](evidence/race_test_runs.txt) |
| Fast Monday report | 447.75 ms → 3.14 ms (customer summary, median) | [`docs/measurement_report.md`](docs/measurement_report.md) |
| Low stock through the category tree | about 6 ms, any depth, no double counting | [`tests/test_category_rollup.sql`](tests/test_category_rollup.sql) |
| Audit trail of every movement | every stock change logged; log is append-only | [`tests/test_audit_trail.sql`](tests/test_audit_trail.sql) |

## Prerequisites

- Docker Desktop (tested with Docker 29.9.3 on Windows 11)
- Python 3 (tested with Python 3.15.2) and the pinned library in
  [`requirements.txt`](requirements.txt) (`psycopg2-binary==2.9.13`)
- The Kloud Kart data bundle from Evalu8. Its six CSV files hold customer personal data, so they
  are **not** in this repository: copy them into `bundle/data/` before loading.

## Quick start

From the repository root, in PowerShell:

```powershell
pip install -r requirements.txt
$env:KLOUDKART_DB_PASSWORD = "<choose a local password>"
.\scripts\run_all.ps1 -Quiet
.\scripts\run_race_test.ps1
```

If PowerShell refuses to run scripts, allow them for this window only first:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

`run_all.ps1` is the fresh load: it deletes the `kloudkart-db` container, starts PostgreSQL 18
with `max_connections=500` (race test 2 opens 400 connections; the default is 100), loads the
bundle exactly as shipped, and runs every SQL file below in order, stopping at the first error.
`run_race_test.ps1` runs `bundle/race_test.py` six times and saves the output with the machine's
details to `evidence/race_test_runs.txt`.

## Run order

| Order | File | What it does |
|---|---|---|
| 1 | `bundle/schema.sql` | Kloud Kart's schema as shipped (not edited) |
| 2 | `bundle/load.sql` | loads the CSVs as shipped (not edited) |
| 3 | [`sql/00_check_setup.sql`](sql/00_check_setup.sql) | version 18, `max_connections` 500, six row counts |
| 4 | [`sql/01_integrity_checks.sql`](sql/01_integrity_checks.sql) | 19 read-only data-quality checks in one table |
| 5 | [`sql/02_schema_fixes.sql`](sql/02_schema_fixes.sql) | constraints for new writes, order-status map, database-assigned ids |
| 6 | [`sql/03_audit_trail.sql`](sql/03_audit_trail.sql) | trigger that logs every stock change; append-only log |
| 7 | [`sql/04_place_order.sql`](sql/04_place_order.sql) | `place_order`, the function `race_test.py` calls |
| 8 | [`sql/05_monday_report.sql`](sql/05_monday_report.sql) | the report's logic as views |
| 9 | [`sql/06_category_rollup.sql`](sql/06_category_rollup.sql) | low-stock rollup through the category tree |
| 10 | [`sql/07_performance.sql`](sql/07_performance.sql) | stored report, refresh procedure, lookup index |
| 11 | [`sql/08_improvement.sql`](sql/08_improvement.sql) | stock-count work list and shelf-count recording |

The files in [`tests/`](tests/) are run by hand after a load; each rolls back anything it changes:

```powershell
docker exec -w /lab kloudkart-db psql -U postgres -v ON_ERROR_STOP=1 -f tests/test_monday_report.sql
```

## Running the Monday report

Refresh the stored report (about 3.3 s; readers keep the previous figures meanwhile), then read it:

```sql
CALL refresh_monday_report();
SELECT * FROM monday_top_100 ORDER BY spend_rank;
SELECT * FROM monday_customer_summary WHERE person_id = 116661;
SELECT * FROM monday_monthly_spend WHERE person_id = 116661 ORDER BY spend_month;
SELECT * FROM monday_report_refresh_log ORDER BY refreshed_at DESC LIMIT 1;   -- how fresh
```

Low stock is live, no refresh needed: `SELECT * FROM low_stock_by_category ORDER BY full_path;`.
Products to recount: `SELECT * FROM stock_drift;`.

## Things a maintainer must know

- **Stock changes are logged by a trigger** (`products_log_stock_movement`), not by the code
  that changes them. Disabling it breaks the audit trail.
- **Every sale must go through `place_order`.** The no-overselling guarantee holds only for
  writers that use it; a manual `UPDATE` is still logged (as `manual_update`) and can never take
  stock below zero, but is not protected against a race.
- **A new order-status spelling must be added to `order_status_map` first**, deliberately: that
  is where it is decided whether it counts as spend.
- **New order ids start at 1,000,000**, above the ids used by 692 orphaned order lines.

## Deliverables

| Deliverable | Where |
|---|---|
| 1. Data diagnosis | [`docs/data_findings.md`](docs/data_findings.md) and [`sql/01_integrity_checks.sql`](sql/01_integrity_checks.sql) |
| 2. Working SQL solution | [`sql/`](sql/), run in order by [`scripts/run_all.ps1`](scripts/run_all.ps1) |
| Performance before / after | [`docs/measurement_report.md`](docs/measurement_report.md), raw figures in [`evidence/`](evidence/) |
| 3. Key decisions | [`decisions/`](decisions/) — ADR-001 overselling (and the trigger question), ADR-002 report speed, ADR-003 audit trail, ADR-004 report definitions, ADR-005 low-stock rollup |
| 4. Memo to Nana | [`docs/client_memo.md`](docs/client_memo.md) |
| 5. Improvement beyond the brief | [`docs/improvement.md`](docs/improvement.md) and [`sql/08_improvement.sql`](sql/08_improvement.sql) |

## Repository layout

```
bundle/      Kloud Kart's files as shipped (CSVs not committed)
sql/         the solution, numbered in run order
tests/       hand-run checks; each rolls back what it changes
scripts/     fresh load, race-test runner, performance measurement (PowerShell)
evidence/    race-test runs and before/after timings with machine details
decisions/   architecture decision records
docs/        data findings, measurement report, improvement, client memo
```
