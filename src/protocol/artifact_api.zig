//! Artifact API response shapes. The Artifact is the org's rule collection (single source of
//! truth). These types describe rule metadata, content, and bundle membership used by CLI
//! sync and TUI display.
const manifest = @import("manifest.zig");

pub const ArtifactManifestResponse = struct {
    revision: i32,
    rules: manifest.ManifestMap,
};

pub const RuleMeta = struct {
    rule_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    updated_at: []const u8,
    source: []const u8 = "",
};

pub const RuleListResponse = struct {
    rules: []const RuleMeta = &.{},
};

pub const RuleContentResponse = struct {
    rule_id: []const u8,
    path: []const u8,
    content_hash: []const u8,
    body: []const u8,
};

/// Batch rule content fetch. Clients use this endpoint for both
/// on-demand and bulk content loads, including one-item requests.
pub const BatchRuleContentRequest = struct {
    rule_ids: []const []const u8,
};

pub const BatchRuleItem = struct {
    rule_id: []const u8,
    path: []const u8 = "",
    content_hash: []const u8 = "",
    body: []const u8 = "",
    /// Per-item error code when a specific rule could not be
    /// served (e.g. `NOT_FOUND`, `FORBIDDEN`). Empty string means the
    /// item was served successfully; callers should check this
    /// before treating body as authoritative.
    @"error": []const u8 = "",
};

pub const BatchRuleContentResponse = struct {
    items: []const BatchRuleItem = &.{},
};

pub const BundleMeta = struct {
    bundle_id: []const u8 = "",
    name: []const u8,
    description: []const u8 = "",
    updated_at: []const u8 = "",
    rule_count: i64 = 0,
    rule_ids: []const []const u8 = &.{},
};

pub const CreateBundleRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    rule_ids: []const []const u8 = &.{},
};

pub const UpdateBundleRequest = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    rule_ids: ?[]const []const u8 = null,
};

pub const BundleListResponse = struct {
    bundles: []const BundleMeta = &.{},
};
