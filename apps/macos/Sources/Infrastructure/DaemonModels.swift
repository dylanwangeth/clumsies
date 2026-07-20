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
    let conflictCount: Int
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
    let scope: DaemonDraftScope
    let resourceKind: DaemonResourceKind
    let targetId: String?
    let path: String?
    let conflict: DaemonDraftConflict?
    let status: DaemonLocalDraftStatus
    let createdAt: String
    let updatedAt: String
    let pendingOperationCount: Int
    let failedOperationCount: Int
}

struct DaemonDraftConflict: Codable, Hashable, Sendable {
    let baseCommitId: String?
    let currentCommitId: String?
    let detectedAt: String
}

enum DaemonDraftScope: String, Codable, Hashable, Sendable {
    case org
    case project
}

enum DaemonResourceKind: String, Codable, Hashable, Sendable {
    case context
    case rule
    case workflow
    case metaprompt
}

enum DaemonLocalDraftStatus: String, Codable, Hashable, Sendable {
    case open
    case submitted
    case discarded
    case conflicted
    case merged
}

enum DaemonDraftOperationSource: String, Codable, Sendable {
    case desktop
    case cli
    case mcpStore = "mcp_store"
    case server
}

enum DaemonDraftSyncState: String, Codable, Sendable {
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
    case rule(name: String?, appliesWhen: String?, constraint: String, tags: [String]?)
    case workflow(content: String)
    case metaprompt(content: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case content
        case name
        case appliesWhen
        case constraint
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(DaemonResourceKind.self, forKey: .kind)
        switch kind {
        case .context:
            self = .context(content: try container.decode(String.self, forKey: .content))
        case .rule:
            self = .rule(
                name: try container.decodeIfPresent(String.self, forKey: .name),
                appliesWhen: try container.decodeIfPresent(String.self, forKey: .appliesWhen),
                constraint: try container.decode(String.self, forKey: .constraint),
                tags: try container.decodeIfPresent([String].self, forKey: .tags)
            )
        case .workflow:
            self = .workflow(content: try container.decode(String.self, forKey: .content))
        case .metaprompt:
            self = .metaprompt(content: try container.decode(String.self, forKey: .content))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .context(let content):
            try container.encode(DaemonResourceKind.context, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .rule(let name, let appliesWhen, let constraint, let tags):
            try container.encode(DaemonResourceKind.rule, forKey: .kind)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(appliesWhen, forKey: .appliesWhen)
            try container.encode(constraint, forKey: .constraint)
            try container.encodeIfPresent(tags, forKey: .tags)
        case .workflow(let content):
            try container.encode(DaemonResourceKind.workflow, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .metaprompt(let content):
            try container.encode(DaemonResourceKind.metaprompt, forKey: .kind)
            try container.encode(content, forKey: .content)
        }
    }

    var primaryText: String {
        switch self {
        case .context(let content), .workflow(let content), .metaprompt(let content):
            return content
        case .rule(_, _, let constraint, _):
            return constraint
        }
    }

    var renderedText: String {
        switch self {
        case .context(let content), .workflow(let content), .metaprompt(let content):
            return content
        case .rule(let name, let appliesWhen, let constraint, let tags):
            return [
                "# \(name ?? "Rule")",
                "",
                "## Applies when",
                "",
                appliesWhen ?? "",
                "",
                "## Constraint",
                "",
                constraint,
                "",
                "Tags: \((tags ?? []).isEmpty ? "None" : (tags ?? []).joined(separator: ", "))"
            ].joined(separator: "\n")
        }
    }

    func replacingPrimaryText(with text: String) -> Self {
        switch self {
        case .context:
            .context(content: text)
        case .rule(let name, let appliesWhen, _, let tags):
            .rule(name: name, appliesWhen: appliesWhen, constraint: text, tags: tags)
        case .workflow:
            .workflow(content: text)
        case .metaprompt:
            .metaprompt(content: text)
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
