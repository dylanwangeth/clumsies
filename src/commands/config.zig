const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const commands = @import("commands.zig");
const lib = @import("clumsies_lib");
const lib_config = lib.config;

const Color = commands.Color;
const P = commands.P;
const jsonEscapeAlloc = commands.jsonEscapeAlloc;

pub const DEFAULT_META_PROMPT_FILES = lib_config.DEFAULT_META_PROMPT_FILES;
pub const RegistryInfo = lib_config.RegistryInfo;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
        try printConfigHelp(stderr);
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        try printConfigHelp(stdout);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listConfig(stdout, allocator);
    } else if (std.mem.eql(u8, subcmd, "get") and args.len >= 2) {
        try getConfig(stdout, stderr, allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "set") and args.len >= 3) {
        try setConfig(stdout, stderr, allocator, args[1], args[2]);
    } else if (std.mem.startsWith(u8, subcmd, "-")) {
        try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, subcmd });
        try printConfigHelp(stderr);
    } else {
        try stderr.print("{s}{s}{s}Error:{s} Unknown subcommand: {s}\n", .{ P, Color.bold, Color.red, Color.reset, subcmd });
        try printConfigHelp(stderr);
    }
}

fn printConfigHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies config <command> [key] [value]{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Commands:\n", .{P});
    try out.print("{s}  {s}list{s}              List all config\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}get{s} <key>         Get config value\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}set{s} <key> <value> Set config value\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Options:\n", .{P});
    try out.print("{s}  {s}-h, --help{s}        Show this help\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Config keys:\n", .{P});
    try out.print("{s}  {s}registry{s}          Registry URL\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}meta_prompt_files{s} Meta-prompt files for startup recall\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}  {s}meta_prompt_file{s}  Default meta-prompt for pub\n", .{ P, Color.cyan, Color.reset });
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    return lib_config.getConfigPath(allocator);
}

fn readConfig(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return lib_config.readConfig(allocator);
}

fn listConfig(stdout: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    try stdout.print("{s}{s}{s}Configuration:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    const parsed = readConfig(allocator) catch {
        try stdout.print("{s}  {s}(no configuration){s}\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer parsed.deinit();

    const keys = parsed.value.object.keys();
    const sorted_keys = try allocator.alloc([]const u8, keys.len);
    defer allocator.free(sorted_keys);
    @memcpy(sorted_keys, keys);
    std.mem.sort([]const u8, sorted_keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (sorted_keys) |key| {
        const value_str = if (parsed.value.object.get(key)) |v| switch (v) {
            .string => |s| s,
            else => "-",
        } else "-";
        try stdout.print("{s}  {s} = {s}\n", .{ P, key, value_str });
    }
}

fn getConfig(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8) !void {
    const parsed = readConfig(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} No configuration found\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    if (parsed.value.object.get(key)) |value| {
        const value_str = switch (value) {
            .string => |s| s,
            else => "-",
        };
        try stdout.print("{s}{s} = {s}\n", .{ P, key, value_str });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} Key not found: {s}\n", .{ P, Color.bold, Color.red, Color.reset, key });
    }
}

fn setConfig(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const base = try commands.getBasePath(allocator);
    defer allocator.free(base);

    // Ensure directory exists
    fs.cwd().makePath(base) catch {};

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    // Read existing config or create new
    var config_map = std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        // Free all keys and values before deinit
        for (config_map.keys(), config_map.values()) |k, v| {
            allocator.free(k);
            allocator.free(v);
        }
        config_map.deinit();
    }

    if (readConfig(allocator)) |parsed| {
        defer parsed.deinit();
        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const v = switch (entry.value_ptr.*) {
                .string => |s| try allocator.dupe(u8, s),
                else => continue,
            };
            try config_map.put(try allocator.dupe(u8, entry.key_ptr.*), v);
        }
    } else |_| {}

    // Set new value (use fetchPut to handle existing key)
    const key_dup = try allocator.dupe(u8, key);
    const val_dup = try allocator.dupe(u8, value);
    if (try config_map.fetchPut(key_dup, val_dup)) |old| {
        // Key already existed, free the duplicated key and old value
        allocator.free(key_dup);
        allocator.free(old.value);
    }

    // Write config
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "{\n");
    var first = true;
    var map_iter = config_map.iterator();
    while (map_iter.next()) |entry| {
        if (!first) try output.appendSlice(allocator, ",\n");
        first = false;
        const esc_key = try jsonEscapeAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(esc_key);
        const esc_val = try jsonEscapeAlloc(allocator, entry.value_ptr.*);
        defer allocator.free(esc_val);
        const line = try std.fmt.allocPrint(allocator, "  \"{s}\": \"{s}\"", .{ esc_key, esc_val });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    try output.appendSlice(allocator, "\n}\n");

    const file = fs.createFileAbsolute(config_path, .{}) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to write config\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();
    try file.writeAll(output.items);

    try stdout.print("{s}{s}{s}✓{s} Set {s} = {s}\n", .{ P, Color.bold, Color.green, Color.reset, key, value });
}

pub fn getRegistry(allocator: std.mem.Allocator) ![]const u8 {
    return lib_config.getRegistry(allocator);
}

/// Parse "url#branch" format into separate url and branch components
pub fn parseRegistryUrl(allocator: std.mem.Allocator, raw: []const u8) !RegistryInfo {
    return lib_config.parseRegistryUrl(allocator, raw);
}

/// Get registry URL and branch, parsing "url#branch" format
pub fn getRegistryInfo(allocator: std.mem.Allocator) !RegistryInfo {
    return lib_config.getRegistryInfo(allocator);
}

pub fn getMetaPromptFilesStr(allocator: std.mem.Allocator) !?[]const u8 {
    return lib_config.getMetaPromptFilesStr(allocator);
}

pub fn getMetaPromptFile(allocator: std.mem.Allocator) !?[]const u8 {
    return lib_config.getMetaPromptFile(allocator);
}

test "parseRegistryUrl: https without branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar.git");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar.git", info.url);
    try testing.expect(info.branch == null);
}

test "parseRegistryUrl: https with branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar.git#main");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar.git", info.url);
    try testing.expectEqualStrings("main", info.branch.?);
}

test "parseRegistryUrl: ssh with branch" {
    const info = try parseRegistryUrl(testing.allocator, "git@github.com:foo/bar.git#develop");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("git@github.com:foo/bar.git", info.url);
    try testing.expectEqualStrings("develop", info.branch.?);
}

test "parseRegistryUrl: hash at end gives empty branch" {
    const info = try parseRegistryUrl(testing.allocator, "https://github.com/foo/bar#");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("https://github.com/foo/bar", info.url);
    try testing.expectEqualStrings("", info.branch.?);
}

test "parseRegistryUrl: multiple hashes uses last one" {
    const info = try parseRegistryUrl(testing.allocator, "url#first#second");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("url#first", info.url);
    try testing.expectEqualStrings("second", info.branch.?);
}

test "parseRegistryUrl: no hash no branch" {
    const info = try parseRegistryUrl(testing.allocator, "git@github.com:foo/bar.git");
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("git@github.com:foo/bar.git", info.url);
    try testing.expect(info.branch == null);
}
