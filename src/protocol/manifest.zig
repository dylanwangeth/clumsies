const std = @import("std");

pub const KvEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const KvMap = struct {
    entries: []const KvEntry,

    pub fn jsonStringify(self: *const @This(), jw: anytype) !void {
        try jw.beginObject();
        for (self.entries) |e| {
            try jw.objectField(e.key);
            try jw.write(e.value);
        }
        try jw.endObject();
    }
};
