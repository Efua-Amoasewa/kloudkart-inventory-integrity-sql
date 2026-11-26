-- tests/test_improvement.sql
-- Shows the stock-count work list, then closes one item with a shelf count inside a
-- transaction that is rolled back.

\pset pager off

\echo '--- 1: the work list (expect 157 products: 14 negative + 143 disagreeing with their log)'
SELECT why_listed, count(*) AS products, sum(abs(unexplained_difference)) AS units_unexplained
FROM stock_drift
GROUP BY why_listed;

BEGIN;
SELECT product_id AS pid, recorded_stock, stock_per_movement_log
FROM stock_drift
WHERE why_listed LIKE 'stock and%'
ORDER BY abs(unexplained_difference) DESC
LIMIT 1 \gset

\echo '--- 2: the worst disagreeing product, before the count'
SELECT :pid AS product_id, :recorded_stock AS recorded_stock, :stock_per_movement_log AS stock_per_log;

\echo '--- 3: staff count 7 on the shelf'
SELECT * FROM record_stock_count(:pid, 7, 'test counter');

\echo '--- 4: the trail now explains it - a stock_take and a correction, both stock_after 7'
SELECT change_qty, reason, note, stock_after
FROM inventory_log
WHERE product_id = :pid
ORDER BY log_id DESC
LIMIT 2;

\echo '--- 5: the product has left the work list (expect 0)'
SELECT count(*) AS still_listed FROM stock_drift WHERE product_id = :pid;
ROLLBACK;
\echo '--- done: the count above was rolled back'
