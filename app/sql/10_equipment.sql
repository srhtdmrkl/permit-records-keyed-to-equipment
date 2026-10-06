-- Equipment details, and links the core schema cannot hold.
-- The equipment list is a copy of the maintenance system (CMMS). Whoever syncs
-- it edits it; permit users only read it. It is not append-only.

ALTER TABLE assets
    ADD COLUMN description TEXT,
    ADD COLUMN location    TEXT;

-- A relief valve on a shared header protects more than one pump.
-- parent_asset_id holds one owner; this table holds any others.
CREATE TABLE asset_links (
    asset_id    UUID NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
    belongs_to  UUID NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
    PRIMARY KEY (asset_id, belongs_to),
    CHECK (asset_id <> belongs_to)
);

CREATE VIEW asset_edges AS
SELECT asset_id AS child, parent_asset_id AS parent FROM assets WHERE parent_asset_id IS NOT NULL
UNION
SELECT asset_id, belongs_to FROM asset_links;

-- The equipment a check on one asset must cover: the asset itself,
-- everything that belongs to it, and everything it belongs to.
-- UNION (not UNION ALL) stops the recursion if the links ever form a loop.
CREATE FUNCTION asset_scope(root UUID)
RETURNS TABLE (asset_id UUID, relation TEXT)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE
    down(id) AS (
        SELECT root
        UNION
        SELECT e.child FROM asset_edges e JOIN down d ON e.parent = d.id
    ),
    up(id) AS (
        SELECT root
        UNION
        SELECT e.parent FROM asset_edges e JOIN up u ON e.child = u.id
    )
    SELECT root, 'self'::text
    UNION
    SELECT id, 'belongs to it' FROM down WHERE id <> root
    UNION
    SELECT id, 'it belongs to' FROM up WHERE id <> root;
$$;

-- Refuse a link that would make a piece of equipment belong to itself.
CREATE FUNCTION reject_asset_loop() RETURNS trigger
LANGUAGE plpgsql
-- Fixed search_path: a session cannot swap in its own temporary sequence or table.
SET search_path = public, pg_temp
AS $$
DECLARE
    -- One function for both tables; read the owner column by name.
    owner UUID := (to_jsonb(NEW) ->> CASE TG_TABLE_NAME WHEN 'assets' THEN 'parent_asset_id' ELSE 'belongs_to' END)::uuid;
BEGIN
    IF owner IS NOT NULL AND EXISTS (
        SELECT 1 FROM asset_scope(NEW.asset_id) s
        WHERE s.asset_id = owner AND s.relation IN ('self', 'belongs to it')
    ) THEN
        RAISE EXCEPTION 'That link would make the equipment belong to itself.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER no_loop BEFORE INSERT OR UPDATE ON assets
FOR EACH ROW EXECUTE FUNCTION reject_asset_loop();

CREATE TRIGGER no_loop BEFORE INSERT OR UPDATE ON asset_links
FOR EACH ROW EXECUTE FUNCTION reject_asset_loop();

GRANT SELECT ON asset_links, asset_edges TO permit_app;
