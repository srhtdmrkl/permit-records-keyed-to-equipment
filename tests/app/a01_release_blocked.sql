-- The article's case through the permit rules: the 21:40 release on P-101
-- is blocked by the relief valve removed under another permit.

SET ROLE permit_app;

SELECT record('P-101', 'PTW-114', 'permit_issued', t('08:00'), 'Supervisor A', NULL, '{"work": "Pump overhaul"}');
SELECT record('P-101', 'PTW-114', 'isolated',      t('08:10'), 'Supervisor A', NULL, '{"method": "Valves locked closed"}');

-- The valve is on equipment that belongs to P-101, so the issuer must cross-reference PTW-114.
SELECT expect_error(
    $q$ SELECT record('PSV-12', 'PTW-117', 'permit_issued', t('09:20'), 'Supervisor A', NULL, '{"work": "Bench test valve"}') $q$,
    'Cross-reference required. Open on this equipment: PTW-114');

SELECT record('PSV-12', 'PTW-117', 'permit_issued', t('09:20'), 'Supervisor A', NULL,
              '{"work": "Bench test valve", "cross_referenced": ["PTW-114", "PTW-999"]}');
-- The stored list is what was open, not what the client sent.
SELECT expect_eq((SELECT cross_referenced::text FROM permits WHERE permit_id = 'PTW-117'), '["PTW-114"]', 'cross-reference list');

SELECT record('PSV-12', 'PTW-117', 'psv_removed',      t('09:30'), 'Technician C');
SELECT record(NULL,     'PTW-117', 'permit_suspended', t('17:45'), 'Technician C', 'Work not finished');

-- The night shift closes the overhaul permit; nothing was removed under it.
SELECT record(NULL, 'PTW-114', 'permit_closed', t('21:35'), 'Night supervisor');
SELECT expect_eq((SELECT status FROM permits WHERE permit_id = 'PTW-114'), 'Closed', 'PTW-114 status');
SELECT expect_eq((SELECT status FROM permits WHERE permit_id = 'PTW-117'), 'Suspended', 'PTW-117 status');

-- A session cannot unblock the release by swapping in its own catalogue or
-- open-conditions table. Temporary objects are found first unless the rules fix search_path.
CREATE TEMP TABLE condition_types AS
SELECT event_type, kind, label, open_label, opens, closes, false AS blocks_release FROM public.condition_types;
CREATE TEMP TABLE open_conditions AS SELECT * FROM public.asset_events WHERE false;
DO $$
BEGIN
    PERFORM expect_error(
        format($q$ SELECT record('P-101', 'PTW-114', 'isolation_released', t('21:40'), 'Night supervisor', NULL, '{}', %L) $q$,
               (SELECT event_id FROM public.asset_events WHERE event_type = 'isolated')),
        'Release blocked');
END $$;
DROP TABLE pg_temp.condition_types, pg_temp.open_conditions;

-- The release is refused, and the refusal names both blockers.
DO $$
DECLARE iso UUID := (SELECT event_id FROM asset_events WHERE event_type = 'isolated');
BEGIN
    PERFORM expect_error(
        format($q$ SELECT record('P-101', 'PTW-114', 'isolation_released', t('21:40'), 'Night supervisor', NULL, '{}', %L) $q$, iso),
        'Release blocked. Still open: Permit open on PSV-12 (PTW-117); Relief valve removed on PSV-12 (PTW-117)');
    -- An override without a real reason is refused.
    PERFORM expect_error(
        format($q$ SELECT record('P-101', 'PTW-114', 'isolation_released', t('21:40'), 'Night supervisor', 'ok', '{"override": true}', %L) $q$, iso),
        'An override needs a reason');
    -- An override with a reason goes through and names what it overrode.
    PERFORM record('P-101', 'PTW-114', 'isolation_released', t('21:40'), 'Night supervisor',
                   'Production pressure; supervisor accepts risk', '{"override": true}', iso);
END $$;

SELECT expect_eq(
    (SELECT detail->'overridden'->1->>'condition' FROM asset_events WHERE event_type = 'isolation_released'),
    'Relief valve removed', 'override names the removed valve');

-- The valve is still open: the override released the isolation, it did not refit anything.
SELECT expect_eq((SELECT count(*)::text FROM open_conditions WHERE event_type = 'psv_removed'), '1', 'valve still open');

-- P-102 never appeared in any of this.
SELECT expect_eq(
    (SELECT count(*)::text FROM conditions_in_scope((SELECT asset_id FROM assets WHERE tag = 'P-101')) WHERE tag = 'P-102'),
    '0', 'P-102 outside the scope');

RESET ROLE;
