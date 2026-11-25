-- ICT371 - Question 3: Library Returns and Overdue Fines 

-- (a) Tables and seed data 
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0,
    CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
('Database Systems'), ('Clean Code'), ('Intro to Algorithms');

-- open overdue loan, an on-time (not yet due) loan, a returned loan, plus three more
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on) VALUES
(1, 'John Mwale',    CURRENT_DATE - 20, CURRENT_DATE - 10, NULL),             -- open, overdue
(2, 'Grace Tembo',   CURRENT_DATE - 2,  CURRENT_DATE + 5,  NULL),             -- open, not yet due
(3, 'Peter Sakala',  CURRENT_DATE - 15, CURRENT_DATE - 5,  CURRENT_DATE - 3), -- returned (fine owed)
(1, 'Joseph Daka',   CURRENT_DATE - 30, CURRENT_DATE - 20, CURRENT_DATE - 20),-- returned exactly on due date
(2, 'Mary Chanda',   CURRENT_DATE - 6,  CURRENT_DATE + 1,  NULL),             -- open, not yet due
(3, 'Alice Zulu',    CURRENT_DATE - 40, CURRENT_DATE - 25, CURRENT_DATE - 20);-- returned late

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end_date DATE;
    v_days     INT;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_end_date := CASE WHEN v_returned IS NOT NULL
                        THEN LEAST(p_as_of, v_returned)
                        ELSE p_as_of END;

    v_days := v_end_date - v_due;
    IF v_days < 0 THEN v_days := 0; END IF;

    RETURN v_days * 2.00;  -- K2 per overdue day
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed  DATE;
    v_returned  DATE;
    v_fine      NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed_on %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);  -- returned_on still NULL here, so p_as_of is used directly

    UPDATE loans
    SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loan_audit();

-- (e) View 
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index 
-- Supports: a given book's unreturned loans.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
-- Justification: a partial index limited to returned_on IS NULL is smaller
-- than a full index and exactly matches the common "currently out" query,
-- so Postgres can use it directly for this predicate.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
    v_fine  NUMERIC(12,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    INTO v_count, v_fine
    FROM loans
    WHERE due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of);

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_fine)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule('refresh_overdue_daily', '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
