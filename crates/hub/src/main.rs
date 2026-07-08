use std::env;
use std::net::SocketAddr;

use hub::db::{DatabaseConfig, connect, run_migrations};
use hub::http;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let database_url =
        env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is required to start clumsies Hub")?;
    let listen_addr = env::var("CLUMSIES_HUB_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".to_owned());
    let listen_addr: SocketAddr = listen_addr.parse()?;

    let database_config = DatabaseConfig::from_url(database_url);
    let pool = connect(&database_config).await?;
    run_migrations(&pool).await?;

    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    axum::serve(listener, http::router(pool)).await?;
    Ok(())
}
