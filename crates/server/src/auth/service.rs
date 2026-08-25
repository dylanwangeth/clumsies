use std::env;
use std::sync::{Arc, RwLock};

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use openidconnect::core::{CoreAuthenticationFlow, CoreClient, CoreProviderMetadata};
use openidconnect::reqwest;
use openidconnect::{
    AccessTokenHash, AuthorizationCode, ClaimsVerificationError, ClientId, ClientSecret, CsrfToken,
    EndpointMaybeSet, EndpointNotSet, EndpointSet, IssuerUrl, Nonce, OAuth2TokenResponse,
    PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RequestTokenError, Scope,
    SignatureVerificationError, TokenResponse as _,
};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use time::OffsetDateTime;
use url::Url;

use crate::api::{
    AdmissionMode, ClientKind, OidcAuthorizationRequest, OidcCallbackRequest, OidcProviderStatus,
    SecretSource, SessionRevoked, TokenGrantType, TokenRequest, TokenResponse, WebAdminSession,
};
use crate::config::PublicOrigin;
use crate::installation::{InstallationError, InstallationService};
use crate::shared::random_token;

use super::error::AuthError;
use super::model::{
    AUTHORIZATION_CODE_TTL, AuthPrincipal, CredentialKind, LOGIN_TRANSACTION_TTL, LoginFlow,
    LoginTransaction, OidcIdentity, OidcLoginCompletion, ProviderSummary, WEB_SESSION_TTL,
    enforce_email_domain,
};
use super::postgres;

const LOCAL_ADMIN_COOKIE_NAME: &str = "clumsies_admin_session";
const SECURE_ADMIN_COOKIE_NAME: &str = "__Host-clumsies_admin_session";
const OIDC_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const OIDC_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

type DiscoveredCoreClient = CoreClient<
    EndpointSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointMaybeSet,
    EndpointMaybeSet,
>;

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
    client_id: String,
    client_secret: String,
    callback_url: String,
    client: RwLock<DiscoveredCoreClient>,
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
            .map_err(|error| AuthError::Configuration(error.to_string()))?
            .to_string();
        let http_client = reqwest::ClientBuilder::new()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(OIDC_CONNECT_TIMEOUT)
            .timeout(OIDC_REQUEST_TIMEOUT)
            .build()
            .map_err(|error| AuthError::ProviderUnavailable(error.to_string()))?;
        let client = discover_oidc_client(
            &issuer,
            &client_id,
            &client_secret,
            &callback_url,
            &http_client,
        )
        .await?;
        Ok(Self {
            issuer,
            client_id,
            client_secret,
            callback_url,
            client: RwLock::new(client),
            http_client,
        })
    }

    fn client(&self) -> Result<DiscoveredCoreClient, AuthError> {
        self.client
            .read()
            .map_err(|_| AuthError::ProviderUnavailable("OIDC client lock is poisoned".to_owned()))
            .map(|client| client.clone())
    }

    async fn refresh_client(&self) -> Result<DiscoveredCoreClient, AuthError> {
        let client = discover_oidc_client(
            &self.issuer,
            &self.client_id,
            &self.client_secret,
            &self.callback_url,
            &self.http_client,
        )
        .await?;
        *self.client.write().map_err(|_| {
            AuthError::ProviderUnavailable("OIDC client lock is poisoned".to_owned())
        })? = client.clone();
        Ok(client)
    }
}

