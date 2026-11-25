-- ICT371 - Question 6: Monthly Payroll Processing 


-- (a) Tables and seed data 
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

CREATE TABLE employees (
    employee_id   SERIAL PRIMARY KEY,
    full_name     VARCHAR(100) NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active        BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,      -- always the first of the month
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Agnes Mulenga', 8000, 1200, 600, TRUE),
('Brian Chibwe',  7000, 1000, 500, TRUE),
('Felix Banda',   6000,  800, 400, FALSE);  -- inactive employee, still has history

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded   NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative for employee %', p_employee_id;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_emp RECORD;
    v_gross NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR v_emp IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active = TRUE LOOP
        IF NOT EXISTS (
            SELECT 1 FROM payroll
            WHERE employee_id = v_emp.employee_id AND pay_month = p_month
        ) THEN
            v_gross := v_emp.basic_salary + v_emp.allowance;
            v_net   := fn_net_pay(v_emp.employee_id);  -- raises -> aborts whole call

            INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
            VALUES (v_emp.employee_id, p_month, v_gross, v_net);
        END IF;
        -- existing employee/month row is left unchanged (no ELSE branch)
    END LOOP;
END;
$$;

CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date);
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_salary_audit();

-- (e) View 
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;
-- joining on employees (not filtering active) keeps historical rows for
-- employees who have since become inactive.

SELECT * FROM v_payroll_report ORDER BY pay_month;

-- (f) Index 
-- Supports: a report filtered by pay_month across all employees.
-- The existing UNIQUE(employee_id, pay_month) index leads with employee_id,
-- so it is not useful for a pay_month-only filter; a dedicated index is needed.
CREATE INDEX idx_payroll_paymonth ON payroll (pay_month);

EXPLAIN ANALYZE
SELECT * FROM payroll WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;

-- (g) Scheduled job
SELECT cron.schedule(
    'process_payroll_monthly',
    '0 2 1 * *',
    $$CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date)$$
);

-- Inspecting the job and its run history:
SELECT * FROM cron.job WHERE jobname = 'process_payroll_monthly';
SELECT * FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll_monthly')
ORDER BY start_time DESC;
