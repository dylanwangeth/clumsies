CREATE UNIQUE INDEX projects_org_name_ci_idx
    ON projects (org_id, lower(name));

CREATE TABLE project_creation_requests (
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    idempotency_key TEXT NOT NULL,
    project_id TEXT NOT NULL
        REFERENCES projects(project_id) ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED,
    request_name TEXT NOT NULL,
    request_description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (org_id, user_id, idempotency_key)
);
