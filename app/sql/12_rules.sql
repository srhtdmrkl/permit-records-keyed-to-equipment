-- Permit rules, enforced by the database on every insert.
-- The application cannot skip them: a data fix, a bulk import and the app
-- all go through the same trigger.

-- Hot work may restart after a suspension only when the latest gas test since
-- the suspension reads at or below this percentage of the lower explosive limit.
-- Set it to your site's rule.
CREATE FUNCTION hot_work_lel_limit() RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$ SELECT 0::numeric $$;

-- A permit's status, worked out from its records. Nothing is overwritten.
CREATE VIEW permits AS
SELECT i.permit_id,
       a.tag,
       i.asset_id,
       i.event_id                   AS issue_event_id,
       i.detail->>'work'            AS work,
       i.detail->>'permit_type'     AS permit_type,
       i.detail->'cross_referenced' AS cross_referenced,
       i.recorded_by                AS issued_by,
       i.device_timestamp           AS issued_at,
       CASE WHEN c.event_id IS NOT NULL         THEN 'Closed'
            WHEN s.event_type = 'permit_suspended' THEN 'Suspended'
            ELSE 'Active' END       AS status,
       s.device_timestamp           AS status_since,
       c.device_timestamp           AS closed_at
FROM asset_events i
JOIN assets a USING (asset_id)
LEFT JOIN asset_events c ON c.closes_event_id = i.event_id
LEFT JOIN LATERAL (
    SELECT l.event_type, l.device_timestamp
    FROM asset_events l
    WHERE l.permit_id = i.permit_id
      AND l.event_type IN ('permit_suspended', 'permit_revalidated')
    ORDER BY l.ingest_seq DESC
    LIMIT 1
) s ON true
WHERE i.event_type = 'permit_issued';

-- One open condition, with where it sits relative to the equipment asked about.
CREATE TYPE scope_condition AS (
    event_id         UUID,
    asset_id         UUID,
    tag              VARCHAR,
    relation         TEXT,
    event_type       VARCHAR,
    kind             VARCHAR,
    label            TEXT,
    permit_id        VARCHAR,
    blocks_release   BOOLEAN,
    reason           TEXT,
    detail           JSONB,
    recorded_by      VARCHAR,
    device_timestamp TIMESTAMPTZ
);

-- Everything open on one piece of equipment, what belongs to it, and what it belongs to.
CREATE FUNCTION conditions_in_scope(root UUID)
RETURNS SETOF scope_condition
LANGUAGE sql STABLE AS $$
    SELECT oc.event_id, oc.asset_id, a.tag, s.relation, oc.event_type, ct.kind, coalesce(ct.open_label, ct.label),
           oc.permit_id, ct.blocks_release, oc.reason, oc.detail, oc.recorded_by, oc.device_timestamp
    FROM asset_scope(root) s
    JOIN open_conditions oc ON oc.asset_id = s.asset_id
    JOIN assets a           ON a.asset_id = oc.asset_id
    JOIN condition_types ct ON ct.event_type = oc.event_type
    ORDER BY oc.device_timestamp, oc.ingest_seq;
$$;

-- What stops this isolation being released.
CREATE FUNCTION release_blockers(isolation_event UUID)
RETURNS SETOF scope_condition
LANGUAGE sql STABLE AS $$
    SELECT c.*
    FROM asset_events i
    CROSS JOIN LATERAL conditions_in_scope(i.asset_id) c
    WHERE i.event_id = isolation_event
      AND c.blocks_release;
$$;

-- What was open at a past moment. as_known = false: by when it happened.
-- as_known = true: by when the server received it, i.e. what the system knew.
CREATE FUNCTION open_conditions_at(as_of TIMESTAMPTZ, as_known BOOLEAN DEFAULT false)
RETURNS SETOF asset_events
LANGUAGE sql STABLE AS $$
    SELECT o.*
    FROM asset_events o
    WHERE o.opens_condition
      AND CASE WHEN as_known THEN o.server_ingest_ts ELSE o.device_timestamp END <= as_of
      AND NOT EXISTS (
            SELECT 1 FROM asset_events c
            WHERE c.closes_event_id = o.event_id
              AND CASE WHEN as_known THEN c.server_ingest_ts ELSE c.device_timestamp END <= as_of
      );
$$;

