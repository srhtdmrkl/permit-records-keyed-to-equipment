-- Article: "Making the log append-only in the database".

-- The application role has no UPDATE, DELETE or TRUNCATE privilege.
SET ROLE permit_app;

DO $$
BEGIN
    UPDATE asset_events SET reason = 'edited';
    RAISE EXCEPTION 'permit_app was allowed to UPDATE';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;

DO $$
BEGIN
    DELETE FROM asset_events;
    RAISE EXCEPTION 'permit_app was allowed to DELETE';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;

DO $$
BEGIN
    TRUNCATE asset_events;
    RAISE EXCEPTION 'permit_app was allowed to TRUNCATE';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;

RESET ROLE;

-- A role that does hold the privilege (here, the superuser running the tests)
-- is stopped by the triggers.
DO $$
BEGIN
    UPDATE asset_events SET reason = 'edited';
    RAISE EXCEPTION 'superuser UPDATE was not blocked';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events is append-only' THEN RAISE; END IF;
END $$;

DO $$
BEGIN
    DELETE FROM asset_events;
    RAISE EXCEPTION 'superuser DELETE was not blocked';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events is append-only' THEN RAISE; END IF;
END $$;

DO $$
BEGIN
    TRUNCATE asset_events;
    RAISE EXCEPTION 'superuser TRUNCATE was not blocked';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events is append-only' THEN RAISE; END IF;
END $$;

-- session_replication_role = 'replica' does not switch the triggers off (ENABLE ALWAYS).
SET session_replication_role = replica;

DO $$
BEGIN
    UPDATE asset_events SET reason = 'edited';
    RAISE EXCEPTION 'replica-mode UPDATE was not blocked';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'asset_events is append-only' THEN RAISE; END IF;
END $$;

-- An insert in replica mode is still numbered and chained by the trigger.
INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp)
SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:40:00+00'
FROM assets WHERE tag = 'P-101';

RESET session_replication_role;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken after an insert in replica mode';
    END IF;
END $$;

-- Nor can it redirect the trigger to its own temporary sequence or table to choose
-- ingest_seq or prev_hash. Temporary objects are found first unless the trigger fixes search_path.
SET ROLE permit_app;
CREATE TEMP SEQUENCE asset_events_seq START 900;
CREATE TEMP TABLE asset_events (event_hash bytea, ingest_seq bigint);
INSERT INTO pg_temp.asset_events VALUES ('\x01'::bytea, 1000000);

INSERT INTO public.asset_events (asset_id, event_type, recorded_by, device_timestamp)
SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:45:00+00'
FROM public.assets WHERE tag = 'P-101';

DROP TABLE pg_temp.asset_events;
DROP SEQUENCE pg_temp.asset_events_seq;
RESET ROLE;

DO $$
BEGIN
    IF (SELECT max(ingest_seq) FROM asset_events) >= 900 THEN
        RAISE EXCEPTION 'a temporary sequence chose ingest_seq';
    END IF;
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'a temporary table chose prev_hash';
    END IF;
END $$;

-- The application cannot forge the server-side fields: the trigger overwrites them.
SET ROLE permit_app;

INSERT INTO asset_events (asset_id, event_type, recorded_by, device_timestamp,
                          server_ingest_ts, ingest_seq, event_hash)
SELECT asset_id, 'gas_test', 'Technician C', TIMESTAMPTZ '2026-09-22 10:50:00+00',
       TIMESTAMPTZ '2000-01-01 00:00:00+00', 999999, '\x00'::bytea
FROM assets WHERE tag = 'P-101';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM asset_events
               WHERE server_ingest_ts < TIMESTAMPTZ '2001-01-01'
                  OR ingest_seq = 999999
                  OR event_hash = '\x00'::bytea) THEN
        RAISE EXCEPTION 'client-supplied server fields were kept';
    END IF;
    IF EXISTS (SELECT 1 FROM chain_breaks) THEN
        RAISE EXCEPTION 'chain broken after insert with forged fields';
    END IF;
END $$;

RESET ROLE;
