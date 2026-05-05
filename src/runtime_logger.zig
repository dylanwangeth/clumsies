const std = @import("std");
const testing = std.testing;

pub const Sink = union(enum) {
    disabled,
    stderr,
    file: []const u8,
};

pub const Options = struct {
    level: std.log.Level,
    sink: Sink,
};

var mutex: std.Thread.Mutex = .{};
var active_level: std.log.Level = .warn;
var active_sink: SinkTag = .disabled;
var active_file: ?std.fs.File = null;
var active_writer: ?std.fs.File.Writer = null;
var writer_buffer: [4096]u8 = undefined;
var failure_reported = false;

const SinkTag = enum {
    disabled,
    stderr,
    file,
};

pub fn init(options: Options) !void {
    mutex.lock();
    defer mutex.unlock();

    deinitLocked();
    active_level = options.level;
    failure_reported = false;

    switch (options.sink) {
        .disabled => active_sink = .disabled,
        .stderr => {
            active_writer = std.fs.File.Writer.initStreaming(std.fs.File.stderr(), &writer_buffer);
            active_sink = .stderr;
        },
        .file => |path| {
            try ensureParentDir(path);
            const file = try std.fs.createFileAbsolute(path, .{ .truncate = false, .read = true });
            errdefer file.close();
            var writer = std.fs.File.Writer.init(file, &writer_buffer);
            try writer.seekTo(try file.getEndPos());
            active_file = file;
            active_writer = writer;
            active_sink = .file;
        },
    }
}

pub fn initBestEffort(options: Options) void {
    init(options) catch {
        mutex.lock();
        defer mutex.unlock();
        deinitLocked();
        active_level = options.level;
        active_sink = .disabled;
        failure_reported = true;
    };
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    deinitLocked();
}

pub fn parseLevel(raw: []const u8) ?std.log.Level {
    if (std.ascii.eqlIgnoreCase(raw, "err") or std.ascii.eqlIgnoreCase(raw, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
    return null;
}

pub fn clientDefaultLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBasePath(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "logs", "client.log" });
}

pub fn resolveLogFilePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw_path)) return allocator.dupe(u8, raw_path);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, raw_path });
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock();
    defer mutex.unlock();

    if (active_sink == .disabled) return;
    if (@intFromEnum(message_level) > @intFromEnum(active_level)) return;

    const writer = if (active_writer) |*writer| writer else {
        active_sink = .disabled;
        return;
    };

    writeLogLine(&writer.interface, message_level, scope, format, args) catch {
        disableLocked();
        return;
    };
    writer.interface.flush() catch {
        disableLocked();
        return;
    };
}

pub fn writeLogLine(
    writer: *std.Io.Writer,
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    const scope_text = comptime if (scope == .default) "default" else @tagName(scope);
    try writer.print(comptime message_level.asText() ++ " (" ++ scope_text ++ "): " ++ format ++ "\n", args);
}

pub fn noteInvalidLevel(raw: []const u8) void {
    if (failure_reported) return;
    const log = std.log.scoped(.logger);
    log.warn("invalid CLUMSIES_LOG_LEVEL '{s}'; using default", .{raw});
    failure_reported = true;
}

fn deinitLocked() void {
    if (active_writer) |*writer| {
        writer.interface.flush() catch {};
    }
    active_writer = null;
    if (active_file) |file| {
        file.close();
    }
    active_file = null;
    active_sink = .disabled;
}

fn disableLocked() void {
    deinitLocked();
    failure_reported = true;
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.HomeNotSet;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

test "parseLevel accepts supported names" {
    try testing.expectEqual(std.log.Level.err, parseLevel("err").?);
    try testing.expectEqual(std.log.Level.err, parseLevel("ERROR").?);
    try testing.expectEqual(std.log.Level.warn, parseLevel("warning").?);
    try testing.expectEqual(std.log.Level.info, parseLevel("Info").?);
    try testing.expectEqual(std.log.Level.debug, parseLevel("debug").?);
}

test "parseLevel rejects unsupported names" {
    try testing.expect(parseLevel("") == null);
    try testing.expect(parseLevel("trace") == null);
}

test "writeLogLine formats level scope and message" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeLogLine(&writer, .warn, .auth, "failed with {s}", .{"error"});
    try testing.expectEqualStrings("warning (auth): failed with error\n", writer.buffered());
}

test "clientDefaultLogPath uses local runtime logs directory" {
    const path = try clientDefaultLogPath(testing.allocator);
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "/.clumsies/logs/client.log"));
}