CREATE FUNCTION apply_permit_rules() RETURNS trigger
LANGUAGE plpgsql
-- Fixed search_path: a session cannot swap in its own temporary sequence or table.
SET search_path = public, pg_temp
AS $$
DECLARE
    ct       condition_types;
    issue    asset_events;
    target   asset_events;
    last_lc  asset_events;
    state    TEXT;
    refs     TEXT[];
    given    TEXT[];
    missing  TEXT;
    blockers JSONB;
    lel      NUMERIC;
BEGIN
    -- The checks below read the state after the lock, which only works under
    -- READ COMMITTED. The chain trigger refuses other levels too; refusing here
    -- first avoids a rule error based on a stale snapshot.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'asset_events inserts must run under READ COMMITTED';
    END IF;
    -- The chain trigger takes the same lock. Taking it here first means two
    -- inserts cannot both pass a check against the same state.
    PERFORM pg_advisory_xact_lock(hashtext('asset_events_chain'));

    SELECT * INTO ct FROM condition_types WHERE event_type = NEW.event_type;
    IF ct.event_type IS NULL THEN
        RAISE EXCEPTION 'Unknown record type: %.', NEW.event_type;
    END IF;
    -- The catalogue decides what opens a condition, not the client.
    NEW.opens_condition := ct.opens;

    IF NEW.device_timestamp > clock_timestamp() + interval '5 minutes' THEN
        RAISE EXCEPTION 'The time of this record is in the future.';
    END IF;
    NEW.permit_id := nullif(btrim(NEW.permit_id), '');
    IF NEW.permit_id IS NULL THEN
        RAISE EXCEPTION 'Every record needs a permit number.';
    END IF;

    SELECT * INTO issue FROM asset_events
    WHERE permit_id = NEW.permit_id AND event_type = 'permit_issued';

    -- ── Issuing a permit ───────────────────────────────
    IF NEW.event_type = 'permit_issued' THEN
        IF issue.event_id IS NOT NULL THEN
            RAISE EXCEPTION 'Permit % already exists.', NEW.permit_id;
        END IF;
        IF coalesce(btrim(NEW.detail->>'work'), '') = '' THEN
            RAISE EXCEPTION 'Describe the work on the permit.';
        END IF;
        -- Every permit with something open on this equipment, what belongs to it,
        -- or what it belongs to must be cross-referenced by the issuer.
        SELECT coalesce(array_agg(DISTINCT c.permit_id ORDER BY c.permit_id), '{}')
          INTO refs
          FROM conditions_in_scope(NEW.asset_id) c;
        SELECT coalesce(array_agg(x), '{}')
          INTO given
          FROM jsonb_array_elements_text(coalesce(NEW.detail->'cross_referenced', '[]'::jsonb)) x;
        SELECT string_agg(r, ', ' ORDER BY r) INTO missing
          FROM unnest(refs) r WHERE r <> ALL (given);
        IF missing IS NOT NULL THEN
            RAISE EXCEPTION 'Cross-reference required. Open on this equipment: %.', missing;
        END IF;
        -- Store what was actually open, not what the client claimed.
        NEW.detail := NEW.detail || jsonb_build_object('cross_referenced', to_jsonb(refs));
        RETURN NEW;
    END IF;

    IF issue.event_id IS NULL THEN
        RAISE EXCEPTION 'Permit % has not been issued.', NEW.permit_id;
    END IF;
    IF NEW.device_timestamp < issue.device_timestamp THEN
        RAISE EXCEPTION 'This record is dated before permit % was issued.', NEW.permit_id;
    END IF;

    SELECT status INTO state FROM permits WHERE permit_id = NEW.permit_id;

    -- Releasing an isolation is an act on the equipment. It may happen after
    -- the permit that placed it is closed. The release check below covers it.
    IF NEW.event_type <> 'isolation_released' THEN
        IF state = 'Closed' THEN
            RAISE EXCEPTION 'Permit % is closed.', NEW.permit_id;
        END IF;
        IF state = 'Suspended' AND NEW.event_type NOT IN ('permit_revalidated', 'permit_closed', 'gas_test') THEN
            RAISE EXCEPTION 'Permit % is suspended. Revalidate it before recording work under it.', NEW.permit_id;
        END IF;
    END IF;

    -- ── Permit status changes ──────────────────────────
    IF ct.kind = 'permit' THEN
        IF NEW.asset_id <> issue.asset_id THEN
            RAISE EXCEPTION 'Record changes to permit % against its own equipment.', NEW.permit_id;
        END IF;
        SELECT * INTO last_lc FROM asset_events
        WHERE permit_id = NEW.permit_id
          AND event_type IN ('permit_issued', 'permit_suspended', 'permit_revalidated')
        ORDER BY ingest_seq DESC LIMIT 1;
        IF NEW.device_timestamp < last_lc.device_timestamp THEN
            RAISE EXCEPTION 'This record is dated before the permit''s last change.';
        END IF;
    END IF;

    IF NEW.event_type = 'permit_suspended' THEN
        IF state <> 'Active' THEN
            RAISE EXCEPTION 'Only an active permit can be suspended. Permit % is %.', NEW.permit_id, lower(state);
        END IF;
        IF coalesce(btrim(NEW.reason), '') = '' THEN
            RAISE EXCEPTION 'Give the reason for the suspension.';
        END IF;
    END IF;

    IF NEW.event_type = 'permit_revalidated' THEN
        IF state <> 'Suspended' THEN
            RAISE EXCEPTION 'Only a suspended permit can be revalidated. Permit % is %.', NEW.permit_id, lower(state);
        END IF;
        IF issue.detail->>'permit_type' = 'hot_work' THEN
            SELECT (g.detail->>'lel_percent')::numeric INTO lel
            FROM asset_events g
            WHERE g.permit_id = NEW.permit_id
              AND g.event_type = 'gas_test'
              AND g.device_timestamp >= last_lc.device_timestamp
              AND g.device_timestamp <= NEW.device_timestamp
            ORDER BY g.device_timestamp DESC, g.ingest_seq DESC
            LIMIT 1;
            IF lel IS NULL THEN
                RAISE EXCEPTION 'Hot work: record a gas test taken after the suspension before revalidating.';
            END IF;
            IF lel > hot_work_lel_limit() THEN
                RAISE EXCEPTION '%', format(
                    'Hot work: the latest gas test reads %s%% of the lower explosive limit. The limit is %s%%.',
                    lel, hot_work_lel_limit());
            END IF;
        END IF;
    END IF;

    IF NEW.event_type = 'permit_closed' THEN
        SELECT string_agg(coalesce(t.open_label, t.label) || ' on ' || a.tag, '; ' ORDER BY oc.device_timestamp) INTO missing
        FROM open_conditions oc
        JOIN condition_types t ON t.event_type = oc.event_type
        JOIN assets a          ON a.asset_id = oc.asset_id
        WHERE oc.permit_id = NEW.permit_id AND t.kind = 'protection';
        IF missing IS NOT NULL THEN
            RAISE EXCEPTION 'Permit % still has protections removed: %. Reinstate them before closing.', NEW.permit_id, missing;
        END IF;
        NEW.closes_event_id := issue.event_id;
        RETURN NEW;
    END IF;

    -- ── Removing a protection ──────────────────────────
    IF ct.kind = 'protection' AND ct.opens THEN
        SELECT oc.permit_id INTO missing FROM open_conditions oc
        WHERE oc.asset_id = NEW.asset_id AND oc.event_type = NEW.event_type
        LIMIT 1;
        IF missing IS NOT NULL THEN
            RAISE EXCEPTION '% is already recorded on this equipment under permit %.', ct.label, missing;
        END IF;
    END IF;

    -- ── Closing a condition ────────────────────────────
    IF ct.closes IS NOT NULL THEN
        SELECT * INTO target FROM asset_events WHERE event_id = NEW.closes_event_id;
        IF target.event_id IS NULL THEN
            RAISE EXCEPTION 'Choose the open record that this closes.';
        END IF;
        IF target.event_type <> ct.closes THEN
            RAISE EXCEPTION '"%" cannot close a "%" record.', ct.label,
                (SELECT label FROM condition_types WHERE event_type = target.event_type);
        END IF;
        IF target.asset_id <> NEW.asset_id THEN
            RAISE EXCEPTION 'That record is on different equipment.';
        END IF;
        IF EXISTS (SELECT 1 FROM asset_events c WHERE c.closes_event_id = target.event_id) THEN
            RAISE EXCEPTION 'That record is already closed.';
        END IF;
        IF NEW.device_timestamp < target.device_timestamp THEN
            RAISE EXCEPTION 'This record is dated before the record it closes.';
        END IF;
    ELSIF NEW.closes_event_id IS NOT NULL THEN
        RAISE EXCEPTION '"%" does not close anything.', ct.label;
    END IF;

    -- ── Releasing an isolation ─────────────────────────
    IF NEW.event_type = 'isolation_released' THEN
        SELECT jsonb_agg(jsonb_build_object('tag', b.tag, 'condition', b.label, 'permit', b.permit_id)
                         ORDER BY b.device_timestamp),
               string_agg(b.label || ' on ' || b.tag || ' (' || b.permit_id || ')', '; ' ORDER BY b.device_timestamp)
          INTO blockers, missing
          FROM release_blockers(target.event_id) b;
        IF blockers IS NOT NULL THEN
            IF coalesce(NEW.detail->>'override', '') <> 'true' THEN
                RAISE EXCEPTION 'Release blocked. Still open: %.', missing;
            END IF;
            IF length(coalesce(btrim(NEW.reason), '')) < 10 THEN
                RAISE EXCEPTION 'An override needs a reason of at least 10 characters.';
            END IF;
            -- The record names what was overridden, worked out here, not by the client.
            NEW.detail := NEW.detail || jsonb_build_object('override', true, 'overridden', blockers);
        ELSE
            NEW.detail := NEW.detail - 'override' - 'overridden';
        END IF;
    END IF;

    -- ── Gas test ───────────────────────────────────────
    IF NEW.event_type = 'gas_test' THEN
        BEGIN
            lel := (NEW.detail->>'lel_percent')::numeric;
        EXCEPTION WHEN others THEN
            lel := NULL;
        END;
        IF lel IS NULL OR lel < 0 OR lel > 100 THEN
            RAISE EXCEPTION 'Enter the gas reading as a percentage of the lower explosive limit, 0 to 100.';
        END IF;
    END IF;

    RETURN NEW;
