const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var show_bundles: bool = false;
    var cat_filter: ?[]const u8 = null;
    var sync: bool = false;
    var quiet_git: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bundles")) {
            show_bundles = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cat")) {
            if (i + 1 < args.len) {
                i += 1;
                cat_filter = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --cat requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try printHelp(stderr);
            return;
        }
    }

    if (show_bundles) {
        try listBundles(stdout, stderr, allocator, sync, quiet_git);
    } else {
        try listPrompts(stdout, stderr, allocator, cat_filter, sync, quiet_git);
    }
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies ls [-b] [-c <cat>] [-s]{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-b, --bundles{s}     List bundles instead of prompts\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-c, --cat{s} <cat>   Filter by category\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}           Sync registry before listing\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}     Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}           Show this help\n\n", .{ P, Color.cyan, Color.reset });
}

fn listPrompts(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, cat_filter: ?[]const u8, sync: bool, quiet_git: bool) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.object.get("prompts") orelse {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };

    if (items.array.items.len == 0) {
        try stdout.print("{s}{s}No prompts found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}Prompts in registry:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}          {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────────────────────────\n", .{P});

    std.mem.sort(std.json.Value, items.array.items, {}, struct {
        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
            const a_cat = if (a.object.get("category")) |c| c.string else "";
            const b_cat = if (b.object.get("category")) |c| c.string else "";
            const cat_order = std.mem.order(u8, a_cat, b_cat);
            if (cat_order != .eq) return cat_order == .lt;
            const a_name = if (a.object.get("name")) |n| n.string else "";
            const b_name = if (b.object.get("name")) |n| n.string else "";
            return std.mem.order(u8, a_name, b_name) == .lt;
        }
    }.lessThan);

    for (items.array.items) |item| {
        const hash = if (item.object.get("hash")) |h| h.string else continue;
        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const category = if (item.object.get("category")) |c| c.string else "conduct";

        // Apply category filter
        if (cat_filter) |filter| {
            if (!std.mem.eql(u8, category, filter) and
                !(std.mem.startsWith(u8, category, filter) and category.len > filter.len and category[filter.len] == '/'))
                continue;
        }

        const short_hash = if (hash.len > 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s: <8}{s}  {s: <16}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, name, desc });
    }
    try stdout.writeAll("\n");
}

fn listBundles(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, sync: bool, quiet_git: bool) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No bundles found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.object.get("bundles") orelse {
        try stdout.print("{s}{s}No bundles found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };

    if (items.array.items.len == 0) {
        try stdout.print("{s}{s}No bundles found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    }

    try stdout.print("{s}{s}{s}Bundles in registry:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}NAME{s}                  {s}TASK{s}      {s}CATEGORIES{s}  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────────────────\n", .{P});

    std.mem.sort(std.json.Value, items.array.items, {}, struct {
        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
            const a_name = if (a.object.get("name")) |n| n.string else "";
            const b_name = if (b.object.get("name")) |n| n.string else "";
            return std.mem.order(u8, a_name, b_name) == .lt;
        }
    }.lessThan);

    for (items.array.items) |item| {
        const name = if (item.object.get("name")) |n| n.string else continue;
        const item_task = if (item.object.get("task")) |t| t.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";

        const prompts_arr = item.object.get("prompts");
        const count = if (prompts_arr) |p| p.array.items.len else 0;
        const label: []const u8 = " prompts";

        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}{s}", .{ count, label }) catch "-";

        try stdout.print("{s}  {s}{s: <20}{s}  {s: <8}  {s: <10}  {s}\n", .{ P, Color.cyan, name, Color.reset, item_task, count_str, desc });
    }
    try stdout.writeAll("\n");
}
