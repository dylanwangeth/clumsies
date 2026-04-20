//! Shell out to $EDITOR so the user can edit a file, then return
//! control to the TUI.
//!
//! The flow is split in three pieces so the logic that does not need
//! a live terminal is testable on its own: `resolveEditor` walks the
//! $EDITOR / $VISUAL / fallback chain, `runEditor` spawns a resolved
//! command and waits for it to exit, and `editFile` stitches them
//! together with libvaxis' alt-screen teardown/restore. Callers do
//! not re-read the file themselves — they decide what to refresh after
//! the host returns (draft index, diff, selected rows).

const std = @import("std");
const vaxis = @import("vaxis");

/// Outcome of an edit attempt. Anything that is not `completed`
/// should leave the caller's state untouched — there is nothing new
/// to ingest.
pub const Result = enum {
    /// Editor exited with status 0.
    completed,
    /// Editor exited with non-zero status (user aborted, crash, etc.).
    failed,
    /// No executable editor was found via $EDITOR, $VISUAL, or the
    /// fallback chain.
    editor_not_found,
    /// Resolved an editor command but spawning the child raised a
    /// lower-level error (fork failed, permission denied, etc.).
    spawn_failed,
};

/// Default fallback list used when both $EDITOR and $VISUAL are
/// unset. `nano` comes before `vi` because it has a more forgiving
/// UX; a user who actively prefers `vi` is expected to set $EDITOR.
pub const default_fallbacks: []const []const u8 = &.{ "nano", "vi" };

/// Resolve the command string to invoke. Preference order:
///   1. `$EDITOR` if non-empty
///   2. `$VISUAL` if non-empty
///   3. First entry of `fallback` that resolves on `$PATH`
///
/// Returns null when no candidate resolves. The returned slice is
/// owned by `allocator`.
pub fn resolveEditor(
    allocator: std.mem.Allocator,
    env: *const std.process.EnvMap,
    fallback: []const []const u8,
) !?[]const u8 {
    const preferred_keys: []const []const u8 = &.{ "EDITOR", "VISUAL" };
    for (preferred_keys) |key| {
        if (env.get(key)) |v| if (v.len > 0) return try allocator.dupe(u8, v);
    }
    for (fallback) |candidate| {
        if (try hasExecutable(allocator, env, candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

/// Spawn a resolved editor command, appending `file_path` as its last
/// argument. `cmd` is parsed as a whitespace-separated shell-style
/// string so `"code --wait"` and similar configs work.
pub fn runEditor(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    file_path: []const u8,
) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |part| try argv.append(allocator, part);
    try argv.append(allocator, file_path);

    if (argv.items.len < 2) return .spawn_failed;

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    // On posix_spawn systems (macOS), exec errors like "file not
    // found" do not surface on spawn itself — spawn returns a forked
    // child pid optimistically and the exec failure bubbles through
    // wait. Map either code path to editor_not_found for the classes
    // that mean "we could not run the resolved command".
    child.spawn() catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return .editor_not_found,
        else => return .spawn_failed,
    };

    const term = child.wait() catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return .editor_not_found,
        else => return .spawn_failed,
    };
    return switch (term) {
        .Exited => |code| if (code == 0) .completed else .failed,
        else => .failed,
    };
}

/// Full edit flow. Releases libvaxis' alt-screen before spawning so
/// the editor owns the terminal, and re-enters the alt-screen after
/// the editor exits. Callers are expected to redraw and re-read any
/// state that the editor may have mutated (draft file contents,
/// diffs, row markers) after this function returns.
///
/// If no editor resolves, `.editor_not_found` is returned without
/// touching the alt-screen.
pub fn editFile(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty_writer: *std.io.Writer,
    env: *const std.process.EnvMap,
    file_path: []const u8,
) !Result {
    const cmd = try resolveEditor(allocator, env, default_fallbacks) orelse
        return .editor_not_found;
    defer allocator.free(cmd);

    try vx.exitAltScreen(tty_writer);
    try vx.resetState(tty_writer);

    const result = runEditor(allocator, cmd, file_path) catch |err| {
        vx.enterAltScreen(tty_writer) catch {};
        return err;
    };

    try vx.enterAltScreen(tty_writer);
    return result;
}

fn hasExecutable(
    allocator: std.mem.Allocator,
    env: *const std.process.EnvMap,
    name: []const u8,
) !bool {
    // A name with a path separator is treated as an explicit path and
    // checked directly — we do not walk $PATH for it.
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        std.fs.cwd().access(name, .{}) catch return false;
        return true;
    }
    const path = env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(candidate);
        std.fs.cwd().access(candidate, .{}) catch continue;
        return true;
    }
    return false;
}

test "resolveEditor: $EDITOR wins when set" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EDITOR", "vim");
    try env.put("VISUAL", "code --wait");

    const cmd = (try resolveEditor(std.testing.allocator, &env, &.{"nano"})) orelse {
        return error.TestUnexpectedNull;
    };
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("vim", cmd);
}

test "resolveEditor: falls back to $VISUAL when $EDITOR is empty" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EDITOR", "");
    try env.put("VISUAL", "code --wait");

    const cmd = (try resolveEditor(std.testing.allocator, &env, &.{"nano"})) orelse {
        return error.TestUnexpectedNull;
    };
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("code --wait", cmd);
}

test "resolveEditor: falls through to fallback list when env vars missing" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    // Point PATH at /usr/bin so we can find `true` deterministically.
    try env.put("PATH", "/usr/bin");

    const cmd = (try resolveEditor(std.testing.allocator, &env, &.{"true"})) orelse {
        return error.TestUnexpectedNull;
    };
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("true", cmd);
}

test "resolveEditor: returns null when nothing resolves" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/nonexistent");

    const cmd = try resolveEditor(std.testing.allocator, &env, &.{"definitely-not-an-editor"});
    try std.testing.expect(cmd == null);
}

test "runEditor: true command returns completed" {
    const result = try runEditor(std.testing.allocator, "/usr/bin/true", "/tmp/ignored");
    try std.testing.expectEqual(Result.completed, result);
}

test "runEditor: false command returns failed" {
    const result = try runEditor(std.testing.allocator, "/usr/bin/false", "/tmp/ignored");
    try std.testing.expectEqual(Result.failed, result);
}

test "runEditor: nonexistent command returns editor_not_found" {
    const result = try runEditor(std.testing.allocator, "/nonexistent/binary", "/tmp/ignored");
    try std.testing.expectEqual(Result.editor_not_found, result);
}

test "runEditor: empty command string returns spawn_failed" {
    const result = try runEditor(std.testing.allocator, "", "/tmp/ignored");
    try std.testing.expectEqual(Result.spawn_failed, result);
}