END $$;

-- BEFORE triggers fire in name order. This one must run before
-- chain_before_insert, because the hash covers the detail it writes.
CREATE TRIGGER a_permit_rules
BEFORE INSERT ON asset_events
FOR EACH ROW EXECUTE FUNCTION apply_permit_rules();

-- Like the core triggers, the rules fire even under session_replication_role = 'replica'.
ALTER TABLE asset_events ENABLE ALWAYS TRIGGER a_permit_rules;

-- The one way the application writes. Looks the equipment up by tag, so a
-- record cannot point at equipment that is not in the list. For permit status
-- changes the tag may be left out: the permit's own equipment is used.
CREATE FUNCTION record(
    p_tag     TEXT,
    p_permit  TEXT,
    p_type    TEXT,
    p_when    TIMESTAMPTZ,
    p_by      TEXT,
    p_reason  TEXT  DEFAULT NULL,
    p_detail  JSONB DEFAULT '{}',
    p_closes  UUID  DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
-- Fixed search_path: a session cannot swap in its own temporary sequence or table.
SET search_path = public, pg_temp
AS $$
DECLARE
    a  UUID;
    id UUID;
BEGIN
    IF coalesce(btrim(p_by), '') = '' THEN
        RAISE EXCEPTION 'Enter who is recording this.';
    END IF;
    IF p_tag IS NULL THEN
        SELECT asset_id INTO a FROM permits WHERE permit_id = btrim(p_permit);
    ELSE
        SELECT asset_id INTO a FROM assets WHERE tag = p_tag;
        IF a IS NULL THEN
            RAISE EXCEPTION 'No equipment tagged % in the equipment list.', p_tag;
        END IF;
    END IF;
    IF a IS NULL THEN
        RAISE EXCEPTION 'Permit % has not been issued.', p_permit;
    END IF;
    IF p_when IS NULL THEN
        RAISE EXCEPTION 'Enter when this happened.';
    END IF;

    INSERT INTO asset_events (asset_id, permit_id, event_type, closes_event_id,
                              detail, reason, recorded_by, device_timestamp)
    VALUES (a, p_permit, p_type, p_closes,
            coalesce(p_detail, '{}'), nullif(btrim(p_reason), ''), btrim(p_by), p_when)
    RETURNING event_id INTO id;
    RETURN id;
END $$;

GRANT SELECT ON permits TO permit_app;
