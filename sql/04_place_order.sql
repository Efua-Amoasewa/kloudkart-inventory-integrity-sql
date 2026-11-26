-- 04_place_order.sql
-- Nana's requirement 1: two customers racing for the last unit - exactly one gets it,
-- the other gets an instant, clear "out of stock", every time.
--
-- Contract fixed by race_test.py:
--   place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer)
--   RETURNS TABLE (success boolean, order_id bigint, message text)
--
-- Mechanism (ADR-001): one conditional UPDATE that checks and decrements in the same
-- statement. PostgreSQL row-locks the product while updating it; a second buyer arriving
-- at the same instant waits for that lock, then re-reads the committed row (Read Committed
-- re-check) and finds too little stock, so its UPDATE changes nothing. No serialization
-- error is possible, so nothing has to be retried.
--
-- Everything below runs inside the caller's single transaction: the stock decrement, the
-- sale movement (written by the trigger in 03_audit_trail.sql), the order and its line
-- either all happen or none do.

-- A buyer queued behind a lock for longer than this is told "busy" instead of waiting
-- indefinitely. In a 400-buyer flash sale each sale holds the lock for well under a
-- millisecond, so the queue clears long before this; it exists for the abnormal case of
-- a lock held by something else (a stuck manual transaction).
CREATE FUNCTION place_order_lock_timeout() RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT '5s' $$;

CREATE FUNCTION place_order(
    p_customer_id bigint,
    p_product_id  bigint,
    p_quantity    integer
) RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_order_id    bigint;
    v_unit_price  numeric(12,2);
    v_available   integer;
BEGIN
    -- ---------------------------------------------------------------- cheap refusals first
    -- These take no lock, so a malformed request never makes real buyers wait.
    IF p_quantity IS NULL OR p_quantity < 1 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'refused: quantity must be at least 1';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, 'refused: unknown customer';
        RETURN;
    END IF;

    PERFORM set_config('lock_timeout', place_order_lock_timeout(), true);

    -- ---------------------------------------------------------------- check and decrement
    -- The order id is taken first so the trigger can stamp it on the sale movement.
    -- A refused attempt leaves a gap in order ids; gaps are harmless and expected.
    v_order_id := nextval(pg_get_serial_sequence('orders', 'order_id'));
    PERFORM set_config('kloudkart.movement_reason', 'sale', true);
    PERFORM set_config('kloudkart.movement_order_id', v_order_id::text, true);

    UPDATE products p
    SET    stock_quantity = p.stock_quantity - p_quantity
    WHERE  p.product_id = p_product_id
      AND  p.stock_quantity >= p_quantity
    RETURNING p.price INTO v_unit_price;

    IF NOT FOUND THEN
        PERFORM set_config('kloudkart.movement_reason', '', true);
        PERFORM set_config('kloudkart.movement_order_id', '', true);

        SELECT p.stock_quantity INTO v_available
        FROM products p
        WHERE p.product_id = p_product_id;

        IF NOT FOUND THEN
            RETURN QUERY SELECT false, NULL::bigint, 'refused: unknown product';
        ELSE
            RETURN QUERY SELECT false, NULL::bigint,
                format('out of stock: %s requested, %s available',
                       p_quantity, greatest(v_available, 0));
        END IF;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------- record the sale
    INSERT INTO orders (order_id, customer_id, order_date, status, total_amount)
    VALUES (v_order_id, p_customer_id, now(), 'completed', v_unit_price * p_quantity);

    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_unit_price);

    PERFORM set_config('kloudkart.movement_reason', '', true);
    PERFORM set_config('kloudkart.movement_order_id', '', true);

    RETURN QUERY SELECT true, v_order_id, 'order placed';

EXCEPTION
    -- Only the one failure this design can produce under contention is caught. Everything
    -- it did is rolled back by the block, so a "busy" answer leaves no stock change behind.
    WHEN lock_not_available THEN
        RETURN QUERY SELECT false, NULL::bigint,
            'busy: too many buyers for this product right now, please try again';
END;
$$;
