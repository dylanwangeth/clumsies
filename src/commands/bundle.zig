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
    create,
    show,
    rm,
    update,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showUsage(stderr);
        return;
    }

    var subcmd: SubCommand = .none;
    const subcmd_args_start: usize = 1;

    if (std.mem.eql(u8, args[0], "list")) {
        subcmd = .list;
    } else if (std.mem.eql(u8, args[0], "create")) {
        subcmd = .create;
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
        .create => try runCreate(stdout, stderr, allocator, subcmd_args),
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
    try stderr.print("{s}  {s}list{s}                           List bundles in registry\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}create{s} <name> <dirs> [-t] [-d]  Create bundle\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}show{s} <name>                     Show bundle content\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}rm{s} <name>                       Remove bundle\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}update{s} <name> --add|--rm        Update bundle\n\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}Options:\n", .{P});
    try stderr.print("{s}  {s}-t, --task{s} <task>    Task type (coding, research, learning, etc.)\n", .{ P, Color.cyan, Color.reset });
    try stderr.print("{s}  {s}-d, --desc{s} <desc>    Description\n\n", .{ P, Color.cyan, Color.reset });
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

fn runList(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    try stdout.writeAll("\n");

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

    try stdout.print("{s}{s}Bundles in registry:{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});
    try stdout.print("{s}  {s}NAME{s}                 {s}TASK{s}      {s}CREATED{s}     {s}DESCRIPTION{s}\n", .{ P, Color.dim, Color.reset, Color.dim, Color.reset, Color.dim, Color.reset, Color.dim, Color.reset });
    try stdout.print("{s}────────────────────────────────────────────────────────────────────────────\n", .{P});

    for (items.array.items) |item| {
        const name = if (item.object.get("name")) |n| n.string else continue;
        const item_task = if (item.object.get("task")) |t| t.string else "-";
        const desc = if (item.object.get("description")) |d| d.string else "-";
        const created_str = if (item.object.get("created_at")) |c| c.string else "0";

        const created_ts = std.fmt.parseInt(i64, created_str, 10) catch 0;
        var date_buf: [10]u8 = undefined;
        const date_str = commands.formatDate(created_ts, &date_buf);

        try stdout.print("{s}  {s}{s: <20}{s}  {s: <8}  {s}  {s}\n", .{ P, Color.cyan, name, Color.reset, item_task, date_str, desc });
    }
    try stdout.writeAll("\n");
}

fn runCreate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse args: <name> <dirs...> [-d <desc>] [-t <task>]
    var description: []const u8 = "-";
    var task: []const u8 = "-";
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
        } else if (arg.len > 0 and arg[0] != '-') {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len < 2) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle requires name and at least one directory\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle create <name> <dir1> [dir2...] [-d <desc>]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    try stdout.writeAll("\n");

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const bundle_name = positional.items[0];
    const dirs = positional.items[1..];

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    // Create bundles directory
    const bundles_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles" });
    defer allocator.free(bundles_dir);
    fs.cwd().makePath(bundles_dir) catch {};

    // Create bundle directory
    const bundle_dir = try std.fs.path.join(allocator, &.{ bundles_dir, bundle_name });
    defer allocator.free(bundle_dir);

    // Check if exists
    const bundle_exists = blk: {
        var dir = fs.openDirAbsolute(bundle_dir, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };
    if (bundle_exists) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle already exists: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Use {s}clumsies bundle rm {s}{s} to remove it first\n\n", .{ P, Color.cyan, bundle_name, Color.reset });
        return;
    }

    fs.cwd().makePath(bundle_dir) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create bundle directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Copy directories
    var sp = spinner.init(stdout, "Copying files");
    sp.start();

    var copied_count: usize = 0;
    for (dirs) |dir_name| {
        const src_path = if (std.fs.path.isAbsolute(dir_name))
            try allocator.dupe(u8, dir_name)
        else
            try std.fs.path.join(allocator, &.{ cwd, dir_name });
        defer allocator.free(src_path);

        const dest_subdir = try std.fs.path.join(allocator, &.{ bundle_dir, std.fs.path.basename(dir_name) });
        defer allocator.free(dest_subdir);

        if (copyDirRecursive(allocator, src_path, dest_subdir)) {
            copied_count += 1;
        } else |_| {
            const dest_file = try std.fs.path.join(allocator, &.{ bundle_dir, std.fs.path.basename(dir_name) });
            defer allocator.free(dest_file);
            fs.copyFileAbsolute(src_path, dest_file, .{}) catch continue;
            copied_count += 1;
        }
    }

    if (copied_count == 0) {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} No files were copied\n\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(bundle_dir) catch {};
        return;
    }
    sp.succeed();

    // Compute hash
    var hash_sp = spinner.init(stdout, "Computing hash");
    hash_sp.start();
    const bundle_hash = computeBundleHash(allocator, bundle_dir) catch {
        hash_sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to compute bundle hash\n\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(bundle_dir) catch {};
        return;
    };
    defer allocator.free(bundle_hash);
    hash_sp.succeed();

    // Update index.json
    const index_path = try std.fs.path.join(allocator, &.{ bundles_dir, "index.json" });
    defer allocator.free(index_path);

    var existing_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer existing_bundles.deinit(allocator);

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            idx_file.close();
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
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_task = if (item.object.get("task")) |t| t.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_task, item_desc, item_created });
                    defer allocator.free(entry);
                    try existing_bundles.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    }

    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_bundles.items.len > 22) "," else "",
        bundle_hash,
        bundle_name,
        task,
        description,
        timestamp,
    });
    defer allocator.free(new_entry);
    try existing_bundles.appendSlice(allocator, new_entry);

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_bundles.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    var sp2 = spinner.init(stdout, "Creating in registry");
    sp2.start();
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Add bundle") catch {};
    git.push(allocator, registry_path) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp2.succeed();

    try stdout.print("{s}{s}{s}✓{s} Created bundle in registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, bundle_hash, Color.reset });
    try stdout.print("{s}  Name: {s}\n\n", .{ P, bundle_name });
}

