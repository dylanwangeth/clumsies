const std = @import("std");
const fs = std.fs;
const styles = @import("../styles.zig");
const git = @import("../git.zig");
const spinner = @import("../spinner.zig");
const config = @import("config.zig");

pub const Color = styles.Color;
pub const P = styles.P;
pub const GitOutput = git.GitOutput;

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

/// Print git output in unified format
/// Shows both stdout and stderr with dim styling
pub fn printGitOutput(writer: anytype, output: *const GitOutput) void {
    const has_stdout = output.stdout != null and output.stdout.?.len > 0;
    const has_stderr = output.stderr != null and output.stderr.?.len > 0;

    if (!has_stdout and !has_stderr) return;

    writer.print("{s}{s}git:{s}\n", .{ P, Color.dim, Color.reset }) catch return;

    if (has_stdout) {
        const stdout_content = std.mem.trim(u8, output.stdout.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stdout_content, '\n');
        while (lines.next()) |line| {
            writer.print("{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch return;
        }
    }

    if (has_stderr) {
        const stderr_content = std.mem.trim(u8, output.stderr.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stderr_content, '\n');
        while (lines.next()) |line| {
            writer.print("{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch return;
        }
    }
}

/// Print git output using raw stdout (for use after spinner)
pub fn printGitOutputRaw(output: *const GitOutput) void {
    const has_stdout = output.stdout != null and output.stdout.?.len > 0;
    const has_stderr = output.stderr != null and output.stderr.?.len > 0;

    if (!has_stdout and !has_stderr) return;

    const raw_stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;

    const header = std.fmt.bufPrint(&buf, "{s}{s}git:{s}\n", .{ P, Color.dim, Color.reset }) catch return;
    _ = raw_stdout.write(header) catch return;

    if (has_stdout) {
        const stdout_content = std.mem.trim(u8, output.stdout.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stdout_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }

    if (has_stderr) {
        const stderr_content = std.mem.trim(u8, output.stderr.?, "\n\r ");
        var lines = std.mem.splitScalar(u8, stderr_content, '\n');
        while (lines.next()) |line| {
            const formatted = std.fmt.bufPrint(&buf, "{s}  {s}{s}{s}\n", .{ P, Color.dim, line, Color.reset }) catch continue;
            _ = raw_stdout.write(formatted) catch continue;
        }
    }
}

/// Ensure registry exists, optionally sync with remote
/// Caller must free the returned path
/// If sync=false and registry exists locally, skip network operations (fast path)
/// If registry doesn't exist, always clones regardless of sync flag
pub fn ensureRegistry(stdout: anytype, stderr: anytype, allocator: std.mem.Allocator, sync: bool) ![]const u8 {
    const registry_info = config.getRegistryInfo(allocator) catch {
        try stderr.print("\n{s}{s}{s}Error:{s} Registry not configured\n", .{ P, Color.bold, Color.red, Color.reset });
        try stderr.print("{s}Run: {s}clumsies config set registry <git-url>{s}\n\n", .{ P, Color.cyan, Color.reset });
        try stderr.print("{s}Tip: Use {s}<git-url>#<branch>{s} to specify a branch\n\n", .{ P, Color.cyan, Color.reset });
        return error.NoRegistry;
    };
    defer registry_info.deinit(allocator);

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

    if (!registry_exists) {
        // Registry doesn't exist - must clone (requires network)
        const stdout_raw = std.fs.File.stdout();
        _ = stdout_raw.write("\n") catch {};

        var sp = spinner.init(stdout, "Fetching registry");
        sp.start();
        fs.cwd().makePath(base_path) catch {};
        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        git.cloneWithBranch(allocator, registry_info.url, registry_path, registry_info.branch, &git_output) catch {
            sp.fail();
            printGitOutputRaw(&git_output);
            try stderr.print("{s}{s}{s}Error:{s} Failed to clone registry\n\n", .{ P, Color.bold, Color.red, Color.reset });
            return error.CloneFailed;
        };
        sp.succeed();
        printGitOutputRaw(&git_output);
    } else if (sync) {
        // Registry exists and sync requested - pull latest
        const stdout_raw = std.fs.File.stdout();
        _ = stdout_raw.write("\n") catch {};

        var sp = spinner.init(stdout, "Syncing registry");
        sp.start();

        var git_output: GitOutput = .{};
        defer git_output.deinit(allocator);

        // If branch specified, ensure we're on correct branch
        if (registry_info.branch) |branch| {
            var checkout_output: GitOutput = .{};
            defer checkout_output.deinit(allocator);
            git.fetchAndCheckout(allocator, registry_path, branch, &checkout_output) catch {};
        }
        git.pull(allocator, registry_path, &git_output) catch {};
        sp.succeed();
        printGitOutputRaw(&git_output);
    }
    // else: registry exists and no sync requested - use local cache (fast path)

    return registry_path;
}

/// Sync meta-prompt files between directories
/// If delete_source is true, removes source file after copy (move semantics)
/// If dest exists and delete_source is true, creates .remote.md version instead
pub fn syncMetaPromptFiles(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8, delete_source: bool) void {
    const entry_files_str = config.getEntryFilesStr(allocator) catch null;
    defer if (entry_files_str) |s| allocator.free(s);

    if (entry_files_str) |ef_str| {
        var iter = std.mem.splitSequence(u8, ef_str, ",");
        while (iter.next()) |entry_file| {
            const trimmed = std.mem.trim(u8, entry_file, " ");
            if (trimmed.len == 0) continue;
            syncSingleFile(allocator, src_dir, dest_dir, trimmed, delete_source);
        }
    } else {
        for (config.DEFAULT_ENTRY_FILES) |entry_file| {
            syncSingleFile(allocator, src_dir, dest_dir, entry_file, delete_source);
        }
    }
}

fn syncSingleFile(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8, filename: []const u8, create_remote_on_conflict: bool) void {
    const src = std.fs.path.join(allocator, &.{ src_dir, filename }) catch return;
    defer allocator.free(src);

    // Check if source exists
    fs.accessAbsolute(src, .{}) catch return;

    const dest = std.fs.path.join(allocator, &.{ dest_dir, filename }) catch return;
    defer allocator.free(dest);

    // Check if dest already exists
    const dest_exists = blk: {
        fs.accessAbsolute(dest, .{}) catch break :blk false;
        break :blk true;
    };

    if (dest_exists) {
        // Compare content - if same, do nothing
        if (filesAreEqual(allocator, src, dest)) {
            return;
        }

        // Content differs
        if (create_remote_on_conflict) {
            // Pull: create .remote.md for user to review, don't touch dest
            const remote_name = generateRemoteName(allocator, filename) catch return;
            defer allocator.free(remote_name);
            const remote_dest = std.fs.path.join(allocator, &.{ dest_dir, remote_name }) catch return;
            defer allocator.free(remote_dest);
            fs.copyFileAbsolute(src, remote_dest, .{}) catch return;
        } else {
            // Push: overwrite dest with src
            fs.copyFileAbsolute(src, dest, .{}) catch return;
        }
    } else {
        // Dest doesn't exist, just copy
        fs.copyFileAbsolute(src, dest, .{}) catch return;
    }
    // Never delete source - keep .prompts/ in sync with git
}

fn filesAreEqual(allocator: std.mem.Allocator, path1: []const u8, path2: []const u8) bool {
    const file1 = fs.openFileAbsolute(path1, .{}) catch return false;
    defer file1.close();
    const file2 = fs.openFileAbsolute(path2, .{}) catch return false;
    defer file2.close();

    const content1 = file1.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return false;
    defer allocator.free(content1);
    const content2 = file2.readToEndAlloc(allocator, MAX_FILE_SIZE) catch return false;
    defer allocator.free(content2);

    return std.mem.eql(u8, content1, content2);
}

fn generateRemoteName(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    // CLAUDE.md -> CLAUDE.remote.md
    // foo.bar.md -> foo.bar.remote.md
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_idx| {
        const name = filename[0..dot_idx];
        const ext = filename[dot_idx..];
        return std.fmt.allocPrint(allocator, "{s}.remote{s}", .{ name, ext });
    }
    // No extension, just append .remote
    return std.fmt.allocPrint(allocator, "{s}.remote", .{filename});
}
