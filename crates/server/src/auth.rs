use std::env;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use openidconnect::core::{CoreAuthenticationFlow, CoreClient, CoreProviderMetadata};
use openidconnect::reqwest;
use openidconnect::{
    AccessTokenHash, AuthorizationCode, ClientId, ClientSecret, CsrfToken, EndpointMaybeSet,
    EndpointNotSet, EndpointSet, IssuerUrl, Nonce, OAuth2TokenResponse, PkceCodeChallenge,
    PkceCodeVerifier, RedirectUrl, Scope, TokenResponse as _,
};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use subtle::ConstantTimeEq;
use thiserror::Error;
use time::{Duration, OffsetDateTime};
use url::Url;
use uuid::Uuid;

use crate::api::{
    ClientKind, OidcAuthorizationRequest, OidcCallbackRequest, OrgRef, SessionRevoked,
    TokenGrantType, TokenRequest, TokenResponse, UserRef,
};

const ACCESS_TOKEN_TTL: Duration = Duration::minutes(15);
const REFRESH_TOKEN_TTL: Duration = Duration::days(30);
const LOGIN_TRANSACTION_TTL: Duration = Duration::minutes(10);
const AUTHORIZATION_CODE_TTL: Duration = Duration::minutes(2);

type DiscoveredCoreClient = CoreClient<
    EndpointSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointMaybeSet,
    EndpointMaybeSet,
>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthPrincipal {
    pub user_id: String,
    pub org_id: String,
    pub session_id: String,
    pub token_id: String,
    pub role: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OidcIdentity {
    pub issuer: String,
    pub subject: String,
    pub email: String,
    pub email_verified: bool,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
}

#[async_trait]
pub trait OidcIdentityProvider: Send + Sync {
    fn authorization_url(
        &self,
        provider_state: &str,
        nonce: &str,
        provider_pkce_challenge: PkceCodeChallenge,
        login_hint: Option<&str>,
    ) -> Result<String, AuthError>;

    async fn exchange_code(
        &self,
        code: &str,
        nonce: &str,
        provider_pkce_verifier: &str,
    ) -> Result<OidcIdentity, AuthError>;
}

pub struct DiscoveredOidcProvider {
    issuer: String,
    client: DiscoveredCoreClient,
    http_client: reqwest::Client,
}

impl DiscoveredOidcProvider {
    pub async fn discover(
        issuer: &str,
        client_id: String,
        client_secret: String,
        callback_url: String,
    ) -> Result<Self, AuthError> {
        let issuer = IssuerUrl::new(issuer.to_owned())
            .map_err(|error| AuthError::Configuration(error.to_string()))?;
        let issuer_identity = issuer.to_string();
        let http_client = reqwest::ClientBuilder::new()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| AuthError::ProviderUnavailable(error.to_string()))?;
        let metadata = CoreProviderMetadata::discover_async(issuer, &http_client)
            .await
            .map_err(|error| AuthError::ProviderUnavailable(error.to_string()))?;
        let client = CoreClient::from_provider_metadata(
            metadata,
            ClientId::new(client_id),
            Some(ClientSecret::new(client_secret)),
        )
        .set_redirect_uri(
            RedirectUrl::new(callback_url)
                .map_err(|error| AuthError::Configuration(error.to_string()))?,
        );
        Ok(Self {
            issuer: issuer_identity,
            client,
            http_client,
        })
    }
}

#[async_trait]
impl OidcIdentityProvider for DiscoveredOidcProvider {
    fn authorization_url(
        &self,
        provider_state: &str,
        nonce: &str,
        provider_pkce_challenge: PkceCodeChallenge,
        login_hint: Option<&str>,
    ) -> Result<String, AuthError> {
        let state = provider_state.to_owned();
        let nonce = nonce.to_owned();
        let mut request = self
            .client
            .authorize_url(
                CoreAuthenticationFlow::AuthorizationCode,
                move || CsrfToken::new(state),
                move || Nonce::new(nonce),
            )
            .add_scope(Scope::new("email".to_owned()))
            .add_scope(Scope::new("profile".to_owned()))
            .set_pkce_challenge(provider_pkce_challenge);
        if let Some(login_hint) = login_hint {
            request = request.add_extra_param("login_hint", login_hint);
        }
        let (url, _, _) = request.url();
        Ok(url.to_string())
    }

