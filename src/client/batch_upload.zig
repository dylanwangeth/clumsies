//! Batch upload mechanism for attestation events. Reads per-session attestation logs in
//! bounded batches, tracks cursor files to avoid re-uploading, and posts each batch via
//! an injected uploader function. Cursors persist across process restarts.
const std = @import("std");
const testing = std.testing;
const attestation = @import("attestation.zig");

const log = std.log.scoped(.attestation_upload);

pub const FlushResult = struct {
    events_read: usize = 0,
    events_sent: usize = 0,
    batches_sent: usize = 0,
};

pub const FlushError = error{
    ReadTraceFailed,
    ReadCursorFailed,
    WriteCursorFailed,
    ParseCursorFailed,
    NotAuthenticated,
    UploadFailed,
    OutOfMemory,
};

pub const MAX_EVENTS_PER_BATCH: usize = 1000;
pub const MAX_BYTES_PER_BATCH: usize = 512 * 1024;
/// Hard upper bound on a single event's size. The hub server rejects bodies
/// larger than 1 MB, so any single event above ~900 KB can never be uploaded
/// successfully. Such events are logged and skipped so the pipeline cannot be
/// wedged by a malformed or pathologically large attestation line.
pub const MAX_SINGLE_EVENT_BYTES: usize = 900 * 1024;

/// A single batch collected from an attestation log, ready to POST as
/// {"events":[line1, line2, ...]} to /api/attestations.
pub const Batch = struct {
    lines: std.ArrayList([]const u8),
    total_bytes: usize,
    end_offset: u64,

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit(allocator);
    }
};

/// Upload helper injected by callers. flushOnce is agnostic to the transport
/// so the library can be tested without a live hub server. Implementations
/// should POST {"events": [...]} to /api/attestations and return true on 2xx.
pub const Uploader = struct {
    ctx: *anyopaque,
    postFn: *const fn (ctx: *anyopaque, body: []const u8) anyerror!bool,

    pub fn post(self: Uploader, body: []const u8) !bool {
        return self.postFn(self.ctx, body);
    }
};

/// Flush pending attestation events for a workspace to the hub server.
///
/// Cursor semantics: byte offset into each attestation log. A successful batch POST
/// advances the cursor atomically via temp file + rename. Network failures
/// leave the cursor untouched so the next run replays the same bytes.
/// Duplicate events are deduplicated server-side via ON CONFLICT.
pub fn flushOnce(
    allocator: std.mem.Allocator,
    ws_id: []const u8,
    uploader: Uploader,
) FlushError!FlushResult {
    var result: FlushResult = .{};

    const log_dir = attestation.attestationLogDirPath(allocator, ws_id) catch return error.OutOfMemory;
    defer allocator.free(log_dir);
    if (std.fs.openDirAbsolute(log_dir, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch return error.ReadTraceFailed) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            const path = std.fs.path.join(allocator, &.{ log_dir, entry.name }) catch return error.OutOfMemory;
            defer allocator.free(path);

            const session_id = entry.name[0 .. entry.name.len - ".jsonl".len];
            const cursor_path = attestation.sessionCursorFilePath(allocator, ws_id, session_id) catch return error.OutOfMemory;
            defer allocator.free(cursor_path);

            const partial = try flushLogFile(allocator, path, cursor_path, uploader);
            result.events_read += partial.events_read;
            result.events_sent += partial.events_sent;
            result.batches_sent += partial.batches_sent;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.ReadTraceFailed,
    }

    const legacy_path = attestation.attestationFilePath(allocator, ws_id) catch return error.OutOfMemory;
    defer allocator.free(legacy_path);
    const legacy_cursor_path = attestation.cursorFilePath(allocator, ws_id) catch return error.OutOfMemory;
    defer allocator.free(legacy_cursor_path);
    const legacy = try flushLogFile(allocator, legacy_path, legacy_cursor_path, uploader);
    result.events_read += legacy.events_read;
    result.events_sent += legacy.events_sent;
    result.batches_sent += legacy.batches_sent;

    return result;
}

