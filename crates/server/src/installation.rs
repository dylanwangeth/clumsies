use std::collections::BTreeSet;
use std::env;

use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use subtle::ConstantTimeEq;
use thiserror::Error;
use time::{Duration, OffsetDateTime};
use url::Url;
use uuid::Uuid;

use crate::api::{
    CreateSetupSessionResponse, InstallationState, ReplaceSetupConfigurationRequest,
    SetupConfiguration, SetupSessionStatus, SetupStatus,
};
use crate::auth::OidcIdentity;

const SETUP_SESSION_TTL: Duration = Duration::minutes(15);
const MINIMUM_SETUP_CODE_LENGTH: usize = 32;
const INSTALLATION_ID: &str = "default";
const LOCAL_SETUP_COOKIE_NAME: &str = "clumsies_setup_session";
const SECURE_SETUP_COOKIE_NAME: &str = "__Host-clumsies_setup_session";

#[derive(Clone)]
pub struct InstallationService {
    pool: PgPool,
    setup_code_hash: Option<[u8; 32]>,
    secure_cookie: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SetupSessionCredentials {
    pub session: CreateSetupSessionResponse,
    pub token: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InitializedInstallation {
    pub org_id: String,
    pub user_id: String,
    pub project_id: String,
}

impl InstallationService {
    pub fn from_env(pool: PgPool) -> Result<Self, InstallationError> {
        let setup_code = optional_env("CLUMSIES_SETUP_CODE");
        let secure_cookie = match optional_env("CLUMSIES_OIDC_CALLBACK_URL") {
            Some(callback_url) => {
                let callback_url = Url::parse(&callback_url).map_err(|error| {
                    InstallationError::Configuration(format!(
                        "CLUMSIES_OIDC_CALLBACK_URL is invalid: {error}"
                    ))
                })?;
                callback_url.scheme() == "https"
            }
            None => true,
        };
        Self::new(pool, setup_code.as_deref(), secure_cookie)
    }

    pub fn new(
        pool: PgPool,
        setup_code: Option<&str>,
        secure_cookie: bool,
    ) -> Result<Self, InstallationError> {
        let setup_code_hash = setup_code
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| {
                if value.len() < MINIMUM_SETUP_CODE_LENGTH {
                    return Err(InstallationError::Configuration(format!(
                        "CLUMSIES_SETUP_CODE must contain at least {MINIMUM_SETUP_CODE_LENGTH} characters"
                    )));
                }
                Ok(secret_hash(value))
            })
            .transpose()?;
        Ok(Self {
            pool,
            setup_code_hash,
            secure_cookie,
        })
    }

    pub fn setup_code_configured(&self) -> bool {
        self.setup_code_hash.is_some()
    }

    pub fn cookie_name(&self) -> &'static str {
        if self.secure_cookie {
            SECURE_SETUP_COOKIE_NAME
        } else {
            LOCAL_SETUP_COOKIE_NAME
        }
    }

    pub fn cookie_secure(&self) -> bool {
        self.secure_cookie
    }

    pub async fn require_initialized(&self) -> Result<(), InstallationError> {
        if self.installation_state().await? == InstallationState::Initialized {
            Ok(())
        } else {
            Err(InstallationError::SetupRequired)
        }
    }

    pub async fn status(
        &self,
        session_token: Option<&str>,
        oidc_configured: bool,
    ) -> Result<SetupStatus, InstallationError> {
        let state = self.installation_state().await?;
        let session = if state == InstallationState::SetupRequired {
            match session_token {
                Some(token) => self.active_session_status(token).await?,
                None => None,
            }
        } else {
            None
        };
        Ok(SetupStatus {
            state,
            setup_code_configured: self.setup_code_configured(),
            oidc_configured,
            session,
        })
    }

