//! Path safety: rejects relative paths that escape their base directory via ".." or absolute
//! paths. Used to validate rule paths and context file paths from untrusted input.
const std = @import("std");
const testing = std.testing;

/// Return true if `name` is a safe relative path that does not escape its
/// base directory. Rejects absolute paths and any path containing a `..`
/// component (using either the platform separator or forward slashes).
///
/// Callers should use this before joining a user- or manifest-provided
/// relative path onto a controlled base directory.
pub fn isSafeRelative(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.fs.path.isAbsolute(name)) return false;

    var it = std.mem.splitScalar(u8, name, std.fs.path.sep);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    if (std.fs.path.sep != '/') {
        var it2 = std.mem.splitScalar(u8, name, '/');
        while (it2.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return false;
        }
    }
    return true;
}

test "isSafeRelative rejects traversal" {
    try testing.expect(!isSafeRelative("../etc/passwd"));
    try testing.expect(!isSafeRelative("foo/../bar"));
    try testing.expect(!isSafeRelative(".."));
}

test "isSafeRelative rejects absolute paths" {
    try testing.expect(!isSafeRelative("/etc/passwd"));
}

test "isSafeRelative rejects empty" {
    try testing.expect(!isSafeRelative(""));
}

test "isSafeRelative accepts plain relative paths" {
    try testing.expect(isSafeRelative("rule/coding/STYLE.md"));
    try testing.expect(isSafeRelative("project-notes.md"));
    try testing.expect(isSafeRelative("workflow/cmd/COMMIT.md"));
}
