const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const SubCommand = enum {
    list,
    register,
    update,
    show,
    rm,
    none,
};

// Frontmatter metadata for bundle (from meta-prompt file)
const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    task: ?[]const u8 = null,
};

fn parseFrontmatter(content: []const u8) Frontmatter {
    var fm = Frontmatter{};

    // Check for frontmatter delimiter
    if (!std.mem.startsWith(u8, content, "---")) return fm;

    // Find end delimiter
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "\n---") orelse return fm;
    const frontmatter_block = rest[0..end_idx];

    // Parse line by line
    var lines = std.mem.splitScalar(u8, frontmatter_block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.name = value;
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            const value = std.mem.trim(u8, trimmed[12..], " \t");
            if (value.len > 0) fm.description = value;
        } else if (std.mem.startsWith(u8, trimmed, "category:")) {
            const value = std.mem.trim(u8, trimmed[9..], " \t");
            if (value.len > 0) fm.category = value;
        } else if (std.mem.startsWith(u8, trimmed, "task:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.task = value;
        }
    }

    return fm;
}

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showUsage(stderr);
        return;
    }

    var subcmd: SubCommand = .none;
    const subcmd_args_start: usize = 1;

    if (std.mem.eql(u8, args[0], "list")) {
        subcmd = .list;
    } else if (std.mem.eql(u8, args[0], "register")) {
        subcmd = .register;
    } else if (std.mem.eql(u8, args[0], "update")) {
        subcmd = .update;
    } else if (std.mem.eql(u8, args[0], "show")) {
        subcmd = .show;
    } else if (std.mem.eql(u8, args[0], "rm") or std.mem.eql(u8, args[0], "remove")) {
        subcmd = .rm;
    }

    const subcmd_args = args[subcmd_args_start..];

    switch (subcmd) {
        .list => try runList(stdout, stderr, allocator),
        .register => try runRegister(stdout, stderr, allocator, subcmd_args),
        .update => try runUpdate(stdout, stderr, allocator, subcmd_args),
        .show => try runShow(stdout, stderr, allocator, subcmd_args),
        .rm => try runRm(stdout, stderr, allocator, subcmd_args),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("\n{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try stderr.print("{s}Usage: {s}clumsies bundle <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Commands:\n", .{P});
    try stderr.print("{s}  {s}list{s}                                  List bundles in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}register{s} <meta-prompt> <dirs...>      Register bundle from workspace\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}update{s} <name> --add/--rm <args...>    Add/remove prompts from bundle\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}show{s} <name>                           Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}rm{s} <name>                             Remove bundle\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Meta-prompt file frontmatter:\n", .{P});
    try stderr.print("{s}  {s}---{s}\n", .{ P, Color.dim, Color.reset });
    try stderr.print("{s}  {s}name: my-bundle{s}        (required)\n", .{ P, Color.dim, Color.reset });
    try stderr.print("{s}  {s}description: ...{s}       (optional)\n", .{ P, Color.dim, Color.reset });
    try stderr.print("{s}  {s}task: coding{s}           (optional)\n", .{ P, Color.dim, Color.reset });
    try stderr.print("{s}  {s}---{s}\n\n", .{ P, Color.dim, Color.reset });
}

fn ensureRegistry(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) ![]const u8 {
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return error.NoRegistry;
    };
    defer allocator.free(registry_url);

    const base_path = commands.getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return error.NoBasePath;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });

    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    // Print leading newline for spinner output (only once per command)
    const stdout_raw = std.fs.File.stdout();
    _ = stdout_raw.write("\n") catch {};

    if (!registry_exists) {
        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        git.clone(allocator, registry_url, registry_path) catch {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            allocator.free(registry_path);
            return error.CloneFailed;
        };
        sp.succeed();
    } else {
        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();
        var _err: ?[]const u8 = null;
        git.pull(allocator, registry_path, &_err) catch {};
        sp.succeed();
    }

    return registry_path;
}

// PromptRef represents a prompt reference in a bundle
const PromptRef = struct {
    hash: []const u8,
    category: []const u8,
    name: []const u8,
    description: []const u8,
    format: []const u8,
};


