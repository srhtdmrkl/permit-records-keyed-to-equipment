-- Article: "A 'latest event per asset' view does not answer this question."
-- A gas test on P-101 recorded after its isolation becomes the latest event,
-- and the view hides the isolation that is still open.

SET ROLE permit_app;

INSERT INTO asset_events (asset_id, permit_id, event_type, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-114', 'gas_test', 'Gas test: 0% LEL', 'Technician C', TIMESTAMPTZ '2026-09-22 10:00:00+00'
FROM assets WHERE tag = 'P-101';

RESET ROLE;

DO $$
DECLARE latest text;
BEGIN
    WITH latest_per_asset AS (
        SELECT DISTINCT ON (asset_id) asset_id, event_type
        FROM asset_events
        ORDER BY asset_id, device_timestamp DESC, ingest_seq DESC
    )
    SELECT l.event_type INTO latest
    FROM latest_per_asset l JOIN assets a USING (asset_id)
    WHERE a.tag = 'P-101';

    IF latest IS DISTINCT FROM 'gas_test' THEN
        RAISE EXCEPTION 'expected the latest event on P-101 to be the gas test, got %', latest;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM open_conditions oc JOIN assets a USING (asset_id)
                   WHERE a.tag = 'P-101' AND oc.event_type = 'isolated') THEN
        RAISE EXCEPTION 'expected the isolation on P-101 to be still open';
    END IF;
END $$;
