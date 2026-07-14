#![allow(dead_code)]

use std::sync::Arc;

use async_trait::async_trait;
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::header::{AUTHORIZATION, LOCATION};
use axum::http::{HeaderValue, Request, StatusCode};
use axum::middleware::{self, Next};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use openidconnect::PkceCodeChallenge;
use server::api::{TokenRequest, TokenResponse};
use server::auth::{AuthError, AuthService, OidcIdentity, OidcIdentityProvider};
use server::http::router_with_auth;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use testcontainers::ContainerAsync;
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::postgres::Postgres;
use tower::ServiceExt;
use url::Url;

pub struct TestPostgres {
    _container: ContainerAsync<Postgres>,
    pub pool: PgPool,
}

pub async fn migrated_postgres() -> TestPostgres {
    let container = Postgres::default().start().await.unwrap();
    let port = container.get_host_port_ipv4(5432).await.unwrap();
    let url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = PgPool::connect(&url).await.unwrap();

    server::db::run_migrations(&pool).await.unwrap();

    TestPostgres {
        _container: container,
        pool,
    }
}

pub async fn authenticated_router(pool: PgPool) -> (Router, TokenResponse) {
    authenticated_router_as(pool, "owner@example.com", "oidc-subject-owner", "Owner").await
}

pub async fn authenticated_router_as(
    pool: PgPool,
    email: &str,
    subject: &str,
    display_name: &str,
) -> (Router, TokenResponse) {
    let auth = AuthService::with_provider(
        pool.clone(),
        Arc::new(FakeOidcProvider {
            email: email.to_owned(),
            subject: subject.to_owned(),
            display_name: display_name.to_owned(),
        }),
        vec![Url::parse("http://127.0.0.1/callback").unwrap()],
    );
    let app = router_with_auth(pool, auth);
    let verifier = "test-verifier-abcdefghijklmnopqrstuvwxyz-0123456789";
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));

    let mut start_url = Url::parse("http://server.test/oauth2/authorization/oidc").unwrap();
    start_url
        .query_pairs_mut()
        .append_pair("client_kind", "desktop")
        .append_pair("redirect_uri", "http://127.0.0.1:49152/callback")
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", "desktop-state");
    let start_response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri_path(&start_url))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(start_response.status(), StatusCode::FOUND);
    let provider_url = Url::parse(
        start_response
            .headers()
            .get(LOCATION)
            .unwrap()
            .to_str()
            .unwrap(),
    )
    .unwrap();
    let provider_state = query_value(&provider_url, "state");

    let mut callback_url = Url::parse("http://server.test/login/oauth2/code/oidc").unwrap();
    callback_url
        .query_pairs_mut()
        .append_pair("code", "oidc-code")
        .append_pair("state", &provider_state);
    let callback_response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri_path(&callback_url))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(callback_response.status(), StatusCode::FOUND);
    let client_url = Url::parse(
        callback_response
            .headers()
            .get(LOCATION)
            .unwrap()
            .to_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(query_value(&client_url, "state"), "desktop-state");
    let code = query_value(&client_url, "code");
    let token_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/token")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&TokenRequest {
                        grant_type: server::api::TokenGrantType::AuthorizationCode,
                        code: Some(code),
                        redirect_uri: Some("http://127.0.0.1:49152/callback".to_owned()),
                        code_verifier: Some(verifier.to_owned()),
                        refresh_token: None,
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(token_response.status(), StatusCode::OK);
    let token: TokenResponse = serde_json::from_slice(
        &to_bytes(token_response.into_body(), usize::MAX)
            .await
            .unwrap(),
    )
    .unwrap();
    let bearer = HeaderValue::from_str(&format!("Bearer {}", token.access_token)).unwrap();
    let authenticated = app.layer(middleware::from_fn(
        move |mut request: Request<Body>, next: Next| {
            let bearer = bearer.clone();
            async move {
                request.headers_mut().insert(AUTHORIZATION, bearer);
                next.run(request).await
            }
        },
    ));
    (authenticated, token)
}

struct FakeOidcProvider {
    email: String,
    subject: String,
    display_name: String,
}

#[async_trait]
impl OidcIdentityProvider for FakeOidcProvider {
    fn authorization_url(
        &self,
        provider_state: &str,
        nonce: &str,
        _provider_pkce_challenge: PkceCodeChallenge,
        _login_hint: Option<&str>,
    ) -> Result<String, AuthError> {
        let mut url = Url::parse("https://accounts.example.test/authorize").unwrap();
        url.query_pairs_mut()
            .append_pair("state", provider_state)
            .append_pair("nonce", nonce);
        Ok(url.to_string())
    }

    async fn exchange_code(
        &self,
        code: &str,
        _nonce: &str,
        _provider_pkce_verifier: &str,
    ) -> Result<OidcIdentity, AuthError> {
        if code != "oidc-code" {
            return Err(AuthError::ProviderInvalid(
                "unexpected mock authorization code".to_owned(),
            ));
        }
        Ok(OidcIdentity {
            issuer: "https://identity.example.test".to_owned(),
            subject: self.subject.clone(),
            email: self.email.clone(),
            email_verified: true,
            display_name: Some(self.display_name.clone()),
            avatar_url: Some("https://images.example.test/avatar.png".to_owned()),
        })
    }
}

fn query_value(url: &Url, name: &str) -> String {
    url.query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
        .unwrap_or_else(|| panic!("missing {name} query parameter in {url}"))
}

fn uri_path(url: &Url) -> String {
    match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    }
}