fn runList(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stdout.print("{s}{s}No bundles found in registry{s}\n\n", .{ P, Color.dim, Color.reset });
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

fn runRegister(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Usage: bundle register <meta-prompt-file> <dirs...>
    if (args.len < 2) {
        try stderr.print("\n{s}{s}{s}Error:{s} Meta-prompt file and at least one directory required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle register <meta-prompt-file> <dir1> [dir2...]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const meta_prompt_path_arg = args[0];
    const dirs = args[1..];

    // Resolve to absolute path
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
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
        try stderr.print("\n{s}{s}{s}Error:{s} Could not open meta-prompt file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, meta_prompt_path_arg });
        return;
    };
    const meta_content = meta_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        meta_file.close();
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to read meta-prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    meta_file.close();
    defer allocator.free(meta_content);

    // Parse frontmatter to get bundle metadata
    const fm = parseFrontmatter(meta_content);
    const bundle_name = fm.name orelse {
        try stderr.print("\n{s}{s}{s}Error:{s} Meta-prompt file must have 'name' in frontmatter\n", .{ P, Color.bold, Color.red, Color.reset });
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

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
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
    for (hash_bytes, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
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
        const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
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
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Add bundle") catch {};
    var push_err: ?[]const u8 = null;
    git.push(allocator, registry_path, &push_err) catch {
        sp4.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
        if (push_err) |e| {
            allocator.free(e);
        }
    };
    sp4.succeed();

    try stdout.print("{s}{s}{s}✓{s} Registered bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Prompts: {d}\n\n", .{ P, prompt_refs.items.len });
}

fn runUpdate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Usage: bundle update <name> --add <files...> --rm <hashes...>
    if (args.len < 2) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name and --add or --rm flag required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> --add <files...>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies bundle update <name> --rm <hashes...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];

    // Parse --add and --rm flags
    var add_files: std.ArrayListUnmanaged([]const u8) = .{};
    defer add_files.deinit(allocator);
    var rm_hashes: std.ArrayListUnmanaged([]const u8) = .{};
    defer rm_hashes.deinit(allocator);

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
        }
    }

    if (add_files.items.len == 0 and rm_hashes.items.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} No files to add or hashes to remove\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> --add <files...>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies bundle update <name> --rm <hashes...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
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
            const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
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
            for (hash_bytes, 0..) |byte, idx| {
                const hex_chars = "0123456789abcdef";
                hash_hex[idx * 2] = hex_chars[byte >> 4];
                hash_hex[idx * 2 + 1] = hex_chars[byte & 0x0f];
            }
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
    const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
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
            const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

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
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Update bundle") catch {};

    var git_err: ?[]const u8 = null;
    defer if (git_err) |e| allocator.free(e);

    git.push(allocator, registry_path, &git_err) catch {
        sp_push.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        if (git_err) |e| {
            try stderr.print("{s}{s}git:\n{s}{s}\n", .{ P, Color.dim, std.mem.trim(u8, e, "\n\r "), Color.reset });
        }
        return;
    };
    sp_push.succeed();

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    if (added_count > 0) {
        try stdout.print("{s}  Added: {d} prompts\n", .{ P, added_count });
    }
    if (removed_count > 0) {
        try stdout.print("{s}  Removed: {d} prompts\n", .{ P, removed_count });
    }
    try stdout.writeAll("\n");
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle show <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
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
        const prompts_content = prompts_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
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

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle rm <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const name = args[0];

    // Read index
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found\n\n", .{ P, Color.bold, Color.red, Color.reset });
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
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Remove bundle") catch {};

    var git_err: ?[]const u8 = null;
    defer if (git_err) |e| allocator.free(e);

    git.push(allocator, registry_path, &git_err) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
        if (git_err) |e| {
            try stderr.print("{s}{s}git:\n{s}{s}\n", .{ P, Color.dim, std.mem.trim(u8, e, "\n\r "), Color.reset });
        }
        return;
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Removed bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, name });
    try stdout.print("{s}{s}Note: Prompts are kept in registry (may be used by other bundles){s}\n\n", .{ P, Color.dim, Color.reset });
}

// Helper functions

fn bundleExists(allocator: std.mem.Allocator, registry_path: []const u8, name: []const u8) bool {
    const index_path = std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" }) catch return false;
    defer allocator.free(index_path);

    const file = fs.openFileAbsolute(index_path, .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return false;
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

fn computeFileHash(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try fs.openFileAbsolute(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return allocator.dupe(u8, &hash_hex);
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
            const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
                file.close();
                continue;
            };
            file.close();
            defer allocator.free(content);

            // Compute hash
            var hash_bytes: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &hash_bytes, .{});
            var hash_hex: [64]u8 = undefined;
            for (hash_bytes, 0..) |byte, i| {
                const hex_chars = "0123456789abcdef";
                hash_hex[i * 2] = hex_chars[byte >> 4];
                hash_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
            }
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
        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
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

/// Strip sequence prefix (NN_) from filename if present
/// e.g., "01_review_commit" -> "review_commit"
fn stripSequencePrefix(name: []const u8) []const u8 {
    if (name.len >= 3 and name[2] == '_') {
        // Check if first two chars are digits
        if (std.ascii.isDigit(name[0]) and std.ascii.isDigit(name[1])) {
            return name[3..];
        }
    }
    return name;
}
