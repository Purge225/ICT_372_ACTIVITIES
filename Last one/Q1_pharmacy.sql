-- ICT371 - Question 1: Pharmacy Stock and Daily Sales 

-- (a) Tables and seed data 
DROP TABLE IF EXISTS stock_audit, daily_sales, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id       SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on       DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id      SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty       INTEGER NOT NULL,
    new_qty       INTEGER NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date    DATE PRIMARY KEY,
    total_qty     INTEGER NOT NULL DEFAULT 0,
    total_amount  NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol 500mg', 1.50, 200),
('Amoxicillin 250mg', 3.75, 150),
('Ibuprofen 400mg',   2.20, 100);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_stock INT;
    v_price NUMERIC(10,2);
BEGIN
    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: have %, need %', p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
    -- Any RAISE above aborts the whole procedure call, so the sale and the
    -- stock deduction either both happen or neither does.
END;
$$;

-- seed six sales through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE);
CALL pr_record_sale(2, 5,  CURRENT_DATE);
CALL pr_record_sale(3, 8,  CURRENT_DATE);
CALL pr_record_sale(1, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 6,  CURRENT_DATE - 1);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_stock_audit();

-- (e) View 
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- query the view after a sale
SELECT * FROM v_low_stock;

-- (f) Index 
-- Supports: one medicine's sales within a sold_on date range.
CREATE INDEX idx_sales_medicine_solddate ON sales (medicine_id, sold_on);

EXPLAIN ANALYZE
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
-- Justification: the query equality-filters on medicine_id and range-filters
-- on sold_on. A composite B-tree index with medicine_id leading lets Postgres
-- do an index range scan instead of a full sequential scan of sales.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_qty INT;
    v_amt NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(quantity),0), COALESCE(SUM(quantity*unit_price),0)
    INTO v_qty, v_amt
    FROM sales WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amt)
    ON CONFLICT (sales_date)
    DO UPDATE SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
    -- ON CONFLICT ... DO UPDATE guarantees a rerun replaces totals rather
    -- than duplicating or double-counting them.
END;
$$;

-- requires: CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_sales_daily', '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
