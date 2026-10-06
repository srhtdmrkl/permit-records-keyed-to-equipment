-- Deleting rows, as a privileged administrator with the triggers disabled.

CREATE TEMP TABLE anchor AS
SELECT event_hash FROM asset_events ORDER BY ingest_seq DESC LIMIT 1;

-- 1. Delete a row from the middle. The check flags the row after the gap.
CREATE TEMP TABLE gap AS
SELECT ingest_seq AS next_seq
FROM asset_events
WHERE ingest_seq > (SELECT ingest_seq FROM asset_events WHERE event_type = 'psv_removed')
ORDER BY ingest_seq
LIMIT 1;

ALTER TABLE asset_events DISABLE TRIGGER no_update_delete;
DELETE FROM asset_events WHERE event_type = 'psv_removed';
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_update_delete;

DO $$
DECLARE flagged bigint[];
BEGIN
    SELECT array_agg(ingest_seq ORDER BY ingest_seq) INTO flagged FROM chain_breaks;
    IF flagged IS DISTINCT FROM ARRAY[(SELECT next_seq FROM gap)] THEN
        RAISE EXCEPTION 'middle delete: expected only row % flagged, got %',
            (SELECT next_seq FROM gap), flagged;
    END IF;
END $$;

-- The relief valve condition has silently left the start check.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM open_conditions_on('P-101') WHERE event_type = 'psv_removed') THEN
        RAISE EXCEPTION 'expected the deleted removal to be gone from the start check';
    END IF;
END $$;

-- 2. Delete the newest row. Nothing follows it, so the chain check passes.
--    Only the outside copy catches it.
ALTER TABLE asset_events DISABLE TRIGGER no_update_delete;
DELETE FROM asset_events
WHERE ingest_seq = (SELECT max(ingest_seq) FROM asset_events);
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_update_delete;

DO $$
DECLARE flagged bigint[];
BEGIN
    SELECT array_agg(ingest_seq ORDER BY ingest_seq) INTO flagged FROM chain_breaks;
    IF flagged IS DISTINCT FROM ARRAY[(SELECT next_seq FROM gap)] THEN
        RAISE EXCEPTION 'tail delete: expected no new flags, got %', flagged;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM anchor a
                   WHERE NOT EXISTS (SELECT 1 FROM asset_events e WHERE e.event_hash = a.event_hash)) THEN
        RAISE EXCEPTION 'tail delete: the outside copy should no longer match any row';
    END IF;
END $$;