fn flushLogFile(
    allocator: std.mem.Allocator,
    attestation_path: []const u8,
    cursor_path: []const u8,
    uploader: Uploader,
) FlushError!FlushResult {
    var result: FlushResult = .{};

    const start_offset = readCursorPath(allocator, cursor_path) catch |err| switch (err) {
        error.FileNotFound => 0,
        error.ParseCursorFailed => return error.ParseCursorFailed,
        else => return error.ReadCursorFailed,
    };

    var file = std.fs.openFileAbsolute(attestation_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return error.ReadTraceFailed,
    };
    defer file.close();

    const stat = file.stat() catch return error.ReadTraceFailed;
    if (start_offset >= stat.size) return result;

    file.seekTo(start_offset) catch return error.ReadTraceFailed;

    var read_buf: [8192]u8 = undefined;
    var reader = std.fs.File.Reader.initSize(file, &read_buf, stat.size);

    var cursor_offset: u64 = start_offset;

    while (true) {
        var batch = collectBatch(allocator, &reader.interface, cursor_offset) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadTraceFailed,
        };
        defer batch.deinit(allocator);

        if (batch.end_offset == cursor_offset) break;

        if (batch.lines.items.len > 0) {
            result.events_read += batch.lines.items.len;

            const body = buildBatchBody(allocator, batch.lines.items) catch return error.OutOfMemory;
            defer allocator.free(body);

            const ok = uploader.post(body) catch return error.UploadFailed;
            if (!ok) return error.UploadFailed;

            result.events_sent += batch.lines.items.len;
            result.batches_sent += 1;
        }

        cursor_offset = batch.end_offset;
        writeCursorPath(allocator, cursor_path, cursor_offset) catch return error.WriteCursorFailed;

        if (cursor_offset >= stat.size) break;
    }

    return result;
}

fn collectBatch(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    start_offset: u64,
) !Batch {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var total_bytes: usize = 0;
    var end_offset: u64 = start_offset;

    while (lines.items.len < MAX_EVENTS_PER_BATCH) {
        const raw = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const trimmed = std.mem.trim(u8, raw, " \t\r");
        const line_bytes = raw.len + 1;
        if (trimmed.len == 0) {
            end_offset += line_bytes;
            continue;
        }

        if (trimmed.len > MAX_SINGLE_EVENT_BYTES) {
            log.warn(
                "dropping oversized attestation event at offset {d}: {d} bytes exceeds {d} limit",
                .{ end_offset, trimmed.len, MAX_SINGLE_EVENT_BYTES },
            );
            end_offset += line_bytes;
            continue;
        }

        const projected = total_bytes + trimmed.len + 1;
        if (projected > MAX_BYTES_PER_BATCH) {
            if (lines.items.len > 0) break;

            log.warn(
                "dropping attestation event at offset {d}: {d} bytes exceeds {d} batch budget",
                .{ end_offset, trimmed.len, MAX_BYTES_PER_BATCH },
            );
            end_offset += line_bytes;
            continue;
        }

        const owned = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(owned);
        try lines.append(allocator, owned);
        total_bytes = projected;
        end_offset += line_bytes;
    }

    return .{
        .lines = lines,
        .total_bytes = total_bytes,
        .end_offset = end_offset,
    };
}

fn buildBatchBody(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"events\":[");
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, line);
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn readCursorPath(_: std.mem.Allocator, cursor_path: []const u8) !u64 {
    var file = try std.fs.openFileAbsolute(cursor_path, .{});
    defer file.close();

    var buf: [32]u8 = undefined;
    var r = std.fs.File.Reader.init(file, &buf);
    var small: [32]u8 = undefined;
    const n = r.interface.readSliceShort(&small) catch return error.ReadCursorFailed;
    const text = std.mem.trim(u8, small[0..n], " \t\r\n");
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u64, text, 10) catch error.ParseCursorFailed;
}

fn writeCursorPath(allocator: std.mem.Allocator, cursor_path: []const u8, offset: u64) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cursor_path});
    defer allocator.free(tmp_path);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        var buf: [32]u8 = undefined;
        var w = std.fs.File.Writer.init(file, &buf);
        try w.interface.print("{d}\n", .{offset});
        try w.interface.flush();
    }

    try std.fs.renameAbsolute(tmp_path, cursor_path);
}

const TestUploader = struct {
    captured: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    should_fail: bool = false,

    fn post(ctx: *anyopaque, body: []const u8) !bool {
        const self: *TestUploader = @ptrCast(@alignCast(ctx));
        if (self.should_fail) return false;
        const copy = try self.allocator.dupe(u8, body);
        try self.captured.append(self.allocator, copy);
        return true;
    }

    fn uploader(self: *TestUploader) Uploader {
        return .{
            .ctx = @ptrCast(self),
            .postFn = TestUploader.post,
        };
    }
};

