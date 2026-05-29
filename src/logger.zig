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
    rotate: bool = true,
    max_bytes: u64 = DEFAULT_LOG_MAX_BYTES,
    backups: usize = DEFAULT_LOG_BACKUPS,
};

pub const DEFAULT_LOG_MAX_BYTES: u64 = 10 * 1024 * 1024;
pub const DEFAULT_LOG_BACKUPS: usize = 10;

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
            if (options.rotate) {
                try rotateLogFileIfNeeded(path, options.max_bytes, options.backups);
            }
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

pub fn loadEnvMap(allocator: std.mem.Allocator) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    loadDotEnv(allocator, &env_map);
    return env_map;
}

pub fn loadDotEnv(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) void {
    const file = std.fs.cwd().openFile(".env", .{}) catch return;
    defer file.close();

    const size = file.getEndPos() catch return;
    if (size == 0) return;
    const alloc_size = std.math.cast(usize, size) orelse return;
    const contents = allocator.alloc(u8, alloc_size) catch return;
    defer allocator.free(contents);

    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &buf);
    reader.interface.readSliceAll(contents) catch return;

    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| {
        applyEnvLine(allocator, env_map, line);
    }
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

pub fn httpAccessLogFn(
    message_level: std.log.Level,
    access: HttpAccess,
) void {
    mutex.lock();
    defer mutex.unlock();

    if (active_sink == .disabled) return;
    if (@intFromEnum(message_level) > @intFromEnum(active_level)) return;

    const writer = if (active_writer) |*writer| writer else {
        active_sink = .disabled;
        return;
    };

    writeHttpAccessLine(&writer.interface, access, color_enabled) catch {
        disableLocked();
        return;
    };
    writer.interface.flush() catch {
        disableLocked();
        return;
    };
}

pub fn hubEventLogFn(
    message_level: std.log.Level,
    event: HubEvent,
) void {
    mutex.lock();
    defer mutex.unlock();

    if (active_sink == .disabled) return;
    if (@intFromEnum(message_level) > @intFromEnum(active_level)) return;

    const writer = if (active_writer) |*writer| writer else {
        active_sink = .disabled;
        return;
    };

    writeHubEventLine(&writer.interface, event) catch {
        disableLocked();
        return;
    };
    writer.interface.flush() catch {
        disableLocked();
        return;
    };
}

pub const HttpAccess = struct {
    status: u16,
    elapsed_ns: i128,
    ip: []const u8,
    client_id: []const u8,
    request_id: []const u8,
    method: []const u8,
    path: []const u8,
    route: []const u8,
    ws_id: []const u8 = "-",
    pr_id: []const u8 = "-",
    rule_id: []const u8 = "-",
    context_id: []const u8 = "-",
    target_user_id: []const u8 = "-",
    org_id: []const u8 = "-",
    error_code: []const u8 = "-",
    error_message: []const u8 = "-",
};

pub const HubEvent = struct {
    name: []const u8,
    outcome: []const u8 = "ok",
    action: []const u8 = "-",
    target_kind: []const u8 = "-",
    actor_user_id: []const u8 = "-",
    org_id: []const u8 = "-",
    ws_id: []const u8 = "-",
    pr_id: []const u8 = "-",
    op_count: ?usize = null,
};

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

