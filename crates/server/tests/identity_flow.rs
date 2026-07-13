mod common;

use server::repository::ServerRepository;

#[tokio::test]
async fn oidc_identity_survives_an_email_claim_change() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = repo
        .bootstrap_self_hosted("Acme Memory", "owner@example.com", Some("Owner"), "Default")
        .await
        .unwrap();

    let (_, first_token) = common::authenticated_router_as(
        postgres.pool.clone(),
        "owner@example.com",
        "stable-subject",
        "Owner",
    )
    .await;
    assert_eq!(first_token.user.user_id, bootstrap.user_id);

    let (_, second_token) = common::authenticated_router_as(
        postgres.pool.clone(),
        "owner-renamed@example.com",
        "stable-subject",
        "Owner",
    )
    .await;
    assert_eq!(second_token.user.user_id, bootstrap.user_id);
    assert_eq!(second_token.user.email, "owner@example.com");

    let identity_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM external_identities
         WHERE issuer = $1 AND subject = $2 AND user_id = $3",
    )
    .bind("https://identity.example.test")
    .bind("stable-subject")
    .bind(&bootstrap.user_id)
    .fetch_one(&postgres.pool)
    .await
    .unwrap();
    assert_eq!(identity_count, 1);
}
