use std::env;
use std::net::SocketAddr;

use server::auth::AuthService;
use server::config::PublicOrigin;
use server::db::{DatabaseConfig, connect, run_migrations};
use server::http;
use server::installation::InstallationService;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let database_url = env::var("DATABASE_URL")
        .map_err(|_| "DATABASE_URL is required to start clumsies Server")?;
    let listen_addr =
        env::var("CLUMSIES_SERVER_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".to_owned());
    let listen_addr: SocketAddr = listen_addr.parse()?;
    let public_origin = PublicOrigin::from_env()?;

    let database_config = DatabaseConfig::from_url(database_url);
    let pool = connect(&database_config).await?;
    run_migrations(&pool).await?;
    let installation = InstallationService::from_env(pool.clone(), public_origin.secure_cookies())?;
    let auth = AuthService::from_env(pool.clone(), &public_origin).await?;

    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    axum::serve(
        listener,
        http::router_with_services(pool, auth, installation),
    )
    .await?;
    Ok(())
}
