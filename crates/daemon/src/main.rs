use daemon::{
    DaemonConfig, DaemonState, remove_daemon_endpoint_file, router, write_daemon_endpoint_file,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = DaemonConfig::from_env()?;
    let listen_addr = config.listen_addr;
    let state = DaemonState::initialize(config.clone()).await?;
    let _sync_worker = state.start_sync_worker();
    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    let actual_addr = listener.local_addr()?;
    let endpoint =
        write_daemon_endpoint_file(&config, actual_addr, state.daemon_installation_id())?;

    eprintln!("clumsiesd listening on {}", endpoint.endpoint);

    let serve_result = axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await;
    let cleanup_result = remove_daemon_endpoint_file(&config);
    serve_result?;
    cleanup_result?;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
