import Foundation

struct DaemonProjectConfig: Codable, Equatable, Sendable {
    let serverUrl: String
    let projectId: String?
    let hasAccessToken: Bool
    let hasRefreshToken: Bool
    let ready: Bool
    let missingFields: [String]
}

struct DaemonProjectConfigUpdate: Codable, Sendable {
    let serverUrl: String
    let projectId: String?
    let accessToken: String?
    let refreshToken: String?
}

struct DaemonProjectSelection: Codable, Sendable {
    let projectId: String
}

struct DaemonProjectBindingListRequest: Codable, Sendable {
    let projectId: String
}

struct DaemonProjectBindingReplaceRequest: Codable, Sendable {
    let workspaceRoot: String
    let projectId: String
    let expectedRevision: Int?
}

struct DaemonProjectBindingRemoveRequest: Codable, Sendable {
    let workspaceRoot: String
    let expectedRevision: Int
}

struct DaemonProjectBindingRemoveResponse: Codable, Sendable {
    let workspaceRoot: String
    let removed: Bool
}

struct DaemonProjectBinding: Codable, Identifiable, Equatable, Sendable {
    var id: String { workspaceRoot }

    let serverUrl: String
    let workspaceRoot: String
    let projectId: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
}

struct DaemonProjectBindingListResponse: Codable, Sendable {
    let items: [DaemonProjectBinding]
}

enum ProjectAgentAdapterKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case opencode
    case dsh
    case antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .opencode: "opencode"
        case .dsh: "DeepSeek Harness (dsh)"
        case .antigravity: "Antigravity"
        }
    }
}

struct DaemonProjectAgentAdapterListRequest: Codable, Sendable {
    let projectId: String
}

struct DaemonProjectAgentAdapterInstallRequest: Codable, Sendable {
    let projectId: String
    let workspaceRoot: String
    let adapter: ProjectAgentAdapterKind
    let runtimeBinaryPath: String
    let expectedRevision: Int?
}

struct DaemonProjectAgentAdapterRemoveRequest: Codable, Sendable {
    let workspaceRoot: String
    let adapter: ProjectAgentAdapterKind
    let expectedRevision: Int
}

struct DaemonProjectAgentAdapterRemoveResponse: Codable, Sendable {
    let workspaceRoot: String
    let adapter: ProjectAgentAdapterKind
    let removed: Bool
}

struct DaemonProjectAgentAdapter: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(workspaceRoot):\(adapter.rawValue)" }

    let serverUrl: String
    let projectId: String
    let workspaceRoot: String
    let adapter: ProjectAgentAdapterKind
    let revision: Int
    let managedFiles: [String]
    let createdAt: String
    let updatedAt: String
}

struct DaemonProjectAgentAdapterListResponse: Codable, Sendable {
    let items: [DaemonProjectAgentAdapter]
}

struct DaemonLegacyAgentAdapterInspectionRequest: Codable, Sendable {
    let runtimeBinaryPath: String
}

struct DaemonLegacyAgentAdapterConflict: Codable, Equatable, Sendable {
    let installId: String
    let adapter: ProjectAgentAdapterKind
    let scope: String
    let targetRoot: String
    let code: String
    let message: String
}

struct DaemonLegacyAgentAdapterInspectionResponse: Codable, Equatable, Sendable {
    let scanned: Int
    let deferred: Int
    let conflicts: [DaemonLegacyAgentAdapterConflict]
}

enum DaemonProjectStorageMode: String, Codable, Sendable {
    case standard = "default"
    case custom
}

enum DaemonProjectStorageAvailability: String, Codable, Sendable {
    case ready
    case moving
    case unavailable
}

