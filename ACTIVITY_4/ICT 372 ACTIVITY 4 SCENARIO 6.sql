-- ICT371 PostgreSQL Scenario Assignment
-- Scenario 6: University Event Seat Booking
-- Student number: 202301541

DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS events;

-- 1. Tables and sample data
CREATE TABLE events (
    event_id        SERIAL PRIMARY KEY,
    event_name      VARCHAR(60) NOT NULL,
    available_seats INT NOT NULL CHECK (available_seats >= 0)
);

CREATE TABLE bookings (
    booking_id     SERIAL PRIMARY KEY,
    event_id       INT NOT NULL REFERENCES events(event_id),
    student_number VARCHAR(20) NOT NULL,
    seats          INT NOT NULL,
    status         VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
);

INSERT INTO events (event_name, available_seats) VALUES
    ('Career Fair', 100),
    ('Tech Talk', 5),
    ('Graduation Gala', 0);

SELECT * FROM events ORDER BY event_id;

-- 2. IF / ELSIF / ELSE event status
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT event_name, available_seats FROM events ORDER BY event_id LOOP
        IF r.available_seats = 0 THEN
            RAISE NOTICE '% : FULL', r.event_name;
        ELSIF r.available_seats <= 10 THEN
            RAISE NOTICE '% : NEARLY FULL (%)', r.event_name, r.available_seats;
        ELSE
            RAISE NOTICE '% : PLENTY OF SEATS (%)', r.event_name, r.available_seats;
        END IF;
    END LOOP;
END $$;

-- 3. WHILE and numeric FOR
DO $$
DECLARE
    d INT := 1;
BEGIN
    WHILE d <= 3 LOOP
        RAISE NOTICE 'Booking reminder day: %', d;
        d := d + 1;
    END LOOP;

    FOR n IN 1..3 LOOP
        RAISE NOTICE 'Entrance check number: %', n;
    END LOOP;
END $$;

-- 4. book_seats procedure
CREATE OR REPLACE PROCEDURE book_seats(p_event_id INT, p_student VARCHAR, p_seats INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INT;
BEGIN
    IF p_seats IS NULL OR p_seats <= 0 THEN
        RAISE EXCEPTION 'Invalid number of seats: % (must be greater than zero)', p_seats;
    END IF;

    SELECT available_seats INTO v_available
    FROM events WHERE event_id = p_event_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event % does not exist', p_event_id;
    END IF;

    IF v_available < p_seats THEN
        RAISE NOTICE 'Booking REJECTED for %: requested % seat(s), only % left',
                     p_student, p_seats, v_available;
        RETURN;
    END IF;

    UPDATE events SET available_seats = available_seats - p_seats
    WHERE event_id = p_event_id;

    INSERT INTO bookings (event_id, student_number, seats)
    VALUES (p_event_id, p_student, p_seats);

    RAISE NOTICE 'Booking recorded for % : % seat(s) at event %', p_student, p_seats, p_event_id;
END $$;

-- 5. Two valid bookings and one exceeding the remaining seats
CALL book_seats(1, '202301541', 4);
CALL book_seats(2, '202301542', 3);
CALL book_seats(2, '202301543', 4);   -- only 2 seats left, not recorded

SELECT * FROM events ORDER BY event_id;
SELECT * FROM bookings ORDER BY booking_id;

-- 6. cancel_booking procedure
CREATE OR REPLACE PROCEDURE cancel_booking(p_booking_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_id INT;
    v_seats    INT;
    v_status   VARCHAR(10);
BEGIN
    SELECT event_id, seats, status INTO v_event_id, v_seats, v_status
    FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking % does not exist', p_booking_id;
    END IF;

    IF v_status = 'CANCELLED' THEN
        RAISE NOTICE 'Booking % already cancelled; no seats released', p_booking_id;
        RETURN;
    END IF;

    UPDATE events SET available_seats = available_seats + v_seats
    WHERE event_id = v_event_id;

    UPDATE bookings SET status = 'CANCELLED'
    WHERE booking_id = p_booking_id;

    RAISE NOTICE 'Booking % cancelled; % seat(s) released', p_booking_id, v_seats;
END $$;

CALL cancel_booking(1);
CALL cancel_booking(1);   -- second call must not release seats again

SELECT * FROM events ORDER BY event_id;
SELECT * FROM bookings ORDER BY booking_id;

-- 7. Explicit cursor: full or nearly full events
DO $$
DECLARE
    cur_full CURSOR FOR
        SELECT event_name, available_seats FROM events
        WHERE available_seats <= 10 ORDER BY available_seats;
    v_name  events.event_name%TYPE;
    v_seats events.available_seats%TYPE;
BEGIN
    OPEN cur_full;
    LOOP
        FETCH cur_full INTO v_name, v_seats;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Full or nearly full: % (% seat(s))', v_name, v_seats;
    END LOOP;
    CLOSE cur_full;
END $$;

-- 8. Zero seats handled with EXCEPTION block
DO $$
BEGIN
    CALL book_seats(1, '202301541', 0);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Error handled: %', SQLERRM;
END $$;

-- 9. Final state
SELECT * FROM events ORDER BY event_id;
SELECT * FROM bookings ORDER BY booking_id;