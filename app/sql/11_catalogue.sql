-- What each kind of record does. The rules read this table, so adding a new
-- kind of removed protection is one row, not a code change.

CREATE TABLE condition_types (
    event_type      VARCHAR(50) PRIMARY KEY,
    kind            VARCHAR(20) NOT NULL CHECK (kind IN ('permit', 'isolation', 'protection', 'record')),
    label           TEXT NOT NULL,                                        -- the record, as it reads in a history
    open_label      TEXT,                                                 -- the open condition, if it reads differently
    opens           BOOLEAN NOT NULL DEFAULT false,                       -- leaves a condition open on the equipment
    closes          VARCHAR(50) REFERENCES condition_types(event_type),   -- the open condition it closes
    blocks_release  BOOLEAN NOT NULL DEFAULT false,                       -- while open, stops an isolation in scope being released
    CHECK (NOT (opens AND closes IS NOT NULL)),
    CHECK (opens OR NOT blocks_release)
);

-- Conditions that open first, so the closers below can point at them.
INSERT INTO condition_types (event_type, kind, label, opens, blocks_release, open_label) VALUES
    ('permit_issued',     'permit',     'Permit issued',                   true, true,  'Permit open'),
    ('isolated',          'isolation',  'Isolated',                        true, false, NULL),
    ('psv_removed',       'protection', 'Relief valve removed',            true, true,  NULL),
    ('trip_inhibited',    'protection', 'Trip or alarm inhibited',         true, true,  NULL),
    ('guard_removed',     'protection', 'Machine guard removed',           true, true,  NULL),
    ('detector_inhibited','protection', 'Gas or fire detector inhibited',  true, true,  NULL);

INSERT INTO condition_types (event_type, kind, label, closes) VALUES
    ('permit_closed',      'permit',     'Permit closed',                    'permit_issued'),
    ('isolation_released', 'isolation',  'Isolation released',               'isolated'),
    ('psv_refitted',       'protection', 'Relief valve refitted and tested', 'psv_removed'),
    ('trip_reinstated',    'protection', 'Trip or alarm reinstated',         'trip_inhibited'),
    ('guard_refitted',     'protection', 'Machine guard refitted',           'guard_removed'),
    ('detector_reinstated','protection', 'Detector reinstated',              'detector_inhibited');

INSERT INTO condition_types (event_type, kind, label) VALUES
    ('permit_suspended',   'permit', 'Permit suspended'),
    ('permit_revalidated', 'permit', 'Permit revalidated'),
    ('gas_test',           'record', 'Gas test');

-- Another isolation on the same pump does not block a release: one point
-- staying isolated is safer, not less safe. An open permit or a removed
-- protection does.

GRANT SELECT ON condition_types TO permit_app;
