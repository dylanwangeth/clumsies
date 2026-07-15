use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use daemon::{
    CredentialStore, CredentialStoreError, DaemonConfig, DaemonIpcService, DaemonState,
    ServerCredentials,
};
use tempfile::TempDir;

#[derive(Clone, Default)]
pub struct TestCredentialStore {
    credentials: Arc<Mutex<Option<ServerCredentials>>>,
    fail_writes: Arc<AtomicBool>,
}

impl TestCredentialStore {
    pub fn new(credentials: Option<ServerCredentials>) -> Self {
        Self {
            credentials: Arc::new(Mutex::new(credentials)),
            fail_writes: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn credentials(&self) -> Option<ServerCredentials> {
        self.credentials.lock().unwrap().clone()
    }

    #[allow(dead_code)]
    pub fn set_fail_writes(&self, fail: bool) {
        self.fail_writes.store(fail, Ordering::Release);
    }
}

impl CredentialStore for TestCredentialStore {
    fn load(&self) -> Result<Option<ServerCredentials>, CredentialStoreError> {
        Ok(self.credentials())
    }

    fn replace(&self, credentials: &ServerCredentials) -> Result<(), CredentialStoreError> {
        if self.fail_writes.load(Ordering::Acquire) {
            return Err(CredentialStoreError::new(
                "injected credential write failure",
            ));
        }
        *self.credentials.lock().unwrap() = Some(credentials.clone());
        Ok(())
    }

    fn clear(&self) -> Result<(), CredentialStoreError> {
        if self.fail_writes.load(Ordering::Acquire) {
            return Err(CredentialStoreError::new(
                "injected credential write failure",
            ));
        }
        *self.credentials.lock().unwrap() = None;
        Ok(())
    }
}

pub async fn initialize_daemon(
    config: DaemonConfig,
    credential_store: TestCredentialStore,
) -> DaemonState {
    DaemonState::initialize_with_credential_store(config, Arc::new(credential_store))
        .await
        .unwrap()
}

pub async fn initialize_authenticated_daemon(
    config: DaemonConfig,
    access_token: impl Into<String>,
    refresh_token: Option<String>,
) -> (DaemonState, TestCredentialStore) {
    let credential_store = TestCredentialStore::new(Some(ServerCredentials {
        server_url: config.project.server_url.clone(),
        access_token: access_token.into(),
        refresh_token,
    }));
    let state = initialize_daemon(config, credential_store.clone()).await;
    (state, credential_store)
}

#[allow(dead_code)]
pub async fn test_daemon() -> (TempDir, DaemonState, DaemonIpcService) {
    let root = tempfile::tempdir().unwrap();
    let state = initialize_daemon(
        DaemonConfig::for_root(root.path()),
        TestCredentialStore::default(),
    )
    .await;
    let service = DaemonIpcService::new(state.clone());
    (root, state, service)
}
