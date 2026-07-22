-- Commit-rewriting migrations update canonical Draft bases in PostgreSQL. Emit
-- one durable event so existing daemon installations refresh stale projections.
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
    'evt_projection_refresh_' || md5('20260722000400:' || draft.draft_id),
    draft.draft_id,
    draft.project_id,
    'updated',
    draft.version,
    NULL,
    now()
FROM drafts AS draft
WHERE draft.status IN ('open', 'submitted', 'conflicted')
  AND draft.base_commit_id IS NOT NULL
ON CONFLICT (event_id) DO NOTHING;
