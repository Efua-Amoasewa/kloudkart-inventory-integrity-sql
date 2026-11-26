-- 01_integrity_checks.sql
-- One pass, one result set: every check the schema's missing constraints call for,
-- with the number of rows that slipped through. Read-only; safe to rerun at any time.
-- Finding ids (F-xx) match docs/data_findings.md.

WITH checks (finding, check_name, constraint_missing, row_count) AS (

    -- ---------------------------------------------------------------- relationships
    -- An anti-join per unenforced foreign key: rows whose parent is not there.
    SELECT 'F-08', 'order_items pointing at a missing order', 'FOREIGN KEY order_items.order_id',
           count(*)
    FROM order_items oi
    LEFT JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_id IS NULL

    UNION ALL
    SELECT 'F-09', 'orders pointing at a missing customer', 'FOREIGN KEY orders.customer_id',
           count(*)
    FROM orders o
    LEFT JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.customer_id IS NOT NULL
      AND c.customer_id IS NULL

    UNION ALL
    SELECT '-', 'order_items pointing at a missing product', 'FOREIGN KEY order_items.product_id',
           count(*)
    FROM order_items oi
    LEFT JOIN products p ON p.product_id = oi.product_id
    WHERE p.product_id IS NULL

    UNION ALL
    SELECT 'F-14', 'inventory_log rows for a missing product', 'FOREIGN KEY inventory_log.product_id',
           count(*)
    FROM inventory_log l
    LEFT JOIN products p ON p.product_id = l.product_id
    WHERE p.product_id IS NULL

    UNION ALL
    SELECT 'F-12', 'categories whose parent does not exist', 'FOREIGN KEY categories.parent_id',
           count(*)
    FROM categories c
    LEFT JOIN categories parent ON parent.category_id = c.parent_id
    WHERE c.parent_id IS NOT NULL
      AND parent.category_id IS NULL

    UNION ALL
    SELECT 'F-13', 'products with no category', 'NOT NULL products.category_id',
           count(*)
    FROM products
    WHERE category_id IS NULL

    -- ---------------------------------------------------------------- identities
    UNION ALL
    SELECT 'F-06', 'customer rows sharing an email (trimmed, any case)', 'UNIQUE customers.email',
           coalesce(sum(rows_per_email), 0)
    FROM (
        SELECT count(*) AS rows_per_email
        FROM customers
        GROUP BY lower(trim(email))
        HAVING count(*) > 1
    ) AS shared_emails

    UNION ALL
    SELECT 'F-07', 'emails with leading or trailing spaces', 'CHECK email = trim(email)',
           count(*)
    FROM customers
    WHERE email <> trim(email)

    UNION ALL
    SELECT 'F-05', 'order lines repeated with identical product, quantity and price', 'UNIQUE (order_id, product_id)',
           coalesce(sum(copies - 1), 0)
    FROM (
        SELECT count(*) AS copies
        FROM order_items
        GROUP BY order_id, product_id, quantity, unit_price
        HAVING count(*) > 1
    ) AS repeated_lines

    -- ---------------------------------------------------------------- value ranges
    UNION ALL
    SELECT 'F-01', 'products with negative stock', 'CHECK stock_quantity >= 0',
           count(*)
    FROM products
    WHERE stock_quantity < 0

    UNION ALL
    -- 99% of lines are 5 units or fewer; 999 and 9999 are keying errors, not orders.
    SELECT 'F-04', 'order lines with quantity of 999 or more', 'CHECK quantity BETWEEN 1 AND <sane max>',
           count(*)
    FROM order_items
    WHERE quantity >= 999

    UNION ALL
    SELECT 'F-10', 'order lines with no unit price', 'NOT NULL order_items.unit_price',
           count(*)
    FROM order_items
    WHERE unit_price IS NULL

    UNION ALL
    SELECT 'F-10', 'order lines with a unit price of zero', 'CHECK unit_price > 0',
           count(*)
    FROM order_items
    WHERE unit_price = 0

    UNION ALL
    SELECT 'F-11', 'orders dated in the future', 'CHECK order_date <= now()',
           count(*)
    FROM orders
    WHERE order_date > now()

    UNION ALL
    SELECT 'F-11', 'inventory_log rows dated in the future', 'CHECK created_at <= now()',
           count(*)
    FROM inventory_log
    WHERE created_at > now()

    -- ---------------------------------------------------------------- types / vocabularies
    UNION ALL
    SELECT 'F-03', 'distinct spellings of order status', 'CHECK status IN (...) or a lookup table',
           count(DISTINCT status)
    FROM orders

    UNION ALL
    SELECT 'F-03', 'orders a filter on status = ''completed'' would miss', 'CHECK status IN (...)',
           count(*)
    FROM orders
    WHERE lower(trim(status)) IN ('completed', 'complete')
      AND status <> 'completed'

    -- ---------------------------------------------------------------- reconciliations
    UNION ALL
    -- Stock should equal the sum of every movement ever logged for the product.
    SELECT 'F-02', 'products whose stock does not equal the sum of their log', 'none (needs a single write path)',
           count(*)
    FROM products p
    JOIN (
        SELECT product_id, sum(change_qty) AS logged_stock
        FROM inventory_log
        GROUP BY product_id
    ) AS logged ON logged.product_id = p.product_id
    WHERE p.stock_quantity <> logged.logged_stock

    UNION ALL
    -- Categories never reached by walking down from the roots: a loop or a broken parent.
    SELECT 'F-12', 'categories unreachable from a root (loop or missing parent)', 'FOREIGN KEY + CHECK no cycles',
           count(*)
    FROM categories
    WHERE category_id NOT IN (
        WITH RECURSIVE reachable AS (
            SELECT category_id FROM categories WHERE parent_id IS NULL
            UNION ALL
            SELECT child.category_id
            FROM categories child
            JOIN reachable r ON child.parent_id = r.category_id
        ) CYCLE category_id SET is_cycle USING walk_path
        SELECT category_id FROM reachable
    )
)
SELECT finding, check_name, constraint_missing, row_count
FROM checks
ORDER BY finding, check_name;
