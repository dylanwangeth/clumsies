const std = @import("std");

pub const GitError = error{
    CommandFailed,
    NotARepository,
    NoRemote,
    OutOfMemory,
};

pub fn init(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "init" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn clone(allocator: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "clone", url, path }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn addRemote(allocator: std.mem.Allocator, path: []const u8, url: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "remote", "add", "origin", url }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn addAll(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "add", "-A" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn commit(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "commit", "-m", message }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn push(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "push", "-u", "origin", "HEAD" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn pull(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "pull" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return GitError.CommandFailed;
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ "git", "remote", "get-url", "origin" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    const stdout_file = child.stdout orelse return GitError.CommandFailed;
    var buffer: [4096]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const n = stdout_file.read(buffer[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    _ = child.wait() catch return GitError.CommandFailed;

    if (total_read == 0) return GitError.NoRemote;

    var end = total_read;
    while (end > 0 and (buffer[end - 1] == '\n' or buffer[end - 1] == '\r')) {
        end -= 1;
    }

    return allocator.dupe(u8, buffer[0..end]) catch return GitError.OutOfMemory;
}

pub fn getBranch(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    const stdout_file = child.stdout orelse return GitError.CommandFailed;
    var buffer: [256]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const n = stdout_file.read(buffer[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    const term = child.wait() catch return GitError.CommandFailed;

    switch (term) {
        .Exited => |code| {
            if (code != 0) return GitError.CommandFailed;
        },
        else => return GitError.CommandFailed,
    }

    if (total_read == 0) return GitError.CommandFailed;

    var end = total_read;
    while (end > 0 and (buffer[end - 1] == '\n' or buffer[end - 1] == '\r')) {
        end -= 1;
    }

    return allocator.dupe(u8, buffer[0..end]) catch return GitError.OutOfMemory;
}

pub fn getStatus(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ "git", "status", "-s" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    const stdout_file = child.stdout orelse return GitError.CommandFailed;
    var buffer: [64 * 1024]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const n = stdout_file.read(buffer[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    _ = child.wait() catch return GitError.CommandFailed;

    return allocator.dupe(u8, buffer[0..total_read]) catch return GitError.OutOfMemory;
}

pub fn getLog(allocator: std.mem.Allocator, path: []const u8, count: u8) ![]const u8 {
    const count_str = std.fmt.allocPrint(allocator, "-{d}", .{count}) catch return GitError.OutOfMemory;
    defer allocator.free(count_str);

    var child = std.process.Child.init(&.{ "git", "log", count_str, "--oneline" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    const stdout_file = child.stdout orelse return GitError.CommandFailed;
    var buffer: [64 * 1024]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const n = stdout_file.read(buffer[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    _ = child.wait() catch return GitError.CommandFailed;

    return allocator.dupe(u8, buffer[0..total_read]) catch return GitError.OutOfMemory;
}
