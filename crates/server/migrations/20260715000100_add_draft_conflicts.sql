CREATE TABLE draft_conflicts (
    draft_id TEXT PRIMARY KEY REFERENCES drafts(draft_id) ON DELETE CASCADE,
    base_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    current_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
