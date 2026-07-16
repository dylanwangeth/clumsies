mod common;

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use serde::Serialize;
use server::api::{
    AccessTokenKind, AccessTokenListResponse, AdminOrg, AdminProject, AdminProjectListResponse,
    AuditEventListResponse, CreateMemberRequest, CreateProjectMemberRequest, CreateProjectRequest,
    DeleteResult, Member, MemberListResponse, MemberStatus, OidcProviderStatus, OrgRole,
    ProjectMember, ProjectMemberListResponse, ProjectRole, UpdateAdminOrgRequest,
    UpdateMemberRequest, UpdateProjectMemberRequest, UpdateProjectRequest,
};
use tower::ServiceExt;

#[tokio::test]
async fn owner_can_operate_the_complete_admin_contract() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Acme Memory",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Default",
    )
    .await;
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;

    let org: AdminOrg = get_json(app.clone(), "/api/v1/admin/org").await;
    assert_eq!(org.org_id, bootstrap.org_id);
    let provider: OidcProviderStatus =
        get_json(app.clone(), "/api/v1/admin/identity-provider").await;
    assert!(provider.configured);

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

    let project: AdminProject = post_json(
        app.clone(),
        "/api/v1/admin/projects",
        &CreateProjectRequest {
            name: "Research".to_owned(),
            description: Some("Shared research memory".to_owned()),
        },
    )
    .await;
    assert_eq!(project.name, "Research");
    assert_eq!(project.member_count, 1);
    let project: AdminProject = patch_json(
        app.clone(),
        &format!("/api/v1/admin/projects/{}", project.project_id),
        project.revision,
        &UpdateProjectRequest {
            name: Some("Research Lab".to_owned()),
            description: None,
        },
    )
    .await;
    assert_eq!(project.name, "Research Lab");

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

    let project_member: ProjectMember = post_json(
        app.clone(),
        &format!("/api/v1/admin/projects/{}/members", bootstrap.project_id),
        &CreateProjectMemberRequest {
            user_id: member.user_id.clone(),
            role: ProjectRole::Member,
        },
    )
    .await;
    assert_eq!(project_member.project_id, bootstrap.project_id);
    assert_eq!(project_member.user.user_id, member.user_id);
    assert_eq!(project_member.user.role, "admin");
    assert_eq!(project_member.role, ProjectRole::Member);

    let project_members: ProjectMemberListResponse = get_json(
        app.clone(),
        &format!(
            "/api/v1/admin/projects/{}/members?role=member",
            bootstrap.project_id
        ),
    )
    .await;
    assert_eq!(project_members.items, vec![project_member.clone()]);

    let project_member: ProjectMember = patch_without_revision(
        app.clone(),
        &format!(
            "/api/v1/admin/projects/{}/members/{}",
            bootstrap.project_id, member.user_id
        ),
        &UpdateProjectMemberRequest {
            role: ProjectRole::Admin,
        },
    )
    .await;
    assert_eq!(project_member.role, ProjectRole::Admin);

    let duplicate = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!(
                    "/api/v1/admin/projects/{}/members",
                    bootstrap.project_id
                ))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&CreateProjectMemberRequest {
                        user_id: member.user_id.clone(),
                        role: ProjectRole::Member,
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(duplicate.status(), StatusCode::CONFLICT);
    let duplicate_body: serde_json::Value = decode_json(duplicate).await;
    assert_eq!(duplicate_body["error"]["code"], "already_exists");

    let projects: AdminProjectListResponse = get_json(app.clone(), "/api/v1/admin/projects").await;
    assert_eq!(projects.items.len(), 2);
    let default_project = projects
        .items
        .iter()
        .find(|item| item.project_id == bootstrap.project_id)
        .unwrap();
    assert_eq!(default_project.member_count, 2);

    let first_page: AdminProjectListResponse =
        get_json(app.clone(), "/api/v1/admin/projects?limit=1").await;
    assert_eq!(first_page.items.len(), 1);
    assert!(first_page.page_info.has_more);
    let cursor = first_page
        .page_info
        .next_cursor
        .expect("a partial page must include the next cursor");
    let second_page: AdminProjectListResponse = get_json(
        app.clone(),
        &format!("/api/v1/admin/projects?limit=1&cursor={cursor}"),
    )
    .await;
    assert_eq!(second_page.items.len(), 1);
    assert!(!second_page.page_info.has_more);
    assert_ne!(
        first_page.items[0].project_id,
        second_page.items[0].project_id
    );

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

    let deleted_project_member: DeleteResult = delete_json(
        app.clone(),
        &format!(
            "/api/v1/admin/projects/{}/members/{}",
            bootstrap.project_id, member.user_id
        ),
        None,
    )
    .await;
    assert_eq!(deleted_project_member.id, member.user_id);

    let deleted_project: DeleteResult = delete_json(
        app.clone(),
        &format!("/api/v1/admin/projects/{}", project.project_id),
        Some(project.revision),
    )
    .await;
    assert_eq!(deleted_project.id, project.project_id);

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
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.project_member_created")
    );
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.project_member_deleted")
    );
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.project_created")
    );
    assert!(
        audit_events
            .items
            .iter()
            .any(|event| event.action == "admin.project_deleted")
    );

    let deleted_member: DeleteResult = delete_json(
        app,
        &format!("/api/v1/admin/members/{}", member.user_id),
        Some(member.revision),
    )
    .await;
    assert_eq!(deleted_member.id, member.user_id);
}

