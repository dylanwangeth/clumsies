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
//!
//! The terminal-state handoff has three layers that all have to flip
//! together: (1) the alt-screen / mouse / bracketed-paste / kitty
//! keyboard CSI modes managed by libvaxis, (2) the POSIX termios line
//! discipline (raw vs canonical — the child editor expects canonical
//! with ECHO and ISIG on), and (3) the libvaxis internal state flags
//! that track which CSI modes are currently active. Failing to flip
//! any one of these leaves the child reading CSI `u` keyboard reports
//! as text (the symptom pico shows as `1;1:3u...` noise) or the shell
//! in raw mode with mouse tracking live after a crash.

const std = @import("std");
const builtin = @import("builtin");
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
/// unset. `vim` comes first because dev environments usually have
/// it and it is the expected default for engineers editing config
/// inside a Zig TUI. `nano` and `vi` trail as pure-ubiquity
/// fallbacks for minimal systems that lack vim.
pub const default_fallbacks: []const []const u8 = &.{ "vim", "nano", "vi" };

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
/// argument. `cmd` is tokenized on whitespace, so entries like
/// `"code --wait"` split into multiple argv tokens; quoted or escaped
/// arguments are not recognized.
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

/// Full edit flow. Hands the terminal to `$EDITOR`: drops all CSI
/// modes libvaxis had enabled (alt screen, kitty keyboard, mouse,
/// bracketed paste) and restores the original termios so the editor
/// sees a canonical cooked terminal. On return, re-enters raw mode,
/// the alt screen, and every CSI feature libvaxis detected at
/// startup, then requests a full refresh so the UI redraws from
/// scratch.
///
/// If no editor resolves, `.editor_not_found` is returned without
/// touching terminal state — nothing to suspend or resume.
pub fn editFile(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    env: *const std.process.EnvMap,
    file_path: []const u8,
) !Result {
    const cmd = try resolveEditor(allocator, env, default_fallbacks) orelse
        return .editor_not_found;
    defer allocator.free(cmd);

    const tty_writer = tty.writer();
    // Surface suspend failures instead of continuing into the editor
    // with a partially-reset terminal — raw mode or a kitty-keyboard
    // push that did not pop will corrupt the child's input handling.
    try suspendTerminal(vx, tty, tty_writer);

    // errdefer guarantees resumeTerminal runs even if runEditor or a
    // later statement returns an error, so the TUI always attempts to
    // restore its own terminal state. A successful path below clears
    // `resumed` so the errdefer becomes a no-op.
    var resumed = false;
    errdefer if (!resumed) {
        resumeTerminal(vx, tty, tty_writer) catch {};
    };

    const result = try runEditor(allocator, cmd, file_path);

    try resumeTerminal(vx, tty, tty_writer);
    resumed = true;
    return result;
}

/// Release the terminal so a child process sees a canonical TTY.
/// Libvaxis' `resetState` writes the disable sequences for every CSI
/// mode it has flipped on (kitty keyboard pop, mouse reset, bracketed
/// paste reset, alt-screen leave). Termios then goes back to the
/// pre-raw snapshot libvaxis saved at `Tty.init` time, so the child
/// gets line-buffered input with ECHO and ISIG back on. Both pieces
/// are necessary: if termios stays raw, Ctrl-C/Ctrl-Q cannot signal
/// the child; if CSI modes stay on, kitty keyboard reports arrive
/// inside the child as literal `1;1:3u` text.
fn suspendTerminal(vx: *vaxis.Vaxis, tty: *vaxis.Tty, tty_writer: *std.io.Writer) !void {
    try vx.resetState(tty_writer);
    try tty_writer.flush();
    if (builtin.os.tag != .windows) {
        std.posix.tcsetattr(tty.fd, .FLUSH, tty.termios) catch {};
    }
}

/// Rebuild the TUI-owned terminal state the user had before the
/// shell-out. `makeRaw` puts the line discipline back into raw mode;
/// `enableDetectedFeatures` re-pushes kitty keyboard and unicode 2027
/// based on the capability flags libvaxis already detected at
/// startup, so a second round-trip of DA1/XTVERSION queries is not
/// needed. Mouse tracking and bracketed paste are re-enabled
/// unconditionally because `App.run` also turns them on
/// unconditionally. Finally request a full refresh so the next render
/// pushes every cell again — otherwise libvaxis' diff renderer
/// believes the screen still matches `screen_last` and the TUI comes
/// up blank on top of the editor's last frame.
fn resumeTerminal(vx: *vaxis.Vaxis, tty: *vaxis.Tty, tty_writer: *std.io.Writer) !void {
    if (builtin.os.tag != .windows) {
        _ = vaxis.tty.PosixTty.makeRaw(tty.fd) catch {};
    }
    try vx.enterAltScreen(tty_writer);
    try vx.enableDetectedFeatures(tty_writer);
    try vx.setMouseMode(tty_writer, true);
    try vx.setBracketedPaste(tty_writer, true);
    vx.queueRefresh();
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
