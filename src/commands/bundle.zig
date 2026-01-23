const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;
const Frontmatter = commands.Frontmatter;
const GitOutput = commands.GitOutput;
const printGitOutputRaw = commands.printGitOutputRaw;
const parseFrontmatter = commands.parseFrontmatter;
const stripSequencePrefix = commands.stripSequencePrefix;
const hexEncode = commands.hexEncode;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;

const SubCommand = enum {
    list,
    register,
    update,
    show,
    rm,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showUsage(stderr);
        return;
    }

    var subcmd: SubCommand = .none;
    var subcmd_args_start: usize = 1;
    var sync: bool = false;

    // Parse subcommand and options
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try showHelp(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sync")) {
            sync = true;
        } else if (std.mem.eql(u8, arg, "list")) {
            subcmd = .list;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "register")) {
            subcmd = .register;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "update")) {
            subcmd = .update;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "show")) {
            subcmd = .show;
            subcmd_args_start = i + 1;
        } else if (std.mem.eql(u8, arg, "rm") or std.mem.eql(u8, arg, "remove")) {
            subcmd = .rm;
            subcmd_args_start = i + 1;
        }
    }

    // Filter out -s/--sync from subcmd_args
    var filtered_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer filtered_args.deinit(allocator);
    for (args[subcmd_args_start..]) |arg| {
        if (!std.mem.eql(u8, arg, "-s") and !std.mem.eql(u8, arg, "--sync")) {
            try filtered_args.append(allocator, arg);
        }
    }

    switch (subcmd) {
        .list => try runList(stdout, stderr, allocator, sync),
        .register => try runRegister(stdout, stderr, allocator, filtered_args.items, sync),
        .update => try runUpdate(stdout, stderr, allocator, filtered_args.items, sync),
        .show => try runShow(stdout, stderr, allocator, filtered_args.items, sync),
        .rm => try runRm(stdout, stderr, allocator, filtered_args.items, sync),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try printBundleHelp(stderr);
}

fn showHelp(stdout: anytype) !void {
    try printBundleHelp(stdout);
}

fn printBundleHelp(out: anytype) !void {
    try out.print("{s}Usage: {s}clumsies bundle [-s] <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Commands:\n", .{P});
    try out.print("{s}  {s}list{s}                                  List bundles in registry\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}register{s} <meta-prompt> <dirs...>      Register bundle from workspace\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}update{s} <name> [--add/--rm/--meta ...]  Modify bundle content\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}show{s} <name>                           Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}rm{s} <name>                             Remove bundle\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-h, --help{s}                            Show this help\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}-s, --sync{s}                            Sync registry before command\n\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Meta-prompt file frontmatter:\n", .{P});
    try out.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}name: my-bundle{s}        (required)\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}description: ...{s}       (optional)\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}task: coding{s}           (optional)\n", .{ P, Color.dim, Color.reset });
    try out.print("{s}  {s}---{s}\n\n", .{ P, Color.dim, Color.reset });
}

// PromptRef represents a prompt reference in a bundle
const PromptRef = struct {
    hash: []const u8,
    category: []const u8,
    name: []const u8,
    description: []const u8,
    format: []const u8,
};


fn runList(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, sync: bool) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
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
    try stdout.print("{s}  {s}NAME{s}                  {s}TASK{s}      {s}PROMPTS{s}  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}──────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (items.array.items) |item| {
        const name = if (item.object.get("name")) |n| n.string else continue;
        const item_task = if (item.object.get("task")) |t| t.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const prompts_arr = item.object.get("prompts");
        const prompts_count = if (prompts_arr) |p| p.array.items.len else 0;

        try stdout.print("{s}  {s}{s: <20}{s}  {s: <8}  {d: <7}  {s}\n", .{ P, Color.cyan, name, Color.reset, item_task, prompts_count, desc });
    }
    try stdout.writeAll("\n");
}

