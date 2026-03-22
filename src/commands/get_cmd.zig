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
const findNextSequence = commands.findNextSequence;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;
const resolveRef = commands.resolveRef;
const findPromptByHashPrefix = commands.findPromptByHashPrefix;
const printAmbiguousPromptHashError = commands.printAmbiguousPromptHashError;
const importPrompt = commands.importPrompt;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const Q = 0;
    const C = 1;
    const R = 2;
    const S = 3;
    const REG = 4;
    const SPECS = [_]flag.FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
        .{ .short = 'g', .long = "group", .kind = .multi_value },
        .{ .short = 'r', .long = "remote-url", .kind = .value },
        .{ .short = 's', .long = "sync", .kind = .boolean },
        .{ .short = null, .long = "registry", .kind = .value },
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
    const group_filters = result.multiValues(C);
    const remote_url = result.value(R);
    const sync = result.boolean(S);
    const registry_override = result.value(REG);
    const refs = result.positionals.items;

    if (refs.len == 0 and group_filters.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Reference or --group required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printHelp(stderr);
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync, quiet_git, registry_override) catch return;
    defer allocator.free(registry_path);

    // If first ref resolves as bundle, do bundle import; otherwise prompt import
    if (refs.len > 0) {
        const kind = resolveRef(allocator, registry_path, refs[0]);
        switch (kind) {
            .bundle => {
                try getBundle(stdout, stderr, allocator, registry_path, refs[0], remote_url, quiet_git);
                return;
            },
            .prompt => {},
            .ambiguous_prompt => {
                try printAmbiguousPromptHashError(stderr, refs[0]);
                return;
            },
            .not_found => {
                if (group_filters.len == 0) {
                    try stderr.print("{s}{s}{s}Error:{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, refs[0] });
                    return;
                }
            },
        }
    }

    try getPrompts(stdout, stderr, allocator, registry_path, refs, group_filters);
}

fn getPrompts(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, hash_args: []const []const u8, group_filters: []const []const u8) !void {
    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine .prompts/ path\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    if (!commands.promptsExist()) {
        fs.cwd().makeDir(".prompts") catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
            return;
        };
    }

    // Read index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No prompts found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No prompts in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var success_count: usize = 0;
    var fail_count: usize = 0;

    // Import by hash
    for (hash_args) |hash| {
        const entry = switch (findPromptByHashPrefix(prompts, hash)) {
            .unique => |entry| entry,
            .ambiguous => {
                try printAmbiguousPromptHashError(stderr, hash);
                fail_count += 1;
                continue;
            },
            .not_found => {
                try stderr.print("{s}{s}{s}✗{s} Not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, hash });
                fail_count += 1;
                continue;
            },
        };

        const group = entry.group orelse {
            try stderr.print("{s}{s}{s}✗{s} Prompt metadata missing group: {s}\n", .{ P, Color.bold, Color.red, Color.reset, entry.hash });
            fail_count += 1;
            continue;
        };

        switch (try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, entry.hash, entry.name, entry.format, group)) {
            .imported => success_count += 1,
            .skipped => {},
            .failed => fail_count += 1,
        }
    }

    // Import by group (prefix match)
    if (group_filters.len > 0) {
        var group_match_count: usize = 0;
        for (prompts.array.items) |item| {
            const item_hash = if (item.object.get("hash")) |h| h.string else continue;
            const item_name_opt: ?[]const u8 = if (item.object.get("name")) |n| n.string else null;
            const item_format = if (item.object.get("format")) |f| f.string else "md";
            const item_group = if (item.object.get("group")) |p| p.string else {
                try stderr.print("{s}{s}{s}✗{s} Prompt metadata missing group: {s}\n", .{ P, Color.bold, Color.red, Color.reset, item_hash });
                fail_count += 1;
                continue;
            };

            var matches = false;
            for (group_filters) |grp| {
                if (std.mem.eql(u8, item_group, grp) or (std.mem.startsWith(u8, item_group, grp) and (grp.len == item_group.len or item_group[grp.len] == '/'))) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            group_match_count += 1;

            switch (try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, item_hash, item_name_opt, item_format, item_group)) {
                .imported => success_count += 1,
                .skipped => {},
                .failed => fail_count += 1,
            }
        }

        if (group_match_count == 0) {
            for (group_filters) |grp| {
                try stderr.print("{s}{s}{s}✗{s} No prompts in group: {s}\n", .{ P, Color.bold, Color.red, Color.reset, grp });
            }
        }
    }

    if (success_count > 0 and fail_count == 0) {
        try stdout.print("{s}Imported {s}{d}{s} prompt{s}\n", .{ P, Color.green, success_count, Color.reset, if (success_count > 1) "s" else "" });
    } else if (success_count > 0 and fail_count > 0) {
        try stdout.print("{s}Imported {s}{d}{s}, failed {s}{d}{s}\n", .{ P, Color.green, success_count, Color.reset, Color.red, fail_count, Color.reset });
    } else if (fail_count > 0) {
        try stderr.print("{s}No prompts imported, failed {s}{d}{s}\n", .{ P, Color.red, fail_count, Color.reset });
    }
}