enum DaemonProjectStorageMoveState: String, Codable, Sendable {
    case preparing
    case materializing
    case verifying
    case switching
    case cleaning
    case completed
    case failed

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

struct DaemonProjectStorageRequest: Codable, Sendable {
    let projectId: String
}

struct DaemonProjectStorageMoveRequest: Codable, Sendable {
    let moveId: String
}

struct DaemonProjectStorageReplaceRequest: Codable, Sendable {
    let projectId: String
    let selectedRootPath: String
    let handoffBookmarkData: String
    let expectedLocationRevision: Int
}

struct DaemonProjectStorageResetRequest: Codable, Sendable {
    let projectId: String
    let expectedLocationRevision: Int
}

struct DaemonProjectCacheClearRequest: Codable, Sendable {
    let projectId: String
    let expectedLocationRevision: Int
}

struct DaemonProjectStorage: Codable, Equatable, Sendable {
    let authorityKey: String
    let projectId: String
    let mode: DaemonProjectStorageMode
    let selectedRootPath: String
    let managedRootPath: String
    let activeGenerationPath: String?
    let searchIndexPath: String
    let availability: DaemonProjectStorageAvailability
    let locationRevision: Int
    let sizeBytes: UInt64
    let activeMoveId: String?
    let issueCode: String?
    let diagnostic: String?
}

struct DaemonProjectStorageMove: Codable, Equatable, Sendable {
    let moveId: String
    let projectId: String
    let sourceMode: DaemonProjectStorageMode
    let destinationMode: DaemonProjectStorageMode
    let sourceManagedRootPath: String
    let destinationManagedRootPath: String
    let sourceLocationRevision: Int
    let state: DaemonProjectStorageMoveState
    let errorCode: String?
    let errorMessage: String?
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
}

struct DaemonProjectCheckoutRequest: Codable, Sendable {
    let projectId: String
}

struct DaemonProjectCheckout: Codable, Sendable {
    let projectId: String
    let commitId: String?
    let refEtag: String?
    let commitCreatedAt: String?
    let orgSelectionRevision: Int
    let selectedOrgResourceIds: [String]
    let resources: [DaemonProjectCheckoutResource]
    let ready: Bool
}

struct DaemonProjectCheckoutResource: Codable, Sendable {
    let resourceId: String
    let scope: DaemonDraftScope
    let resourceKind: DaemonResourceKind
    let projectId: String?
    let path: String
    let contentHash: String
    let content: DaemonDraftContent
}

struct DaemonHealth: Codable, Equatable, Sendable {
    let daemonVersion: String
    let agentRuntime: AgentRuntimeIdentity
    let serverUrl: String
    let projectId: String?
    let daemonInstallationId: String
    let logDir: String
    let localDb: DaemonLocalDatabaseStatus
}

struct AgentRuntimeIdentity: Codable, Equatable, Sendable {
    let protocolRevision: Int
    let buildId: String
}

struct DaemonLocalDatabaseStatus: Codable, Equatable, Sendable {
    let path: String
    let ready: Bool
    let schemaVersion: Int
}

struct DaemonSyncStatus: Codable, Equatable, Sendable {
    let draftSync: DaemonSyncChannelStatus
    let commitSync: DaemonSyncChannelStatus
    let pendingOperationCount: Int
    let failedOperationCount: Int
    let behindDraftCount: Int
    let reconciliationConflictCount: Int
    let lastSuccessAt: String?
}

struct DaemonSyncChannelStatus: Codable, Equatable, Sendable {
    let state: String
    let serverCursor: String?
    let lastAttemptAt: String?
    let lastSuccessAt: String?
    let lastError: APIErrorPayload?
}

struct DaemonSyncRetryRequest: Codable, Sendable {
    let channel: String
}

struct DaemonRetryResponse: Codable, Sendable {
    let retryId: String
    let started: Bool
}

struct DaemonMCPStatus: Codable, Equatable, Sendable {
    let running: Bool
    let endpoint: String?
    let adapters: [DaemonMCPAdapterStatus]
}

struct DaemonMCPAdapterStatus: Codable, Equatable, Sendable {
    let name: String
    let running: Bool
    let lastError: APIErrorPayload?
}

struct DaemonServerRequest: Codable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: String?
}

