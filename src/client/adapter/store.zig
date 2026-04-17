//! Adapter install state persistence. Stores manifests and WAL (write-ahead log) events under
//! ~/.clumsies/adapters/installs/{install_id}/. Manifests record which files were written;
//! WAL events provide an audit trail of install/update/remove operations.
const std = @import("std");
const util_hash = @import("clumsies_lib").util.hash;
const auth = @import("../auth.zig");
const model = @import("model.zig");

pub const LoadedManifest = struct {
    parsed: std.json.Parsed(model.InstallManifest),

    pub fn deinit(self: *LoadedManifest) void {
        self.parsed.deinit();
    }
};

pub fn installIdForTarget(allocator: std.mem.Allocator, agent_name: []const u8, scope: []const u8, target_root: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ agent_name, scope, target_root });
    defer allocator.free(key);
    return std.fmt.allocPrint(allocator, "{s}-{x}", .{ agent_name, std.hash.Wyhash.hash(0, key) });
}

pub fn adaptersBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "adapters", "installs" });
}

pub fn installDirPath(allocator: std.mem.Allocator, install_id: []const u8) ![]const u8 {
    const base = try adaptersBasePath(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, install_id });
}

pub fn manifestPath(allocator: std.mem.Allocator, install_id: []const u8) ![]const u8 {
    const dir = try installDirPath(allocator, install_id);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "manifest.json" });
}

pub fn walPath(allocator: std.mem.Allocator, install_id: []const u8) ![]const u8 {
    const dir = try installDirPath(allocator, install_id);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "wal.jsonl" });
}

pub fn ensureInstallDir(allocator: std.mem.Allocator, install_id: []const u8) !void {
    const base = try auth.getBasePath(allocator);
    defer allocator.free(base);
    ensureDir(base);

    const adapters_dir = try std.fs.path.join(allocator, &.{ base, "adapters" });
    defer allocator.free(adapters_dir);
    ensureDir(adapters_dir);

    const installs_dir = try std.fs.path.join(allocator, &.{ adapters_dir, "installs" });
    defer allocator.free(installs_dir);
    ensureDir(installs_dir);

    const install_dir = try std.fs.path.join(allocator, &.{ installs_dir, install_id });
    defer allocator.free(install_dir);
    ensureDir(install_dir);
}

pub fn loadManifest(allocator: std.mem.Allocator, install_id: []const u8) !?LoadedManifest {
    const path = try manifestPath(allocator, install_id);
    defer allocator.free(path);

    return loadManifestAtPath(allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn loadManifestForTarget(
    allocator: std.mem.Allocator,
    agent_name: []const u8,
    scope: []const u8,
    target_root: []const u8,
) !?LoadedManifest {
    const install_id = try installIdForTarget(allocator, agent_name, scope, target_root);
    defer allocator.free(install_id);

    if (try loadManifest(allocator, install_id)) |loaded| {
        return loaded;
    }

    const installs_dir = try adaptersBasePath(allocator);
    defer allocator.free(installs_dir);

    var dir = std.fs.openDirAbsolute(installs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    var best_match: ?LoadedManifest = null;

    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        const path = try std.fs.path.join(allocator, &.{ installs_dir, entry.name, "manifest.json" });
        defer allocator.free(path);

        var loaded = loadManifestAtPath(allocator, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        errdefer loaded.deinit();

        if (!manifestMatchesTarget(loaded.parsed.value, agent_name, scope, target_root)) {
            loaded.deinit();
            continue;
        }

        if (best_match) |*best| {
            if (manifestPreferredOver(loaded.parsed.value, best.parsed.value)) {
                best.deinit();
                best_match = loaded;
            } else {
                loaded.deinit();
            }
        } else {
            best_match = loaded;
        }
    }

    return best_match;
}

fn loadManifestAtPath(allocator: std.mem.Allocator, path: []const u8) !LoadedManifest {
    const content = readFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return err,
        else => return err,
    };
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(model.InstallManifest, allocator, content, .{ .allocate = .alloc_always });
    return .{ .parsed = parsed };
}

pub fn writeManifest(allocator: std.mem.Allocator, manifest: model.InstallManifest) !void {
    try ensureInstallDir(allocator, manifest.install_id);

    const path = try manifestPath(allocator, manifest.install_id);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
    defer allocator.free(json);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        var buf: [4096]u8 = undefined;
        var writer = std.fs.File.Writer.init(file, &buf);
        try writer.interface.writeAll(json);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    }

    try std.fs.renameAbsolute(tmp_path, path);
}

pub fn appendWalEvent(allocator: std.mem.Allocator, event: model.WalEvent) !void {
    try ensureInstallDir(allocator, event.install_id);

    const path = try walPath(allocator, event.install_id);
    defer allocator.free(path);

    var file = try std.fs.createFileAbsolute(path, .{ .truncate = false, .mode = 0o600 });
    defer file.close();
    try file.seekFromEnd(0);

    const json = try std.json.Stringify.valueAlloc(allocator, event, .{});
    defer allocator.free(json);

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.initStreaming(file, &buf);
    try writer.interface.writeAll(json);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

pub fn fingerprintForContent(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const hash = util_hash.contentHash(content);
    return allocator.dupe(u8, &hash);
}

fn ensureDir(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.warn("failed to create directory {s}: {}", .{ path, err });
        }
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var reader = std.fs.File.Reader.init(file, &read_buf);
    return try reader.interface.allocRemaining(allocator, std.io.Limit.limited(256 * 1024));
}

fn manifestMatchesTarget(
    manifest: model.InstallManifest,
    agent_name: []const u8,
    scope: []const u8,
    target_root: []const u8,
) bool {
    const manifest_agent = if (manifest.target_agent.len != 0) manifest.target_agent else manifest.adapter_id;
    return std.mem.eql(u8, manifest_agent, agent_name) and
        std.mem.eql(u8, manifest.scope, scope) and
        std.mem.eql(u8, manifest.target_root, target_root);
}

fn manifestPreferredOver(candidate: model.InstallManifest, current: model.InstallManifest) bool {
    const candidate_active = std.mem.eql(u8, candidate.status, "active");
    const current_active = std.mem.eql(u8, current.status, "active");
    if (candidate_active != current_active) return candidate_active;
    return candidate.updated_at > current.updated_at;
}

test "installIdForTarget differs by target root" {
    const a = try installIdForTarget(std.testing.allocator, "codex", model.Scope.workspace.cliString(), "/tmp/a");
    defer std.testing.allocator.free(a);
    const b = try installIdForTarget(std.testing.allocator, "codex", model.Scope.workspace.cliString(), "/tmp/b");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "installIdForTarget differs by scope" {
    const workspace = try installIdForTarget(std.testing.allocator, "codex", model.Scope.workspace.cliString(), "/tmp/a");
    defer std.testing.allocator.free(workspace);
    const user = try installIdForTarget(std.testing.allocator, "codex", model.Scope.user.cliString(), "/tmp/a");
    defer std.testing.allocator.free(user);
    try std.testing.expect(!std.mem.eql(u8, workspace, user));
}
