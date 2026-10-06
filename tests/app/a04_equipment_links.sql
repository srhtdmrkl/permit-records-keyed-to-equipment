-- A relief valve on a shared header belongs to two pumps. Removing it blocks
-- a release on either. The equipment list cannot form a loop.

INSERT INTO assets (tag, description) VALUES ('PSV-30', 'Relief valve on shared discharge header');
INSERT INTO asset_links (asset_id, belongs_to)
SELECT v.asset_id, p.asset_id FROM assets v, assets p
WHERE v.tag = 'PSV-30' AND p.tag IN ('P-101', 'P-102');

SET ROLE permit_app;

SELECT record('P-102',  'PTW-120', 'permit_issued', t('08:00'), 'A', NULL, '{"work": "Seal change"}');
SELECT record('P-102',  'PTW-120', 'isolated',      t('08:05'), 'A');
SELECT record(NULL,     'PTW-120', 'permit_closed', t('08:30'), 'A');
SELECT record('PSV-30', 'PTW-121', 'permit_issued', t('09:00'), 'A', NULL, '{"work": "Header valve test", "cross_referenced": ["PTW-120"]}');
SELECT record('PSV-30', 'PTW-121', 'psv_removed',   t('09:10'), 'A');

DO $$
DECLARE iso UUID := (SELECT event_id FROM asset_events WHERE event_type = 'isolated');
BEGIN
    PERFORM expect_error(
        format($q$ SELECT record('P-102', 'PTW-120', 'isolation_released', t('10:00'), 'A', NULL, '{}', %L) $q$, iso),
        'Relief valve removed on PSV-30');
END $$;

-- The same valve shows on P-101's screen too.
SELECT expect_eq(
    (SELECT string_agg(tag || ':' || relation || ':' || event_type, ', ' ORDER BY device_timestamp)
     FROM conditions_in_scope((SELECT asset_id FROM assets WHERE tag = 'P-101'))),
    'PSV-30:belongs to it:permit_issued, PSV-30:belongs to it:psv_removed', 'P-101 sees the shared valve');

RESET ROLE;

-- Loops are refused, through either kind of link.
SELECT expect_error($q$ UPDATE assets SET parent_asset_id = (SELECT asset_id FROM assets WHERE tag = 'PSV-12') WHERE tag = 'P-101' $q$,
                    'belong to itself');
SELECT expect_error($q$ INSERT INTO asset_links SELECT p.asset_id, v.asset_id FROM assets p, assets v WHERE p.tag = 'P-101' AND v.tag = 'PSV-30' $q$,
                    'belong to itself');
