-- Hash chain: each row carries a fingerprint of its own contents
-- plus the previous row's fingerprint.

-- One function computes the hash, for both writing and checking.
-- Fixed column list, so adding a column later does not change old hashes.
-- Fixed timezone, so the JSON text is identical in every session.
CREATE FUNCTION compute_event_hash(e asset_events) RETURNS BYTEA
LANGUAGE plpgsql
SET timezone = 'UTC'
AS $$
BEGIN
    RETURN sha256(coalesce(e.prev_hash, ''::bytea) || convert_to(json_build_array(
        e.event_id, e.asset_id, e.permit_id, e.event_type, e.opens_condition,
        e.closes_event_id, e.detail, e.reason, e.recorded_by,
        e.device_timestamp, e.server_ingest_ts, e.ingest_seq
    )::text, 'UTF8'));
END $$;

CREATE FUNCTION chain_event() RETURNS trigger
LANGUAGE plpgsql
-- Fixed search_path: a session cannot swap in its own temporary sequence or table.
SET search_path = public, pg_temp
AS $$
BEGIN
    -- The lock only works if the SELECT below sees rows committed while we waited.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'asset_events inserts must run under READ COMMITTED';
    END IF;
    -- One writer at a time, so the chain stays a single line.
    -- Permit events arrive at human speed; serialising them is cheap.
    PERFORM pg_advisory_xact_lock(hashtext('asset_events_chain'));
    NEW.ingest_seq       := nextval('asset_events_seq');
    NEW.server_ingest_ts := clock_timestamp();
    SELECT event_hash INTO NEW.prev_hash
      FROM asset_events
     ORDER BY ingest_seq DESC
     LIMIT 1;
    NEW.event_hash := compute_event_hash(NEW);
    RETURN NEW;
END $$;

CREATE TRIGGER chain_before_insert
BEFORE INSERT ON asset_events
FOR EACH ROW EXECUTE FUNCTION chain_event();

-- Every row where the chain is broken. An empty result means intact.
CREATE VIEW chain_breaks AS
SELECT ingest_seq
FROM (
    SELECT e.ingest_seq,
           e.event_hash,
           e.prev_hash,
           compute_event_hash(e)                          AS recomputed,
           lag(e.event_hash) OVER (ORDER BY e.ingest_seq) AS expected_prev
    FROM asset_events e
) t
WHERE event_hash IS DISTINCT FROM recomputed
   OR prev_hash  IS DISTINCT FROM expected_prev;
