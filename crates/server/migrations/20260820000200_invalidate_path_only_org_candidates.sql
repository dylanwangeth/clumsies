-- Candidates created before path-only Organization Draft targets were
-- canonicalized may have reconciled against a different resource after a
-- rename or path reuse. Invalidate those cached projections so both server
-- and daemon callers must rebuild them with stable resource identity.
WITH invalidated_drafts AS (
    UPDATE draft_reconciliation_candidates AS candidate
    SET invalidated_at = now()
    FROM drafts AS draft
    WHERE candidate.draft_id = draft.draft_id
      AND candidate.invalidated_at IS NULL
      AND draft.resource_scope = 'org'
      AND draft.status IN ('open', 'submitted')
      AND draft.target_id IS NULL
      AND draft.path IS NOT NULL
      AND NOT COALESCE((
            SELECT operation.action = 'create'
            FROM draft_operations AS operation
            WHERE operation.draft_id = draft.draft_id
            ORDER BY operation.ordinal
            LIMIT 1
      ), FALSE)
    RETURNING draft.draft_id
)
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
    'evt_path_identity_refresh_' || md5('20260820000200:' || draft.draft_id),
    draft.draft_id,
    draft.project_id,
    'updated',
    draft.version,
    NULL,
    now()
FROM drafts AS draft
JOIN (SELECT DISTINCT draft_id FROM invalidated_drafts) AS invalidated
  ON invalidated.draft_id = draft.draft_id
ON CONFLICT (event_id) DO NOTHING;