fn runRegister(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    // Usage: bundle register <meta-prompt-file> <dirs...>
    if (args.len < 2) {
        try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file and at least one directory required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle register <meta-prompt-file> <dir1> [dir2...]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const meta_prompt_path_arg = args[0];
    const dirs = args[1..];

    // Resolve to absolute path
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const meta_prompt_path = if (std.fs.path.isAbsolute(meta_prompt_path_arg))
        try allocator.dupe(u8, meta_prompt_path_arg)
    else
        try std.fs.path.join(allocator, &.{ cwd, meta_prompt_path_arg });
    defer allocator.free(meta_prompt_path);

    // Read meta-prompt file
    const meta_file = fs.openFileAbsolute(meta_prompt_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open meta-prompt file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, meta_prompt_path_arg });
        return;
    };
    const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        meta_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_file.close();
    defer allocator.free(meta_content);

    // Parse frontmatter to get bundle metadata
    const fm = parseFrontmatter(meta_content);
    const bundle_name = fm.name orelse {
        try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file must have 'name' in frontmatter\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Example:\n", .{P});
        try stderr.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}name: my-bundle{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}description: A starter bundle{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}task: coding{s}\n", .{ P, Color.dim, Color.reset });
        try stderr.print("{s}  {s}---{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    const description = fm.description orelse "-";
    const task = fm.task orelse "-";

    try stdout.writeAll("\n");

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    // Check if bundle already exists
    if (bundleExists(allocator, registry_path, bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle already exists: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Use {s}clumsies bundle rm {s}{s} to remove it first\n\n", .{ P, Color.cyan, bundle_name, Color.reset });
        return;
    }

    // Ensure registry directories exist
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const bundles_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles" });
    defer allocator.free(bundles_dir);
    fs.cwd().makePath(bundles_dir) catch {};

    const meta_prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts" });
    defer allocator.free(meta_prompts_dir);
    fs.cwd().makePath(meta_prompts_dir) catch {};

    // Collect prompts from user-specified directories
    var sp = spinner.init(stdout, "Uploading prompts");
    sp.start();

    var prompt_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer {
        for (prompt_refs.items) |ref| {
            allocator.free(ref.hash);
            allocator.free(ref.category);
            allocator.free(ref.name);
            allocator.free(ref.description);
            allocator.free(ref.format);
        }
        prompt_refs.deinit(allocator);
    }

    // Collect from each user-specified directory
    for (dirs) |dir_arg| {
        const dir_path = if (std.fs.path.isAbsolute(dir_arg))
            try allocator.dupe(u8, dir_arg)
        else
            try std.fs.path.join(allocator, &.{ cwd, dir_arg });
        defer allocator.free(dir_path);

        // Use directory basename as category
        const category = std.fs.path.basename(dir_arg);
        collectAndUploadPrompts(allocator, dir_path, category, prompts_dir, &prompt_refs) catch continue;
    }

    if (prompt_refs.items.len == 0) {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} No prompt files found in specified directories\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }
    sp.succeed();

    // Update prompts/index.json
    var sp2 = spinner.init(stdout, "Updating prompts index");
    sp2.start();
    updatePromptsIndex(allocator, registry_path, prompt_refs.items) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to update prompts index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp2.succeed();

    // Upload meta-prompt file
    var sp_meta = spinner.init(stdout, "Uploading meta-prompt");
    sp_meta.start();

    // Compute hash of meta-prompt content
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(meta_content, &hash_bytes, .{});
    var hash_hex: [64]u8 = undefined;
    hexEncode(&hash_bytes, &hash_hex);
    const meta_prompt_hash = try allocator.dupe(u8, &hash_hex);
    defer allocator.free(meta_prompt_hash);

    // Write meta-prompt to registry
    const meta_dest_path = try std.fs.path.join(allocator, &.{ meta_prompts_dir, meta_prompt_hash });
    defer allocator.free(meta_dest_path);

    const meta_dest_file = fs.createFileAbsolute(meta_dest_path, .{}) catch {
        sp_meta.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt to registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_dest_file.writeAll(meta_content) catch {
        meta_dest_file.close();
        sp_meta.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt content\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_dest_file.close();
    sp_meta.succeed();

    // Create bundle entry with references
    var sp3 = spinner.init(stdout, "Creating bundle");
    sp3.start();

    const index_path = try std.fs.path.join(allocator, &.{ bundles_dir, "index.json" });
    defer allocator.free(index_path);

    var existing_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer existing_bundles.deinit(allocator);

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            idx_file.close();
            sp3.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        idx_file.close();
        defer allocator.free(idx_content);

        if (std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("bundles")) |bundles| {
                try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
                for (bundles.array.items, 0..) |item, idx| {
                    if (idx > 0) try existing_bundles.appendSlice(allocator, ",");
                    try appendBundleEntry(allocator, &existing_bundles, item);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    }

    // Add new bundle entry
    const timestamp = std.time.timestamp();
    const comma = if (existing_bundles.items.len > 22) "," else "";

    const new_entry_start = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{d}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{
        comma,
        bundle_name,
        task,
        description,
        timestamp,
        meta_prompt_hash,
    });
    defer allocator.free(new_entry_start);
    try existing_bundles.appendSlice(allocator, new_entry_start);

    // Add prompt references
    for (prompt_refs.items, 0..) |ref, idx| {
        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
            if (idx > 0) "," else "",
            ref.hash,
            ref.category,
        });
        defer allocator.free(ref_entry);
        try existing_bundles.appendSlice(allocator, ref_entry);
    }

    try existing_bundles.appendSlice(allocator, "\n      ]\n    }\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        sp3.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_bundles.items) catch {
        sp3.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp3.succeed();

    // Commit and push
    var sp4 = spinner.init(stdout, "Pushing to registry");
    sp4.start();

    var add_output: GitOutput = .{};
    defer add_output.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output) catch {};

    var commit_output: GitOutput = .{};
    defer commit_output.deinit(allocator);
    git.commit(allocator, registry_path, "Add bundle", &commit_output) catch {};

    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    git.push(allocator, registry_path, &git_output) catch {
        sp4.fail();
        printGitOutputRaw(&git_output);
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp4.succeed();
    printGitOutputRaw(&git_output);

    try stdout.print("{s}{s}{s}✓{s} Registered bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Prompts: {d}\n\n", .{ P, prompt_refs.items.len });
}

fn runUpdate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    // Usage: bundle update <name> --add <files...> --rm <hashes...> --meta <file>
    if (args.len < 2) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name and at least one flag required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add <files...>] [--rm <hashes...>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];

    // Parse --add, --rm, and --meta flags
    var add_files: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_files.deinit(allocator);
    var rm_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer rm_hashes.deinit(allocator);
    var meta_file_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--add")) {
            // Collect all arguments until next flag or end
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try add_files.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1; // Back up for outer loop
        } else if (std.mem.eql(u8, args[i], "--rm")) {
            // Collect all arguments until next flag or end
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try rm_hashes.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1; // Back up for outer loop
        } else if (std.mem.eql(u8, args[i], "--meta")) {
            i += 1;
            if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
                meta_file_arg = args[i];
            }
        }
    }

    if (add_files.items.len == 0 and rm_hashes.items.len == 0 and meta_file_arg == null) {
        try stderr.print("{s}{s}{s}Error:{s} No changes specified\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add <files...>] [--rm <hashes...>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    // Check if bundle exists
    if (!bundleExists(allocator, registry_path, bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        return;
    }

    // Get current directory for resolving relative paths
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    // Process --meta: upload new meta-prompt and get hash
    var new_meta_hash: ?[]const u8 = null;
    defer if (new_meta_hash) |h| allocator.free(h);

    if (meta_file_arg) |meta_arg| {
        const meta_path = if (std.fs.path.isAbsolute(meta_arg))
            try allocator.dupe(u8, meta_arg)
        else
            try std.fs.path.join(allocator, &.{ cwd, meta_arg });
        defer allocator.free(meta_path);

        const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Could not open meta-prompt file: {s}\n", .{ P, Color.bold, Color.red, Color.reset, meta_arg });
            return;
        };
        const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            meta_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        meta_file.close();
        defer allocator.free(meta_content);

        // Calculate hash
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(meta_content, &hash_bytes, .{});
        var hash_hex: [64]u8 = undefined;
        hexEncode(&hash_bytes, &hash_hex);
        new_meta_hash = try allocator.dupe(u8, &hash_hex);

        // Write to meta-prompts directory
        const meta_prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts" });
        defer allocator.free(meta_prompts_dir);
        fs.cwd().makePath(meta_prompts_dir) catch {};

        const meta_dest_path = try std.fs.path.join(allocator, &.{ meta_prompts_dir, new_meta_hash.? });
        defer allocator.free(meta_dest_path);

        const meta_dest_file = fs.createFileAbsolute(meta_dest_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt to registry\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        meta_dest_file.writeAll(meta_content) catch {
            meta_dest_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to write meta-prompt to registry\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        meta_dest_file.close();
    }

    // Process --add: upload files and collect refs
    var new_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer {
        for (new_refs.items) |ref| {
            allocator.free(ref.hash);
            allocator.free(ref.category);
            allocator.free(ref.name);
            allocator.free(ref.description);
            allocator.free(ref.format);
        }
        new_refs.deinit(allocator);
    }

    if (add_files.items.len > 0) {
        var sp_add = spinner.init(stdout, "Uploading prompts");
        sp_add.start();

        for (add_files.items) |file_arg| {
            const file_path = if (std.fs.path.isAbsolute(file_arg))
                try allocator.dupe(u8, file_arg)
            else
                try std.fs.path.join(allocator, &.{ cwd, file_arg });
            defer allocator.free(file_path);

            // Read file
            const file = fs.openFileAbsolute(file_path, .{}) catch {
                sp_add.fail();
                try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, file_arg });
                return;
            };
            const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
                file.close();
                sp_add.fail();
                try stderr.print("{s}{s}{s}Error:{s} Failed to read file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, file_arg });
                return;
            };
            file.close();
            defer allocator.free(content);

            // Compute hash
            var hash_bytes: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &hash_bytes, .{});
            var hash_hex: [64]u8 = undefined;
            hexEncode(&hash_bytes, &hash_hex);
            const hash = try allocator.dupe(u8, &hash_hex);

            // Extract metadata
            const basename = std.fs.path.basename(file_arg);
            const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
            const format = if (ext_idx) |ei| try allocator.dupe(u8, basename[ei + 1 ..]) else try allocator.dupe(u8, "md");
            const name_end = ext_idx orelse basename.len;
            const raw_name = basename[0..name_end];

            const fm = parseFrontmatter(content);
            // Name always comes from filename
            const name = try allocator.dupe(u8, stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, fm.description orelse "-");
            const category = try allocator.dupe(u8, fm.category orelse "conduct");

            // Copy to registry
            const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
            defer allocator.free(dest_path);
            fs.copyFileAbsolute(file_path, dest_path, .{}) catch {};

            try new_refs.append(allocator, .{
                .hash = hash,
                .category = category,
                .name = name,
                .description = description,
                .format = format,
            });
        }
        sp_add.succeed();

        // Update prompts/index.json
        var sp_idx = spinner.init(stdout, "Updating prompts index");
        sp_idx.start();
        updatePromptsIndex(allocator, registry_path, new_refs.items) catch {
            sp_idx.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to update prompts index\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        sp_idx.succeed();
    }

    // Update bundle: add new refs and remove specified hashes
    var sp_update = spinner.init(stdout, "Updating bundle");
    sp_update.start();

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        idx_file.close();
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Invalid bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Rebuild index with updated bundle
    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);
    try new_index.appendSlice(allocator, "{\n  \"bundles\": [");

    var first = true;
    var added_count: usize = 0;
    var removed_count: usize = 0;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        if (std.mem.eql(u8, item_name, bundle_name)) {
            // This is the target bundle - rebuild with modifications
            const item_task = if (item.object.get("task")) |t| t.string else "-";
            const item_desc = if (item.object.get("description")) |d| d.string else "-";
            const item_created = if (item.object.get("created_at")) |c| c.string else "0";
            const item_meta = new_meta_hash orelse (if (item.object.get("meta_prompt")) |m| m.string else "");

            const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
            defer allocator.free(entry_start);
            try new_index.appendSlice(allocator, entry_start);

            var ref_first = true;

            // Keep existing prompts (excluding those in rm_hashes)
            if (item.object.get("prompts")) |prompts| {
                for (prompts.array.items) |ref| {
                    const hash = if (ref.object.get("hash")) |h| h.string else continue;
                    const cat = if (ref.object.get("category")) |p| p.string else continue;

                    // Check if this hash should be removed
                    var should_remove = false;
                    for (rm_hashes.items) |rm_hash| {
                        if (std.mem.startsWith(u8, hash, rm_hash)) {
                            should_remove = true;
                            removed_count += 1;
                            break;
                        }
                    }

                    if (!should_remove) {
                        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                            if (ref_first) "" else ",",
                            hash,
                            cat,
                        });
                        defer allocator.free(ref_entry);
                        try new_index.appendSlice(allocator, ref_entry);
                        ref_first = false;
                    }
                }
            }

            // Add new prompts
            for (new_refs.items) |ref| {
                const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                    if (ref_first) "" else ",",
                    ref.hash,
                    ref.category,
                });
                defer allocator.free(ref_entry);
                try new_index.appendSlice(allocator, ref_entry);
                ref_first = false;
                added_count += 1;
            }

            try new_index.appendSlice(allocator, "\n      ]\n    }");
        } else {
            // Other bundles - copy as-is
            try appendBundleEntry(allocator, &new_index, item);
        }
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    // Write updated index
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {
        sp_update.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to write bundle index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp_update.succeed();

    // Commit and push
    var sp_push = spinner.init(stdout, "Pushing to registry");
    sp_push.start();

    var add_output2: GitOutput = .{};
    defer add_output2.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output2) catch {};

    var commit_output2: GitOutput = .{};
    defer commit_output2.deinit(allocator);
    git.commit(allocator, registry_path, "Update bundle", &commit_output2) catch {};

    var git_output2: GitOutput = .{};
    defer git_output2.deinit(allocator);

    git.push(allocator, registry_path, &git_output2) catch {
        sp_push.fail();
        printGitOutputRaw(&git_output2);
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp_push.succeed();
    printGitOutputRaw(&git_output2);

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    if (new_meta_hash != null) {
        try stdout.print("{s}    Meta-prompt updated\n", .{P});
    }
    if (added_count > 0) {
        try stdout.print("{s}    Added: {d} prompts\n", .{ P, added_count });
    }
    if (removed_count > 0) {
        try stdout.print("{s}    Removed: {d} prompts\n", .{ P, removed_count });
    }
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle show <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    const name = args[0];

    // Read index to find bundle by name
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find bundle by name
    var found_bundle: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, name)) {
            found_bundle = item;
            break;
        }
    }

    if (found_bundle == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name });
        return;
    }

    const bundle = found_bundle.?;
    const bundle_name = if (bundle.object.get("name")) |n| n.string else "-";
    const bundle_task = if (bundle.object.get("task")) |t| t.string else "-";
    const bundle_desc = if (bundle.object.get("description")) |d| d.string else "-";
    const bundle_meta = if (bundle.object.get("meta_prompt")) |m| m.string else "";

    try stdout.print("{s}{s}{s}Bundle:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, bundle_name });
    try stdout.print("{s}{s}Task:{s} {s}\n", .{ P, Color.orange, Color.reset, bundle_task });
    try stdout.print("{s}{s}Description:{s} {s}\n", .{ P, Color.orange, Color.reset, bundle_desc });
    if (bundle_meta.len > 0) {
        const short_meta = if (bundle_meta.len >= 8) bundle_meta[0..8] else bundle_meta;
        try stdout.print("{s}{s}Meta-prompt:{s} {s}\n", .{ P, Color.orange, Color.reset, short_meta });
    }
    try stdout.writeAll("\n");

    // List prompt references
    const prompts_arr = bundle.object.get("prompts") orelse {
        try stdout.print("{s}{s}No prompts in bundle{s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };

    // Build lookup from prompts/index.json (duplicate strings to avoid use-after-free)
    const prompts_index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(prompts_index_path);

    const PromptInfo = struct { name: []const u8, description: []const u8 };
    var prompt_lookup = std.StringHashMap(PromptInfo).init(allocator);
    defer {
        var iter = prompt_lookup.iterator();
        while (iter.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
            allocator.free(@constCast(entry.value_ptr.name));
            allocator.free(@constCast(entry.value_ptr.description));
        }
        prompt_lookup.deinit();
    }

    if (fs.openFileAbsolute(prompts_index_path, .{})) |prompts_file| {
        const prompts_content = prompts_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            prompts_file.close();
            return;
        };
        prompts_file.close();
        defer allocator.free(prompts_content);

        if (std.json.parseFromSlice(std.json.Value, allocator, prompts_content, .{})) |prompts_parsed| {
            defer prompts_parsed.deinit();
            if (prompts_parsed.value.object.get("prompts")) |prompts_list| {
                for (prompts_list.array.items) |item| {
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";

                    // Duplicate strings to keep them valid after JSON is freed
                    const hash_copy = allocator.dupe(u8, item_hash) catch continue;
                    const name_copy = allocator.dupe(u8, item_name) catch {
                        allocator.free(hash_copy);
                        continue;
                    };
                    const desc_copy = allocator.dupe(u8, item_desc) catch {
                        allocator.free(hash_copy);
                        allocator.free(name_copy);
                        continue;
                    };

                    prompt_lookup.put(hash_copy, .{ .name = name_copy, .description = desc_copy }) catch {
                        allocator.free(hash_copy);
                        allocator.free(name_copy);
                        allocator.free(desc_copy);
                    };
                }
            }
        } else |_| {}
    } else |_| {}

    try stdout.print("{s}{s}{s}Prompts ({d}):{s}\n", .{ P, Color.bold, Color.orange, prompts_arr.array.items.len, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}  {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (prompts_arr.array.items) |ref| {
        const hash = if (ref.object.get("hash")) |h| h.string else "-";
        const category = if (ref.object.get("category")) |p| p.string else "-";
        const short_hash = if (hash.len >= 8) hash[0..8] else hash;

        // Lookup name and description
        const lookup_result = prompt_lookup.get(hash);
        const p_name = if (lookup_result) |r| r.name else "-";
        const p_desc = if (lookup_result) |r| r.description else "-";

        try stdout.print("{s}  {s}{s: <8}{s}  {s: <8}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, p_name, p_desc });
    }
    try stdout.writeAll("\n");
}

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle rm <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    const name = args[0];

    // Read index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
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
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Find and remove bundle by name (only from index, keep prompts)
    var found = false;
    var new_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer new_bundles.deinit(allocator);

    try new_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    var first = true;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (std.mem.eql(u8, item_name, name)) {
            found = true;
            continue;
        }

        if (!first) try new_bundles.appendSlice(allocator, ",");
        first = false;

        try appendBundleEntry(allocator, &new_bundles, item);
    }
    try new_bundles.appendSlice(allocator, "\n  ]\n}\n");

    if (!found) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name });
        return;
    }

    // Write updated index (prompts are kept in registry)
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_bundles.items) catch {};

    // Commit and push
    var sp = spinner.init(stdout, "Removing from registry");
    sp.start();

    var add_output3: GitOutput = .{};
    defer add_output3.deinit(allocator);
    git.addAll(allocator, registry_path, &add_output3) catch {};

    var commit_output3: GitOutput = .{};
    defer commit_output3.deinit(allocator);
    git.commit(allocator, registry_path, "Remove bundle", &commit_output3) catch {};

    var git_output3: GitOutput = .{};
    defer git_output3.deinit(allocator);

    git.push(allocator, registry_path, &git_output3) catch {
        sp.fail();
        printGitOutputRaw(&git_output3);
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        return;
    };
    sp.succeed();
    printGitOutputRaw(&git_output3);

    try stdout.print("{s}{s}{s}✓{s} Removed bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, name });
    try stdout.print("{s}{s}Note: Prompts are kept in registry (may be used by other bundles){s}\n\n", .{ P, Color.dim, Color.reset });
}

