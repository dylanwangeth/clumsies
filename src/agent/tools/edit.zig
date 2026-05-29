//! Built-in `Edit` tool.
//!
//! `Edit` patches an existing file by replacing one exact text occurrence. It
//! is intentionally narrower than `Write`: the old text acts as an anchor so
//! the runtime can reject missing or ambiguous edits instead of guessing where
//! the model meant to modify the file.

const std = @import("std");
const tool = @import("../core/tool.zig");
const tool_result = @import("result.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Edit",
    .description = "Patch an existing workspace file by replacing exact text.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}
    ,
    .kind = .mutate,
    .scheduling = .serial,
    .effects = .{ .reads_workspace = true, .writes_workspace = true },
    .failure_policy = .stop_on_error,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The provider-visible contract is a small exact replacement request. This
/// function owns the safety boundary that turns it into filesystem mutation:
/// the path must stay in the workspace, the old text must exist exactly once,
/// and all edit failures are returned as tool results the model can recover
/// from in the next turn.
pub fn invoke(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    arguments: []const u8,
) !tool.Result {
    const parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{});
    defer parsed.deinit();
    const args = parsed.value;

    if (args.old.len == 0) {
        return tool_result.fail(allocator, "invalid_arguments", "old text must not be empty");
    }
    try workspace.ensureSafePath(args.path);

    var workspace_dir = try workspace.open(context);
    defer workspace_dir.close();

    const content = workspace.readFileAlloc(
        allocator,
        workspace_dir,
        args.path,
        context.max_read_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return tool_result.fail(allocator, "not_found", "target file does not exist"),
        else => return err,
    };
    defer allocator.free(content);

    const matches = countMatches(content, args.old);
    if (matches == 0) return tool_result.fail(allocator, "not_found", "old text was not found");
    if (matches > 1) {
        return tool_result.fail(allocator, "ambiguous_match", "old text matched more than once");
    }

    const replacement = try replaceOnce(allocator, content, args.old, args.new);
    defer allocator.free(replacement);

    try workspace.writeFile(workspace_dir, args.path, replacement);
    return tool_result.okPathAction(allocator, args.path, "edited");
}

/// Counts non-overlapping exact matches for edit anchoring.
///
/// `Edit` must know whether an old-text anchor is unique before writing. A
/// count above one is a recoverable tool error because the model can read a
/// narrower range and provide more context.
fn countMatches(content: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, content, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}

/// Builds a new file buffer after a verified unique replacement.
///
/// The caller owns the returned buffer and is responsible for freeing it after
/// the workspace write succeeds or fails.
fn replaceOnce(
    allocator: std.mem.Allocator,
    content: []const u8,
    old: []const u8,
    new: []const u8,
) ![]const u8 {
    const index = std.mem.indexOf(u8, content, old).?;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..index]);
    try out.appendSlice(allocator, new);
    try out.appendSlice(allocator, content[index + old.len ..]);
    return out.toOwnedSlice(allocator);
}

const Args = struct {
    path: []const u8,
    old: []const u8,
    new: []const u8,
};

const testing = std.testing;

test "Edit replaces one exact text occurrence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "pub fn main() void {\n    return;\n}\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"path\":\"main.zig\",\"old\":\"return;\",\"new\":\"std.debug.print(\\\"ok\\\", .{});\"}",
    );
    defer result.deinit(testing.allocator);

    const updated = try tmp.dir.readFileAlloc(testing.allocator, "main.zig", 1024);
    defer testing.allocator.free(updated);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, updated, "std.debug.print") != null);
}

test "Edit rejects ambiguous old text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "main.zig", .data = "same\nsame\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"path\":\"main.zig\",\"old\":\"same\",\"new\":\"other\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "ambiguous_match") != null);
}
