const std = @import("std");
const flag = @import("../flags.zig");
const library_api = @import("clumsies_lib").protocol.library_api;
const workspace_api = @import("clumsies_lib").protocol.workspace_api;
const path_util = @import("clumsies_lib").util.path_util;
const util_hash = @import("clumsies_lib").util.hash;
const auth_mod = @import("../auth.zig");
const drafts_mod = @import("../drafts.zig");
const ws_config = @import("../workspace_config.zig");
const HubClient = @import("../hub_client.zig").HubClient;
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const SPECS = [_]flag.FlagSpec{};

    var err_ctx: flag.ErrorContext = .{};
    var result = flag.parse(&SPECS, allocator, args, &err_ctx) catch |err| switch (err) {
        error.HelpRequested => {
            try printHelp(stdout);
            return;
        },
        error.UnknownFlag => {
            try stderr.print("{s}{s}{s}Error:{s} Unknown flag: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.UnexpectedArgument => {
            try stderr.print("{s}{s}{s}Error:{s} Unexpected argument: {s}\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            try printHelp(stderr);
            return;
        },
        error.MissingValue => {
            try stderr.print("{s}{s}{s}Error:{s} {s} requires a value\n", .{ P, Color.bold, Color.red, Color.reset, err_ctx.flag.? });
            return;
        },
    };
    defer result.deinit(allocator);

    // Resolve workspace from config
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const binding = ws_config.resolveWorkspace(allocator, cwd_path) catch {
        try stderr.print("{s}{s}{s}Error:{s} No workspace bound to this directory. Run {s}clumsies init{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer allocator.free(binding.ws_id);
    defer allocator.free(binding.name);
    const ws_id = binding.ws_id;

    const auth_info = auth_mod.loadAuth(allocator) catch {
        try stderr.print("{s}{s}{s}Error:{s} Not logged in. Run {s}clumsies login{s} first.\n", .{ P, Color.bold, Color.red, Color.reset, Color.cyan, Color.reset });
        return;
    };
    defer auth_info.deinit(allocator);

    var hub = HubClient.init(allocator, auth_info.hub_url, auth_info.access_token);
    defer hub.deinit();
    // Wire refresh-on-401 so a long-idle access token rotates
    // transparently during sync instead of forcing `clumsies login`.
    try hub.enableRefresh(auth_info.refresh_token, auth_info.username, auth_mod.persistRotatedTokens);

    // GET /api/workspaces/{ws_id}/manifest
    const manifest_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/manifest", .{ws_id});
    defer allocator.free(manifest_path);

    const manifest_response = hub.get(manifest_path) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Failed to reach Hub at {s}: {s}\n", .{ P, Color.bold, Color.red, Color.reset, auth_info.hub_url, @errorName(err) });
        return;
    };
    defer manifest_response.deinit();
    if (manifest_response.status != .ok) {
        try stderr.print("{s}{s}{s}Error:{s} Failed to fetch manifest (HTTP {d})\n", .{ P, Color.bold, Color.red, Color.reset, @intFromEnum(manifest_response.status) });
        return;
    }

    const manifest_parsed = std.json.parseFromSlice(workspace_api.WorkspaceManifestResponse, allocator, manifest_response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        try stderr.print("{s}{s}{s}Error:{s} Failed to parse manifest\n", .{ P, Color.bold, Color.red, Color.reset });
        return;
    };
    defer manifest_parsed.deinit();
    const manifest = manifest_parsed.value;

    // Set up cache directory
    const cache_dir = try ws_config.getCachePath(allocator, ws_id);
    defer allocator.free(cache_dir);

    // Ensure directory hierarchy
    const base_path = try auth_mod.getBasePath(allocator);
    defer allocator.free(base_path);
    ensureDir(base_path);
    const workspaces_dir = try std.fs.path.join(allocator, &.{ base_path, "workspaces" });
    defer allocator.free(workspaces_dir);
    ensureDir(workspaces_dir);
    const ws_dir = try std.fs.path.join(allocator, &.{ workspaces_dir, ws_id });
    defer allocator.free(ws_dir);
    ensureDir(ws_dir);
    ensureDir(cache_dir);

    // Classify: hash-compare every manifest entry against the local
    // cache so we only ship the IDs/paths that genuinely need
    // refetching. On a warm cache this trims the batch request down
    // to zero items and sync finishes on the manifest call alone.
    var prompts_to_fetch: std.ArrayList([]const u8) = .empty;
    defer prompts_to_fetch.deinit(allocator);
    var prompts_path_for_id: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer prompts_path_for_id.deinit(allocator);
    var prompt_skipped: usize = 0;
    for (manifest.prompts.items) |entry| {
        const prompt_id = entry.key;
        const prompt_path = entry.value.path;
        const remote_hash = stripHashPrefix(entry.value.hash);
        if (try localFileMatchesHash(allocator, cache_dir, cacheSubDirForPromptPath(prompt_path), prompt_path, remote_hash)) {
            prompt_skipped += 1;
            continue;
        }
        try prompts_to_fetch.append(allocator, prompt_id);
        try prompts_path_for_id.put(allocator, prompt_id, prompt_path);
    }

    var contexts_to_fetch: std.ArrayList([]const u8) = .empty;
    defer contexts_to_fetch.deinit(allocator);
    var context_skipped: usize = 0;
    for (manifest.context.items) |entry| {
        const ctx_path = entry.value.path;
        const remote_hash = stripHashPrefix(entry.value.hash);
        if (try localFileMatchesHash(allocator, cache_dir, "context", ctx_path, remote_hash)) {
            context_skipped += 1;
            continue;
        }
        try contexts_to_fetch.append(allocator, ctx_path);
    }

    try stdout.print("{s}\xe2\x86\x92 Prompts: {d} unchanged, {d} to fetch\n", .{ P, prompt_skipped, prompts_to_fetch.items.len });
    try stdout.flush();

    var prompt_fetched: usize = 0;
    if (prompts_to_fetch.items.len > 0) {
        prompt_fetched = fetchPromptsBatch(allocator, &hub, stderr, cache_dir, prompts_to_fetch.items, &prompts_path_for_id) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Prompt batch fetch failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, @errorName(err) });
            return;
        };
    }

    try stdout.print("{s}\xe2\x86\x92 Context: {d} unchanged, {d} to fetch\n", .{ P, context_skipped, contexts_to_fetch.items.len });
    try stdout.flush();

    var context_fetched: usize = 0;
    if (contexts_to_fetch.items.len > 0) {
        context_fetched = fetchContextBatch(allocator, &hub, stderr, cache_dir, ws_id, contexts_to_fetch.items) catch |err| {
            try stderr.print("{s}{s}{s}Error:{s} Context batch fetch failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, @errorName(err) });
            return;
        };
    }

    const prompt_count = prompt_fetched + prompt_skipped;
    const context_count = context_fetched + context_skipped;

    // Write manifest.json to cache
    {
        const manifest_file_path = try std.fs.path.join(allocator, &.{ ws_dir, "manifest.json" });
        defer allocator.free(manifest_file_path);

        const file = try std.fs.createFileAbsolute(manifest_file_path, .{ .truncate = true });
        defer file.close();

        var buf: [8192]u8 = undefined;
        var w = std.fs.File.Writer.init(file, &buf);
        try w.interface.writeAll(manifest_response.body);
        try w.interface.flush();
    }

    const reconcile = drafts_mod.reconcileDrafts(allocator, ws_dir, cache_dir) catch drafts_mod.ReconcileSummary{};
    const skipped_suffix = try std.fmt.allocPrint(allocator, " ({d} prompts + {d} context unchanged)", .{ prompt_skipped, context_skipped });
    defer allocator.free(skipped_suffix);
    const skipped_note: []const u8 = if (prompt_skipped + context_skipped > 0) skipped_suffix else "";
    if (reconcile.conflicted > 0) {
        try stdout.print("{s}{s}{s}Synced:{s} {d} prompts, {d} context files{s}, {d} drafts flagged conflicted\n", .{ P, Color.bold, Color.green, Color.reset, prompt_count, context_count, skipped_note, reconcile.conflicted });
    } else {
        try stdout.print("{s}{s}{s}Synced:{s} {d} prompts, {d} context files{s}\n", .{ P, Color.bold, Color.green, Color.reset, prompt_count, context_count, skipped_note });
    }
}

