import Foundation

struct UserReference: Codable, Hashable, Sendable {
    let userId: String
    let email: String
    let displayName: String?
    let avatarUrl: String?
    let role: String
}

struct OrganizationReference: Codable, Hashable, Sendable {
    let orgId: String
    let name: String
}

struct ProjectReference: Codable, Identifiable, Hashable, Sendable {
    var id: String { projectId }

    let projectId: String
    let name: String
}

struct ProjectRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { projectId }

    let projectId: String
    let name: String
    let description: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
}

struct CreateProjectRequest: Codable, Sendable {
    let name: String
    let description: String?
}

struct UpdateProjectRequest: Codable, Sendable {
    let name: String?
    let description: String?
}

struct CurrentUserResponse: Codable, Sendable {
    let user: UserReference
    let org: OrganizationReference
    let projects: [ProjectReference]
    let defaultProjectId: String?
    let capabilities: [String]
}

struct PageInfo: Codable, Sendable {
    let nextCursor: String?
    let hasMore: Bool
}

struct ListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let pageInfo: PageInfo
}

struct RuleMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String { ruleId }

    let ruleId: String
    let scope: String
    let projectId: String?
    let path: String
    let name: String
    let contentHash: String
    let status: String
    let updatedAt: String
}

struct ContextMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String { contextId }

    let contextId: String
    let scope: String
    let projectId: String?
    let kind: String
    let path: String
    let contentHash: String
    let size: Int
    let updatedAt: String
}

struct WorkflowMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String { workflowId }

    let workflowId: String
    let scope: String
    let projectId: String?
    let path: String
    let name: String
    let contentHash: String
    let status: String
    let updatedAt: String
}

struct RuleDetail: Codable, Sendable {
    let rule: RuleMetadata
    let content: String
    let etag: String
}

struct ContextDetail: Codable, Sendable {
    let context: ContextMetadata
    let content: String
    let etag: String
}

struct WorkflowDetail: Codable, Sendable {
    let workflow: WorkflowMetadata
    let content: String
    let etag: String
}

struct PersonalBundleMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleId }

    let bundleId: String
    let ownerUserId: String
    let name: String
    let description: String
    let ruleCount: Int
    let contextCount: Int
    let workflowCount: Int
    let revision: Int
    let createdAt: String
    let updatedAt: String
}

struct PersonalBundleDetail: Codable, Sendable {
    let bundle: PersonalBundleMetadata
    let rules: [RuleMetadata]
    let context: [ContextMetadata]
    let workflows: [WorkflowMetadata]
    let etag: String
}

struct PersonalBundleRequest: Codable, Sendable {
    let name: String
    let description: String
    let ruleIds: [String]
    let contextIds: [String]
    let workflowIds: [String]
}

struct ProjectOrgSelection: Codable, Sendable {
    let projectId: String
    let rules: [RuleMetadata]
    let context: [ContextMetadata]
    let workflows: [WorkflowMetadata]
    let revision: Int
}

struct CommitStateResponse: Codable, Sendable {
    let updateAvailable: Bool
    let ref: CommitReference
    let latest: CommitMetadata?
    let downloadUrl: String?
    let incrementalSupported: Bool
}

struct CommitReference: Codable, Sendable {
    let name: String
    let scope: String
    let orgId: String
    let projectId: String?
    let commitId: String?
    let updatedAt: String
}

struct CommitMetadata: Codable, Sendable {
    let commitId: String
    let scope: String
    let orgId: String
    let projectId: String?
    let treeId: String
    let parentCommitId: String?
    let version: Int
    let createdAt: String
}

struct CommitPayload: Codable, Sendable {
    let commit: CommitMetadata
    let tree: CommitTree
    let blobs: [CommitBlob]
}

struct CommitTree: Codable, Sendable {
    let treeId: String
    let entries: [CommitTreeEntry]
}

enum ServerTreeEntryKind: String, Codable, Hashable, Sendable {
    case context
    case rule
    case workflow
    case projectOrgSelection = "project_org_selection"

    init(_ kind: DaemonResourceKind) {
        switch kind {
        case .context: self = .context
        case .rule: self = .rule
        case .workflow: self = .workflow
        }
    }
}

struct CommitTreeEntry: Codable, Sendable {
    let id: String
    let type: ServerTreeEntryKind
    let scope: String
    let projectId: String?
    let path: String?
    let blobId: String
    let source: String
}

struct CommitBlob: Codable, Sendable {
    let blobId: String
    let content: String
}

struct ReviewMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String { reviewId }

    let reviewId: String
    let projectId: String
    let draftId: String
    let author: UserReference
    let title: String
    let description: String
    let status: String
    let version: Int
    let decisionBody: String?
    let approvedResultHash: String?
    let coordination: DraftCoordination
    let createdAt: String
    let updatedAt: String
}

struct ReviewComment: Codable, Identifiable, Hashable, Sendable {
    var id: String { commentId }

