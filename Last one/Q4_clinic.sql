-- ICT371 - Question 4: Clinic Appointment Scheduling

-- (a) Tables and seed data
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id        INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE NOT NULL,
    slot_time        TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status           VARCHAR(10) NOT NULL CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES ('Charity Mumba'), ('Brian Lungu'), ('Esther Phiri');
INSERT INTO doctors  (full_name) VALUES ('Dr. Kunda'), ('Dr. Mbewe'), ('Dr. Nkonde');

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
    v_exists BOOLEAN;
    v_count  INT;
BEGIN
    SELECT EXISTS(SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) INTO v_exists;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN COALESCE(v_count, 0);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date: %', p_day;
    END IF;
    IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
    -- the clash check itself is enforced by the trigger below
END;
$$;

CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '09:00');

-- (d) Trigger 
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash() RETURNS TRIGGER AS $$
DECLARE
    v_clash BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR appointment_id <> NEW.appointment_id)
    ) INTO v_clash;

    IF v_clash AND NEW.status <> 'CANCELLED' THEN
        RAISE EXCEPTION 'Doctor % already has a non-cancelled appointment at % on %',
            NEW.doctor_id, NEW.slot_time, NEW.appointment_day;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- (e) View 
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) Index 
-- Supports: searches by appointment_day and doctor_id.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN ANALYZE
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
-- Justification: both columns are typically filtered together (a doctor's
-- schedule for a given day), so a composite index on (appointment_day,
-- doctor_id) directly supports the lookup used by booking and the clash check.

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_booked INT; v_attended INT; v_cancelled INT;
BEGIN
    SELECT COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date)
    DO UPDATE SET booked_count = EXCLUDED.booked_count,
                  attended_count = EXCLUDED.attended_count,
                  cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
