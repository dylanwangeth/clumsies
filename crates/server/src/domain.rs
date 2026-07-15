use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct User {
    pub user_id: String,
    pub email: String,
    pub display_name: Option<String>,
    pub role: String,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Org {
    pub org_id: String,
    pub name: String,
    pub revision: i64,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Project {
    pub project_id: String,
    pub org_id: String,
    pub name: String,
    pub description: String,
    pub revision: i64,
    pub created_at: OffsetDateTime,
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
pub enum ResourceKind {
    Rule,
    Context,
    Workflow,
}

impl ResourceKind {
    pub fn id_prefix(self) -> &'static str {
        match self {
            Self::Rule => "rul",
            Self::Context => "ctx",
            Self::Workflow => "wfl",
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum DraftResourceKind {
    Context,
    Rule,
    Workflow,
    Metaprompt,
}

impl DraftResourceKind {
    pub fn as_resource_kind(self) -> Option<ResourceKind> {
        match self {
            Self::Context => Some(ResourceKind::Context),
            Self::Rule => Some(ResourceKind::Rule),
            Self::Workflow => Some(ResourceKind::Workflow),
            Self::Metaprompt => None,
        }
    }
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
pub enum ContextKind {
    File,
    Note,
    Decision,
    Reference,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowStep {
    pub order: i32,
    pub rule_id: Option<String>,
    pub body: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowStepInput {
    pub rule_id: Option<String>,
    pub body: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RuleContent {
    pub applies_when: String,
    pub constraint: String,
    pub tags: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowContent {
    pub description: String,
    pub steps: Vec<WorkflowStep>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResourceRecord {
    pub resource_id: String,
    pub org_id: String,
    pub project_id: Option<String>,
    pub scope: ResourceScope,
    pub kind: ResourceKind,
    pub path: String,
    pub name: String,
    pub status: ResourceStatus,
    pub revision: i64,
    pub content_hash: String,
    pub body: String,
    pub context_kind: Option<ContextKind>,
    pub workflow_steps: Vec<WorkflowStep>,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MetapromptRecord {
    pub metaprompt_id: String,
    pub org_id: String,
    pub project_id: Option<String>,
    pub scope: ResourceScope,
    pub status: ResourceStatus,
    pub revision: i64,
    pub content_hash: String,
    pub body: String,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectOrgSelection {
    pub project_id: String,
    pub rule_ids: Vec<String>,
    pub context_ids: Vec<String>,
    pub workflow_ids: Vec<String>,
    pub revision: i64,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundle {
    pub bundle_id: String,
    pub owner_user_id: String,
    pub name: String,
    pub description: String,
    pub rule_ids: Vec<String>,
    pub context_ids: Vec<String>,
    pub workflow_ids: Vec<String>,
    pub revision: i64,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
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
        name: Option<String>,
        description: String,
        steps: Vec<WorkflowStepInput>,
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
    pub operation_id: String,
    pub input: DraftOperationInput,
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Draft {
    pub draft_id: String,
    pub project_id: String,
    pub base_commit_id: Option<String>,
    pub author_user_id: String,
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
    pub daemon_installation_id: Option<String>,
    pub conflict_count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftDetail {
    pub draft: Draft,
    pub operations: Vec<DraftOperation>,
    pub sync_state: DraftSyncState,
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
    pub draft_id: String,
    pub project_id: String,
    pub author_user_id: String,
    pub title: String,
    pub description: String,
    pub status: ReviewStatus,
    pub version: i64,
    pub decision_body: Option<String>,
    pub created_at: OffsetDateTime,
    pub updated_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewMerge {
    pub merge_id: String,
    pub review_id: String,
    pub commit_id: Option<String>,
    pub applied_operation_count: usize,
    pub created_at: OffsetDateTime,
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

impl From<ResourceKind> for TreeEntryKind {
    fn from(kind: ResourceKind) -> Self {
        match kind {
            ResourceKind::Rule => Self::Rule,
            ResourceKind::Context => Self::Context,
            ResourceKind::Workflow => Self::Workflow,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TreeEntry {
    pub id: String,
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
pub struct Commit {
    pub commit_id: String,
    pub scope: CommitScope,
    pub org_id: String,
    pub project_id: Option<String>,
    pub tree_id: String,
    pub parent_commit_id: Option<String>,
    pub version: i64,
    pub created_at: OffsetDateTime,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateDraftRequest {
    pub project_id: String,
    pub base_commit_id: Option<String>,
    pub title: String,
    pub description: Option<String>,
    pub resource: DraftResourceRef,
    pub operations: Vec<DraftOperationInput>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreatePersonalBundleRequest {
    pub owner_user_id: String,
    pub name: String,
    pub description: String,
    pub rule_ids: Vec<String>,
    pub context_ids: Vec<String>,
    pub workflow_ids: Vec<String>,
}
