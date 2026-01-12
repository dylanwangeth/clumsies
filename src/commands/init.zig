const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Check if .prompts already exists
    if (commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Use {s}clumsies status{s} to check current state\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Parse args
    var is_bundle = false;
    var arg_value: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bundle")) {
            is_bundle = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            arg_value = arg;
        }
    }

    if (is_bundle) {
        try initFromBundle(stdout, stderr, allocator, arg_value);
        return;
    }

    // Regular init with remote URL
    if (arg_value == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies init <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}       {s}clumsies init -B <bundle-name>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const remote_url = arg_value;

    // Create .prompts directory
    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

    fs.cwd().makeDir(".prompts") catch |err| {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    // Initialize git repo
    git.init(allocator, prompts_path) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to initialize git repository\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };

    // Add remote
    git.addRemote(allocator, prompts_path, remote_url.?) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to add remote\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    try stdout.print("\n{s}{s}{s}✓{s} Initialized .prompts/\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Remote: {s}{s}{s}\n\n", .{ P, Color.cyan, remote_url.?, Color.reset });
}

fn initFromBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, bundle_name: ?[]const u8) !void {
    if (bundle_name == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies init -B <bundle-name>{s}\n\n", .{ P, Color.cyan, Color.reset });
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
    const bundle_dir = try std.fs.path.join(allocator, &.{ registry_path, "bundles", bundle_name.? });
    defer allocator.free(bundle_dir);

    const bundle_exists = blk: {
        var dir = fs.openDirAbsolute(bundle_dir, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!bundle_exists) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name.? });
        try stderr.print("{s}Run {s}clumsies list -B{s} to see available bundles\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Create .prompts directory
    fs.cwd().makeDir(".prompts") catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    const prompts_path = try commands.getPromptsPath(allocator);
    defer allocator.free(prompts_path);

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

    try stdout.print("{s}{s}{s}✓{s} Initialized .prompts/ from bundle\n", .{ P, Color.bold, Color.green, Color.reset });
    try stdout.print("{s}  Bundle: {s}{s}{s}\n", .{ P, Color.cyan, bundle_name.?, Color.reset });
    try stdout.print("{s}  Note: Run {s}clumsies init <remote>{s} to set up git remote\n\n", .{ P, Color.dim, Color.reset });
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
