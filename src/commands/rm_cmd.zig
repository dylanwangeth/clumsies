const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const spinner = @import("../spinner.zig");
const flag = @import("../flags.zig");

const Color = commands.Color;
const P = commands.P;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const resolveRef = commands.resolveRef;
const appendBundleEntry = commands.appendBundleEntry;
const appendPromptEntry = commands.appendPromptEntry;

pub fn run(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const Q = 0;
    const S = 1;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
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
    const sync = result.boolean(S);

    if (result.positionals.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Reference required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const refs = result.positionals.items;
    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git) catch return;
    defer allocator.free(registry_path);

    const kind = resolveRef(allocator, registry_path, refs[0]);

    switch (kind) {
        .prompt => try rmPrompts(stdout, stderr, allocator, registry_path, refs, quiet_git),
        .bundle => try rmBundles(stdout, stderr, allocator, registry_path, refs, quiet_git),
        .not_found => {
            try stderr.print("{s}{s}{s}Error:{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, refs[0] });
        },
    }
}

fn rmPrompts(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash_args: []const []const u8, quiet_git: bool) !void {
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    file.close();
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Prompt not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var removed_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer removed_hashes.deinit(allocator);

    var new_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer new_prompts.deinit(allocator);

    try new_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    var first = true;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;

        var should_remove = false;
        for (hash_args) |hash| {
            if (std.mem.startsWith(u8, item_hash, hash)) {
                should_remove = true;
                try removed_hashes.append(allocator, item_hash);
                break;
            }
        }

        if (should_remove) continue;

        if (!first) try new_prompts.appendSlice(allocator, ",");
        first = false;
        try appendPromptEntry(allocator, &new_prompts, item);
    }
    try new_prompts.appendSlice(allocator, "\n  ]\n}\n");

    if (removed_hashes.items.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No matching prompts found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Delete prompt files
    for (removed_hashes.items) |hash| {
        const prompt_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", hash });
        defer allocator.free(prompt_path);
        fs.deleteFileAbsolute(prompt_path) catch {};
    }

    // Write updated index
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_prompts.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index data\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    var sp = spinner.init(stdout, "Removing from registry");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const commit_msg = if (removed_hashes.items.len == 1) "Remove prompt" else "Remove prompts";
    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    // Commit may fail if no changes — that's ok, continue to push
    git.commit(allocator, registry_path, commit_msg, &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Removed {d} prompt(s)\n", .{ P, Color.bold, Color.green, Color.reset, removed_hashes.items.len });
}

fn rmBundles(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, name_args: []const []const u8, quiet_git: bool) !void {
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    file.close();
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var removed_count: usize = 0;
    var new_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer new_bundles.deinit(allocator);

    try new_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    var first = true;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        var should_remove = false;
        for (name_args) |name| {
            if (std.mem.eql(u8, item_name, name)) {
                should_remove = true;
                removed_count += 1;
                break;
            }
        }

        if (should_remove) continue;

        if (!first) try new_bundles.appendSlice(allocator, ",");
        first = false;

        try appendBundleEntry(allocator, &new_bundles, item);
    }
    try new_bundles.appendSlice(allocator, "\n  ]\n}\n");

    if (removed_count == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No matching bundles found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_bundles.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index data\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    var sp = spinner.init(stdout, "Removing from registry");
    sp.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to stage changes\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const commit_msg = if (removed_count == 1) "Remove bundle" else "Remove bundles";
    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, commit_msg, &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp.fail();
        printGitOutputRaw(&git_output, quiet_git);
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output, quiet_git);

    try stdout.print("{s}{s}{s}✓{s} Removed {d} bundle(s)\n", .{ P, Color.bold, Color.green, Color.reset, removed_count });
    try stdout.print("{s}{s}Note: Prompts are kept in registry (may be used by other bundles){s}\n", .{ P, Color.dim, Color.reset });
}

fn printHelp(out: *std.io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies rm <ref>... [-s]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Remove prompt(s) or bundle(s) from registry.\n", .{P});
    try out.print("{s}Type is auto-detected: hex = prompt hash, otherwise = bundle name.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-s, --sync{s}       Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}  Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}       Show this help\n", .{ P, Color.cyan, Color.reset });
}