struct DaemonServerResponse: Codable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: String
}

struct DaemonDraftListQuery: Codable, Sendable {
    let projectId: String?
    let status: String?
    let cursor: String?
    let limit: Int?

    init(projectId: String? = nil, status: String? = nil, cursor: String? = nil, limit: Int? = nil) {
        self.projectId = projectId
        self.status = status
        self.cursor = cursor
        self.limit = limit
    }
}

struct DaemonDraftListResponse: Codable, Sendable {
    let items: [DaemonDraftSummary]
}

struct DaemonDraftDetailRequest: Codable, Sendable {
    let draftId: String
}

struct DaemonDraftDetail: Codable, Sendable {
    let draft: DaemonDraftSummary
    let operations: [DaemonLocalDraftOperation]
}

struct DaemonDraftSummary: Codable, Identifiable, Hashable, Sendable {
    var id: String { draftId }

    let draftId: String
    let projectId: String
    let serverDraftId: String?
    let serverVersion: Int
    let baseCommitId: String?
    let currentCommitId: String?
    let freshness: DraftFreshness
    let hasUpstreamResourceChanges: Bool
    let reconciliation: DraftReconciliationStatus
    let reconciliationCandidateId: String?
    let scope: DaemonDraftScope
    let resourceKind: DaemonResourceKind
    let targetId: String?
    let path: String?
    let status: DaemonLocalDraftStatus
    let createdAt: String
    let updatedAt: String
    let pendingOperationCount: Int
    let failedOperationCount: Int
}

enum DaemonDraftScope: String, Codable, Hashable, Sendable {
    case org
    case project
}

enum DaemonResourceKind: String, Codable, Hashable, Sendable {
    case memory

    /// The daemon now models a single Memory kind, but archived local
    /// databases and older clients still write the legacy context/rule/
    /// workflow values; decode them all to `.memory`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "context", "rule", "workflow", "memory":
            self = .memory
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown daemon resource kind: \(raw)"
            ))
        }
    }
}

enum DaemonLocalDraftStatus: String, Codable, Hashable, Sendable {
    case open
    case submitted
    case merged
    case discarded
}

enum DraftFreshness: String, Codable, Hashable, Sendable {
    case current
    case behind
}

enum DraftReconciliationStatus: String, Codable, Hashable, Sendable {
    case unknown
    case clean
    case conflicts
}

enum DaemonDraftOperationSource: String, Codable, Hashable, Sendable {
    case desktop
    case cli
    case mcpStore = "mcp_store"
    case server
}

enum DaemonDraftSyncState: String, Codable, Hashable, Sendable {
    case queued
    case syncing
    case retrying
    case synced
    case failed
}

struct DaemonLocalDraftOperation: Codable, Identifiable, Sendable {
    var id: String { localOperationId }

    let localOperationId: String
    let resourceKind: DaemonResourceKind
    let operation: DaemonDraftOperation
    let source: DaemonDraftOperationSource
    let syncStatus: DaemonDraftSyncState
    let lastError: String?
    let createdAt: String
    let updatedAt: String
}

struct DaemonDraftOperationRequest: Codable, Sendable {
    let draftId: String?
    let baseCommitId: String?
    let projectId: String
    let scope: DaemonDraftScope
    let resource: DaemonResourceKind
    let op: DaemonDraftOperation
    let source: DaemonDraftOperationSource
}

struct DaemonDraftOperationResponse: Codable, Sendable {
    let localOperationId: String
    let draftId: String
    let queued: Bool
    let syncStatus: DaemonDraftSyncState
}

struct DaemonDraftContent: Codable, Hashable, Sendable {
    let description: String?
    let content: String

    var primaryText: String { content }
    var renderedText: String { content }

    func replacingPrimaryText(with text: String) -> DaemonDraftContent {
        .init(description: description, content: text)
    }
}

