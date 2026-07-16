mod common;

use axum::body::{Body, to_bytes};
use axum::http::header::{COOKIE, HOST, IF_MATCH, LOCATION, ORIGIN, SET_COOKIE};
use axum::http::{Request, StatusCode};
use server::api::{AdminOrg, SessionRevoked, UpdateAdminOrgRequest, WebAdminSession};
use tower::ServiceExt;
use url::Url;

#[tokio::test]
async fn owner_web_session_enforces_csrf_origin_and_logout() {
    let postgres = common::migrated_postgres().await;
    common::initialize_installation(
        postgres.pool.clone(),
        "Clumsies Lab",
        "owner@example.com",
        "Owner",
        "web-owner-subject",
        "Default",
    )
    .await;
    let app = common::setup_router(
        postgres.pool.clone(),
        "owner@example.com",
        "web-owner-subject",
    );

    let start = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(
                    "/oauth2/authorization/oidc?client_kind=web_admin&return_to=%2Fadmin%2Fmembers",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::FOUND);
    let provider_url =
        Url::parse(start.headers().get(LOCATION).unwrap().to_str().unwrap()).unwrap();
    let provider_state = provider_url
        .query_pairs()
        .find(|(name, _)| name == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    let callback = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/login/oauth2/code/oidc?code=oidc-code&state={provider_state}"
                ))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(callback.status(), StatusCode::FOUND);
    assert_eq!(callback.headers().get(LOCATION).unwrap(), "/admin/members");
    let cookie = callback
        .headers()
        .get(SET_COOKIE)
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    assert!(cookie.starts_with("clumsies_admin_session="));

    let session_response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/admin/session")
                .header(COOKIE, &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(session_response.status(), StatusCode::OK);
    let session: WebAdminSession = decode_json(session_response).await;
    assert_eq!(session.user.email, "owner@example.com");

    let org_response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/admin/org")
                .header(COOKIE, &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let org: AdminOrg = decode_json(org_response).await;
    let update = UpdateAdminOrgRequest {
        name: Some("Clumsies Studio".to_owned()),
        allowed_email_domains: None,
    };

    let missing_csrf = mutate_org(
        app.clone(),
        &cookie,
        org.revision,
        &update,
        None,
        Some("http://server.test"),
    )
    .await;
    assert_eq!(missing_csrf.status(), StatusCode::FORBIDDEN);

    let missing_origin = mutate_org(
        app.clone(),
        &cookie,
        org.revision,
        &update,
        Some(&session.csrf_token),
        None,
    )
    .await;
    assert_eq!(missing_origin.status(), StatusCode::FORBIDDEN);

    let updated = mutate_org(
        app.clone(),
        &cookie,
        org.revision,
        &update,
        Some(&session.csrf_token),
        Some("http://server.test"),
    )
    .await;
    assert_eq!(updated.status(), StatusCode::OK);
    let updated: AdminOrg = decode_json(updated).await;
    assert_eq!(updated.name, "Clumsies Studio");

    let logout = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/admin/session")
                .header(COOKIE, &cookie)
                .header("x-csrf-token", &session.csrf_token)
                .header(ORIGIN, "http://server.test")
                .header(HOST, "server.test")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(logout.status(), StatusCode::OK);
    let cleared_cookie = logout.headers().get(SET_COOKIE).unwrap().to_str().unwrap();
    assert!(cleared_cookie.contains("Max-Age=0"));
    let revoked: SessionRevoked = decode_json(logout).await;
    assert!(revoked.revoked);

    let after_logout = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/admin/session")
                .header(COOKIE, cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(after_logout.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn organization_member_cannot_create_a_web_admin_session() {
    let postgres = common::migrated_postgres().await;
    common::initialize_installation(
        postgres.pool.clone(),
        "Clumsies Lab",
        "owner@example.com",
        "Owner",
        "owner-subject",
        "Default",
    )
    .await;
    sqlx::query(
        "INSERT INTO users (user_id, email, role, status)
         VALUES ('usr_member', 'member@example.com', 'member', 'active')",
    )
    .execute(&postgres.pool)
    .await
    .unwrap();
    let app = common::setup_router(
        postgres.pool.clone(),
        "member@example.com",
        "member-subject",
    );

    let start = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/oauth2/authorization/oidc?client_kind=web_admin&return_to=%2Fadmin")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let provider_url =
        Url::parse(start.headers().get(LOCATION).unwrap().to_str().unwrap()).unwrap();
    let provider_state = provider_url
        .query_pairs()
        .find(|(name, _)| name == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();
    let callback = app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/login/oauth2/code/oidc?code=oidc-code&state={provider_state}"
                ))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(callback.status(), StatusCode::FOUND);
    assert_eq!(
        callback.headers().get(LOCATION).unwrap(),
        "/admin?error=admin_access_required"
    );
    assert!(callback.headers().get(SET_COOKIE).is_none());
    let denied = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM audit_events
         WHERE action = 'auth.web_admin_access_denied' AND actor_user_id = 'usr_member'",
    )
    .fetch_one(&postgres.pool)
    .await
    .unwrap();
    assert_eq!(denied, 1);
}

async fn mutate_org(
    app: axum::Router,
    cookie: &str,
    revision: i64,
    body: &UpdateAdminOrgRequest,
    csrf: Option<&str>,
    origin: Option<&str>,
) -> axum::response::Response {
    let mut request = Request::builder()
        .method("PATCH")
        .uri("/api/v1/admin/org")
        .header("content-type", "application/json")
        .header(COOKIE, cookie)
        .header(IF_MATCH, revision.to_string())
        .header(HOST, "server.test");
    if let Some(csrf) = csrf {
        request = request.header("x-csrf-token", csrf);
    }
    if let Some(origin) = origin {
        request = request.header(ORIGIN, origin);
    }
    app.oneshot(
        request
            .body(Body::from(serde_json::to_vec(body).unwrap()))
            .unwrap(),
    )
    .await
    .unwrap()
}

async fn decode_json<T>(response: axum::response::Response) -> T
where
    T: serde::de::DeserializeOwned,
{
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}
