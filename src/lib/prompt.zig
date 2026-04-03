const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");
const sequence = @import("sequence.zig");

pub const MAX_FILE_SIZE = 10 * 1024 * 1024;
pub const PROMPTS_DIR_NAME = ".prompts";

pub fn getPromptsPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, PROMPTS_DIR_NAME });
}

pub fn promptsExist() bool {
    var dir = std.fs.cwd().openDir(PROMPTS_DIR_NAME, .{}) catch return false;
    dir.close();
    return true;
}

pub fn promptsIsGitRepo() bool {
    var dir = std.fs.cwd().openDir(".prompts/.git", .{}) catch return false;
    dir.close();
    return true;
}

/// Derive group from a file's absolute path by finding the `.prompts/` segment.
pub fn deriveGroupFromFile(abs_path: []const u8) ?[]const u8 {
    const after_marker = findAfterPromptsMarker(abs_path) orelse return null;
    const last_fwd = std.mem.lastIndexOfScalar(u8, after_marker, '/');
    const last_bck = std.mem.lastIndexOfScalar(u8, after_marker, '\\');
    const last_sep = if (last_fwd) |f| (if (last_bck) |b| @max(f, b) else f) else (last_bck orelse return null);
    const group = after_marker[0..last_sep];
    if (group.len == 0) return null;
    return group;
}

/// Derive group from a directory's absolute path by finding the `.prompts/` segment.
pub fn deriveGroupFromDir(abs_path: []const u8) ?[]const u8 {
    const after_marker = findAfterPromptsMarker(abs_path) orelse return null;
    const trimmed = std.mem.trimRight(u8, after_marker, "/\\");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn displayNameFromFilename(filename: []const u8) []const u8 {
    const ext_idx = std.mem.lastIndexOfScalar(u8, filename, '.');
    const basename = if (ext_idx) |idx| filename[0..idx] else filename;
    return sequence.stripSequencePrefix(basename);
}

pub fn hashContentHexAlloc(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash_bytes, .{});
    var hash_hex: [64]u8 = undefined;
    encoding.hexEncode(&hash_bytes, &hash_hex);
    return try allocator.dupe(u8, &hash_hex);
}

pub fn readFileHashHexAlloc(allocator: std.mem.Allocator, abs_path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, std.io.Limit.limited(MAX_FILE_SIZE));
    defer allocator.free(content);

    return try hashContentHexAlloc(allocator, content);
}

fn findAfterPromptsMarker(abs_path: []const u8) ?[]const u8 {
    const marker_fwd = ".prompts/";
    const marker_bck = ".prompts\\";
    const idx = std.mem.indexOf(u8, abs_path, marker_fwd) orelse
        (std.mem.indexOf(u8, abs_path, marker_bck) orelse return null);
    return abs_path[idx + marker_fwd.len ..];
}

test "deriveGroupFromFile: nested path" {
    try testing.expectEqualStrings("rule/arch", deriveGroupFromFile("/home/user/.prompts/rule/arch/00_FOO.md").?);
}

test "deriveGroupFromFile: single level" {
    try testing.expectEqualStrings("coding", deriveGroupFromFile("/path/.prompts/coding/01_BAR.md").?);
}

test "deriveGroupFromFile: no .prompts marker" {
    try testing.expect(deriveGroupFromFile("/path/to/foo.md") == null);
}

test "deriveGroupFromFile: file directly in .prompts root" {
    try testing.expect(deriveGroupFromFile("/path/.prompts/foo.md") == null);
}

test "deriveGroupFromFile: deep nesting" {
    try testing.expectEqualStrings("rule/writing/blog", deriveGroupFromFile("/x/.prompts/rule/writing/blog/00_STYLE.md").?);
}

test "deriveGroupFromFile: backslash separators" {
    try testing.expectEqualStrings("rule\\arch", deriveGroupFromFile("C:\\Users\\foo\\.prompts\\rule\\arch\\00_FOO.md").?);
}

test "deriveGroupFromDir: nested path" {
    try testing.expectEqualStrings("rule/didactics", deriveGroupFromDir("/home/user/.prompts/rule/didactics").?);
}

test "deriveGroupFromDir: single level" {
    try testing.expectEqualStrings("conduct", deriveGroupFromDir("/path/.prompts/conduct").?);
}

test "deriveGroupFromDir: trailing slash" {
    try testing.expectEqualStrings("rule/coding", deriveGroupFromDir("/path/.prompts/rule/coding/").?);
}

test "deriveGroupFromDir: no .prompts marker" {
    try testing.expect(deriveGroupFromDir("/path/to/somedir") == null);
}

test "deriveGroupFromDir: .prompts root itself" {
    try testing.expect(deriveGroupFromDir("/path/.prompts/") == null);
}

test "deriveGroupFromDir: backslash separators" {
    try testing.expectEqualStrings("rule\\didactics", deriveGroupFromDir("C:\\Users\\foo\\.prompts\\rule\\didactics").?);
}

test "deriveGroupFromDir: deep nesting" {
    try testing.expectEqualStrings("rule/pedagogy/advanced", deriveGroupFromDir("/x/.prompts/rule/pedagogy/advanced").?);
}

test "displayNameFromFilename: strips extension and sequence" {
    try testing.expectEqualStrings("PR_WORKFLOW", displayNameFromFilename("03_PR_WORKFLOW.md"));
}
