const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const ListType = enum {
    prompt,
    bundle,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var list_type: ListType = .none;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--prompt")) {
            list_type = .prompt;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            list_type = .bundle;
        }
    }

    if (list_type == .none) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify -P (prompts) or -B (bundles)\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies list -P{s} or {s}clumsies list -B{s}\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
        return;
    }

    // Get registry URL
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(registry_url);

    try stdout.writeAll("\n");

    // Get registry path
    const base_path = commands.getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });
    defer allocator.free(registry_path);

    // Ensure registry is cloned or pull latest
    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!registry_exists) {
        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        git.clone(allocator, registry_url, registry_path) catch {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        sp.succeed();
    } else {
        var sp = spinner.init(stdout, "Updating registry");
        sp.start();
        git.pull(allocator, registry_path) catch {};
        sp.succeed();
    }

    // Read index
    const index_subpath = if (list_type == .prompt) "prompts/index.json" else "bundles/index.json";
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, index_subpath });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No {s}s found in registry{s}\n\n", .{ P, Color.dim, if (list_type == .prompt) "prompt" else "bundle", Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const items_key = if (list_type == .prompt) "prompts" else "bundles";
    const items = parsed.value.object.get(items_key) orelse {
        try stdout.print("{s}{s}No {s}s found in registry{s}\n\n", .{ P, Color.dim, if (list_type == .prompt) "prompt" else "bundle", Color.reset });
        return;
    };

    if (items.array.items.len == 0) {
        try stdout.print("{s}{s}No {s}s found in registry{s}\n\n", .{ P, Color.dim, if (list_type == .prompt) "prompt" else "bundle", Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}s in registry:{s}\n", .{ P, Color.bold, if (list_type == .prompt) "Prompt" else "Bundle", Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}      {s}CREATED{s}     {s}NAME{s}                 {s}DESCRIPTION{s}\n", .{ P, Color.dim, Color.reset, Color.dim, Color.reset, Color.dim, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (items.array.items) |item| {
        const hash = if (item.object.get("hash")) |h| h.string else continue;
        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const created_str = if (item.object.get("created_at")) |c| c.string else "0";

        const created_ts = std.fmt.parseInt(i64, created_str, 10) catch 0;
        var date_buf: [10]u8 = undefined;
        const date_str = commands.formatDate(created_ts, &date_buf);

        const short_hash = if (hash.len > 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s}{s}  {s}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, date_str, name, desc });
    }
    try stdout.writeAll("\n");
}
