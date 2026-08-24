mod common;

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use server::api::{
    AcquireIssueClaimRequest, IssueClaimListResponse, ReleaseIssueClaimRequest,
    ReleaseIssueClaimResponse,
};
use time::{Duration, OffsetDateTime};
use tower::ServiceExt;

#[tokio::test]
async fn only_one_project_member_wins_a_live_issue_claim() {
    let postgres = common::migrated_postgres().await;
    let installation = common::initialize_installation(
        postgres.pool.clone(),
        "Clumsies Lab",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Default",
    )
    .await;
    let (owner_app, owner_token) = common::authenticated_router(postgres.pool.clone()).await;
    let (member_app, member_token) = common::authenticated_router_as(
        postgres.pool.clone(),
        "member@example.com",
        "oidc-subject-member",
        "Member",
    )
    .await;
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role)
         VALUES ($1, $2, 'member')",
    )
    .bind(&installation.project_id)
    .bind(&member_token.user.user_id)
    .execute(&postgres.pool)
    .await
    .unwrap();

    let project_id = installation.project_id;
    let lease_expires_at = OffsetDateTime::now_utc() + Duration::hours(1);
    let owner_request = claim_request(
        owner_app.clone(),
        &project_id,
        "issue_0123456789abcdef0123456789abcdef",
        "run_owner",
        lease_expires_at,
    );
    let member_request = claim_request(
        member_app.clone(),
        &project_id,
        "issue_0123456789abcdef0123456789abcdef",
        "run_member",
        lease_expires_at,
    );
    let (owner_response, member_response) = tokio::join!(owner_request, member_request);
    let statuses = [owner_response.status(), member_response.status()];
    assert_eq!(
        statuses
            .iter()
            .filter(|status| **status == StatusCode::OK)
            .count(),
        1
    );
    assert_eq!(
        statuses
            .iter()
            .filter(|status| **status == StatusCode::CONFLICT)
            .count(),
        1
    );

    let response = owner_app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/projects/{project_id}/issue-claims"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let claims: IssueClaimListResponse = decode_json(response).await;
    assert_eq!(claims.items.len(), 1);
    let claim = &claims.items[0];
    assert_eq!(claim.issue_id, "issue_0123456789abcdef0123456789abcdef");
    assert!(
        claim.claimant.user_id == owner_token.user.user_id
            || claim.claimant.user_id == member_token.user.user_id
    );

    let winner_app = if claim.run_id == "run_owner" {
        owner_app
    } else {
        member_app
    };
    let response = winner_app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!(
                    "/api/v1/projects/{project_id}/issues/issue_0123456789abcdef0123456789abcdef/claim"
                ))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_vec(&ReleaseIssueClaimRequest {
                        run_id: claim.run_id.clone(),
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let released: ReleaseIssueClaimResponse = decode_json(response).await;
    assert!(released.released);
}

fn claim_request(
    app: Router,
    project_id: &str,
    issue_id: &str,
    run_id: &str,
    lease_expires_at: OffsetDateTime,
) -> impl std::future::Future<Output = axum::response::Response> {
    let uri = format!("/api/v1/projects/{project_id}/issues/{issue_id}/claim");
    let body = serde_json::to_vec(&AcquireIssueClaimRequest {
        issue_key: "ISSUE-001".to_owned(),
        run_id: run_id.to_owned(),
        lease_expires_at,
    })
    .unwrap();
    async move {
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap()
    }
}

async fn decode_json<T: serde::de::DeserializeOwned>(response: axum::response::Response) -> T {
    serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap()
}
