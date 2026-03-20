const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const flag = @import("../flags.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const stripSequencePrefix = commands.stripSequencePrefix;
const hexEncode = commands.hexEncode;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const META_PROMPT_GROUP = commands.META_PROMPT_GROUP;
const ensureRegistry = commands.ensureRegistry;
const appendPromptEntry = commands.appendPromptEntry;
const jsonEscapeAlloc = commands.jsonEscapeAlloc;
const PromptRef = commands.PromptRef;
const freePromptRefs = commands.freePromptRefs;
const updatePromptsIndex = commands.updatePromptsIndex;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const Q = 0;
    const D = 1;
    const C = 2;
    const META = 3;
    const S = 4;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
        .{ .short = 'd', .long = "desc", .kind = .value },
        .{ .short = 'g', .long = "group", .kind = .value },
        .{ .short = 'm', .long = "meta", .kind = .boolean },
        .{ .short = 's', .long = "sync", .kind = .boolean },
    };
    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);
    const quiet_git = result.boolean(Q);
    const desc_flag = result.value(D);
    var group_flag = result.value(C);
    const sync = result.boolean(S);

    if (result.boolean(META)) {
        group_flag = META_PROMPT_GROUP;
    }

    if (result.positionals.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} File(s) required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git, null) catch return;
    defer allocator.free(registry_path);

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    // Expand directories into file lists
    var expanded_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (expanded_paths.items) |p| allocator.free(p);
        expanded_paths.deinit(allocator);
    }

    for (result.positionals.items) |raw_path| {
        const abs = if (std.fs.path.isAbsolute(raw_path))
            try allocator.dupe(u8, raw_path)
        else
            try std.fs.path.join(allocator, &.{ cwd, raw_path });

        const stat = fs.cwd().statFile(abs) catch |err| {
            // Windows: statFile calls openFile with .file_only, which returns
            // IsDir for directories (ziglang/zig#5732). Handle it explicitly.
            if (err == error.IsDir) {
                defer allocator.free(abs);
                expandDirectory(allocator, abs, &expanded_paths);
                continue;
            }
            allocator.free(abs);
            try expanded_paths.append(allocator, try allocator.dupe(u8, raw_path));
            continue;
        };

        if (stat.kind == .directory) {
            defer allocator.free(abs);
            expandDirectory(allocator, abs, &expanded_paths);
        } else {
            try expanded_paths.append(allocator, abs);
        }
    }

    if (expanded_paths.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No files found in the specified path(s)\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    var refs: std.ArrayListUnmanaged(PromptRef) = .empty;
    defer freePromptRefs(allocator, &refs);

    for (expanded_paths.items) |file_path| {
        if (try preparePrompt(stdout, stderr, allocator, prompts_dir, cwd, file_path, desc_flag, group_flag)) |ref| {
            try refs.append(allocator, ref);
        }
    }

    if (refs.items.len == 0) return;

    updatePromptsIndex(allocator, registry_path, refs.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to update prompts index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const registered = refs.items.len;

    // Commit and push
    var sp = spinner.init(stdout, "Registering prompt(s)");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

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
        try stdout.print("{s}{s}{s}✓{s} Registered prompt in registry\n", .{ P, Color.bold, Color.green, Color.reset });
    } else {
        try stdout.print("{s}{s}{s}✓{s} Registered {d} prompts in registry\n", .{ P, Color.bold, Color.green, Color.reset, registered });
    }
}

fn preparePrompt(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, prompts_dir: []const u8, cwd: []const u8, file_path: []const u8, desc_flag: ?[]const u8, group_flag: ?[]const u8) !?PromptRef {
    const abs_path = if (std.fs.path.isAbsolute(file_path))
        try allocator.dupe(u8, file_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, file_path });
    defer allocator.free(abs_path);

    const file = fs.openFileAbsolute(abs_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return null;
    };
    defer file.close();

    const raw_content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return null;
    };
    defer allocator.free(raw_content);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_content, &hash, .{});
    var hash_hex: [64]u8 = undefined;
    hexEncode(&hash, &hash_hex);

    const basename = std.fs.path.basename(file_path);
    const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
    const format = if (ext_idx) |idx| basename[idx + 1 ..] else "md";
    const name_end = ext_idx orelse basename.len;
    const raw_name = basename[0..name_end];
    const name = stripSequencePrefix(raw_name);
    const description = desc_flag orelse "-";
    const raw_group = group_flag orelse commands.deriveGroupFromFile(abs_path) orelse {
        try stderr.print("{s}{s}{s}Error:{s} Could not derive group from path: {s}\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        try stderr.print("{s}Use {s}--group{s} to specify a group\n", .{ P, Color.cyan, Color.reset });
        return null;
    };

    // Normalize backslashes for cross-platform registry consistency
    var group_owned: ?[]u8 = null;
    defer if (group_owned) |c| allocator.free(c);
    const prompt_group: []const u8 = if (std.mem.indexOfScalar(u8, raw_group, '\\') != null) blk: {
        group_owned = try allocator.dupe(u8, raw_group);
        std.mem.replaceScalar(u8, group_owned.?, '\\', '/');
        break :blk group_owned.?;
    } else raw_group;

    // Copy file to registry
    const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, &hash_hex });
    defer allocator.free(dest_path);

    if (fs.openFileAbsolute(dest_path, .{})) |existing| {
        existing.close();
        try stdout.print("{s}{s}{s}!{s} Already exists: {s} ({s})\n", .{ P, Color.bold, Color.orange, Color.reset, name, hash_hex[0..8] });
        return null;
    } else |_| {}

    const dest_file = fs.createFileAbsolute(dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create file in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return null;
    };
    defer dest_file.close();
    dest_file.writeAll(raw_content) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n", .{ P, Color.bold, Color.red, Color.reset });
        return null;
    };

    try stdout.print("{s}Hash: {s}{s}{s}  Name: {s}\n", .{ P, Color.cyan, hash_hex[0..8], Color.reset, name });

    return .{
        .hash = try allocator.dupe(u8, &hash_hex),
        .group = try allocator.dupe(u8, prompt_group),
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .format = try allocator.dupe(u8, format),
    };
}

/// Recursively expand a directory into individual file paths
fn expandDirectory(allocator: std.mem.Allocator, abs_path: []const u8, expanded_paths: *std.ArrayListUnmanaged([]const u8)) void {
    var dir = fs.openDirAbsolute(abs_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const child = std.fs.path.join(allocator, &.{ abs_path, entry.name }) catch continue;
        if (entry.kind == .directory) {
            expandDirectory(allocator, child, expanded_paths);
            allocator.free(child);
        } else if (entry.kind == .file) {
            expanded_paths.append(allocator, child) catch {
                allocator.free(child);
            };
        } else {
            allocator.free(child);
        }
    }
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies add <file|dir>... [-g <group>] [-m] [-d <desc>] [-s]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Register prompt(s) to registry. Directories are expanded to their files.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-g, --group{s} <group> Group (derived from .prompts/ path)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-m, --meta{s}          Register as meta-prompt file (shorthand for -g ../)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-d, --desc{s} <desc>  Description\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}         Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}    Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}         Show this help\n", .{ P, Color.cyan, Color.reset });
}
