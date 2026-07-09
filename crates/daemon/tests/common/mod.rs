use daemon::{DaemonConfig, DaemonIpcService, DaemonState};
use tempfile::TempDir;

pub async fn test_daemon() -> (TempDir, DaemonState, DaemonIpcService) {
    let root = tempfile::tempdir().unwrap();
    let state = DaemonState::initialize(DaemonConfig::for_root(root.path()))
        .await
        .unwrap();
    let service = DaemonIpcService::new(state.clone());
    (root, state, service)
}
