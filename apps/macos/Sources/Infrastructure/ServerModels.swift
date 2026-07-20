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

struct RuleContent: Codable, Hashable, Sendable {
    let appliesWhen: String
    let constraint: String
    let tags: [String]
}

struct RuleDetail: Codable, Sendable {
    let rule: RuleMetadata
    let content: RuleContent
    let etag: String
}

struct ContextDetail: Codable, Sendable {
    let context: ContextMetadata
    let content: String
    let etag: String
}

struct WorkflowContent: Codable, Hashable, Sendable {
    let description: String
    let steps: [WorkflowStep]
}

struct WorkflowStep: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(order):\(ruleId ?? ""):\(body ?? "")" }

    let order: Int
    let ruleId: String?
    let body: String?
}

struct WorkflowDetail: Codable, Sendable {
    let workflow: WorkflowMetadata
    let content: WorkflowContent
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

struct CommitTreeEntry: Codable, Sendable {
    let id: String
    let type: DaemonResourceKind
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
    let conflict: DaemonDraftConflict?
}

struct CreateReviewRequest: Codable, Sendable {
    let draftId: String
    let expectedDraftVersion: Int
    let title: String
    let description: String
}

struct CreateReviewSubmissionRequest: Codable, Sendable {
    let expectedReviewVersion: Int
    let expectedDraftVersion: Int
    let title: String
    let description: String
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

struct CreateReviewConflictResolutionRequest: Codable, Sendable {
    let expectedReviewVersion: Int
    let expectedDraftVersion: Int
    let operations: [DraftOperationInput]
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
