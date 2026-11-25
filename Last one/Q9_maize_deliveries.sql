-- ICT371 - Question 9: Farmer Cooperative Maize Deliveries 


-- (a) Tables and seed data 
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL PRIMARY KEY,
    farmer_id     INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade         CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2),
    total_value   NUMERIC(12,2),
    delivered_on  DATE NOT NULL,
    is_paid       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
('F001','Moses Kunda'), ('F002','Rhoda Banda'), ('F003','Chilufya Mwansa');

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC AS $$
BEGIN
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Unsupported grade: %', p_grade;
    END IF;
    RETURN CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 ELSE 3.00 END;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR(1), p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: %', p_weight;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
    -- unit_rate and total_value are populated by the trigger
END;
$$;

CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE);
CALL pr_receive_delivery(1, 'B', 150, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE);
CALL pr_receive_delivery(2, 'A',  80, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'B', 120, CURRENT_DATE);
CALL pr_receive_delivery(3, 'C',  90, CURRENT_DATE - 1);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := NEW.weight_kg * NEW.unit_rate;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();
-- Fires for direct SQL inserts/updates too, so pricing is always consistent.

-- (e) View 
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- (f) Index 
-- Supports: a farmer's deliveries between two dates.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN ANALYZE
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- Justification: farmer_id is an equality filter and delivered_on a range
-- filter; the composite index with farmer_id first supports an index range
-- scan for per-farmer delivery history.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_weight NUMERIC(14,2);
    v_value  NUMERIC(14,2);
BEGIN
    SELECT COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
    INTO v_weight, v_value
    FROM deliveries WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule('refresh_purchases_daily', '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
