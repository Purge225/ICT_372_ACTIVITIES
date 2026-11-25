-- ICT371 - Question 7: Water Meter Readings and Billing

-- (a) Tables and seed data 
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL PRIMARY KEY,
    customer_id       INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month     DATE NOT NULL,      -- first of month
    previous_reading  NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      SERIAL PRIMARY KEY,
    reading_id   INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(10,2) NOT NULL,
    amount_paid  NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on       DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES ('Patrick Chola'), ('Monde Siwale'), ('Lweendo Hamoonga');

-- readings covering zero, exactly 10, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, date_trunc('month', CURRENT_DATE)::date, 100, 100),  -- zero units
(2, date_trunc('month', CURRENT_DATE)::date, 200, 210),  -- exactly 10 units
(3, date_trunc('month', CURRENT_DATE)::date, 50,  70),   -- 20 units (above 10)
(1, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date, 90, 100),
(2, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date, 185, 200),
(3, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date, 30, 50);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC AS $$
DECLARE
    v_charge NUMERIC;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev NUMERIC;
    v_curr NUMERIC;
    v_units NUMERIC;
    v_charge NUMERIC;
BEGIN
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

CALL pr_generate_bill(1, CURRENT_DATE + 14);
CALL pr_generate_bill(2, CURRENT_DATE + 14);
CALL pr_generate_bill(3, CURRENT_DATE + 14);

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_reading_guard() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_guard
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_guard();
-- Fires for any INSERT/UPDATE, including direct SQL bulk imports.

-- (e) View 
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, (b.charge - b.amount_paid) AS outstanding
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index 
-- Supports: date-based searches for overdue, unpaid bills.
CREATE INDEX idx_bills_due_unpaid ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN ANALYZE
SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
-- Justification: the overdue-bill query always combines "due before today"
-- with "not fully paid"; a partial index on due_on restricted to unpaid
-- bills avoids indexing settled bills and matches this query directly.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
DECLARE
    v_total NUMERIC(14,2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0) INTO v_total
    FROM bills WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule('refresh_receivables_daily', '30 0 * * *',
    $$CALL pr_refresh_receivables()$$);
