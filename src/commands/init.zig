const std = @import("std");
const fs = std.fs;
const git = @import("../git.zig");
const commands = @import("commands.zig");
const config = @import("config.zig");
const spinner = @import("../spinner.zig");

const Color = commands.Color;
const P = commands.P;

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse args: init <bundle> <url>
    var bundle_name: ?[]const u8 = null;
    var remote_url: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            if (bundle_name == null) {
                bundle_name = arg;
            } else if (remote_url == null) {
                remote_url = arg;
            }
        }
    }

    if (bundle_name == null or remote_url == null) {
        try stderr.print("\n{s}{s}{s}Error:{s} Bundle name and remote URL required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies init <bundle> <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    if (commands.promptsExist()) {
        try stderr.print("\n{s}{s}{s}Error:{s} .prompts/ already exists\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Use {s}clumsies clone{s} to clone existing prompts to a new machine\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const prompts_path = commands.getPromptsPath(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Could not determine .prompts/ path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(prompts_path);

    try stdout.writeAll("\n");
    try initFromBundle(stdout, stderr, allocator, prompts_path, bundle_name.?, remote_url.?);
}

fn initFromBundle(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, prompts_path: []const u8, bundle_name: []const u8, remote_url: []const u8) !void {
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
        var _err: ?[]const u8 = null;
        git.pull(allocator, registry_path, &_err) catch {};
        sp.succeed();
    }

    // Read bundles/index.json
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles", "index.json" });
    defer allocator.free(index_path);

    const index_file = fs.openFileAbsolute(index_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run {s}clumsies bundle list{s} to see available bundles\n\n", .{ P, Color.cyan, Color.reset });
        return;
    };
    const index_content = index_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        index_file.close();
        try stderr.print("{s}{s}{s}Error:{s} Failed to read bundles index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    index_file.close();
    defer allocator.free(index_content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, index_content, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse bundles index\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    // Find bundle by name
    const bundles = parsed.value.object.get("bundles") orelse {
        try stderr.print("{s}{s}{s}Error:{s} No bundles found in registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
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

    if (found_bundle == null) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, bundle_name });
        try stderr.print("{s}Run {s}clumsies bundle list{s} to see available bundles\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    // Check meta_prompt is present
    const meta_prompt_hash = if (found_bundle.?.object.get("meta_prompt")) |m| m.string else "";
    if (meta_prompt_hash.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Bundle has no meta-prompt file\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Bundle must be registered with a meta-prompt file\n\n", .{P});
        return;
    }

    // Get prompts index for name/format lookup
    const prompts_index_path = try std.fs.path.join(allocator, &.{ registry_path, "prompts", "index.json" });
    defer allocator.free(prompts_index_path);

    var prompts_index: ?std.json.Parsed(std.json.Value) = null;
    if (fs.openFileAbsolute(prompts_index_path, .{})) |pf| {
        defer pf.close();
        if (pf.readToEndAlloc(allocator, 10 * 1024 * 1024)) |content| {
            defer allocator.free(content);
            prompts_index = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        } else |_| {}
    } else |_| {}
    defer if (prompts_index) |pi| pi.deinit();

    // Create .prompts directory structure
    fs.cwd().makeDir(".prompts") catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to create .prompts/: {}\n\n", .{ P, Color.bold, Color.red, Color.reset, err });
        return;
    };

    const conduct_path = try std.fs.path.join(allocator, &.{ prompts_path, "conduct" });
    defer allocator.free(conduct_path);
    fs.cwd().makePath(conduct_path) catch {};

    const command_path = try std.fs.path.join(allocator, &.{ prompts_path, "command" });
    defer allocator.free(command_path);
    fs.cwd().makePath(command_path) catch {};

    // Copy prompts from registry
    var sp = spinner.init(stdout, "Copying prompts");
    sp.start();

    const prompts_arr = found_bundle.?.object.get("prompts") orelse {
        sp.fail();
        try stderr.print("{s}{s}{s}Error:{s} Bundle has no prompts\n\n", .{ P, Color.bold, Color.red, Color.reset });
        fs.deleteTreeAbsolute(prompts_path) catch {};
        return;
    };

    var prompt_count: usize = 0;
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

        // Determine next sequence number
        const target_dir = if (std.mem.eql(u8, category, "command")) command_path else conduct_path;
        const seq = findNextSequence(allocator, target_dir);

        // Destination: .prompts/{category}/{seq}_{name}.{format}
        const filename = try std.fmt.allocPrint(allocator, "{d:0>2}_{s}.{s}", .{ seq, prompt_name, prompt_format });
        defer allocator.free(filename);
        const dest_path = try std.fs.path.join(allocator, &.{ target_dir, filename });
        defer allocator.free(dest_path);

        fs.copyFileAbsolute(src_path, dest_path, .{}) catch continue;
        prompt_count += 1;
    }
    sp.succeed();

    // Copy meta-prompt file
    var sp2 = spinner.init(stdout, "Copying meta-prompt");
    sp2.start();

    const meta_src = try std.fs.path.join(allocator, &.{ registry_path, "meta-prompts", meta_prompt_hash });
    defer allocator.free(meta_src);

    // Get target filename from config or default to CLAUDE.md
    const meta_prompt_filename = config.getMetaPromptFile(allocator) catch null orelse "CLAUDE.md";
    defer if (config.getMetaPromptFile(allocator) catch null) |f| allocator.free(f);

    // Copy to workspace root (parent of .prompts/)
    const cwd = std.process.getCwdAlloc(allocator) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Could not determine current directory\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer allocator.free(cwd);

    const meta_dest = try std.fs.path.join(allocator, &.{ cwd, meta_prompt_filename });
    defer allocator.free(meta_dest);

    fs.copyFileAbsolute(meta_src, meta_dest, .{}) catch {
        sp2.fail();
        try stderr.print("{s}{s}{s}Error:{s} Failed to copy meta-prompt file\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    sp2.succeed();

    try stdout.print("\n{s}{s}✓{s} Created .prompts/ from bundle: {s}{s}{s}\n", .{ P, Color.green, Color.reset, Color.cyan, bundle_name, Color.reset });
    try stdout.print("{s}  Prompts: {d}\n", .{ P, prompt_count });
    try stdout.print("{s}  Meta-prompt: {s}\n", .{ P, meta_prompt_filename });

    // Init git and add remote
    git.init(allocator, prompts_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to initialize git repository\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    try stdout.print("{s}{s}✓{s} Initialized git repository\n", .{ P, Color.green, Color.reset });

    git.addRemote(allocator, prompts_path, remote_url) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to add remote\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    try stdout.print("{s}{s}✓{s} Added remote: {s}{s}{s}\n\n", .{ P, Color.green, Color.reset, Color.cyan, remote_url, Color.reset });
}

fn findNextSequence(_: std.mem.Allocator, dir_path: []const u8) u8 {
    var used: [100]bool = .{false} ** 100;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return 0) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 3 and entry.name[2] == '_') {
            if (std.ascii.isDigit(entry.name[0]) and std.ascii.isDigit(entry.name[1])) {
                const seq = (entry.name[0] - '0') * 10 + (entry.name[1] - '0');
                if (seq < 100) used[seq] = true;
            }
        }
    }

    // Find first unused
    for (used, 0..) |is_used, i| {
        if (!is_used) return @intCast(i);
    }
    return 99;
}
