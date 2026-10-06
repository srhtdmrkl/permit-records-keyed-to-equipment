-- Article: "Fixed column list, so adding a column later does not change old hashes."
-- A routine migration leaves the chain intact, and new rows still chain after it.

ALTER TABLE asset_events ADD COLUMN site VARCHAR(20);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'adding a column broke the chain';
    END IF;
END $$;

SET ROLE permit_app;

INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp, site)
SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:50:00+00', 'Platform'
FROM assets WHERE tag = 'P-101';

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken by an insert after the migration';
    END IF;
END $$;
