import Foundation
import XPC

enum DaemonXPCError: LocalizedError, Sendable {
    case invalidRequest
    case connectionFailed
    case requestTimedOut
    case invalidReply
    case daemon(APIErrorPayload)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not encode the daemon request."
        case .connectionFailed:
            return "The local Clumsies daemon is unavailable."
        case .requestTimedOut:
            return "The local Clumsies daemon did not respond in time."
        case .invalidReply:
            return "The local Clumsies daemon returned an invalid response."
        case .daemon(let error):
            return "\(error.code): \(error.message)"
        }
    }
}

struct DaemonXPCClient: Sendable {
    static let serviceName = ClumsiesIdentifiers.daemon
    private static let replyQueue = DispatchQueue(
        label: ClumsiesIdentifiers.xpcReplyQueue,
        qos: .userInitiated,
        attributes: .concurrent
    )

    let serviceName: String

    init(serviceName: String = Self.serviceName) {
        self.serviceName = serviceName
    }

    func health(timeout: TimeInterval = 3) async throws -> DaemonHealth {
        try await call(method: "health", payload: EmptyPayload(), timeout: timeout)
    }

    func projectConfig() async throws -> DaemonProjectConfig {
        try await call(method: "project_config", payload: EmptyPayload())
    }

    func replaceProjectConfig(_ update: DaemonProjectConfigUpdate) async throws -> DaemonProjectConfig {
        try await call(method: "replace_project_config", payload: update)
    }

    func selectProject(_ projectId: String) async throws -> DaemonProjectConfig {
        try await call(method: "select_project", payload: DaemonProjectSelection(projectId: projectId))
    }

    func projectBindings(_ projectId: String) async throws -> [DaemonProjectBinding] {
        let response: DaemonProjectBindingListResponse = try await call(
            method: "list_project_bindings",
            payload: DaemonProjectBindingListRequest(projectId: projectId)
        )
        return response.items
    }

    func replaceProjectBinding(_ request: DaemonProjectBindingReplaceRequest) async throws
        -> DaemonProjectBinding {
        try await call(method: "replace_project_binding", payload: request)
    }

    func removeProjectBinding(_ request: DaemonProjectBindingRemoveRequest) async throws
        -> DaemonProjectBindingRemoveResponse {
        try await call(method: "remove_project_binding", payload: request)
    }

    func projectAgentAdapters(_ projectId: String) async throws -> [DaemonProjectAgentAdapter] {
        let response: DaemonProjectAgentAdapterListResponse = try await call(
            method: "list_project_agent_adapters",
            payload: DaemonProjectAgentAdapterListRequest(projectId: projectId)
        )
        return response.items
    }

    func installProjectAgentAdapter(_ request: DaemonProjectAgentAdapterInstallRequest) async throws
        -> DaemonProjectAgentAdapter {
        try await call(method: "install_project_agent_adapter", payload: request)
    }

    func removeProjectAgentAdapter(_ request: DaemonProjectAgentAdapterRemoveRequest) async throws
        -> DaemonProjectAgentAdapterRemoveResponse {
        try await call(method: "remove_project_agent_adapter", payload: request)
    }

    func projectCheckout(_ projectId: String) async throws -> DaemonProjectCheckout {
        try await call(
            method: "project_checkout",
            payload: DaemonProjectCheckoutRequest(projectId: projectId)
        )
    }

    func syncStatus() async throws -> DaemonSyncStatus {
        try await call(method: "sync_status", payload: EmptyPayload())
    }

    func projectStorage(_ projectId: String) async throws -> DaemonProjectStorage {
        try await call(
            method: "project_storage",
            payload: DaemonProjectStorageRequest(projectId: projectId)
        )
    }

    func replaceProjectStorage(_ request: DaemonProjectStorageReplaceRequest) async throws
        -> DaemonProjectStorageMove {
        try await call(method: "replace_project_storage", payload: request)
    }