    let commentId: String
    let reviewId: String
    let author: UserReference
    let body: String
    let createdAt: String
}

struct ServerDraftResourceReference: Codable, Hashable, Sendable {
    let scope: String
    let kind: DaemonResourceKind
    let id: String?
    let path: String?
}

struct ServerDraft: Codable, Sendable {
    let draftId: String
    let projectId: String
    let baseCommitId: String?
    let author: UserReference
    let title: String
    let description: String
    let resource: ServerDraftResourceReference
    let status: String
    let coordination: DraftCoordination
    let version: Int
    let createdAt: String
    let updatedAt: String
}

struct ServerDraftOperation: Codable, Identifiable, Sendable {
    var id: String { operationId }

    let action: String
    let resource: ServerDraftResourceReference
    let content: DaemonDraftContent?
    let newPath: String?
    let operationId: String
    let createdAt: String
}

struct ReviewDetail: Codable, Sendable {
    let review: ReviewMetadata
    let draft: ServerDraft
    let operations: [ServerDraftOperation]
    let comments: [ReviewComment]
}

struct DraftCoordination: Codable, Hashable, Sendable {
    let freshness: DraftFreshness
    let currentCommitId: String?
    let hasUpstreamResourceChanges: Bool
    let reconciliation: DraftReconciliationStatus
    let candidateId: String?
}

struct ReconciliationResourceState: Codable, Hashable, Sendable {
    let exists: Bool
    let resource: ServerDraftResourceReference
    let content: DaemonDraftContent?
}

struct ReconciliationConflict: Codable, Hashable, Sendable {
    let kind: String
    let field: String
    let base: String?
    let current: String?
    let draft: String?
}

struct DraftReconciliationCandidate: Codable, Identifiable, Hashable, Sendable {
    var id: String { candidateId }

    let candidateId: String
    let draftId: String
    let draftVersion: Int
    let baseCommitId: String?
    let currentCommitId: String?
    let status: DraftReconciliationStatus
    let baseState: ReconciliationResourceState
    let currentState: ReconciliationResourceState
    let draftState: ReconciliationResourceState
    let proposedState: ReconciliationResourceState?
    let conflicts: [ReconciliationConflict]
    let resultHash: String?
    let valid: Bool
    let createdAt: String
    let invalidatedAt: String?

    var hasDraftResultChanges: Bool {
        draftState != (proposedState ?? draftState)
    }
}

struct CreateDraftReconciliationCandidateRequest: Codable, Sendable {
    let expectedDraftVersion: Int
}

struct CreateDraftRebaseRequest: Codable, Sendable {
    let candidateId: String
    let expectedDraftVersion: Int
    let resolvedState: ReconciliationResourceState?
}

struct DraftRebaseResult: Codable, Sendable {
    let rebaseId: String
    let previousRevisionId: String
    let draft: ServerDraftDetail
    let review: ReviewMetadata?
    let approvalInvalidated: Bool
}

struct ServerDraftDetail: Codable, Sendable {
    let draft: ServerDraft
    let operations: [ServerDraftOperation]
    let syncState: ServerDraftSyncState
}

struct ServerDraftSyncState: Codable, Sendable {
    let status: String
    let serverCursor: String?
    let daemonInstallationId: String?
}

struct CreateReviewRequest: Codable, Sendable {
    let draftId: String
    let expectedDraftVersion: Int
    let title: String
    let description: String
    let candidateId: String?
    let resolvedState: ReconciliationResourceState?
}

struct CreateReviewSubmissionRequest: Codable, Sendable {
    let expectedReviewVersion: Int
    let expectedDraftVersion: Int
    let title: String
    let description: String
    let candidateId: String?
    let resolvedState: ReconciliationResourceState?
}

struct CreateReviewCommentRequest: Codable, Sendable {
    let body: String
}

struct CreateReviewDecisionRequest: Codable, Sendable {
    let decision: String
    let expectedReviewVersion: Int
    let body: String
}

struct CreateReviewMergeRequest: Codable, Sendable {
    let expectedReviewVersion: Int
}

struct DraftOperationInput: Codable, Sendable {
    let action: String
    let resource: ServerDraftResourceReference
    let content: DaemonDraftContent?
    let newPath: String?
}

struct ReviewMergeResponse: Codable, Sendable {
    let review: ReviewMetadata
    let commitId: String?
    let appliedOperationCount: Int
}

struct ReplaceProjectOrgSelectionRequest: Codable, Sendable {
    let ruleIds: [String]
    let contextIds: [String]
    let workflowIds: [String]
}

struct DeleteResult: Codable, Sendable {
    let deleted: Bool
    let id: String
}

struct TokenResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
}

struct TokenExchangeRequest: Encodable, Sendable {
    let grantType = "authorization_code"
    let code: String
    let redirectUri: String
    let codeVerifier: String
}
