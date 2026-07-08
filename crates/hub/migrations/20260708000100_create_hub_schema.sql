CREATE TABLE orgs (
    org_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
    user_id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    display_name TEXT,
    role TEXT NOT NULL,
    google_subject TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE projects (
    project_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE project_members (
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('member', 'admin')),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, user_id)
);

CREATE TABLE resources (
    resource_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow')),
    path TEXT NOT NULL,
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'deprecated', 'archived')),
    revision BIGINT NOT NULL DEFAULT 1,
    content_hash TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    context_kind TEXT CHECK (context_kind IN ('file', 'note', 'decision', 'reference')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((scope = 'org' AND project_id IS NULL) OR (scope = 'project' AND project_id IS NOT NULL))
);

CREATE UNIQUE INDEX resources_org_path_idx
    ON resources(org_id, resource_kind, path)
    WHERE scope = 'org' AND status = 'active';

CREATE UNIQUE INDEX resources_project_path_idx
    ON resources(project_id, resource_kind, path)
    WHERE scope = 'project' AND status = 'active';

CREATE TABLE workflow_steps (
    resource_id TEXT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    step_order INTEGER NOT NULL,
    rule_id TEXT REFERENCES resources(resource_id) ON DELETE SET NULL,
    body TEXT,
    PRIMARY KEY (resource_id, step_order)
);

CREATE TABLE metaprompts (
    metaprompt_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
    status TEXT NOT NULL CHECK (status IN ('active', 'deprecated', 'archived')),
    revision BIGINT NOT NULL DEFAULT 1,
    content_hash TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((scope = 'org' AND project_id IS NULL) OR (scope = 'project' AND project_id IS NOT NULL))
);

CREATE UNIQUE INDEX metaprompts_org_singleton_idx
    ON metaprompts(org_id)
    WHERE scope = 'org';

CREATE UNIQUE INDEX metaprompts_project_singleton_idx
    ON metaprompts(project_id)
    WHERE scope = 'project';

CREATE TABLE project_org_resource_selections (
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    resource_id TEXT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, resource_id)
);

CREATE TABLE personal_bundles (
    bundle_id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    revision BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE personal_bundle_items (
    bundle_id TEXT NOT NULL REFERENCES personal_bundles(bundle_id) ON DELETE CASCADE,
    resource_id TEXT NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow')),
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bundle_id, resource_id)
);

CREATE TABLE drafts (
    draft_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    author_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow', 'metaprompt')),
    target_id TEXT,
    path TEXT,
    status TEXT NOT NULL CHECK (status IN ('open', 'submitted', 'discarded', 'conflicted')),
    version BIGINT NOT NULL DEFAULT 1,
    daemon_installation_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE draft_operations (
    operation_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    action TEXT NOT NULL CHECK (action IN ('create', 'update', 'rename', 'delete')),
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow', 'metaprompt')),
    target_id TEXT,
    path TEXT,
    base_hash TEXT,
    new_path TEXT,
    body TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE draft_events (
    server_sequence BIGSERIAL NOT NULL UNIQUE,
    event_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    event_type TEXT NOT NULL CHECK (event_type IN ('created', 'updated', 'operation_appended', 'discarded', 'submitted', 'conflicted')),
    version BIGINT NOT NULL,
    daemon_installation_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE reviews (
    review_id TEXT PRIMARY KEY,
    draft_id TEXT NOT NULL UNIQUE REFERENCES drafts(draft_id) ON DELETE RESTRICT,
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    author_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('open', 'approved', 'rejected', 'merged')),
    version BIGINT NOT NULL DEFAULT 1,
    decision_body TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE review_comments (
    comment_id TEXT PRIMARY KEY,
    review_id TEXT NOT NULL REFERENCES reviews(review_id) ON DELETE CASCADE,
    author_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE review_merges (
    merge_id TEXT PRIMARY KEY,
    review_id TEXT NOT NULL UNIQUE REFERENCES reviews(review_id) ON DELETE RESTRICT,
    snapshot_id TEXT,
    applied_operation_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE snapshots (
    snapshot_id TEXT PRIMARY KEY,
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    version BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((scope = 'org' AND project_id IS NULL) OR (scope = 'project' AND project_id IS NOT NULL))
);

CREATE TABLE snapshot_items (
    snapshot_id TEXT NOT NULL REFERENCES snapshots(snapshot_id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow', 'metaprompt', 'project_org_selection')),
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project', 'daemon')),
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    path TEXT,
    content_hash TEXT,
    content TEXT,
    source TEXT NOT NULL CHECK (source IN ('org', 'project', 'selected_org', 'bootstrap', 'config')),
    PRIMARY KEY (snapshot_id, item_id)
);
