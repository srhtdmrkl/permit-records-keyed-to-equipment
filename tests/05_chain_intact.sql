-- Article: "Building the chain". An untouched log checks clean,
-- including rows added in one multi-row INSERT.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken after seed';
    END IF;
END $$;

-- The first row has no predecessor; every later row points at the one before.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM asset_events WHERE prev_hash IS NULL;
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly one row without prev_hash, got %', n;
    END IF;
END $$;

SET ROLE permit_app;

INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp)
SELECT asset_id, 'gas_test', 'Technician C', ts
FROM assets,
     (VALUES (TIMESTAMPTZ '2026-09-22 10:00:00+00'),
             (TIMESTAMPTZ '2026-09-22 10:05:00+00'),
             (TIMESTAMPTZ '2026-09-22 10:10:00+00')) v(ts)
WHERE tag = 'P-101';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken after multi-row insert';
    END IF;
END $$;

RESET ROLE;

-- The hash does not depend on the session's time zone or bytea output format.
SET timezone = 'America/Sao_Paulo';
SET bytea_output = 'escape';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain check depends on session settings';
    END IF;
END $$;

RESET timezone;
RESET bytea_output;
