-- 00_check_setup.sql
-- Confirms the environment before anything else is believed:
--   * server version starts with 18 (the version the lab is graded against)
--   * max_connections is 500, not the default 100 (race_test.py test 2 needs 400)
--   * all six tables loaded

SELECT version() AS server_version;

SHOW max_connections;

SELECT 'categories'    AS table_name, count(*) AS row_count FROM categories
UNION ALL SELECT 'products',      count(*) FROM products
UNION ALL SELECT 'customers',     count(*) FROM customers
UNION ALL SELECT 'orders',        count(*) FROM orders
UNION ALL SELECT 'order_items',   count(*) FROM order_items
UNION ALL SELECT 'inventory_log', count(*) FROM inventory_log
ORDER BY table_name;
