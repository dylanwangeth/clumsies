//! Built-in `Grep` tool.
//!
//! `Grep` performs a bounded literal-text search over workspace files. It does
//! not expose regex yet, so the provider-facing description explicitly says
//! "literal text" to avoid promising behavior the implementation lacks.

const std = @import("std");
const tool = @import("../core/tool.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Grep",
    .description = "Search workspace files for literal text.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"}},"required":["pattern"]}
    ,
    .kind = .observe,
    .effects = .{ .reads_workspace = true },
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// `builtin.zig` should only decide which resolved tool to call. The `Grep`
/// module owns how provider JSON becomes a bounded workspace search, including
/// the current literal-match behavior and the model-visible result format.
pub fn invoke(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    arguments: []const u8,
) !tool.Result {
    const parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{});
    defer parsed.deinit();
    const args = parsed.value;
    const base_path = args.path orelse ".";
    try workspace.ensureSafePath(base_path);

    var workspace_dir = try workspace.open(context);
    defer workspace_dir.close();

    var base = try workspace_dir.openDir(base_path, .{ .iterate = true });
    defer base.close();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var walker = try base.walk(allocator);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (args.glob) |pattern| {
            if (!workspace.matchesGlob(pattern, entry.path)) continue;
        }
        if (count >= context.max_matches) break;

        {
            var file = base.openFile(entry.path, .{}) catch continue;
            defer file.close();
            const content = file.readToEndAlloc(allocator, context.max_read_bytes) catch continue;
            defer allocator.free(content);

            count += try appendMatches(
                allocator,
                &out,
                entry.path,
                content,
                args.pattern,
                context.max_matches - count,
            );
        }
    }

    if (count == 0) try out.appendSlice(allocator, "no matches\n");
    return .{ .content = try out.toOwnedSlice(allocator), .owns_content = true };
}

/// Appends grep matches in the conventional `path:line: text` shape.
///
/// Keeping the output familiar helps the model cite or inspect matches without
/// learning a custom tool-result format.
fn appendMatches(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    content: []const u8,
    pattern: []const u8,
    remaining: usize,
) !usize {
    var current_line: usize = 1;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (current_line += 1) {
        if (emitted >= remaining) break;
        if (std.mem.indexOf(u8, line, pattern) == null) continue;
        try out.writer(allocator).print("{s}:{d}: {s}\n", .{ path, current_line, line });
        emitted += 1;
    }
    return emitted;
}

const Args = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
};

const testing = std.testing;

test "Grep returns matching lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "src/root.zig",
        .data = "pub const agent = @import(\"agent/root.zig\");\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/other.zig",
        .data = "const std = @import(\"std\");\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(
        testing.allocator,
        context,
        "{\"pattern\":\"agent\",\"path\":\"src\",\"glob\":\"*.zig\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "root.zig:1:") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "agent/root.zig") != null);
}
