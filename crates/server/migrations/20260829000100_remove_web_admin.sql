UPDATE access_tokens
SET revoked_at = COALESCE(revoked_at, now())
WHERE kind = 'web_session';

UPDATE auth_sessions
SET revoked_at = COALESCE(revoked_at, now())
WHERE session_id IN (
    SELECT session_id FROM access_tokens WHERE kind = 'web_session'
);

DELETE FROM oidc_login_transactions
WHERE client_kind = 'web_admin' OR flow = 'web_admin_login';

ALTER TABLE oidc_login_transactions
    DROP CONSTRAINT oidc_login_transactions_client_kind_check,
    DROP CONSTRAINT oidc_login_transactions_flow_check;

ALTER TABLE oidc_login_transactions
    ADD CONSTRAINT oidc_login_transactions_client_kind_check
    CHECK (client_kind IN ('desktop', 'cli')),
    ADD CONSTRAINT oidc_login_transactions_flow_check CHECK (
        (
            flow = 'product_login'
            AND setup_session_id IS NULL
            AND client_kind IN ('desktop', 'cli')
            AND client_code_challenge IS NOT NULL
        )
        OR (
            flow = 'installation_setup'
            AND setup_session_id IS NOT NULL
            AND client_kind = 'desktop'
            AND client_state IS NOT NULL
            AND client_code_challenge IS NOT NULL
        )
    );
