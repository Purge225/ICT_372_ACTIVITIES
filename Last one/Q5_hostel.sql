
-- ICT371 - Question 5: Hostel Room Allocation


-- (a) Tables and seed data 
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CHECK ( (status = 'ACTIVE' AND released_on IS NULL)
         OR (status = 'ENDED'  AND released_on IS NOT NULL) )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INTEGER NOT NULL DEFAULT 0,
    free_beds      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
('S3001','Faith Mwaba'), ('S3002','Davis Siame'), ('S3003','Ruth Mulenga'), ('S3004','Isaac Phiri');

INSERT INTO rooms (room_number, capacity) VALUES
('A101', 2),  -- will end up full
('A102', 3),  -- partly occupied
('A103', 2);  -- empty

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;  -- ENDED allocations are excluded, so they never reduce availability
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_free INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    v_free := fn_free_beds(p_room_id);  -- raises if unknown room
    IF v_free <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);   -- room A101 now full
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);   -- room A102 partly occupied
-- student 4 and room A103 deliberately left unallocated

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_allocation_guard() RETURNS TRIGGER AS $$
DECLARE
    v_capacity  INT;
    v_active    INT;
    v_other_act BOOLEAN;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id;

        SELECT COUNT(*) INTO v_active
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_active >= v_capacity THEN
            RAISE EXCEPTION 'Room % is at full capacity (%)', NEW.room_id, v_capacity;
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)
        ) INTO v_other_act;

        IF v_other_act THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocation_guard
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_guard();

-- (e) View 
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COALESCE(COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'), 0) AS occupied_beds,
       r.capacity - COALESCE(COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'), 0) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) Index 
-- Supports: ACTIVE allocations filtered by room_id.
CREATE INDEX idx_allocations_room_active ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN ANALYZE
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
-- Justification: capacity and clash checks repeatedly query "ACTIVE
-- allocations for this room"; a partial index on that predicate is smaller
-- than indexing every row and matches this hot-path query exactly.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule('refresh_occupancy_daily', '55 23 * * *',
    $$CALL pr_refresh_occupancy()$$);
