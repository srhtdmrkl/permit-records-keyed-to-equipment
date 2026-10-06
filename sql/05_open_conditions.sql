-- What is wrong with this equipment right now: every condition opened and not yet closed.

CREATE VIEW open_conditions AS
SELECT o.*
FROM asset_events o
WHERE o.opens_condition
  AND NOT EXISTS (
        SELECT 1 FROM asset_events c
        WHERE c.closes_event_id = o.event_id
  );

-- Everything open on one piece of equipment and the equipment that belongs to it.
-- Same query as the article, with the tag as a parameter.
CREATE FUNCTION open_conditions_on(root_tag TEXT)
RETURNS TABLE (
    tag              VARCHAR,
    event_type       VARCHAR,
    permit_id        VARCHAR,
    recorded_by      VARCHAR,
    device_timestamp TIMESTAMPTZ,
    server_ingest_ts TIMESTAMPTZ
)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE tree AS (
        SELECT asset_id FROM assets WHERE tag = root_tag
        UNION ALL
        SELECT a.asset_id
        FROM assets a
        JOIN tree t ON a.parent_asset_id = t.asset_id
    )
    SELECT a.tag, oc.event_type, oc.permit_id, oc.recorded_by,
           oc.device_timestamp, oc.server_ingest_ts
    FROM open_conditions oc
    JOIN tree USING (asset_id)
    JOIN assets a USING (asset_id)
    ORDER BY oc.device_timestamp;
$$;

GRANT SELECT ON open_conditions TO permit_app;
GRANT EXECUTE ON FUNCTION open_conditions_on(TEXT) TO permit_app;