    pub async fn create_session(
        &self,
        setup_code: &str,
    ) -> Result<SetupSessionCredentials, InstallationError> {
        let expected_hash = self
            .setup_code_hash
            .as_ref()
            .ok_or(InstallationError::SetupUnavailable)?;
        let actual_hash = secret_hash(setup_code.trim());
        if expected_hash.ct_eq(&actual_hash).unwrap_u8() != 1 {
            return Err(InstallationError::InvalidSetupCode);
        }

        let session_id = prefixed_id("setup");
        let token = random_token();
        let csrf_token = random_token();
        let expires_at = OffsetDateTime::now_utc() + SETUP_SESSION_TTL;
        let mut tx = self.pool.begin().await?;
        require_setup_required(&mut tx, false).await?;
        sqlx::query(
            "INSERT INTO setup_sessions (
                session_id, token_hash, csrf_token_hash, expires_at
             ) VALUES ($1, $2, $3, $4)",
        )
        .bind(&session_id)
        .bind(secret_hash_hex(&token))
        .bind(secret_hash_hex(&csrf_token))
        .bind(expires_at)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(SetupSessionCredentials {
            session: CreateSetupSessionResponse {
                expires_at,
                csrf_token,
            },
            token,
        })
    }

    pub async fn replace_configuration(
        &self,
        session_token: &str,
        csrf_token: &str,
        request: ReplaceSetupConfigurationRequest,
    ) -> Result<SetupConfiguration, InstallationError> {
        let configuration = normalize_configuration(request)?;
        let mut tx = self.pool.begin().await?;
        require_setup_required(&mut tx, false).await?;
        let session_id =
            require_active_session(&mut tx, session_token, Some(csrf_token), false).await?;
        sqlx::query(
            "UPDATE setup_sessions
             SET org_name = $2,
                 default_project_name = $3,
                 allowed_email_domains = $4,
                 configuration_saved_at = now(),
                 updated_at = now()
             WHERE session_id = $1",
        )
        .bind(session_id)
        .bind(&configuration.org_name)
        .bind(&configuration.default_project_name)
        .bind(&configuration.allowed_email_domains)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(configuration)
    }

    pub async fn authorize_oidc(
        &self,
        session_token: &str,
        csrf_token: &str,
    ) -> Result<String, InstallationError> {
        let mut tx = self.pool.begin().await?;
        require_setup_required(&mut tx, false).await?;
        let session_id =
            require_active_session(&mut tx, session_token, Some(csrf_token), true).await?;
        tx.commit().await?;
        Ok(session_id)
    }

    pub async fn initialize_with_oidc(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        session_id: &str,
        identity: &OidcIdentity,
    ) -> Result<InitializedInstallation, InstallationError> {
        require_setup_required(tx, true).await?;
        let session = sqlx::query(
            "SELECT org_name, default_project_name, allowed_email_domains
             FROM setup_sessions
             WHERE session_id = $1
               AND consumed_at IS NULL
               AND expires_at > now()
               AND configuration_saved_at IS NOT NULL
             FOR UPDATE",
        )
        .bind(session_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(InstallationError::ConfigurationRequired)?;
        let org_name: String = session.try_get("org_name")?;
        let project_name: String = session.try_get("default_project_name")?;
        let allowed_email_domains: Vec<String> = session.try_get("allowed_email_domains")?;
        enforce_email_domain(&identity.email, &allowed_email_domains)?;
        let owner_email = normalize_email(&identity.email)?;

        let org_id = prefixed_id("org");
        let user_id = prefixed_id("usr");
        let project_id = prefixed_id("prj");
        sqlx::query(
            "INSERT INTO orgs (org_id, name, allowed_email_domains)
             VALUES ($1, $2, $3)",
        )
        .bind(&org_id)
        .bind(org_name)
        .bind(allowed_email_domains)
        .execute(&mut **tx)
        .await?;
        insert_ref(tx, "org", &org_id, None).await?;
        sqlx::query(
            "INSERT INTO users (
                user_id, email, display_name, avatar_url, role, status
             ) VALUES ($1, $2, $3, $4, 'owner', 'active')",
        )
        .bind(&user_id)
        .bind(owner_email)
        .bind(identity.display_name.as_deref())
        .bind(identity.avatar_url.as_deref())
        .execute(&mut **tx)
        .await?;
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
        sqlx::query(
            "INSERT INTO projects (project_id, org_id, name)
             VALUES ($1, $2, $3)",
        )
        .bind(&project_id)
        .bind(&org_id)
        .bind(project_name)
        .execute(&mut **tx)
        .await?;
        insert_ref(tx, "project", &org_id, Some(&project_id)).await?;
        sqlx::query("INSERT INTO project_org_selection_states (project_id) VALUES ($1)")
            .bind(&project_id)
            .execute(&mut **tx)
            .await?;
        sqlx::query(
            "INSERT INTO project_members (project_id, user_id, role)
             VALUES ($1, $2, 'admin')",
        )
        .bind(&project_id)
        .bind(&user_id)
        .execute(&mut **tx)
        .await?;
        sqlx::query(
            "UPDATE server_installations
             SET state = 'initialized', org_id = $2, initialized_at = now(), updated_at = now()
             WHERE installation_id = $1 AND state = 'setup_required'",
        )
        .bind(INSTALLATION_ID)
        .bind(&org_id)
        .execute(&mut **tx)
        .await?;
        sqlx::query(
            "UPDATE setup_sessions
             SET consumed_at = now(), updated_at = now()
             WHERE consumed_at IS NULL",
        )
        .execute(&mut **tx)
        .await?;
        sqlx::query(
            "INSERT INTO audit_events (
                event_id, org_id, actor_user_id, action, target_type, target_id
             ) VALUES ($1, $2, $3, 'installation.completed', 'org', $2)",
        )
        .bind(prefixed_id("audit"))
        .bind(&org_id)
        .bind(&user_id)
        .execute(&mut **tx)
        .await?;
        Ok(InitializedInstallation {
            org_id,
            user_id,
            project_id,
        })
    }

    async fn installation_state(&self) -> Result<InstallationState, InstallationError> {
        let state = sqlx::query_scalar::<_, String>(
            "SELECT state FROM server_installations WHERE installation_id = $1",
        )
        .bind(INSTALLATION_ID)
        .fetch_one(&self.pool)
        .await?;
        installation_state(&state)
    }

    async fn active_session_status(
        &self,
        token: &str,
    ) -> Result<Option<SetupSessionStatus>, InstallationError> {
        let row = sqlx::query(
            "SELECT org_name, default_project_name, allowed_email_domains,
                    configuration_saved_at, expires_at
             FROM setup_sessions
             WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()",
        )
        .bind(secret_hash_hex(token))
        .fetch_optional(&self.pool)
        .await?;
        row.map(|row| {
            let configuration = if row
                .try_get::<Option<OffsetDateTime>, _>("configuration_saved_at")?
                .is_some()
            {
                Some(SetupConfiguration {
                    org_name: row.try_get("org_name")?,
                    default_project_name: row.try_get("default_project_name")?,
                    allowed_email_domains: row.try_get("allowed_email_domains")?,
                })
            } else {
                None
            };
            Ok(SetupSessionStatus {
                expires_at: row.try_get("expires_at")?,
                configuration,
            })
        })
        .transpose()
    }
}

