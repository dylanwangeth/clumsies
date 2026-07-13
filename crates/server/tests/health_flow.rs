mod common;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use server::http::{AdminHealth, HealthStatus, router};
use tower::ServiceExt;

#[tokio::test]
async fn health_after_migrations_reports_database_and_schema_ready() {
    let postgres = common::migrated_postgres().await;
    let app = router(postgres.pool.clone());
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/admin/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let health: AdminHealth = serde_json::from_slice(&body).unwrap();
    assert_eq!(health.status, HealthStatus::Down);
    assert_eq!(health.database.status, HealthStatus::Ok);
    assert_eq!(health.schema.status, HealthStatus::Ok);
    assert_eq!(health.commit_service.status, HealthStatus::Ok);
    assert_eq!(health.oidc.status, HealthStatus::Down);
}