    async fn exchange_code(
        &self,
        code: &str,
        nonce: &str,
        provider_pkce_verifier: &str,
    ) -> Result<OidcIdentity, AuthError> {
        let response = self
            .client
            .exchange_code(AuthorizationCode::new(code.to_owned()))
            .map_err(|error| AuthError::ProviderInvalid(error.to_string()))?
            .set_pkce_verifier(PkceCodeVerifier::new(provider_pkce_verifier.to_owned()))
            .request_async(&self.http_client)
            .await
            .map_err(|error| AuthError::ProviderUnavailable(error.to_string()))?;
        let id_token = response.id_token().ok_or_else(|| {
            AuthError::ProviderInvalid("provider returned no ID token".to_owned())
        })?;
        let verifier = self.client.id_token_verifier();
        let claims = id_token
            .claims(&verifier, &Nonce::new(nonce.to_owned()))
            .map_err(|error| AuthError::ProviderInvalid(error.to_string()))?;
        if let Some(expected_hash) = claims.access_token_hash() {
            let actual_hash = AccessTokenHash::from_token(
                response.access_token(),
                id_token
                    .signing_alg()
                    .map_err(|error| AuthError::ProviderInvalid(error.to_string()))?,
                id_token
                    .signing_key(&verifier)
                    .map_err(|error| AuthError::ProviderInvalid(error.to_string()))?,
            )
            .map_err(|error| AuthError::ProviderInvalid(error.to_string()))?;
            if actual_hash != *expected_hash {
                return Err(AuthError::ProviderInvalid(
                    "provider access token hash does not match the ID token".to_owned(),
                ));
            }
        }
        let email = claims
            .email()
            .map(|email| email.as_str().to_owned())
            .ok_or(AuthError::EmailNotVerified)?;
        let display_name = claims
            .name()
            .and_then(|claim| claim.get(None))
            .map(|name| name.as_str().to_owned())
            .filter(|name| !name.trim().is_empty());
        let avatar_url = claims
            .picture()
            .and_then(|claim| claim.get(None))
            .map(|picture| picture.as_str().to_owned())
            .filter(|value| Url::parse(value).is_ok_and(|url| url.scheme() == "https"));
        Ok(OidcIdentity {
            issuer: self.issuer.clone(),
            subject: claims.subject().as_str().to_owned(),
            email,
            email_verified: claims.email_verified().unwrap_or(false),
            display_name,
            avatar_url,
        })
    }
}

#[derive(Clone)]
pub struct AuthService {
    pool: PgPool,
    provider: Option<Arc<dyn OidcIdentityProvider>>,
    allowed_redirects: Arc<Vec<Url>>,
}

impl AuthService {
    pub fn unconfigured(pool: PgPool) -> Self {
        Self {
            pool,
            provider: None,
            allowed_redirects: Arc::new(Vec::new()),
        }
    }

    pub fn with_provider(
        pool: PgPool,
        provider: Arc<dyn OidcIdentityProvider>,
        allowed_redirects: Vec<Url>,
    ) -> Self {
        Self {
            pool,
            provider: Some(provider),
            allowed_redirects: Arc::new(allowed_redirects),
        }
    }

