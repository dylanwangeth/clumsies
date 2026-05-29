//! Built-in `Write` tool.
//!
//! `Write` creates or replaces a whole workspace file. It is intentionally
//! broader than `Edit`: the model must provide the final complete file content,
//! so callers should prefer `Edit` for localized changes.

const std = @import("std");
const tool = @import("../core/tool.zig");
const tool_result = @import("result.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Write",
    .description = "Create or replace a whole workspace file.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    ,
    .kind = .mutate,
    .scheduling = .serial,
    .effects = .{ .writes_workspace = true },
    .failure_policy = .stop_on_error,
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// `Write` owns the whole-file mutation boundary. It validates that the
/// provider-supplied path stays inside the workspace, creates parent
/// directories when needed, and then replaces the target file with the exact
/// content supplied by the model.
pub fn invoke(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    arguments: []const u8,
) !tool.Result {
    const parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{});
    defer parsed.deinit();
    const args = parsed.value;
    try workspace.ensureSafePath(args.path);

    var workspace_dir = try workspace.open(context);
    defer workspace_dir.close();

    if (std.fs.path.dirname(args.path)) |parent| {
        try workspace_dir.makePath(parent);
    }

    try workspace.writeFile(workspace_dir, args.path, args.content);
    return tool_result.okPathAction(allocator, args.path, "wrote");
}

const Args = struct {
    path: []const u8,
    content: []const u8,
};

const testing = std.testing;

test "Write creates a whole file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"path\":\"src/main.zig\",\"content\":\"pub fn main() void {}\\n\"}",
    );
    defer result.deinit(testing.allocator);

    const written = try tmp.dir.readFileAlloc(testing.allocator, "src/main.zig", 1024);
    defer testing.allocator.free(written);

    try testing.expect(!result.is_error);
    try testing.expectEqualStrings("pub fn main() void {}\n", written);
}

test "Write replaces a whole file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "main.zig", .data = "old\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"path\":\"main.zig\",\"content\":\"new\\n\"}",
    );
    defer result.deinit(testing.allocator);

    const written = try tmp.dir.readFileAlloc(testing.allocator, "main.zig", 1024);
    defer testing.allocator.free(written);

    try testing.expect(!result.is_error);
    try testing.expectEqualStrings("new\n", written);
}
