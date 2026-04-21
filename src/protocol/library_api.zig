//! Library API response shapes. The Library is the org's prompt collection (single source of
//! truth). These types describe prompt metadata, content, and bundle membership used by CLI
//! sync and TUI display.
const manifest = @import("manifest.zig");

pub const LibraryManifestResponse = struct {
    revision: i32,
    prompts: manifest.ManifestMap,
};

pub const PromptMeta = struct {
    prompt_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
    source: []const u8 = "",
};

pub const PromptListResponse = struct {
    prompts: []const PromptMeta = &.{},
};

pub const PromptContentResponse = struct {
    prompt_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    body: []const u8,
};

/// Batch prompt content fetch. Used by `clumsies sync` to pull many
/// prompts in one request instead of one GET per prompt. The single
/// PromptContentResponse endpoint (used by TUI on-demand loads)
/// remains; this is an additive sync-oriented path.
pub const BatchPromptContentRequest = struct {
    prompt_ids: []const []const u8,
};

pub const BatchPromptItem = struct {
    prompt_id: []const u8,
    path: []const u8 = "",
    content_hash: []const u8 = "",
    body: []const u8 = "",
    /// Per-item error code when a specific prompt could not be
    /// served (e.g. `NOT_FOUND`, `FORBIDDEN`). Empty string means the
    /// item was served successfully; callers should check this
    /// before treating body as authoritative.
    @"error": []const u8 = "",
};

pub const BatchPromptContentResponse = struct {
    items: []const BatchPromptItem = &.{},
};

pub const BundleMeta = struct {
    name: []const u8,
    description: []const u8 = "",
    updated_at: []const u8 = "",
    prompt_count: i64 = 0,
    prompt_ids: []const []const u8 = &.{},
};

pub const BundleListResponse = struct {
    bundles: []const BundleMeta = &.{},
};
