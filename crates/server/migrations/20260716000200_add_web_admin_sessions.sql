ALTER TABLE auth_sessions
    ADD COLUMN csrf_token TEXT;

ALTER TABLE access_tokens
    DROP CONSTRAINT access_tokens_kind_check;

ALTER TABLE access_tokens
    ADD CONSTRAINT access_tokens_kind_check
    CHECK (kind IN ('access', 'refresh', 'integration', 'web_session'));

ALTER TABLE oidc_login_transactions
    DROP CONSTRAINT oidc_login_transactions_flow_check;

ALTER TABLE oidc_login_transactions
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
            AND client_kind = 'web_admin'
            AND client_code_challenge IS NULL
        )
        OR (
            flow = 'web_admin_login'
            AND setup_session_id IS NULL
            AND client_kind = 'web_admin'
            AND client_code_challenge IS NULL
        )
    );
