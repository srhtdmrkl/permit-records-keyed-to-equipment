-- The equipment list.
-- In production this mirrors the maintenance system (CMMS) and is refreshed from it
-- when a permit is issued or a start is requested, not on a schedule. It is not owned here.
-- Tags must match the CMMS exactly; free-text equipment names break the link.

CREATE TABLE assets (
    asset_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tag              VARCHAR(50) NOT NULL UNIQUE,      -- 'P-101', 'PSV-12'; must match the maintenance system
    parent_asset_id  UUID REFERENCES assets(asset_id)  -- PSV-12 points to P-101
);

CREATE INDEX ON assets (parent_asset_id);

-- If one valve protects several pieces of equipment, replace parent_asset_id
-- with a link table. A single parent cannot represent that.
