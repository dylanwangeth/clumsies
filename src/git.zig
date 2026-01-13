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
    const term = child.spawnAndWait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn clone(allocator: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "clone", url, path }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn addRemote(allocator: std.mem.Allocator, path: []const u8, url: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "remote", "add", "origin", url }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn addAll(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "add", "-A" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn commit(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !void {
    var child = std.process.Child.init(&.{ "git", "commit", "-m", message }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn push(allocator: std.mem.Allocator, path: []const u8, err_out: *?[]const u8) !void {
    var child = std.process.Child.init(&.{ "git", "push", "-u", "origin", "HEAD" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    // Read stderr
    var stderr_buf: [4096]u8 = undefined;
    var stderr_len: usize = 0;
    if (child.stderr) |stderr_file| {
        while (stderr_len < stderr_buf.len) {
            const n = stderr_file.read(stderr_buf[stderr_len..]) catch break;
            if (n == 0) break;
            stderr_len += n;
        }
    }

    const term = child.wait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (stderr_len > 0) {
                    err_out.* = allocator.dupe(u8, stderr_buf[0..stderr_len]) catch null;
                }
                return GitError.CommandFailed;
            }
        },
        else => return GitError.CommandFailed,
    }
}

pub fn pull(allocator: std.mem.Allocator, path: []const u8, err_out: *?[]const u8) !void {
    var child = std.process.Child.init(&.{ "git", "pull", "--rebase" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    // Read stderr
    var stderr_buf: [4096]u8 = undefined;
    var stderr_len: usize = 0;
    if (child.stderr) |stderr_file| {
        while (stderr_len < stderr_buf.len) {
            const n = stderr_file.read(stderr_buf[stderr_len..]) catch break;
            if (n == 0) break;
            stderr_len += n;
        }
    }

    const term = child.wait() catch return GitError.CommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (stderr_len > 0) {
                    err_out.* = allocator.dupe(u8, stderr_buf[0..stderr_len]) catch null;
                }
                return GitError.CommandFailed;
            }
        },
        else => return GitError.CommandFailed,
    }
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ "git", "remote", "get-url", "origin" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

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

pub fn hasUnpushedCommits(allocator: std.mem.Allocator, path: []const u8) bool {
    // Check if there are commits that haven't been pushed
    // git rev-list @{u}..HEAD --count returns the number of unpushed commits
    var child = std.process.Child.init(&.{ "git", "rev-list", "@{u}..HEAD", "--count" }, allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = child.spawn() catch return false;

    const stdout_file = child.stdout orelse return false;
    var buffer: [32]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const n = stdout_file.read(buffer[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    const term = child.wait() catch return false;
    switch (term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    const count_str = std.mem.trim(u8, buffer[0..total_read], " \n\r");
    const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
    return count > 0;
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
