//! Workspace API request and response shapes. ContextFile describes a file in the workspace's
//! context tree (project knowledge). WorkspaceManifestResponse carries the manifest that drives
//! the sync protocol — each entry maps a rule path to its content hash.
//! CreateWorkspaceRequest / CreateWorkspaceResponse are the wire contract for POST
//! /api/workspaces, shared between hub, cli and tui.
const manifest = @import("manifest.zig");

pub const ContextFile = struct {
    context_id: []const u8 = "",
    path: []const u8,
    content_hash: []const u8,
    size: i64 = 0,
    author: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const ContextFilesResponse = struct {
    files: []const ContextFile = &.{},
};

/// Batch context content fetch. Clients use paths as stable content
/// keys for both on-demand and bulk content loads.
pub const BatchContextContentRequest = struct {
    paths: []const []const u8,
};

pub const BatchContextItem = struct {
    path: []const u8,
    content_hash: []const u8 = "",
    body: []const u8 = "",
    @"error": []const u8 = "",
};

pub const BatchContextContentResponse = struct {
    items: []const BatchContextItem = &.{},
};

pub const WorkspaceManifestResponse = struct {
    ws_id: []const u8,
    name: []const u8,
    revision: i32,
    rules: manifest.ManifestMap,
    context: manifest.ManifestMap,
};

pub const CreateWorkspaceRequest = struct {
    name: []const u8,
    description: []const u8,
    bundle_id: ?[]const u8 = null,
};

pub const CreateWorkspaceResponse = struct {
    ws_id: []const u8,
    name: []const u8,
    description: []const u8,
    revision: i32 = 0,
};

pub const UpdateWorkspaceRequest = struct {
    name: []const u8,
    description: []const u8,
};

pub const WorkspaceRulesRequest = struct {
    rule_ids: []const []const u8,
};

pub const WorkspaceRulesResponse = struct {
    revision: i32,
};

pub const WorkspaceMember = struct {
    user_id: []const u8,
    username: []const u8,
    role: []const u8,
    joined_at: []const u8,
};

pub const WorkspaceMembersResponse = struct {
    members: []const WorkspaceMember = &.{},
};
