//! Built-in `Glob` tool.
//!
//! `Glob` enumerates workspace files and returns paths matching a small glob
//! pattern. It is deliberately read-only and bounded by `Context.max_matches`.

const std = @import("std");
const tool = @import("../core/tool.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Glob",
    .description = "Find workspace files matching a glob pattern.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}
    ,
    .kind = .observe,
    .effects = .{ .reads_workspace = true },
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The common `invoke` name keeps the registry/dispatcher generic, while this
/// file owns the provider JSON parsing and workspace traversal semantics for
/// `Glob`. Keeping those details here lets the tool's schema, behavior, and
/// tests evolve together.
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
        if (!workspace.matchesGlob(args.pattern, entry.path)) continue;
        if (count >= context.max_matches) break;
        try out.writer(allocator).print("{s}\n", .{entry.path});
        count += 1;
    }

    if (count == 0) try out.appendSlice(allocator, "no matches\n");
    return .{ .content = try out.toOwnedSlice(allocator), .owns_content = true };
}

const Args = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
};

const testing = std.testing;

test "Glob lists matching files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(testing.allocator, context, "{\"pattern\":\"*.zig\"}");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "src/root.zig") != null);
}
