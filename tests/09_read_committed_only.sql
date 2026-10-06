-- Article: "Building the chain". The chain trigger refuses inserts under
-- REPEATABLE READ and SERIALIZABLE. There, its SELECT could miss a row committed
-- while it waited for the lock, and two rows would point at the same predecessor.

BEGIN ISOLATION LEVEL REPEATABLE READ;
DO $$
BEGIN
    INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp)
    SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:50:00+00'
    FROM assets WHERE tag = 'P-101';
    RAISE EXCEPTION 'insert under REPEATABLE READ was accepted';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events inserts must run under READ COMMITTED' THEN RAISE; END IF;
END $$;
COMMIT;

BEGIN ISOLATION LEVEL SERIALIZABLE;
DO $$
BEGIN
    INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp)
    SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:50:00+00'
    FROM assets WHERE tag = 'P-101';
    RAISE EXCEPTION 'insert under SERIALIZABLE was accepted';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events inserts must run under READ COMMITTED' THEN RAISE; END IF;
END $$;
COMMIT;

-- READ COMMITTED, the PostgreSQL default, is accepted and the chain stays intact.
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp)
SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:50:00+00'
FROM assets WHERE tag = 'P-101';
COMMIT;

DO $$
BEGIN
    IF (SELECT count(*) FROM asset_events WHERE event_type = 'gas_test') <> 1 THEN
        RAISE EXCEPTION 'expected only the READ COMMITTED insert to be kept';
    END IF;
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken after READ COMMITTED insert';
    END IF;
END $$;
