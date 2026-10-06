-- Article: "One pump, two permits".
-- The 21:40 start request on P-101.

SET ROLE permit_app;

-- Search by permit, as the paper rack did: PTW-114 shows only the isolation.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM open_conditions WHERE permit_id = 'PTW-114';
    IF n <> 1 THEN
        RAISE EXCEPTION 'by permit: expected 1 open condition on PTW-114, got %', n;
    END IF;
END $$;

-- Rule 1 broken: records keyed to the pump's own tag only miss the valve.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
    FROM open_conditions oc JOIN assets a USING (asset_id)
    WHERE a.tag = 'P-101';
    IF n <> 1 THEN
        RAISE EXCEPTION 'pump tag only: expected 1 open condition, got %', n;
    END IF;
END $$;

-- Rule 1 kept: search by equipment, including what belongs to it.
DO $$
DECLARE got text;
BEGIN
    SELECT string_agg(tag || ':' || event_type || ':' || permit_id, ', ' ORDER BY device_timestamp)
      INTO got
      FROM open_conditions_on('P-101');
    IF got IS DISTINCT FROM 'P-101:isolated:PTW-114, PSV-12:psv_removed:PTW-117' THEN
        RAISE EXCEPTION 'by equipment: expected isolation and missing relief valve, got %', got;
    END IF;
END $$;

-- The unrelated pump never leaks into the check.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM open_conditions_on('P-101') WHERE tag = 'P-102') THEN
        RAISE EXCEPTION 'P-102 appeared in the check on P-101';
    END IF;
END $$;

RESET ROLE;