test "buildBatchBody wraps lines in events array" {
    const lines = [_][]const u8{
        "{\"ws_id\":\"w\",\"session_id\":\"s\",\"event_id\":0,\"type\":\"setup\",\"timestamp\":1}",
        "{\"ws_id\":\"w\",\"session_id\":\"s\",\"event_id\":1,\"type\":\"refer\",\"timestamp\":2}",
    };
    const body = try buildBatchBody(testing.allocator, &lines);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "{\"events\":["));
    try testing.expect(std.mem.endsWith(u8, body, "]}"));
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"refer\"") != null);
    const comma_count = std.mem.count(u8, body, "},{");
    try testing.expectEqual(@as(usize, 1), comma_count);
}

test "collectBatch stops at event count limit" {
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(testing.allocator);
    var i: usize = 0;
    while (i < MAX_EVENTS_PER_BATCH + 5) : (i += 1) {
        try sample.writer(testing.allocator).print("line-{d}\n", .{i});
    }

    var reader = std.Io.Reader.fixed(sample.items);
    var batch = try collectBatch(testing.allocator, &reader, 0);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(MAX_EVENTS_PER_BATCH, batch.lines.items.len);
}

test "collectBatch stops at byte budget" {
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(testing.allocator);
    const chunk = "x" ** 1024;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        try sample.writer(testing.allocator).print("{s}\n", .{chunk});
    }

    var reader = std.Io.Reader.fixed(sample.items);
    var batch = try collectBatch(testing.allocator, &reader, 0);
    defer batch.deinit(testing.allocator);

    try testing.expect(batch.lines.items.len < 600);
    try testing.expect(batch.total_bytes <= MAX_BYTES_PER_BATCH);
}

test "collectBatch skips blank lines without counting them" {
    const sample = "a\n\nb\n";
    var reader = std.Io.Reader.fixed(sample);
    var batch = try collectBatch(testing.allocator, &reader, 100);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), batch.lines.items.len);
    try testing.expectEqualStrings("a", batch.lines.items[0]);
    try testing.expectEqualStrings("b", batch.lines.items[1]);
    // end_offset advances past every byte consumed from the reader
    // (including the blank line's newline); only the emitted lines
    // count is reduced by the blank-skip logic.
    try testing.expectEqual(@as(u64, 100 + sample.len), batch.end_offset);
}

test "collectBatch drops oversized event and keeps neighbors" {
    const huge = "x" ** (MAX_SINGLE_EVENT_BYTES + 100);
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(testing.allocator);
    try sample.writer(testing.allocator).print("ok1\n{s}\nok2\n", .{huge});

    var reader = std.Io.Reader.fixed(sample.items);
    var batch = try collectBatch(testing.allocator, &reader, 0);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), batch.lines.items.len);
    try testing.expectEqualStrings("ok1", batch.lines.items[0]);
    try testing.expectEqualStrings("ok2", batch.lines.items[1]);
    const expected_end: u64 = 4 + huge.len + 1 + 4;
    try testing.expectEqual(expected_end, batch.end_offset);
}

test "collectBatch advances offset when only oversized events are present" {
    const huge = "x" ** (MAX_SINGLE_EVENT_BYTES + 100);
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(testing.allocator);
    try sample.writer(testing.allocator).print("{s}\n", .{huge});

    var reader = std.Io.Reader.fixed(sample.items);
    var batch = try collectBatch(testing.allocator, &reader, 50);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), batch.lines.items.len);
    try testing.expectEqual(@as(u64, 50 + huge.len + 1), batch.end_offset);
}

test "collectBatch drops first event when it exceeds batch budget" {
    const too_large = "x" ** MAX_BYTES_PER_BATCH;
    var sample: std.ArrayList(u8) = .empty;
    defer sample.deinit(testing.allocator);
    try sample.writer(testing.allocator).print("{s}\nok\n", .{too_large});

    var reader = std.Io.Reader.fixed(sample.items);
    var batch = try collectBatch(testing.allocator, &reader, 10);
    defer batch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), batch.lines.items.len);
    try testing.expectEqualStrings("ok", batch.lines.items[0]);
    try testing.expect(batch.total_bytes <= MAX_BYTES_PER_BATCH);
    try testing.expectEqual(@as(u64, 10 + too_large.len + 1 + 3), batch.end_offset);
}
