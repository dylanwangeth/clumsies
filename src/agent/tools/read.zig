//! Built-in `Read` tool.
//!
//! `Read` is the narrow file-inspection primitive. It opens a workspace-local
//! file, returns numbered lines, and never lets model-provided paths escape the
//! configured workspace root.

const std = @import("std");
const tool = @import("../core/tool.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Read",
    .description = "Read a bounded range from a workspace file.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"line_count":{"type":"integer","minimum":1}},"required":["path"]}
    ,
    .kind = .observe,
    .effects = .{ .reads_workspace = true },
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// Every built-in tool exposes `invoke` so `builtin.zig` can dispatch a
/// resolved provider tool call without knowing each tool's argument schema.
/// This file owns the boundary from provider JSON to workspace file IO, keeping
/// path validation, output shape, and result ownership close to the `Read`
/// definition.
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

    var file = try workspace_dir.openFile(args.path, .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, context.max_read_bytes);
    defer allocator.free(file_content);

    const content = try formatResult(
        allocator,
        args.path,
        file_content,
        args.start_line orelse 1,
        args.line_count orelse context.max_matches,
    );
    return .{ .content = content, .owns_content = true };
}

/// Formats file content for the next provider turn.
///
/// Tool output becomes model input. Numbered lines give the model stable
/// context for follow-up reads or edits without returning the whole file.
fn formatResult(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    start_line: usize,
    line_count: usize,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.writer(allocator).print("file: {s}\n", .{path});

    var current_line: usize = 1;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (current_line += 1) {
        if (current_line < start_line) continue;
        if (emitted >= line_count) break;
        try out.writer(allocator).print("{d}: {s}\n", .{ current_line, line });
        emitted += 1;
    }

    if (emitted == 0) try out.appendSlice(allocator, "no lines in range\n");
    return out.toOwnedSlice(allocator);
}

const Args = struct {
    path: []const u8,
    start_line: ?usize = null,
    line_count: ?usize = null,
};

const testing = std.testing;

test "Read returns numbered file content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "main.zig",
        .data = "const std = @import(\"std\");\npub fn main() void {}\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"path\":\"main.zig\",\"line_count\":1}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "file: main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "1: const std") != null);
}
