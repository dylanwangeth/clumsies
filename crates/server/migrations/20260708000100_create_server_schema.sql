CREATE TABLE orgs (
    org_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    allowed_email_domains TEXT[] NOT NULL DEFAULT '{}',
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE refs (
    ref_id TEXT PRIMARY KEY,
    ref_name TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    project_id TEXT,
    commit_id TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((scope = 'org' AND project_id IS NULL) OR (scope = 'project' AND project_id IS NOT NULL))
);

CREATE TABLE users (
    user_id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    display_name TEXT,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    status TEXT NOT NULL CHECK (status IN ('invited', 'active', 'disabled')) DEFAULT 'invited',
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX users_email_lower_idx ON users (lower(email));

CREATE TABLE external_identities (
    external_identity_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    protocol TEXT NOT NULL CHECK (protocol IN ('oidc')),
    issuer TEXT NOT NULL,
    subject TEXT NOT NULL,
    email_at_binding TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (issuer, subject),
    UNIQUE (user_id, protocol, issuer)
);

CREATE TABLE oidc_login_transactions (
    transaction_id TEXT PRIMARY KEY,
    provider_state_hash TEXT NOT NULL UNIQUE,
    nonce TEXT NOT NULL,
    provider_pkce_verifier TEXT NOT NULL,
    client_kind TEXT NOT NULL CHECK (client_kind IN ('desktop', 'cli', 'web_admin')),
    client_redirect_uri TEXT NOT NULL,
    client_state TEXT,
    client_code_challenge TEXT NOT NULL,
    return_to TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE authorization_codes (
    code_id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE auth_sessions (
    session_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE access_tokens (
    token_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES auth_sessions(session_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh', 'integration')),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX access_tokens_session_idx ON access_tokens(session_id);

CREATE TABLE audit_events (
    event_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    actor_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
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

ALTER TABLE refs
    ADD CONSTRAINT refs_project_id_fkey
    FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE;

CREATE UNIQUE INDEX refs_org_name_idx
    ON refs(org_id, ref_name)
    WHERE scope = 'org';

CREATE UNIQUE INDEX refs_project_name_idx
    ON refs(project_id, ref_name)
    WHERE scope = 'project';

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

CREATE TABLE project_org_selection_states (
    project_id TEXT PRIMARY KEY REFERENCES projects(project_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

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
    resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow', 'metaprompt')),
    base_commit_id TEXT,
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
    resource_scope TEXT NOT NULL CHECK (resource_scope IN ('org', 'project')),
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
    event_type TEXT NOT NULL CHECK (event_type IN ('created', 'updated', 'operation_appended', 'discarded', 'submitted', 'reopened', 'conflicted')),
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
    commit_id TEXT,
    applied_operation_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE blobs (
    blob_id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE trees (
    tree_id TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE commits (
    commit_id TEXT PRIMARY KEY,
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project')),
    org_id TEXT NOT NULL REFERENCES orgs(org_id) ON DELETE CASCADE,
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    tree_id TEXT NOT NULL REFERENCES trees(tree_id) ON DELETE RESTRICT,
    parent_commit_id TEXT REFERENCES commits(commit_id) ON DELETE RESTRICT,
    version BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((scope = 'org' AND project_id IS NULL) OR (scope = 'project' AND project_id IS NOT NULL))
);

ALTER TABLE refs
    ADD CONSTRAINT refs_commit_id_fkey
    FOREIGN KEY (commit_id) REFERENCES commits(commit_id) ON DELETE RESTRICT;

ALTER TABLE drafts
    ADD CONSTRAINT drafts_base_commit_id_fkey
    FOREIGN KEY (base_commit_id) REFERENCES commits(commit_id) ON DELETE RESTRICT;

ALTER TABLE review_merges
    ADD CONSTRAINT review_merges_commit_id_fkey
    FOREIGN KEY (commit_id) REFERENCES commits(commit_id) ON DELETE RESTRICT;

CREATE TABLE tree_entries (
    tree_id TEXT NOT NULL REFERENCES trees(tree_id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    resource_kind TEXT NOT NULL CHECK (resource_kind IN ('rule', 'context', 'workflow', 'metaprompt', 'project_org_selection')),
    scope TEXT NOT NULL CHECK (scope IN ('org', 'project', 'daemon')),
    project_id TEXT REFERENCES projects(project_id) ON DELETE CASCADE,
    path TEXT,
    blob_id TEXT NOT NULL REFERENCES blobs(blob_id) ON DELETE RESTRICT,
    source TEXT NOT NULL CHECK (source IN ('org', 'project', 'selected_org', 'bootstrap', 'config')),
    PRIMARY KEY (tree_id, item_id)
);
