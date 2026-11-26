-- 05_monday_report.sql
-- Nana's requirement 2: for every customer - total spent, order count, monthly spend for
-- the trailing 12 months, a running per-customer total, and a top-100 ranking.
--
-- This file holds the report LOGIC as plain views (a saved question, recomputed on every
-- read). 07_performance.sql measures them, then stores their answers as materialized
-- views so Adwoa's Monday read takes milliseconds. Keeping the logic here means the
-- definition of "spend" lives in exactly one place.
--
-- Decisions (ADR-004), each named where it is applied below:
--   * Spend      = orders whose status counts as spend in order_status_map (completed,
--                  shipped), valued at orders.total_amount, the amount charged at checkout.
--                  Line totals are not used: F-04 and F-05 inflate them by ~4.0 million.
--   * Customer   = a person, identified by trimmed lower-case email (F-06): the 533
--                  duplicated people are reported once, under their lowest customer_id.
--   * Excluded   = orders whose customer does not exist (F-09) and orders dated after the
--                  moment the report runs (F-11).
--   * Trailing 12 months = the current calendar month (to date) and the 11 before it.

BEGIN;

-- ------------------------------------------------------------------ who is a person
CREATE VIEW customer_identity AS
SELECT customer_id,
       min(customer_id) OVER (PARTITION BY lower(trim(email))) AS person_id
FROM customers;

-- ------------------------------------------------------------------ the orders that count
CREATE VIEW spend_orders AS
SELECT o.order_id,
       ci.person_id,
       o.order_date,
       o.total_amount
FROM orders o
JOIN order_status_map sm  ON sm.raw_status = o.status
JOIN customer_identity ci ON ci.customer_id = o.customer_id   -- drops F-09 orphans
WHERE sm.counts_as_spend
  AND o.order_date <= now();                                    -- drops F-11 future dates

-- ------------------------------------------------------------------ running total, per order
-- ROWS, not the default RANGE: two orders by one person at the same timestamp would each
-- show the combined total under RANGE. With ROWS and order_id as a tie-breaker, every order
-- adds exactly its own amount, in a repeatable order.
CREATE VIEW report_order_running_total AS
SELECT person_id,
       order_id,
       order_date,
       total_amount,
       sum(total_amount) OVER (
           PARTITION BY person_id
           ORDER BY order_date, order_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total
FROM spend_orders;

-- ------------------------------------------------------------------ monthly, trailing 12
CREATE VIEW report_monthly_spend AS
SELECT person_id,
       date_trunc('month', order_date)::date AS spend_month,
       count(*)                              AS orders_in_month,
       sum(total_amount)                     AS spend_in_month
FROM spend_orders
-- 11 months back from the start of this month = 12 calendar months including this one.
WHERE order_date >= date_trunc('month', now()) - interval '11 months'
GROUP BY person_id, date_trunc('month', order_date);

-- ------------------------------------------------------------------ one row per person
-- One pass over spend_orders computes lifetime totals, the trailing-12 total and the rank.
-- RANK, not ROW_NUMBER: two people who spent exactly the same share a place, so the
-- "top 100" can hold more than 100 people when there is a tie at the boundary - nobody is
-- dropped by an arbitrary tie-break.
CREATE VIEW report_customer_summary AS
WITH per_person AS (
    SELECT person_id,
           sum(total_amount) AS total_spent,
           count(*)          AS order_count,
           coalesce(sum(total_amount) FILTER (
               WHERE order_date >= date_trunc('month', now()) - interval '11 months'
           ), 0)             AS trailing_12m_spent,
           max(order_date)   AS last_order_at
    FROM spend_orders
    GROUP BY person_id
)
SELECT pp.person_id,
       c.full_name,
       trim(c.email)  AS email,
       pp.total_spent,
       pp.order_count,
       pp.trailing_12m_spent,
       pp.last_order_at,
       rank() OVER (ORDER BY pp.total_spent DESC) AS spend_rank
FROM per_person pp
JOIN customers c ON c.customer_id = pp.person_id;

-- ------------------------------------------------------------------ the top 100
-- A window function cannot sit in WHERE, so the rank is computed in the view above and
-- filtered here.
CREATE VIEW report_top_100 AS
SELECT *
FROM report_customer_summary
WHERE spend_rank <= 100;

COMMIT;
