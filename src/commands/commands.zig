const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const styles = @import("../styles.zig");
const git = @import("../git.zig");

// Sub-modules
const frontmatter_mod = @import("frontmatter.zig");
const sequence_mod = @import("sequence.zig");
const encoding_mod = @import("encoding.zig");
const registry_mod = @import("registry.zig");
const index_mod = @import("index.zig");
const import_mod = @import("import.zig");

// --- Re-exported types ---

pub const Color = styles.Color;
pub const P = styles.P;
pub const GitOutput = git.GitOutput;

// --- Shared constants ---

pub const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
pub const MAX_SEQUENCE_NUMBER: u8 = sequence_mod.MAX_SEQUENCE_NUMBER;
pub const META_PROMPT_CATEGORY = "../";

// --- Re-exports: frontmatter ---

pub const Frontmatter = frontmatter_mod.Frontmatter;
pub const parseFrontmatter = frontmatter_mod.parseFrontmatter;
pub const hasFrontmatter = frontmatter_mod.hasFrontmatter;
pub const stripFrontmatter = frontmatter_mod.stripFrontmatter;

// --- Re-exports: sequence ---

pub const stripSequencePrefix = sequence_mod.stripSequencePrefix;
pub const findNextSequence = sequence_mod.findNextSequence;

// --- Re-exports: encoding ---

pub const hexEncode = encoding_mod.hexEncode;
pub const jsonEscapeAlloc = encoding_mod.jsonEscapeAlloc;
pub const isHexString = encoding_mod.isHexString;

// --- Re-exports: registry ---

pub const RefKind = registry_mod.RefKind;
pub const ensureRegistry = registry_mod.ensureRegistry;
pub const resolveRef = registry_mod.resolveRef;
pub const bundleExists = registry_mod.bundleExists;

// --- Re-exports: index ---

pub const PromptRef = index_mod.PromptRef;
pub const freePromptRefs = index_mod.freePromptRefs;
pub const updatePromptsIndex = index_mod.updatePromptsIndex;
pub const appendPromptEntry = index_mod.appendPromptEntry;
pub const appendBundleEntry = index_mod.appendBundleEntry;

// --- Re-exports: import ---

pub const ImportResult = import_mod.ImportResult;
pub const importPrompt = import_mod.importPrompt;
pub const collectAndUploadPrompts = import_mod.collectAndUploadPrompts;

// --- Path utilities ---

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

// --- Date formatting ---

/// Format timestamp to ISO date string (YYYY-MM-DD)
pub fn formatDate(timestamp: i64, buf: *[10]u8) []const u8 {
    const epoch_seconds: u64 = @intCast(if (timestamp < 0) 0 else timestamp);
    const days_since_epoch = epoch_seconds / 86400;

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

// --- Git output formatting ---

/// Print git output in unified format
/// Shows both stdout and stderr with dim styling
pub fn printGitOutput(writer: *std.io.Writer, output: *const GitOutput) void {
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
/// If quiet=true, output is suppressed.
pub fn printGitOutputRaw(output: *const GitOutput, quiet: bool) void {
    if (quiet) return;
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

// --- Tests for functions that remain in this file ---

test "formatDate: unix epoch" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", formatDate(0, &buf));
}

test "formatDate: known date 2024-01-01" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2024-01-01", formatDate(1704067200, &buf));
}

test "formatDate: leap year feb 29" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2024-02-29", formatDate(1709164800, &buf));
}

test "formatDate: negative timestamp clamps to epoch" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", formatDate(-100, &buf));
}

test "formatDate: end of year" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2023-12-31", formatDate(1703980800, &buf));
}

test "formatDate: year 2026" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("2026-03-18", formatDate(1774051200, &buf));
}
