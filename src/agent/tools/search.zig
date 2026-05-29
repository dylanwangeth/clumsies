//! Built-in `Search` tool.
//!
//! `Search` is the agent-facing discovery primitive. It keeps path search and
//! content search behind one provider-visible tool because both operations ask
//! the same question: which workspace locations are relevant to the task?

const std = @import("std");
const tool = @import("../core/tool.zig");
const workspace = @import("workspace.zig");

pub const DEFINITION: tool.Definition = .{
    .name = "Search",
    .description = "Search workspace paths or file contents.",
    .parameters_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"target":{"type":"string","enum":["path","content"]},"query":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"}},"required":["target","query"]}
    ,
    .kind = .observe,
    .effects = .{ .reads_workspace = true },
};

/// Local implementation entrypoint used by the built-in tool dispatcher.
///
/// The provider sees one `Search` tool, while this function owns the internal
/// split between path discovery and content discovery. Keeping that split here
/// prevents the catalog from exposing Unix-era names such as `glob` or `grep`
/// while still letting each search mode keep focused behavior.
pub fn invoke(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    arguments: []const u8,
) !tool.Result {
    const parsed = try std.json.parseFromSlice(Args, allocator, arguments, .{});
    defer parsed.deinit();

    return switch (parsed.value.target) {
        .path => searchPaths(allocator, context, parsed.value),
        .content => searchContent(allocator, context, parsed.value),
    };
}

/// Matches the minimal path-pattern dialect exposed by `Search`.
///
/// The first tool catalog intentionally supports only `*` and `?` so providers
/// can rely on a stable schema while the implementation remains replaceable by
/// richer gitignore-aware matching later.
pub fn matchesPathPattern(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*') {
        return matchesPathPattern(pattern[1..], path) or
            (path.len > 0 and matchesPathPattern(pattern, path[1..]));
    }
    if (path.len == 0) return false;
    if (pattern[0] == '?' or pattern[0] == path[0]) {
        return matchesPathPattern(pattern[1..], path[1..]);
    }
    return false;
}

/// Searches workspace paths without opening file contents.
///
/// Path search is cheap, read-only discovery that returns relative paths
/// matching `query`.
fn searchPaths(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    args: Args,
) !tool.Result {
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
        if (!matchesPathPattern(args.query, entry.path)) continue;
        if (count >= context.max_matches) break;
        try out.writer(allocator).print("{s}\n", .{entry.path});
        count += 1;
    }

    if (count == 0) try out.appendSlice(allocator, "no matches\n");
    return .{ .content = try out.toOwnedSlice(allocator), .owns_content = true };
}

/// Searches file contents and returns path-and-line match records.
///
/// Content search still accepts an optional path-pattern filter because agents
/// commonly know both the symbol/text they need and the file family worth
/// scanning, such as `*.zig`.
fn searchContent(
    allocator: std.mem.Allocator,
    context: workspace.Context,
    args: Args,
) !tool.Result {
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
            if (!matchesPathPattern(pattern, entry.path)) continue;
        }
        if (count >= context.max_matches) break;

        var file = base.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(allocator, context.max_read_bytes) catch continue;
        defer allocator.free(content);

        count += try appendContentMatches(
            allocator,
            &out,
            entry.path,
            content,
            args.query,
            context.max_matches - count,
        );
    }

    if (count == 0) try out.appendSlice(allocator, "no matches\n");
    return .{ .content = try out.toOwnedSlice(allocator), .owns_content = true };
}

/// Appends content matches in the conventional `path:line: text` shape.
///
/// Keeping the output familiar helps the model cite or inspect matches without
/// learning a custom tool-result format.
fn appendContentMatches(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    content: []const u8,
    query: []const u8,
    remaining: usize,
) !usize {
    var current_line: usize = 1;
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (current_line += 1) {
        if (emitted >= remaining) break;
        if (std.mem.indexOf(u8, line, query) == null) continue;
        try out.writer(allocator).print("{s}:{d}: {s}\n", .{ path, current_line, line });
        emitted += 1;
    }
    return emitted;
}

const Target = enum {
    path,
    content,
};

const Args = struct {
    target: Target,
    query: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
};

const testing = std.testing;

test "Search lists matching paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const context: workspace.Context = .{
        .workspace_path = try tmp.dir.realpath(".", &path_buf),
    };

    const result = try invoke(testing.allocator, context, "{\"target\":\"path\",\"query\":\"*.zig\"}");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "src/root.zig") != null);
}

test "Search returns matching content lines" {
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
        "{\"target\":\"content\",\"query\":\"agent\",\"path\":\"src\",\"glob\":\"*.zig\"}",
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "root.zig:1:") != null);
    try testing.expect(std.mem.indexOf(u8, result.content, "agent/root.zig") != null);
}