pub fn writeHttpAccessLine(
    writer: *std.Io.Writer,
    access: HttpAccess,
    use_color: bool,
) std.Io.Writer.Error!void {
    var ts_buf: [19]u8 = undefined;
    formatTimestamp(&ts_buf);
    var duration_buf: [16]u8 = undefined;
    const duration = formatDuration(&duration_buf, access.elapsed_ns);
    const show_client_id = access.client_id.len > 0 and !std.mem.eql(u8, access.client_id, "-");

    if (use_color) {
        const dim = "\x1b[2m";
        const reset = "\x1b[0m";
        try writer.print(
            dim ++ "{s}" ++ reset ++ " |{s} {d: >3} {s}| {s: >8} | {s: <15} |{s} {s: ^6} {s}| {s}",
            .{ ts_buf, statusColor(access.status), access.status, reset, duration, access.ip, methodColor(access.method), access.method, reset, access.path },
        );
    } else {
        try writer.print(
            "{s} | {d: >3} | {s: >8} | {s: <15} | {s: <6} {s}",
            .{ ts_buf, access.status, duration, access.ip, access.method, access.path },
        );
    }
    if (show_client_id) {
        try writeField(writer, "client_id", access.client_id);
    }
    try writeField(writer, "request_id", access.request_id);
    try writeField(writer, "route", access.route);
    try writeOptionalField(writer, "target_user_id", access.target_user_id);
    try writeOptionalField(writer, "org_id", access.org_id);
    try writeOptionalField(writer, "ws_id", access.ws_id);
    try writeOptionalField(writer, "pr_id", access.pr_id);
    try writeOptionalField(writer, "rule_id", access.rule_id);
    try writeOptionalField(writer, "context_id", access.context_id);
    if (!std.mem.eql(u8, access.error_code, "-")) {
        try writeField(writer, "error_code", access.error_code);
    }
    if (!std.mem.eql(u8, access.error_message, "-")) {
        try writeField(writer, "error_message", access.error_message);
    }
    try writer.writeByte('\n');
}

pub fn writeHubEventLine(writer: *std.Io.Writer, event: HubEvent) std.Io.Writer.Error!void {
    var ts_buf: [19]u8 = undefined;
    formatTimestamp(&ts_buf);
    try writer.print("{s} [EVENT] hub.{s} outcome={s}", .{ ts_buf, event.name, event.outcome });
    try writeOptionalField(writer, "action", event.action);
    try writeOptionalField(writer, "target_kind", event.target_kind);
    try writeOptionalField(writer, "actor_user_id", event.actor_user_id);
    try writeOptionalField(writer, "org_id", event.org_id);
    try writeOptionalField(writer, "ws_id", event.ws_id);
    try writeOptionalField(writer, "pr_id", event.pr_id);
    if (event.op_count) |op_count| {
        try writer.print(" op_count={d}", .{op_count});
    }
    try writer.writeByte('\n');
}

fn writeOptionalField(writer: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    if (value.len == 0 or std.mem.eql(u8, value, "-")) return;
    try writeField(writer, name, value);
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try writer.print(" {s}=", .{name});
    if (isBareLogValue(value)) {
        try writer.writeAll(value);
    } else {
        try writeQuotedValue(writer, value);
    }
}

fn isBareLogValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':' or byte == '/')) return false;
    }
    return true;
}

fn writeQuotedValue(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20 or byte == 0x7f) {
                try writer.writeByte('?');
            } else {
                try writer.writeByte(byte);
            },
        }
    }
    try writer.writeByte('"');
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
    rotate: bool,
    max_bytes: u64,
    backups: usize,
};

pub fn defaultEnvConfig() EnvConfig {
    return .{
        .level = .info,
        .invalid_level = null,
        .rotate = true,
        .max_bytes = DEFAULT_LOG_MAX_BYTES,
        .backups = DEFAULT_LOG_BACKUPS,
    };
}

pub fn configFromEnvMap(env_map: *const std.process.EnvMap) EnvConfig {
    var log_level: std.log.Level = .info;
    var invalid_level: ?[]const u8 = null;
    var rotate = true;
    var max_bytes = DEFAULT_LOG_MAX_BYTES;
    var backups = DEFAULT_LOG_BACKUPS;

    if (env_map.get("CLUMSIES_LOG_LEVEL")) |raw| {
        if (parseLevel(raw)) |parsed| {
            log_level = parsed;
        } else {
            invalid_level = raw;
        }
    }

    if (env_map.get("CLUMSIES_LOG_ROTATE")) |raw| {
        rotate = !isFalseEnvValue(raw);
    }

    if (env_map.get("CLUMSIES_LOG_MAX_BYTES")) |raw| {
        if (std.fmt.parseUnsigned(u64, raw, 10)) |parsed| {
            max_bytes = parsed;
        } else |_| {}
    }

    if (env_map.get("CLUMSIES_LOG_BACKUPS")) |raw| {
        if (std.fmt.parseUnsigned(usize, raw, 10)) |parsed| {
            backups = parsed;
        } else |_| {}
    }

    return .{
        .level = log_level,
        .invalid_level = invalid_level,
        .rotate = rotate,
        .max_bytes = max_bytes,
        .backups = backups,
    };
}

