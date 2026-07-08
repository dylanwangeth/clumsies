use axum::Router;
use daemon::{DaemonConfig, DaemonState, router};
use tempfile::TempDir;

pub async fn test_daemon() -> (TempDir, DaemonState, Router) {
    let root = tempfile::tempdir().unwrap();
    let state = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .unwrap();
    let app = router(state.clone());
    (root, state, app)
}
