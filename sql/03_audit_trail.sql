-- 03_audit_trail.sql
-- Nana's requirement 4: a trail of every stock movement an auditor can walk afterwards.
--
-- Design (ADR-003):
--   * A trigger on products writes one inventory_log row for EVERY change to
--     stock_quantity, whoever makes it: place_order, record_stock_movement, or a person
--     typing UPDATE in a terminal. A trigger cannot be forgotten - that is what it is for.
--   * Callers that know WHY stock moved (a sale, a restock) say so by setting two
--     transaction-local settings before the update; the trigger reads them. A change made
--     without them is still logged, as 'manual_update', so it stands out.
--   * The log is append-only: rows cannot be edited. Deletes stay possible because
--     race_test.py removes its own fixtures' movements when it cleans up.

BEGIN;

-- ------------------------------------------------------------------ extend the log
ALTER TABLE inventory_log
    ADD COLUMN order_id    bigint,                      -- the order that caused a sale
    ADD COLUMN stock_after integer,                     -- stock once this movement applied
    ADD COLUMN recorded_by text;                        -- database role that made the change

-- Defaults are set AFTER adding the columns so the 282,352 historical rows stay NULL:
-- adding a column WITH a default would stamp every old row with today's role, claiming
-- knowledge of who recorded four years of history that nobody has.
-- No foreign key on order_id, deliberately: history must outlive the rows it describes.
ALTER TABLE inventory_log
    ALTER COLUMN recorded_by SET DEFAULT current_user,
    ALTER COLUMN created_at  SET DEFAULT now();

-- Every reason already in the data, plus the two the trigger itself writes.
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_reason_known CHECK (reason IN (
        'sale', 'restock', 'return', 'correction', 'damage', 'stock_take',
        'opening_balance',   -- a product created with stock already on the shelf
        'manual_update'      -- a stock change made without saying why
    ));

-- ------------------------------------------------------------------ log every change
CREATE FUNCTION log_stock_movement() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_reason   text;
    v_change   integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF coalesce(NEW.stock_quantity, 0) = 0 THEN
            RETURN NEW;                                   -- nothing on the shelf, nothing to log
        END IF;
        v_reason := 'opening_balance';
        v_change := NEW.stock_quantity;
    ELSE
        IF NEW.stock_quantity IS NOT DISTINCT FROM OLD.stock_quantity THEN
            RETURN NEW;                                   -- price or name changed, not stock
        END IF;
        -- current_setting(..., true) returns NULL instead of failing when never set.
        v_reason := coalesce(nullif(current_setting('kloudkart.movement_reason', true), ''),
                             'manual_update');
        v_change := NEW.stock_quantity - coalesce(OLD.stock_quantity, 0);
    END IF;

    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note, order_id, stock_after)
    VALUES (
        NEW.product_id,
        v_change,
        v_reason,
        now(),
        nullif(current_setting('kloudkart.movement_note', true), ''),
        nullif(current_setting('kloudkart.movement_order_id', true), '')::bigint,
        NEW.stock_quantity
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER products_log_stock_movement
    AFTER INSERT OR UPDATE OF stock_quantity ON products
    FOR EACH ROW
    EXECUTE FUNCTION log_stock_movement();

-- ------------------------------------------------------------------ append-only
CREATE FUNCTION refuse_log_edit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'inventory_log is append-only: record a correcting movement instead of editing log_id %',
        OLD.log_id
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER inventory_log_append_only
    BEFORE UPDATE ON inventory_log
    FOR EACH ROW
    EXECUTE FUNCTION refuse_log_edit();

-- ------------------------------------------------------------------ non-sale movements
-- Restocks, returns, damage, corrections and stock takes go through here, so each one
-- carries a reason and a note. Sales go through place_order (04_place_order.sql).
CREATE FUNCTION record_stock_movement(
    p_product_id bigint,
    p_change     integer,
    p_reason     text,
    p_note       text DEFAULT NULL
) RETURNS integer                                       -- stock after the movement
LANGUAGE plpgsql AS $$
DECLARE
    v_stock_after integer;
BEGIN
    IF p_reason = 'sale' THEN
        RAISE EXCEPTION 'sales must go through place_order so they create an order';
    END IF;

    PERFORM set_config('kloudkart.movement_reason', p_reason, true);
    PERFORM set_config('kloudkart.movement_note', coalesce(p_note, ''), true);

    -- The row lock taken here is the same one place_order takes, so a restock and a sale
    -- of the same product queue behind each other instead of overwriting each other.
    UPDATE products
    SET    stock_quantity = stock_quantity + p_change
    WHERE  product_id = p_product_id
    RETURNING stock_quantity INTO v_stock_after;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'product % does not exist', p_product_id;
    END IF;

    -- Clear the context so a later statement in the same transaction is not mislabelled.
    PERFORM set_config('kloudkart.movement_reason', '', true);
    PERFORM set_config('kloudkart.movement_note', '', true);
    RETURN v_stock_after;
END;
$$;

COMMIT;
