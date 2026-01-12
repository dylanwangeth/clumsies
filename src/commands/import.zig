const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Get hash from args (no flags needed - import is prompt-only)
    var hash: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            hash = arg;
            break;
        }
    }

    if (hash == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Prompt hash required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies import <hash>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (!commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ not found\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies init <git-url>{s} or {s}clumsies init -B <bundle>{s} first\n\n", .{ P, Color.cyan, Color.reset, Color.cyan, Color.reset });
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

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, hash.?);
}

fn importPrompt(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, prompts_path: []const u8, hash: []const u8) !void {
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
    const name = if (found.?.object.get("name")) |n| n.string else "prompt";

    // Read prompt content
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
        try stderr.print("{s}{s}{s}Error:{s} Failed to read prompt\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompt_content);

    // Default to command/ directory
    const type_dir = "command";
    const dest_dir = try std.fs.path.join(allocator, &.{ prompts_path, type_dir });
    defer allocator.free(dest_dir);

    fs.cwd().makePath(dest_dir) catch {};

    // Get next sequence number
    const seq = getNextSequenceNumber(dest_dir);
    var upper_name: [256]u8 = undefined;
    const upper_len = toUpperSnakeCase(name, &upper_name);

    const dest_filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.md", .{ seq, upper_name[0..upper_len] });
    defer allocator.free(dest_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, dest_filename });
    defer allocator.free(dest_path);

    // Write file
    const dest_file = fs.createFileAbsolute(dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer dest_file.close();
    dest_file.writeAll(prompt_content) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    try stdout.print("{s}{s}{s}✓{s} Imported prompt to .prompts/\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  File: {s}{s}/{s}{s}\n\n", .{ P, Color.cyan, type_dir, dest_filename, Color.reset });
}

fn getNextSequenceNumber(dir_path: []const u8) u8 {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var max_seq: u8 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name.len >= 2) {
            const seq = std.fmt.parseInt(u8, entry.name[0..2], 10) catch continue;
            if (seq > max_seq) max_seq = seq;
        }
    }
    return max_seq + 1;
}

fn toUpperSnakeCase(input: []const u8, output: *[256]u8) usize {
    var out_idx: usize = 0;
    for (input) |c| {
        if (out_idx >= 255) break;
        if (c >= 'a' and c <= 'z') {
            output[out_idx] = c - 32;
            out_idx += 1;
        } else if (c >= 'A' and c <= 'Z') {
            output[out_idx] = c;
            out_idx += 1;
        } else if (c == ' ' or c == '-' or c == '_') {
            output[out_idx] = '_';
            out_idx += 1;
        }
    }
    return out_idx;
}