fn applyEnvLine(allocator: std.mem.Allocator, env_map: *std.process.EnvMap, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    const value = stripQuotes(raw_value);
    if (env_map.get(key) != null) return;

    const key_owned = allocator.dupe(u8, key) catch return;
    const val_owned = allocator.dupe(u8, value) catch {
        allocator.free(key_owned);
        return;
    };
    env_map.put(key_owned, val_owned) catch {
        allocator.free(key_owned);
        allocator.free(val_owned);
    };
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn levelColor(comptime level: std.log.Level) []const u8 {
    return comptime switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };
}

fn statusColor(status: u16) []const u8 {
    if (status >= 500) return "\x1b[97;41m";
    if (status >= 400) return "\x1b[30;43m";
    if (status >= 300) return "\x1b[30;47m";
    if (status >= 200) return "\x1b[30;42m";
    return "\x1b[30;46m";
}

fn methodColor(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "GET")) return "\x1b[97;44m";
    if (std.mem.eql(u8, method, "POST")) return "\x1b[30;46m";
    if (std.mem.eql(u8, method, "PUT")) return "\x1b[30;43m";
    if (std.mem.eql(u8, method, "DELETE")) return "\x1b[97;41m";
    if (std.mem.eql(u8, method, "PATCH")) return "\x1b[30;42m";
    if (std.mem.eql(u8, method, "HEAD")) return "\x1b[97;45m";
    return "\x1b[30;47m";
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

fn formatDuration(buf: *[16]u8, ns: i128) []const u8 {
    const value: u128 = @intCast(@max(ns, 0));
    var writer: std.Io.Writer = .fixed(buf);
    if (value < std.time.ns_per_us) {
        writer.print("{d}ns", .{value}) catch return "";
    } else if (value < std.time.ns_per_ms) {
        const us = value / std.time.ns_per_us;
        writer.print("{d}us", .{us}) catch return "";
    } else if (value < std.time.ns_per_s) {
        const hundredths = value / (std.time.ns_per_ms / 100);
        writer.print("{d}.{d:0>2}ms", .{ hundredths / 100, hundredths % 100 }) catch return "";
    } else {
        const hundredths = value / (std.time.ns_per_s / 100);
        writer.print("{d}.{d:0>2}s", .{ hundredths / 100, hundredths % 100 }) catch return "";
    }
    return writer.buffered();
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

fn rotateLogFileIfNeeded(path: []const u8, max_bytes: u64, backups: usize) !void {
    if (max_bytes == 0 or backups == 0) return;

    var current_date: [10]u8 = undefined;
    formatDateFromSeconds(&current_date, @intCast(@max(std.time.milliTimestamp(), 0) / 1000));

    var log_date: [10]u8 = undefined;
    const stat = blk: {
        var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;
        if (!readLogDate(file, &log_date)) {
            if (!formatDateFromNs(stat.mtime, &log_date)) {
                @memcpy(&log_date, &current_date);
            }
        }
        break :blk stat;
    };

    const archive_date = log_date[0..];
    const stale_date = !std.mem.eql(u8, archive_date, current_date[0..]);
    if (!stale_date and stat.size < max_bytes) return;

    const allocator = std.heap.page_allocator;
    const archive_path = try nextArchivePath(allocator, path, archive_date);
    defer allocator.free(archive_path);

    std.fs.renameAbsolute(path, archive_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try pruneLogArchives(allocator, path, backups);
}

fn readLogDate(file: std.fs.File, out: *[10]u8) bool {
    var buf: [10]u8 = undefined;
    var read_buf: [64]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &read_buf);
    reader.interface.readSliceAll(&buf) catch return false;
    if (!isDateStamp(buf[0..])) return false;
    @memcpy(out, &buf);
    return true;
}

fn formatDateFromNs(ns: i128, out: *[10]u8) bool {
    if (ns < 0) return false;
    const secs_i128 = @divFloor(ns, std.time.ns_per_s);
    const secs = std.math.cast(u64, secs_i128) orelse return false;
    formatDateFromSeconds(out, secs);
    return true;
}

fn formatDateFromSeconds(out: *[10]u8, secs: u64) void {
    const epoch_secs: epoch.EpochSeconds = .{ .secs = secs };
    const ed = epoch_secs.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();

    writeDigits4(out[0..4], yd.year);
    out[4] = '-';
    writeDigits2(out[5..7], md.month.numeric());
    out[7] = '-';
    writeDigits2(out[8..10], md.day_index + 1);
}

fn isDateStamp(value: []const u8) bool {
    if (value.len != 10) return false;
    return std.ascii.isDigit(value[0]) and
        std.ascii.isDigit(value[1]) and
        std.ascii.isDigit(value[2]) and
        std.ascii.isDigit(value[3]) and
        value[4] == '-' and
        std.ascii.isDigit(value[5]) and
        std.ascii.isDigit(value[6]) and
        value[7] == '-' and
        std.ascii.isDigit(value[8]) and
        std.ascii.isDigit(value[9]);
}

fn nextArchivePath(allocator: std.mem.Allocator, path: []const u8, date: []const u8) ![]u8 {
    var suffix: usize = 0;
    while (suffix < 10_000) : (suffix += 1) {
        const candidate = try archivePath(allocator, path, date, suffix);
        std.fs.accessAbsolute(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        allocator.free(candidate);
    }
    return error.NoAvailableArchiveName;
}

fn archivePath(allocator: std.mem.Allocator, path: []const u8, date: []const u8, suffix: usize) ![]u8 {
    const dir = std.fs.path.dirname(path);
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".log")) base[0 .. base.len - ".log".len] else base;
    const archive_name = if (suffix == 0)
        try std.fmt.allocPrint(allocator, "{s}-{s}.log", .{ stem, date })
    else
        try std.fmt.allocPrint(allocator, "{s}-{s}.{d}.log", .{ stem, date, suffix });
    defer allocator.free(archive_name);

    if (dir) |parent| return std.fs.path.join(allocator, &.{ parent, archive_name });
    return allocator.dupe(u8, archive_name);
}

