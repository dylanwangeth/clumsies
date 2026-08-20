ALTER TABLE draft_operations
    ADD COLUMN ordinal BIGINT;

-- Freeze the ordering used by existing deployments before making it part of
-- the write contract. operation_id is retained only as the legacy tie-breaker
-- for rows that share PostgreSQL's transaction timestamp.
WITH ranked_operations AS (
    SELECT
        operation_id,
        ROW_NUMBER() OVER (
            PARTITION BY draft_id
            ORDER BY created_at, operation_id
        ) AS ordinal
    FROM draft_operations
)
UPDATE draft_operations AS operation
SET ordinal = ranked.ordinal
FROM ranked_operations AS ranked
WHERE ranked.operation_id = operation.operation_id;

ALTER TABLE draft_operations
    ALTER COLUMN ordinal SET NOT NULL,
    ADD CONSTRAINT draft_operations_ordinal_positive CHECK (ordinal > 0),
    ADD CONSTRAINT draft_operations_draft_ordinal_unique UNIQUE (draft_id, ordinal);

-- Existing daemon projections may have consumed operations in the legacy
-- tie-break order. Wake every active Draft so it reloads the now-canonical
-- ordinal projection without changing the Draft's content version.
INSERT INTO draft_events (
    event_id,
    draft_id,
    project_id,
    event_type,
    version,
    daemon_installation_id,
    created_at
)
SELECT
    'evt_projection_refresh_' || md5('20260820000100:' || draft.draft_id),
    draft.draft_id,
    draft.project_id,
    'updated',
    draft.version,
    NULL,
    now()
FROM drafts AS draft
WHERE draft.status IN ('open', 'submitted')
ON CONFLICT (event_id) DO NOTHING;
