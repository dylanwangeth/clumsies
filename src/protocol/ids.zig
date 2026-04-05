const std = @import("std");

pub const Revision = struct {
    value: i64,

    pub fn toEtag(self: Revision, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\"rev-{d}\"", .{self.value}) catch "";
    }

    pub fn fromEtag(etag: []const u8) ?Revision {
        if (etag.len < 6) return null;
        const trimmed = if (etag[0] == '"' and etag[etag.len - 1] == '"')
            etag[1 .. etag.len - 1]
        else
            etag;
        if (!std.mem.startsWith(u8, trimmed, "rev-")) return null;
        const num = std.fmt.parseInt(i64, trimmed[4..], 10) catch return null;
        return .{ .value = num };
    }
};

test "Revision ETag roundtrip" {
    const rev = Revision{ .value = 42 };
    var buf: [32]u8 = undefined;
    const etag = rev.toEtag(&buf);
    const parsed = Revision.fromEtag(etag) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), parsed.value);
}
