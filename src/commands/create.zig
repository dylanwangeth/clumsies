const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const CreateType = enum {
    prompt,
    bundle,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse -P or -B flag and file paths
    var create_type: CreateType = .none;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--prompt")) {
            create_type = .prompt;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            create_type = .bundle;
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        }
    }

    if (create_type == .none) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify -P (prompt) or -B (bundle)\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies create -P <file>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies create -B <name> <dirs...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (files.items.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} File or directory required\n", .{ P, Color.bold, Color.red, Color.reset });
        if (create_type == .prompt) {
            try stderr.print("{s}Usage: {s}clumsies create -P <file.md>{s}\n\n", .{ P, Color.cyan, Color.reset });
        } else {
            try stderr.print("{s}Usage: {s}clumsies create -B <name> <dirs...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        }
        return;
    }

    // Get registry URL from config
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(registry_url);

    try stdout.writeAll("\n");

    // Get registry cache path
    const base_path = commands.getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });
    defer allocator.free(registry_path);

    // Ensure registry is cloned
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
        // Pull latest
        var sp = spinner.init(stdout, "Updating registry");
        sp.start();
        git.pull(allocator, registry_path) catch {};
        sp.succeed();
    }

    if (create_type == .prompt) {
        try createPrompt(stdout, stderr, allocator, registry_path, files.items[0]);
    } else {
        try createBundle(stdout, stderr, allocator, registry_path, files.items);
    }
}

fn createPrompt(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, file_path: []const u8) !void {
    // Read the file
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const abs_path = if (std.fs.path.isAbsolute(file_path))
        try allocator.dupe(u8, file_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, file_path });
    defer allocator.free(abs_path);

    const file = fs.openFileAbsolute(abs_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not open file: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, file_path });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to read file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(content);

    // Compute SHA-256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hash_hex[i * 2] = hex_chars[byte >> 4];
        hash_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    // Extract name from filename (without path and extension)
    const basename = std.fs.path.basename(file_path);
    const name_end = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
    const name = basename[0..name_end];

    // Create prompts directory if needed
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    // Copy file to registry with hash name
    const hash_filename = try std.fmt.allocPrint(allocator, "{s}.md", .{hash_hex});
    defer allocator.free(hash_filename);

    const dest_path = try std.fs.path.join(allocator, &.{ prompts_dir, hash_filename });
    defer allocator.free(dest_path);

    // Check if already exists
    if (fs.openFileAbsolute(dest_path, .{})) |existing| {
        existing.close();
        try stdout.print("{s}{s}{s}!{s} Prompt already exists in registry\n", .{ P, Color.bold, Color.orange, Color.reset });
        try stdout.print("{s}  Hash: {s}{s}{s}\n\n", .{ P, Color.cyan, hash_hex, Color.reset });
        return;
    } else |_| {}

    // Write content to registry
    const dest_file = fs.createFileAbsolute(dest_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create file in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer dest_file.close();
    dest_file.writeAll(content) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Update index.json
    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    // Read existing index or create new
    var existing_prompts: std.ArrayListUnmanaged(u8) = .{};
    defer existing_prompts.deinit(allocator);

    if (fs.openFileAbsolute(index_path, .{})) |idx_file| {
        const idx_content = idx_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            idx_file.close();
            try stderr.print("{s}{s}{s}Error:{s} Failed to read index\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        idx_file.close();
        defer allocator.free(idx_content);

        // Parse and rebuild without the trailing ]
        if (std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
                for (prompts.array.items, 0..) |item, idx| {
                    if (idx > 0) try existing_prompts.appendSlice(allocator, ",");
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;
                    const item_name = if (item.object.get("name")) |n| n.string else "-";
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_created });
                    defer allocator.free(entry);
                    try existing_prompts.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_prompts.appendSlice(allocator, "{\n  \"prompts\": [");
    }

    // Add new entry
    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"-\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_prompts.items.len > 20) "," else "",
        hash_hex,
        name,
        timestamp,
    });
    defer allocator.free(new_entry);
    try existing_prompts.appendSlice(allocator, new_entry);

    // Write index
    const idx_out = fs.createFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer idx_out.close();
    idx_out.writeAll(existing_prompts.items) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Commit and push
    var sp = spinner.init(stdout, "Creating in registry");
    sp.start();

    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Add prompt") catch {};
    git.push(allocator, registry_path) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp.succeed();

    try stdout.print("{s}{s}{s}✓{s} Created prompt to registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Hash: {s}{s}{s}\n", .{ P, Color.cyan, hash_hex, Color.reset });
    try stdout.print("{s}  Name: {s}\n\n", .{ P, name });
}

fn createBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, args: []const []const u8) !void {
    if (args.len < 2) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle requires name and at least one directory\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies create -B <name> <dir1> [dir2...]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const bundle_name = args[0];
    const dirs = args[1..];

    // Get cwd
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    // Create bundles directory if needed
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
        try stderr.print("{s}Use {s}clumsies rm -B {s}{s} to remove it first\n\n", .{ P, Color.cyan, bundle_name, Color.reset });
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

        // Copy directory recursively
        if (copyDirRecursive(allocator, src_path, dest_subdir)) {
            copied_count += 1;
        } else |_| {
            // Try as file
            const dest_file = try std.fs.path.join(allocator, &.{ bundle_dir, std.fs.path.basename(dir_name) });
            defer allocator.free(dest_file);
            fs.copyFileAbsolute(src_path, dest_file, .{}) catch continue;
            copied_count += 1;
        }
    }
    sp.succeed();

    if (copied_count == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No files were copied\n\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(bundle_dir) catch {};
        return;
    }

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
                    const item_desc = if (item.object.get("description")) |d| d.string else "-";
                    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

                    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, item_name, item_desc, item_created });
                    defer allocator.free(entry);
                    try existing_bundles.appendSlice(allocator, entry);
                }
            }
        } else |_| {}
    } else |_| {
        try existing_bundles.appendSlice(allocator, "{\n  \"bundles\": [");
    }

    // Add new entry (use name as hash for bundles)
    const timestamp = std.time.timestamp();
    const new_entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"-\",\n      \"created_at\": \"{d}\"\n    }}\n  ]\n}}\n", .{
        if (existing_bundles.items.len > 22) "," else "",
        bundle_name,
        bundle_name,
        timestamp,
    });
    defer allocator.free(new_entry);
    try existing_bundles.appendSlice(allocator, new_entry);

    // Write index
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

    try stdout.print("{s}{s}{s}✓{s} Created bundle to registry\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Name: {s}{s}{s}\n", .{ P, Color.cyan, bundle_name, Color.reset });
    try stdout.print("{s}  Dirs: {d}\n\n", .{ P, copied_count });
}

fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    // Create destination directory
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
