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
    show,
    rm,
    update,
    none,
};

// Frontmatter metadata
const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
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
    } else if (std.mem.eql(u8, args[0], "show")) {
        subcmd = .show;
    } else if (std.mem.eql(u8, args[0], "rm") or std.mem.eql(u8, args[0], "remove")) {
        subcmd = .rm;
    } else if (std.mem.eql(u8, args[0], "update")) {
        subcmd = .update;
    }

    const subcmd_args = args[subcmd_args_start..];

    switch (subcmd) {
        .list => try runList(stdout, stderr, allocator),
        .register => try runRegister(stdout, stderr, allocator, subcmd_args),
        .show => try runShow(stdout, stderr, allocator, subcmd_args),
        .rm => try runRm(stdout, stderr, allocator, subcmd_args),
        .update => try runUpdate(stdout, stderr, allocator, subcmd_args),
        .none => try showUsage(stderr),
    }
}

fn showUsage(stderr: anytype) !void {
    try stderr.print("\n{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
    try stderr.print("{s}Usage: {s}clumsies bundle <command>{s}\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Commands:\n", .{P});
    try stderr.print("{s}  {s}list{s}                                    List bundles in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}register{s} <name> <dirs> [-t] [-d] [-M]   Register bundle\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}show{s} <name>                             Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}update{s} <name> [--add|--rm] [-t] [-d]    Update bundle\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}rm{s} <name>                               Remove bundle\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Options:\n", .{P});
    try stderr.print("{s}  {s}-t, --task{s} <task>              Task type (coding, research, etc.)\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}-d, --desc{s} <desc>              Description\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}-M, --meta-prompt-file{s} <file>  Meta-prompt file (default: CLAUDE.md)\n\n", .{ P, Color.cyan, Color.reset });
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
        git.pull(allocator, registry_path) catch {};
        sp.succeed();
    }

    return registry_path;
}

