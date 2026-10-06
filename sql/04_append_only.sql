-- Make the log append-only in the database, not only in the application.

-- Roles are cluster-wide in PostgreSQL, so create them only if missing.
-- permit_app is NOLOGIN here because the tests and the browser pages switch to it
-- with SET ROLE. In production it is the role the application logs in as: create it with LOGIN.
DO $$
BEGIN
    CREATE ROLE ledger_owner NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE ROLE permit_app NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- The table and sequence belong to a role nobody logs in as
ALTER TABLE asset_events OWNER TO ledger_owner;
ALTER SEQUENCE asset_events_seq OWNER TO ledger_owner;

-- The application can add and read, nothing else
GRANT SELECT, INSERT ON asset_events TO permit_app;
GRANT USAGE ON SEQUENCE asset_events_seq TO permit_app;
GRANT SELECT ON assets TO permit_app;
GRANT SELECT ON chain_breaks TO permit_app;

-- Reject edits and deletes even from roles that hold the privilege
CREATE FUNCTION reject_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'asset_events is append-only';
END $$;

CREATE TRIGGER no_update_delete
BEFORE UPDATE OR DELETE ON asset_events
FOR EACH ROW EXECUTE FUNCTION reject_change();

-- TRUNCATE skips row triggers, so block it separately
CREATE TRIGGER no_truncate
BEFORE TRUNCATE ON asset_events
FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

-- Ensure triggers fire even if a session sets session_replication_role = 'replica'
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER chain_before_insert;
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_update_delete;
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER no_truncate;

-- A superuser, or anyone who can act as ledger_owner, can still disable these triggers.
-- That is why the hash chain and its outside copies exist.
-- With logical replication these triggers also fire on the subscriber and
-- recompute the sequence numbers, timestamps and hashes there.
