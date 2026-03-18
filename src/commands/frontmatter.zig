const std = @import("std");
const testing = std.testing;

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

/// Check if content starts with a YAML frontmatter block (---\n...\n---).
pub fn hasFrontmatter(content: []const u8) bool {
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return false;
    const start = if (std.mem.startsWith(u8, content, "---\r\n")) @as(usize, 5) else @as(usize, 4);
    if (std.mem.indexOf(u8, content[start..], "\n---\n") != null) return true;
    if (std.mem.indexOf(u8, content[start..], "\n---\r\n") != null) return true;
    if (std.mem.endsWith(u8, content, "\n---")) return true;
    return false;
}

/// Strip YAML frontmatter from the beginning of content.
pub fn stripFrontmatter(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return content;
    const start = if (std.mem.startsWith(u8, content, "---\r\n")) @as(usize, 5) else @as(usize, 4);

    if (std.mem.indexOf(u8, content[start..], "\n---\n")) |idx| {
        const after = start + idx + 5;
        return std.mem.trimLeft(u8, content[after..], "\r\n");
    }
    if (std.mem.indexOf(u8, content[start..], "\n---\r\n")) |idx| {
        const after = start + idx + 6;
        return std.mem.trimLeft(u8, content[after..], "\r\n");
    }
    if (std.mem.endsWith(u8, content, "\n---")) {
        return "";
    }
    return content;
}

test "parseFrontmatter: all fields" {
    const content = "---\nname: foo\ndescription: a thing\ncategory: rule/coding\ntask: coding\n---\nbody";
    const fm = parseFrontmatter(content);
    try testing.expectEqualStrings("foo", fm.name.?);
    try testing.expectEqualStrings("a thing", fm.description.?);
    try testing.expectEqualStrings("rule/coding", fm.category.?);
    try testing.expectEqualStrings("coding", fm.task.?);
}

test "parseFrontmatter: subset of fields" {
    const content = "---\ndescription: only desc\n---\nbody";
    const fm = parseFrontmatter(content);
    try testing.expect(fm.name == null);
    try testing.expectEqualStrings("only desc", fm.description.?);
    try testing.expect(fm.category == null);
    try testing.expect(fm.task == null);
}

test "parseFrontmatter: no frontmatter" {
    const fm = parseFrontmatter("just some content");
    try testing.expect(fm.name == null);
    try testing.expect(fm.description == null);
}

test "parseFrontmatter: malformed no closing delimiter" {
    const fm = parseFrontmatter("---\nname: foo\nno closing");
    try testing.expect(fm.name == null);
}

test "parseFrontmatter: empty content" {
    const fm = parseFrontmatter("");
    try testing.expect(fm.name == null);
}

test "parseFrontmatter: empty values ignored" {
    const content = "---\nname:\ndescription: \n---\n";
    const fm = parseFrontmatter(content);
    try testing.expect(fm.name == null);
    try testing.expect(fm.description == null);
}

test "parseFrontmatter: whitespace around values" {
    const content = "---\nname:   bar  \n---\n";
    const fm = parseFrontmatter(content);
    try testing.expectEqualStrings("bar", fm.name.?);
}

test "hasFrontmatter: valid with LF" {
    try testing.expect(hasFrontmatter("---\nname: foo\n---\nbody"));
}

test "hasFrontmatter: valid with CRLF" {
    try testing.expect(hasFrontmatter("---\r\nname: foo\n---\r\nbody"));
}

test "hasFrontmatter: ends with newline-dash-dash-dash" {
    try testing.expect(hasFrontmatter("---\nname: foo\n---"));
}

test "hasFrontmatter: no frontmatter" {
    try testing.expect(!hasFrontmatter("just content"));
}

test "hasFrontmatter: starts with dashes but no closing" {
    try testing.expect(!hasFrontmatter("---\nname: foo\nno end"));
}

test "hasFrontmatter: empty" {
    try testing.expect(!hasFrontmatter(""));
}

test "stripFrontmatter: strips and returns body" {
    try testing.expectEqualStrings("body text", stripFrontmatter("---\nname: foo\n---\nbody text"));
}

test "stripFrontmatter: CRLF line endings" {
    try testing.expectEqualStrings("body", stripFrontmatter("---\r\nname: foo\n---\r\nbody"));
}

test "stripFrontmatter: ends with delimiter returns empty" {
    try testing.expectEqualStrings("", stripFrontmatter("---\nname: foo\n---"));
}

test "stripFrontmatter: no frontmatter returns original" {
    try testing.expectEqualStrings("just content", stripFrontmatter("just content"));
}

test "stripFrontmatter: trims leading newlines from body" {
    try testing.expectEqualStrings("body", stripFrontmatter("---\nfoo: bar\n---\n\n\nbody"));
}