fn pruneLogArchives(allocator: std.mem.Allocator, active_path: []const u8, backups: usize) !void {
    const dir_path = std.fs.path.dirname(active_path) orelse ".";
    const base = std.fs.path.basename(active_path);
    const stem = if (std.mem.endsWith(u8, base, ".log")) base[0 .. base.len - ".log".len] else base;
    const prefix = try std.fmt.allocPrint(allocator, "{s}-", .{stem});
    defer allocator.free(prefix);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var archives: std.ArrayList(LogArchive) = .empty;
    defer {
        for (archives.items) |item| allocator.free(item.name);
        archives.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        const stat = dir.statFile(entry.name) catch continue;
        try archives.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .mtime = stat.mtime,
        });
    }

    if (archives.items.len <= backups) return;
    std.mem.sort(LogArchive, archives.items, {}, logArchiveOlderThan);

    const remove_count = archives.items.len - backups;
    for (archives.items[0..remove_count]) |item| {
        dir.deleteFile(item.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

const LogArchive = struct {
    name: []u8,
    mtime: i128,
};

fn logArchiveOlderThan(_: void, lhs: LogArchive, rhs: LogArchive) bool {
    if (lhs.mtime != rhs.mtime) return lhs.mtime < rhs.mtime;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn isFalseEnvValue(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off");
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

test "writeHttpAccessLine omits application log prefix" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeHttpAccessLine(&writer, .{
        .status = 400,
        .elapsed_ns = 1_234_000,
        .ip = "127.0.0.1",
        .client_id = "client-1",
        .request_id = "req-1 error_code=OK",
        .method = "GET",
        .path = "/bad",
        .route = "unknown.read",
        .ws_id = "ws-1",
        .pr_id = "ppr-1",
        .target_user_id = "usr-1",
        .error_code = "BAD_REQUEST",
        .error_message = "bad \"value\"",
    }, false);
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "[WARN ]") == null);
    try testing.expect(std.mem.indexOf(u8, output, "(hub_request)") == null);
    try testing.expect(std.mem.indexOf(u8, output, "| 400 |   1.23ms | 127.0.0.1       |") != null);
    try testing.expect(std.mem.indexOf(u8, output, "client_id=client-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "request_id=\"req-1 error_code=OK\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "route=unknown.read") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ws_id=ws-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pr_id=ppr-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "target_user_id=usr-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "error_code=BAD_REQUEST") != null);
    try testing.expect(std.mem.indexOf(u8, output, "error_message=\"bad \\\"value\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "| GET    /bad") != null);
}

test "writeHubEventLine emits business event fields" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeHubEventLine(&writer, .{
        .name = "rule_pr.accepted",
        .action = "accept",
        .target_kind = "rule_pr",
        .actor_user_id = "usr-1",
        .org_id = "org-1",
        .ws_id = "ws-1",
        .pr_id = "ppr-1",
        .op_count = 3,
    });
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "[EVENT] hub.rule_pr.accepted outcome=ok") != null);
    try testing.expect(std.mem.indexOf(u8, output, "action=accept") != null);
    try testing.expect(std.mem.indexOf(u8, output, "target_kind=rule_pr") != null);
    try testing.expect(std.mem.indexOf(u8, output, "actor_user_id=usr-1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "op_count=3") != null);
}

test "writeHttpAccessLine colors only status and method" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeHttpAccessLine(&writer, .{
        .status = 200,
        .elapsed_ns = 7_917_000,
        .ip = "127.0.0.1",
        .client_id = "-",
        .request_id = "req-2",
        .method = "GET",
        .path = "/api/auth/me",
        .route = "auth.read",
    }, true);
    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[30;42m 200 \x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[97;44m  GET   \x1b[0m| /api/auth/me") != null);
    try testing.expect(std.mem.indexOf(u8, output, "|\x1b[30;42m 200 \x1b[0m|   7.91ms") != null);
    try testing.expect(std.mem.indexOf(u8, output, "127.0.0.1       ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "client_id=") == null);
    try testing.expect(std.mem.indexOf(u8, output, "request_id=req-2") != null);
}

test "formatDuration adapts units" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("999ns", formatDuration(&buf, 999));
    try testing.expectEqualStrings("742us", formatDuration(&buf, 742_000));
    try testing.expectEqualStrings("7.91ms", formatDuration(&buf, 7_917_000));
    try testing.expectEqualStrings("1.25s", formatDuration(&buf, 1_250_000_000));
}

test "clientDefaultLogPath uses local runtime logs directory" {
    const path = try clientDefaultLogPath(testing.allocator);
    defer testing.allocator.free(path);

    const suffix = try std.fs.path.join(testing.allocator, &.{ ".clumsies", "logs", "client.log" });
    defer testing.allocator.free(suffix);

    try testing.expect(std.mem.endsWith(u8, path, suffix));
}

test "file sink rotates stale dated client log on init" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "client.log", "2000-01-01 00:00:00 [INFO ] (test): old\n");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("client.log", &path_buf);

    try init(.{ .level = .info, .sink = .{ .file = path }, .max_bytes = 1024, .backups = 3 });
    defer deinit();

    try tmp.dir.access("client-2000-01-01.log", .{});
    try tmp.dir.access("client.log", .{});
}

test "file sink rotates oversized current client log on init" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var current_date: [10]u8 = undefined;
    formatDateFromSeconds(&current_date, @intCast(@max(std.time.milliTimestamp(), 0) / 1000));
    const content = try std.fmt.allocPrint(
        testing.allocator,
        "{s} 00:00:00 [INFO ] (test): oversized\n",
        .{current_date},
    );
    defer testing.allocator.free(content);
    try writeTestFile(tmp.dir, "client.log", content);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("client.log", &path_buf);

    try init(.{ .level = .info, .sink = .{ .file = path }, .max_bytes = 8, .backups = 3 });
    defer deinit();

    const archive_name = try std.fmt.allocPrint(testing.allocator, "client-{s}.log", .{current_date});
    defer testing.allocator.free(archive_name);
    try tmp.dir.access(archive_name, .{});
    try tmp.dir.access("client.log", .{});
}

fn writeTestFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = std.fs.File.Writer.init(file, &write_buf);
    defer fw.interface.flush() catch {};
    try fw.interface.writeAll(content);
}
