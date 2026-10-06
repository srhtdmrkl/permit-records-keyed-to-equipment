-- Closures are checked on insert: right type, same equipment, not already
-- closed, not dated before what they close. A permit cannot close with a
-- protection still removed.

SET ROLE permit_app;

SELECT record('PSV-12', 'PTW-117', 'permit_issued', t('09:20'), 'Supervisor A', NULL, '{"work": "Bench test valve"}');
SELECT record('PSV-12', 'PTW-117', 'psv_removed',   t('09:30'), 'Technician C');
SELECT record('P-102',  'PTW-120', 'permit_issued', t('09:40'), 'Supervisor D', NULL, '{"work": "Seal change"}');
SELECT record('P-102',  'PTW-120', 'isolated',      t('09:45'), 'Supervisor D');

DO $$
DECLARE
    psv UUID := (SELECT event_id FROM asset_events WHERE event_type = 'psv_removed');
    iso UUID := (SELECT event_id FROM asset_events WHERE event_type = 'isolated');
BEGIN
    PERFORM expect_error(format($q$ SELECT record('PSV-12', 'PTW-117', 'guard_refitted', t('10:00'), 'C', NULL, '{}', %L) $q$, psv),
                         'cannot close');
    PERFORM expect_error(format($q$ SELECT record('P-102', 'PTW-120', 'psv_refitted', t('10:00'), 'C', NULL, '{}', %L) $q$, psv),
                         'different equipment');
    PERFORM expect_error(format($q$ SELECT record('PSV-12', 'PTW-117', 'psv_refitted', t('09:00'), 'C', NULL, '{}', %L) $q$, psv),
                         'dated before');
    PERFORM expect_error(format($q$ SELECT record('PSV-12', 'PTW-117', 'psv_refitted', t('10:00'), 'C', NULL, '{}', %L) $q$, iso),
                         'cannot close');
    PERFORM expect_error($q$ SELECT record('PSV-12', 'PTW-117', 'psv_refitted', t('10:00'), 'C') $q$,
                         'Choose the open record');
    PERFORM expect_error($q$ SELECT record('PSV-12', 'PTW-117', 'psv_removed', t('10:00'), 'C') $q$,
                         'already recorded');

    -- Closing the permit with the valve still off is refused.
    PERFORM expect_error($q$ SELECT record(NULL, 'PTW-117', 'permit_closed', t('10:00'), 'C') $q$,
                         'still has protections removed: Relief valve removed on PSV-12');

    PERFORM record('PSV-12', 'PTW-117', 'psv_refitted', t('11:00'), 'C', NULL, '{}', psv);
    PERFORM expect_error(format($q$ SELECT record('PSV-12', 'PTW-117', 'psv_refitted', t('11:05'), 'C', NULL, '{}', %L) $q$, psv),
                         'already closed');
    PERFORM record(NULL, 'PTW-117', 'permit_closed', t('11:10'), 'C');

    -- A closed permit takes no more work.
    PERFORM expect_error($q$ SELECT record('PSV-12', 'PTW-117', 'psv_removed', t('11:20'), 'C') $q$, 'is closed');
END $$;

-- Both the removal and the refit are still on file.
SELECT expect_eq((SELECT count(*)::text FROM asset_events WHERE permit_id = 'PTW-117'), '4', 'PTW-117 records kept');

-- Unknown types, future times and missing permits are refused.
SELECT expect_error($q$ SELECT record('P-101', 'PTW-200', 'valve_vibes', t('10:00'), 'C') $q$, 'Unknown record type');
SELECT expect_error($q$ SELECT record('P-101', 'PTW-201', 'isolated', t('10:00'), 'C') $q$, 'has not been issued');
SELECT expect_error($q$ SELECT record('P-101', 'PTW-202', 'permit_issued', now() + interval '1 day', 'C', NULL, '{"work": "x"}') $q$, 'in the future');
SELECT expect_error($q$ SELECT record('X-999', 'PTW-203', 'permit_issued', t('10:00'), 'C', NULL, '{"work": "x"}') $q$, 'No equipment tagged X-999');

-- The client cannot decide what opens a condition.
INSERT INTO asset_events (asset_id, permit_id, event_type, opens_condition, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-120', 'trip_inhibited', false, 'D', t('12:00') FROM assets WHERE tag = 'P-102';
SELECT expect_eq((SELECT opens_condition::text FROM asset_events WHERE event_type = 'trip_inhibited'), 'true', 'opens_condition from catalogue');

RESET ROLE;