// PromptRef represents a prompt reference in a bundle
const PromptRef = struct {
    hash: []const u8,
    path: []const u8,
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
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}NAME{s}                 {s}TASK{s}      {s}PROMPTS{s}  {s}DESCRIPTION{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});

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
    // Parse args: <name> <dirs...> [-d <desc>] [-t <task>] [-M <file>]
    var description: []const u8 = "-";
    var task: []const u8 = "-";
    var meta_prompt_file: ?[]const u8 = null;
    var positional: std.ArrayListUnmanaged([]const u8) = .{};
    defer positional.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--desc")) {
            if (i + 1 < args.len) {
                i += 1;
                description = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--task")) {
            if (i + 1 < args.len) {
                i += 1;
                task = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--meta-prompt-file")) {
            if (i + 1 < args.len) {
                i += 1;
                meta_prompt_file = args[i];
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len < 2) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle requires name and at least one directory\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle register <name> <dir1> [dir2...] [-d <desc>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const bundle_name = positional.items[0];
    const dirs = positional.items[1..];

    // Check if bundle already exists
    if (bundleExists(allocator, registry_path, bundle_name)) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle already exists: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Use {s}clumsies bundle rm {s}{s} to remove it first\n\n", .{ P, Color.cyan, bundle_name, Color.reset });
        return;
    }

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    // Ensure directories exist
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const bundles_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles" });
    defer allocator.free(bundles_dir);
    fs.cwd().makePath(bundles_dir) catch {};

    // Collect all .md files and upload as prompts
    var sp = spinner.init(stdout, "Uploading prompts");
    sp.start();

    var prompt_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer {
        for (prompt_refs.items) |ref| {
            allocator.free(ref.hash);
            allocator.free(ref.path);
            allocator.free(ref.name);
            allocator.free(ref.description);
            allocator.free(ref.format);
        }
        prompt_refs.deinit(allocator);
    }

    for (dirs) |dir_name| {
        const src_path = if (std.fs.path.isAbsolute(dir_name))
            try allocator.dupe(u8, dir_name)
        else
            try std.fs.path.join(allocator, &.{ cwd, dir_name });
        defer allocator.free(src_path);

        const base_name = std.fs.path.basename(dir_name);
        collectAndUploadPrompts(allocator, src_path, base_name, prompts_dir, &prompt_refs) catch continue;
    }

    if (prompt_refs.items.len == 0) {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} No .md files found in specified directories\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    // Find and upload meta-prompt file
    var sp_meta = spinner.init(stdout, "Uploading meta-prompt");
    sp_meta.start();
    const meta_prompt_hash = findAndUploadMetaPrompt(allocator, cwd, registry_path, meta_prompt_file) catch null;
    if (meta_prompt_hash) |_| {
        sp_meta.succeed();
    } else {
        sp_meta.fail();
        try stderr.print("{s}{s}Warning:{s} No meta-prompt file found (CLAUDE.md, CURSOR.md, etc.)\n", .{ P, Color.orange, Color.reset });
    }
    defer if (meta_prompt_hash) |h| allocator.free(h);

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
        meta_prompt_hash orelse "",
    });
    defer allocator.free(new_entry_start);
    try existing_bundles.appendSlice(allocator, new_entry_start);

    // Add prompt references
    for (prompt_refs.items, 0..) |ref, idx| {
        const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"path\": \"{s}\" }}", .{
            if (idx > 0) "," else "",
            ref.hash,
            ref.path,
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
    git.push(allocator, registry_path) catch {
        sp4.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp4.succeed();

    try stdout.print("{s}{s}{s}✓{s} Registered bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Prompts: {d}\n\n", .{ P, prompt_refs.items.len });
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

    try stdout.print("{s}{s}{s}Prompts ({d}):{s}\n", .{ P, Color.bold, Color.orange, prompts_arr.array.items.len, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}HASH{s}          {s}PATH{s}\n", .{ P, Color.orange, Color.reset, Color.orange, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (prompts_arr.array.items) |ref| {
        const hash = if (ref.object.get("hash")) |h| h.string else "-";
        const path = if (ref.object.get("path")) |p| p.string else "-";
        const short_hash = if (hash.len >= 8) hash[0..8] else hash;
        try stdout.print("{s}  {s}{s}{s}      {s}\n", .{ P, Color.cyan, short_hash, Color.reset, path });
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
    git.push(allocator, registry_path) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Removed locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Removed bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, name });
    try stdout.print("{s}{s}Note: Prompts are kept in registry (may be used by other bundles){s}\n\n", .{ P, Color.dim, Color.reset });
}

fn runUpdate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse: <name> [--add|--rm <files...>] [-t <task>] [-d <desc>]
    if (args.len < 2) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add|--rm <files>] [-t <task>] [-d <desc>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];
    var is_add = false;
    var is_rm = false;
    var new_task: ?[]const u8 = null;
    var new_desc: ?[]const u8 = null;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--add") or std.mem.eql(u8, arg, "-a")) {
            is_add = true;
        } else if (std.mem.eql(u8, arg, "--rm") or std.mem.eql(u8, arg, "-r")) {
            is_rm = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--task")) {
            if (i + 1 < args.len) {
                i += 1;
                new_task = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--desc")) {
            if (i + 1 < args.len) {
                i += 1;
                new_desc = args[i];
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        }
    }

    // Must have either file operation or metadata update
    const has_file_op = (is_add or is_rm) and files.items.len > 0;
    const has_metadata_update = new_task != null or new_desc != null;

    if (!has_file_op and !has_metadata_update) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify --add/--rm with files, or -t/-d to update metadata\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> [--add|--rm <files>] [-t <task>] [-d <desc>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if ((is_add or is_rm) and files.items.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} --add/--rm requires at least one file\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    // Read current bundle
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

    // Find target bundle
    var found_bundle: ?std.json.Value = null;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, bundle_name)) {
            found_bundle = item;
            break;
        }
    }

    if (found_bundle == null) {
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

    // Collect current prompt refs
    var current_refs: std.ArrayListUnmanaged(PromptRef) = .{};
    defer {
        for (current_refs.items) |ref| {
            allocator.free(ref.hash);
            allocator.free(ref.path);
            allocator.free(ref.name);
            allocator.free(ref.description);
            allocator.free(ref.format);
        }
        current_refs.deinit(allocator);
    }

    if (found_bundle.?.object.get("prompts")) |prompts_arr| {
        for (prompts_arr.array.items) |ref| {
            const hash = if (ref.object.get("hash")) |h| h.string else continue;
            const path = if (ref.object.get("path")) |p| p.string else continue;
            // Extract format from path extension
            const ext_idx = std.mem.lastIndexOf(u8, path, ".");
            const fmt = if (ext_idx) |idx| path[idx + 1 ..] else "md";
            try current_refs.append(allocator, .{
                .hash = try allocator.dupe(u8, hash),
                .path = try allocator.dupe(u8, path),
                .name = try allocator.dupe(u8, "-"),
                .description = try allocator.dupe(u8, "-"),
                .format = try allocator.dupe(u8, fmt),
            });
        }
    }

    if (has_file_op) {
        if (is_add) {
            var sp = spinner.init(stdout, "Adding prompts");
            sp.start();

            for (files.items) |file_path| {
                const src = if (std.fs.path.isAbsolute(file_path))
                    try allocator.dupe(u8, file_path)
                else
                    try std.fs.path.join(allocator, &.{ cwd, file_path });
                defer allocator.free(src);

                // Extract format from extension
                const basename = std.fs.path.basename(file_path);
                const ext_idx = std.mem.lastIndexOf(u8, basename, ".");
                if (ext_idx == null) continue; // Skip files without extension
                const format = try allocator.dupe(u8, basename[ext_idx.? + 1 ..]);
                const name_end = ext_idx.?;

                // Read file content for hash and frontmatter
                const prompt_file = fs.openFileAbsolute(src, .{}) catch continue;
                const prompt_content = prompt_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
                    prompt_file.close();
                    continue;
                };
                prompt_file.close();
                defer allocator.free(prompt_content);

                // Compute hash
                var hash_bytes: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(prompt_content, &hash_bytes, .{});
                var hash_hex: [64]u8 = undefined;
                for (hash_bytes, 0..) |byte, idx| {
                    const hex_chars = "0123456789abcdef";
                    hash_hex[idx * 2] = hex_chars[byte >> 4];
                    hash_hex[idx * 2 + 1] = hex_chars[byte & 0x0f];
                }
                const hash = try allocator.dupe(u8, &hash_hex);

                // Parse frontmatter
                const fm = parseFrontmatter(prompt_content);
                const raw_name = basename[0..name_end];
                // Strip sequence prefix (NN_) if present
                const name = try allocator.dupe(u8, fm.name orelse stripSequencePrefix(raw_name));
                const description = try allocator.dupe(u8, fm.description orelse "-");

                // Copy to prompts/<hash> (pure hash, no extension)
                const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
                defer allocator.free(dest_path);
                fs.copyFileAbsolute(src, dest_path, .{}) catch {};

                // Extract path: frontmatter category > file path detection > default
                const prompt_path = if (fm.category) |cat|
                    cat
                else if (std.mem.indexOf(u8, file_path, "conduct") != null)
                    "conduct"
                else if (std.mem.indexOf(u8, file_path, "command") != null)
                    "command"
                else
                    "conduct"; // default to conduct

                try current_refs.append(allocator, .{
                    .hash = hash,
                    .path = try allocator.dupe(u8, prompt_path),
                    .name = name,
                    .description = description,
                    .format = format,
                });
            }
            sp.succeed();
        } else if (is_rm) {
            var sp = spinner.init(stdout, "Removing prompts");
            sp.start();

            // Remove refs matching the given hash prefixes
            var new_refs: std.ArrayListUnmanaged(PromptRef) = .{};
            defer new_refs.deinit(allocator);

            for (current_refs.items) |ref| {
                var should_remove = false;
                for (files.items) |hash_prefix| {
                    // Match by hash prefix
                    if (std.mem.startsWith(u8, ref.hash, hash_prefix)) {
                        should_remove = true;
                        break;
                    }
                }
                if (!should_remove) {
                    try new_refs.append(allocator, .{
                        .hash = try allocator.dupe(u8, ref.hash),
                        .path = try allocator.dupe(u8, ref.path),
                        .name = try allocator.dupe(u8, ref.name),
                        .description = try allocator.dupe(u8, ref.description),
                        .format = try allocator.dupe(u8, ref.format),
                    });
                }
            }

            // Swap
            for (current_refs.items) |ref| {
                allocator.free(ref.hash);
                allocator.free(ref.path);
                allocator.free(ref.name);
                allocator.free(ref.description);
                allocator.free(ref.format);
            }
            current_refs.clearRetainingCapacity();
            for (new_refs.items) |ref| {
                try current_refs.append(allocator, ref);
            }
            new_refs.clearRetainingCapacity();

            sp.succeed();
        }
    }

    // Rebuild index
    var sp2 = spinner.init(stdout, "Updating bundle");
    sp2.start();

    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);
    try new_index.appendSlice(allocator, "{\n  \"bundles\": [");

    var first = true;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        if (std.mem.eql(u8, item_name, bundle_name)) {
            // Write updated bundle (use new values if provided)
            const item_task = new_task orelse (if (item.object.get("task")) |t| t.string else "-");
            const item_desc = new_desc orelse (if (item.object.get("description")) |d| d.string else "-");
            const item_created = if (item.object.get("created_at")) |c| c.string else "0";
            const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

            const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{ item_name, item_task, item_desc, item_created, item_meta });
            defer allocator.free(entry_start);
            try new_index.appendSlice(allocator, entry_start);

            for (current_refs.items, 0..) |ref, idx| {
                const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"path\": \"{s}\" }}", .{
                    if (idx > 0) "," else "",
                    ref.hash,
                    ref.path,
                });
                defer allocator.free(ref_entry);
                try new_index.appendSlice(allocator, ref_entry);
            }
            try new_index.appendSlice(allocator, "\n      ]\n    }");
        } else {
            try appendBundleEntry(allocator, &new_index, item);
        }
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        sp2.fail();
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {};
    sp2.succeed();

    // Commit and push
    var sp3 = spinner.init(stdout, "Pushing to registry");
    sp3.start();
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Update bundle") catch {};
    git.push(allocator, registry_path) catch {
        sp3.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp3.succeed();

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Prompts: {d}\n\n", .{ P, current_refs.items.len });
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
            // Strip sequence prefix (NN_) if present
            const name = try allocator.dupe(u8, fm.name orelse stripSequencePrefix(raw_name));
            const description = try allocator.dupe(u8, fm.description orelse "-");
            // Use frontmatter category if available, otherwise use base_name from directory
            const prompt_path = fm.category orelse base_name;

            // Copy to prompts/<hash> (pure hash, no extension)
            const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash });
            defer allocator.free(dest_path);
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch {};

            // Add reference (path is just the directory: conduct or command)
            try refs.append(allocator, .{
                .hash = hash,
                .path = try allocator.dupe(u8, prompt_path),
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

    // Track hashes to avoid duplicates
    var seen_hashes = std.StringHashMap(void).init(allocator);
    defer seen_hashes.deinit();

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
                    const item_path = if (item.object.get("path")) |p| p.string else "conduct";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    seen_hashes.put(item_hash, {}) catch {};

                    const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"path\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{
                        if (first) "" else ",",
                        item_hash,
                        item_name,
                        item_desc,
                        item_format,
                        item_path,
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

        const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"path\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}", .{
            if (first) "" else ",",
            ref.hash,
            ref.name,
            ref.description,
            ref.format,
            ref.path,
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
            const path = if (ref.object.get("path")) |p| p.string else continue;
            const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\", \"path\": \"{s}\" }}", .{
                if (idx > 0) "," else "",
                hash,
                path,
            });
            defer allocator.free(ref_entry);
            try buf.appendSlice(allocator, ref_entry);
        }
    }
    try buf.appendSlice(allocator, "\n      ]\n    }");
}

