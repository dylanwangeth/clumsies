UPDATE drafts
SET status = 'submitted'
WHERE status = 'conflicted';

ALTER TABLE drafts DROP CONSTRAINT drafts_status_check;
ALTER TABLE drafts
    ADD CONSTRAINT drafts_status_check
    CHECK (status IN ('open', 'submitted', 'merged', 'discarded'));

UPDATE draft_events
SET event_type = 'updated'
WHERE event_type = 'conflicted';

ALTER TABLE draft_events DROP CONSTRAINT draft_events_event_type_check;
ALTER TABLE draft_events
    ADD CONSTRAINT draft_events_event_type_check
    CHECK (event_type IN (
        'created', 'updated', 'operation_appended', 'discarded',
        'submitted', 'reopened', 'rebased', 'merged'
    ));

DROP TABLE draft_conflicts;

ALTER TABLE reviews
    ADD COLUMN approved_result_hash TEXT;

CREATE TABLE draft_reconciliation_candidates (
    candidate_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    draft_version BIGINT NOT NULL,
    base_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    current_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('clean', 'conflicts')),
    base_state JSONB NOT NULL,
    current_state JSONB NOT NULL,
    draft_state JSONB NOT NULL,
    proposed_state JSONB,
    conflicts JSONB NOT NULL,
    result_hash TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    invalidated_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX draft_reconciliation_candidates_active_tuple_idx
    ON draft_reconciliation_candidates (
        draft_id,
        draft_version,
        COALESCE(base_commit_id, ''),
        COALESCE(current_commit_id, '')
    )
    WHERE invalidated_at IS NULL;

CREATE INDEX draft_reconciliation_candidates_draft_idx
    ON draft_reconciliation_candidates (draft_id, created_at DESC);

CREATE TABLE draft_revisions (
    revision_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    draft_version BIGINT NOT NULL,
    base_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    lifecycle_status TEXT NOT NULL CHECK (lifecycle_status IN ('open', 'submitted', 'merged', 'discarded')),
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    operations JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX draft_revisions_draft_idx
    ON draft_revisions (draft_id, created_at DESC);

CREATE TABLE draft_rebases (
    rebase_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    candidate_id TEXT NOT NULL REFERENCES draft_reconciliation_candidates(candidate_id) ON DELETE RESTRICT,
    previous_revision_id TEXT NOT NULL REFERENCES draft_revisions(revision_id) ON DELETE RESTRICT,
    applied_by_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    resulting_draft_version BIGINT NOT NULL,
    result_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX draft_rebases_draft_idx
    ON draft_rebases (draft_id, created_at DESC);
