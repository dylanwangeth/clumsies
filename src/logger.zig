const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const epoch = std.time.epoch;

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
var color_enabled: bool = false;
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
        .disabled => {
            active_sink = .disabled;
            color_enabled = false;
        },
        .stderr => {
            active_writer = std.fs.File.Writer.initStreaming(std.fs.File.stderr(), &writer_buffer);
            active_sink = .stderr;
            color_enabled = detectColor();
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
            color_enabled = false;
        },
    }
}

pub fn initBestEffort(options: Options) void {
    init(options) catch {
        mutex.lock();
        defer mutex.unlock();
        deinitLocked();
        active_level = options.level;
        color_enabled = false;
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

    writeLogLine(&writer.interface, message_level, scope, format, args, color_enabled) catch {
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
    use_color: bool,
) std.Io.Writer.Error!void {
    const scope_text = comptime if (scope == .default) "default" else @tagName(scope);

    var ts_buf: [19]u8 = undefined;
    formatTimestamp(&ts_buf);

    if (use_color) {
        const level_color = comptime levelColor(message_level);
        const dim = "\x1b[2m";
        const reset = "\x1b[0m";
        try writer.print(dim ++ "{s}" ++ reset ++ " " ++ level_color ++ "[" ++ levelText(message_level) ++ "]" ++ reset ++ " (" ++ scope_text ++ "): " ++ format ++ "\n", .{ts_buf} ++ args);
    } else {
        try writer.print("{s} [" ++ levelText(message_level) ++ "] (" ++ scope_text ++ "): " ++ format ++ "\n", .{ts_buf} ++ args);
    }
}

pub fn noteInvalidLevel(raw: []const u8) void {
    if (failure_reported) return;
    const log = std.log.scoped(.logger);
    log.warn("invalid CLUMSIES_LOG_LEVEL '{s}'; using default", .{raw});
    failure_reported = true;
}

pub fn redactedPath(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| return path[0..idx];
    return path;
}

pub const EnvConfig = struct {
    level: std.log.Level,
    invalid_level: ?[]const u8,
};

pub fn configFromEnv(allocator: std.mem.Allocator) EnvConfig {
    var log_level: std.log.Level = .info;
    var invalid_level: ?[]u8 = null;

    if (std.process.getEnvVarOwned(allocator, "CLUMSIES_LOG_LEVEL")) |raw| {
        if (parseLevel(raw)) |parsed| {
            log_level = parsed;
            allocator.free(raw);
        } else {
            invalid_level = raw;
        }
    } else |_| {}

    return .{ .level = log_level, .invalid_level = invalid_level };
}

fn levelColor(comptime level: std.log.Level) []const u8 {
    return comptime switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };
}

fn levelText(comptime level: std.log.Level) []const u8 {
    return comptime switch (level) {
        .err => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
    };
}

fn formatTimestamp(buf: *[19]u8) void {
    const s: u64 = @intCast(@max(std.time.milliTimestamp(), 0) / 1000);

    const epoch_secs: epoch.EpochSeconds = .{ .secs = s };
    const ed = epoch_secs.getEpochDay();
    const ds = epoch_secs.getDaySeconds();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();

    writeDigits4(buf[0..4], yd.year);
    buf[4] = '-';
    writeDigits2(buf[5..7], md.month.numeric());
    buf[7] = '-';
    writeDigits2(buf[8..10], md.day_index + 1);
    buf[10] = ' ';
    writeDigits2(buf[11..13], ds.getHoursIntoDay());
    buf[13] = ':';
    writeDigits2(buf[14..16], ds.getMinutesIntoHour());
    buf[16] = ':';
    writeDigits2(buf[17..19], ds.getSecondsIntoMinute());
}

fn writeDigits2(buf: *[2]u8, val: anytype) void {
    const v: u8 = @intCast(val);
    buf[0] = '0' + v / 10;
    buf[1] = '0' + v % 10;
}

fn writeDigits4(buf: *[4]u8, val: u16) void {
    const v: u16 = val;
    buf[0] = @intCast('0' + v / 1000);
    buf[1] = @intCast('0' + (v / 100) % 10);
    buf[2] = @intCast('0' + (v / 10) % 10);
    buf[3] = @intCast('0' + v % 10);
}

fn detectColor() bool {
    const no_color = std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR") catch null;
    if (no_color) |val| {
        std.heap.page_allocator.free(val);
        return false;
    }
    if (builtin.os.tag == .windows) return false;
    return std.posix.isatty(std.posix.STDERR_FILENO);
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
    color_enabled = false;
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

test "writeLogLine formats timestamp level scope and message" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeLogLine(&writer, .warn, .auth, "failed with {s}", .{"error"}, false);
    const output = writer.buffered();
    // Verify structure: YYYY-MM-DD HH:MM:SS [WARN ] (auth): failed with error
    try testing.expect(output[4] == '-');
    try testing.expect(output[7] == '-');
    try testing.expect(output[10] == ' ');
    try testing.expect(output[13] == ':');
    try testing.expect(output[16] == ':');
    try testing.expect(std.mem.indexOf(u8, output, "[WARN ]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "(auth): failed with error") != null);
}

test "writeLogLine includes ANSI color codes when enabled" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeLogLine(&writer, .info, .hub, "starting", .{}, true);
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[INFO ]") != null);
}

test "writeLogLine omits ANSI codes when color disabled" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeLogLine(&writer, .err, .default, "oops", .{}, false);
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[ERROR]") != null);
}

test "clientDefaultLogPath uses local runtime logs directory" {
    const path = try clientDefaultLogPath(testing.allocator);
    defer testing.allocator.free(path);

    const suffix = try std.fs.path.join(testing.allocator, &.{ ".clumsies", "logs", "client.log" });
    defer testing.allocator.free(suffix);

    try testing.expect(std.mem.endsWith(u8, path, suffix));
}
