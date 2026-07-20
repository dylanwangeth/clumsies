use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserRef {
    pub user_id: String,
    pub email: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub role: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OrgRef {
    pub org_id: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectRef {
    pub project_id: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MeResponse {
    pub user: UserRef,
    pub org: OrgRef,
    pub projects: Vec<ProjectRef>,
    pub default_project_id: Option<String>,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClientKind {
    Desktop,
    Cli,
    WebAdmin,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct OidcAuthorizationRequest {
    pub client_kind: ClientKind,
    pub redirect_uri: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    pub state: Option<String>,
    pub login_hint: Option<String>,
    pub return_to: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct OidcCallbackRequest {
    pub code: Option<String>,
    pub state: String,
    pub error: Option<String>,
    pub error_description: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TokenGrantType {
    AuthorizationCode,
    RefreshToken,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenRequest {
    pub grant_type: TokenGrantType,
    pub code: Option<String>,
    pub redirect_uri: Option<String>,
    pub code_verifier: Option<String>,
    pub refresh_token: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub token_type: String,
    pub expires_in: i64,
    pub user: UserRef,
    pub org: OrgRef,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRevoked {
    pub revoked: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WebAdminSession {
    pub user: UserRef,
    pub org: OrgRef,
    pub capabilities: Vec<String>,
    pub token_id: String,
    pub csrf_token: String,
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InstallationState {
    SetupRequired,
    Initialized,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetupConfiguration {
    pub org_name: String,
    pub default_project_name: String,
    pub allowed_email_domains: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetupSessionStatus {
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    pub configuration: Option<SetupConfiguration>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetupStatus {
    pub state: InstallationState,
    pub setup_code_configured: bool,
    pub oidc_configured: bool,
    pub session: Option<SetupSessionStatus>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateSetupSessionRequest {
    pub setup_code: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateSetupSessionResponse {
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    pub csrf_token: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplaceSetupConfigurationRequest {
    pub org_name: String,
    pub default_project_name: String,
    pub allowed_email_domains: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetupOidcAuthorizationRequest {
    pub redirect_uri: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetupOidcAuthorization {
    pub authorization_url: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OrgRole {
    Owner,
    Admin,
    Member,
}

impl OrgRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Member => "member",
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemberStatus {
    Invited,
    Active,
    Disabled,
}

impl MemberStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Invited => "invited",
            Self::Active => "active",
            Self::Disabled => "disabled",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminOrg {
    pub org_id: String,
    pub name: String,
    pub allowed_email_domains: Vec<String>,
    pub revision: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateAdminOrgRequest {
    pub name: Option<String>,
    pub allowed_email_domains: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateMemberRequest {
    pub email: String,
    pub role: OrgRole,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateMemberRequest {
    pub role: Option<OrgRole>,
    pub status: Option<MemberStatus>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Member {
    pub user_id: String,
    pub email: String,
    pub display_name: Option<String>,
    pub role: OrgRole,
    pub status: MemberStatus,
    pub external_identity_bound: bool,
    pub revision: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemberListResponse {
    pub items: Vec<Member>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminProject {
    pub project_id: String,
    pub name: String,
    pub description: String,
    pub member_count: i64,
    pub revision: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdminProjectListResponse {
    pub items: Vec<AdminProject>,
    pub page_info: PageInfo,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProjectRole {
    Member,
    Admin,
}

impl ProjectRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Member => "member",
            Self::Admin => "admin",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectMember {
    pub project_id: String,
    pub user: UserRef,
    pub role: ProjectRole,
    #[serde(with = "time::serde::rfc3339")]
    pub joined_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectMemberListResponse {
    pub items: Vec<ProjectMember>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateProjectMemberRequest {
    pub user_id: String,
    pub role: ProjectRole,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateProjectMemberRequest {
    pub role: ProjectRole,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AccessTokenKind {
    Access,
    Refresh,
    Integration,
    WebSession,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AdmissionMode {
    InviteOnly,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SecretSource {
    DeploymentEnvironment,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OidcProviderStatus {
    pub protocol: String,
    pub configured: bool,
    pub issuer: Option<String>,
    pub callback_url: Option<String>,
    pub admission_mode: AdmissionMode,
    pub secret_source: SecretSource,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccessTokenMeta {
    pub token_id: String,
    pub user_id: String,
    pub kind: AccessTokenKind,
    pub revoked: bool,
    #[serde(with = "time::serde::rfc3339::option")]
    pub expires_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccessTokenListResponse {
    pub items: Vec<AccessTokenMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuditEvent {
    pub event_id: String,
    pub actor_user_id: Option<String>,
    pub action: String,
    pub target_type: String,
    pub target_id: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuditEventListResponse {
    pub items: Vec<AuditEvent>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateProjectRequest {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateProjectRequest {
    pub name: Option<String>,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectListResponse {
    pub items: Vec<Project>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Project {
    pub project_id: String,
    pub name: String,
    pub description: String,
    pub revision: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeleteResult {
    pub deleted: bool,
    pub id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleRequest {
    pub name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub rule_ids: Vec<String>,
    #[serde(default)]
    pub context_ids: Vec<String>,
    #[serde(default)]
    pub workflow_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleUpdateRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub rule_ids: Option<Vec<String>>,
    pub context_ids: Option<Vec<String>>,
    pub workflow_ids: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleListResponse {
    pub items: Vec<PersonalBundleMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleDetail {
    pub bundle: PersonalBundleMeta,
    pub rules: Vec<RuleMeta>,
    pub context: Vec<ContextMeta>,
    pub workflows: Vec<WorkflowMeta>,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleMeta {
    pub bundle_id: String,
    pub owner_user_id: String,
    pub name: String,
    pub description: String,
    pub rule_count: i64,
    pub context_count: i64,
    pub workflow_count: i64,
    pub revision: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ResourceScope {
    Org,
    Project,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum DraftResourceKind {
    Context,
    Rule,
    Workflow,
    Metaprompt,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ResourceStatus {
    Active,
    Deprecated,
    Archived,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DraftStatus {
    Open,
    Submitted,
    Discarded,
    Conflicted,
    Merged,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DraftOperationAction {
    Create,
    Update,
    Rename,
    Delete,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftResourceRef {
    pub scope: ResourceScope,
    pub kind: DraftResourceKind,
    pub id: Option<String>,
    pub path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DraftResourceContent {
    Context {
        content: String,
    },
    Rule {
        name: Option<String>,
        applies_when: Option<String>,
        constraint: String,
        tags: Option<Vec<String>>,
    },
    Workflow {
        content: String,
    },
    Metaprompt {
        content: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationInput {
    pub action: DraftOperationAction,
    pub resource: DraftResourceRef,
    pub content: Option<DraftResourceContent>,
    pub new_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperation {
    #[serde(flatten)]
    pub input: DraftOperationInput,
    pub operation_id: String,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Draft {
    pub draft_id: String,
    pub project_id: String,
    pub base_commit_id: Option<String>,
    pub author: UserRef,
    pub title: String,
    pub description: String,
    pub resource: DraftResourceRef,
    pub status: DraftStatus,
    pub version: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DraftSyncStatus {
    Synced,
    Pending,
    Conflicted,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftSyncState {
    pub status: DraftSyncStatus,
    pub server_cursor: Option<String>,
    pub daemon_installation_id: Option<String>,
    pub conflict_count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftConflict {
    pub base_commit_id: Option<String>,
    pub current_commit_id: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub detected_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftDetail {
    pub draft: Draft,
    pub operations: Vec<DraftOperation>,
    pub sync_state: DraftSyncState,
    pub conflict: Option<DraftConflict>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftListResponse {
    pub items: Vec<Draft>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateDraftRequest {
    pub daemon_installation_id: String,
    pub project_id: String,
    pub base_commit_id: Option<String>,
    pub title: String,
    pub description: Option<String>,
    pub resource: DraftResourceRef,
    #[serde(default)]
    pub operations: Vec<DraftOperationInput>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateDraftRequest {
    pub title: Option<String>,
    pub description: Option<String>,
    pub status: Option<DraftStatus>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftEventListResponse {
    pub events: Vec<DraftEvent>,
    pub next_cursor: Option<String>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftEvent {
    pub event_id: String,
    pub draft_id: String,
    pub project_id: String,
    pub event_type: DraftEventType,
    pub version: i64,
    pub daemon_installation_id: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DraftEventType {
    Created,
    Updated,
    OperationAppended,
    Discarded,
    Submitted,
    Reopened,
    Conflicted,
    Merged,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationBatchRequest {
    pub daemon_installation_id: String,
    pub operations: Vec<DraftOperationBatchItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationBatchItem {
    pub local_operation_id: String,
    pub draft_id: String,
    pub expected_draft_version: i64,
    pub operation: DraftOperationInput,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationBatchResponse {
    pub accepted_operations: Vec<String>,
    pub cursor: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewRequest {
    pub draft_id: String,
    pub expected_draft_version: i64,
    pub title: Option<String>,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewSubmissionRequest {
    pub expected_review_version: i64,
    pub expected_draft_version: i64,
    pub title: Option<String>,
    pub description: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStatus {
    Open,
    Approved,
    Rejected,
    Merged,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Review {
    pub review_id: String,
    pub project_id: String,
    pub draft_id: String,
    pub author: UserRef,
    pub title: String,
    pub description: String,
    pub status: ReviewStatus,
    pub version: i64,
    pub decision_body: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewDetail {
    pub review: Review,
    pub draft: Draft,
    pub operations: Vec<DraftOperation>,
    pub comments: Vec<ReviewComment>,
    pub conflict: Option<DraftConflict>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewListResponse {
    pub items: Vec<Review>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewCommentListResponse {
    pub items: Vec<ReviewComment>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewComment {
    pub comment_id: String,
    pub review_id: String,
    pub author: UserRef,
    pub body: String,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewCommentRequest {
    pub body: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewDecisionRequest {
    pub decision: ReviewDecision,
    pub expected_review_version: i64,
    pub body: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReviewDecision {
    Approved,
    Rejected,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewMergeRequest {
    pub expected_review_version: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateReviewConflictResolutionRequest {
    pub expected_review_version: i64,
    pub expected_draft_version: i64,
    pub operations: Vec<DraftOperationInput>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewMergeResult {
    pub review: Review,
    pub commit_id: Option<String>,
    pub applied_operation_count: i64,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CommitScope {
    Org,
    Project,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TreeEntryScope {
    Org,
    Project,
    Daemon,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TreeEntrySource {
    Org,
    Project,
    SelectedOrg,
    Bootstrap,
    Config,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TreeEntryKind {
    Rule,
    Context,
    Workflow,
    Metaprompt,
    ProjectOrgSelection,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Commit {
    pub commit_id: String,
    pub scope: CommitScope,
    pub org_id: String,
    pub project_id: Option<String>,
    pub tree_id: String,
    pub parent_commit_id: Option<String>,
    pub version: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Ref {
    pub name: String,
    pub scope: CommitScope,
    pub org_id: String,
    pub project_id: Option<String>,
    pub commit_id: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommitStateResponse {
    pub update_available: bool,
    #[serde(rename = "ref")]
    pub reference: Ref,
    pub latest: Option<Commit>,
    pub download_url: Option<String>,
    pub incremental_supported: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TreeEntry {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: TreeEntryKind,
    pub scope: TreeEntryScope,
    pub project_id: Option<String>,
    pub path: Option<String>,
    pub blob_id: String,
    pub source: TreeEntrySource,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Tree {
    pub tree_id: String,
    pub entries: Vec<TreeEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Blob {
    pub blob_id: String,
    pub content: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommitPayload {
    pub commit: Commit,
    pub tree: Tree,
    pub blobs: Vec<Blob>,
    pub project_org_selection: Option<ProjectOrgSelection>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectOrgSelection {
    pub project_id: String,
    pub rules: Vec<RuleMeta>,
    pub context: Vec<ContextMeta>,
    pub workflows: Vec<WorkflowMeta>,
    pub revision: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplaceProjectOrgSelectionRequest {
    #[serde(default)]
    pub rule_ids: Vec<String>,
    #[serde(default)]
    pub context_ids: Vec<String>,
    #[serde(default)]
    pub workflow_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuleListResponse {
    pub items: Vec<RuleMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextListResponse {
    pub items: Vec<ContextMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowListResponse {
    pub items: Vec<WorkflowMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuleDetail {
    pub rule: RuleMeta,
    pub content: RuleContent,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextDetail {
    pub context: ContextMeta,
    pub content: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowDetail {
    pub workflow: WorkflowMeta,
    pub content: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuleContent {
    pub applies_when: String,
    pub constraint: String,
    pub tags: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MetapromptDetail {
    pub metaprompt: MetapromptMeta,
    pub content: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MetapromptMeta {
    pub metaprompt_id: String,
    pub scope: ResourceScope,
    pub project_id: Option<String>,
    pub path: String,
    pub content_hash: String,
    pub status: ResourceStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuleMeta {
    pub rule_id: String,
    pub scope: ResourceScope,
    pub project_id: Option<String>,
    pub path: String,
    pub name: String,
    pub content_hash: String,
    pub status: ResourceStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextMeta {
    pub context_id: String,
    pub scope: ResourceScope,
    pub project_id: Option<String>,
    pub kind: ContextKind,
    pub path: String,
    pub content_hash: String,
    pub size: i64,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ContextKind {
    File,
    Note,
    Decision,
    Reference,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowMeta {
    pub workflow_id: String,
    pub scope: ResourceScope,
    pub project_id: Option<String>,
    pub path: String,
    pub name: String,
    pub content_hash: String,
    pub status: ResourceStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommitListResponse {
    pub items: Vec<Commit>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PageInfo {
    pub next_cursor: Option<String>,
    pub has_more: bool,
}

impl DraftResourceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Rule => "rule",
            Self::Workflow => "workflow",
            Self::Metaprompt => "metaprompt",
        }
    }

    pub fn resource_id_prefix(self) -> &'static str {
        match self {
            Self::Context => "ctx",
            Self::Rule => "rul",
            Self::Workflow => "wfl",
            Self::Metaprompt => "mpf",
        }
    }
}

impl DraftResourceContent {
    pub fn kind(&self) -> DraftResourceKind {
        match self {
            Self::Context { .. } => DraftResourceKind::Context,
            Self::Rule { .. } => DraftResourceKind::Rule,
            Self::Workflow { .. } => DraftResourceKind::Workflow,
            Self::Metaprompt { .. } => DraftResourceKind::Metaprompt,
        }
    }
}

impl ResourceScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Org => "org",
            Self::Project => "project",
        }
    }
}

impl DraftOperationAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Update => "update",
            Self::Rename => "rename",
            Self::Delete => "delete",
        }
    }
}

impl DraftEventType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Updated => "updated",
            Self::OperationAppended => "operation_appended",
            Self::Discarded => "discarded",
            Self::Submitted => "submitted",
            Self::Reopened => "reopened",
            Self::Conflicted => "conflicted",
            Self::Merged => "merged",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_timestamps_use_rfc3339() {
        let event = AuditEvent {
            event_id: "evt_test".to_owned(),
            actor_user_id: None,
            action: "test.created".to_owned(),
            target_type: "test".to_owned(),
            target_id: None,
            created_at: OffsetDateTime::UNIX_EPOCH,
        };

        let json = serde_json::to_value(&event).expect("serialize audit event");
        assert_eq!(json["created_at"], "1970-01-01T00:00:00Z");

        let decoded: AuditEvent = serde_json::from_value(json).expect("deserialize audit event");
        assert_eq!(decoded.created_at, OffsetDateTime::UNIX_EPOCH);
    }
}
