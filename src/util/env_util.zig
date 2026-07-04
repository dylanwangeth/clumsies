const std = @import("std");

pub const GetError = error{
    OutOfMemory,
    EnvironmentVariableNotFound,
    InvalidEnvironmentKey,
};

var process_environ: std.process.Environ = .empty;

pub fn init(environ: std.process.Environ) void {
    process_environ = environ;
}

pub fn getOwned(allocator: std.mem.Allocator, key: []const u8) GetError![]u8 {
    if (process_environ.block.isEmpty()) return error.EnvironmentVariableNotFound;
    return getOwnedFrom(process_environ, allocator, key);
}

pub fn getOwnedFrom(environ: std.process.Environ, allocator: std.mem.Allocator, key: []const u8) GetError![]u8 {
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EnvironmentVariableMissing => error.EnvironmentVariableNotFound,
        error.InvalidWtf8 => error.InvalidEnvironmentKey,
    };
}

pub fn homeDir(allocator: std.mem.Allocator) GetError![]u8 {
    return getOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => getOwned(allocator, "USERPROFILE"),
        else => err,
    };
}
