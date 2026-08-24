CREATE TABLE issue_claims (
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    issue_id TEXT NOT NULL,
    issue_key TEXT NOT NULL,
    claimant_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, issue_id)
);

CREATE INDEX issue_claims_active_by_project
    ON issue_claims (project_id, lease_expires_at DESC);
