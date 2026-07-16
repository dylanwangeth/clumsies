DO $$
BEGIN
    IF (SELECT COUNT(*) FROM orgs) > 1 THEN
        RAISE EXCEPTION 'clumsies self-hosted Server supports exactly one organization';
    END IF;

    IF (SELECT COUNT(*) FROM orgs) = 1
       AND NOT EXISTS (
           SELECT 1
           FROM users u
           JOIN project_members pm ON pm.user_id = u.user_id
           JOIN projects p ON p.project_id = pm.project_id
           WHERE u.role = 'owner'
             AND u.status = 'active'
             AND p.org_id = (SELECT org_id FROM orgs LIMIT 1)
       ) THEN
        RAISE EXCEPTION 'existing organization is missing an active owner with project access';
    END IF;
END $$;

CREATE UNIQUE INDEX orgs_singleton_idx ON orgs ((TRUE));

CREATE TABLE server_installations (
    installation_id TEXT PRIMARY KEY CHECK (installation_id = 'default'),
    state TEXT NOT NULL CHECK (state IN ('setup_required', 'initialized')),
    org_id TEXT UNIQUE REFERENCES orgs(org_id) ON DELETE RESTRICT,
    initialized_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (state = 'setup_required' AND org_id IS NULL AND initialized_at IS NULL)
        OR (state = 'initialized' AND org_id IS NOT NULL AND initialized_at IS NOT NULL)
    )
);

INSERT INTO server_installations (
    installation_id,
    state,
    org_id,
    initialized_at
)
SELECT
    'default',
    CASE WHEN org.org_id IS NULL THEN 'setup_required' ELSE 'initialized' END,
    org.org_id,
    CASE WHEN org.org_id IS NULL THEN NULL ELSE org.created_at END
FROM (SELECT org_id, created_at FROM orgs ORDER BY created_at LIMIT 1) org
RIGHT JOIN (SELECT 1) singleton ON TRUE;

CREATE TABLE setup_sessions (
    session_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    csrf_token_hash TEXT NOT NULL,
    org_name TEXT,
    default_project_name TEXT,
    allowed_email_domains TEXT[] NOT NULL DEFAULT '{}',
    configuration_saved_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX setup_sessions_active_idx
    ON setup_sessions (expires_at)
    WHERE consumed_at IS NULL;

ALTER TABLE oidc_login_transactions
    ADD COLUMN flow TEXT NOT NULL DEFAULT 'product_login',
    ADD COLUMN setup_session_id TEXT REFERENCES setup_sessions(session_id) ON DELETE RESTRICT,
    ALTER COLUMN client_code_challenge DROP NOT NULL;

ALTER TABLE oidc_login_transactions
    ADD CONSTRAINT oidc_login_transactions_flow_check CHECK (
        (
            flow = 'product_login'
            AND setup_session_id IS NULL
            AND client_code_challenge IS NOT NULL
        )
        OR (
            flow = 'installation_setup'
            AND setup_session_id IS NOT NULL
            AND client_kind = 'web_admin'
            AND client_code_challenge IS NULL
        )
    );
