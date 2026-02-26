const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const stripSequencePrefix = commands.stripSequencePrefix;
const hexEncode = commands.hexEncode;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const hasFrontmatter = commands.hasFrontmatter;
const stripFrontmatter = commands.stripFrontmatter;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var file_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_paths.deinit(allocator);
    var desc_flag: ?[]const u8 = null;
    var cat_flag: ?[]const u8 = null;
    var sync: bool = false;
    var quiet_git: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-Q") or std.mem.eql(u8, arg, "--quiet-git")) {
            quiet_git = true;
        } else if (std.mem.eql(u8, arg, "--desc") or std.mem.eql(u8, arg, "-d")) {
            if (i + 1 < args.len) {
                i += 1;
                desc_flag = args[i];
            } else {
                try stderr.print("{s}{s}{s}Error:{s} --desc requires a value\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }
        } else if (std.mem.eql(u8, arg, "--cat") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                i += 1;
                cat_flag = args[i];
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
        } else {
            try file_paths.append(allocator, arg);
        }
    }

    if (file_paths.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} File(s) required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    var registered: usize = 0;

    for (file_paths.items) |file_path| {
        if (try registerOne(stdout, stderr, allocator, registry_path, prompts_dir, cwd, file_path, desc_flag, cat_flag)) {
            registered += 1;
        }
    }

    if (registered == 0) return;

    // Commit and push
    var sp = spinner.init(stdout, "Registering prompt(s)");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    const commit_msg = if (registered == 1) "Add prompt" else "Add prompts";
    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, commit_msg, &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    if (registered == 1) {
        try stdout.print("{s}{s}{s}✓{s} Registered prompt in registry\n\n", .{ P, Color.bold, Color.green, Color.reset });
    } else {
        try stdout.print("{s}{s}{s}✓{s} Registered {d} prompts in registry\n\n", .{ P, Color.bold, Color.green, Color.reset, registered });
    }
}

fn registerOne(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, _: []const u8, prompts_dir: []const u8, cwd: []const u8, file_path: []const u8, desc_flag: ?[]const u8, cat_flag: ?[]const u8) !bool {
    const abs_path = if (std.fs.path.isAbsolute(file_path))
        try allocator.dupe(u8, file_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, file_path });
    defer allocator.free(abs_path);

    const file = fs.openFileAbsolute(abs_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return false;
    };
    defer file.close();

    const raw_content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return false;
    };
    defer allocator.free(raw_content);

    const had_frontmatter = hasFrontmatter(raw_content);
    const content = stripFrontmatter(raw_content);

    if (had_frontmatter) {
        try stdout.print("{s}{s}Stripped frontmatter from {s}{s}\n", .{ P, Color.dim, file_path, Color.reset });
    }

    // Compute SHA-256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var hash_hex: [64]u8 = undefined;
    hexEncode(&hash, &hash_hex);

    // Extract file extension and name
    const basename = std.fs.path.basename(file_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
    const format = if (ext_idx) |idx| basename[idx + 1 ..] else "md";
    const name_end = ext_idx orelse basename.len;
    const raw_name = basename[0..name_end];
    const name = stripSequencePrefix(raw_name);
    const description = desc_flag orelse "-";
    const prompt_category = cat_flag orelse "conduct";

    // Copy file to registry
    const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, &hash_hex });
    defer allocator.free(dest_path);

    if (fs.openFileAbsolute(dest_path, .{})) |existing| {
        existing.close();
        try stdout.print("{s}{s}{s}!{s} Already exists: {s} ({s})\n", .{ P, Color.bold, Color.orange, Color.reset, name, hash_hex[0..8] });
        return false;
    } else |_| {}

    const dest_file = fs.createFileAbsolute(dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create file in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return false;
    };
    defer dest_file.close();
    dest_file.writeAll(content) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n", .{ P, Color.bold, Color.red, Color.reset });
        return false;
    };

    // Update index.json
    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    var existing_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer existing_prompts.deinit(allocator);

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            idx_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n", .{ P, Color.bold, Color.red, Color.reset });
            return false;
        };
        idx_file.close();
        defer allocator.free(idx_content);

        if (std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
                for (prompts.array.items, 0..) |item, idx| {
                    if (idx > 0) try existing_prompts.appendSlice(allocator, ",");
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_format = if (item.object.get("format")) |f| f.string else "md";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";
                    const item_category = if (item.object.get("category")) |p| p.string else "conduct";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_format, item_category, item_created });
                    defer allocator.free(entry);
                    try existing_prompts.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    }

    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_prompts.items.len > 20) "," else "",
        hash_hex,
        name,
        description,
        format,
        prompt_category,
        timestamp,
    });
    defer allocator.free(new_entry);
    try existing_prompts.appendSlice(allocator, new_entry);

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n", .{ P, Color.bold, Color.red, Color.reset });
        return false;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_prompts.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n", .{ P, Color.bold, Color.red, Color.reset });
        return false;
    };

    try stdout.print("{s}  Hash: {s}{s}{s}  Name: {s}\n", .{ P, Color.cyan, hash_hex[0..8], Color.reset, name });
    return true;
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies add <file>... [-c <cat>] [-d <desc>] [-s]{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Register prompt(s) to registry.\n\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-c, --cat{s} <cat>    Category (default: conduct)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-d, --desc{s} <desc>  Description\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}         Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}   Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}         Show this help\n\n", .{ P, Color.cyan, Color.reset });
}
