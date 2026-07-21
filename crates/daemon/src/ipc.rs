use crate::{
    ActivateMemoryRequest, ActivateMemoryResponse, DaemonDraftDetail, DaemonDraftDetailRequest,
    DaemonDraftListQuery, DaemonDraftListResponse, DaemonDraftOperationRequest,
    DaemonDraftOperationResponse, DaemonError, DaemonHealth, DaemonIpcRequest, DaemonIpcResponse,
    DaemonIpcService, DaemonMcpStatus, DaemonProjectConfig, DaemonProjectConfigUpdateRequest,
    DaemonProjectSelectionRequest, DaemonRetryResponse, DaemonServerRequest, DaemonServerResponse,
    DaemonSyncRetryRequest, DaemonSyncStatus, LoadMemoryRequest, LoadMemoryResponse,
    SearchIndexProjectRequest, SearchIndexStatus,
};

#[derive(Clone, Debug)]
pub struct DaemonIpcClient {
    service_name: String,
}

impl DaemonIpcClient {
    pub fn new(service_name: impl Into<String>) -> Self {
        Self {
            service_name: service_name.into(),
        }
    }

    pub fn service_name(&self) -> &str {
        &self.service_name
    }

    pub fn call(&self, request: DaemonIpcRequest) -> Result<DaemonIpcResponse, DaemonError> {
        platform::call(&self.service_name, request)
    }

    pub fn health(&self) -> Result<DaemonHealth, DaemonError> {
        self.call(DaemonIpcRequest::empty("health"))?.into_payload()
    }

    pub fn project_config(&self) -> Result<DaemonProjectConfig, DaemonError> {
        self.call(DaemonIpcRequest::empty("project_config"))?
            .into_payload()
    }

    pub fn replace_project_config(
        &self,
        request: DaemonProjectConfigUpdateRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "replace_project_config",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn select_project(
        &self,
        request: DaemonProjectSelectionRequest,
    ) -> Result<DaemonProjectConfig, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "select_project",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn sync_status(&self) -> Result<DaemonSyncStatus, DaemonError> {
        self.call(DaemonIpcRequest::empty("sync_status"))?
            .into_payload()
    }

    pub fn activate_memory(
        &self,
        request: ActivateMemoryRequest,
    ) -> Result<ActivateMemoryResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "activate_memory",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn load_memory(
        &self,
        request: LoadMemoryRequest,
    ) -> Result<LoadMemoryResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "load_memory",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn search_index_status(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "search_index_status",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn rebuild_search_index(
        &self,
        request: SearchIndexProjectRequest,
    ) -> Result<SearchIndexStatus, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "rebuild_search_index",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn retry_sync(
        &self,
        request: DaemonSyncRetryRequest,
    ) -> Result<DaemonRetryResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "retry_sync",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn mcp_status(&self) -> Result<DaemonMcpStatus, DaemonError> {
        self.call(DaemonIpcRequest::empty("mcp_status"))?
            .into_payload()
    }

    pub fn list_drafts(
        &self,
        query: DaemonDraftListQuery,
    ) -> Result<DaemonDraftListResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "list_drafts",
            serde_json::to_value(query)?,
        ))?
        .into_payload()
    }

    pub fn get_draft(&self, draft_id: impl Into<String>) -> Result<DaemonDraftDetail, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "get_draft",
            serde_json::to_value(DaemonDraftDetailRequest {
                draft_id: draft_id.into(),
            })?,
        ))?
        .into_payload()
    }

    pub fn store_draft_operation(
        &self,
        request: DaemonDraftOperationRequest,
    ) -> Result<DaemonDraftOperationResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "store_draft_operation",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }

    pub fn server_request(
        &self,
        request: DaemonServerRequest,
    ) -> Result<DaemonServerResponse, DaemonError> {
        self.call(DaemonIpcRequest::new(
            "server_request",
            serde_json::to_value(request)?,
        ))?
        .into_payload()
    }
}

pub struct DaemonIpcServer {
    inner: platform::DaemonIpcServerInner,
}

impl DaemonIpcServer {
    pub fn start(
        service_name: impl Into<String>,
        service: DaemonIpcService,
    ) -> Result<Self, DaemonError> {
        Ok(Self {
            inner: platform::DaemonIpcServerInner::start(service_name.into(), service)?,
        })
    }

