-- 08_improvement.sql
-- Improvement beyond the brief (docs/improvement.md): a stock-count work list and a way to
-- close each item on it through the audit trail.
--
-- Nana's stock counts "no longer match reality closely enough to trust". F-01 and F-02 make
-- that measurable: products with negative stock, and products whose stock disagrees with
-- the sum of their own movement log. This turns those findings into something staff can
-- act on, and keeps them from coming back unnoticed.

BEGIN;

-- ------------------------------------------------------------------ the work list
-- Since 03_audit_trail.sql every stock change writes a movement, so stock_quantity and
-- sum(change_qty) move together. A product appearing here AFTER its count has been
-- recorded means something bypassed the trail - which is the point of watching it.
CREATE VIEW stock_drift AS
WITH logged AS (
    SELECT product_id,
           sum(change_qty) AS logged_stock,
           max(created_at) AS last_movement_at
    FROM inventory_log
    GROUP BY product_id
)
SELECT p.product_id,
       p.product_name,
       p.stock_quantity                                  AS recorded_stock,
       coalesce(l.logged_stock, 0)                       AS stock_per_movement_log,
       p.stock_quantity - coalesce(l.logged_stock, 0)    AS unexplained_difference,
       l.last_movement_at,
       CASE
           WHEN p.stock_quantity < 0 THEN 'negative stock: customers paid for goods not on the shelf'
           ELSE 'stock and movement log disagree'
       END                                               AS why_listed
FROM products p
LEFT JOIN logged l ON l.product_id = p.product_id
WHERE p.stock_quantity < 0
   OR p.stock_quantity <> coalesce(l.logged_stock, 0);

-- ------------------------------------------------------------------ closing an item
-- Staff count the shelf; this records what they found. Two movements at most, both in the
-- trail, both in one transaction:
--   1. 'stock_take'  - moves recorded stock to the counted figure (via the products trigger)
--   2. 'correction'  - only if the log still disagrees afterwards: one entry that closes the
--                      historical gap, so the log explains the counted figure from now on.
CREATE FUNCTION record_stock_count(
    p_product_id bigint,
    p_counted    integer,
    p_counted_by text
) RETURNS TABLE (stock_change integer, log_gap_closed integer, stock_now integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_recorded integer;
    v_logged   integer;
BEGIN
    IF p_counted IS NULL OR p_counted < 0 THEN
        RAISE EXCEPTION 'a shelf count cannot be negative or missing (got %)', p_counted;
    END IF;
    IF coalesce(trim(p_counted_by), '') = '' THEN
        RAISE EXCEPTION 'say who counted, so the trail records it';
    END IF;

    -- Same row lock place_order takes: a sale cannot slip in between reading and writing.
    SELECT p.stock_quantity INTO v_recorded
    FROM products p
    WHERE p.product_id = p_product_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'product % does not exist', p_product_id;
    END IF;

    stock_change := p_counted - v_recorded;
    IF stock_change <> 0 THEN
        PERFORM set_config('kloudkart.movement_reason', 'stock_take', true);
        PERFORM set_config('kloudkart.movement_note', 'shelf count by ' || p_counted_by, true);
        UPDATE products p SET stock_quantity = p_counted WHERE p.product_id = p_product_id;
        PERFORM set_config('kloudkart.movement_reason', '', true);
        PERFORM set_config('kloudkart.movement_note', '', true);
    END IF;

    SELECT coalesce(sum(l.change_qty), 0) INTO v_logged
    FROM inventory_log l
    WHERE l.product_id = p_product_id;

    log_gap_closed := p_counted - v_logged;
    IF log_gap_closed <> 0 THEN
        INSERT INTO inventory_log (product_id, change_qty, reason, note, stock_after)
        VALUES (p_product_id, log_gap_closed, 'correction',
                'closes historical gap between stock and log; shelf count by ' || p_counted_by,
                p_counted);
    END IF;

    stock_now := p_counted;
    RETURN NEXT;
END;
$$;

COMMIT;
