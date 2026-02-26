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
const findNextSequence = commands.findNextSequence;
const MAX_FILE_SIZE = commands.MAX_FILE_SIZE;
const ensureRegistry = commands.ensureRegistry;

const SubCommand = enum {
    list,
    register,
    update,
    show,
    rm,
    import_bundle,
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
        } else if (std.mem.eql(u8, arg, "import")) {
            subcmd = .import_bundle;
            subcmd_args_start = i + 1;
        } else if (subcmd == .none and std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try printBundleHelp(stderr);
            return;
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
        .import_bundle => try runImportBundle(stdout, stderr, allocator, filtered_args.items, sync),
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
    try out.print("{s}  {s}import{s} <name> [--remote-url <url>] [--update-meta]   Import bundle to .prompts/\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}register{s} <meta-prompt> <dirs...>      Register bundle from workspace\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}update{s} <name> [--add/--rm/--add-prompt/--rm-prompt/--meta]  Modify bundle\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}show{s} <name> [--meta]                   Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}rm{s} <name>...                          Remove bundle(s)\n\n", .{ P, Color.cyan, Color.reset });
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

fn isHexString(s: []const u8) bool {
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
            return false;
        }
    }
    return true;
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

        // New format: show categories count; old format: show prompts count
        const categories_arr = item.object.get("categories");
        const count = if (categories_arr) |c| c.array.items.len else blk: {
            const prompts_arr = item.object.get("prompts");
            break :blk if (prompts_arr) |p| p.array.items.len else 0;
        };
        const label: []const u8 = if (categories_arr != null) " cats" else " prompts";

        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}{s}", .{ count, label }) catch "-";

        try stdout.print("{s}  {s}{s: <20}{s}  {s: <8}  {s: <10}  {s}\n", .{ P, Color.cyan, name, Color.reset, item_task, count_str, desc });
    }
    try stdout.writeAll("\n");
}

