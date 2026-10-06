-- Article: "State at a past moment". The two versions of the question
-- give different answers when an event was recorded offline and synced late.
-- Both questions are asked the article's way: P-101 and its equipment, under any permit.

SET ROLE permit_app;

-- Recorded and synced live at 11:00.
INSERT INTO asset_events (asset_id, permit_id, event_type, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-117', 'gas_test', 'Gas retest: 0% LEL', 'Technician C',
       TIMESTAMPTZ '2026-09-23 11:00:00+00'
FROM assets WHERE tag = 'PSV-12';

RESET ROLE;

-- The moment the system had received the 11:00 event.
CREATE TEMP TABLE cutoff AS
SELECT server_ingest_ts AS cutoff_ts FROM asset_events WHERE device_timestamp = TIMESTAMPTZ '2026-09-23 11:00:00+00';

-- The sync happens later. Without a pause, two inserts can share a server
-- timestamp (PGlite's clock ticks in milliseconds). ingest_seq never ties.
SELECT pg_sleep(0.01);

SET ROLE permit_app;

-- Recorded offline at 10:15, synced afterwards. It arrives after the 11:00 event.
INSERT INTO asset_events (asset_id, permit_id, event_type, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-117', 'permit_suspended', 'Gas alarm', 'Safety Officer B',
       TIMESTAMPTZ '2026-09-23 10:15:00+00'
FROM assets WHERE tag = 'PSV-12';

RESET ROLE;

-- P-101 and the equipment that belongs to it, as in the article's queries.
CREATE TEMP TABLE tree AS
WITH RECURSIVE tree AS (
    SELECT asset_id, tag FROM assets WHERE tag = 'P-101'
    UNION ALL
    SELECT a.asset_id, a.tag
    FROM assets a
    JOIN tree t ON a.parent_asset_id = t.asset_id
)
SELECT * FROM tree;

DO $$
DECLARE t             timestamptz := (SELECT cutoff_ts FROM cutoff);
        offline_seq   bigint;
        live_seq      bigint;
        permits       text;
BEGIN
    SELECT ingest_seq INTO live_seq    FROM asset_events WHERE device_timestamp = TIMESTAMPTZ '2026-09-23 11:00:00+00';
    SELECT ingest_seq INTO offline_seq FROM asset_events WHERE device_timestamp = TIMESTAMPTZ '2026-09-23 10:15:00+00';

    -- Arrival order is not the order things happened.
    IF offline_seq < live_seq THEN
        RAISE EXCEPTION 'expected the offline event to arrive after the live one';
    END IF;

    -- What the system knew at that moment: the offline suspension had not arrived.
    IF EXISTS (SELECT 1 FROM asset_events e JOIN tree USING (asset_id)
               WHERE e.server_ingest_ts <= t
                 AND e.device_timestamp = TIMESTAMPTZ '2026-09-23 10:15:00+00') THEN
        RAISE EXCEPTION 'system-knew query included an event not yet received';
    END IF;

    -- What had happened by 10:15: the suspension, with a sync gap showing it came in late.
    IF NOT EXISTS (SELECT 1 FROM asset_events e JOIN tree USING (asset_id)
                   WHERE e.device_timestamp <= TIMESTAMPTZ '2026-09-23 10:15:00+00'
                     AND e.event_type = 'permit_suspended'
                     AND e.server_ingest_ts - e.device_timestamp > interval '0') THEN
        RAISE EXCEPTION 'had-happened query missed the late-synced suspension';
    END IF;

    -- Under any permit: the pump's isolation (PTW-114) and the valve's records (PTW-117).
    SELECT string_agg(DISTINCT e.permit_id, ', ' ORDER BY e.permit_id) INTO permits
    FROM asset_events e JOIN tree USING (asset_id)
    WHERE e.device_timestamp <= TIMESTAMPTZ '2026-09-23 10:15:00+00';
    IF permits IS DISTINCT FROM 'PTW-114, PTW-117' THEN
        RAISE EXCEPTION 'had-happened query: expected PTW-114 and PTW-117, got %', permits;
    END IF;
END $$;
