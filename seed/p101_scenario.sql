-- The article's illustrative case: pump P-101, its relief valve PSV-12, two permits.
-- Not a reconstruction of Piper Alpha's records.
-- P-102 is an unrelated pump with its own open condition; it must never
-- appear in a check on P-101.

INSERT INTO assets (tag) VALUES ('P-101'), ('P-102');
INSERT INTO assets (tag, parent_asset_id)
SELECT 'PSV-12', asset_id FROM assets WHERE tag = 'P-101';

-- Written as the application role, to prove it can do its job with INSERT alone.
SET ROLE permit_app;

INSERT INTO asset_events (asset_id, permit_id, event_type, opens_condition, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-114', 'isolated', true,
       'Overhaul permit issued; pump isolated', 'Supervisor A', TIMESTAMPTZ '2026-09-22 08:00:00+00'
FROM assets WHERE tag = 'P-101';

INSERT INTO asset_events (asset_id, permit_id, event_type, opens_condition, detail, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-117', 'psv_removed', true, '{"blind_flange_fitted": true}',
       'Relief valve removed for testing; blind flange fitted', 'Technician C', TIMESTAMPTZ '2026-09-22 09:30:00+00'
FROM assets WHERE tag = 'PSV-12';

INSERT INTO asset_events (asset_id, permit_id, event_type, opens_condition, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-120', 'isolated', true,
       'Seal replacement; pump isolated', 'Supervisor D', TIMESTAMPTZ '2026-09-22 12:00:00+00'
FROM assets WHERE tag = 'P-102';

INSERT INTO asset_events (asset_id, permit_id, event_type, opens_condition, reason, recorded_by, device_timestamp)
SELECT asset_id, 'PTW-117', 'permit_suspended', false,
       'Work not finished at end of shift', 'Technician C', TIMESTAMPTZ '2026-09-22 17:45:00+00'
FROM assets WHERE tag = 'PSV-12';

RESET ROLE;