/// Batch-fetch prompt bodies in a single POST. Per-item errors from
/// the Hub response and local write failures are printed to stderr
/// so the user can tell why a "46 of 46" manifest only produced
/// "44 written"; the overall return value is the count of prompts
/// successfully written to cache.
fn fetchPromptsBatch(
    allocator: std.mem.Allocator,
    hub: *HubClient,
    stderr: *std.Io.Writer,
    cache_dir: []const u8,
    prompt_ids: []const []const u8,
    path_for_id: *const std.StringHashMapUnmanaged([]const u8),
) !usize {
    const body_json = try std.json.Stringify.valueAlloc(
        allocator,
        library_api.BatchPromptContentRequest{ .prompt_ids = prompt_ids },
        .{},
    );
    defer allocator.free(body_json);

    const resp = try hub.post("/api/org/library/prompts/content", body_json);
    defer resp.deinit();
    if (resp.status != .ok) return error.BatchFetchFailed;

    const parsed = try std.json.parseFromSlice(library_api.BatchPromptContentResponse, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var written: usize = 0;
    for (parsed.value.items) |item| {
        if (item.@"error".len > 0) {
            try stderr.print("  ! prompt {s}: {s}\n", .{ item.prompt_id, item.@"error" });
            continue;
        }
        // Prefer the path the server reports (authoritative) but fall
        // back to the manifest-side path we had when building the
        // request, so a blank server path (older Hub, partial row)
        // still lands in the right cache slot.
        const target_path = if (item.path.len > 0)
            item.path
        else
            path_for_id.get(item.prompt_id) orelse {
                try stderr.print("  ! prompt {s}: missing path in response\n", .{item.prompt_id});
                continue;
            };
        writeToCache(allocator, cache_dir, cacheSubDirForPromptPath(target_path), target_path, item.body) catch |err| {
            try stderr.print("  ! prompt {s}: write failed ({s})\n", .{ target_path, @errorName(err) });
            continue;
        };
        written += 1;
    }
    return written;
}

/// Decide the cache subdirectory a given library prompt path writes
/// to. Reserved top-level names (`META_PROMPT.md`) land at the cache
/// root so loaders can read them without knowing the prompt
/// namespace layout. Everything else lives under `cache/prompt/` so
/// the prompt namespace cannot collide with context.
fn cacheSubDirForPromptPath(prompt_path: []const u8) []const u8 {
    if (std.mem.eql(u8, prompt_path, "META_PROMPT.md")) return "";
    return "prompt";
}

/// Batch-fetch context file bodies. Mirrors `fetchPromptsBatch` but
/// keyed by path inside a single workspace.
fn fetchContextBatch(
    allocator: std.mem.Allocator,
    hub: *HubClient,
    stderr: *std.Io.Writer,
    cache_dir: []const u8,
    ws_id: []const u8,
    paths: []const []const u8,
) !usize {
    const body_json = try std.json.Stringify.valueAlloc(
        allocator,
        workspace_api.BatchContextContentRequest{ .paths = paths },
        .{},
    );
    defer allocator.free(body_json);

    const api_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/context/files/content", .{ws_id});
    defer allocator.free(api_path);

    const resp = try hub.post(api_path, body_json);
    defer resp.deinit();
    if (resp.status != .ok) return error.BatchFetchFailed;

    const parsed = try std.json.parseFromSlice(workspace_api.BatchContextContentResponse, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var written: usize = 0;
    for (parsed.value.items) |item| {
        if (item.@"error".len > 0) {
            try stderr.print("  ! context {s}: {s}\n", .{ item.path, item.@"error" });
            continue;
        }
        writeToCache(allocator, cache_dir, "context", item.path, item.body) catch |err| {
            try stderr.print("  ! context {s}: write failed ({s})\n", .{ item.path, @errorName(err) });
            continue;
        };
        written += 1;
    }
    return written;
}

/// Compare a manifest-declared hash against the local cache file's
/// sha256 so we can skip the fetch for unchanged files. Returns false
/// when the cache file is missing / unreadable or the hashes diverge,
/// which forces a fetch. Accepts either a bare hex hash or a
/// `sha256:HEX` prefixed form (the manifest currently uses the
/// prefixed form); callers should pass the stripped hex for the
/// remote side.
fn localFileMatchesHash(
    allocator: std.mem.Allocator,
    ws_cache_dir: []const u8,
    sub_dir: []const u8,
    rel_path: []const u8,
    remote_hash_hex: []const u8,
) !bool {
    if (remote_hash_hex.len == 0) return false;
    if (!path_util.isSafeRelative(rel_path)) return false;
    const dir_path = try std.fs.path.join(allocator, &.{ ws_cache_dir, sub_dir });
    defer allocator.free(dir_path);
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, rel_path });
    defer allocator.free(file_path);

    const file = std.fs.openFileAbsolute(file_path, .{}) catch return false;
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    var fr = std.fs.File.Reader.init(file, &read_buf);
    const content = fr.interface.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch return false;
    defer allocator.free(content);

    const local_hash = util_hash.sha256HexAlloc(allocator, content) catch return false;
    defer allocator.free(local_hash);
    return std.mem.eql(u8, local_hash, remote_hash_hex);
}

