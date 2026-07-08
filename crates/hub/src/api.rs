use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserRef {
    pub user_id: String,
    pub email: String,
    pub display_name: Option<String>,
    pub role: String,
    pub auth_provider: AuthProvider,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateProjectRequest {
    pub org_id: String,
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
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeleteResult {
    pub deleted: bool,
    pub id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleRequest {
    pub owner_user_id: String,
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
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthProvider {
    Google,
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
    pub kind: DraftResourceKind,
    pub id: Option<String>,
    pub path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationInput {
    pub action: DraftOperationAction,
    pub resource: DraftResourceRef,
    pub base_hash: Option<String>,
    pub body: Option<String>,
    pub new_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperation {
    #[serde(flatten)]
    pub input: DraftOperationInput,
    pub operation_id: String,
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Draft {
    pub draft_id: String,
    pub project_id: String,
    pub author: UserRef,
    pub title: String,
    pub description: String,
    pub resource: DraftResourceRef,
    pub status: DraftStatus,
    pub version: i64,
    pub created_at: OffsetDateTime,
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
    pub runtime_installation_id: Option<String>,
    pub conflict_count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftDetail {
    pub draft: Draft,
    pub operations: Vec<DraftOperation>,
    pub sync_state: DraftSyncState,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftListResponse {
    pub items: Vec<Draft>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateDraftRequest {
    pub author_user_id: String,
    pub runtime_installation_id: String,
    pub project_id: String,
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
    pub runtime_installation_id: Option<String>,
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
    Conflicted,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftOperationBatchRequest {
    pub runtime_installation_id: String,
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
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewDetail {
    pub review: Review,
    pub draft: Draft,
    pub operations: Vec<DraftOperation>,
    pub comments: Vec<ReviewComment>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewComment {
    pub comment_id: String,
    pub review_id: String,
    pub author: UserRef,
    pub body: String,
    pub created_at: OffsetDateTime,
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
    pub expected_target_version: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewMergeResult {
    pub review: Review,
    pub snapshot_id: Option<String>,
    pub applied_operation_count: i64,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotScope {
    Org,
    Project,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotItemScope {
    Org,
    Project,
    Runtime,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotSource {
    Org,
    Project,
    SelectedOrg,
    Bootstrap,
    Config,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotItemKind {
    Rule,
    Context,
    Workflow,
    Metaprompt,
    ProjectOrgSelection,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotManifest {
    pub snapshot_id: String,
    pub scope: SnapshotScope,
    pub project_id: Option<String>,
    pub version: i64,
    pub created_at: OffsetDateTime,
    pub items: Vec<SnapshotManifestItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotManifestItem {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: SnapshotItemKind,
    pub scope: SnapshotItemScope,
    pub project_id: Option<String>,
    pub path: Option<String>,
    pub content_hash: Option<String>,
    pub source: SnapshotSource,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotContentItem {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: SnapshotItemKind,
    pub scope: SnapshotItemScope,
    pub project_id: Option<String>,
    pub path: Option<String>,
    pub content_hash: String,
    pub content: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotPayload {
    pub manifest: SnapshotManifest,
    pub content_items: Vec<SnapshotContentItem>,
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
    pub body: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextDetail {
    pub context: ContextMeta,
    pub body: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowDetail {
    pub workflow: WorkflowMeta,
    pub steps: Vec<WorkflowStep>,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowStep {
    pub order: i32,
    pub rule_id: Option<String>,
    pub body: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MetapromptDetail {
    pub metaprompt: MetapromptMeta,
    pub body: String,
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
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotListResponse {
    pub items: Vec<SnapshotManifest>,
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
            Self::Conflicted => "conflicted",
        }
    }
}
