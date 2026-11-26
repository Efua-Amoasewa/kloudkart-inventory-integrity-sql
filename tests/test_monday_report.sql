-- tests/test_monday_report.sql
-- Checks sql/05_monday_report.sql against figures computed a different way, by hand.
-- Read-only.

\pset pager off

\echo '--- 1: reconciliation - expect 124030 orders (matches docs/data_findings.md)'
SELECT count(*) AS people, sum(order_count) AS orders, sum(total_spent) AS spend
FROM report_customer_summary;

\echo '--- 2: the top 3 customers'
SELECT person_id, total_spent, order_count, trailing_12m_spent, spend_rank
FROM report_customer_summary
ORDER BY spend_rank
LIMIT 3;

\echo '--- 3: rank 1 by hand, straight from orders + customers - expect by_hand = report'
SELECT s.person_id,
       (SELECT sum(o.total_amount)
        FROM orders o
        JOIN customers c ON c.customer_id = o.customer_id
        WHERE lower(trim(c.email)) = (SELECT lower(trim(email)) FROM customers WHERE customer_id = s.person_id)
          AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
          AND o.order_date <= now()) AS by_hand,
       s.total_spent AS report
FROM report_customer_summary s
WHERE s.spend_rank = 1;

\echo '--- 4: running total for rank 1 - each row = previous row + this order'
SELECT order_date, total_amount, running_total
FROM report_order_running_total
WHERE person_id = (SELECT person_id FROM report_customer_summary WHERE spend_rank = 1)
ORDER BY order_date, order_id;

\echo '--- 5: monthly spend for rank 1 - only the trailing 12 calendar months appear'
SELECT spend_month, orders_in_month, spend_in_month
FROM report_monthly_spend
WHERE person_id = (SELECT person_id FROM report_customer_summary WHERE spend_rank = 1)
ORDER BY spend_month;

\echo '--- 6: a duplicated customer - expect two customer rows, one person_id'
SELECT c.customer_id, ci.person_id
FROM customers c
JOIN customer_identity ci ON ci.customer_id = c.customer_id
WHERE lower(trim(c.email)) = (
    SELECT lower(trim(email)) FROM customers GROUP BY 1 HAVING count(*) > 1 ORDER BY 1 LIMIT 1
);

\echo '--- 7: top 100 size and its last rank'
SELECT count(*) AS rows_in_top_100, max(spend_rank) AS last_rank FROM report_top_100;