/// Manifest hashes arrive as `"sha256:HEX"`; our local hasher emits
/// just `HEX`. Normalize by stripping the algo prefix so callers can
/// compare hex-to-hex.
fn stripHashPrefix(raw: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return raw;
    return raw[colon + 1 ..];
}

fn ensureDir(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.warn("failed to create directory {s}: {}", .{ path, err });
        }
    };
}

fn writeToCache(allocator: std.mem.Allocator, ws_cache_dir: []const u8, sub_dir: []const u8, name: []const u8, content: []const u8) !void {
    if (!path_util.isSafeRelative(name)) return error.UnsafePath;
    const dir_path = try std.fs.path.join(allocator, &.{ ws_cache_dir, sub_dir });
    defer allocator.free(dir_path);
    ensureDir(dir_path);

    // Handle nested paths by creating parent directories
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(file_path);

    // Ensure parent directory exists for nested names like "group/file.md"
    if (std.fs.path.dirname(file_path)) |parent| {
        const parent_owned = try allocator.dupe(u8, parent);
        defer allocator.free(parent_owned);
        std.fs.makeDirAbsolute(parent_owned) catch {};
    }

    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();

    var buf: [8192]u8 = undefined;
    var w = std.fs.File.Writer.init(file, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const HEX = "0123456789ABCDEF";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try buf.append(allocator, byte);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, HEX[byte >> 4]);
            try buf.append(allocator, HEX[byte & 0x0f]);
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print("{s}Usage: {s}clumsies sync{s}\n", .{ P, Color.cyan, Color.reset });
    try out.print("{s}Sync workspace prompts and context files from Hub to local cache.\n", .{P});
    try out.print("{s}Requires workspace binding (run {s}clumsies init{s} first).\n", .{ P, Color.cyan, Color.reset });
}

const testing = std.testing;

test "percentEncode encodes special characters" {
    const allocator = testing.allocator;
    const result = try percentEncode(allocator, "hello world/foo&bar");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello%20world%2Ffoo%26bar", result);
}

test "percentEncode passes unreserved characters" {
    const allocator = testing.allocator;
    const result = try percentEncode(allocator, "hello-world_v1.0~beta");
    defer allocator.free(result);
    try testing.expectEqualStrings("hello-world_v1.0~beta", result);
}
