-- Article: Rule 2. "A removed barrier stays open until something closes it."

SET ROLE permit_app;

-- A suspension does not close the removal; it opens nothing and closes nothing.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM open_conditions_on('P-101') WHERE event_type = 'psv_removed') THEN
        RAISE EXCEPTION 'suspension closed the relief valve condition';
    END IF;
END $$;

-- "Relief valve refitted and tested" closes it by pointing at the removal event.
INSERT INTO asset_events (asset_id, permit_id, event_type, closes_event_id, reason, recorded_by, device_timestamp)
SELECT r.asset_id, 'PTW-117', 'psv_refitted', r.event_id,
       'Relief valve refitted and tested', 'Technician C', TIMESTAMPTZ '2026-09-23 09:00:00+00'
FROM asset_events r
WHERE r.event_type = 'psv_removed';

DO $$
DECLARE got text;
BEGIN
    SELECT string_agg(tag || ':' || event_type, ', ') INTO got FROM open_conditions_on('P-101');
    IF got IS DISTINCT FROM 'P-101:isolated' THEN
        RAISE EXCEPTION 'after refit: expected only the isolation open, got %', got;
    END IF;
END $$;

-- The removal row is still there. Closing it added a row; it changed nothing.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM asset_events WHERE event_type IN ('psv_removed', 'psv_refitted');
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected removal and refit both kept, got % rows', n;
    END IF;
END $$;

RESET ROLE;