    pub async fn from_env(pool: PgPool) -> Result<Self, AuthError> {
        let issuer = optional_env("CLUMSIES_OIDC_ISSUER");
        let client_id = optional_env("CLUMSIES_OIDC_CLIENT_ID");
        let client_secret = optional_env("CLUMSIES_OIDC_CLIENT_SECRET");
        let callback_url = optional_env("CLUMSIES_OIDC_CALLBACK_URL");
        if issuer.is_none()
            && client_id.is_none()
            && client_secret.is_none()
            && callback_url.is_none()
        {
            return Ok(Self::unconfigured(pool));
        }
        let issuer = issuer.ok_or_else(|| {
            AuthError::Configuration("CLUMSIES_OIDC_ISSUER is required".to_owned())
        })?;
        let client_id = client_id.ok_or_else(|| {
            AuthError::Configuration("CLUMSIES_OIDC_CLIENT_ID is required".to_owned())
        })?;
        let client_secret = client_secret.ok_or_else(|| {
            AuthError::Configuration("CLUMSIES_OIDC_CLIENT_SECRET is required".to_owned())
        })?;
        let callback_url = callback_url.ok_or_else(|| {
            AuthError::Configuration("CLUMSIES_OIDC_CALLBACK_URL is required".to_owned())
        })?;
        let allowed_redirects = env::var("CLUMSIES_CLIENT_REDIRECT_URIS")
            .map_err(|_| {
                AuthError::Configuration(
                    "CLUMSIES_CLIENT_REDIRECT_URIS is required when OIDC is configured".to_owned(),
                )
            })?
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| {
                Url::parse(value).map_err(|error| {
                    AuthError::Configuration(format!(
                        "invalid client redirect URI {value}: {error}"
                    ))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if allowed_redirects.is_empty() {
            return Err(AuthError::Configuration(
                "CLUMSIES_CLIENT_REDIRECT_URIS must contain at least one URI".to_owned(),
            ));
        }
        let provider =
            DiscoveredOidcProvider::discover(&issuer, client_id, client_secret, callback_url)
                .await?;
        Ok(Self::with_provider(
            pool,
            Arc::new(provider),
            allowed_redirects,
        ))
    }

    pub fn configured(&self) -> bool {
        self.provider.is_some()
    }

    pub async fn begin_login(
        &self,
        request: OidcAuthorizationRequest,
    ) -> Result<String, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        if request.code_challenge_method != "S256" {
            return Err(AuthError::InvalidRequest(
                "code_challenge_method must be S256".to_owned(),
            ));
        }
        validate_code_challenge(&request.code_challenge)?;
        let client_redirect = Url::parse(&request.redirect_uri)
            .map_err(|error| AuthError::InvalidRequest(error.to_string()))?;
        if !self.redirect_allowed(&client_redirect) {
            return Err(AuthError::RedirectNotAllowed);
        }
        validate_return_to(request.return_to.as_deref(), &client_redirect)?;

        let provider_state = random_token();
        let nonce = random_token();
        let (provider_pkce_challenge, provider_pkce_verifier) =
            PkceCodeChallenge::new_random_sha256();
        let authorization_url = provider.authorization_url(
            &provider_state,
            &nonce,
            provider_pkce_challenge,
            request.login_hint.as_deref(),
        )?;
        sqlx::query(
            "INSERT INTO oidc_login_transactions (
                transaction_id, provider_state_hash, nonce, provider_pkce_verifier,
                client_kind, client_redirect_uri, client_state, client_code_challenge,
                return_to, expires_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(prefixed_id("login"))
        .bind(secret_hash(&provider_state))
        .bind(nonce)
        .bind(provider_pkce_verifier.secret())
        .bind(client_kind(request.client_kind))
        .bind(client_redirect.as_str())
        .bind(request.state)
        .bind(request.code_challenge)
        .bind(request.return_to)
        .bind(OffsetDateTime::now_utc() + LOGIN_TRANSACTION_TTL)
        .execute(&self.pool)
        .await?;
        Ok(authorization_url)
    }

    pub async fn complete_login(&self, request: OidcCallbackRequest) -> Result<String, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        let transaction = self.login_transaction(&request.state).await?;
        if let Some(provider_error) = request.error {
            self.consume_login_transaction(&transaction.transaction_id)
                .await?;
            return callback_redirect(
                &transaction,
                None,
                Some((&provider_error, request.error_description.as_deref())),
            );
        }
        let code = request.code.ok_or_else(|| {
            AuthError::InvalidRequest("OIDC callback requires code or error".to_owned())
        })?;
        let identity = provider
            .exchange_code(
                &code,
                &transaction.nonce,
                &transaction.provider_pkce_verifier,
            )
            .await?;
        if !identity.email_verified {
            return Err(AuthError::EmailNotVerified);
        }
        let authorization_code = random_token();
        let mut tx = self.pool.begin().await?;
        let consumed = sqlx::query(
            "UPDATE oidc_login_transactions
             SET consumed_at = now()
             WHERE transaction_id = $1 AND consumed_at IS NULL AND expires_at > now()",
        )
        .bind(&transaction.transaction_id)
        .execute(&mut *tx)
        .await?;
        if consumed.rows_affected() != 1 {
            return Err(AuthError::LoginTransactionExpired);
        }
        let org = sqlx::query(
            "SELECT org_id, allowed_email_domains FROM orgs ORDER BY created_at LIMIT 1",
        )
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(AuthError::MemberNotAllowed)?;
        let org_id: String = org.try_get("org_id")?;
        let allowed_domains: Vec<String> = org.try_get("allowed_email_domains")?;
        enforce_email_domain(&identity.email, &allowed_domains)?;
        let user_id = resolve_external_identity(&mut tx, &identity).await?;
        sqlx::query(
            "INSERT INTO authorization_codes (
                code_id, code_hash, user_id, org_id, redirect_uri, code_challenge, expires_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(prefixed_id("code"))
        .bind(secret_hash(&authorization_code))
        .bind(&user_id)
        .bind(&org_id)
        .bind(&transaction.client_redirect_uri)
        .bind(&transaction.client_code_challenge)
        .bind(OffsetDateTime::now_utc() + AUTHORIZATION_CODE_TTL)
        .execute(&mut *tx)
        .await?;
        insert_audit_event(
            &mut tx,
            &org_id,
            Some(&user_id),
            "auth.oidc_login_completed",
            "session",
            None,
        )
        .await?;
        tx.commit().await?;
        callback_redirect(&transaction, Some(&authorization_code), None)
    }

    pub async fn exchange_token(&self, request: TokenRequest) -> Result<TokenResponse, AuthError> {
        match request.grant_type {
            TokenGrantType::AuthorizationCode => self.exchange_authorization_code(request).await,
            TokenGrantType::RefreshToken => self.rotate_refresh_token(request).await,
        }
    }

    pub async fn authenticate(&self, bearer_token: &str) -> Result<AuthPrincipal, AuthError> {
        let row = sqlx::query(
            "SELECT t.token_id, t.session_id, t.user_id, s.org_id, u.role
             FROM access_tokens t
             JOIN auth_sessions s ON s.session_id = t.session_id
             JOIN users u ON u.user_id = t.user_id
             WHERE t.token_hash = $1
               AND t.kind IN ('access', 'integration')
               AND t.revoked_at IS NULL
               AND (t.expires_at IS NULL OR t.expires_at > now())
               AND s.revoked_at IS NULL
               AND u.status = 'active'",
        )
        .bind(secret_hash(bearer_token))
        .fetch_optional(&self.pool)
        .await?
        .ok_or(AuthError::Unauthorized)?;
        Ok(AuthPrincipal {
            token_id: row.try_get("token_id")?,
            session_id: row.try_get("session_id")?,
            user_id: row.try_get("user_id")?,
            org_id: row.try_get("org_id")?,
            role: row.try_get("role")?,
        })
    }

    pub async fn revoke_session(
        &self,
        principal: &AuthPrincipal,
    ) -> Result<SessionRevoked, AuthError> {
        let mut tx = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE auth_sessions SET revoked_at = now()
             WHERE session_id = $1 AND revoked_at IS NULL",
        )
        .bind(&principal.session_id)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "UPDATE access_tokens SET revoked_at = now()
             WHERE session_id = $1 AND revoked_at IS NULL",
        )
        .bind(&principal.session_id)
        .execute(&mut *tx)
        .await?;
        insert_audit_event(
            &mut tx,
            &principal.org_id,
            Some(&principal.user_id),
            "auth.session_revoked",
            "session",
            Some(&principal.session_id),
        )
        .await?;
        tx.commit().await?;
        Ok(SessionRevoked {
            revoked: result.rows_affected() == 1,
        })
    }

    async fn exchange_authorization_code(
        &self,
        request: TokenRequest,
    ) -> Result<TokenResponse, AuthError> {
        let code = request.code.ok_or(AuthError::InvalidGrant)?;
        let redirect_uri = request.redirect_uri.ok_or(AuthError::InvalidGrant)?;
        let verifier = request.code_verifier.ok_or(AuthError::InvalidGrant)?;
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT code_id, user_id, org_id, redirect_uri, code_challenge
             FROM authorization_codes
             WHERE code_hash = $1 AND consumed_at IS NULL AND expires_at > now()
             FOR UPDATE",
        )
        .bind(secret_hash(&code))
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(AuthError::InvalidGrant)?;
        let expected_redirect: String = row.try_get("redirect_uri")?;
        let expected_challenge: String = row.try_get("code_challenge")?;
        let actual_challenge = code_challenge(&verifier);
        if expected_redirect != redirect_uri
            || expected_challenge.len() != actual_challenge.len()
            || expected_challenge
                .as_bytes()
                .ct_eq(actual_challenge.as_bytes())
                .unwrap_u8()
                != 1
        {
            return Err(AuthError::InvalidGrant);
        }
        let code_id: String = row.try_get("code_id")?;
        let user_id: String = row.try_get("user_id")?;
        let org_id: String = row.try_get("org_id")?;
        sqlx::query("UPDATE authorization_codes SET consumed_at = now() WHERE code_id = $1")
            .bind(&code_id)
            .execute(&mut *tx)
            .await?;
        let session_id = prefixed_id("ses");
        sqlx::query("INSERT INTO auth_sessions (session_id, user_id, org_id) VALUES ($1, $2, $3)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&org_id)
            .execute(&mut *tx)
            .await?;
        let response = issue_token_pair(&mut tx, &session_id, &user_id, &org_id).await?;
        insert_audit_event(
            &mut tx,
            &org_id,
            Some(&user_id),
            "auth.session_created",
            "session",
            Some(&session_id),
        )
        .await?;
        tx.commit().await?;
        Ok(response)
    }

    async fn rotate_refresh_token(
        &self,
        request: TokenRequest,
    ) -> Result<TokenResponse, AuthError> {
        let refresh_token = request.refresh_token.ok_or(AuthError::InvalidGrant)?;
        let mut tx = self.pool.begin().await?;
        let row = sqlx::query(
            "SELECT t.token_id, t.session_id, t.user_id, s.org_id
             FROM access_tokens t
             JOIN auth_sessions s ON s.session_id = t.session_id
             JOIN users u ON u.user_id = t.user_id
             WHERE t.token_hash = $1 AND t.kind = 'refresh'
               AND t.revoked_at IS NULL AND t.expires_at > now()
               AND s.revoked_at IS NULL AND u.status = 'active'
             FOR UPDATE OF t",
        )
        .bind(secret_hash(&refresh_token))
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(AuthError::InvalidGrant)?;
        let token_id: String = row.try_get("token_id")?;
        let session_id: String = row.try_get("session_id")?;
        let user_id: String = row.try_get("user_id")?;
        let org_id: String = row.try_get("org_id")?;
        sqlx::query("UPDATE access_tokens SET revoked_at = now() WHERE token_id = $1")
            .bind(&token_id)
            .execute(&mut *tx)
            .await?;
        let response = issue_token_pair(&mut tx, &session_id, &user_id, &org_id).await?;
        tx.commit().await?;
        Ok(response)
    }

    async fn login_transaction(&self, provider_state: &str) -> Result<LoginTransaction, AuthError> {
        let row = sqlx::query(
            "SELECT transaction_id, nonce, provider_pkce_verifier, client_redirect_uri,
                    client_state, client_code_challenge, return_to
             FROM oidc_login_transactions
             WHERE provider_state_hash = $1 AND consumed_at IS NULL AND expires_at > now()",
        )
        .bind(secret_hash(provider_state))
        .fetch_optional(&self.pool)
        .await?
        .ok_or(AuthError::LoginTransactionExpired)?;
        Ok(LoginTransaction {
            transaction_id: row.try_get("transaction_id")?,
            nonce: row.try_get("nonce")?,
            provider_pkce_verifier: row.try_get("provider_pkce_verifier")?,
            client_redirect_uri: row.try_get("client_redirect_uri")?,
            client_state: row.try_get("client_state")?,
            client_code_challenge: row.try_get("client_code_challenge")?,
            return_to: row.try_get("return_to")?,
        })
    }

    async fn consume_login_transaction(&self, transaction_id: &str) -> Result<(), AuthError> {
        let result = sqlx::query(
            "UPDATE oidc_login_transactions SET consumed_at = now()
             WHERE transaction_id = $1 AND consumed_at IS NULL AND expires_at > now()",
        )
        .bind(transaction_id)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 1 {
            Ok(())
        } else {
            Err(AuthError::LoginTransactionExpired)
        }
    }

    fn redirect_allowed(&self, requested: &Url) -> bool {
        self.allowed_redirects
            .iter()
            .any(|allowed| redirect_matches(allowed, requested))
    }
}

#[derive(Debug)]
struct LoginTransaction {
    transaction_id: String,
    nonce: String,
    provider_pkce_verifier: String,
    client_redirect_uri: String,
    client_state: Option<String>,
    client_code_challenge: String,
    return_to: Option<String>,
}

async fn issue_token_pair(
    tx: &mut Transaction<'_, Postgres>,
    session_id: &str,
    user_id: &str,
    org_id: &str,
) -> Result<TokenResponse, AuthError> {
    let access_token = random_token();
    let refresh_token = random_token();
    let now = OffsetDateTime::now_utc();
    for (kind, token, expires_at) in [
        ("access", &access_token, now + ACCESS_TOKEN_TTL),
        ("refresh", &refresh_token, now + REFRESH_TOKEN_TTL),
    ] {
        sqlx::query(
            "INSERT INTO access_tokens (
                token_id, session_id, user_id, kind, token_hash, expires_at
             ) VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(prefixed_id("tok"))
        .bind(session_id)
        .bind(user_id)
        .bind(kind)
        .bind(secret_hash(token))
        .bind(expires_at)
        .execute(&mut **tx)
        .await?;
    }
    let user_row = sqlx::query(
        "SELECT user_id, email, display_name, avatar_url, role FROM users WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_one(&mut **tx)
    .await?;
    let org_row = sqlx::query("SELECT org_id, name FROM orgs WHERE org_id = $1")
        .bind(org_id)
        .fetch_one(&mut **tx)
        .await?;
    let role: String = user_row.try_get("role")?;
    let user = UserRef {
        user_id: user_row.try_get("user_id")?,
        email: user_row.try_get("email")?,
        display_name: user_row.try_get("display_name")?,
        avatar_url: user_row.try_get("avatar_url")?,
        role: role.clone(),
    };
    Ok(TokenResponse {
        access_token,
        refresh_token,
        token_type: "Bearer".to_owned(),
        expires_in: ACCESS_TOKEN_TTL.whole_seconds(),
        capabilities: capabilities(&role),
        user,
        org: OrgRef {
            org_id: org_row.try_get("org_id")?,
            name: org_row.try_get("name")?,
        },
    })
}

async fn resolve_external_identity(
    tx: &mut Transaction<'_, Postgres>,
    identity: &OidcIdentity,
) -> Result<String, AuthError> {
    let bound_user = sqlx::query(
        "SELECT u.user_id, u.status
         FROM external_identities i
         JOIN users u ON u.user_id = i.user_id
         WHERE i.protocol = 'oidc' AND i.issuer = $1 AND i.subject = $2
         FOR UPDATE OF i, u",
    )
    .bind(&identity.issuer)
    .bind(&identity.subject)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(user) = bound_user {
        let user_id: String = user.try_get("user_id")?;
        ensure_member_enabled(user.try_get("status")?)?;
        activate_member(
            tx,
            &user_id,
            identity.display_name.as_deref(),
            identity.avatar_url.as_deref(),
        )
        .await?;
        return Ok(user_id);
    }

    let user = sqlx::query(
        "SELECT user_id, status
         FROM users
         WHERE lower(email) = lower($1)
         FOR UPDATE",
    )
    .bind(&identity.email)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(AuthError::MemberNotAllowed)?;
    let user_id: String = user.try_get("user_id")?;
    ensure_member_enabled(user.try_get("status")?)?;

    let existing_subject = sqlx::query_scalar::<_, String>(
        "SELECT subject
         FROM external_identities
         WHERE user_id = $1 AND protocol = 'oidc' AND issuer = $2
         FOR UPDATE",
    )
    .bind(&user_id)
    .bind(&identity.issuer)
    .fetch_optional(&mut **tx)
    .await?;
    match existing_subject {
        Some(subject) if subject != identity.subject => {
            return Err(AuthError::ProviderIdentityConflict);
        }
        Some(_) => {}
        None => {
            sqlx::query(
                "INSERT INTO external_identities (
                    external_identity_id, user_id, protocol, issuer, subject, email_at_binding
                 ) VALUES ($1, $2, 'oidc', $3, $4, $5)",
            )
            .bind(prefixed_id("idn"))
            .bind(&user_id)
            .bind(&identity.issuer)
            .bind(&identity.subject)
            .bind(&identity.email)
            .execute(&mut **tx)
            .await?;
        }
    }
    activate_member(
        tx,
        &user_id,
        identity.display_name.as_deref(),
        identity.avatar_url.as_deref(),
    )
    .await?;
    Ok(user_id)
}

fn ensure_member_enabled(status: String) -> Result<(), AuthError> {
    if status == "disabled" {
        Err(AuthError::MemberNotAllowed)
    } else {
        Ok(())
    }
}

async fn activate_member(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    display_name: Option<&str>,
    avatar_url: Option<&str>,
) -> Result<(), AuthError> {
    sqlx::query(
        "UPDATE users
         SET status = 'active',
             display_name = COALESCE($2, display_name),
             avatar_url = COALESCE($3, avatar_url),
             revision = revision + 1, updated_at = now()
         WHERE user_id = $1
           AND (
               status <> 'active'
               OR ($2 IS NOT NULL AND display_name IS DISTINCT FROM $2)
               OR ($3 IS NOT NULL AND avatar_url IS DISTINCT FROM $3)
           )",
    )
    .bind(user_id)
    .bind(display_name)
    .bind(avatar_url)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn insert_audit_event(
    tx: &mut Transaction<'_, Postgres>,
    org_id: &str,
    actor_user_id: Option<&str>,
    action: &str,
    target_type: &str,
    target_id: Option<&str>,
) -> Result<(), AuthError> {
    sqlx::query(
        "INSERT INTO audit_events (
            event_id, org_id, actor_user_id, action, target_type, target_id
         ) VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(prefixed_id("evt"))
    .bind(org_id)
    .bind(actor_user_id)
    .bind(action)
    .bind(target_type)
    .bind(target_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

fn callback_redirect(
    transaction: &LoginTransaction,
    code: Option<&str>,
    error: Option<(&str, Option<&str>)>,
) -> Result<String, AuthError> {
    let mut url = Url::parse(&transaction.client_redirect_uri)
        .map_err(|parse_error| AuthError::InvalidRequest(parse_error.to_string()))?;
    {
        let mut query = url.query_pairs_mut();
        if let Some(code) = code {
            query.append_pair("code", code);
            query.append_pair(
                "expires_in",
                &AUTHORIZATION_CODE_TTL.whole_seconds().to_string(),
            );
        }
        if let Some((error, description)) = error {
            query.append_pair("error", error);
            if let Some(description) = description {
                query.append_pair("error_description", description);
            }
        }
        if let Some(state) = &transaction.client_state {
            query.append_pair("state", state);
        }
        if let Some(return_to) = &transaction.return_to {
            query.append_pair("return_to", return_to);
        }
    }
    Ok(url.to_string())
}

fn validate_code_challenge(value: &str) -> Result<(), AuthError> {
    if value.len() != 43
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err(AuthError::InvalidRequest(
            "code_challenge must be a SHA-256 base64url value".to_owned(),
        ));
    }
    Ok(())
}

fn code_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn validate_return_to(value: Option<&str>, client_redirect: &Url) -> Result<(), AuthError> {
    let Some(value) = value else {
        return Ok(());
    };
    if value.starts_with('/') && !value.starts_with("//") {
        return Ok(());
    }
    let return_url = Url::parse(value)
        .map_err(|_| AuthError::InvalidRequest("return_to is not trusted".to_owned()))?;
    if return_url.scheme() == client_redirect.scheme()
        && return_url.host_str() == client_redirect.host_str()
        && return_url.port_or_known_default() == client_redirect.port_or_known_default()
    {
        Ok(())
    } else {
        Err(AuthError::InvalidRequest(
            "return_to is not trusted".to_owned(),
        ))
    }
}

fn redirect_matches(allowed: &Url, requested: &Url) -> bool {
    if allowed == requested {
        return true;
    }
    allowed.scheme() == "http"
        && requested.scheme() == "http"
        && allowed.port().is_none()
        && is_loopback_host(allowed.host_str())
        && allowed.host_str() == requested.host_str()
        && allowed.path() == requested.path()
        && allowed.query() == requested.query()
        && requested.port().is_some()
}

fn is_loopback_host(host: Option<&str>) -> bool {
    matches!(host, Some("127.0.0.1") | Some("[::1]") | Some("localhost"))
}

fn enforce_email_domain(email: &str, allowed_domains: &[String]) -> Result<(), AuthError> {
    if allowed_domains.is_empty() {
        return Ok(());
    }
    let domain = email.rsplit_once('@').map(|(_, domain)| domain);
    if domain.is_some_and(|domain| {
        allowed_domains
            .iter()
            .any(|allowed| domain.eq_ignore_ascii_case(allowed))
    }) {
        Ok(())
    } else {
        Err(AuthError::DomainNotAllowed)
    }
}

fn capabilities(role: &str) -> Vec<String> {
    let mut capabilities = vec![
        "memory:read".to_owned(),
        "draft:write".to_owned(),
        "review:write".to_owned(),
    ];
    if role == "owner" || role == "admin" {
        capabilities.push("review:merge".to_owned());
        capabilities.push("admin:write".to_owned());
    }
    capabilities
}

fn client_kind(kind: ClientKind) -> &'static str {
    match kind {
        ClientKind::Desktop => "desktop",
        ClientKind::Cli => "cli",
        ClientKind::WebAdmin => "web_admin",
    }
}

fn secret_hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn random_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn prefixed_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn optional_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("OIDC is not configured")]
    NotConfigured,
    #[error("invalid authentication configuration: {0}")]
    Configuration(String),
    #[error("invalid authentication request: {0}")]
    InvalidRequest(String),
    #[error("redirect URI is not allowed")]
    RedirectNotAllowed,
    #[error("OIDC provider is unavailable: {0}")]
    ProviderUnavailable(String),
    #[error("OIDC identity response is invalid: {0}")]
    ProviderInvalid(String),
    #[error("OIDC login transaction is expired or already consumed")]
    LoginTransactionExpired,
    #[error("OIDC email is not verified")]
    EmailNotVerified,
    #[error("member is not admitted to this Server")]
    MemberNotAllowed,
    #[error("email domain is not allowed")]
    DomainNotAllowed,
    #[error("OIDC identity conflicts with the admitted member")]
    ProviderIdentityConflict,
    #[error("authorization grant is invalid or expired")]
    InvalidGrant,
    #[error("authentication is required")]
    Unauthorized,
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
}

impl AuthError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotConfigured => "oidc_not_configured",
            Self::Configuration(_) => "auth_configuration_invalid",
            Self::InvalidRequest(_) => "validation_failed",
            Self::RedirectNotAllowed => "redirect_uri_not_allowed",
            Self::ProviderUnavailable(_) => "oidc_provider_unavailable",
            Self::ProviderInvalid(_) => "oidc_id_token_invalid",
            Self::LoginTransactionExpired => "login_transaction_expired",
            Self::EmailNotVerified => "email_not_verified",
            Self::MemberNotAllowed => "member_not_allowed",
            Self::DomainNotAllowed => "domain_not_allowed",
            Self::ProviderIdentityConflict => "oidc_identity_conflict",
            Self::InvalidGrant => "invalid_grant",
            Self::Unauthorized => "unauthorized",
            Self::Sqlx(_) => "internal_error",
        }
    }
}