    func projectStorageMove(_ moveId: String) async throws -> DaemonProjectStorageMove {
        try await call(
            method: "project_storage_move",
            payload: DaemonProjectStorageMoveRequest(moveId: moveId)
        )
    }

    func resetProjectStorage(_ request: DaemonProjectStorageResetRequest) async throws
        -> DaemonProjectStorageMove {
        try await call(method: "reset_project_storage", payload: request)
    }

    func clearProjectCache(_ request: DaemonProjectCacheClearRequest) async throws
        -> DaemonProjectStorage {
        try await call(method: "clear_project_cache", payload: request)
    }

    func retrySync(channel: String = "all") async throws -> DaemonRetryResponse {
        try await call(method: "retry_sync", payload: DaemonSyncRetryRequest(channel: channel))
    }

    func mcpStatus() async throws -> DaemonMCPStatus {
        try await call(method: "mcp_status", payload: EmptyPayload())
    }

    func listDrafts(_ query: DaemonDraftListQuery = .init(limit: 200)) async throws -> DaemonDraftListResponse {
        try await call(method: "list_drafts", payload: query)
    }

    func draft(_ draftId: String) async throws -> DaemonDraftDetail {
        try await call(method: "get_draft", payload: DaemonDraftDetailRequest(draftId: draftId))
    }

    func store(_ request: DaemonDraftOperationRequest) async throws -> DaemonDraftOperationResponse {
        try await call(method: "store_draft_operation", payload: request)
    }

    func issueBoard(_ projectId: String) async throws -> IssueBoardResponse {
        try await call(
            method: "list_issue_board",
            payload: IssueBoardListRequest(projectId: projectId)
        )
    }

    func issueDetail(projectId: String, issueNumber: Int) async throws -> IssueDetailResponse {
        try await call(
            method: "get_issue_detail",
            payload: IssueDetailRequest(projectId: projectId, issueNumber: issueNumber)
        )
    }

    func applyIssueGate(_ request: ApplyIssueGateRequest) async throws -> IssueMutationResponse {
        try await call(method: "apply_issue_gate", payload: request)
    }

    func setVerificationStepCompleted(
        _ request: SetVerificationStepCompletedRequest
    ) async throws -> IssueMutationResponse {
        try await call(method: "set_verification_step_completed", payload: request)
    }

    func unclaimIssue(_ request: UnclaimIssueRequest) async throws -> IssueMutationResponse {
        try await call(method: "unclaim_issue", payload: request)
    }

    func removeIssue(_ request: RemoveIssueRequest) async throws -> IssueRemovalResponse {
        try await call(method: "remove_issue", payload: request)
    }

    func listRetrievalRuns(_ request: RetrievalRunListRequest) async throws
        -> RetrievalRunListResponse {
        try await call(method: "list_retrieval_runs", payload: request)
    }

    func retrievalRun(_ runId: String) async throws -> RetrievalRunDetail {
        try await call(
            method: "get_retrieval_run",
            payload: RetrievalRunRequest(runId: runId)
        )
    }

    func createEvaluationCase(_ request: CreateEvaluationCaseRequest) async throws
        -> EvaluationCaseDetail {
        try await call(method: "create_evaluation_case", payload: request)
    }

    func resolveEvaluationCase(_ request: ResolveEvaluationCaseRequest) async throws
        -> EvaluationCaseDetail {
        try await call(method: "resolve_evaluation_case", payload: request)
    }

    func clearRetrievalRuns(projectId: String?) async throws -> ClearRetrievalRunsResponse {
        try await call(
            method: "clear_retrieval_runs",
            payload: ClearRetrievalRunsRequest(projectId: projectId)
        )
    }

    func exportEvaluationSet(projectId: String?, caseIds: [String] = []) async throws
        -> ExportEvaluationSetResponse {
        try await call(
            method: "export_evaluation_set",
            payload: ExportEvaluationSetRequest(projectId: projectId, caseIds: caseIds)
        )
    }

    func serverRequest(_ request: DaemonServerRequest) async throws -> DaemonServerResponse {
        try await call(method: "server_request", payload: request)
    }

