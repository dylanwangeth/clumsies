const std = @import("std");

pub const GitError = error{
    CommandFailed,
    NotARepository,
    NoRemote,
    OutOfMemory,
};

/// Git 命令输出结构，统一捕获 stdout 和 stderr
pub const GitOutput = struct {
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,

    pub fn deinit(self: *GitOutput, allocator: std.mem.Allocator) void {
        if (self.stdout) |s| allocator.free(s);
        if (self.stderr) |s| allocator.free(s);
    }
};

/// 通用 git 命令执行函数，捕获所有输出
pub fn run(allocator: std.mem.Allocator, cwd: ?[]const u8, args: []const []const u8, output: ?*GitOutput) !void {
    var child = std.process.Child.init(args, allocator);
    if (cwd) |c| child.cwd = c;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch return GitError.CommandFailed;

    // Read stdout
    var stdout_buf: [8192]u8 = undefined;
    var stdout_len: usize = 0;
    if (child.stdout) |stdout_file| {
        while (stdout_len < stdout_buf.len) {
            const n = stdout_file.read(stdout_buf[stdout_len..]) catch break;
            if (n == 0) break;
            stdout_len += n;
        }
    }

    // Read stderr
    var stderr_buf: [8192]u8 = undefined;
    var stderr_len: usize = 0;
    if (child.stderr) |stderr_file| {
        while (stderr_len < stderr_buf.len) {
            const n = stderr_file.read(stderr_buf[stderr_len..]) catch break;
            if (n == 0) break;
            stderr_len += n;
        }
    }

    const term = child.wait() catch return GitError.CommandFailed;

    // Populate output if provided
    if (output) |out| {
        if (stdout_len > 0) {
            out.stdout = allocator.dupe(u8, stdout_buf[0..stdout_len]) catch null;
        }
        if (stderr_len > 0) {
            out.stderr = allocator.dupe(u8, stderr_buf[0..stderr_len]) catch null;
        }
    }

    switch (term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

pub fn init(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "init" }, output);
}

pub fn clone(allocator: std.mem.Allocator, url: []const u8, path: []const u8, output: ?*GitOutput) !void {
    return cloneWithBranch(allocator, url, path, null, output);
}

pub fn cloneWithBranch(allocator: std.mem.Allocator, url: []const u8, path: []const u8, branch: ?[]const u8, output: ?*GitOutput) !void {
    if (branch) |b| {
        return run(allocator, null, &.{ "git", "clone", "-b", b, url, path }, output);
    } else {
        return run(allocator, null, &.{ "git", "clone", url, path }, output);
    }
}

pub fn checkout(allocator: std.mem.Allocator, path: []const u8, branch: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "checkout", branch }, output);
}

pub fn fetchAndCheckout(allocator: std.mem.Allocator, path: []const u8, branch: []const u8, output: ?*GitOutput) !void {
    // First fetch
    try run(allocator, path, &.{ "git", "fetch", "origin", branch }, output);
    // Then checkout
    return checkout(allocator, path, branch, output);
}

pub fn addRemote(allocator: std.mem.Allocator, path: []const u8, url: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "remote", "add", "origin", url }, output);
}

pub fn hasRemote(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) !bool {
    run(allocator, path, &.{ "git", "remote", "get-url", "origin" }, output) catch return false;
    return true;
}

pub fn setRemoteUrl(allocator: std.mem.Allocator, path: []const u8, url: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "remote", "set-url", "origin", url }, output);
}

pub fn addAll(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "add", "-A" }, output);
}

pub fn commit(allocator: std.mem.Allocator, path: []const u8, message: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "commit", "-m", message }, output);
}

pub fn push(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "push", "-u", "origin", "HEAD" }, output);
}

pub fn pull(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) !void {
    return run(allocator, path, &.{ "git", "pull", "--rebase" }, output);
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) ![]const u8 {
    var git_output: GitOutput = .{};
    defer if (output == null) git_output.deinit(allocator);

    run(allocator, path, &.{ "git", "remote", "get-url", "origin" }, &git_output) catch |err| {
        if (output) |out| {
            out.* = git_output;
        }
        return err;
    };

    if (output) |out| {
        out.* = git_output;
    }

    const stdout = git_output.stdout orelse return GitError.NoRemote;
    var end = stdout.len;
    while (end > 0 and (stdout[end - 1] == '\n' or stdout[end - 1] == '\r')) {
        end -= 1;
    }

    return allocator.dupe(u8, stdout[0..end]) catch return GitError.OutOfMemory;
}

pub fn getBranch(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) ![]const u8 {
    var git_output: GitOutput = .{};
    defer if (output == null) git_output.deinit(allocator);

    run(allocator, path, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, &git_output) catch |err| {
        if (output) |out| out.* = git_output;
        return err;
    };

    if (output) |out| out.* = git_output;

    const stdout = git_output.stdout orelse return GitError.CommandFailed;
    var end = stdout.len;
    while (end > 0 and (stdout[end - 1] == '\n' or stdout[end - 1] == '\r')) {
        end -= 1;
    }

    return allocator.dupe(u8, stdout[0..end]) catch return GitError.OutOfMemory;
}

pub fn getStatus(allocator: std.mem.Allocator, path: []const u8, output: ?*GitOutput) ![]const u8 {
    var git_output: GitOutput = .{};
    defer if (output == null) git_output.deinit(allocator);

    run(allocator, path, &.{ "git", "status" }, &git_output) catch |err| {
        if (output) |out| out.* = git_output;
        return err;
    };

    if (output) |out| out.* = git_output;

    const stdout = git_output.stdout orelse return allocator.dupe(u8, "") catch return GitError.OutOfMemory;
    return allocator.dupe(u8, stdout) catch return GitError.OutOfMemory;
}

pub fn hasUnpushedCommits(allocator: std.mem.Allocator, path: []const u8) bool {
    // Check if there are commits that haven't been pushed
    // git rev-list @{u}..HEAD --count returns the number of unpushed commits
    var git_output: GitOutput = .{};
    defer git_output.deinit(allocator);

    run(allocator, path, &.{ "git", "rev-list", "@{u}..HEAD", "--count" }, &git_output) catch return false;

    const stdout = git_output.stdout orelse return false;
    const count_str = std.mem.trim(u8, stdout, " \n\r");
    const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
    return count > 0;
}

pub fn getLog(allocator: std.mem.Allocator, path: []const u8, count: u8, output: ?*GitOutput) ![]const u8 {
    const count_str = std.fmt.allocPrint(allocator, "-{d}", .{count}) catch return GitError.OutOfMemory;
    defer allocator.free(count_str);

    var git_output: GitOutput = .{};
    defer if (output == null) git_output.deinit(allocator);

    run(allocator, path, &.{ "git", "log", count_str, "--oneline" }, &git_output) catch |err| {
        if (output) |out| out.* = git_output;
        return err;
    };

    if (output) |out| out.* = git_output;

    const stdout = git_output.stdout orelse return allocator.dupe(u8, "") catch return GitError.OutOfMemory;
    return allocator.dupe(u8, stdout) catch return GitError.OutOfMemory;
}
