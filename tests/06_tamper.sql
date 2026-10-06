-- Article: "The chain alone does not stop someone with full database access."
-- Each block plays a privileged administrator who disables the triggers.

-- The outside copy: the latest hash, as sent in the shift report.
CREATE TEMP TABLE anchor AS
SELECT event_hash FROM asset_events ORDER BY ingest_seq DESC LIMIT 1;

-- 1. Edit an old row. The check flags that row.
ALTER TABLE asset_events DISABLE TRIGGER no_update_delete;
UPDATE asset_events SET reason = 'Valve inspected; left in place' WHERE event_type = 'psv_removed';
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_update_delete;

DO $$
DECLARE flagged bigint[];
        edited  bigint;
BEGIN
    SELECT ingest_seq INTO edited FROM asset_events WHERE event_type = 'psv_removed';
    SELECT array_agg(ingest_seq ORDER BY ingest_seq) INTO flagged FROM chain_breaks;
    IF flagged IS DISTINCT FROM ARRAY[edited] THEN
        RAISE EXCEPTION 'edit: expected only row % flagged, got %', edited, flagged;
    END IF;
END $$;

-- 2. Recompute every hash after the edit. The chain check now passes;
--    only the outside copy shows the log was changed.
ALTER TABLE asset_events DISABLE TRIGGER no_update_delete;
DO $$
DECLARE r    asset_events;
        prev bytea;
BEGIN
    FOR r IN SELECT * FROM asset_events ORDER BY ingest_seq LOOP
        r.prev_hash  := prev;
        r.event_hash := compute_event_hash(r);
        UPDATE asset_events
           SET prev_hash = r.prev_hash, event_hash = r.event_hash
         WHERE event_id = r.event_id;
        prev := r.event_hash;
    END LOOP;
END $$;
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_update_delete;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'recompute: expected the chain check to pass';
    END IF;
    IF (SELECT event_hash FROM asset_events ORDER BY ingest_seq DESC LIMIT 1)
       = (SELECT event_hash FROM anchor) THEN
        RAISE EXCEPTION 'recompute: latest hash still matches the outside copy';
    END IF;
END $$;