fn runShow(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle show <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    try stdout.writeAll("\n");

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
    var found_name: ?[]const u8 = null;
    var found_desc: ?[]const u8 = null;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        if (std.mem.eql(u8, item_name, name)) {
            found_name = item_name;
            found_desc = if (item.object.get("description")) |d| d.string else null;
            break;
        }
    }

    if (found_name == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name });
        return;
    }

    try stdout.print("{s}{s}Bundle:{s} {s}\n", .{ P, Color.bold, Color.reset, found_name.? });
    if (found_desc) |d| {
        try stdout.print("{s}{s}Description:{s} {s}\n\n", .{ P, Color.dim, Color.reset, d });
    }

    // List bundle contents
    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", found_name.? });
    defer allocator.free(bundle_dir);

    try stdout.print("{s}{s}Contents:{s}\n", .{ P, Color.bold, Color.reset });
    try listDirRecursive(stdout, allocator, bundle_dir, 0);
    try stdout.writeAll("\n");
}

fn runRm(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle rm <name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    try stdout.writeAll("\n");

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

    // Find and remove bundle by name
    var found = false;
    var new_bundles: std.ArrayListUnmanaged(u8) = .{};
    defer new_bundles.deinit(allocator);

    try new_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    var first = true;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        const item_hash = if (item.object.get("hash")) |h| h.string else "-";

        if (std.mem.eql(u8, item_name, name)) {
            found = true;
            continue;
        }

        const item_task = if (item.object.get("task")) |t| t.string else "-";
        const item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (!first) try new_bundles.appendSlice(allocator, ",");
        first = false;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_task, item_desc, item_created });
        defer allocator.free(entry);
        try new_bundles.appendSlice(allocator, entry);
    }
    try new_bundles.appendSlice(allocator, "\n  ]\n}\n");

    if (!found) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, name });
        return;
    }

    // Delete bundle directory
    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", name });
    defer allocator.free(bundle_dir);
    fs.deleteTreeAbsolute(bundle_dir) catch {};

    // Write updated index
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

    try stdout.print("{s}{s}{s}✓{s} Removed bundle: {s}\n\n", .{ P, Color.bold, Color.green, Color.reset, name });
}

