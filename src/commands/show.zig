const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const ShowType = enum {
    prompt,
    bundle,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var show_type: ShowType = .none;
    var hash: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--prompt")) {
            show_type = .prompt;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            show_type = .bundle;
        } else if (arg.len > 0 and arg[0] != '-') {
            hash = arg;
        }
    }

    if (show_type == .none) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify -P (prompt) or -B (bundle)\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies show -P <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (hash == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies show -P <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
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

    // Ensure registry is cloned
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
    }

    if (show_type == .prompt) {
        try showPrompt(stdout, stderr, allocator, registry_path, hash.?);
    } else {
        try showBundle(stdout, stderr, allocator, registry_path, hash.?);
    }
}

fn showPrompt(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8) !void {
    // Find the prompt in index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read registry index\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No prompts in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find matching prompt
    var found: ?std.json.Value = null;
    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            found = item;
            break;
        }
    }

    if (found == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    const full_hash = found.?.object.get("hash").?.string;
    const name = if (found.?.object.get("name")) |n| n.string else "-";
    const desc = if (found.?.object.get("description")) |d| d.string else "-";

    // Print metadata
    try stdout.print("{s}{s}Hash:{s}        {s}{s}{s}\n", .{ P, Color.bold, Color.reset, Color.cyan, full_hash, Color.reset });
    try stdout.print("{s}{s}Name:{s}        {s}\n", .{ P, Color.bold, Color.reset, name });
    try stdout.print("{s}{s}Description:{s} {s}\n\n", .{ P, Color.bold, Color.reset, desc });

    // Read and show content
    const prompt_filename = try std.fmt.allocPrint(allocator, "{s}.md", .{full_hash});
    defer allocator.free(prompt_filename);

    const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", prompt_filename });
    defer allocator.free(prompt_path);

    const prompt_file = fs.openFileAbsolute(prompt_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Prompt file not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer prompt_file.close();

    const prompt_content = prompt_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompt_content);

    try stdout.print("{s}{s}Content:{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}────────────────────────────────────────\n", .{P});
    try stdout.print("{s}{s}\n", .{ P, prompt_content });
}

fn showBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8) !void {
    // Find the bundle in bundles/index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read registry index\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No bundles in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find matching bundle
    var found: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            found = item;
            break;
        }
    }

    if (found == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    const bundle_name = found.?.object.get("hash").?.string;
    const name = if (found.?.object.get("name")) |n| n.string else "-";
    const desc = if (found.?.object.get("description")) |d| d.string else "-";

    // Print metadata
    try stdout.print("{s}{s}Name:{s}        {s}{s}{s}\n", .{ P, Color.bold, Color.reset, Color.cyan, name, Color.reset });
    try stdout.print("{s}{s}Description:{s} {s}\n\n", .{ P, Color.bold, Color.reset, desc });

    // List bundle contents
    const bundle_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles", bundle_name });
    defer allocator.free(bundle_path);

    var dir = fs.openDirAbsolute(bundle_path, .{ .iterate = true }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Bundle directory not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer dir.close();

    try stdout.print("{s}{s}Contents:{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}────────────────────────────────────────\n", .{P});

    try listDirRecursive(stdout, allocator, bundle_path, 0);
    try stdout.writeAll("\n");
}

fn listDirRecursive(stdout: anytype, allocator: std.mem.Allocator, path: []const u8, depth: usize) !void {
    var dir = fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (entry.name[0] == '.') continue;

        var i: usize = 0;
        while (i < depth) : (i += 1) {
            try stdout.writeAll("    ");
        }

        if (entry.kind == .directory) {
            try stdout.print("{s}    {s}{s}/{s}\n", .{ P, Color.cyan, entry.name, Color.reset });
            const subpath = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(subpath);
            try listDirRecursive(stdout, allocator, subpath, depth + 1);
        } else {
            try stdout.print("{s}    {s}\n", .{ P, entry.name });
        }
    }
}
