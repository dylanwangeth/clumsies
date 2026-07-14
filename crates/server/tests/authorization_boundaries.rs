mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use server::api::{
    CreateDraftRequest, CreateProjectRequest, DraftDetail, DraftResourceKind, DraftResourceRef,
    ResourceScope,
};
use server::repository::ServerRepository;
use tower::ServiceExt;

#[tokio::test]
async fn bearer_identity_enforces_personal_and_project_boundaries() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted(
            "Acme Memory",
            "owner@example.com",
            Some("Owner"),
            "Shared Project",
        )
        .await
        .unwrap();
    let member_id = repo
        .create_user("member@example.com", Some("Member"), "member")
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role) VALUES ($1, $2, 'member')",
    )
    .bind(&bootstrap.project_id)
    .bind(&member_id)
    .execute(&postgres.pool)
    .await
    .unwrap();
    let private_project_id = repo
        .create_project(&bootstrap.org_id, "Owner Only", "")
        .await
        .unwrap();

    let (owner_app, _) = common::authenticated_router(postgres.pool.clone()).await;
    let draft_response = owner_app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/drafts")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&CreateDraftRequest {
                        daemon_installation_id: "daemon_owner".to_owned(),
                        project_id: bootstrap.project_id.clone(),
                        base_commit_id: None,
                        title: "Owner draft".to_owned(),
                        description: None,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Project,
                            kind: DraftResourceKind::Context,
                            id: None,
                            path: Some("context/private.md".to_owned()),
                        },
                        operations: Vec::new(),
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(draft_response.status(), StatusCode::OK);
    let owner_draft: DraftDetail = serde_json::from_slice(
        &to_bytes(draft_response.into_body(), usize::MAX)
            .await
            .unwrap(),
    )
    .unwrap();

    let (member_app, _) = common::authenticated_router_as(
        postgres.pool.clone(),
        "member@example.com",
        "oidc-subject-member",
        "Member",
    )
    .await;

    let shared_project = member_app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/projects/{}", bootstrap.project_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(shared_project.status(), StatusCode::OK);

    let private_project = member_app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/projects/{private_project_id}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(private_project.status(), StatusCode::NOT_FOUND);

    let private_draft = member_app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/drafts/{}", owner_draft.draft.draft_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(private_draft.status(), StatusCode::NOT_FOUND);

    let org_draft = member_app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/drafts")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&CreateDraftRequest {
                        daemon_installation_id: "daemon_member".to_owned(),
                        project_id: bootstrap.project_id.clone(),
                        base_commit_id: None,
                        title: "Forbidden org draft".to_owned(),
                        description: None,
                        resource: DraftResourceRef {
                            scope: ResourceScope::Org,
                            kind: DraftResourceKind::Context,
                            id: None,
                            path: Some("context/org.md".to_owned()),
                        },
                        operations: Vec::new(),
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(org_draft.status(), StatusCode::FORBIDDEN);

    let create_project = member_app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/projects")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&CreateProjectRequest {
                        name: "Forbidden".to_owned(),
                        description: None,
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_project.status(), StatusCode::FORBIDDEN);

    let administer_project_members = member_app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/admin/projects/{}/members",
                    bootstrap.project_id
                ))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(administer_project_members.status(), StatusCode::FORBIDDEN);
}
