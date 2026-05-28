//! Workspace access helpers for built-in tools.
//!
//! Built-in tools receive model-provided paths, but the model must not choose
//! the filesystem root. This module centralizes the workspace root, read
//! limits, path traversal checks, and the small glob matcher used by the first
//! read-only tools.

const std = @import("std");
const path_util = @import("../../util/path_util.zig");

/// Runtime workspace bounds shared by built-in tools.
pub const Context = struct {
    workspace_path: []const u8 = ".",
    max_read_bytes: usize = 64 * 1024,
    max_matches: usize = 100,
};

/// Opens the configured workspace without letting tool arguments choose a root.
pub fn open(context: Context) !std.fs.Dir {
    if (std.fs.path.isAbsolute(context.workspace_path)) {
        return std.fs.openDirAbsolute(context.workspace_path, .{});
    }
    return std.fs.cwd().openDir(context.workspace_path, .{});
}

/// Rejects absolute paths and traversal before joining with the workspace root.
pub fn ensureSafePath(path: []const u8) !void {
    if (!path_util.isSafeRelative(path)) return error.UnsafePath;
}

/// Minimal glob matcher used by the first built-in read-only tools.
///
/// It intentionally supports only `*` and `?`; richer gitignore-aware matching
/// can replace this helper later without changing each tool's public schema.
pub fn matchesGlob(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (pattern[0] == '*') {
        return matchesGlob(pattern[1..], path) or
            (path.len > 0 and matchesGlob(pattern, path[1..]));
    }
    if (path.len == 0) return false;
    if (pattern[0] == '?' or pattern[0] == path[0]) {
        return matchesGlob(pattern[1..], path[1..]);
    }
    return false;
}
