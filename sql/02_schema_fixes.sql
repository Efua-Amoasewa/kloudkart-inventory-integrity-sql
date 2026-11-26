-- 02_schema_fixes.sql
-- The constraints Kloud Kart's schema never had, added so that NEW writes cannot repeat
-- the faults in docs/data_findings.md.
--
-- Rule used throughout: where existing rows already break a rule, the constraint is added
-- NOT VALID. PostgreSQL then enforces it on every insert and update from now on, but does
-- not certify the old rows. Old faults are reported, not silently rewritten: the correct
-- value for a negative stock or a missing customer is not something this script can know.
--
-- Checked against race_test.py: it inserts products with no category, and its cleanup
-- deletes order_items -> orders -> inventory_log -> products in that order, so none of
-- these constraints blocks it.

BEGIN;

-- ------------------------------------------------------------------ F-01 negative stock
-- The safety net under place_order: even a future bug cannot sell below zero.
-- 14 products are already negative, hence NOT VALID.
ALTER TABLE products
    ADD CONSTRAINT products_stock_not_negative CHECK (stock_quantity >= 0) NOT VALID;

-- ------------------------------------------------------------------ relationships
-- Zero existing orphans: these can be fully validated.
ALTER TABLE order_items
    ADD CONSTRAINT order_items_product_fk
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE products
    ADD CONSTRAINT products_category_fk
    FOREIGN KEY (category_id) REFERENCES categories (category_id);

-- Existing orphans (F-08, F-09, F-12, F-14): enforced for new rows only.
ALTER TABLE order_items
    ADD CONSTRAINT order_items_order_fk
    FOREIGN KEY (order_id) REFERENCES orders (order_id) NOT VALID;

ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id) NOT VALID;

ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_product_fk
    FOREIGN KEY (product_id) REFERENCES products (product_id) NOT VALID;

ALTER TABLE categories
    ADD CONSTRAINT categories_parent_fk
    FOREIGN KEY (parent_id) REFERENCES categories (category_id) NOT VALID;

-- ------------------------------------------------------------------ value ranges
-- No existing line has quantity <= 0 or a negative price, so these validate in full.
-- NULL prices (F-10) pass a CHECK; they are reported, not blocked retroactively.
ALTER TABLE order_items
    ADD CONSTRAINT order_items_quantity_positive CHECK (quantity > 0),
    ADD CONSTRAINT order_items_price_not_negative CHECK (unit_price >= 0);

-- F-07: new emails must arrive trimmed. 1,314 existing rows do not, hence NOT VALID.
ALTER TABLE customers
    ADD CONSTRAINT customers_email_trimmed CHECK (email = trim(email)) NOT VALID;

COMMIT;
