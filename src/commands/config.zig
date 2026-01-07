const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");
const Color = commands.Color;
const P = commands.P;

const Config = struct {
    lang: [2]u8 = .{ 'e', 'n' },

    pub fn langStr(self: *const Config) []const u8 {
        return &self.lang;
    }
};

pub fn run(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try showHelp(stdout);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "set")) {
        if (args.len < 3) {
            try stderr.print("\n{s}{s}{s}Error:{s} Missing key or value\n{s}Usage: {s}clumsies config set <key> <value>{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
            return;
        }
        try setConfig(stdout, stderr, allocator, args[1], args[2]);
    } else if (std.mem.eql(u8, subcommand, "get")) {
        if (args.len < 2) {
            try stderr.print("\n{s}{s}{s}Error:{s} Missing key\n{s}Usage: {s}clumsies config get <key>{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
            return;
        }
        try getConfig(stdout, stderr, allocator, args[1]);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try listConfig(stdout, stderr, allocator);
    } else {
        try stderr.print("\n{s}{s}{s}Error:{s} Unknown subcommand '{s}'\n", .{ P, Color.bold, Color.red, Color.reset, subcommand });
        try showHelp(stdout);
    }
}

fn showHelp(stdout: anytype) !void {
    try stdout.writeAll("\n");
    try stdout.print("{s}{s}{s}clumsies config{s} - Manage configuration\n\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}{s}Usage:{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}  clumsies config set <key> <value>   Set a config value\n", .{P});
    try stdout.print("{s}  clumsies config get <key>           Get a config value\n", .{P});
    try stdout.print("{s}  clumsies config list                List all config\n\n", .{P});
    try stdout.print("{s}{s}Available keys:{s}\n", .{ P, Color.bold, Color.reset });
    try stdout.print("{s}  lang    Default language (ISO 639-1, e.g., en, zh, ja, ko)\n\n", .{P});
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const base_path = try commands.getBasePath(allocator);
    defer allocator.free(base_path);
    return try std.fs.path.join(allocator, &.{ base_path, "config.json" });
}

fn loadConfig(allocator: std.mem.Allocator) !Config {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = fs.openFileAbsolute(config_path, .{}) catch {
        return Config{};
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return Config{};
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return Config{};
    };
    defer parsed.deinit();

    var config = Config{};

    if (parsed.value.object.get("lang")) |lang_val| {
        if (lang_val == .string and lang_val.string.len == 2) {
            config.lang = .{ lang_val.string[0], lang_val.string[1] };
        }
    }

    return config;
}

fn saveConfig(allocator: std.mem.Allocator, config: Config) !void {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const base_path = try commands.getBasePath(allocator);
    defer allocator.free(base_path);

    // Ensure directory exists
    fs.cwd().makePath(base_path) catch {};

    const file = fs.createFileAbsolute(config_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\n  \"lang\": \"{s}\"\n}}\n", .{config.langStr()}) catch {
        return error.BufferTooSmall;
    };

    try file.writeAll(json);
}

fn isValidLangCode(code: []const u8) bool {
    if (code.len != 2) return false;
    // ISO 639-1: two lowercase letters
    for (code) |c| {
        if (c < 'a' or c > 'z') return false;
    }
    return true;
}

fn setConfig(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    var config = try loadConfig(allocator);

    if (std.mem.eql(u8, key, "lang")) {
        if (!isValidLangCode(value)) {
            try stderr.print("\n{s}{s}{s}Error:{s} Invalid language code '{s}'. Use ISO 639-1 format (e.g., en, zh, ja, ko).\n\n", .{ P, Color.bold, Color.red, Color.reset, value });
            return;
        }
        config.lang = .{ value[0], value[1] };
    } else {
        try stderr.print("\n{s}{s}{s}Error:{s} Unknown config key '{s}'\n\n", .{ P, Color.bold, Color.red, Color.reset, key });
        return;
    }

    try saveConfig(allocator, config);
    try stdout.print("\n{s}{s}{s}✓{s} Set {s}{s}{s} = {s}{s}{s}\n\n", .{ P, Color.bold, Color.green, Color.reset, Color.bold, key, Color.reset, Color.cyan, value, Color.reset });
}

fn getConfig(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, key: []const u8) !void {
    const config = try loadConfig(allocator);

    try stdout.writeAll("\n");

    if (std.mem.eql(u8, key, "lang")) {
        try stdout.print("{s}{s}{s}{s} = {s}{s}{s}\n\n", .{ P, Color.bold, key, Color.reset, Color.cyan, config.langStr(), Color.reset });
    } else {
        try stderr.print("{s}{s}{s}Error:{s} Unknown config key '{s}'\n\n", .{ P, Color.bold, Color.red, Color.reset, key });
    }
}

fn listConfig(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) !void {
    _ = stderr;
    const config = try loadConfig(allocator);

    try stdout.writeAll("\n");
    try stdout.print("{s}{s}{s}Configuration:{s}\n", .{ P, Color.bold, Color.orange, Color.reset });
    try stdout.print("{s}  {s}lang{s} = {s}{s}{s}\n\n", .{ P, Color.bold, Color.reset, Color.cyan, config.langStr(), Color.reset });
}

/// Get the configured language, with optional override
/// Caller must free the returned slice
pub fn getLang(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |lang| {
        if (isValidLangCode(lang)) {
            return try allocator.dupe(u8, lang);
        }
        return try allocator.dupe(u8, "en");
    }

    const config = try loadConfig(allocator);
    return try allocator.dupe(u8, config.langStr());
}
