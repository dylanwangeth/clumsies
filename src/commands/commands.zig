const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const styles = @import("../styles.zig");
const git = @import("../git.zig");

const frontmatter_mod = @import("frontmatter.zig");
const sequence_mod = @import("sequence.zig");
const encoding_mod = @import("encoding.zig");
const registry_mod = @import("registry.zig");
const index_mod = @import("index.zig");
const import_mod = @import("import.zig");

pub const Color = styles.Color;
pub const P = styles.P;
pub const GitOutput = git.GitOutput;

pub const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
pub const MAX_SEQUENCE_NUMBER: u8 = sequence_mod.MAX_SEQUENCE_NUMBER;
pub const META_PROMPT_CATEGORY = "../";

pub const Frontmatter = frontmatter_mod.Frontmatter;
pub const parseFrontmatter = frontmatter_mod.parseFrontmatter;
pub const hasFrontmatter = frontmatter_mod.hasFrontmatter;
pub const stripFrontmatter = frontmatter_mod.stripFrontmatter;

pub const stripSequencePrefix = sequence_mod.stripSequencePrefix;
pub const findNextSequence = sequence_mod.findNextSequence;

pub const hexEncode = encoding_mod.hexEncode;
pub const jsonEscapeAlloc = encoding_mod.jsonEscapeAlloc;
pub const isHexString = encoding_mod.isHexString;

pub const RefKind = registry_mod.RefKind;
pub const ensureRegistry = registry_mod.ensureRegistry;
pub const resolveRef = registry_mod.resolveRef;
pub const bundleExists = registry_mod.bundleExists;
pub const printGitOutputRaw = registry_mod.printGitOutputRaw;
pub const getBasePath = registry_mod.getBasePath;

pub const PromptRef = index_mod.PromptRef;
pub const freePromptRefs = index_mod.freePromptRefs;
pub const updatePromptsIndex = index_mod.updatePromptsIndex;
pub const appendPromptEntry = index_mod.appendPromptEntry;
pub const appendBundleEntry = index_mod.appendBundleEntry;

pub const ImportResult = import_mod.ImportResult;
pub const importPrompt = import_mod.importPrompt;
pub const collectAndUploadPrompts = import_mod.collectAndUploadPrompts;

pub fn getPromptsPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".prompts" });
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
    const secs: u64 = @intCast(if (timestamp < 0) 0 else timestamp);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @as(u8, @intFromEnum(month_day.month)) + 1,
        month_day.day_index + 1,
    }) catch return "0000-00-00";
    return buf[0..10];
}

/// Print git output in unified format with dim styling
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
