-- 07_performance.sql
-- Make the Monday report fast, and prove it (docs/measurement_report.md).
-- Each change below was chosen from the "before" plans in evidence/performance_before.txt,
-- not from a hunch. Decisions: ADR-002.
--
-- No BEGIN/COMMIT here on purpose: CREATE INDEX CONCURRENTLY cannot run inside a
-- transaction block. psql -v ON_ERROR_STOP=1 still stops at the first error.

-- ------------------------------------------------------------------ 1. fresher statistics
-- The status map was created after load.sql's ANALYZE, so the planner estimated 435 rows where
-- 7 came back (the table holds 15). Wrong estimates feed every join choice above them.
ANALYZE order_status_map;

-- ------------------------------------------------------------------ 2. index for lookups
-- "One customer's orders" read all 159,384 orders and discarded 159,375 (Seq Scan, Rows
-- Removed by Filter). The index serves that lookup and the orders_customer_fk check.
-- Cost, measured: every insert into orders now also maintains this index.
-- CONCURRENTLY: on Kloud Kart's live server a plain CREATE INDEX would block order
-- inserts - i.e. stop the shop taking orders - until the build finished.
CREATE INDEX CONCURRENTLY orders_customer_id_idx ON orders (customer_id);

-- ------------------------------------------------------------------ 3. stored report
-- The report reads ~124,000 orders and 40,420 customers and spends most of its time
-- matching duplicate customers and grouping. Its answer changes only when orders change,
-- and Adwoa reads it weekly, so the answer is computed ahead of time and stored.
-- The logic stays in 05_monday_report.sql; these are snapshots of those views.
CREATE MATERIALIZED VIEW monday_customer_summary AS
SELECT * FROM report_customer_summary;

CREATE MATERIALIZED VIEW monday_order_running_total AS
SELECT * FROM report_order_running_total;

CREATE MATERIALIZED VIEW monday_monthly_spend AS
SELECT * FROM report_monthly_spend;

-- A unique index is what REFRESH ... CONCURRENTLY needs to compare old and new versions,
-- so readers keep seeing the previous figures while a refresh runs instead of waiting.
CREATE UNIQUE INDEX monday_customer_summary_person_uq   ON monday_customer_summary (person_id);
CREATE UNIQUE INDEX monday_order_running_total_order_uq ON monday_order_running_total (order_id);
CREATE UNIQUE INDEX monday_monthly_spend_person_month_uq ON monday_monthly_spend (person_id, spend_month);

-- Serve the two ways Adwoa reads them: by rank, and one person's history.
CREATE INDEX monday_customer_summary_rank_idx ON monday_customer_summary (spend_rank);
CREATE INDEX monday_order_running_total_person_idx ON monday_order_running_total (person_id, order_date);

ANALYZE monday_customer_summary;
ANALYZE monday_order_running_total;
ANALYZE monday_monthly_spend;

CREATE VIEW monday_top_100 AS
SELECT *
FROM monday_customer_summary
WHERE spend_rank <= 100;

-- ------------------------------------------------------------------ 4. refreshing it
-- How fresh the figures are must be visible, not assumed.
CREATE TABLE monday_report_refresh_log (
    refreshed_at timestamptz PRIMARY KEY DEFAULT now(),
    duration     interval    NOT NULL
);

-- Run by the scheduler before Adwoa starts on Monday (README, "Running the Monday report").
CREATE PROCEDURE refresh_monday_report()
LANGUAGE plpgsql AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY monday_customer_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY monday_order_running_total;
    REFRESH MATERIALIZED VIEW CONCURRENTLY monday_monthly_spend;
    INSERT INTO monday_report_refresh_log (refreshed_at, duration)
    VALUES (now(), clock_timestamp() - v_started);
END;
$$;
