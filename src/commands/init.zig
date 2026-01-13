const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse args: init [-B <bundle>] [url]
    var is_bundle = false;
    var bundle_name: ?[]const u8 = null;
    var remote_url: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            is_bundle = true;
            // Next arg is bundle name
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                i += 1;
                bundle_name = args[i];
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            // Non-flag arg: could be bundle name (if -B without value) or URL
            if (is_bundle and bundle_name == null) {
                bundle_name = arg;
            } else {
                remote_url = arg;
            }
        }
    }

    // Check current state
    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Could not determine .prompts/ path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    const prompts_exists = commands.promptsExist();

    const git_path = std.fs.path.join(allocator, &.{ prompts_path, ".git" }) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Memory allocation failed\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(git_path);

    const git_exists = blk: {
        var dir = fs.openDirAbsolute(git_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    const has_remote = blk: {
        if (!git_exists) break :blk false;
        _ = git.getRemoteUrl(allocator, prompts_path) catch break :blk false;
        break :blk true;
    };

    try stdout.writeAll("\n");

    // Handle bundle mode
    if (is_bundle) {
        if (bundle_name == null) {
            try stderr.print("{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Usage: {s}clumsies init -B <bundle> [git-url]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }

        if (prompts_exists) {
            try stderr.print("{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Cannot initialize from bundle when .prompts/ exists\n\n", .{P});
            return;
        }

        try initFromBundle(stdout, stderr, allocator, prompts_path, bundle_name.?, remote_url);
        return;
    }

    // Regular init mode - need URL
    if (remote_url == null) {
        if (!prompts_exists) {
            try stderr.print("{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Usage: {s}clumsies init <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
            try stderr.print("{s}       {s}clumsies init -B <bundle> [git-url]{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else if (!git_exists) {
            try stderr.print("{s}{s}{s}Error:{s} Remote URL required to initialize git\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Usage: {s}clumsies init <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else if (has_remote) {
            try stderr.print("{s}{s}{s}Error:{s} .prompts/ already has a remote configured\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Use {s}clumsies status{s} to check current state\n\n", .{ P, Color.cyan, Color.reset });
            return;
        } else {
            try stderr.print("{s}{s}{s}Error:{s} Remote URL required to add remote\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Usage: {s}clumsies init <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
            return;
        }
    }

    // State machine for init
    if (!prompts_exists) {
        // Create .prompts/
        fs.cwd().makeDir(".prompts") catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n\n", .{ P, Color.bold, Color.red, Color.reset, err });
            return;
        };

        // Create default directories
        const conduct_path = try std.fs.path.join(allocator, &.{ prompts_path, "conduct" });
        defer allocator.free(conduct_path);
        const command_path = try std.fs.path.join(allocator, &.{ prompts_path, "command" });
        defer allocator.free(command_path);

        fs.cwd().makePath(conduct_path) catch {};
        fs.cwd().makePath(command_path) catch {};

        // Create .gitkeep files
        const conduct_keep = try std.fs.path.join(allocator, &.{ conduct_path, ".gitkeep" });
        defer allocator.free(conduct_keep);
        const command_keep = try std.fs.path.join(allocator, &.{ command_path, ".gitkeep" });
        defer allocator.free(command_keep);

        if (fs.createFileAbsolute(conduct_keep, .{})) |f| f.close() else |_| {}
        if (fs.createFileAbsolute(command_keep, .{})) |f| f.close() else |_| {}

        try stdout.print("{s}{s}✓{s} Created .prompts/\n", .{ P, Color.green, Color.reset });
    }

    if (!git_exists) {
        // Initialize git
        git.init(allocator, prompts_path) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to initialize git repository\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}✓{s} Initialized git repository\n", .{ P, Color.green, Color.reset });
    }

    if (!has_remote) {
        // Add remote
        git.addRemote(allocator, prompts_path, remote_url.?) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}✓{s} Added remote: {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.cyan, remote_url.?, Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} Remote already configured\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    }

    try stdout.writeAll("\n");
}

fn initFromBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, prompts_path: []const u8, bundle_name: []const u8, remote_url: ?[]const u8) !void {
    // Get registry URL from config
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(registry_url);

    // Get registry path
    const base_path = commands.getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });
    defer allocator.free(registry_path);

    // Ensure registry is cloned or pull latest
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

    // Check if bundle exists
    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", bundle_name });
    defer allocator.free(bundle_dir);

    const bundle_exists = blk: {
        var dir = fs.openDirAbsolute(bundle_dir, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!bundle_exists) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Run {s}clumsies list -B{s} to see available bundles\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Create .prompts directory
    fs.cwd().makeDir(".prompts") catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    // Copy bundle contents to .prompts/
    var sp = spinner.init(stdout, "Copying bundle");
    sp.start();

    copyDirRecursive(allocator, bundle_dir, prompts_path) catch {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to copy bundle contents\n\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(prompts_path) catch {};
        return;
    };
    sp.succeed();

    try stdout.print("{s}{s}✓{s} Created .prompts/ from bundle: {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.cyan, bundle_name, Color.reset });

    // If URL provided, also init git and add remote
    if (remote_url) |url| {
        git.init(allocator, prompts_path) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to initialize git repository\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}✓{s} Initialized git repository\n", .{ P, Color.green, Color.reset });

        git.addRemote(allocator, prompts_path, url) catch {
            try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return;
        };
        try stdout.print("{s}{s}✓{s} Added remote: {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.cyan, url, Color.reset });
    }

    try stdout.writeAll("\n");
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