// Helper functions

fn bundleExists(allocator: std.mem.Allocator, registry_path: []const u8, name: []const u8) bool {
    const index_path = std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" }) catch return false;
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return false;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();

    const bundles = parsed.value.object.get("bundles") orelse return false;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, name)) return true;
    }
    return false;
}

fn collectAndUploadPrompts(allocator: std.mem.Allocator, src_dir: []const u8, base_name: []const u8, prompts_dir: []const u8, refs: *std.ArrayListUnmanaged(PromptRef)) !void {
    var dir = fs.openDirAbsolute(src_dir, .{ .iterate = true }) catch return error.Failed;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return error.Failed) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src_dir, entry.name });
        defer allocator.free(src_path);

        if (entry.kind == .directory) {
            const sub_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_name, entry.name });
            defer allocator.free(sub_base);
            try collectAndUploadPrompts(allocator, src_path, sub_base, prompts_dir, refs);
        } else if (entry.kind == .file) {
            // Extract format from extension
            const ext_idx = std.mem.lastIndexOf(u8, entry.name, ".");
            if (ext_idx == null) continue; // Skip files without extension
            const format = try allocator.dupe(u8, entry.name[ext_idx.? + 1 ..]);
            const name_end = ext_idx.?;

            // Read file content for hash and frontmatter
            const file = fs.openFileAbsolute(src_path, .{}) catch continue;
            const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
                file.close();
                continue;
            };
            file.close();
            defer allocator.free(content);

            // Compute hash
            var hash_bytes: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &hash_bytes, .{});
            var hash_hex: [64]u8 = undefined;
            hexEncode(&hash_bytes, &hash_hex);
            const hash = try allocator.dupe(u8, &hash_hex);

            // Parse frontmatter for metadata (only for text files)
            const fm = parseFrontmatter(content);
            const raw_name = entry.name[0..name_end];
            // Strip sequence prefix (NN_) if present, name always comes from filename
            const name = try allocator.dupe(u8, stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, fm.description orelse "-");
            // Use frontmatter category if available, otherwise use base_name from directory
            const prompt_category = fm.category orelse base_name;

            // Copy to prompts/<hash> (pure hash, no extension)
            const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
            defer allocator.free(dest_path);
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch {};

            // Add reference (category is just the directory: conduct or command)
            try refs.append(allocator, .{
                .hash = hash,
                .category = try allocator.dupe(u8, prompt_category),
                .name = name,
                .description = description,
                .format = format,
            });
        }
    }
}

