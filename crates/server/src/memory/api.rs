use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::api::PageInfo;

/// Neutral, verifiable export of the org's effective Memory state for the
/// Unified Memory migration: every Memory, active Draft, Project org
/// selection, and personal
/// bundles. IDs are emitted as-is so the export doubles as the
/// old_id -> memory_id identity map (identity is preserved).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryExport {
    pub org_id: String,
    pub exported_at: String,
    pub memories: Vec<MemoryExportItem>,
    pub drafts: Vec<MemoryExportDraft>,
    pub selections: Vec<MemoryExportSelection>,
    pub bundles: Vec<MemoryExportBundle>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryExportItem {
    pub memory_id: String,
    pub scope: String,
    pub project_id: Option<String>,
    pub path: String,
    pub name: String,
    pub description: String,
    pub status: String,
    pub content_hash: String,
    pub body: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryExportDraft {
    pub draft_id: String,
    pub project_id: String,
    pub title: String,
    pub description: String,
    pub resource_scope: String,
    pub target_id: Option<String>,
    pub path: Option<String>,
    pub status: String,
    pub version: i64,
    pub operations: Vec<serde_json::Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryExportSelection {
    pub project_id: String,
    pub resource_ids: Vec<String>,
    pub revision: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryExportBundle {
    pub bundle_id: String,
    pub owner_user_id: String,
    pub name: String,
    pub description: String,
    pub resource_ids: Vec<String>,
    pub revision: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleRequest {
    pub name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub resource_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleUpdateRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub resource_ids: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleListResponse {
    pub items: Vec<PersonalBundleMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleDetail {
    pub bundle: PersonalBundleMeta,
    pub memories: Vec<MemoryMeta>,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalBundleMeta {
    pub bundle_id: String,
    pub owner_user_id: String,
    pub name: String,
    pub description: String,
    pub resource_count: i64,
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

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ResourceStatus {
    Active,
    Deprecated,
    Archived,
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
    Memory,
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
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
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
    pub memories: Vec<MemoryMeta>,
    pub revision: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplaceProjectOrgSelectionRequest {
    #[serde(default)]
    pub resource_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryListResponse {
    pub items: Vec<MemoryMeta>,
    pub page_info: PageInfo,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryDetail {
    pub memory: MemoryMeta,
    pub content: String,
    pub etag: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryMeta {
    pub memory_id: String,
    pub scope: ResourceScope,
    pub project_id: Option<String>,
    pub path: String,
    pub name: String,
    pub description: String,
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

impl ResourceScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Org => "org",
            Self::Project => "project",
        }
    }
}
