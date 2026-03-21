const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const styles = @import("../styles.zig");
const git = @import("../git.zig");
const spinner = @import("../spinner.zig");
const config = @import("config.zig");
const encoding = @import("encoding.zig");

const Color = styles.Color;
const P = styles.P;
const GitOutput = git.GitOutput;

const MAX_FILE_SIZE = 10 * 1024 * 1024;

pub const PromptIndexEntry = struct {
    hash: []const u8,
    name: ?[]const u8 = null,
    description: []const u8 = "-",
    format: []const u8 = "md",
    group: ?[]const u8 = null,
};

pub const PromptMatch = union(enum) {
    unique: PromptIndexEntry,
    ambiguous: void,
    not_found: void,
};

pub const RefKind = enum { prompt, bundle, ambiguous_prompt, not_found };

pub fn printGitOutputRaw(output: *const GitOutput, quiet: bool) void {
    if (quiet) return;
    const has_stdout = output.stdout != null and output.stdout.?.len > 0;
    const has_stderr = output.stderr != null and output.stderr.?.len > 0;

    if (!has_stdout and !has_stderr) return;

    const raw_stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;

    const header = std.fmt.bufPrint(&buf, "{s}{s}git:{s}\n", .{ P, Color.dim, Color.reset }) catch return;
    _ = raw_stdout.write(header) catch return;

    if (has_stdout) {
        const stdout_content = std.mem.trim(u8, output.stdout.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stdout_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }

    if (has_stderr) {
        const stderr_content = std.mem.trim(u8, output.stderr.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stderr_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }
}

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.NoHome;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

/// Ensure registry exists, optionally sync with remote.
/// If registry_url is provided, use it instead of the configured registry
/// and cache in ~/.clumsies/cache/<hash>/.
pub fn ensureRegistry(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator, sync: bool, quiet_git: bool, registry_url: ?[]const u8) ![]const u8 {
    const registry_info = if (registry_url) |url|
        try config.parseRegistryUrl(allocator, url)
    else
        config.getRegistryInfo(allocator) catch {
            try stderr.print("{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
            try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n", .{ P, Color.cyan, Color.reset });
            try stderr.print("{s}Tip: Use {s}<git-url>#<branch>{s} to specify a branch\n", .{ P, Color.cyan, Color.reset });
            return error.NoRegistry;
        };
    defer registry_info.deinit(allocator);

    const base_path = getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n", .{ P, Color.bold, Color.red, Color.reset });
        return error.NoBasePath;
    };
    defer allocator.free(base_path);

    // Override: cache in ~/.clumsies/cache/<hash>/ to avoid conflicts
    const registry_path = if (registry_url != null) blk: {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(registry_info.url, &hash, .{});
        var hex: [64]u8 = undefined;
        encoding.hexEncode(&hash, &hex);
        break :blk try std.fs.path.join(allocator, &.{ base_path, "cache", hex[0..16] });
    } else try std.fs.path.join(allocator, &.{ base_path, "registry" });
    errdefer allocator.free(registry_path);

    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (!registry_exists) {
        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        git.cloneWithBranch(allocator, registry_info.url, registry_path, registry_info.branch, &git_output) catch {
            sp.fail();
            printGitOutputRaw(&git_output, quiet_git);
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n", .{ P, Color.bold, Color.red, Color.reset });
            return error.CloneFailed;
        };
        sp.succeed();
        printGitOutputRaw(&git_output, quiet_git);
    } else if (sync) {
        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();

        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        var sync_ok = true;
        if (registry_info.branch) |branch| {
            var checkout_output: GitOutput = .{};
            defer checkout_output.deinit(allocator);
            git.fetchAndCheckout(allocator, registry_path, branch, &checkout_output) catch {
                sync_ok = false;
            };
        }
        git.pull(allocator, registry_path, &git_output) catch {
            sync_ok = false;
        };
        if (sync_ok) {
            sp.succeed();
        } else {
            sp.fail();
            try stderr.print("{s}{s}{s}Warning:{s} Sync failed, using local cache\n", .{ P, Color.bold, Color.orange, Color.reset });
        }
        printGitOutputRaw(&git_output, quiet_git);
    }

    return registry_path;
}

/// Resolve a ref to either a prompt (by hash prefix) or bundle (by name).
/// 1. If ref is hex-only → search prompts/index.json by hash prefix
/// 2. Otherwise → search bundles/index.json by name
/// 3. not_found if neither matches
pub fn resolveRef(allocator: std.mem.Allocator, registry_path: []const u8, ref: []const u8) RefKind {
    if (encoding.isHexString(ref)) {
        const index_path = std.fs.path.join(allocator, &.{ registry_path, "prompts/index.json" }) catch return .not_found;
        defer allocator.free(index_path);

        const file = fs.openFileAbsolute(index_path, .{}) catch return .not_found;
        defer file.close();
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return .not_found;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .not_found;
        defer parsed.deinit();

        const prompts = parsed.value.object.get("prompts") orelse return .not_found;
        return switch (findPromptByHashPrefix(prompts, ref)) {
            .unique => .prompt,
            .ambiguous => .ambiguous_prompt,
            .not_found => .not_found,
        };
    } else {
        const index_path = std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" }) catch return .not_found;
        defer allocator.free(index_path);

        const file = fs.openFileAbsolute(index_path, .{}) catch return .not_found;
        defer file.close();
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return .not_found;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .not_found;
        defer parsed.deinit();

        const bundles = parsed.value.object.get("bundles") orelse return .not_found;
        for (bundles.array.items) |item| {
            const item_name = if (item.object.get("name")) |n| n.string else continue;
            if (std.mem.eql(u8, item_name, ref)) return .bundle;
        }
        return .not_found;
    }
}

pub fn findPromptByHashPrefix(prompts: std.json.Value, prefix: []const u8) PromptMatch {
    var found: ?PromptIndexEntry = null;

    for (prompts.array.items) |item| {
        const item_hash = if (item.object.get("hash")) |h| h.string else continue;
        if (!std.mem.startsWith(u8, item_hash, prefix)) continue;

        if (found != null) return .ambiguous;

        found = .{
            .hash = item_hash,
            .name = if (item.object.get("name")) |n| n.string else null,
            .description = if (item.object.get("description")) |d| d.string else "-",
            .format = if (item.object.get("format")) |f| f.string else "md",
            .group = if (item.object.get("group")) |g| g.string else null,
        };
    }

    if (found) |entry| return .{ .unique = entry };
    return .not_found;
}

pub fn printAmbiguousPromptHashError(stderr: *std.io.Writer, ref: []const u8) !void {
    try stderr.print("{s}{s}{s}Error:{s} Ambiguous prompt hash prefix: {s}\n", .{ P, Color.bold, Color.red, Color.reset, ref });
    try stderr.print("{s}Use a longer prefix or the full hash\n", .{P});
}

/// Check if a bundle exists in the registry by name
pub fn bundleExists(allocator: std.mem.Allocator, registry_path: []const u8, name: []const u8) bool {
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

fn writeTestFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "resolveRef: hash prefix matches prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("prompts");
    try writeTestFile(tmp.dir, "prompts/index.json",
        \\{"prompts":[{"hash":"abcdef1234567890","name":"FOO","description":"-","format":"md","group":"rule","created_at":"0"}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(RefKind.prompt, resolveRef(testing.allocator, path, "abcdef12"));
}

test "resolveRef: ambiguous hash prefix returns ambiguous_prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("prompts");
    try writeTestFile(tmp.dir, "prompts/index.json",
        \\{"prompts":[
        \\{"hash":"abcdef1234567890","name":"FOO","description":"-","format":"md","group":"rule","created_at":"0"},
        \\{"hash":"abcdef99aaaa0000","name":"BAR","description":"-","format":"md","group":"rule","created_at":"0"}
        \\]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(RefKind.ambiguous_prompt, resolveRef(testing.allocator, path, "abcdef"));
}

test "resolveRef: name matches bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json",
        \\{"bundles":[{"name":"my-bundle","task":"-","description":"-","created_at":"0","meta_prompt":"","prompts":[]}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(RefKind.bundle, resolveRef(testing.allocator, path, "my-bundle"));
}

test "resolveRef: no match returns not_found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("prompts");
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "prompts/index.json", "{\"prompts\":[]}");
    try writeTestFile(tmp.dir, "bundles/index.json", "{\"bundles\":[]}");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(RefKind.not_found, resolveRef(testing.allocator, path, "deadbeef"));
    try testing.expectEqual(RefKind.not_found, resolveRef(testing.allocator, path, "nonexistent"));
}

test "findPromptByHashPrefix: unique match returns metadata" {
    const json =
        \\{"prompts":[{"hash":"abcdef1234567890","name":"FOO","description":"desc","format":"md","group":"rule","created_at":"0"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts").?;
    const match = findPromptByHashPrefix(prompts, "abcdef12");
    switch (match) {
        .unique => |entry| {
            try testing.expectEqualStrings("abcdef1234567890", entry.hash);
            try testing.expectEqualStrings("FOO", entry.name.?);
            try testing.expectEqualStrings("desc", entry.description);
            try testing.expectEqualStrings("md", entry.format);
            try testing.expectEqualStrings("rule", entry.group.?);
        },
        else => return error.UnexpectedResult,
    }
}

test "findPromptByHashPrefix: ambiguous prefix returns ambiguous" {
    const json =
        \\{"prompts":[
        \\{"hash":"abcdef1234567890","name":"FOO","description":"-","format":"md","group":"rule","created_at":"0"},
        \\{"hash":"abcdef99aaaa0000","name":"BAR","description":"-","format":"md","group":"rule","created_at":"0"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const prompts = parsed.value.object.get("prompts").?;
    switch (findPromptByHashPrefix(prompts, "abcdef")) {
        .ambiguous => {},
        else => return error.UnexpectedResult,
    }
}

test "resolveRef: no index files returns not_found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(RefKind.not_found, resolveRef(testing.allocator, path, "abcdef"));
    try testing.expectEqual(RefKind.not_found, resolveRef(testing.allocator, path, "some-name"));
}

test "bundleExists: existing bundle returns true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json",
        \\{"bundles":[{"name":"coding","task":"-","description":"-","created_at":"0","meta_prompt":"","prompts":[]}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expect(bundleExists(testing.allocator, path, "coding"));
}

test "bundleExists: non-existing bundle returns false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json", "{\"bundles\":[]}");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expect(!bundleExists(testing.allocator, path, "nope"));
}

test "bundleExists: no index file returns false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expect(!bundleExists(testing.allocator, path, "anything"));
}
