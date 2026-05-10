//! Draft feature state. Tracks local rule/context draft metadata and PR
//! composer form state shared by workspace and artifact interactions.

const std = @import("std");
const drafts_mod = @import("../../../drafts.zig");

pub const DraftTarget = struct {
    ws_id: []const u8,
    category: drafts_mod.DraftCategory,
    path: []const u8,
    rule_id: ?[]const u8 = null,
    context_id: ?[]const u8 = null,
};

pub const PendingPrAction = struct {
    target: DraftTarget,
    status_on_success: drafts_mod.DraftStatus,
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    by_rule_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    by_context_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    by_meta_prompt_path: std.StringHashMapUnmanaged(drafts_mod.DraftStatus) = .{},
    by_rule_draft_path: std.StringHashMapUnmanaged([]const u8) = .{},
    by_context_draft_path: std.StringHashMapUnmanaged([]const u8) = .{},
    by_meta_prompt_draft_path: std.StringHashMapUnmanaged([]const u8) = .{},
    by_rule_local_id: std.StringHashMapUnmanaged([]const u8) = .{},
    by_context_local_id: std.StringHashMapUnmanaged([]const u8) = .{},
    by_meta_prompt_local_id: std.StringHashMapUnmanaged([]const u8) = .{},
    create_rule_paths: []const []const u8 = &.{},
    create_context_paths: []const []const u8 = &.{},
    total: usize = 0,
    cache_ws_id: ?[]const u8 = null,
    cache_seeded: bool = false,
    index_size: u64 = 0,
    index_mtime: i128 = 0,
    last_index_check_tick: u64 = 0,
    pending_discard_target: ?DraftTarget = null,
    pending_discard_path_owned: ?[]const u8 = null,
    pending_pr_action: ?PendingPrAction = null,
    pending_pr_action_ws_id_owned: ?[]const u8 = null,
    pending_pr_action_path_owned: ?[]const u8 = null,

    show_pr_composer: bool = false,
    pr_composer_title_buf: [80]u8 = .{0} ** 80,
    pr_composer_title_len: usize = 0,
    pr_composer_body_buf: [512]u8 = .{0} ** 512,
    pr_composer_body_len: usize = 0,
    pr_composer_focus: enum { title, body } = .title,
    pr_composer_target: ?DraftTarget = null,
    pr_composer_operation: drafts_mod.DraftOperation = .modify,
    pr_composer_path_owned: ?[]const u8 = null,
    pr_composer_batch_targets: []DraftTarget = &.{},
    pr_composer_submitting: bool = false,

    show_new_draft_form: bool = false,
    new_draft_path_buf: [128]u8 = .{0} ** 128,
    new_draft_path_len: usize = 0,
    new_draft_category: drafts_mod.DraftCategory = .rule,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
};
