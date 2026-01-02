const std = @import("std");
const fs = std.fs;
const styles = @import("../styles.zig");

pub const Color = styles.Color;
pub const P = styles.P;

// Re-export all commands
pub const help = @import("help.zig");
pub const search = @import("search.zig");
pub const detail = @import("detail.zig");
pub const use = @import("use.zig");
pub const install = @import("install.zig");
pub const upgrade = @import("upgrade.zig");
pub const zen = @import("zen.zig");

// Shared types
pub const Language = enum { en, zh };

pub const WriteResult = struct {
    written: bool,
    skipped: bool,
};

// Shared utilities
pub fn getRegistryPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);
    return try std.fs.path.join(allocator, &.{ home_dir, ".clumsies", "registry" });
}

pub fn writeFile(dir: fs.Dir, path: []const u8, content: []const u8, force: bool, stdout: anytype, stderr: anytype) WriteResult {
    const file_exists = blk: {
        dir.access(path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            break :blk true;
        };
        break :blk true;
    };

    if (file_exists and !force) {
        stdout.print("{s}  {s}skip:{s} {s} {s}(exists, use --force){s}\n", .{ P, Color.dim, Color.reset, path, Color.dim, Color.reset }) catch {};
        return .{ .written = false, .skipped = true };
    }

    const file = dir.createFile(path, .{}) catch |err| {
        stderr.print("{s}{s}{s}Error:{s} creating file '{s}': {}\n", .{ P, Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        stderr.print("{s}{s}{s}Error:{s} writing file '{s}': {}\n", .{ P, Color.bold, Color.red, Color.reset, path, err }) catch {};
        return .{ .written = false, .skipped = false };
    };

    if (file_exists) {
        stdout.print("{s}  {s}{s}overwrite:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, path }) catch {};
    } else {
        stdout.print("{s}  {s}{s}create:{s} {s}\n", .{ P, Color.bold, Color.orange, Color.reset, path }) catch {};
    }

    return .{ .written = true, .skipped = false };
}
