use std::future::{self, Future, IntoFuture};
use std::time::Duration;

use crate::app::build_app;
use crate::auth::AuthService;
use crate::config::ServerConfig;
use crate::db::{DatabaseConfig, connect, run_migrations};
use crate::installation::InstallationService;
use crate::telemetry;

const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Debug, PartialEq, Eq)]
enum DrainResult<T> {
    Finished(T),
    TimedOut,
}

pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    telemetry::init()?;
    let ServerConfig {
        database_url,
        listen_addr,
        public_origin,
    } = ServerConfig::from_env()?;

    let pool = connect(&DatabaseConfig::from_url(database_url)).await?;
    run_migrations(&pool).await?;
    let installation = InstallationService::from_env(pool.clone(), public_origin.secure_cookies())?;
    let auth = AuthService::from_env(pool.clone(), &public_origin).await?;
    let app = build_app(pool, auth, installation);
    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    let listen_addr = listener.local_addr()?;

    tracing::info!(%listen_addr, "clumsies server started");
    let (graceful_shutdown, graceful_shutdown_received) = tokio::sync::oneshot::channel();
    let server = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            let _ = graceful_shutdown_received.await;
        })
        .into_future();
    if let DrainResult::Finished(result) = run_with_shutdown_limit(
        server,
        shutdown_signal(),
        graceful_shutdown,
        SHUTDOWN_DRAIN_TIMEOUT,
    )
    .await
    {
        result?;
    }
    tracing::info!("clumsies server stopped");
    Ok(())
}

async fn run_with_shutdown_limit<Server, Shutdown, Output>(
    server: Server,
    shutdown: Shutdown,
    graceful_shutdown: tokio::sync::oneshot::Sender<()>,
    drain_timeout: Duration,
) -> DrainResult<Output>
where
    Server: Future<Output = Output>,
    Shutdown: Future<Output = ()>,
{
    tokio::pin!(server);
    tokio::pin!(shutdown);

    tokio::select! {
        output = &mut server => DrainResult::Finished(output),
        _ = &mut shutdown => {
            tracing::info!(
                drain_timeout_seconds = drain_timeout.as_secs(),
                "shutdown signal received; draining active requests"
            );
            let _ = graceful_shutdown.send(());
            match tokio::time::timeout(drain_timeout, &mut server).await {
                Ok(output) => DrainResult::Finished(output),
                Err(_) => {
                    tracing::warn!(
                        drain_timeout_seconds = drain_timeout.as_secs(),
                        "graceful shutdown drain timed out; closing remaining connections"
                    );
                    DrainResult::TimedOut
                }
            }
        }
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    tokio::select! {
        _ = ctrl_c_signal() => {}
        _ = terminate_signal() => {}
    }

    #[cfg(not(unix))]
    ctrl_c_signal().await;
}

async fn ctrl_c_signal() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        tracing::error!(%error, "failed to listen for Ctrl-C");
        future::pending::<()>().await;
    }
}

#[cfg(unix)]
async fn terminate_signal() {
    let mut signal = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
    {
        Ok(signal) => signal,
        Err(error) => {
            tracing::error!(%error, "failed to listen for SIGTERM");
            future::pending::<()>().await;
            return;
        }
    };
    if signal.recv().await.is_none() {
        tracing::error!("SIGTERM signal stream closed unexpectedly");
        future::pending::<()>().await;
    }
}

#[cfg(test)]
mod tests {
    use tokio::time::Instant;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn shutdown_allows_requests_to_drain_within_deadline() {
        let (graceful_shutdown, graceful_shutdown_received) = tokio::sync::oneshot::channel();
        let server = async move {
            let _ = graceful_shutdown_received.await;
            tokio::time::sleep(Duration::from_secs(3)).await;
            "clean"
        };
        let started = Instant::now();

        let result = run_with_shutdown_limit(
            server,
            future::ready(()),
            graceful_shutdown,
            SHUTDOWN_DRAIN_TIMEOUT,
        )
        .await;

        assert_eq!(result, DrainResult::Finished("clean"));
        assert_eq!(started.elapsed(), Duration::from_secs(3));
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_stops_waiting_at_drain_deadline() {
        let (graceful_shutdown, graceful_shutdown_received) = tokio::sync::oneshot::channel();
        let server = async move {
            let _ = graceful_shutdown_received.await;
            future::pending::<()>().await;
        };
        let started = Instant::now();

        let result = run_with_shutdown_limit(
            server,
            future::ready(()),
            graceful_shutdown,
            SHUTDOWN_DRAIN_TIMEOUT,
        )
        .await;

        assert_eq!(result, DrainResult::TimedOut);
        assert_eq!(started.elapsed(), SHUTDOWN_DRAIN_TIMEOUT);
    }
}