fn runRegister(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    // Usage: bundle register <meta-prompt-file> <dirs...>
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies bundle register <meta-prompt-file> <dir1> [dir2...]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }
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

    // Collect unique categories from prompt refs
    var seen_cats = std.StringHashMap(void).init(allocator);
    defer seen_cats.deinit();
    var cat_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer cat_list.deinit(allocator);

    for (prompt_refs.items) |ref| {
        if (!seen_cats.contains(ref.category)) {
            seen_cats.put(ref.category, {}) catch {};
            cat_list.append(allocator, ref.category) catch {};
        }
    }

    const new_entry_start = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{d}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{
        comma,
        bundle_name,
        task,
        description,
        timestamp,
        meta_prompt_hash,
    });
    defer allocator.free(new_entry_start);
    try existing_bundles.appendSlice(allocator, new_entry_start);

    // Write categories array
    for (cat_list.items, 0..) |cat, idx| {
        const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
            if (idx > 0) ", " else "",
            cat,
        });
        defer allocator.free(cat_entry);
        try existing_bundles.appendSlice(allocator, cat_entry);
    }

    try existing_bundles.appendSlice(allocator, "],\n      \"prompts\": []\n    }\n  ]\n}\n");

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
    // Usage: bundle update <name> --add <dirs...> --rm <cats...> --add-prompt <hashes...> --rm-prompt <hashes...> --meta <file>
    if (args.len < 2) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name and at least one flag required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add <dirs>] [--rm <cats>] [--add-prompt <hash>] [--rm-prompt <hash>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];

    // Parse flags
    var add_dirs: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_dirs.deinit(allocator);
    var rm_cats: std.ArrayListUnmanaged([]const u8) = .{};
    defer rm_cats.deinit(allocator);
    var add_prompt_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_prompt_hashes.deinit(allocator);
    var rm_prompt_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer rm_prompt_hashes.deinit(allocator);
    var meta_file_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--add")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try add_dirs.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--rm")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try rm_cats.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--add-prompt")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try add_prompt_hashes.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--rm-prompt")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try rm_prompt_hashes.append(allocator, args[i]);
            }
            if (i < args.len) i -= 1;
        } else if (std.mem.eql(u8, args[i], "--meta")) {
            i += 1;
            if (i < args.len and !std.mem.startsWith(u8, args[i], "--")) {
                meta_file_arg = args[i];
            }
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, args[i] });
            try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add <dirs>] [--rm <cats>] [--add-prompt <hash>] [--rm-prompt <hash>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    if (add_dirs.items.len == 0 and rm_cats.items.len == 0 and add_prompt_hashes.items.len == 0 and rm_prompt_hashes.items.len == 0 and meta_file_arg == null) {
        try stderr.print("{s}{s}{s}Error:{s} No changes specified\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add <dirs>] [--rm <cats>] [--add-prompt <hash>] [--rm-prompt <hash>] [--meta <file>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    if (!bundleExists(allocator, registry_path, bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        return;
    }

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

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(meta_content, &hash_bytes, .{});
        var hash_hex: [64]u8 = undefined;
        hexEncode(&hash_bytes, &hash_hex);
        new_meta_hash = try allocator.dupe(u8, &hash_hex);

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

    // Process --add: scan directories, upload prompts, collect new categories
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

    if (add_dirs.items.len > 0) {
        var sp_add = spinner.init(stdout, "Uploading prompts");
        sp_add.start();

        for (add_dirs.items) |dir_arg| {
            const dir_path = if (std.fs.path.isAbsolute(dir_arg))
                try allocator.dupe(u8, dir_arg)
            else
                try std.fs.path.join(allocator, &.{ cwd, dir_arg });
            defer allocator.free(dir_path);

            const category = std.fs.path.basename(dir_arg);
            collectAndUploadPrompts(allocator, dir_path, category, prompts_dir, &new_refs) catch continue;
        }

        if (new_refs.items.len == 0) {
            sp_add.fail();
            try stderr.print("{s}{s}{s}Error:{s} No prompt files found in specified directories\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
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

    // Update bundle index
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
    var cats_added: usize = 0;
    var cats_removed: usize = 0;
    var prompts_added: usize = 0;
    var prompts_removed: usize = 0;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        if (std.mem.eql(u8, item_name, bundle_name)) {
            // Target bundle - rebuild with categories + prompts format
            const item_task = if (item.object.get("task")) |t| t.string else "-";
            const item_desc = if (item.object.get("description")) |d| d.string else "-";
            const item_created = if (item.object.get("created_at")) |c| c.string else "0";
            const item_meta = new_meta_hash orelse (if (item.object.get("meta_prompt")) |m| m.string else "");

            const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
            defer allocator.free(entry_start);
            try new_index.appendSlice(allocator, entry_start);

            // Build categories list: existing + new from --add dirs, minus --rm cats
            var cat_set = std.StringHashMap(void).init(allocator);
            defer cat_set.deinit();
            var cat_order: std.ArrayListUnmanaged([]const u8) = .{};
            defer cat_order.deinit(allocator);

            // Seed from existing categories (or extract from old prompts array)
            if (item.object.get("categories")) |existing_cats| {
                for (existing_cats.array.items) |c| {
                    if (!cat_set.contains(c.string)) {
                        cat_set.put(c.string, {}) catch {};
                        cat_order.append(allocator, c.string) catch {};
                    }
                }
            } else if (item.object.get("prompts")) |old_prompts| {
                for (old_prompts.array.items) |ref| {
                    const cat = if (ref.object.get("category")) |c| c.string else continue;
                    if (!cat_set.contains(cat)) {
                        cat_set.put(cat, {}) catch {};
                        cat_order.append(allocator, cat) catch {};
                    }
                }
            }

            // Add new categories from --add dirs
            for (new_refs.items) |ref| {
                if (!cat_set.contains(ref.category)) {
                    cat_set.put(ref.category, {}) catch {};
                    cat_order.append(allocator, ref.category) catch {};
                    cats_added += 1;
                }
            }

            // Remove --rm categories
            for (rm_cats.items) |rm_cat| {
                if (cat_set.contains(rm_cat)) {
                    _ = cat_set.remove(rm_cat);
                    cats_removed += 1;
                }
            }

            // Write categories array (preserving order, skipping removed)
            var cat_first = true;
            for (cat_order.items) |cat| {
                if (!cat_set.contains(cat)) continue;
                const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                    if (cat_first) "" else ", ",
                    cat,
                });
                defer allocator.free(cat_entry);
                try new_index.appendSlice(allocator, cat_entry);
                cat_first = false;
            }

            try new_index.appendSlice(allocator, "],\n      \"prompts\": [");

            // Build prompts list (precise refs)
            var prompt_first = true;

            // Keep existing precise prompts (if new format), minus --rm-prompt
            if (item.object.get("categories") != null) {
                // New format: prompts array has precise refs
                if (item.object.get("prompts")) |existing_prompts| {
                    for (existing_prompts.array.items) |ref| {
                        const hash = if (ref.object.get("hash")) |h| h.string else continue;
                        const cat = if (ref.object.get("category")) |c| c.string else continue;

                        var should_remove = false;
                        for (rm_prompt_hashes.items) |rm_hash| {
                            if (std.mem.startsWith(u8, hash, rm_hash)) {
                                should_remove = true;
                                prompts_removed += 1;
                                break;
                            }
                        }
                        if (should_remove) continue;

                        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                            if (prompt_first) "" else ",",
                            hash,
                            cat,
                        });
                        defer allocator.free(ref_entry);
                        try new_index.appendSlice(allocator, ref_entry);
                        prompt_first = false;
                    }
                }
            }
            // Old format (no categories): don't carry over old prompts to precise refs

            // Add --add-prompt hashes
            for (add_prompt_hashes.items) |add_hash| {
                // Look up category from prompts index
                var found_cat: []const u8 = "conduct";
                const p_idx_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
                defer allocator.free(p_idx_path);
                if (fs.openFileAbsolute(p_idx_path, .{})) |pf| {
                    defer pf.close();
                    if (pf.readToEndAlloc(allocator, MAX_FILE_SIZE)) |pc| {
                        defer allocator.free(pc);
                        if (std.json.parseFromSlice(std.json.Value, allocator, pc, .{})) |pp| {
                            defer pp.deinit();
                            if (pp.value.object.get("prompts")) |pl| {
                                for (pl.array.items) |p| {
                                    const ph = if (p.object.get("hash")) |h| h.string else continue;
                                    if (std.mem.startsWith(u8, ph, add_hash)) {
                                        found_cat = if (p.object.get("category")) |c| c.string else "conduct";
                                        break;
                                    }
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                } else |_| {}

                const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"category\": \"{s}\" }}", .{
                    if (prompt_first) "" else ",",
                    add_hash,
                    found_cat,
                });
                defer allocator.free(ref_entry);
                try new_index.appendSlice(allocator, ref_entry);
                prompt_first = false;
                prompts_added += 1;
            }

            try new_index.appendSlice(allocator, "]\n    }");
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
    if (cats_added > 0) {
        try stdout.print("{s}    Categories added: {d}\n", .{ P, cats_added });
    }
    if (cats_removed > 0) {
        try stdout.print("{s}    Categories removed: {d}\n", .{ P, cats_removed });
    }
    if (prompts_added > 0) {
        try stdout.print("{s}    Prompts added: {d}\n", .{ P, prompts_added });
    }
    if (prompts_removed > 0) {
        try stdout.print("{s}    Prompts removed: {d}\n", .{ P, prompts_removed });
    }
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle show <name> [--meta]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Parse args
    var name: ?[]const u8 = null;
    var show_meta: bool = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--meta")) {
            show_meta = true;
        } else if (name == null and !std.mem.startsWith(u8, arg, "-")) {
            name = arg;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies bundle show <name> [--meta]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    if (name == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle show <name> [--meta]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

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
        if (std.mem.eql(u8, item_name, name.?)) {
            found_bundle = item;
            break;
        }
    }

    if (found_bundle == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name.? });
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

    // --meta: print full meta-prompt content and return
    if (show_meta) {
        if (bundle_meta.len == 0) {
            try stderr.print("{s}{s}{s}Error:{s} Bundle has no meta-prompt\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        }
        const meta_path = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts", bundle_meta });
        defer allocator.free(meta_path);

        const meta_file = fs.openFileAbsolute(meta_path, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Meta-prompt file not found in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer meta_file.close();

        const meta_content = meta_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to read meta-prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        defer allocator.free(meta_content);

        try stdout.writeAll(meta_content);
        if (meta_content.len > 0 and meta_content[meta_content.len - 1] != '\n') {
            try stdout.writeAll("\n");
        }
        return;
    }

    // Read prompts/index.json for resolving categories to prompts
    const prompts_index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" });
    defer allocator.free(prompts_index_path);

    var prompts_index: ?std.json.Parsed(std.json.Value) = null;
    if (fs.openFileAbsolute(prompts_index_path, .{})) |pf| {
        defer pf.close();
        if (pf.readToEndAlloc(allocator, MAX_FILE_SIZE)) |pc| {
            defer allocator.free(pc);
            prompts_index = std.json.parseFromSlice(std.json.Value, allocator, pc, .{}) catch null;
        } else |_| {}
    } else |_| {}
    defer if (prompts_index) |pi| pi.deinit();

    const prompts_list = if (prompts_index) |pi| pi.value.object.get("prompts") else null;

    const has_categories = bundle.object.get("categories") != null;

    if (has_categories) {
        // New format: show categories and resolved prompts
        const categories = bundle.object.get("categories").?;

        try stdout.print("{s}{s}{s}Categories ({d}):{s}\n", .{ P, Color.bold, Color.orange, categories.array.items.len, Color.reset });
        for (categories.array.items) |cat_val| {
            try stdout.print("{s}  {s}{s}{s}\n", .{ P, Color.cyan, cat_val.string, Color.reset });
        }
        try stdout.writeAll("\n");

        // Show resolved prompts per category
        try stdout.print("{s}{s}{s}Resolved prompts:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
        try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}        {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

        var total: usize = 0;

        // From categories (batch)
        if (prompts_list) |pl| {
            for (categories.array.items) |cat_val| {
                const cat = cat_val.string;
                for (pl.array.items) |p| {
                    const p_cat = if (p.object.get("category")) |c| c.string else continue;
                    if (std.mem.eql(u8, p_cat, cat)) {
                        const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                        const p_name = if (p.object.get("name")) |n| n.string else "-";
                        const p_desc = if (p.object.get("description")) |d| d.string else "-";
                        const short_hash = if (p_hash.len >= 8) p_hash[0..8] else p_hash;

                        try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, p_cat, p_name, p_desc });
                        total += 1;
                    }
                }
            }
        }

        // From precise prompts
        if (bundle.object.get("prompts")) |precise| {
            for (precise.array.items) |ref| {
                const hash = if (ref.object.get("hash")) |h| h.string else continue;
                const ref_cat = if (ref.object.get("category")) |c| c.string else "-";
                const short_hash = if (hash.len >= 8) hash[0..8] else hash;

                // Look up name/desc
                var p_name: []const u8 = "-";
                var p_desc: []const u8 = "-";
                if (prompts_list) |pl| {
                    for (pl.array.items) |p| {
                        const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                        if (std.mem.eql(u8, p_hash, hash)) {
                            p_name = if (p.object.get("name")) |n| n.string else "-";
                            p_desc = if (p.object.get("description")) |d| d.string else "-";
                            break;
                        }
                    }
                }

                try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}  {s}(precise){s}\n", .{ P, Color.cyan, short_hash, Color.reset, ref_cat, p_name, p_desc, Color.dim, Color.reset });
                total += 1;
            }
        }

        if (total == 0) {
            try stdout.print("{s}  {s}(no matching prompts){s}\n", .{ P, Color.dim, Color.reset });
        }
    } else {
        // Old format: show prompts array directly
        const prompts_arr = bundle.object.get("prompts") orelse {
            try stdout.print("{s}{s}No prompts in bundle{s}\n\n", .{ P, Color.dim, Color.reset });
            return;
        };

        try stdout.print("{s}{s}{s}Prompts ({d}):{s}\n", .{ P, Color.bold, Color.orange, prompts_arr.array.items.len, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});
        try stdout.print("{s}  {s}HASH{s}      {s}CATEGORY{s}        {s}NAME{s}                  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
        try stdout.print("{s}────────────────────────────────────────────────────────────────────────────────\n", .{P});

        for (prompts_arr.array.items) |ref| {
            const hash = if (ref.object.get("hash")) |h| h.string else "-";
            const category = if (ref.object.get("category")) |p| p.string else "-";
            const short_hash = if (hash.len >= 8) hash[0..8] else hash;

            // Lookup name/desc from prompts index
            var p_name: []const u8 = "-";
            var p_desc: []const u8 = "-";
            if (prompts_list) |pl| {
                for (pl.array.items) |p| {
                    const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                    if (std.mem.eql(u8, p_hash, hash)) {
                        p_name = if (p.object.get("name")) |n| n.string else "-";
                        p_desc = if (p.object.get("description")) |d| d.string else "-";
                        break;
                    }
                }
            }

            try stdout.print("{s}  {s}{s: <8}{s}  {s: <14}  {s: <20}  {s}\n", .{ P, Color.cyan, short_hash, Color.reset, category, p_name, p_desc });
        }
    }
    try stdout.writeAll("\n");
}

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, arg });
            try stderr.print("{s}Usage: {s}clumsies bundle rm <name>...{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle rm <name>...{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

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

    // Find and remove bundles by name (only from index, keep prompts)
    var removed_count: usize = 0;
    var new_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer new_bundles.deinit(allocator);

    try new_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    var first = true;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        // Check if this bundle should be removed
        var should_remove = false;
        for (args) |name| {
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
        try stderr.print("{s}{s}{s}Error:{s} No matching bundles found\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const commit_msg = if (removed_count == 1) "Remove bundle" else "Remove bundles";
    var commit_output3: GitOutput = .{};
    defer commit_output3.deinit(allocator);
    git.commit(allocator, registry_path, commit_msg, &commit_output3) catch {};

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

    try stdout.print("{s}{s}{s}✓{s} Removed {d} bundle(s)\n", .{ P, Color.bold, Color.green, Color.reset, removed_count });
    try stdout.print("{s}{s}Note: Prompts are kept in registry (may be used by other bundles){s}\n\n", .{ P, Color.dim, Color.reset });
}

fn runImportBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8, sync: bool) !void {
    // Parse args: import <name> [--remote-url <url>] [--update-meta]
    var bundle_name: ?[]const u8 = null;
    var remote_url: ?[]const u8 = null;
    var update_meta_only: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--remote-url") or std.mem.eql(u8, args[i], "-r")) {
            i += 1;
            if (i < args.len) {
                remote_url = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--update-meta")) {
            update_meta_only = true;
        } else if (bundle_name == null and !std.mem.startsWith(u8, args[i], "-")) {
            bundle_name = args[i];
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, args[i] });
            try stderr.print("{s}Usage: {s}clumsies bundle import <name> [--remote-url <url>] [--update-meta]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    if (bundle_name == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle import <name> [--remote-url <url>] [--update-meta]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine .prompts/ path\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    // Create .prompts/ and git init if not exists (skip in --update-meta mode)
    if (!update_meta_only) {
        const need_init = !commands.promptsExist();
        if (need_init) {
            fs.cwd().makeDir(".prompts") catch |err| {
                try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n", .{ P, Color.bold, Color.red, Color.reset, err });
                return;
            };

            // Only create context/ here; conduct/ and command/ subdirs are
            // created dynamically during import based on prompt categories
            const context_path = try std.fs.path.join(allocator, &.{ prompts_path, "context" });
            defer allocator.free(context_path);
            fs.cwd().makePath(context_path) catch {};

            // Git init
            var init_output: GitOutput = .{};
            defer init_output.deinit(allocator);

            git.init(allocator, prompts_path, &init_output) catch {
                printGitOutputRaw(&init_output);
                try stderr.print("{s}{s}{s}Error:{s} Failed to initialize git repository\n", .{ P, Color.bold, Color.red, Color.reset });
                fs.deleteTreeAbsolute(prompts_path) catch {};
                return;
            };
            try stdout.print("{s}{s}{s}✓{s} Initialized .prompts/ repository\n", .{ P, Color.bold, Color.green, Color.reset });
            printGitOutputRaw(&init_output);
        }
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator, sync) catch return;
    defer allocator.free(registry_path);

    // Read bundles/index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles", "index.json" });
    defer allocator.free(index_path);

    const index_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies bundle list{s} to see available bundles\n", .{ P, Color.cyan, Color.reset });
        return;
    };
    const index_content = index_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        index_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read bundles index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    index_file.close();
    defer allocator.free(index_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, index_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse bundles index\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    // Find bundle by name
    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    var found_bundle: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, bundle_name.?)) {
            found_bundle = item;
            break;
        }
    }

    if (found_bundle == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name.? });
        try stderr.print("{s}Run {s}clumsies bundle list{s} to see available bundles\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Check meta_prompt is present
    const meta_prompt_hash = if (found_bundle.?.object.get("meta_prompt")) |m| m.string else "";
    if (meta_prompt_hash.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle has no meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Bundle must be registered with a meta-prompt file\n", .{P});
        return;
    }

    // Get prompts index for name/format lookup
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

    // Copy prompts from registry (skip in --update-meta mode)
    var prompt_count: usize = 0;
    if (!update_meta_only) {
        var sp = spinner.init(stdout, "Importing prompts");
        sp.start();

        const has_categories = found_bundle.?.object.get("categories") != null;

        if (has_categories) {
            // New format: resolve prompts from categories + precise prompts
            const prompts_list = if (prompts_index) |pi| pi.value.object.get("prompts") else null;
            if (prompts_list == null) {
                sp.fail();
                try stderr.print("{s}{s}{s}Error:{s} Prompts index not found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            }

            // Collect hashes to import (dedup)
            const ImportEntry = struct { hash: []const u8, category: []const u8, name: []const u8, format: []const u8 };
            var import_set = std.StringHashMap(ImportEntry).init(allocator);
            defer import_set.deinit();

            // Step 1: categories — batch import all matching prompts
            if (found_bundle.?.object.get("categories")) |categories| {
                for (categories.array.items) |cat_val| {
                    const cat = cat_val.string;
                    for (prompts_list.?.array.items) |p| {
                        const p_cat = if (p.object.get("category")) |c| c.string else continue;
                        if (std.mem.eql(u8, p_cat, cat)) {
                            const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                            if (!import_set.contains(p_hash)) {
                                import_set.put(p_hash, .{
                                    .hash = p_hash,
                                    .category = p_cat,
                                    .name = if (p.object.get("name")) |n| n.string else "prompt",
                                    .format = if (p.object.get("format")) |f| f.string else "md",
                                }) catch {};
                            }
                        }
                    }
                }
            }

            // Step 2: precise prompts — add individual refs
            if (found_bundle.?.object.get("prompts")) |precise_prompts| {
                for (precise_prompts.array.items) |ref| {
                    const hash = if (ref.object.get("hash")) |h| h.string else continue;
                    if (!import_set.contains(hash)) {
                        const ref_cat = if (ref.object.get("category")) |c| c.string else "conduct";
                        // Look up name/format from prompts index
                        var p_name: []const u8 = "prompt";
                        var p_fmt: []const u8 = "md";
                        for (prompts_list.?.array.items) |p| {
                            const p_hash = if (p.object.get("hash")) |h| h.string else continue;
                            if (std.mem.eql(u8, p_hash, hash)) {
                                p_name = if (p.object.get("name")) |n| n.string else "prompt";
                                p_fmt = if (p.object.get("format")) |f| f.string else "md";
                                break;
                            }
                        }
                        import_set.put(hash, .{
                            .hash = hash,
                            .category = ref_cat,
                            .name = p_name,
                            .format = p_fmt,
                        }) catch {};
                    }
                }
            }

            // Step 3: copy each prompt to .prompts/{category}/
            var iter = import_set.iterator();
            while (iter.next()) |entry| {
                const ie = entry.value_ptr.*;

                const src_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", ie.hash });
                defer allocator.free(src_path);

                const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, ie.category });
                defer allocator.free(target_dir);
                fs.cwd().makePath(target_dir) catch {};

                const seq = findNextSequence(target_dir);
                const filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq, ie.name, ie.format });
                defer allocator.free(filename);
                const dest_path = try std.fs.path.join(allocator, &.{ target_dir, filename });
                defer allocator.free(dest_path);

                fs.copyFileAbsolute(src_path, dest_path, .{}) catch continue;
                prompt_count += 1;
            }
        } else {
            // Old format: iterate prompts array directly (backward compat)
            const prompts_arr = found_bundle.?.object.get("prompts") orelse {
                sp.fail();
                try stderr.print("{s}{s}{s}Error:{s} Bundle has no prompts\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            };

            for (prompts_arr.array.items) |ref| {
                const hash = if (ref.object.get("hash")) |h| h.string else continue;
                const category = if (ref.object.get("category")) |c| c.string else "conduct";

                // Look up prompt details in prompts/index.json
                var prompt_name: []const u8 = "prompt";
                var prompt_format: []const u8 = "md";
                if (prompts_index) |pi| {
                    if (pi.value.object.get("prompts")) |prompts| {
                        for (prompts.array.items) |p| {
                            const p_hash = if (p.object.get("hash")) |ph| ph.string else continue;
                            if (std.mem.eql(u8, p_hash, hash)) {
                                prompt_name = if (p.object.get("name")) |n| n.string else "prompt";
                                prompt_format = if (p.object.get("format")) |f| f.string else "md";
                                break;
                            }
                        }
                    }
                }

                // Source: registry/prompts/{hash}
                const src_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", hash });
                defer allocator.free(src_path);

                // target_dir = .prompts/{category}/ with makePath for hierarchy
                const target_dir = try std.fs.path.join(allocator, &.{ prompts_path, category });
                defer allocator.free(target_dir);
                fs.cwd().makePath(target_dir) catch {};

                const seq = findNextSequence(target_dir);
                const filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq, prompt_name, prompt_format });
                defer allocator.free(filename);
                const dest_path = try std.fs.path.join(allocator, &.{ target_dir, filename });
                defer allocator.free(dest_path);

                fs.copyFileAbsolute(src_path, dest_path, .{}) catch continue;
                prompt_count += 1;
            }
        }
        sp.succeed();
    }

    // Copy meta-prompt file
    var sp2 = spinner.init(stdout, "Copying meta-prompt");
    sp2.start();

    const meta_src = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts", meta_prompt_hash });
    defer allocator.free(meta_src);

    // Get target filename from config or default to CLAUDE.md
    const meta_prompt_file_opt = config.getMetaPromptFile(allocator) catch null;
    defer if (meta_prompt_file_opt) |f| allocator.free(f);
    const meta_prompt_filename = meta_prompt_file_opt orelse "CLAUDE.md";

    // Copy to workspace root (parent of .prompts/)
    const cwd = std.process.getCwdAlloc(allocator) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const meta_dest = try std.fs.path.join(allocator, &.{ cwd, meta_prompt_filename });
    defer allocator.free(meta_dest);

    fs.copyFileAbsolute(meta_src, meta_dest, .{}) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to copy meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp2.succeed();

    if (update_meta_only) {
        try stdout.print("{s}{s}{s}✓{s} Updated meta-prompt: {s}\n", .{ P, Color.bold, Color.green, Color.reset, meta_prompt_filename });
    } else {
        try stdout.print("{s}{s}{s}✓{s} Imported bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name.? });
        try stdout.print("{s}    Prompts: {d}\n", .{ P, prompt_count });
        try stdout.print("{s}    Meta-prompt: {s}\n", .{ P, meta_prompt_filename });

        // Add remote if specified
        if (remote_url) |url| {
            var remote_output: GitOutput = .{};
            defer remote_output.deinit(allocator);

            git.addRemote(allocator, prompts_path, url, &remote_output) catch {
                printGitOutputRaw(&remote_output);
                try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n", .{ P, Color.bold, Color.red, Color.reset });
                return;
            };
            try stdout.print("{s}{s}{s}✓{s} Added remote: {s}\n", .{ P, Color.bold, Color.green, Color.reset, url });
            printGitOutputRaw(&remote_output);
        }
    }
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

            const raw_name = entry.name[0..name_end];
            // Strip sequence prefix (NN_) if present, name always comes from filename
            const name = try allocator.dupe(u8, stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, "-");
            // Category from directory structure
            const prompt_category = base_name;

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

    const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"categories\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
    defer allocator.free(entry_start);
    try buf.appendSlice(allocator, entry_start);

    // Write categories array
    if (item.object.get("categories")) |categories| {
        // New format: has explicit categories array
        for (categories.array.items, 0..) |cat, idx| {
            const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                if (idx > 0) ", " else "",
                cat.string,
            });
            defer allocator.free(cat_entry);
            try buf.appendSlice(allocator, cat_entry);
        }
    } else if (item.object.get("prompts")) |prompts| {
        // Backward compat: extract unique categories from prompts array
        var seen_cats = std.StringHashMap(void).init(allocator);
        defer seen_cats.deinit();
        var cat_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer cat_list.deinit(allocator);

        for (prompts.array.items) |ref| {
            const cat = if (ref.object.get("category")) |c| c.string else continue;
            if (!seen_cats.contains(cat)) {
                seen_cats.put(cat, {}) catch {};
                cat_list.append(allocator, cat) catch {};
            }
        }
        for (cat_list.items, 0..) |cat, idx| {
            const cat_entry = try std.fmt.allocPrint(allocator, "{s}\"{s}\"", .{
                if (idx > 0) ", " else "",
                cat,
            });
            defer allocator.free(cat_entry);
            try buf.appendSlice(allocator, cat_entry);
        }
    }

    try buf.appendSlice(allocator, "],\n      \"prompts\": [");

    // Write prompts array (precise refs)
    if (item.object.get("prompts")) |prompts| {
        // Only write prompts if this is new format (has categories) or old format
        if (item.object.get("categories") != null) {
            // New format: prompts contains precise refs only
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
        // Old format (no categories): prompts are migrated to categories, so prompts stays empty
    }
    try buf.appendSlice(allocator, "]\n    }");
}
