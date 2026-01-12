const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const RmType = enum {
    prompt,
    bundle,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rm_type: RmType = .none;
    var hash: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--prompt")) {
            rm_type = .prompt;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            rm_type = .bundle;
        } else if (arg.len > 0 and arg[0] != '-') {
            hash = arg;
        }
    }

    if (rm_type == .none) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify -P (prompt) or -B (bundle)\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies rm -P <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (hash == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies rm -P <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
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

    if (rm_type == .prompt) {
        try rmPrompt(stdout, stderr, allocator, registry_path, hash.?);
    } else {
        try rmBundle(stdout, stderr, allocator, registry_path, hash.?);
    }
}

fn rmPrompt(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8) !void {
    // Find and remove prompt from index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read registry index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    file.close();
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

    // Find and get full hash
    var full_hash: ?[]const u8 = null;
    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            full_hash = item_hash;
            break;
        }
    }

    if (full_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Delete the prompt file
    const prompt_filename = try std.fmt.allocPrint(allocator, "{s}.md", .{full_hash.?});
    defer allocator.free(prompt_filename);

    const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", prompt_filename });
    defer allocator.free(prompt_path);

    fs.deleteFileAbsolute(prompt_path) catch {};

    // Rebuild index.json without this entry
    var new_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer new_prompts.deinit(allocator);

    try new_prompts.appendSlice(allocator, "{\n  \"prompts\": [");

    var first = true;
    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.eql(u8, item_hash, full_hash.?)) continue;

        if (!first) {
            try new_prompts.appendSlice(allocator, ",");
        }
        first = false;

        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const created = if (item.object.get("created_at")) |c| c.string else "0";

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, name, desc, created });
        defer allocator.free(entry);
        try new_prompts.appendSlice(allocator, entry);
    }

    try new_prompts.appendSlice(allocator, "\n  ]\n}\n");

    // Write new index
    const new_file = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer new_file.close();
    new_file.writeAll(new_prompts.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Remove prompt") catch {};
    git.push(allocator, registry_path) catch {
        try stderr.print("{s}{s}{s}Warning:{s} Changes saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };

    try stdout.print("{s}{s}{s}✓{s} Removed prompt from registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n\n", .{ P, Color.cyan, full_hash.?, Color.reset });
}

fn rmBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, hash: []const u8) !void {
    // Find and remove bundle from index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not read registry index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    file.close();
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

    // Find and get full hash
    var full_hash: ?[]const u8 = null;
    for (bundles.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.startsWith(u8, item_hash, hash)) {
            full_hash = item_hash;
            break;
        }
    }

    if (full_hash == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, hash });
        return;
    }

    // Delete the bundle directory
    const bundle_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles", full_hash.? });
    defer allocator.free(bundle_path);

    fs.deleteTreeAbsolute(bundle_path) catch {};

    // Rebuild index.json without this entry
    var new_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer new_bundles.deinit(allocator);

    try new_bundles.appendSlice(allocator, "{\n  \"bundles\": [");

    var first = true;
    for (bundles.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (std.mem.eql(u8, item_hash, full_hash.?)) continue;

        if (!first) {
            try new_bundles.appendSlice(allocator, ",");
        }
        first = false;

        const name = if (item.object.get("name")) |n| n.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const created = if (item.object.get("created_at")) |c| c.string else "0";

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, name, desc, created });
        defer allocator.free(entry);
        try new_bundles.appendSlice(allocator, entry);
    }

    try new_bundles.appendSlice(allocator, "\n  ]\n}\n");

    // Write new index
    const new_file = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer new_file.close();
    new_file.writeAll(new_bundles.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Remove bundle") catch {};
    git.push(allocator, registry_path) catch {
        try stderr.print("{s}{s}{s}Warning:{s} Changes saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };

    try stdout.print("{s}{s}{s}✓{s} Removed bundle from registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Name: {s}{s}{s}\n\n", .{ P, Color.cyan, full_hash.?, Color.reset });
}
