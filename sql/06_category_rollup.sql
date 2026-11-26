-- 06_category_rollup.sql
-- Nana's requirement 3: low stock at a glance, rolled up through a category tree of any
-- depth (Electronics -> Phones -> Phone Accessories -> Cases -> ...).
--
-- Decisions (ADR-005):
--   * Low stock    = fewer than low_stock_threshold() units (5): about a week of sales for
--                    a typical product (median ~18 units / 30 days in the last 90 days of
--                    data). Out of stock (0 or below) is counted separately.
--   * A category's figure INCLUDES every category beneath it, at any depth. A product is
--     counted once per category above it, never twice for the same category.
--   * Depth is never hard-coded: the recursive walk stops when a level finds no children.
--   * The walk carries a CYCLE guard. The data has a loop (F-12: Promotions <-> Seasonal
--     Promotions); without the guard the walk would never finish.
--   * Products that a walk from the top cannot reach (F-12) or that have no category (F-13)
--     are still shown, so a low-stock product can never be invisible.
--   * This stays a live view, not a stored answer: stock changes with every sale, and a
--     stale low-stock figure is the dangerous kind. It answers in milliseconds anyway.

BEGIN;

-- ------------------------------------------------------------------ the one threshold
CREATE FUNCTION low_stock_threshold() RETURNS integer
LANGUAGE sql IMMUTABLE AS $$ SELECT 5 $$;

-- ------------------------------------------------------------------ where each category sits
-- Walk down from the top-level categories to give every reachable category its depth and
-- full path. Categories caught in a loop or under a missing parent never appear here.
CREATE VIEW category_paths AS
WITH RECURSIVE walk AS (
    SELECT category_id,
           category_name,
           1                    AS depth,
           category_name::text  AS full_path
    FROM categories
    WHERE parent_id IS NULL

    UNION ALL

    SELECT child.category_id,
           child.category_name,
           w.depth + 1,
           w.full_path || ' > ' || child.category_name
    FROM categories child
    JOIN walk w ON child.parent_id = w.category_id
) CYCLE category_id SET is_cycle USING walk_path
SELECT category_id, category_name, depth, full_path
FROM walk
WHERE NOT is_cycle;

-- ------------------------------------------------------------------ every category, and all beneath it
-- One row per (category, category at or below it). Every category starts its own walk,
-- including ones a walk from the top cannot reach, so their products still roll up
-- somewhere. The CYCLE guard stops the Promotions loop after one lap.
CREATE VIEW category_subtree AS
WITH RECURSIVE descend AS (
    SELECT category_id AS ancestor_id,
           category_id AS descendant_id
    FROM categories

    UNION ALL

    SELECT d.ancestor_id,
           child.category_id
    FROM categories child
    JOIN descend d ON child.parent_id = d.descendant_id
) CYCLE descendant_id SET is_cycle USING walk_path
SELECT DISTINCT ancestor_id, descendant_id      -- DISTINCT: a loop must not count twice
FROM descend
WHERE NOT is_cycle;

-- ------------------------------------------------------------------ the rollup
CREATE VIEW low_stock_by_category AS
SELECT c.category_id,
       c.category_name,
       cp.depth,
       coalesce(cp.full_path, c.category_name || ' (not reachable from a top category)') AS full_path,
       count(p.product_id)                                                      AS products,
       count(p.product_id) FILTER (WHERE p.stock_quantity < low_stock_threshold()) AS low_stock_products,
       count(p.product_id) FILTER (WHERE p.stock_quantity <= 0)                 AS out_of_stock_products
FROM categories c
JOIN category_subtree st   ON st.ancestor_id = c.category_id
LEFT JOIN products p       ON p.category_id = st.descendant_id
LEFT JOIN category_paths cp ON cp.category_id = c.category_id
GROUP BY c.category_id, c.category_name, cp.depth, cp.full_path

UNION ALL

-- F-13: products with no category still need to be seen.
SELECT NULL,
       'Uncategorised',
       NULL,
       'Uncategorised (no category recorded)',
       count(*),
       count(*) FILTER (WHERE stock_quantity < low_stock_threshold()),
       count(*) FILTER (WHERE stock_quantity <= 0)
FROM products
WHERE category_id IS NULL;

-- ------------------------------------------------------------------ the products themselves
-- The drill-down behind the counts: which products, where, how many left.
CREATE VIEW low_stock_products AS
SELECT p.product_id,
       p.product_name,
       p.stock_quantity,
       coalesce(cp.full_path,
                CASE WHEN p.category_id IS NULL THEN 'Uncategorised'
                     ELSE '(category not reachable from a top category)' END) AS category_path
FROM products p
LEFT JOIN category_paths cp ON cp.category_id = p.category_id
WHERE p.stock_quantity < low_stock_threshold();

COMMIT;
