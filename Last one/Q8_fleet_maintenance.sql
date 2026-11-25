
-- ICT371 - Question 8: Transport Fleet Maintenance


-- (a) Tables and seed data
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id           SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      NUMERIC(10,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(10,2) NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE NOT NULL,
    start_odometer  NUMERIC(10,2) NOT NULL,
    end_odometer    NUMERIC(10,2) NOT NULL
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(10,2) NOT NULL,
    flagged_on       DATE NOT NULL
);

-- three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ABC 1234', 12000, 11000),  -- 1000 km since service: not due
('DEF 5678', 20000, 14000),  -- 6000 km since service: due
('GHI 9012', 5000,  5000);   -- just serviced: not due

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_current NUMERIC;
    v_last    NUMERIC;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
    -- vehicle odometer is updated by the trigger, not here
END;
$$;

CALL pr_record_trip(1, CURRENT_DATE,     12000, 12200);
CALL pr_record_trip(1, CURRENT_DATE + 1, 12200, 12450);
CALL pr_record_trip(2, CURRENT_DATE,     20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE + 1, 20300, 20550);
CALL pr_record_trip(3, CURRENT_DATE,     5000,  5120);
CALL pr_record_trip(3, CURRENT_DATE + 1, 5120,  5260);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
    v_current NUMERIC;
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'start_odometer (%) must match vehicle current_odometer (%)',
            NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (e) View 
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;

-- (f) Index 
-- Supports: one vehicle's trips within a trip_on date range.
CREATE INDEX idx_trips_vehicle_tripdate ON trips (vehicle_id, trip_on);

EXPLAIN ANALYZE
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
-- Justification: vehicle_id is filtered by equality and trip_on by range;
-- the composite index with vehicle_id leading supports an efficient index
-- range scan for per-vehicle trip-history queries.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert or update an alert for every vehicle currently due
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service, flagged_on = EXCLUDED.flagged_on;

    -- remove alerts for vehicles that are no longer due (e.g. after service)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000
    );
END;
$$;

SELECT cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
    $$CALL pr_refresh_service_alerts()$$);
