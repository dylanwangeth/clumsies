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

/// Batch rule content fetch. Used by `clumsies sync` to pull many
/// rules in one request instead of one GET per rule. The single
/// RuleContentResponse endpoint (used by TUI on-demand loads)
/// remains; this is an additive sync-oriented path.
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
    name: []const u8,
    description: []const u8 = "",
    updated_at: []const u8 = "",
    rule_count: i64 = 0,
    rule_ids: []const []const u8 = &.{},
};

pub const BundleListResponse = struct {
    bundles: []const BundleMeta = &.{},
};
