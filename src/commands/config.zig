const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");

const Color = commands.Color;
const P = commands.P;

pub const DEFAULT_ENTRY_FILES = [_][]const u8{ "CLAUDE.md", "CURSOR.md", "AGENTS.md", "COPILOT.md" };

/// Registry URL with optional branch (parsed from "url#branch" format)
pub const RegistryInfo = struct {
    url: []const u8,
    branch: ?[]const u8,

    pub fn deinit(self: RegistryInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.branch) |b| allocator.free(b);
    }
};

const Config = struct {
    registry: ?[]const u8 = null,
    entry_files: ?[]const u8 = null,
    meta_prompt_file: ?[]const u8 = null,
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr.print("\n{s}{s}{s}Error:{s} Subcommand required\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies config <get|set|list> [key] [value]{s}\n\n", .{ P, Color.cyan, Color.reset });
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        try listConfig(stdout, allocator);
    } else if (std.mem.eql(u8, subcmd, "get") and args.len >= 2) {
        try getConfig(stdout, stderr, allocator, args[1]);
    } else if (std.mem.eql(u8, subcmd, "set") and args.len >= 3) {
        try setConfig(stdout, stderr, allocator, args[1], args[2]);
    } else {
        try stderr.print("\n{s}{s}{s}Error:{s} Invalid config command\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Usage: {s}clumsies config <get|set|list> [key] [value]{s}\n\n", .{ P, Color.cyan, Color.reset });
    }
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try commands.getBasePath(allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "config.json" });
}

fn readConfig(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = fs.openFileAbsolute(config_path, .{}) catch return error.NoConfig;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024);
    defer allocator.free(content);

    return std.json.parseFromSlice(std.json.Value, allocator, content, .{});
}

fn listConfig(stdout: anytype, allocator: std.mem.Allocator) !void {
    try stdout.print("\n{s}{s}{s}Configuration:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });

    const parsed = readConfig(allocator) catch {
        try stdout.print("{s}  {s}(no configuration){s}\n\n", .{ P, Color.dim, Color.reset });
        return;
    };
    defer parsed.deinit();

    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        const value_str = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => "-",
        };
        try stdout.print("{s}  {s} = {s}\n", .{ P, entry.key_ptr.*, value_str });
    }
    try stdout.writeAll("\n");
}

fn getConfig(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, key: []const u8) !void {
    const parsed = readConfig(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} No configuration found\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer parsed.deinit();

    if (parsed.value.object.get(key)) |value| {
        const value_str = switch (value) {
            .string => |s| s,
            else => "-",
        };
        try stdout.print("\n{s}{s} = {s}\n\n", .{ P, key, value_str });
    } else {
        try stderr.print("\n{s}{s}{s}Error:{s} Key not found: {s}\n\n", .{ P, Color.bold, Color.red, Color.reset, key });
    }
}

fn setConfig(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
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
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "{\n");
    var first = true;
    var map_iter = config_map.iterator();
    while (map_iter.next()) |entry| {
        if (!first) try output.appendSlice(allocator, ",\n");
        first = false;
        const line = try std.fmt.allocPrint(allocator, "  \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    try output.appendSlice(allocator, "\n}\n");

    const file = fs.createFileAbsolute(config_path, .{}) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Failed to write config\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer file.close();
    try file.writeAll(output.items);

    try stdout.print("\n{s}{s}{s}✓{s} Set {s} = {s}\n\n", .{ P, Color.bold, Color.green, Color.reset, key, value });
}

pub fn getRegistry(allocator: std.mem.Allocator) ![]const u8 {
    const parsed = try readConfig(allocator);
    defer parsed.deinit();

    if (parsed.value.object.get("registry")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => error.NoRegistry,
        };
    }
    return error.NoRegistry;
}

/// Get registry URL and branch, parsing "url#branch" format
pub fn getRegistryInfo(allocator: std.mem.Allocator) !RegistryInfo {
    const raw = try getRegistry(allocator);
    defer allocator.free(raw);

    // Find '#' separator for branch
    if (std.mem.lastIndexOfScalar(u8, raw, '#')) |idx| {
        const url = try allocator.dupe(u8, raw[0..idx]);
        const branch = try allocator.dupe(u8, raw[idx + 1 ..]);
        return .{ .url = url, .branch = branch };
    }

    return .{
        .url = try allocator.dupe(u8, raw),
        .branch = null,
    };
}

pub fn getEntryFilesStr(allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = readConfig(allocator) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get("entry_files")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    return null;
}

pub fn getMetaPromptFile(allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = readConfig(allocator) catch return null;
    defer parsed.deinit();

    if (parsed.value.object.get("meta_prompt_file")) |value| {
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    return null;
}
