-- ICT371 - Question 2: University Fee Payments 


-- (a) Tables and seed data 
DROP TABLE IF EXISTS payment_audit, daily_collections, payments, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id   SERIAL PRIMARY KEY,
    student_id   INTEGER NOT NULL REFERENCES students(student_id),
    amount       NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on      DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id     SERIAL PRIMARY KEY,
    payment_id   INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id   INTEGER NOT NULL REFERENCES students(student_id),
    amount       NUMERIC(12,2) NOT NULL,
    logged_at    TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
('S2301', 'Mwansa Banda', 5000.00),
('S2302', 'Chileshe Phiri', 3500.00),
('S2303', 'Natasha Mulenga', 4200.00);   -- will start with no payments

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid    NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee_due FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;  -- if no payments exist v_paid = 0, so full fee returned
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: %', p_amount;
    END IF;

    v_balance := fn_fee_balance(p_student_id);  -- raises if unknown student

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %', p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
    -- fee_due is never touched here; the audit row is written by the trigger.
END;
$$;

CALL pr_receive_payment(1, 2000.00, CURRENT_DATE);
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE);
CALL pr_receive_payment(2,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  300.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 5);
-- student 3 deliberately left with zero payments

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (e) View 
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index 
-- Supports: payments filtered by student_id and a paid_on date range.
CREATE INDEX idx_payments_student_paiddate ON payments (student_id, paid_on);

EXPLAIN ANALYZE
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- Justification: student_id is an equality filter, paid_on a range filter,
-- so a composite index with student_id first supports an efficient index
-- range scan for this access pattern.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
    v_amt   NUMERIC(12,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount),0) INTO v_count, v_amt
    FROM payments WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amt)
    ON CONFLICT (collection_date)
    DO UPDATE SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
