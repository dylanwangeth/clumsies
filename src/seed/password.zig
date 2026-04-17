//! Bcrypt password hashing for seed user accounts.
const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

pub fn hashPassword(password: []const u8, out: *[128]u8) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = false },
        .encoding = .phc,
    }, out);
}