fn updatePromptsIndex(allocator: std.mem.Allocator, registry_path: []const u8, refs: []const PromptRef) !void {
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    // Build index content, preserving existing entries and adding new ones
    var index_content: std.ArrayListUnmanaged(u8) = .{};
    defer index_content.deinit(allocator);
    try index_content.appendSlice(allocator, "{\n  \"prompts\": [");

    // Track hashes to avoid duplicates (keys are owned, must free)
    var seen_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_hashes.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(@constCast(key.*));
        }
        seen_hashes.deinit();
    }

    var first = true;
    const timestamp = std.time.timestamp();

    // Read and preserve existing entries
    if (fs.openFileAbsolute(index_path, .{})) |file| {
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            file.close();
            return;
        };
        file.close();
        defer allocator.free(content);

        if (std.json.parseFromSlice(std.json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                for (prompts.array.items) |item| {
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_format = if (item.object.get("format")) |f| f.string else "md";
                    const item_category = if (item.object.get("category")) |p| p.string else "conduct";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    const hash_copy = allocator.dupe(u8, item_hash) catch continue;
                    seen_hashes.put(hash_copy, {}) catch {
                        allocator.free(hash_copy);
                    };

                    const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{
                        if (first) "" else ",",
                        item_hash,
                        item_name,
                        item_desc,
                        item_format,
                        item_category,
                        item_created,
                    });
                    defer allocator.free(entry);
                    try index_content.appendSlice(allocator, entry);
                    first = false;
                }
            }
        } else |_| {}
    } else |_| {}

    // Add new refs that don't exist yet
    for (refs) |ref| {
        if (seen_hashes.contains(ref.hash)) continue;

        const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"category\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}", .{
            if (first) "" else ",",
            ref.hash,
            ref.name,
            ref.description,
            ref.format,
            ref.category,
            timestamp,
        });
        defer allocator.free(entry);
        try index_content.appendSlice(allocator, entry);
        first = false;
    }

    try index_content.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = try fs.createFileAbsolute(index_path, .{});
    defer idx_out.close();
    try idx_out.writeAll(index_content.items);
}

fn appendBundleEntry(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), item: std.json.Value) !void {
    const item_name = if (item.object.get("name")) |n| n.string else return;
    const item_task = if (item.object.get("task")) |t| t.string else "-";
    const item_desc = if (item.object.get("description")) |d| d.string else "-";
    const item_created = if (item.object.get("created_at")) |c| c.string else "0";
    const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

    const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
    defer allocator.free(entry_start);
    try buf.appendSlice(allocator, entry_start);

    if (item.object.get("prompts")) |prompts| {
        for (prompts.array.items, 0..) |ref, idx| {
            const hash = if (ref.object.get("hash")) |h| h.string else continue;
            const category = if (ref.object.get("category")) |p| p.string else continue;
            const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                if (idx > 0) "," else "",
                hash,
                category,
            });
            defer allocator.free(ref_entry);
            try buf.appendSlice(allocator, ref_entry);
        }
    }
    try buf.appendSlice(allocator, "\n      ]\n    }");
}
