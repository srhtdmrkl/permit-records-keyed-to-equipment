-- A suspended hot work permit revalidates only after a clean gas test taken
-- since the suspension. Suspended permits take no work.

INSERT INTO assets (tag) VALUES ('T-205');

SET ROLE permit_app;

SELECT record('T-205', 'PTW-130', 'permit_issued', t('07:50'), 'Supervisor A', NULL,
              '{"work": "Weld repair", "permit_type": "hot_work"}');
SELECT record('T-205', 'PTW-130', 'gas_test', t('07:55'), 'Technician C', NULL, '{"lel_percent": 0}');

SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_revalidated', t('08:00'), 'A') $q$, 'Only a suspended permit');
SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_suspended', t('10:15'), 'B') $q$, 'reason for the suspension');
SELECT record(NULL, 'PTW-130', 'permit_suspended', t('10:15'), 'Safety Officer B', 'Gas alarm');
SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_suspended', t('10:20'), 'B', 'again') $q$, 'is suspended');

-- The 07:55 test was before the suspension. It does not count.
SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_revalidated', t('10:30'), 'A') $q$, 'record a gas test taken after the suspension');

-- Work under a suspended permit is refused.
SELECT expect_error($q$ SELECT record('T-205', 'PTW-130', 'guard_removed', t('10:30'), 'A') $q$, 'is suspended');

-- A bad reading is accepted as a record, and blocks the restart.
SELECT expect_error($q$ SELECT record('T-205', 'PTW-130', 'gas_test', t('10:40'), 'C', NULL, '{"lel_percent": "lots"}') $q$, '0 to 100');
SELECT record('T-205', 'PTW-130', 'gas_test', t('10:40'), 'Technician C', NULL, '{"lel_percent": 4}');
SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_revalidated', t('10:45'), 'A') $q$, 'reads 4% of the lower explosive limit');

SELECT record('T-205', 'PTW-130', 'gas_test', t('10:50'), 'Technician C', NULL, '{"lel_percent": 0}');
-- Revalidating dated before the clean test is still refused.
SELECT expect_error($q$ SELECT record(NULL, 'PTW-130', 'permit_revalidated', t('10:48'), 'A') $q$, 'reads 4%');
SELECT record(NULL, 'PTW-130', 'permit_revalidated', t('11:00'), 'Supervisor A', 'Retest clear');

SELECT expect_eq((SELECT status FROM permits WHERE permit_id = 'PTW-130'), 'Active', 'PTW-130 status');
-- The whole morning is on file.
SELECT expect_eq((SELECT count(*)::text FROM asset_events WHERE permit_id = 'PTW-130'), '6', 'PTW-130 records kept');

RESET ROLE;