fn getBundle(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, bundle_name: []const u8, remote_url: ?[]const u8, quiet_git: bool) !void {
    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine .prompts/ path\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    try ensurePromptsDir(stdout, stderr, allocator, prompts_path, quiet_git);

    // Find bundle in index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles", "index.json" });
    defer allocator.free(index_path);

    const index_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    const index_content = index_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        index_file.close();
        return;
    };
    index_file.close();
    defer allocator.free(index_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, index_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse bundles index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var found_bundle: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, bundle_name)) {
            found_bundle = item;
            break;
        }
    }

    const bundle = found_bundle orelse {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        return;
    };

    const prompt_count = try importBundlePrompts(stdout, stderr, allocator, registry_path, prompts_path, bundle);

    try stdout.print("{s}{s}{s}✓{s} Imported bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}Prompts: {d}\n", .{ P, prompt_count });

    if (remote_url) |url| {
        var remote_output: GitOutput = .{};
        defer remote_output.deinit(allocator);

        git.addRemote(allocator, prompts_path, url, &remote_output) catch {
            printGitOutputRaw(&remote_output, quiet_git);
            try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}{s}✓{s} Added remote: {s}\n", .{ P, Color.bold, Color.green, Color.reset, url });
        printGitOutputRaw(&remote_output, quiet_git);
    }
}

fn ensurePromptsDir(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, prompts_path: []const u8, quiet_git: bool) !void {
    if (commands.promptsExist()) return;

    fs.cwd().makeDir(".prompts") catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    const context_path = try std.fs.path.join(allocator, &.{ prompts_path, "context" });
    defer allocator.free(context_path);
    fs.cwd().makePath(context_path) catch {};

    var init_output: GitOutput = .{};
    defer init_output.deinit(allocator);

    git.init(allocator, prompts_path, &init_output) catch {
        printGitOutputRaw(&init_output, quiet_git);
        try stderr.print("{s}{s}{s}Error:{s} Failed to initialize git repository\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(prompts_path) catch {};
        return;
    };
    try stdout.print("{s}{s}{s}✓{s} Initialized .prompts/ repository\n", .{ P, Color.bold, Color.green, Color.reset });
    printGitOutputRaw(&init_output, quiet_git);
}

fn importBundlePrompts(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, registry_path: []const u8, prompts_path: []const u8, bundle: std.json.Value) !usize {
    const prompts_index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", "index.json" });
    defer allocator.free(prompts_index_path);

    var prompts_index: ?std.json.Parsed(std.json.Value) = null;
    if (fs.openFileAbsolute(prompts_index_path, .{})) |pf| {
        defer pf.close();
        if (pf.readToEndAlloc(allocator, MAX_FILE_SIZE)) |content| {
            defer allocator.free(content);
            prompts_index = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        } else |_| {}
    } else |_| {}
    defer if (prompts_index) |pi| pi.deinit();

    var sp = spinner.init(stdout, "Importing prompts");
    sp.start();

    const prompts_arr = bundle.object.get("prompts") orelse {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Bundle has no prompts\n", .{ P, Color.bold, Color.red, Color.reset });
        return 0;
    };

    const prompts_list = if (prompts_index) |pi| pi.value.object.get("prompts") else null;
    var count: usize = 0;

    for (prompts_arr.array.items) |ref| {
        const hash = if (ref.object.get("hash")) |h| h.string else continue;

        var group: ?[]const u8 = null;
        var prompt_name: ?[]const u8 = null;
        var prompt_format: []const u8 = "md";
        if (prompts_list) |pl| {
            for (pl.array.items) |p| {
                const p_hash = if (p.object.get("hash")) |ph| ph.string else continue;
                if (std.mem.eql(u8, p_hash, hash)) {
                    group = if (p.object.get("group")) |c| c.string else null;
                    prompt_name = if (p.object.get("name")) |n| n.string else null;
                    prompt_format = if (p.object.get("format")) |f| f.string else "md";
                    break;
                }
            }
        }

        const resolved_group = group orelse {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} Prompt metadata missing group: {s}\n", .{ P, Color.bold, Color.red, Color.reset, hash });
            return error.MissingGroup;
        };

        if (try importPrompt(stdout, stderr, allocator, registry_path, prompts_path, hash, prompt_name, prompt_format, resolved_group) == .imported) {
            count += 1;
        }
    }
    sp.succeed();
    return count;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies get <ref>... [-g <group>] [--remote-url <url>] [-s]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Import prompt(s) or a bundle to local .prompts/.\n", .{P});
    try out.print("{s}Type is auto-detected: hex = prompt, otherwise = bundle.\n", .{P});
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-g, --group{s} <group>    Import all prompts in group (prefix match)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--remote-url{s} <url>      Add git remote after bundle import\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}--registry{s} <url>         Use a different registry (read-only)\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}             Sync registry before command\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-Q, --quiet-git{s}        Suppress git output\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-h, --help{s}             Show this help\n", .{ P, Color.cyan, Color.reset });
}
