const std = @import("std");
const testing = std.testing;

pub const MAX_SEQUENCE_NUMBER: u8 = 99;

/// Strip sequence prefix (NN_) from filename if present.
pub fn stripSequencePrefix(name: []const u8) []const u8 {
    if (name.len >= 3 and name[2] == '_') {
        if (std.ascii.isDigit(name[0]) and std.ascii.isDigit(name[1])) {
            return name[3..];
        }
    }
    return name;
}

/// Find next available sequence number with gap filling.
pub fn findNextSequence(dir_path: []const u8) u8 {
    var used: [100]bool = [_]bool{false} ** 100;
    var max_seq: u8 = 0;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len < 3) continue;
        if (entry.name[2] != '_') continue;

        const seq = std.fmt.parseInt(u8, entry.name[0..2], 10) catch continue;
        if (seq < 100) {
            used[seq] = true;
            if (seq >= max_seq) max_seq = seq + 1;
        }
    }

    var i: u8 = 0;
    while (i < max_seq) : (i += 1) {
        if (!used[i]) return i;
    }

    return if (max_seq > MAX_SEQUENCE_NUMBER) MAX_SEQUENCE_NUMBER else max_seq;
}

test "stripSequencePrefix: normal prefix" {
    try testing.expectEqualStrings("REVIEW_COMMIT", stripSequencePrefix("01_REVIEW_COMMIT"));
}

test "stripSequencePrefix: high number" {
    try testing.expectEqualStrings("FOO", stripSequencePrefix("99_FOO"));
}

test "stripSequencePrefix: non-digit prefix unchanged" {
    try testing.expectEqualStrings("AB_FOO", stripSequencePrefix("AB_FOO"));
}

test "stripSequencePrefix: too short unchanged" {
    try testing.expectEqualStrings("1_", stripSequencePrefix("1_"));
}

test "stripSequencePrefix: empty string" {
    try testing.expectEqualStrings("", stripSequencePrefix(""));
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "findNextSequence: empty directory returns 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(@as(u8, 0), findNextSequence(path));
}

test "findNextSequence: one file returns next" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile("00_FOO.md", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(@as(u8, 1), findNextSequence(path));
}

test "findNextSequence: gap filling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile("00_A.md", .{});
    _ = try tmp.dir.createFile("01_B.md", .{});
    _ = try tmp.dir.createFile("03_D.md", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(@as(u8, 2), findNextSequence(path));
}

test "findNextSequence: contiguous returns next" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile("00_A.md", .{});
    _ = try tmp.dir.createFile("01_B.md", .{});
    _ = try tmp.dir.createFile("02_C.md", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(@as(u8, 3), findNextSequence(path));
}

test "findNextSequence: ignores non-prefixed files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try tmp.dir.createFile("README.md", .{});
    _ = try tmp.dir.createFile("notes.txt", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);
    try testing.expectEqual(@as(u8, 0), findNextSequence(path));
}

test "findNextSequence: nonexistent directory returns 0" {
    try testing.expectEqual(@as(u8, 0), findNextSequence("/tmp/clumsies_nonexistent_dir_test"));
}
