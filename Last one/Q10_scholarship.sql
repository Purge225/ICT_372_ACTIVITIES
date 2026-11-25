-- ICT371 - Question 10: Scholarship Application Assessment


-- (a) Tables and seed data 
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id    SERIAL PRIMARY KEY,
    student_id        INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income    NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark      NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on      DATE NOT NULL,
    status            VARCHAR(10) NOT NULL CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id     SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status   VARCHAR(10) NOT NULL,
    new_status   VARCHAR(10) NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
('S9001','Thandiwe Mwale'), ('S9002','Obvious Phiri'), ('S9003','Gift Chanda');

-- six PENDING applications: qualifying, non-qualifying, and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 20, 2000, 75, CURRENT_DATE - 5, 'PENDING'),  -- qualifies
(1, 24, 2900, 70, CURRENT_DATE - 4, 'PENDING'),  -- boundary: income=2900, mark=70 -> qualifies
(2, 17, 1000, 90, CURRENT_DATE - 3, 'PENDING'),  -- age below range -> fails
(2, 25, 3000, 70, CURRENT_DATE - 2, 'PENDING'),  -- boundary: age=25, income=3000, mark=70 -> qualifies
(3, 22, 3100, 85, CURRENT_DATE - 1, 'PENDING'),  -- income above limit -> fails
(3, 23, 1500, 65, CURRENT_DATE,     'PENDING');  -- mark below 70 -> fails

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must all be provided';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative: %', p_income;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive: %', p_age;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100: %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_status  VARCHAR(10);
    v_age     INT;
    v_income  NUMERIC;
    v_mark    NUMERIC;
    v_eligible BOOLEAN;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status=%)', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_decision_audit();

-- (e) View 
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';
-- household income intentionally omitted

SELECT * FROM v_approved_applicants;

-- (f) Index 
-- Supports: applications searched by status within a submitted_on date range.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN ANALYZE
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- Justification: status is an equality filter and submitted_on a range
-- filter, matching the weekly assessment batch job; a composite index with
-- status first supports an efficient index range scan.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    v_app RECORD;
BEGIN
    FOR v_app IN SELECT application_id FROM applications WHERE status = 'PENDING' LOOP
        CALL pr_assess_application(v_app.application_id);
    END LOOP;
    -- Only PENDING rows are selected, and pr_assess_application itself
    -- rejects non-PENDING applications, so a rerun neither reassesses
    -- completed applications nor duplicates audit entries.
END;
$$;

SELECT cron.schedule('assess_pending_weekly', '0 8 * * 1',
    $$CALL pr_assess_pending()$$);