enum DaemonDraftOperation: Codable, Sendable {
    case create(path: String, content: DaemonDraftContent, description: String?)
    case update(id: String, content: DaemonDraftContent, description: String?)
    case rename(id: String, newPath: String, description: String?)
    case delete(id: String, description: String?)
    case discard(id: String)

    private enum CodingKeys: String, CodingKey {
        case create
        case update
        case rename
        case delete
        case discard
    }

    private struct CreatePayload: Codable {
        let path: String
        let content: DaemonDraftContent
        let description: String?
    }

    private struct UpdatePayload: Codable {
        let id: String
        let content: DaemonDraftContent
        let description: String?
    }

    private struct RenamePayload: Codable {
        let id: String
        let newPath: String
        let description: String?
    }

    private struct DeletePayload: Codable {
        let id: String
        let description: String?
    }

    private struct DiscardPayload: Codable {
        let id: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(CreatePayload.self, forKey: .create) {
            self = .create(path: value.path, content: value.content, description: value.description)
        } else if let value = try container.decodeIfPresent(UpdatePayload.self, forKey: .update) {
            self = .update(id: value.id, content: value.content, description: value.description)
        } else if let value = try container.decodeIfPresent(RenamePayload.self, forKey: .rename) {
            self = .rename(id: value.id, newPath: value.newPath, description: value.description)
        } else if let value = try container.decodeIfPresent(DeletePayload.self, forKey: .delete) {
            self = .delete(id: value.id, description: value.description)
        } else if let value = try container.decodeIfPresent(DiscardPayload.self, forKey: .discard) {
            self = .discard(id: value.id)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown daemon draft operation")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .create(let path, let content, let description):
            try container.encode(CreatePayload(path: path, content: content, description: description), forKey: .create)
        case .update(let id, let content, let description):
            try container.encode(UpdatePayload(id: id, content: content, description: description), forKey: .update)
        case .rename(let id, let newPath, let description):
            try container.encode(RenamePayload(id: id, newPath: newPath, description: description), forKey: .rename)
        case .delete(let id, let description):
            try container.encode(DeletePayload(id: id, description: description), forKey: .delete)
        case .discard(let id):
            try container.encode(DiscardPayload(id: id), forKey: .discard)
        }
    }
}

enum IssueLifecycle: String, Codable, CaseIterable, Hashable, Sendable {
    case open
    case closed
}

enum IssueBoardState: String, Codable, CaseIterable, Hashable, Sendable {
    case todo
    case inProgress = "in_progress"
    case paused
    case inReview = "in_review"
    case done
}

enum IssueGateAction: String, Codable, Hashable, Sendable {
    case approveClosure = "approve_closure"
    case requestChanges = "request_changes"
    case reopen
}

enum IssueRemovalAction: String, Codable, Hashable, Sendable {
    case archive
    case delete
}

enum IssueExternalReferenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case issue
    case pullRequest = "pull_request"
}

struct IssueExternalReference: Codable, Equatable, Hashable, Sendable {
    let kind: IssueExternalReferenceKind
    let url: String
}

enum IssueBlockingFactKind: String, Codable, Hashable, Sendable {
    case hostCapability = "host_capability"
    case external
}

struct IssueBlockingFact: Codable, Equatable, Hashable, Sendable {
    let factId: String
    let kind: IssueBlockingFactKind
    let value: String?
    let description: String
    let satisfied: Bool
}

enum IssueBlockingReasonKind: String, Codable, Hashable, Sendable {
    case dependency
    case fact
}

struct IssueBlockingReason: Codable, Equatable, Hashable, Sendable {
    let kind: IssueBlockingReasonKind
    let issueKey: String?
    let title: String?
    let boardState: IssueBoardState?
    let factId: String?
    let description: String?
}

struct IssueDependencyState: Codable, Equatable, Hashable, Sendable {
    let issueKey: String
    let title: String
    let boardState: IssueBoardState
}

