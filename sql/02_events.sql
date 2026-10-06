-- The event log. Every change is a new row; no row is edited or deleted.

CREATE SEQUENCE asset_events_seq;

CREATE TABLE asset_events (
    event_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id          UUID NOT NULL REFERENCES assets(asset_id),
    permit_id         VARCHAR(50),
    event_type        VARCHAR(50) NOT NULL,  -- 'isolated', 'psv_removed', 'psv_refitted', 'permit_suspended', 'gas_test'
    opens_condition   BOOLEAN NOT NULL DEFAULT false,               -- true: this event leaves something open on the asset
    closes_event_id   UUID REFERENCES asset_events(event_id),       -- the event whose condition this one closes
    detail            JSONB NOT NULL DEFAULT '{}',
    reason            TEXT,
    recorded_by       VARCHAR(255) NOT NULL,
    device_timestamp  TIMESTAMPTZ NOT NULL,  -- when the worker's device says it happened
    server_ingest_ts  TIMESTAMPTZ NOT NULL,  -- when the server received it; set by trigger
    ingest_seq        BIGINT NOT NULL UNIQUE,-- arrival order; set by trigger
    prev_hash         BYTEA,
    event_hash        BYTEA NOT NULL
);

CREATE INDEX ON asset_events (asset_id) WHERE opens_condition;
CREATE UNIQUE INDEX ON asset_events (closes_event_id) WHERE closes_event_id IS NOT NULL;
CREATE INDEX ON asset_events (asset_id, device_timestamp);
CREATE INDEX ON asset_events (permit_id, ingest_seq);