    pub fn service_name(&self) -> &str {
        self.inner.service_name()
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;

    pub fn call(
        service_name: &str,
        _request: DaemonIpcRequest,
    ) -> Result<DaemonIpcResponse, DaemonError> {
        Err(DaemonError::Ipc(format!(
            "local daemon IPC is only implemented on macOS; requested XPC Mach service {service_name}"
        )))
    }

    pub struct DaemonIpcServerInner {
        service_name: String,
    }

    impl DaemonIpcServerInner {
        pub fn start(
            service_name: String,
            _service: DaemonIpcService,
        ) -> Result<Self, DaemonError> {
            Err(DaemonError::Ipc(format!(
                "local daemon IPC is only implemented on macOS; requested XPC Mach service {service_name}"
            )))
        }

        pub fn service_name(&self) -> &str {
            &self.service_name
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{CStr, CString, c_char, c_void};
    use std::ptr;

    use block2::RcBlock;
    use tokio::runtime::Handle;

    use super::*;

    type XpcObject = *mut c_void;
    type XpcConnection = *mut c_void;
    type XpcType = *const c_void;
    type DispatchQueue = *mut c_void;

    const XPC_CONNECTION_MACH_SERVICE_LISTENER: u64 = 1;
    const REQUEST_JSON_KEY: &str = "request_json";
    const RESPONSE_JSON_KEY: &str = "response_json";

    #[link(name = "System")]
    unsafe extern "C" {
        static _xpc_type_connection: c_void;
        static _xpc_type_dictionary: c_void;
        static _xpc_type_error: c_void;

        fn xpc_connection_create_mach_service(
            name: *const c_char,
            targetq: DispatchQueue,
            flags: u64,
        ) -> XpcConnection;
        fn xpc_connection_set_event_handler(connection: XpcConnection, handler: *mut c_void);
        fn xpc_connection_activate(connection: XpcConnection);
        fn xpc_connection_cancel(connection: XpcConnection);
        fn xpc_connection_send_message(connection: XpcConnection, message: XpcObject);
        fn xpc_connection_send_message_with_reply_sync(
            connection: XpcConnection,
            message: XpcObject,
        ) -> XpcObject;

        fn xpc_dictionary_create(
            keys: *const *const c_char,
            values: *const XpcObject,
            count: usize,
        ) -> XpcObject;
        fn xpc_dictionary_create_reply(original: XpcObject) -> XpcObject;
        fn xpc_dictionary_set_string(xdict: XpcObject, key: *const c_char, value: *const c_char);
        fn xpc_dictionary_get_string(xdict: XpcObject, key: *const c_char) -> *const c_char;

        fn xpc_get_type(object: XpcObject) -> XpcType;
        fn xpc_release(object: XpcObject);
    }

    pub fn call(
        service_name: &str,
        request: DaemonIpcRequest,
    ) -> Result<DaemonIpcResponse, DaemonError> {
        let service_name = CString::new(service_name)
            .map_err(|error| DaemonError::Ipc(format!("invalid XPC service name: {error}")))?;
        let connection = unsafe {
            XpcConnectionHandle::new(xpc_connection_create_mach_service(
                service_name.as_ptr(),
                ptr::null_mut(),
                0,
            ))?
        };
        let handler = RcBlock::new(|_event: XpcObject| {});
        unsafe {
            xpc_connection_set_event_handler(connection.as_ptr(), RcBlock::as_ptr(&handler).cast());
            xpc_connection_activate(connection.as_ptr());
        }

        let message =
            xpc_dictionary_with_json(REQUEST_JSON_KEY, &serde_json::to_string(&request)?)?;
        let reply = unsafe {
            XpcOwnedObject::new(xpc_connection_send_message_with_reply_sync(
                connection.as_ptr(),
                message.as_ptr(),
            ))?
        };
        if unsafe { object_type(reply.as_ptr()) } == unsafe { xpc_error_type() } {
            return Err(DaemonError::Ipc("XPC returned an error object".to_owned()));
        }
        let response_json = xpc_dictionary_string(reply.as_ptr(), RESPONSE_JSON_KEY)?;
        serde_json::from_str(&response_json).map_err(DaemonError::from)
    }

    pub struct DaemonIpcServerInner {
        service_name: String,
        _listener: XpcConnectionHandle,
        _handler: RcBlock<dyn Fn(XpcObject) + 'static>,
    }

    impl DaemonIpcServerInner {
        pub fn start(service_name: String, service: DaemonIpcService) -> Result<Self, DaemonError> {
            let runtime = Handle::try_current().map_err(|error| {
                DaemonError::Ipc(format!("tokio runtime is required for XPC server: {error}"))
            })?;
            let service_name_c = CString::new(service_name.as_str())
                .map_err(|error| DaemonError::Ipc(format!("invalid XPC service name: {error}")))?;
            let listener = unsafe {
                XpcConnectionHandle::new(xpc_connection_create_mach_service(
                    service_name_c.as_ptr(),
                    ptr::null_mut(),
                    XPC_CONNECTION_MACH_SERVICE_LISTENER,
                ))?
            };
            let handler = RcBlock::new(move |peer: XpcObject| {
                if unsafe { object_type(peer) } != unsafe { xpc_connection_type() } {
                    return;
                }
                accept_peer(peer.cast(), service.clone(), runtime.clone());
            });
            unsafe {
                xpc_connection_set_event_handler(
                    listener.as_ptr(),
                    RcBlock::as_ptr(&handler).cast(),
                );
                xpc_connection_activate(listener.as_ptr());
            }
            Ok(Self {
                service_name,
                _listener: listener,
                _handler: handler,
            })
        }

        pub fn service_name(&self) -> &str {
            &self.service_name
        }
    }

    fn accept_peer(peer: XpcConnection, service: DaemonIpcService, runtime: Handle) {
        let peer_handler = RcBlock::new(move |message: XpcObject| {
            if unsafe { object_type(message) } != unsafe { xpc_dictionary_type() } {
                return;
            }
            let response_json = dispatch_message(&service, &runtime, message);
            let Ok(response_json) = response_json else {
                return;
            };
            let reply = unsafe { xpc_dictionary_create_reply(message) };
            let Ok(reply) = (unsafe { XpcOwnedObject::new(reply) }) else {
                return;
            };
            if set_xpc_string(reply.as_ptr(), RESPONSE_JSON_KEY, &response_json).is_ok() {
                unsafe {
                    xpc_connection_send_message(peer, reply.as_ptr());
                }
            }
        });
        unsafe {
            xpc_connection_set_event_handler(peer, RcBlock::as_ptr(&peer_handler).cast());
            xpc_connection_activate(peer);
        }
    }

    fn dispatch_message(
        service: &DaemonIpcService,
        runtime: &Handle,
        message: XpcObject,
    ) -> Result<String, DaemonError> {
        let request_json = xpc_dictionary_string(message, REQUEST_JSON_KEY)?;
        let request: DaemonIpcRequest = serde_json::from_str(&request_json)?;
        let response = runtime.block_on(service.dispatch(request));
        serde_json::to_string(&response).map_err(DaemonError::from)
    }

    fn xpc_dictionary_with_json(key: &str, value: &str) -> Result<XpcOwnedObject, DaemonError> {
        let object =
            unsafe { XpcOwnedObject::new(xpc_dictionary_create(ptr::null(), ptr::null(), 0))? };
        set_xpc_string(object.as_ptr(), key, value)?;
        Ok(object)
    }

    fn set_xpc_string(object: XpcObject, key: &str, value: &str) -> Result<(), DaemonError> {
        let key = CString::new(key)
            .map_err(|error| DaemonError::Ipc(format!("invalid XPC key: {error}")))?;
        let value = CString::new(value)
            .map_err(|error| DaemonError::Ipc(format!("invalid XPC string value: {error}")))?;
        unsafe {
            xpc_dictionary_set_string(object, key.as_ptr(), value.as_ptr());
        }
        Ok(())
    }

    fn xpc_dictionary_string(object: XpcObject, key: &str) -> Result<String, DaemonError> {
        if unsafe { object_type(object) } != unsafe { xpc_dictionary_type() } {
            return Err(DaemonError::Ipc(
                "expected XPC dictionary response".to_owned(),
            ));
        }
        let key = CString::new(key)
            .map_err(|error| DaemonError::Ipc(format!("invalid XPC key: {error}")))?;
        let value = unsafe { xpc_dictionary_get_string(object, key.as_ptr()) };
        if value.is_null() {
            return Err(DaemonError::Ipc(format!(
                "missing XPC string field: {}",
                key.to_string_lossy()
            )));
        }
        Ok(unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned())
    }

    unsafe fn object_type(object: XpcObject) -> XpcType {
        unsafe { xpc_get_type(object) }
    }

    unsafe fn xpc_connection_type() -> XpcType {
        &raw const _xpc_type_connection as XpcType
    }

    unsafe fn xpc_dictionary_type() -> XpcType {
        &raw const _xpc_type_dictionary as XpcType
    }

    unsafe fn xpc_error_type() -> XpcType {
        &raw const _xpc_type_error as XpcType
    }

    struct XpcOwnedObject {
        object: XpcObject,
    }

    impl XpcOwnedObject {
        unsafe fn new(object: XpcObject) -> Result<Self, DaemonError> {
            if object.is_null() {
                Err(DaemonError::Ipc("XPC returned a null object".to_owned()))
            } else {
                Ok(Self { object })
            }
        }

        fn as_ptr(&self) -> XpcObject {
            self.object
        }
    }

    impl Drop for XpcOwnedObject {
        fn drop(&mut self) {
            unsafe {
                xpc_release(self.object);
            }
        }
    }

    struct XpcConnectionHandle {
        connection: XpcConnection,
    }

    impl XpcConnectionHandle {
        unsafe fn new(connection: XpcConnection) -> Result<Self, DaemonError> {
            if connection.is_null() {
                Err(DaemonError::Ipc(
                    "XPC returned a null connection".to_owned(),
                ))
            } else {
                Ok(Self { connection })
            }
        }

        fn as_ptr(&self) -> XpcConnection {
            self.connection
        }
    }

    impl Drop for XpcConnectionHandle {
        fn drop(&mut self) {
            unsafe {
                xpc_connection_cancel(self.connection);
                xpc_release(self.connection.cast());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_mach_service_returns_an_ipc_error() {
        let client = DaemonIpcClient::new("ai.clumsies.daemon.missing-test-service");

        let error = client.health().unwrap_err();

        assert!(matches!(error, DaemonError::Ipc(_)));
    }
}