enum AgentRunHost: String, Codable, Hashable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case manual
    case zed
    case opencode
    /// DeepSeek Harness web sessions (hook-issued runs).
    case dsh
    /// Google Antigravity lifecycle hook integration.
    case antigravity
    /// Host added by a newer daemon than this app build; the board must keep
    /// decoding instead of failing the whole payload.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRunHost(rawValue: raw) ?? .unknown
    }
}

enum AgentRunKind: String, Codable, Hashable, Sendable {
    case root
    case subagent
}

enum AgentRunPhase: String, Codable, Hashable, Sendable {
    case running
    case ended
}

enum AgentRunOutcome: String, Codable, Hashable, Sendable {
    case completed
    case blocked
    case failed
    case cancelled
    case unknown
}

enum IssueBoardDiagnosticCode: String, Codable, Hashable, Sendable {
    case malformedPath = "malformed_path"
    case malformedTitle = "malformed_title"
    case titleNumberMismatch = "title_number_mismatch"
    case duplicateIssueNumber = "duplicate_issue_number"
}

struct IssueBoardListRequest: Codable, Equatable, Sendable {
    let projectId: String
}

struct IssueDetailRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueNumber: Int
}

struct IssueDetailResponse: Codable, Equatable, Sendable {
    let issue: IssueBoardCard
    let body: String
    let acceptanceCriteria: [String]
}

struct ApplyIssueGateRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueNumber: Int
    let expectedRevision: Int
    let action: IssueGateAction
}

struct SetVerificationStepCompletedRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueKey: String
    let expectedRevision: Int
    let stepIndex: Int
    let completed: Bool
}

struct UnclaimIssueRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueKey: String
    let expectedRevision: Int
    /// AgentRun releasing its own Issue; nil for a human (desktop) release of
    /// a Paused or abandoned In Progress Issue back to Todo.
    let runId: String?
}

struct ResumeIssueRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueKey: String
    let takeover: Bool
    /// AgentRun resuming the Issue; nil for a human (desktop) resume.
    let runId: String?
}

struct VerificationStep: Codable, Equatable, Hashable, Sendable {
    let text: String
    var completed: Bool
}

struct IssueStateEvent: Codable, Equatable, Hashable, Sendable {
    let fromState: IssueBoardState
    let toState: IssueBoardState
    let changedByRunId: String?
    let occurredAt: String
}

struct IssueMutationResponse: Codable, Equatable, Sendable {
    let issueId: String
    let issueKey: String
    let boardState: IssueBoardState
    let revision: Int
    let updatedAt: String
}

struct IssueWorkflowMutationResponse: Codable, Equatable, Sendable {
    let issueId: String
    let issueKey: String
    let boardState: IssueBoardState
    let stateRevision: Int
    let stateUpdatedAt: String
    let run: AgentRun?
}

struct RemoveIssueRequest: Codable, Equatable, Sendable {
    let projectId: String
    let issueNumber: Int
    let expectedRevision: Int
    let action: IssueRemovalAction
}

struct IssueRemovalResponse: Codable, Equatable, Sendable {
    let issueId: String
    let issueKey: String
    let action: IssueRemovalAction
    let removedAt: String
}

struct IssueBoardResponse: Codable, Equatable, Sendable {
    let projectId: String
    let effectiveHash: String
    let issues: [IssueBoardCard]
    let unlinkedRuns: [AgentRun]
    let diagnostics: [IssueBoardDiagnostic]
}

struct IssueBoardCard: Codable, Identifiable, Equatable, Sendable {
    var id: String { issueId }

