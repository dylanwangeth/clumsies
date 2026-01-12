const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

const UpdateOp = enum {
    add,
    rm,
    none,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var is_bundle = false;
    var bundle_name: ?[]const u8 = null;
    var operation: UpdateOp = .none;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            is_bundle = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            operation = .add;
        } else if (std.mem.eql(u8, arg, "--rm")) {
            operation = .rm;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (bundle_name == null) {
                bundle_name = arg;
            } else {
                try files.append(allocator, arg);
            }
        }
    }

    if (!is_bundle) {
        try stderr.print("\n{s}{s}{s}Error:{s} Update only supports bundles (-B)\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies update -B <name> --add <files...>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies update -B <name> --rm <files...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (bundle_name == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies update -B <name> --add <files...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (operation == .none) {
        try stderr.print("\n{s}{s}{s}Error:{s} Specify --add or --rm operation\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies update -B <name> --add <files...>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies update -B <name> --rm <files...>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (files.items.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} At least one file or directory required\n", .{ P, Color.bold, Color.red, Color.reset });
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
        var sp = spinner.init(stdout, "Updating registry");
        sp.start();
        git.pull(allocator, registry_path) catch {};
        sp.succeed();
    }

    // Check bundle exists
    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", bundle_name.? });
    defer allocator.free(bundle_dir);

    const bundle_exists = blk: {
        var dir = fs.openDirAbsolute(bundle_dir, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!bundle_exists) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name.? });
        try stderr.print("{s}Use {s}clumsies create -B {s} <dirs...>{s} to create it first\n\n", .{ P, Color.cyan, bundle_name.?, Color.reset });
        return;
    }

    if (operation == .add) {
        try addToBundle(stdout, stderr, allocator, registry_path, bundle_dir, bundle_name.?, files.items);
    } else {
        try removeFromBundle(stdout, stderr, allocator, registry_path, bundle_dir, bundle_name.?, files.items);
    }
}

fn addToBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, bundle_dir: []const u8, bundle_name: []const u8, items: []const []const u8) !void {
    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    var sp = spinner.init(stdout, "Adding files");
    sp.start();

    var added_count: usize = 0;
    for (items) |item| {
        const src_path = if (std.fs.path.isAbsolute(item))
            try allocator.dupe(u8, item)
        else
            try std.fs.path.join(allocator, &.{ cwd, item });
        defer allocator.free(src_path);

        const dest_path = try std.fs.path.join(allocator, &.{ bundle_dir, std.fs.path.basename(item) });
        defer allocator.free(dest_path);

        // Try as directory first
        if (copyDirRecursive(allocator, src_path, dest_path)) {
            added_count += 1;
        } else |_| {
            // Try as file
            fs.copyFileAbsolute(src_path, dest_path, .{}) catch continue;
            added_count += 1;
        }
    }
    sp.succeed();

    if (added_count == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No files were added\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Commit and push
    var sp2 = spinner.init(stdout, "Pushing to registry");
    sp2.start();

    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Update bundle: add files") catch {};
    git.push(allocator, registry_path) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp2.succeed();

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Added: {d} item(s)\n\n", .{ P, added_count });
}

fn removeFromBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, registry_path: []const u8, bundle_dir: []const u8, bundle_name: []const u8, items: []const []const u8) !void {
    var sp = spinner.init(stdout, "Removing files");
    sp.start();

    var removed_count: usize = 0;
    for (items) |item| {
        const target_path = try std.fs.path.join(allocator, &.{ bundle_dir, item });
        defer allocator.free(target_path);

        // Try as directory first
        fs.deleteTreeAbsolute(target_path) catch {
            // Try as file
            fs.deleteFileAbsolute(target_path) catch continue;
        };
        removed_count += 1;
    }
    sp.succeed();

    if (removed_count == 0) {
        try stderr.print("{s}{s}{s}Error:{s} No files were removed\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    // Commit and push
    var sp2 = spinner.init(stdout, "Pushing to registry");
    sp2.start();

    git.addAll(allocator, registry_path) catch {};
    git.commit(allocator, registry_path, "Update bundle: remove files") catch {};
    git.push(allocator, registry_path) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Warning:{s} Saved locally but failed to push to remote\n", .{ P, Color.bold, Color.orange, Color.reset });
    };
    sp2.succeed();

    try stdout.print("{s}{s}{s}✓{s} Updated bundle: {s}\n", .{ P, Color.bold, Color.green, Color.reset, bundle_name });
    try stdout.print("{s}  Removed: {d} item(s)\n\n", .{ P, removed_count });
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
