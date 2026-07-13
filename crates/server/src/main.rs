use std::env;
use std::net::SocketAddr;

use server::auth::AuthService;
use server::db::{DatabaseConfig, connect, run_migrations};
use server::http;
use server::repository::ServerRepository;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let database_url = env::var("DATABASE_URL")
        .map_err(|_| "DATABASE_URL is required to start clumsies Server")?;
    let listen_addr =
        env::var("CLUMSIES_SERVER_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".to_owned());
    let listen_addr: SocketAddr = listen_addr.parse()?;

    let database_config = DatabaseConfig::from_url(database_url);
    let pool = connect(&database_config).await?;
    run_migrations(&pool).await?;
    if let Ok(owner_email) = env::var("CLUMSIES_BOOTSTRAP_OWNER_EMAIL") {
        let org_name =
            env::var("CLUMSIES_BOOTSTRAP_ORG_NAME").unwrap_or_else(|_| "Clumsies".to_owned());
        let owner_name = env::var("CLUMSIES_BOOTSTRAP_OWNER_NAME").ok();
        let project_name =
            env::var("CLUMSIES_BOOTSTRAP_PROJECT_NAME").unwrap_or_else(|_| "Default".to_owned());
        ServerRepository::new(pool.clone())
            .bootstrap_self_hosted(
                &org_name,
                &owner_email,
                owner_name.as_deref(),
                &project_name,
            )
            .await?;
    }
    let auth = AuthService::from_env(pool.clone()).await?;

    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    axum::serve(listener, http::router_with_auth(pool, auth)).await?;
    Ok(())
}