    let issueId: String
    let projectId: String
    let issueNumber: Int
    let issueKey: String
    let resourceId: String
    let path: String
    let lifecycle: IssueLifecycle
    let title: String
    let description: String
    let descriptionExcerpt: String
    let externalReferences: [IssueExternalReference]
    let foundAt: String?
    let createdAt: String?
    let startedAt: String?
    let closedAt: String?
    let archivedAt: String?
    let contentHash: String
    let sourceCommitId: String?
    let draftId: String?
    let draftRevision: String?
    let boardState: IssueBoardState
    let stateRevision: Int
    let stateUpdatedAt: String?
    let closureSummary: String?
    let isStale: Bool
    let blocked: Bool
    let blockingReasons: [IssueBlockingReason]
    let dependencies: [IssueDependencyState]
    let blockingFacts: [IssueBlockingFact]
    let activeRuns: [AgentRun]
    let latestRun: AgentRun?
    let changedByRunId: String?
    let verificationLevel: VerificationLevel
    let verificationSteps: [VerificationStep]
    let stateEvents: [IssueStateEvent]
}

enum VerificationLevel: String, Codable, Hashable, Sendable {
    case agentSelf = "agent_self"
    case humanRequired = "human_required"
    case mixed
}

extension IssueBoardCard {
    private enum CodingKeys: String, CodingKey {
        case issueId
        case projectId
        case issueNumber
        case issueKey
        case resourceId
        case path
        case lifecycle
        case title
        case description
        case descriptionExcerpt
        case externalReferences
        case foundAt
        case createdAt
        case startedAt
        case closedAt
        case archivedAt
        case contentHash
        case sourceCommitId
        case draftId
        case draftRevision
        case boardState
        case stateRevision
        case stateUpdatedAt
        case closureSummary
        case isStale
        case blocked
        case blockingReasons
        case dependencies
        case blockingFacts
        case activeRuns
        case latestRun
        case changedByRunId
        case verificationLevel
        case verificationSteps
        case stateEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueId = try container.decode(String.self, forKey: .issueId)
        projectId = try container.decode(String.self, forKey: .projectId)
        issueNumber = try container.decode(Int.self, forKey: .issueNumber)
        issueKey = try container.decode(String.self, forKey: .issueKey)
        resourceId = try container.decode(String.self, forKey: .resourceId)
        path = try container.decode(String.self, forKey: .path)
        lifecycle = try container.decode(IssueLifecycle.self, forKey: .lifecycle)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        descriptionExcerpt = try container.decodeIfPresent(
            String.self,
            forKey: .descriptionExcerpt
        ) ?? description
        externalReferences = try container.decodeIfPresent(
            [IssueExternalReference].self,
            forKey: .externalReferences
        ) ?? []
        foundAt = try container.decodeIfPresent(String.self, forKey: .foundAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        closedAt = try container.decodeIfPresent(String.self, forKey: .closedAt)
        archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        sourceCommitId = try container.decodeIfPresent(String.self, forKey: .sourceCommitId)
        draftId = try container.decodeIfPresent(String.self, forKey: .draftId)
        draftRevision = try container.decodeIfPresent(String.self, forKey: .draftRevision)
        boardState = try container.decode(IssueBoardState.self, forKey: .boardState)
        stateRevision = try container.decode(Int.self, forKey: .stateRevision)
        stateUpdatedAt = try container.decodeIfPresent(String.self, forKey: .stateUpdatedAt)
        closureSummary = try container.decodeIfPresent(String.self, forKey: .closureSummary)
        isStale = try container.decode(Bool.self, forKey: .isStale)
        blocked = try container.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        blockingReasons = try container.decodeIfPresent(
            [IssueBlockingReason].self,
            forKey: .blockingReasons
        ) ?? []
        dependencies = try container.decodeIfPresent(
            [IssueDependencyState].self,
            forKey: .dependencies
        ) ?? []
        blockingFacts = try container.decodeIfPresent(
            [IssueBlockingFact].self,
            forKey: .blockingFacts
        ) ?? []
        activeRuns = try container.decode([AgentRun].self, forKey: .activeRuns)
        latestRun = try container.decodeIfPresent(AgentRun.self, forKey: .latestRun)
        changedByRunId = try container.decodeIfPresent(String.self, forKey: .changedByRunId)
        verificationLevel = try container.decodeIfPresent(
            VerificationLevel.self,
            forKey: .verificationLevel
        ) ?? .agentSelf
        verificationSteps = try container.decodeIfPresent(
            [VerificationStep].self,
            forKey: .verificationSteps
        ) ?? []
        stateEvents = try container.decodeIfPresent(
            [IssueStateEvent].self,
            forKey: .stateEvents
        ) ?? []
    }
}

struct AgentRun: Codable, Identifiable, Equatable, Sendable {
    var id: String { runId }

