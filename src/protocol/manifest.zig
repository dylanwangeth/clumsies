//! Manifest format: the content index at the heart of the sync protocol. A manifest maps rule
//! paths to content hashes. During sync, the client diffs its local manifest against the
//! server's — only rules with changed hashes get downloaded.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ManifestEntry = struct {
    path: []const u8,
    hash: []const u8,
    description: []const u8 = "",
};

pub const ManifestItem = struct {
    key: []const u8,
    value: ManifestEntry,
};

pub const ManifestMap = struct {
    items: []const ManifestItem,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        var items: std.ArrayList(ManifestItem) = .empty;
        errdefer items.deinit(allocator);

        if (.object_begin != try source.next()) return error.UnexpectedToken;
        while (true) {
            const alloc_when = options.allocate orelse .alloc_if_needed;
            const token = try source.nextAlloc(allocator, alloc_when);
            switch (token) {
                inline .string, .allocated_string => |key| {
                    try items.append(allocator, .{
                        .key = key,
                        .value = try std.json.innerParse(ManifestEntry, allocator, source, options),
                    });
                },
                .object_end => break,
                else => return error.UnexpectedToken,
            }
        }

        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;

        var items: std.ArrayList(ManifestItem) = .empty;
        errdefer items.deinit(allocator);

        var it = source.object.iterator();
        while (it.next()) |kv| {
            try items.append(allocator, .{
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .value = try std.json.innerParseFromValue(ManifestEntry, allocator, kv.value_ptr.*, options),
            });
        }

        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        for (self.items) |item| {
            try jw.objectField(item.key);
            try jw.write(item.value);
        }
        try jw.endObject();
    }
};

test "ManifestMap parses object entries" {
    const testing = std.testing;
    const body =
        \\{"rule-a":{"path":"rule/coding/00_COMPATIBILITY.md","hash":"sha256:abc"}}
    ;

    const parsed = try std.json.parseFromSlice(ManifestMap, testing.allocator, body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.items.len);
    try testing.expectEqualStrings("rule-a", parsed.value.items[0].key);
    try testing.expectEqualStrings("rule/coding/00_COMPATIBILITY.md", parsed.value.items[0].value.path);
    try testing.expectEqualStrings("sha256:abc", parsed.value.items[0].value.hash);
}
