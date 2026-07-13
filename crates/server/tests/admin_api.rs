mod common;

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use serde::Serialize;
use server::api::{
    AccessTokenKind, AccessTokenListResponse, AdminOrg, AdminProjectListResponse,
    AuditEventListResponse, CreateMemberRequest, DeleteResult, Member, MemberListResponse,
    MemberStatus, OrgRole, UpdateAdminOrgRequest, UpdateMemberRequest,
};
use server::repository::ServerRepository;
use tower::ServiceExt;

#[tokio::test]
async fn owner_can_operate_the_complete_admin_contract() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted("Acme Memory", "owner@example.com", Some("Owner"), "Default")
        .await
        .unwrap();
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;

    let org: AdminOrg = get_json(app.clone(), "/api/v1/admin/org").await;
    assert_eq!(org.org_id, bootstrap.org_id);

    let org: AdminOrg = patch_json(
        app.clone(),
        "/api/v1/admin/org",
        org.revision,
        &UpdateAdminOrgRequest {
            name: Some("Acme Knowledge".to_owned()),
            allowed_email_domains: Some(vec!["EXAMPLE.COM".to_owned()]),
        },
    )
    .await;
    assert_eq!(org.name, "Acme Knowledge");
    assert_eq!(org.allowed_email_domains, vec!["example.com"]);

    let member: Member = post_json(
        app.clone(),
        "/api/v1/admin/members",
        &CreateMemberRequest {
            email: "member@example.com".to_owned(),
            role: OrgRole::Member,
        },
    )
    .await;
    assert_eq!(member.status, MemberStatus::Invited);

    let members: MemberListResponse = get_json(app.clone(), "/api/v1/admin/members").await;
    assert_eq!(members.items.len(), 2);
    assert!(
        members
            .items
            .iter()
            .find(|item| item.user_id == bootstrap.user_id)
            .unwrap()
            .external_identity_bound
    );
    assert!(
        !members
            .items
            .iter()
            .find(|item| item.user_id == member.user_id)
            .unwrap()
            .external_identity_bound
    );

    let member: Member = patch_json(
        app.clone(),
        &format!("/api/v1/admin/members/{}", member.user_id),
        member.revision,
        &UpdateMemberRequest {
            role: Some(OrgRole::Admin),
            status: Some(MemberStatus::Active),
        },
    )
    .await;
    assert_eq!(member.role, OrgRole::Admin);
    assert_eq!(member.status, MemberStatus::Active);

    let projects: AdminProjectListResponse = get_json(app.clone(), "/api/v1/admin/projects").await;
    assert_eq!(projects.items.len(), 1);
    assert_eq!(projects.items[0].project_id, bootstrap.project_id);
    assert_eq!(projects.items[0].member_count, 1);

    let tokens: AccessTokenListResponse = get_json(app.clone(), "/api/v1/admin/tokens").await;
    let refresh_token_id = tokens
        .items
        .iter()
        .find(|token| token.kind == AccessTokenKind::Refresh)
        .expect("OIDC login should issue a refresh token")
        .token_id
        .clone();
    let deleted_token: DeleteResult = delete_json(
        app.clone(),
        &format!("/api/v1/admin/tokens/{refresh_token_id}"),
        None,
    )
    .await;
    assert_eq!(deleted_token.id, refresh_token_id);

    let audit_events: AuditEventListResponse =
        get_json(app.clone(), "/api/v1/admin/audit-events").await;
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.org_updated")
    );
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.token_revoked")
    );

    let deleted_member: DeleteResult = delete_json(
        app,
        &format!("/api/v1/admin/members/{}", member.user_id),
        Some(member.revision),
    )
    .await;
    assert_eq!(deleted_member.id, member.user_id);
}

async fn get_json<T>(app: Router, uri: &str) -> T
where
    T: serde::de::DeserializeOwned,
{
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn post_json<TRequest, TResponse>(app: Router, uri: &str, request: &TRequest) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    request_json(app, "POST", uri, None, request).await
}

async fn patch_json<TRequest, TResponse>(
    app: Router,
    uri: &str,
    revision: i64,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    request_json(app, "PATCH", uri, Some(revision), request).await
}

async fn request_json<TRequest, TResponse>(
    app: Router,
    method: &str,
    uri: &str,
    revision: Option<i64>,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(revision) = revision {
        builder = builder.header("if-match", revision.to_string());
    }
    let response = app
        .oneshot(
            builder
                .body(Body::from(serde_json::to_vec(request).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn delete_json<T>(app: Router, uri: &str, revision: Option<i64>) -> T
where
    T: serde::de::DeserializeOwned,
{
    let mut builder = Request::builder().method("DELETE").uri(uri);
    if let Some(revision) = revision {
        builder = builder.header("if-match", revision.to_string());
    }
    let response = app
        .oneshot(builder.body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    decode_json(response).await
}

async fn decode_json<T>(response: axum::response::Response) -> T
where
    T: serde::de::DeserializeOwned,
{
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}