    func call<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        payload: Payload,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let encoder = JSONCoding.encoder()
        let payloadData = try encoder.encode(payload)
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        let requestObject: [String: Any] = ["method": method, "payload": payloadObject]
        guard JSONSerialization.isValidJSONObject(requestObject) else {
            throw DaemonXPCError.invalidRequest
        }
        let requestData = try JSONSerialization.data(withJSONObject: requestObject)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw DaemonXPCError.invalidRequest
        }

        let responseJSON = try await Self.send(requestJSON, to: serviceName, timeout: timeout)
        guard let responseData = responseJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            throw DaemonXPCError.invalidReply
        }
        if !ok {
            let errorObject = object["error"] ?? [:]
            let errorData = try JSONSerialization.data(withJSONObject: errorObject)
            if let error = try? JSONCoding.decoder().decode(APIErrorPayload.self, from: errorData) {
                throw DaemonXPCError.daemon(error)
            }
            throw DaemonXPCError.invalidReply
        }
        guard let payloadObject = object["payload"] else {
            throw DaemonXPCError.invalidReply
        }
        let decodedPayloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        return try JSONCoding.decoder().decode(Response.self, from: decodedPayloadData)
    }

    private static func send(
        _ requestJSON: String,
        to serviceName: String,
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = DaemonXPCRequestState(continuation: continuation)
            let connection = xpc_connection_create_mach_service(serviceName, replyQueue, 0)
            request.attach(connection)
            xpc_connection_set_event_handler(connection) { event in
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    request.fail(.connectionFailed)
                }
            }
            xpc_connection_activate(connection)

            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "request_json", requestJSON)
            xpc_connection_send_message_with_reply(connection, message, replyQueue) { reply in
                guard xpc_get_type(reply) != XPC_TYPE_ERROR,
                      xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                      let responsePointer = xpc_dictionary_get_string(reply, "response_json") else {
                    request.fail(.connectionFailed)
                    return
                }
                request.succeed(String(cString: responsePointer))
            }
            replyQueue.asyncAfter(deadline: .now() + timeout) {
                request.fail(.requestTimedOut)
            }
        }
    }
}

struct DaemonStartupReadiness: Sendable {
    typealias HealthCheck = @Sendable (TimeInterval) async throws -> DaemonHealth

    let timeout: Duration
    let retryInterval: Duration
    let requestTimeout: Duration

    init(
        timeout: Duration = .seconds(30),
        retryInterval: Duration = .milliseconds(150),
        requestTimeout: Duration = .seconds(3)
    ) {
        self.timeout = timeout
        self.retryInterval = retryInterval
        self.requestTimeout = requestTimeout
    }

    func waitForHealth(_ check: HealthCheck) async throws -> DaemonHealth {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: DaemonXPCError = .connectionFailed

        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            do {
                return try await check(min(requestTimeout, remaining).timeInterval)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DaemonXPCError {
                switch error {
                case .connectionFailed, .requestTimedOut:
                    lastError = error
                case .invalidRequest, .invalidReply, .daemon:
                    throw error
                }
            }

            let retryRemaining = clock.now.duration(to: deadline)
            guard retryRemaining > .zero else { break }
            try await Task.sleep(for: min(retryInterval, retryRemaining))
        }

        throw lastError
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

private final class DaemonXPCRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var connection: xpc_connection_t?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func attach(_ connection: xpc_connection_t) {
        lock.withLock {
            self.connection = connection
        }
    }

    func succeed(_ response: String) {
        finish(.success(response))
    }

    func fail(_ error: DaemonXPCError) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, DaemonXPCError>) {
        let completion: (CheckedContinuation<String, Error>, xpc_connection_t?)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            let connection = self.connection
            self.connection = nil
            return (continuation, connection)
        }
        guard let (continuation, connection) = completion else { return }
        if let connection {
            xpc_connection_cancel(connection)
        }
        switch result {
        case .success(let response):
            continuation.resume(returning: response)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