    let runId: String
    let projectId: String
    let issueNumber: Int?
    let host: AgentRunHost
    let hostRunKey: String
    let hostSessionId: String?
    let parentRunId: String?
    let kind: AgentRunKind
    let phase: AgentRunPhase
    let outcome: AgentRunOutcome?
    let endReason: String?
    let displayLabel: String?
    let summary: String?
    let revision: Int
    let startedAt: String
    let lastSeenAt: String
    let leaseExpiresAt: String
    let endedAt: String?
}

struct IssueBoardDiagnostic: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(resourceId):\(code.rawValue):\(path)" }

    let resourceId: String
    let path: String
    let code: IssueBoardDiagnosticCode
    let message: String
}

enum RetrievalRunStatus: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case failed
}

enum RetrievalExclusionReason: String, Codable, Hashable, Sendable {
    case selected
    case belowRelevance = "below_relevance"
    case overlap
    case perResourceLimit = "per_resource_limit"
    case tokenBudget = "token_budget"
    case fragmentLimit = "fragment_limit"
    case notReranked = "not_reranked"
}

enum RetrievalDeltaAction: String, Codable, Hashable, Sendable {
    case add
    case replace
    case reuse
}

struct RetrievalRunListRequest: Codable, Sendable {
    let projectId: String?
    let status: RetrievalRunStatus?
    let cursor: String?
    let limit: Int?
}

struct RetrievalRunRequest: Codable, Sendable {
    let runId: String
}

struct RetrievalRunListResponse: Codable, Sendable {
    let items: [RetrievalRun]
    let nextCursor: String?
}

struct RetrievalStageLatencies: Codable, Equatable, Sendable {
    let effectiveMemoryUs: UInt64
    let indexEnsureUs: UInt64
    let bm25Us: UInt64
    let embeddingUs: UInt64
    let vectorUs: UInt64
    let rrfUs: UInt64
    let rerankUs: UInt64
    let assemblyUs: UInt64
    let persistenceUs: UInt64
    let totalUs: UInt64
}

struct RetrievalRun: Codable, Identifiable, Equatable, Sendable {
    var id: String { runId }

    let runId: String
    let projectId: String
    let query: String
    let activationStateFingerprint: String
    let status: RetrievalRunStatus
    let effectiveHash: String?
    let indexRevision: String?
    let resourceCount: UInt64
    let unitCount: UInt64
    let parserVersion: String?
    let chunkerVersion: String?
    let modelRevision: String?
    let rankingProfile: String?
    let latencies: RetrievalStageLatencies
    let returnedFragmentCount: UInt64
    let returnedTokenCount: UInt64
    let errorStage: String?
    let errorCode: String?
    let errorSummary: String?
    let createdAt: String
    let completedAt: String?
    let evaluationCaseId: String?
    let evaluationCaseStatus: EvaluationCaseStatus?
}

struct RetrievalSourceLocator: Codable, Equatable, Sendable {
    let type: String
    let startByte: UInt64
    let endByte: UInt64
    let headingPath: [String]
}

struct RetrievalCandidate: Codable, Identifiable, Equatable, Sendable {
    var id: String { unitKey }

