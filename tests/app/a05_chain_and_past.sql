-- The rules write into detail before the hash is taken, so the chain still
-- checks clean. The state at a past moment ignores later closures.

-- The rules refuse inserts under REPEATABLE READ, before any rule reads a stale snapshot.
-- First in the file: PGlite runs it as one batch, where an isolation level must come first.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT expect_error($q$ SELECT record('P-101', 'PTW-114', 'gas_test', t('16:00'), 'C', NULL, '{"lel_percent": 0}') $q$,
                    'must run under READ COMMITTED');
COMMIT;

SET ROLE permit_app;

SELECT record('P-101', 'PTW-114', 'permit_issued', t('08:00'), 'A', NULL, '{"work": "Overhaul"}');
SELECT record('P-101', 'PTW-114', 'isolated',      t('08:10'), 'A');
SELECT record('PSV-12','PTW-117', 'permit_issued', t('09:20'), 'A', NULL, '{"work": "Valve", "cross_referenced": ["PTW-114"]}');
SELECT record('PSV-12','PTW-117', 'psv_removed',   t('09:30'), 'C');
DO $$
BEGIN
    PERFORM record('PSV-12', 'PTW-117', 'psv_refitted', t('15:00'), 'C', NULL, '{}',
                   (SELECT event_id FROM asset_events WHERE event_type = 'psv_removed'));
END $$;

SELECT expect_eq((SELECT count(*)::text FROM chain_breaks), '0', 'chain intact');

SELECT expect_eq((SELECT count(*)::text FROM open_conditions_at(t('12:00')) WHERE event_type = 'psv_removed'), '1', 'valve off at 12:00');
SELECT expect_eq((SELECT count(*)::text FROM open_conditions_at(t('16:00')) WHERE event_type = 'psv_removed'), '0', 'valve back at 16:00');
-- The test day is in the past, but the server received everything just now:
-- at 12:00 on the test day the system knew nothing.
SELECT expect_eq((SELECT count(*)::text FROM open_conditions_at(t('12:00'), true)), '0', 'system knew nothing then');

RESET ROLE;

-- The rules fire even when a session sets session_replication_role = 'replica'.
SET session_replication_role = replica;
SELECT expect_error($q$ SELECT record('P-101', 'PTW-999', 'isolated', t('12:00'), 'A') $q$, 'has not been issued');
RESET session_replication_role;

-- The rules layer does not weaken append-only.
SET ROLE permit_app;
SELECT expect_error($q$ UPDATE asset_events SET reason = 'x' $q$, 'permission denied');
RESET ROLE;
SELECT expect_error($q$ DELETE FROM asset_events $q$, 'append-only');
