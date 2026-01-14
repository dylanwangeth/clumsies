const std = @import("std");
const fs = std.fs;
const styles = @import("../styles.zig");
const git = @import("../git.zig");
const spinner = @import("../spinner.zig");
const config = @import("config.zig");

pub const Color = styles.Color;
pub const P = styles.P;

// Shared constants
pub const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
pub const MAX_SEQUENCE_NUMBER: u8 = 99;

// Frontmatter metadata structure
pub const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    task: ?[]const u8 = null,
};

/// Parse YAML frontmatter from markdown content
pub fn parseFrontmatter(content: []const u8) Frontmatter {
    var fm = Frontmatter{};

    // Check for frontmatter delimiter
    if (!std.mem.startsWith(u8, content, "---")) return fm;

    // Find end delimiter
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "\n---") orelse return fm;
    const frontmatter_block = rest[0..end_idx];

    // Parse line by line
    var lines = std.mem.splitScalar(u8, frontmatter_block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.name = value;
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            const value = std.mem.trim(u8, trimmed[12..], " \t");
            if (value.len > 0) fm.description = value;
        } else if (std.mem.startsWith(u8, trimmed, "category:")) {
            const value = std.mem.trim(u8, trimmed[9..], " \t");
            if (value.len > 0) fm.category = value;
        } else if (std.mem.startsWith(u8, trimmed, "task:")) {
            const value = std.mem.trim(u8, trimmed[5..], " \t");
            if (value.len > 0) fm.task = value;
        }
    }

    return fm;
}

/// Strip sequence prefix (NN_) from filename if present
/// e.g., "01_review_commit" -> "review_commit"
pub fn stripSequencePrefix(name: []const u8) []const u8 {
    if (name.len >= 3 and name[2] == '_') {
        // Check if first two chars are digits
        if (std.ascii.isDigit(name[0]) and std.ascii.isDigit(name[1])) {
            return name[3..];
        }
    }
    return name;
}

/// Encode bytes to hexadecimal string
pub fn hexEncode(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

/// Find next available sequence number with gap filling
/// If files 00_, 01_, 03_ exist, returns 2 (fills the gap)
/// If files 00_, 01_, 02_ exist, returns 3 (next number)
pub fn findNextSequence(dir_path: []const u8) u8 {
    var used: [100]bool = [_]bool{false} ** 100;
    var max_seq: u8 = 0;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        // Parse sequence number from filename (NN_...)
        if (entry.name.len < 3) continue;
        if (entry.name[2] != '_') continue;

        const seq = std.fmt.parseInt(u8, entry.name[0..2], 10) catch continue;
        if (seq < 100) {
            used[seq] = true;
            if (seq >= max_seq) max_seq = seq + 1;
        }
    }

    // Find first gap
    var i: u8 = 0;
    while (i < max_seq) : (i += 1) {
        if (!used[i]) return i;
    }

    // No gap found, return next number (capped at MAX_SEQUENCE_NUMBER)
    return if (max_seq > MAX_SEQUENCE_NUMBER) MAX_SEQUENCE_NUMBER else max_seq;
}

pub fn getPromptsPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".prompts" });
}

pub fn getBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".clumsies" });
}

pub fn promptsExist() bool {
    var dir = std.fs.cwd().openDir(".prompts", .{}) catch return false;
    dir.close();
    return true;
}

pub fn promptsIsGitRepo() bool {
    var dir = std.fs.cwd().openDir(".prompts/.git", .{}) catch return false;
    dir.close();
    return true;
}

/// Format timestamp to ISO date string (YYYY-MM-DD)
pub fn formatDate(timestamp: i64, buf: *[10]u8) []const u8 {
    const epoch_seconds: u64 = @intCast(if (timestamp < 0) 0 else timestamp);
    const days_since_epoch = epoch_seconds / 86400;

    // Simple date calculation
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        const days_in_year: u64 = if (is_leap) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    const days_in_months = [_]u8{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |days| {
        if (remaining_days < days) break;
        remaining_days -= days;
        month += 1;
    }

    const day: u8 = @intCast(remaining_days + 1);

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return "0000-00-00";
    return buf[0..10];
}

/// Ensure registry is cloned and synced, returns registry path
/// Caller must free the returned path
pub fn ensureRegistry(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator) ![]const u8 {
    const registry_url = config.getRegistry(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        return error.NoRegistry;
    };
    defer allocator.free(registry_url);

    const base_path = getBasePath(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Could not determine config path\n\n", .{ P, Color.bold, Color.red, Color.reset });
        return error.NoBasePath;
    };
    defer allocator.free(base_path);

    const registry_path = try std.fs.path.join(allocator, &.{ base_path, "registry" });
    errdefer allocator.free(registry_path);

    const registry_exists = blk: {
        var dir = fs.openDirAbsolute(registry_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    // Print leading newline for spinner output
    const stdout_raw = std.fs.File.stdout();
    _ = stdout_raw.write("\n") catch {};

    if (!registry_exists) {
        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        git.clone(allocator, registry_url, registry_path) catch {
            sp.fail();
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return error.CloneFailed;
        };
        sp.succeed();
    } else {
        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();
        var git_err: ?[]const u8 = null;
        git.pull(allocator, registry_path, &git_err) catch {
            // Log warning but don't fail - local cache may still be usable
            if (git_err) |e| allocator.free(e);
        };
        sp.succeed();
    }

    return registry_path;
}

/// Sync meta-prompt files between directories
pub fn syncMetaPromptFiles(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) void {
    const entry_files_str = config.getEntryFilesStr(allocator) catch null;
    defer if (entry_files_str) |s| allocator.free(s);

    if (entry_files_str) |ef_str| {
        var iter = std.mem.splitSequence(u8, ef_str, ",");
        while (iter.next()) |entry_file| {
            const trimmed = std.mem.trim(u8, entry_file, " ");
            if (trimmed.len == 0) continue;

            const src = std.fs.path.join(allocator, &.{ src_dir, trimmed }) catch continue;
            defer allocator.free(src);
            const dest = std.fs.path.join(allocator, &.{ dest_dir, trimmed }) catch continue;
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    } else {
        for (config.DEFAULT_ENTRY_FILES) |entry_file| {
            const src = std.fs.path.join(allocator, &.{ src_dir, entry_file }) catch continue;
            defer allocator.free(src);
            const dest = std.fs.path.join(allocator, &.{ dest_dir, entry_file }) catch continue;
            defer allocator.free(dest);

            fs.copyFileAbsolute(src, dest, .{}) catch continue;
        }
    }
}