// Find and upload meta-prompt file (CLAUDE.md, etc.) to registry
// If explicit_file is provided, use that file directly
// Otherwise, check config for meta_prompt_file, then fall back to default search
// Returns the hash of the uploaded file, or null if not found
fn findAndUploadMetaPrompt(allocator: std.mem.Allocator, cwd: []const u8, registry_path: []const u8, explicit_file: ?[]const u8) !?[]const u8 {
    const meta_prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts" });
    defer allocator.free(meta_prompts_dir);
    fs.cwd().makePath(meta_prompts_dir) catch {};

    // Determine which file(s) to try
    var files_to_try: [4][]const u8 = .{ "", "", "", "" };
    var files_count: usize = 0;

    if (explicit_file) |ef| {
        // Use explicit file from -M flag
        files_to_try[0] = ef;
        files_count = 1;
    } else if (config.getMetaPromptFile(allocator) catch null) |cf| {
        // Use config file
        defer allocator.free(cf);
        files_to_try[0] = cf;
        files_count = 1;
    } else {
        // Fall back to default search order
        const default_files = [_][]const u8{ "CLAUDE.md", "CURSOR.md", "AGENTS.md", "COPILOT.md" };
        for (default_files, 0..) |f, i| {
            files_to_try[i] = f;
        }
        files_count = 4;
    }

    for (files_to_try[0..files_count]) |filename| {
        if (filename.len == 0) continue;

        const file_path = try std.fs.path.join(allocator, &.{ cwd, filename });
        defer allocator.free(file_path);

        const file = fs.openFileAbsolute(file_path, .{}) catch continue;
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

        // Copy to meta-prompts/<hash> (pure hash, no extension)
        const dest_path = try std.fs.path.join(allocator, &.{ meta_prompts_dir, hash });
        defer allocator.free(dest_path);
        fs.copyFileAbsolute(file_path, dest_path, .{}) catch {};

        return hash;
    }

    return null;
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
