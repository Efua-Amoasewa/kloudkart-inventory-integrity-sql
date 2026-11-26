-- tests/test_audit_trail.sql
-- Exercises sql/03_audit_trail.sql inside one transaction and rolls everything back, so
-- the database is unchanged afterwards. Run WITHOUT ON_ERROR_STOP: tests 4 and 5 are
-- meant to fail, and each is wrapped in a savepoint so the rest can continue.

\pset pager off
BEGIN;

SELECT min(product_id) AS pid FROM products \gset

\echo '--- test 1: a restock through record_stock_movement is logged with its reason and note'
SELECT record_stock_movement(:pid, 5, 'restock', 'supplier delivery test') AS stock_after_restock;

\echo '--- test 2: a manual UPDATE is still logged, as manual_update'
UPDATE products SET stock_quantity = stock_quantity - 1 WHERE product_id = :pid;

\echo '--- test 3: a price-only change writes no log row'
UPDATE products SET price = price WHERE product_id = :pid;

\echo '--- expect: newest two rows are manual_update (-1) and restock (+5); nothing for the price change'
SELECT log_id, change_qty, reason, note, stock_after, recorded_by
FROM inventory_log
WHERE product_id = :pid
ORDER BY log_id DESC
LIMIT 3;

\echo '--- test 4: editing a log row is refused (expect ERROR: inventory_log is append-only)'
SAVEPOINT before_edit;
UPDATE inventory_log SET change_qty = 0 WHERE log_id = (SELECT max(log_id) FROM inventory_log);
ROLLBACK TO SAVEPOINT before_edit;

\echo '--- test 5: going below zero is refused (expect ERROR: ... products_stock_not_negative)'
SAVEPOINT before_negative;
SELECT record_stock_movement(:pid, -100000, 'correction');
ROLLBACK TO SAVEPOINT before_negative;

ROLLBACK;
\echo '--- done: everything above was rolled back'
