const std = @import("std");

pub const ManifestEntry = struct {
    path: []const u8,
    hash: []const u8,
};

pub const ManifestItem = struct {
    key: []const u8,
    value: ManifestEntry,
};

pub const ManifestMap = struct {
    items: []const ManifestItem,

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        for (self.items) |item| {
            try jw.objectField(item.key);
            try jw.write(item.value);
        }
        try jw.endObject();
    }
};
