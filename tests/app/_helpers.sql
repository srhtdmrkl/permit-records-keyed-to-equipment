-- Loaded before every app test, after the schema. Not a test itself.

CREATE FUNCTION expect_error(stmt TEXT, fragment TEXT) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        IF position(fragment IN SQLERRM) = 0 THEN
            RAISE EXCEPTION 'expected an error containing "%", got "%"', fragment, SQLERRM;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'expected an error containing "%", but it succeeded: %', fragment, stmt;
END $$;

CREATE FUNCTION expect_eq(got TEXT, want TEXT, what TEXT) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF got IS DISTINCT FROM want THEN
        RAISE EXCEPTION '%: expected "%", got "%"', what, want, got;
    END IF;
END $$;

-- The article's case, without any records.
INSERT INTO assets (tag, description) VALUES ('P-101', 'Condensate pump A'), ('P-102', 'Condensate pump B');
INSERT INTO assets (tag, description, parent_asset_id)
SELECT 'PSV-12', 'Relief valve on P-101', asset_id FROM assets WHERE tag = 'P-101';

-- Shorthand for a time on the test day.
CREATE FUNCTION t(hhmm TEXT) RETURNS TIMESTAMPTZ
LANGUAGE sql IMMUTABLE AS $$ SELECT ('2026-09-22 ' || hhmm || ':00+00')::timestamptz $$;
