//! Read local drafts/index.json files across all workspaces.
const std = @import("std");
const env_util = @import("clumsies_lib").util.env_util;

pub const DraftEntry = struct {
    category: []const u8,
    rule_id: ?[]const u8 = null,
    current_path: ?[]const u8 = null,
    draft_path: []const u8,
    operation: []const u8,
    status: []const u8,
};

fn getHomeDirOwned(allocator: std.mem.Allocator) ?[]u8 {
    return env_util.homeDir(allocator) catch null;
}

pub fn readAllDrafts(allocator: std.mem.Allocator) ?[]const DraftEntry {
    const home = getHomeDirOwned(allocator) orelse return null;
    defer allocator.free(home);
    const ws_root = std.fs.path.join(allocator, &.{ home, ".clumsies", "workspaces" }) catch return null;
    defer allocator.free(ws_root);

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, ws_root, .{ .iterate = true }) catch return null;
    defer dir.close(std.Options.debug_io);

    var all: std.ArrayList(DraftEntry) = .empty;
    var it = dir.iterate();
    while (it.next(std.Options.debug_io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const index_path = std.fs.path.join(allocator, &.{ ws_root, entry.name, "drafts", "index.json" }) catch continue;
        defer allocator.free(index_path);
        readIndexFile(allocator, index_path, &all);
    }

    if (all.items.len == 0) return null;
    return all.items;
}

fn readIndexFile(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DraftEntry)) void {
    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return;
    defer file.close(std.Options.debug_io);

    var buf: [64 * 1024]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, std.Options.debug_io, &read_buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch return;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return;

    const Json = struct {
        version: u32 = 1,
        drafts: []const struct {
            category: []const u8 = "",
            rule_id: ?[]const u8 = null,
            current_path: ?[]const u8 = null,
            draft_path: []const u8 = "",
            operation: []const u8 = "",
            status: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Json, allocator, buf[0..total], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    for (parsed.value.drafts) |d| {
        out.append(allocator, .{
            .category = allocator.dupe(u8, d.category) catch continue,
            .rule_id = if (d.rule_id) |pid| (allocator.dupe(u8, pid) catch continue) else null,
            .current_path = if (d.current_path) |cp| (allocator.dupe(u8, cp) catch continue) else null,
            .draft_path = allocator.dupe(u8, d.draft_path) catch continue,
            .operation = allocator.dupe(u8, d.operation) catch continue,
            .status = allocator.dupe(u8, d.status) catch continue,
        }) catch continue;
    }
}
