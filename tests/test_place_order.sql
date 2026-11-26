-- tests/test_place_order.sql
-- Hand tests for sql/04_place_order.sql on a throwaway product with 1 unit, inside one
-- transaction that is rolled back. The concurrent behaviour is proven by race_test.py;
-- this checks each answer place_order can give.

\pset pager off
BEGIN;

SELECT min(customer_id) AS cid FROM customers \gset
INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
VALUES (99001, 'HAND TEST PRODUCT', NULL, 10.00, 1, now());

\echo '--- test 1: buy the last unit (expect success = t, order_id 1000000 or above)'
SELECT * FROM place_order(:cid, 99001, 1);

\echo '--- test 2: buy again (expect out of stock: 1 requested, 0 available)'
SELECT * FROM place_order(:cid, 99001, 1);

\echo '--- test 3: quantity 0 (expect refused)'
SELECT * FROM place_order(:cid, 99001, 0);

\echo '--- test 4: unknown customer (expect refused)'
SELECT * FROM place_order(-5, 99001, 1);

\echo '--- test 5: unknown product (expect refused)'
SELECT * FROM place_order(:cid, -5, 1);

\echo '--- expect: stock 0, never below'
SELECT stock_quantity FROM products WHERE product_id = 99001;

\echo '--- expect: opening_balance +1, then one sale -1 carrying the order id'
SELECT change_qty, reason, order_id, stock_after
FROM inventory_log
WHERE product_id = 99001
ORDER BY log_id;

ROLLBACK;
\echo '--- done: everything above was rolled back'
