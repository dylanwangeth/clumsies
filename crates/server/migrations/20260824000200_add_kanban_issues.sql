CREATE TABLE kanban_issues (
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    issue_id TEXT NOT NULL,
    issue_number BIGINT NOT NULL CHECK (issue_number BETWEEN 1 AND 999),
    assignee_user_id TEXT NOT NULL,
    content_revision BIGINT NOT NULL CHECK (content_revision > 0),
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, issue_id),
    UNIQUE (project_id, issue_number),
    FOREIGN KEY (project_id, assignee_user_id)
        REFERENCES project_members(project_id, user_id) ON DELETE RESTRICT
);

-- Claims are short-lived execution leases and cannot be reconstructed into
-- durable Issue snapshots during this one-time authority migration.
DELETE FROM issue_claims;

ALTER TABLE issue_claims
    ADD CONSTRAINT issue_claims_issue_fk
    FOREIGN KEY (project_id, issue_id)
    REFERENCES kanban_issues(project_id, issue_id) ON DELETE CASCADE;

CREATE INDEX kanban_issues_by_project_number
    ON kanban_issues (project_id, issue_number);