fn runUpdate(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse: <name> --add|--rm <files...>
    if (args.len < 3) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name and files required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> --add|--rm <files...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];
    var is_add = false;
    var is_rm = false;
    var files_start: usize = 2;

    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--add") or std.mem.eql(u8, arg, "-a")) {
            is_add = true;
            files_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "--rm") or std.mem.eql(u8, arg, "-r")) {
            is_rm = true;
            files_start = i + 1;
            break;
        }
    }

    if (!is_add and !is_rm) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify --add or --rm\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies bundle update <name> --add|--rm <files...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const files = args[files_start..];
    if (files.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} At least one file required\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    try stdout.writeAll("\n");

    const registry_path = ensureRegistry(stdout, stderr, allocator) catch return;
    defer allocator.free(registry_path);

    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", bundle_name });
    defer allocator.free(bundle_dir);

    // Check bundle exists
    {
        var dir = fs.openDirAbsolute(bundle_dir, .{}) catch {
            try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
            return;
        };
        dir.close();
    }

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    if (is_add) {
        var sp = spinner.init(stdout, "Adding files");
        sp.start();
        var added: usize = 0;
        for (files) |file_name| {
            const src = if (std.fs.path.isAbsolute(file_name))
                try allocator.dupe(u8, file_name)
            else
                try std.fs.path.join(allocator, &.{ cwd, file_name });
            defer allocator.free(src);

            const dest = try std.fs.path.join(allocator, &.{ bundle_dir, std.fs.path.basename(file_name) });
            defer allocator.free(dest);

            if (copyDirRecursive(allocator, src, dest)) {
                added += 1;
            } else |_| {
                fs.copyFileAbsolute(src, dest, .{}) catch continue;
                added += 1;
            }
        }
        if (added == 0) {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} No files were added\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        }
        sp.succeed();
    } else {
        var sp = spinner.init(stdout, "Removing files");
        sp.start();
        for (files) |file_name| {
            const path = try std.fs.path.join(allocator, &.{ bundle_dir, file_name });
            defer allocator.free(path);
            fs.deleteTreeAbsolute(path) catch {};
        }
        sp.succeed();
    }

    // Recompute hash
    var hash_sp = spinner.init(stdout, "Computing hash");
    hash_sp.start();
    const new_hash = computeBundleHash(allocator, bundle_dir) catch {
        hash_sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to compute hash\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(new_hash);
    hash_sp.succeed();

    // Update index with new hash
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        idx_file.close();
        return;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch return;
    defer parsed.deinit();

    var new_index: std.ArrayListUnmanaged(u8) = .{};
    defer new_index.deinit(allocator);
    try new_index.appendSlice(allocator, "{\n  \"bundles\": [");

    const bundles = parsed.value.object.get("bundles") orelse return;
    var first = true;
    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;
        const item_task = if (item.object.get("task")) |t| t.string else "-";
        const item_desc = if (item.object.get("description")) |d| d.string else "-";
        const item_created = if (item.object.get("created_at")) |c| c.string else "0";

        if (!first) try new_index.appendSlice(allocator, ",");
        first = false;

        const hash_to_use = if (std.mem.eql(u8, item_name, bundle_name)) new_hash else if (item.object.get("hash")) |h| h.string else continue;

        const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ hash_to_use, item_name, item_task, item_desc, item_created });
        defer allocator.free(entry);
        try new_index.appendSlice(allocator, entry);
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch return;
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch {};

    // Commit and push
    var sp2 = spinner.init(stdout, "Updating registry");
    sp2.start();
    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Update bundle") catch {};
    git.push(allocator, registry_path) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Updated locally but failed to push\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp2.succeed();

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Hash: {s}{s}{s}\n\n", .{ P, Color.cyan, new_hash, Color.reset });
}

fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    fs.cwd().makePath(dest) catch return error.Failed;
    var src_dir = fs.openDirAbsolute(src, .{ .iterate = true }) catch return error.Failed;
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (iter.next() catch return error.Failed) |entry| {
        const src_path = std.fs.path.join(allocator, &.{ src, entry.name }) catch continue;
        defer allocator.free(src_path);
        const dest_path = std.fs.path.join(allocator, &.{ dest, entry.name }) catch continue;
        defer allocator.free(dest_path);

        if (entry.kind == .directory) {
            try copyDirRecursive(allocator, src_path, dest_path);
        } else if (entry.kind == .file) {
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch continue;
        }
    }
}

fn computeBundleHash(allocator: std.mem.Allocator, bundle_dir: []const u8) ![]const u8 {
    var file_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (file_paths.items) |p| allocator.free(p);
        file_paths.deinit(allocator);
    }

    try collectFilePaths(allocator, bundle_dir, bundle_dir, &file_paths);

    std.mem.sort([]const u8, file_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (file_paths.items) |rel_path| {
        const full_path = try std.fs.path.join(allocator, &.{ bundle_dir, rel_path });
        defer allocator.free(full_path);

        const file = fs.openFileAbsolute(full_path, .{}) catch continue;
        defer file.close();

        hasher.update(rel_path);
        hasher.update("\x00");

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch break;
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
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

fn collectFilePaths(allocator: std.mem.Allocator, base_dir: []const u8, current_dir: []const u8, paths: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = fs.openDirAbsolute(current_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try collectFilePaths(allocator, base_dir, full_path, paths);
        } else if (entry.kind == .file) {
            const rel_path = try allocator.dupe(u8, full_path[base_dir.len + 1 ..]);
            try paths.append(allocator, rel_path);
        }
    }
}

fn listDirRecursive(stdout: anytype, allocator: std.mem.Allocator, dir_path: []const u8, depth: usize) !void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        var indent_buf: [64]u8 = undefined;
        const indent_len = @min(depth * 2, 62);
        @memset(indent_buf[0..indent_len], ' ');

        if (entry.kind == .directory) {
            try stdout.print("{s}  {s}{s}/{s}\n", .{ P, indent_buf[0..indent_len], entry.name, Color.reset });
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(subdir);
            try listDirRecursive(stdout, allocator, subdir, depth + 1);
        } else {
            try stdout.print("{s}  {s}{s}\n", .{ P, indent_buf[0..indent_len], entry.name });
        }
    }
}