#[tokio::test]
async fn unknown_admin_project_is_not_disclosed() {
    let postgres = common::migrated_postgres().await;
    common::initialize_installation(
        postgres.pool.clone(),
        "Primary",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Primary",
    )
    .await;
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;

    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/admin/projects/prj_unknown/members")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_updates_reject_stale_revisions_and_preserve_the_last_owner() {
    let postgres = common::migrated_postgres().await;
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Primary",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Primary",
    )
    .await;
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;

    let project: AdminProject = post_json(
        app.clone(),
        "/api/v1/admin/projects",
        &CreateProjectRequest {
            name: "Stable".to_owned(),
            description: None,
        },
    )
    .await;
    let stale_project = json_response(
        app.clone(),
        "PATCH",
        &format!("/api/v1/admin/projects/{}", project.project_id),
        Some(project.revision + 1),
        &UpdateProjectRequest {
            name: Some("Overwritten".to_owned()),
            description: None,
        },
    )
    .await;
    assert_eq!(stale_project.status(), StatusCode::CONFLICT);
    let stale_body: serde_json::Value = decode_json(stale_project).await;
    assert_eq!(stale_body["error"]["code"], "version_conflict");
    let unchanged: AdminProject = get_json(
        app.clone(),
        &format!("/api/v1/admin/projects/{}", project.project_id),
    )
    .await;
    assert_eq!(unchanged.name, "Stable");

    let members: MemberListResponse = get_json(app.clone(), "/api/v1/admin/members").await;
    let owner = members
        .items
        .into_iter()
        .find(|member| member.user_id == bootstrap.user_id)
        .expect("bootstrap owner must be listed");
    let demotion = json_response(
        app.clone(),
        "PATCH",
        &format!("/api/v1/admin/members/{}", owner.user_id),
        Some(owner.revision),
        &UpdateMemberRequest {
            role: Some(OrgRole::Member),
            status: None,
        },
    )
    .await;
    assert_eq!(demotion.status(), StatusCode::BAD_REQUEST);
    let demotion_body: serde_json::Value = decode_json(demotion).await;
    assert_eq!(demotion_body["error"]["code"], "invalid_request");

    let self_disable = json_response(
        app.clone(),
        "PATCH",
        &format!("/api/v1/admin/members/{}", owner.user_id),
        Some(owner.revision),
        &UpdateMemberRequest {
            role: None,
            status: Some(MemberStatus::Disabled),
        },
    )
    .await;
    assert_eq!(self_disable.status(), StatusCode::BAD_REQUEST);
    let self_disable_body: serde_json::Value = decode_json(self_disable).await;
    assert_eq!(self_disable_body["error"]["code"], "invalid_request");

    let self_uninvite = json_response(
        app,
        "PATCH",
        &format!("/api/v1/admin/members/{}", owner.user_id),
        Some(owner.revision),
        &UpdateMemberRequest {
            role: None,
            status: Some(MemberStatus::Invited),
        },
    )
    .await;
    assert_eq!(self_uninvite.status(), StatusCode::BAD_REQUEST);
    let self_uninvite_body: serde_json::Value = decode_json(self_uninvite).await;
    assert_eq!(self_uninvite_body["error"]["code"], "invalid_request");
}

#[tokio::test]
async fn admin_lists_reject_invalid_pagination() {
    let postgres = common::migrated_postgres().await;
    common::initialize_installation(
        postgres.pool.clone(),
        "Primary",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Primary",
    )
    .await;
    let (app, _) = common::authenticated_router(postgres.pool.clone()).await;

    for uri in [
        "/api/v1/admin/projects?limit=0",
        "/api/v1/admin/projects?limit=201",
        "/api/v1/admin/projects?limit=not-a-number",
        "/api/v1/admin/projects?cursor=not-a-cursor",
        "/api/v1/admin/projects?cursor=-1",
        "/api/v1/admin/projects/prj_unknown/members?role=owner",
    ] {
        let response = app
            .clone()
            .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{uri}");
        let body: serde_json::Value = decode_json(response).await;
        assert_eq!(body["error"]["code"], "invalid_request", "{uri}");
    }
}

async fn get_json<T>(app: Router, uri: &str) -> T
where
    T: serde::de::DeserializeOwned,
{
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert!(response.status().is_success());
    decode_json(response).await
}

async fn post_json<TRequest, TResponse>(app: Router, uri: &str, request: &TRequest) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    let response = json_response(app, "POST", uri, None, request).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    decode_json(response).await
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

async fn patch_without_revision<TRequest, TResponse>(
    app: Router,
    uri: &str,
    request: &TRequest,
) -> TResponse
where
    TRequest: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
    request_json(app, "PATCH", uri, None, request).await
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
    let response = json_response(app, method, uri, revision, request).await;
    assert!(response.status().is_success());
    decode_json(response).await
}

async fn json_response<TRequest>(
    app: Router,
    method: &str,
    uri: &str,
    revision: Option<i64>,
    request: &TRequest,
) -> axum::response::Response
where
    TRequest: Serialize,
{
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(revision) = revision {
        builder = builder.header("if-match", revision.to_string());
    }
    app.oneshot(
        builder
            .body(Body::from(serde_json::to_vec(request).unwrap()))
            .unwrap(),
    )
    .await
    .unwrap()
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