async fn require_setup_required(
    tx: &mut Transaction<'_, Postgres>,
    exclusive: bool,
) -> Result<(), InstallationError> {
    let state = if exclusive {
        sqlx::query_scalar::<_, String>(
            "SELECT state FROM server_installations
             WHERE installation_id = $1
             FOR UPDATE",
        )
        .bind(INSTALLATION_ID)
        .fetch_one(&mut **tx)
        .await?
    } else {
        sqlx::query_scalar::<_, String>(
            "SELECT state FROM server_installations
             WHERE installation_id = $1
             FOR SHARE",
        )
        .bind(INSTALLATION_ID)
        .fetch_one(&mut **tx)
        .await?
    };
    if installation_state(&state)? == InstallationState::SetupRequired {
        Ok(())
    } else {
        Err(InstallationError::Locked)
    }
}

async fn require_active_session(
    tx: &mut Transaction<'_, Postgres>,
    session_token: &str,
    csrf_token: Option<&str>,
    require_configuration: bool,
) -> Result<String, InstallationError> {
    let row = sqlx::query(
        "SELECT session_id, csrf_token_hash, configuration_saved_at
         FROM setup_sessions
         WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()
         FOR UPDATE",
    )
    .bind(secret_hash_hex(session_token))
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(InstallationError::InvalidSession)?;
    if let Some(csrf_token) = csrf_token {
        let expected_hash = hex::decode(row.try_get::<String, _>("csrf_token_hash")?)
            .map_err(|_| InstallationError::CorruptSession)?;
        let actual_hash = secret_hash(csrf_token);
        if expected_hash.as_slice().ct_eq(&actual_hash).unwrap_u8() != 1 {
            return Err(InstallationError::CsrfMismatch);
        }
    }
    if require_configuration
        && row
            .try_get::<Option<OffsetDateTime>, _>("configuration_saved_at")?
            .is_none()
    {
        return Err(InstallationError::ConfigurationRequired);
    }
    Ok(row.try_get("session_id")?)
}

