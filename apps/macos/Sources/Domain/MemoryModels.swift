import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case hub
    case local
    case bundles
    case reviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hub: "Hub"
        case .local: "Local"
        case .bundles: "Bundles"
        case .reviews: "Reviews"
        }
    }

    var symbol: String {
        switch self {
        case .hub: "cloud"
        case .local: "macbook.and.ipod"
        case .bundles: "shippingbox"
        case .reviews: "checkmark.bubble"
        }
    }
}

enum MemoryKind: String, Codable, Identifiable, Sendable {
    case context
    case rules
    case workflows
    case metaprompt

    static let userMaintainedCases: [MemoryKind] = [.context, .rules, .workflows]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .context: "Context"
        case .rules: "Rules"
        case .workflows: "Workflow"
        case .metaprompt: "Metaprompt"
        }
    }

    var isUserMaintained: Bool {
        Self.userMaintainedCases.contains(self)
    }

    var singularTitle: String {
        switch self {
        case .context: "Context"
        case .rules: "Rule"
        case .workflows: "Workflow"
        case .metaprompt: "Metaprompt"
        }
    }

    var symbol: String {
        switch self {
        case .context: "doc.text"
        case .rules: "checklist"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .metaprompt: "text.bubble"
        }
    }

    var daemonKind: DaemonResourceKind {
        switch self {
        case .context: .context
        case .rules: .rule
        case .workflows: .workflow
        case .metaprompt: .metaprompt
        }
    }

    func supportsMarkdownPreview(path: String) -> Bool {
        switch self {
        case .rules, .workflows, .metaprompt:
            return true
        case .context:
            let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            return pathExtension == "md" || pathExtension == "markdown"
        }
    }

    init(_ daemonKind: DaemonResourceKind) {
        switch daemonKind {
        case .context: self = .context
        case .rule: self = .rules
        case .workflow: self = .workflows
        case .metaprompt: self = .metaprompt
        }
    }
}

enum MemoryScope: String, Codable, Sendable {
    case org
    case project
}

struct EditableMemoryDocument: Hashable, Sendable {
    var title: String
    var path: String
    var body: String
    var appliesWhen: String
    var tags: [String]
}

struct MemoryResource: Identifiable, Hashable, Sendable {
    let id: String
    let scope: MemoryScope
    let projectId: String?
    let projectName: String?
    let kind: MemoryKind
    let contentHash: String
    let updatedAt: String
    let refCommitId: String?
    var contentLoaded: Bool
    var document: EditableMemoryDocument
}

struct LocalDraft: Identifiable, Hashable, Sendable {
    let id: String
    let projectId: String
    let serverId: String?
    let serverVersion: Int
    let baseCommitId: String?
    let scope: MemoryScope
    let kind: MemoryKind
    let targetId: String?
    let status: DaemonLocalDraftStatus
    let origin: DaemonDraftOperationSource
    let syncStatus: DaemonDraftSyncState
    let conflict: DaemonDraftConflict?
    let updatedAt: String
    var document: EditableMemoryDocument
    var isDeletion: Bool
}

struct MemoryListItem: Identifiable, Hashable, Sendable {
    let id: String
    let resource: MemoryResource?
    let draft: LocalDraft?
    let inherited: Bool

    var document: EditableMemoryDocument {
        draft?.document ?? resource?.document ?? .init(
            title: "Untitled",
            path: "",
            body: "",
            appliesWhen: "",
            tags: []
        )
    }

    var kind: MemoryKind { draft?.kind ?? resource?.kind ?? .context }
    var scope: MemoryScope { draft?.scope ?? resource?.scope ?? .project }
    var projectId: String? { draft?.projectId ?? resource?.projectId }
    var contentLoaded: Bool { draft != nil || resource?.contentLoaded == true }

    var supportsMarkdownPreview: Bool {
        kind.supportsMarkdownPreview(path: document.path)
    }
}

struct PersonalBundle: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String
    var resourceIds: [String]
    let revision: Int
    let updatedAt: String
}

struct ReviewRecord: Identifiable, Hashable, Sendable {
    let id: String
    let projectId: String
    let draftId: String
    let title: String
    let description: String
    let author: UserReference
    let status: String
    let version: Int
    let decisionBody: String?
    let updatedAt: String
    let operationCount: Int
    let commentCount: Int
    let conflict: DaemonDraftConflict?
}

struct ReviewChangeSources: Sendable {
    let baseContent: String?
    let currentContent: String?
    let draftContent: String?
    let resolutionContent: String?
    let operationLabels: [String]
}

struct ProjectState: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let refCommitId: String?
    let refEtag: String
    let selectedOrgResourceIds: Set<String>
    let orgSelectionRevision: Int
    let isLoaded: Bool
}

struct RuntimeState: Sendable {
    let health: DaemonHealth
    let sync: DaemonSyncStatus
    let mcp: DaemonMCPStatus
    let serverDataSource: String
}

enum WorkbenchTabMode: String, Hashable, Sendable {
    case source
    case preview
}

struct WorkbenchTab: Identifiable, Hashable, Sendable {
    var id: String {
        "\(section.rawValue):\(projectId ?? "shared"):\(itemId):\(mode.rawValue)"
    }

    let section: WorkspaceSection
    let projectId: String?
    let itemId: String
    let mode: WorkbenchTabMode
    let title: String

    func isVisible(in section: WorkspaceSection, projectId: String?) -> Bool {
        guard self.section == section else { return false }
        guard section == .local else { return true }
        return self.projectId == projectId
    }
}