async fn discover_oidc_client(
    issuer: &str,
    client_id: &str,
    client_secret: &str,
    callback_url: &str,
    http_client: &reqwest::Client,
) -> Result<DiscoveredCoreClient, AuthError> {
    let issuer = IssuerUrl::new(issuer.to_owned())
        .map_err(|error| AuthError::Configuration(error.to_string()))?;
    let metadata = CoreProviderMetadata::discover_async(issuer, http_client)
        .await
        .map_err(|error| AuthError::ProviderUnavailable(error.to_string()))?;
    Ok(CoreClient::from_provider_metadata(
        metadata,
        ClientId::new(client_id.to_owned()),
        Some(ClientSecret::new(client_secret.to_owned())),
    )
    .set_redirect_uri(
        RedirectUrl::new(callback_url.to_owned())
            .map_err(|error| AuthError::Configuration(error.to_string()))?,
    ))
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
        let client = self.client()?;
        let mut request = client
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
        let client = self.client()?;
        let response = client
            .exchange_code(AuthorizationCode::new(code.to_owned()))
            .map_err(|error| AuthError::ProviderCodeExchangeFailed(error.to_string()))?
            .set_pkce_verifier(PkceCodeVerifier::new(provider_pkce_verifier.to_owned()))
            .request_async(&self.http_client)
            .await
            .map_err(|error| match error {
                RequestTokenError::Request(error) => {
                    AuthError::ProviderUnavailable(error.to_string())
                }
                RequestTokenError::ServerResponse(error) => {
                    AuthError::ProviderCodeExchangeFailed(error.to_string())
                }
                RequestTokenError::Parse(error, _) => {
                    AuthError::ProviderCodeExchangeFailed(error.to_string())
                }
                RequestTokenError::Other(error) => AuthError::ProviderCodeExchangeFailed(error),
            })?;
        let id_token = response.id_token().ok_or_else(|| {
            AuthError::ProviderInvalid("provider returned no ID token".to_owned())
        })?;
        let nonce = Nonce::new(nonce.to_owned());
        let initial_verifier = client.id_token_verifier();
        let verification_client = match id_token.claims(&initial_verifier, &nonce) {
            Ok(_) => client.clone(),
            Err(error) if needs_jwks_refresh(&error) => self.refresh_client().await?,
            Err(error) => return Err(AuthError::ProviderInvalid(error.to_string())),
        };
        let verifier = verification_client.id_token_verifier();
        let claims = id_token
            .claims(&verifier, &nonce)
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

fn needs_jwks_refresh(error: &ClaimsVerificationError) -> bool {
    matches!(
        error,
        ClaimsVerificationError::SignatureVerification(SignatureVerificationError::NoMatchingKey)
    )
}

#[derive(Clone)]
pub struct AuthService {
    pool: PgPool,
    provider: Option<Arc<dyn OidcIdentityProvider>>,
    allowed_redirects: Arc<Vec<Url>>,
    provider_summary: Option<ProviderSummary>,
    secure_cookie: bool,
}

impl AuthService {
    pub fn unconfigured(pool: PgPool) -> Self {
        Self {
            pool,
            provider: None,
            allowed_redirects: Arc::new(Vec::new()),
            provider_summary: None,
            secure_cookie: false,
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
            provider_summary: None,
            secure_cookie: false,
        }
    }

    pub async fn from_env(pool: PgPool, public_origin: &PublicOrigin) -> Result<Self, AuthError> {
        let issuer = optional_env("CLUMSIES_OIDC_ISSUER");
        let client_id = optional_env("CLUMSIES_OIDC_CLIENT_ID");
        let client_secret = optional_env("CLUMSIES_OIDC_CLIENT_SECRET");
        if issuer.is_none() && client_id.is_none() && client_secret.is_none() {
            return Ok(Self::unconfigured(pool));
        }
        let issuer = required_oidc_value("CLUMSIES_OIDC_ISSUER", issuer)?;
        let client_id = required_oidc_value("CLUMSIES_OIDC_CLIENT_ID", client_id)?;
        let client_secret = required_oidc_value("CLUMSIES_OIDC_CLIENT_SECRET", client_secret)?;
        let callback_url = public_origin.oidc_callback_url();
        let mut allowed_redirects = vec![public_origin.admin_setup_callback_url()];
        if let Some(configured_redirects) = optional_env("CLUMSIES_CLIENT_REDIRECT_URIS") {
            for value in configured_redirects
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                let redirect = Url::parse(value).map_err(|error| {
                    AuthError::Configuration(format!(
                        "invalid client redirect URI {value}: {error}"
                    ))
                })?;
                if !allowed_redirects.contains(&redirect) {
                    allowed_redirects.push(redirect);
                }
            }
        }
        let provider = DiscoveredOidcProvider::discover(
            &issuer,
            client_id,
            client_secret,
            callback_url.clone(),
        )
        .await?;
        Ok(Self {
            pool,
            provider: Some(Arc::new(provider)),
            allowed_redirects: Arc::new(allowed_redirects),
            provider_summary: Some(ProviderSummary {
                issuer,
                callback_url,
            }),
            secure_cookie: public_origin.secure_cookies(),
        })
    }

    pub fn configured(&self) -> bool {
        self.provider.is_some()
    }

    pub fn admin_cookie_name(&self) -> &'static str {
        if self.secure_cookie {
            SECURE_ADMIN_COOKIE_NAME
        } else {
            LOCAL_ADMIN_COOKIE_NAME
        }
    }

    pub fn admin_cookie_secure(&self) -> bool {
        self.secure_cookie
    }

    pub fn web_session_ttl_seconds(&self) -> i64 {
        WEB_SESSION_TTL.whole_seconds()
    }

    pub fn provider_status(&self) -> OidcProviderStatus {
        OidcProviderStatus {
            protocol: "oidc".to_owned(),
            configured: self.configured(),
            issuer: self
                .provider_summary
                .as_ref()
                .map(|summary| summary.issuer.clone()),
            callback_url: self
                .provider_summary
                .as_ref()
                .map(|summary| summary.callback_url.clone()),
            admission_mode: AdmissionMode::InviteOnly,
            secret_source: SecretSource::DeploymentEnvironment,
        }
    }

    pub async fn begin_login(
        &self,
        request: OidcAuthorizationRequest,
    ) -> Result<String, AuthError> {
        if request.client_kind == ClientKind::WebAdmin {
            return self.begin_web_admin_login(request).await;
        }
        self.begin_product_login(request).await
    }

    async fn begin_product_login(
        &self,
        request: OidcAuthorizationRequest,
    ) -> Result<String, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        let code_challenge_method = request.code_challenge_method.as_deref().ok_or_else(|| {
            AuthError::InvalidRequest("code_challenge_method is required".to_owned())
        })?;
        if code_challenge_method != "S256" {
            return Err(AuthError::InvalidRequest(
                "code_challenge_method must be S256".to_owned(),
            ));
        }
        let code_challenge = request
            .code_challenge
            .as_deref()
            .ok_or_else(|| AuthError::InvalidRequest("code_challenge is required".to_owned()))?;
        validate_code_challenge(code_challenge)?;
        let redirect_uri = request
            .redirect_uri
            .as_deref()
            .ok_or_else(|| AuthError::InvalidRequest("redirect_uri is required".to_owned()))?;
        let client_redirect = Url::parse(redirect_uri)
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
        postgres::insert_product_login_transaction(
            &self.pool,
            postgres::ProductLoginTransaction {
                provider_state: &provider_state,
                nonce: &nonce,
                provider_pkce_verifier: provider_pkce_verifier.secret(),
                client_kind: client_kind(request.client_kind),
                client_redirect_uri: client_redirect.as_str(),
                client_state: request.state.as_deref(),
                client_code_challenge: code_challenge,
                return_to: request.return_to.as_deref(),
                expires_at: OffsetDateTime::now_utc() + LOGIN_TRANSACTION_TTL,
            },
        )
        .await?;
        Ok(authorization_url)
    }

    async fn begin_web_admin_login(
        &self,
        request: OidcAuthorizationRequest,
    ) -> Result<String, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        let return_to = request.return_to.as_deref().unwrap_or("/admin");
        self.validate_admin_return_to(return_to)?;

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
        postgres::insert_web_admin_login_transaction(
            &self.pool,
            &provider_state,
            &nonce,
            provider_pkce_verifier.secret(),
            return_to,
            OffsetDateTime::now_utc() + LOGIN_TRANSACTION_TTL,
        )
        .await?;
        Ok(authorization_url)
    }

    pub async fn begin_setup_login(
        &self,
        setup_session_id: &str,
        redirect_uri: &str,
    ) -> Result<String, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        let client_redirect = Url::parse(redirect_uri)
            .map_err(|error| AuthError::InvalidRequest(error.to_string()))?;
        if !self.redirect_allowed(&client_redirect) {
            return Err(AuthError::RedirectNotAllowed);
        }

        let provider_state = random_token();
        let nonce = random_token();
        let (provider_pkce_challenge, provider_pkce_verifier) =
            PkceCodeChallenge::new_random_sha256();
        let authorization_url =
            provider.authorization_url(&provider_state, &nonce, provider_pkce_challenge, None)?;
        postgres::insert_setup_login_transaction(
            &self.pool,
            &provider_state,
            &nonce,
            provider_pkce_verifier.secret(),
            client_redirect.as_str(),
            OffsetDateTime::now_utc() + LOGIN_TRANSACTION_TTL,
            setup_session_id,
        )
        .await?;
        Ok(authorization_url)
    }

    pub async fn complete_login(
        &self,
        request: OidcCallbackRequest,
        installation: &InstallationService,
    ) -> Result<OidcLoginCompletion, AuthError> {
        let provider = self.provider.as_ref().ok_or(AuthError::NotConfigured)?;
        let transaction = postgres::login_transaction(&self.pool, &request.state).await?;
        if let Some(provider_error) = request.error {
            postgres::consume_login_transaction(&self.pool, &transaction.transaction_id).await?;
            return callback_completion(
                &transaction,
                None,
                Some((&provider_error, request.error_description.as_deref())),
                None,
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
        let mut tx = self.pool.begin().await?;
        if !postgres::consume_login_transaction_in(&mut tx, &transaction.transaction_id).await? {
            return Err(AuthError::LoginTransactionExpired);
        }
        if transaction.flow == LoginFlow::InstallationSetup {
            let setup_session_id = transaction
                .setup_session_id
                .as_deref()
                .ok_or(AuthError::CorruptLoginTransaction)?;
            let initialized = match installation
                .initialize_with_oidc(&mut tx, setup_session_id, &identity)
                .await
            {
                Ok(initialized) => initialized,
                Err(error) => {
                    tx.rollback().await?;
                    if matches!(
                        error,
                        InstallationError::ConfigurationRequired
                            | InstallationError::OwnerDomainNotAllowed
                            | InstallationError::InvalidOwnerIdentity
                    ) {
                        postgres::consume_login_transaction(
                            &self.pool,
                            &transaction.transaction_id,
                        )
                        .await?;
                        return callback_completion(
                            &transaction,
                            None,
                            Some((error.code(), None)),
                            None,
                        );
                    }
                    return Err(error.into());
                }
            };
            let web_session =
                postgres::issue_web_session(&mut tx, &initialized.user_id, &initialized.org_id)
                    .await?;
            tx.commit().await?;
            return callback_completion(&transaction, None, None, Some(web_session.token));
        }

        let org = postgres::organization_admission(&mut tx).await?;
        enforce_email_domain(&identity.email, &org.allowed_email_domains)?;
        let org_id = org.org_id;
        let user_id = postgres::resolve_external_identity(&mut tx, &identity).await?;
        if transaction.flow == LoginFlow::WebAdminLogin {
            let role = postgres::active_user_role(&mut tx, &user_id).await?;
            if role != "owner" && role != "admin" {
                postgres::insert_audit_event(
                    &mut tx,
                    &org_id,
                    Some(&user_id),
                    "auth.web_admin_access_denied",
                    "user",
                    Some(&user_id),
                )
                .await?;
                tx.commit().await?;
                return callback_completion(
                    &transaction,
                    None,
                    Some((AuthError::AdminAccessRequired.code(), None)),
                    None,
                );
            }
            let web_session = postgres::issue_web_session(&mut tx, &user_id, &org_id).await?;
            tx.commit().await?;
            return callback_completion(&transaction, None, None, Some(web_session.token));
        }

        let authorization_code = random_token();
        let client_code_challenge = transaction
            .client_code_challenge
            .as_deref()
            .ok_or(AuthError::CorruptLoginTransaction)?;
        postgres::insert_authorization_code(
            &mut tx,
            &authorization_code,
            &user_id,
            &org_id,
            &transaction.client_redirect_uri,
            client_code_challenge,
            OffsetDateTime::now_utc() + AUTHORIZATION_CODE_TTL,
        )
        .await?;
        postgres::insert_audit_event(
            &mut tx,
            &org_id,
            Some(&user_id),
            "auth.oidc_login_completed",
            "session",
            None,
        )
        .await?;
        tx.commit().await?;
        callback_completion(&transaction, Some(&authorization_code), None, None)
    }

    pub async fn exchange_token(&self, request: TokenRequest) -> Result<TokenResponse, AuthError> {
        match request.grant_type {
            TokenGrantType::AuthorizationCode => self.exchange_authorization_code(request).await,
            TokenGrantType::RefreshToken => self.rotate_refresh_token(request).await,
        }
    }

    pub async fn authenticate(&self, bearer_token: &str) -> Result<AuthPrincipal, AuthError> {
        postgres::authenticate_bearer(&self.pool, bearer_token).await
    }

    pub async fn authenticate_web_session(
        &self,
        session_token: &str,
    ) -> Result<AuthPrincipal, AuthError> {
        postgres::authenticate_web_session(&self.pool, session_token).await
    }

    pub async fn web_admin_session(
        &self,
        principal: &AuthPrincipal,
    ) -> Result<WebAdminSession, AuthError> {
        if principal.credential_kind != CredentialKind::WebSession {
            return Err(AuthError::Unauthorized);
        }
        postgres::web_admin_session(&self.pool, principal).await
    }

    pub async fn revoke_session(
        &self,
        principal: &AuthPrincipal,
    ) -> Result<SessionRevoked, AuthError> {
        let mut tx = self.pool.begin().await?;
        let response = postgres::revoke_session(&mut tx, principal).await?;
        tx.commit().await?;
        Ok(response)
    }

    async fn exchange_authorization_code(
        &self,
        request: TokenRequest,
    ) -> Result<TokenResponse, AuthError> {
        let code = request.code.ok_or(AuthError::InvalidGrant)?;
        let redirect_uri = request.redirect_uri.ok_or(AuthError::InvalidGrant)?;
        let verifier = request.code_verifier.ok_or(AuthError::InvalidGrant)?;
        let actual_challenge = code_challenge(&verifier);
        let mut tx = self.pool.begin().await?;
        let response =
            postgres::exchange_authorization_code(&mut tx, &code, &redirect_uri, &actual_challenge)
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
        let response = postgres::rotate_refresh_token(&mut tx, &refresh_token).await?;
        tx.commit().await?;
        Ok(response)
    }

    fn redirect_allowed(&self, requested: &Url) -> bool {
        self.allowed_redirects
            .iter()
            .any(|allowed| redirect_matches(allowed, requested))
    }

    fn validate_admin_return_to(&self, value: &str) -> Result<(), AuthError> {
        if is_internal_admin_path(value) {
            return Ok(());
        }
        let return_url = Url::parse(value)
            .map_err(|_| AuthError::InvalidRequest("return_to is not trusted".to_owned()))?;
        if is_admin_path(return_url.path()) && self.redirect_allowed(&return_url) {
            Ok(())
        } else {
            Err(AuthError::InvalidRequest(
                "return_to is not trusted".to_owned(),
            ))
        }
    }
}

fn callback_completion(
    transaction: &LoginTransaction,
    code: Option<&str>,
    error: Option<(&str, Option<&str>)>,
    web_session_token: Option<String>,
) -> Result<OidcLoginCompletion, AuthError> {
    let redirect_uri = if transaction.flow == LoginFlow::WebAdminLogin {
        web_admin_redirect(&transaction.client_redirect_uri, error)?
    } else {
        callback_redirect(transaction, code, error)?
    };
    Ok(OidcLoginCompletion {
        redirect_uri,
        web_session_token,
    })
}

fn callback_redirect(
    transaction: &LoginTransaction,
    code: Option<&str>,
    error: Option<(&str, Option<&str>)>,
) -> Result<String, AuthError> {
    let mut url = Url::parse(&transaction.client_redirect_uri)
        .map_err(|parse_error| AuthError::InvalidRequest(parse_error.to_string()))?;
    let has_query_values = code.is_some()
        || error.is_some()
        || transaction.client_state.is_some()
        || transaction.return_to.is_some();
    if !has_query_values {
        return Ok(url.to_string());
    }
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

fn web_admin_redirect(
    return_to: &str,
    error: Option<(&str, Option<&str>)>,
) -> Result<String, AuthError> {
    let relative = is_internal_admin_path(return_to);
    let mut url = if relative {
        Url::parse("https://clumsies.invalid")
            .expect("static base URL is valid")
            .join(return_to)
            .map_err(|parse_error| AuthError::InvalidRequest(parse_error.to_string()))?
    } else {
        let url = Url::parse(return_to)
            .map_err(|parse_error| AuthError::InvalidRequest(parse_error.to_string()))?;
        if !is_admin_path(url.path()) {
            return Err(AuthError::InvalidRequest(
                "return_to is not an Admin path".to_owned(),
            ));
        }
        url
    };
    if let Some((error, description)) = error {
        let mut query = url.query_pairs_mut();
        query.append_pair("error", error);
        if let Some(description) = description {
            query.append_pair("error_description", description);
        }
    }
    let query = url
        .query()
        .map(|query| format!("?{query}"))
        .unwrap_or_default();
    if relative {
        Ok(format!("{}{query}", url.path()))
    } else {
        url.set_query(query.strip_prefix('?'));
        Ok(url.to_string())
    }
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

fn is_internal_admin_path(value: &str) -> bool {
    is_admin_path(value) && !value.starts_with("//")
}

fn is_admin_path(value: &str) -> bool {
    value == "/admin" || value.starts_with("/admin/")
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

fn client_kind(kind: ClientKind) -> &'static str {
    match kind {
        ClientKind::Desktop => "desktop",
        ClientKind::Cli => "cli",
        ClientKind::WebAdmin => "web_admin",
    }
}

fn optional_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn required_oidc_value(name: &str, value: Option<String>) -> Result<String, AuthError> {
    match value {
        Some(value) if !value.eq_ignore_ascii_case("null") => Ok(value),
        _ => Err(AuthError::Configuration(format!(
            "{name} is required and must not be null"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oidc_configuration_rejects_null_placeholders() {
        let error = required_oidc_value("CLUMSIES_OIDC_CLIENT_ID", Some("null".to_owned()))
            .expect_err("null must not be accepted as an OIDC credential");

        assert!(matches!(error, AuthError::Configuration(_)));
    }
}