async fn insert_ref(
    tx: &mut Transaction<'_, Postgres>,
    scope: &str,
    org_id: &str,
    project_id: Option<&str>,
) -> Result<(), InstallationError> {
    sqlx::query(
        "INSERT INTO refs (ref_id, ref_name, scope, org_id, project_id)
         VALUES ($1, 'refs/heads/main', $2, $3, $4)",
    )
    .bind(prefixed_id("ref"))
    .bind(scope)
    .bind(org_id)
    .bind(project_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

fn normalize_configuration(
    request: ReplaceSetupConfigurationRequest,
) -> Result<SetupConfiguration, InstallationError> {
    Ok(SetupConfiguration {
        org_name: normalize_name(&request.org_name, "organization")?,
        default_project_name: normalize_name(&request.default_project_name, "project")?,
        allowed_email_domains: normalize_email_domains(request.allowed_email_domains)?,
    })
}

fn normalize_name(value: &str, field: &str) -> Result<String, InstallationError> {
    let value = value.trim();
    if value.is_empty() || value.chars().count() > 120 || value.chars().any(char::is_control) {
        return Err(InstallationError::InvalidRequest(format!(
            "{field} name must contain between 1 and 120 visible characters"
        )));
    }
    Ok(value.to_owned())
}

fn normalize_email(email: &str) -> Result<String, InstallationError> {
    let email = email.trim().to_ascii_lowercase();
    let Some((local, domain)) = email.split_once('@') else {
        return Err(InstallationError::InvalidOwnerIdentity);
    };
    if local.is_empty() || domain.is_empty() || domain.contains('@') || !valid_domain(domain) {
        return Err(InstallationError::InvalidOwnerIdentity);
    }
    Ok(email)
}

fn normalize_email_domains(domains: Vec<String>) -> Result<Vec<String>, InstallationError> {
    let mut normalized = BTreeSet::new();
    for domain in domains {
        let domain = domain.trim().trim_start_matches('@').to_ascii_lowercase();
        if !valid_domain(&domain) {
            return Err(InstallationError::InvalidRequest(format!(
                "invalid allowed email domain: {domain}"
            )));
        }
        normalized.insert(domain);
    }
    Ok(normalized.into_iter().collect())
}

fn valid_domain(domain: &str) -> bool {
    !domain.is_empty()
        && domain.len() <= 253
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn enforce_email_domain(email: &str, allowed_domains: &[String]) -> Result<(), InstallationError> {
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
        Err(InstallationError::OwnerDomainNotAllowed)
    }
}

fn installation_state(value: &str) -> Result<InstallationState, InstallationError> {
    match value {
        "setup_required" => Ok(InstallationState::SetupRequired),
        "initialized" => Ok(InstallationState::Initialized),
        _ => Err(InstallationError::CorruptInstallation),
    }
}

fn optional_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn secret_hash(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

fn secret_hash_hex(value: &str) -> String {
    hex::encode(secret_hash(value))
}

fn random_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn prefixed_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

#[derive(Debug, Error)]
pub enum InstallationError {
    #[error("Server setup must be completed before product login")]
    SetupRequired,
    #[error("Server setup is permanently locked")]
    Locked,
    #[error("Server setup is unavailable because CLUMSIES_SETUP_CODE is not configured")]
    SetupUnavailable,
    #[error("setup code is invalid")]
    InvalidSetupCode,
    #[error("setup session is invalid or expired")]
    InvalidSession,
    #[error("setup CSRF token is invalid")]
    CsrfMismatch,
    #[error("setup configuration must be saved before owner login")]
    ConfigurationRequired,
    #[error("the OIDC owner identity does not match an allowed email domain")]
    OwnerDomainNotAllowed,
    #[error("the OIDC owner identity contains an invalid email address")]
    InvalidOwnerIdentity,
    #[error("invalid setup request: {0}")]
    InvalidRequest(String),
    #[error("invalid Server setup configuration: {0}")]
    Configuration(String),
    #[error("stored setup session is corrupt")]
    CorruptSession,
    #[error("stored Server installation state is corrupt")]
    CorruptInstallation,
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
}

impl InstallationError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::SetupRequired => "setup_required",
            Self::Locked => "setup_locked",
            Self::SetupUnavailable => "setup_unavailable",
            Self::InvalidSetupCode => "setup_code_invalid",
            Self::InvalidSession => "setup_session_invalid",
            Self::CsrfMismatch => "setup_csrf_invalid",
            Self::ConfigurationRequired => "setup_configuration_required",
            Self::OwnerDomainNotAllowed => "setup_owner_domain_not_allowed",
            Self::InvalidOwnerIdentity => "setup_owner_identity_invalid",
            Self::InvalidRequest(_) => "validation_failed",
            Self::Configuration(_) => "setup_configuration_invalid",
            Self::CorruptSession | Self::CorruptInstallation | Self::Sqlx(_) => "internal_error",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_configuration_normalizes_names_and_domains() {
        let configuration = normalize_configuration(ReplaceSetupConfigurationRequest {
            org_name: "  Clumsies Lab  ".to_owned(),
            default_project_name: "  Default  ".to_owned(),
            allowed_email_domains: vec!["@Example.COM".to_owned(), "example.com".to_owned()],
        })
        .unwrap();
        assert_eq!(configuration.org_name, "Clumsies Lab");
        assert_eq!(configuration.default_project_name, "Default");
        assert_eq!(configuration.allowed_email_domains, ["example.com"]);
    }

    #[tokio::test]
    async fn short_setup_code_is_rejected() {
        let pool = PgPool::connect_lazy("postgres://clumsies@127.0.0.1/clumsies").unwrap();
        let result = InstallationService::new(pool, Some("too-short"), false);
        assert!(matches!(result, Err(InstallationError::Configuration(_))));
    }
}
