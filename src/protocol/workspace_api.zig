//! Workspace API request and response shapes. ContextFile describes a file in the workspace's
//! context tree (project knowledge). WorkspaceManifestResponse carries the manifest that drives
//! the sync protocol — each entry maps a prompt path to its content hash.
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

/// Batch context content fetch. Used by `clumsies sync` to pull many
/// context files in one request instead of one GET per file. The
/// single GET endpoint (used by TUI) remains.
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
    prompts: manifest.ManifestMap,
    context: manifest.ManifestMap,
};

pub const CreateWorkspaceRequest = struct {
    name: []const u8,
    bundle_id: ?[]const u8 = null,
};

pub const CreateWorkspaceResponse = struct {
    ws_id: []const u8,
    name: []const u8,
    revision: i32 = 0,
};