    let unitKey: String
    let resourceId: String
    let scope: DaemonDraftScope
    let kind: DaemonResourceKind
    let path: String
    let headingPath: [String]
    let locator: RetrievalSourceLocator
    let contentHash: String
    let resourceContentHash: String
    let tokenCount: UInt64
    let evidenceExcerpt: String
    let exactRank: UInt64?
    let bm25Rank: UInt64?
    let bm25Score: Double?
    let vectorRank: UInt64?
    let vectorScore: Double?
    let rrfRank: UInt64?
    let rrfScore: Double?
    let rerankerRank: UInt64?
    let rerankerLogit: Double?
    let rerankerRelevance: Double?
    let finalRank: UInt64?
    let selected: Bool
    let exclusionReason: RetrievalExclusionReason
    let deltaAction: RetrievalDeltaAction?
}

struct RetrievalRunDetail: Codable, Sendable {
    let run: RetrievalRun
    let candidates: [RetrievalCandidate]
    let evaluationCase: EvaluationCase?
    let evidence: [EvaluationEvidence]
    let evidenceSuggestions: [EvaluationEvidenceSuggestion]
    let report: RetrievalBenchmarkReport?
}

struct CreateEvaluationCaseRequest: Codable, Sendable {
    let runId: String
}

struct ResolveEvaluationCaseRequest: Codable, Sendable {
    let caseId: String
    let expectedVersion: UInt64
    let evidence: [EvaluationEvidenceInput]
    let noneMatched: Bool
}

struct EvaluationEvidenceInput: Codable, Hashable, Sendable {
    let resourceId: String
    let unitKey: String?
}

enum EvaluationCaseStatus: String, Codable, Equatable, Sendable {
    case draft
    case needsEvidence = "needs_evidence"
    case ready
}

struct EvaluationCase: Codable, Identifiable, Equatable, Sendable {
    var id: String { caseId }

    let caseId: String
    let sourceRunId: String
    let corpusId: String
    let projectId: String
    let query: String
    let status: EvaluationCaseStatus
    let version: UInt64
    let createdAt: String
    let updatedAt: String
}

struct EvaluationEvidence: Codable, Identifiable, Equatable, Sendable {
    var id: String { evidenceId }

    let evidenceId: String
    let caseId: String
    let resourceId: String
    let unitKey: String?
    let evidenceExcerpt: String
}

enum RetrievalFailureStage: String, Codable, Equatable, Sendable {
    case fusion
    case reranking
    case assembly
}

struct EvaluationEvidenceSuggestion: Codable, Identifiable, Equatable, Sendable {
    var id: String { unitKey }

    let resourceId: String
    let unitKey: String
    let path: String
    let headingPath: [String]
    let evidenceExcerpt: String
    let modelRelevance: Double?
    let likelyFailureStage: RetrievalFailureStage
    let exclusionReason: RetrievalExclusionReason
}

struct RetrievalBenchmarkMetrics: Codable, Equatable, Sendable {
    let caseCount: UInt64
    let recallAt20: Double
    let ndcgAt10: Double
    let mrr: Double
    let resourceDiversity: Double
    let scopeViolation: Double
    let staleResult: Double
    let warmP50Us: UInt64
    let warmP95Us: UInt64
}

struct RetrievalBenchmarkReport: Codable, Equatable, Sendable {
    let variants: [String: RetrievalBenchmarkMetrics]
}

struct EvaluationCaseDetail: Codable, Sendable {
    let evaluationCase: EvaluationCase
    let evidence: [EvaluationEvidence]
    let evidenceSuggestions: [EvaluationEvidenceSuggestion]
    let report: RetrievalBenchmarkReport?
}

struct ClearRetrievalRunsRequest: Codable, Sendable {
    let projectId: String?
}

struct ClearRetrievalRunsResponse: Codable, Sendable {
    let deletedRunCount: UInt64
}

struct ExportEvaluationSetRequest: Codable, Sendable {
    let projectId: String?
    let caseIds: [String]
}

struct ExportEvaluationSetResponse: Codable, Sendable {
    let fixtureJson: String
    let report: RetrievalBenchmarkReport
}
