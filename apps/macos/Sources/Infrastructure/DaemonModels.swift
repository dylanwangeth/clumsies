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
    let serverUrl: String
    let projectId: String?
    let daemonInstallationId: String
    let logDir: String
    let localDb: DaemonLocalDatabaseStatus
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
    case context
    case rule
    case workflow
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

enum DaemonDraftContent: Codable, Hashable, Sendable {
    case context(content: String)
    case rule(content: String)
    case workflow(content: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(DaemonResourceKind.self, forKey: .kind)
        switch kind {
        case .context:
            self = .context(content: try container.decode(String.self, forKey: .content))
        case .rule:
            self = .rule(content: try container.decode(String.self, forKey: .content))
        case .workflow:
            self = .workflow(content: try container.decode(String.self, forKey: .content))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .context(let content):
            try container.encode(DaemonResourceKind.context, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .rule(let content):
            try container.encode(DaemonResourceKind.rule, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .workflow(let content):
            try container.encode(DaemonResourceKind.workflow, forKey: .kind)
            try container.encode(content, forKey: .content)
        }
    }

    var primaryText: String {
        switch self {
        case .context(let content), .rule(let content), .workflow(let content):
            return content
        }
    }

    var renderedText: String {
        switch self {
        case .context(let content), .rule(let content), .workflow(let content):
            return content
        }
    }

    func replacingPrimaryText(with text: String) -> Self {
        switch self {
        case .context:
            .context(content: text)
        case .rule:
            .rule(content: text)
        case .workflow:
            .workflow(content: text)
        }
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
    let judgments: [EvaluationJudgment]
    let corpusResources: [EvaluationCorpusResource]
    let report: RetrievalBenchmarkReport?
}

struct CreateEvaluationCaseRequest: Codable, Sendable {
    let runId: String
    let queryCategory: String?
    let notes: String?
}

struct ReplaceEvaluationJudgmentsRequest: Codable, Sendable {
    let caseId: String
    let expectedJudgmentVersion: UInt64
    let judgments: [EvaluationJudgmentInput]
}

struct EvaluationJudgmentInput: Codable, Hashable, Sendable {
    let resourceId: String
    let unitKey: String?
    let relevance: UInt8
    let missed: Bool
    let notes: String?
}

struct EvaluationCase: Codable, Identifiable, Equatable, Sendable {
    var id: String { caseId }

    let caseId: String
    let sourceRunId: String
    let corpusId: String
    let projectId: String
    let query: String
    let queryCategory: String?
    let notes: String?
    let judgmentVersion: UInt64
    let createdAt: String
    let updatedAt: String
}

struct EvaluationJudgment: Codable, Identifiable, Equatable, Sendable {
    var id: String { judgmentId }

    let judgmentId: String
    let caseId: String
    let resourceId: String
    let unitKey: String?
    let relevance: UInt8
    let missed: Bool
    let evidenceExcerpt: String
    let notes: String?
}

struct EvaluationCorpusResource: Codable, Identifiable, Equatable, Sendable {
    var id: String { resourceId }

    let resourceId: String
    let scope: DaemonDraftScope
    let kind: DaemonResourceKind
    let path: String
    let title: String
    let contentHash: String
    let sourceCommitId: String?
    let draftId: String?
    let draftRevision: String?
    let preview: String
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
    let judgments: [EvaluationJudgment]
    let corpusResources: [EvaluationCorpusResource]
    let report: RetrievalBenchmarkReport
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
