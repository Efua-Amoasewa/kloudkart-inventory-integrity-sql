-- tests/test_category_rollup.sql
-- Checks sql/06_category_rollup.sql: depth is found, nothing is double counted, nothing is
-- invisible, and a new level needs no query change. The new level is rolled back.

\pset pager off

\echo '--- 1: top-level families, plus everything a walk from the top cannot reach'
SELECT category_name, depth, low_stock_products, out_of_stock_products, products
FROM low_stock_by_category
WHERE depth = 1 OR depth IS NULL
ORDER BY low_stock_products DESC;

\echo '--- 2: deepest level found by the walk (expect 4 today)'
SELECT max(depth) AS deepest FROM category_paths;

\echo '--- 3: the Phones branch, level by level'
SELECT full_path, low_stock_products
FROM low_stock_by_category
WHERE full_path LIKE 'Electronics > Phones%'
ORDER BY depth, full_path;

\echo '--- 4: no double counting - expect tops + loop island + Clearance + uncategorised = total'
SELECT (SELECT count(*) FROM low_stock_products)                                          AS total_low,
       (SELECT sum(low_stock_products) FROM low_stock_by_category WHERE depth = 1)        AS via_tops,
       (SELECT low_stock_products FROM low_stock_by_category WHERE category_id = 9001)   AS promo_loop_island,
       (SELECT low_stock_products FROM low_stock_by_category WHERE category_id = 9003)   AS clearance_island,
       (SELECT low_stock_products FROM low_stock_by_category WHERE category_id IS NULL)  AS uncategorised;

\echo '--- 5: add a 5th level under Cases (rolled back) - expect depth 5 and counts rising by 1'
BEGIN;
SELECT category_id AS cases_id
FROM category_paths
WHERE full_path = 'Electronics > Phones > Phone Accessories > Cases' \gset
INSERT INTO categories (category_id, category_name, parent_id) VALUES (99901, 'Leather Cases', :cases_id);
INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
VALUES (99902, 'TEST leather case', 99901, 50.00, 2, now());
SELECT full_path, depth, low_stock_products
FROM low_stock_by_category
WHERE full_path LIKE '%Cases%' OR (depth = 1 AND category_name = 'Electronics')
ORDER BY depth;
ROLLBACK;
