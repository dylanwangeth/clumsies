const std = @import("std");
const flag = @import("../flags.zig");
const artifact_api = @import("clumsies_lib").protocol.artifact_api;
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
const log = std.log.scoped(.sync);

/// Must stay ≤ the hub-side cap (`BATCH_MAX_IDS` / `BATCH_MAX_PATHS`
/// in src/hub/artifact.zig and context.zig). Oversized batches
/// currently 400 with "too many rule_ids" / "too many paths";
/// chunking here keeps sync working on workspaces with more than
/// that many changed entries.
const BATCH_CHUNK_SIZE: usize = 1024;

pub const MaterializeOptions = struct {
    progress: ?*std.Io.Writer = null,
    errors: ?*std.Io.Writer = null,
};

pub const MaterializeSummary = struct {
    rules_total: usize = 0,
    rules_fetched: usize = 0,
    rules_unchanged: usize = 0,
    context_total: usize = 0,
    context_fetched: usize = 0,
    context_unchanged: usize = 0,
    conflicted_drafts: usize = 0,
};

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

    const summary = materializeWorkspace(allocator, &hub, ws_id, .{ .progress = stdout, .errors = stderr }) catch |err| {
        try stderr.print("{s}{s}{s}Error:{s} Sync failed: {s}\n", .{ P, Color.bold, Color.red, Color.reset, @errorName(err) });
        return;
    };

    const skipped_suffix = try std.fmt.allocPrint(allocator, " ({d} rules + {d} context unchanged)", .{ summary.rules_unchanged, summary.context_unchanged });
    defer allocator.free(skipped_suffix);
    const skipped_note: []const u8 = if (summary.rules_unchanged + summary.context_unchanged > 0) skipped_suffix else "";
    if (summary.conflicted_drafts > 0) {
        try stdout.print("{s}{s}{s}Synced:{s} {d} rules, {d} context files{s}, {d} drafts flagged conflicted\n", .{ P, Color.bold, Color.green, Color.reset, summary.rules_total, summary.context_total, skipped_note, summary.conflicted_drafts });
    } else {
        try stdout.print("{s}{s}{s}Synced:{s} {d} rules, {d} context files{s}\n", .{ P, Color.bold, Color.green, Color.reset, summary.rules_total, summary.context_total, skipped_note });
    }
}

pub fn materializeWorkspace(
    allocator: std.mem.Allocator,
    hub: *HubClient,
    ws_id: []const u8,
    options: MaterializeOptions,
) !MaterializeSummary {
    // GET /api/workspaces/{ws_id}/manifest
    const manifest_path = try std.fmt.allocPrint(allocator, "/api/workspaces/{s}/manifest", .{ws_id});
    defer allocator.free(manifest_path);

    const manifest_response = try hub.get(manifest_path);
    defer manifest_response.deinit();
    if (manifest_response.status != .ok) return error.ManifestFetchFailed;

    const manifest_parsed = std.json.parseFromSlice(workspace_api.WorkspaceManifestResponse, allocator, manifest_response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.ManifestParseFailed;
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
    var rule_to_fetch: std.ArrayList([]const u8) = .empty;
    defer rule_to_fetch.deinit(allocator);
    var rule_path_for_id: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer rule_path_for_id.deinit(allocator);
    var rule_skipped: usize = 0;
    var regular_rule_to_fetch: usize = 0;
    // Reserved paths (MPF) are reported on their own line so the
    // "Rules: N unchanged, M to fetch" summary refers only to
    // regular rules + workflows. The reserved file still shares the
    // batch fetch below — it is just accounted for separately in
    // the human-readable output.
    var mpf_status: enum { absent, unchanged, to_fetch } = .absent;
    for (manifest.rules.items) |entry| {
        const rule_id = entry.key;
        const rule_path = entry.value.path;
        const remote_hash = stripHashPrefix(entry.value.hash);
        const matches = try localFileMatchesHash(allocator, cache_dir, cacheSubDirForRulePath(rule_path), rule_path, remote_hash);
        const is_mpf = std.mem.eql(u8, rule_path, "META_PROMPT.md");
        if (is_mpf) mpf_status = if (matches) .unchanged else .to_fetch;
        if (matches) {
            if (!is_mpf) rule_skipped += 1;
            continue;
        }
        try rule_to_fetch.append(allocator, rule_id);
        try rule_path_for_id.put(allocator, rule_id, rule_path);
        if (!is_mpf) regular_rule_to_fetch += 1;
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

    switch (mpf_status) {
        .absent => {},
        .unchanged => if (options.progress) |out| try out.print("{s}\xe2\x86\x92 META_PROMPT.md: unchanged\n", .{P}),
        .to_fetch => if (options.progress) |out| try out.print("{s}\xe2\x86\x92 META_PROMPT.md: to fetch\n", .{P}),
    }
    if (options.progress) |out| {
        try out.print("{s}\xe2\x86\x92 Rules: {d} unchanged, {d} to fetch\n", .{ P, rule_skipped, regular_rule_to_fetch });
        try out.flush();
    }

    var rule_fetched: usize = 0;
    {
        var start: usize = 0;
        while (start < rule_to_fetch.items.len) {
            const end = @min(start + BATCH_CHUNK_SIZE, rule_to_fetch.items.len);
            rule_fetched += fetchRuleBatch(allocator, hub, options.errors, cache_dir, rule_to_fetch.items[start..end], &rule_path_for_id) catch |err| {
                if (options.errors) |writer| try writer.print("{s}{s}{s}Error:{s} Rule batch fetch failed for items {d}-{d}: {s}\n", .{ P, Color.bold, Color.red, Color.reset, start + 1, end, @errorName(err) });
                return error.RuleBatchFetchFailed;
            };
            start = end;
        }
    }

    if (options.progress) |out| {
        try out.print("{s}\xe2\x86\x92 Context: {d} unchanged, {d} to fetch\n", .{ P, context_skipped, contexts_to_fetch.items.len });
        try out.flush();
    }

    var context_fetched: usize = 0;
    {
        var start: usize = 0;
        while (start < contexts_to_fetch.items.len) {
            const end = @min(start + BATCH_CHUNK_SIZE, contexts_to_fetch.items.len);
            context_fetched += fetchContextBatch(allocator, hub, options.errors, cache_dir, ws_id, contexts_to_fetch.items[start..end]) catch |err| {
                if (options.errors) |writer| try writer.print("{s}{s}{s}Error:{s} Context batch fetch failed for items {d}-{d}: {s}\n", .{ P, Color.bold, Color.red, Color.reset, start + 1, end, @errorName(err) });
                return error.ContextBatchFetchFailed;
            };
            start = end;
        }
    }

    // MPF is intentionally excluded from `rule_skipped` so the
    // "Rules" line only reports regular rules + workflows. Re-add
    // it to the final rule_count when MPF was unchanged this sync
    // so the totals still reflect every manifest entry.
    const mpf_in_unchanged: usize = if (mpf_status == .unchanged) 1 else 0;
    const rule_count = rule_fetched + rule_skipped + mpf_in_unchanged;
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
    return .{
        .rules_total = rule_count,
        .rules_fetched = rule_fetched,
        .rules_unchanged = rule_skipped + mpf_in_unchanged,
        .context_total = context_count,
        .context_fetched = context_fetched,
        .context_unchanged = context_skipped,
        .conflicted_drafts = reconcile.conflicted,
    };
}

/// Batch-fetch rule bodies in a single POST. Per-item errors from
/// the Hub response and local write failures are printed to stderr
/// so the user can tell why a "46 of 46" manifest only produced
/// "44 written"; the overall return value is the count of rules
/// successfully written to cache.
fn fetchRuleBatch(
    allocator: std.mem.Allocator,
    hub: *HubClient,
    stderr: ?*std.Io.Writer,
    cache_dir: []const u8,
    rule_ids: []const []const u8,
    path_for_id: *const std.StringHashMapUnmanaged([]const u8),
) !usize {
    const body_json = try std.json.Stringify.valueAlloc(
        allocator,
        artifact_api.BatchRuleContentRequest{ .rule_ids = rule_ids },
        .{},
    );
    defer allocator.free(body_json);

    const resp = try hub.post("/api/org/artifact/rules/content", body_json);
    defer resp.deinit();
    if (resp.status != .ok) return error.BatchFetchFailed;

    const parsed = try std.json.parseFromSlice(artifact_api.BatchRuleContentResponse, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var written: usize = 0;
    for (parsed.value.items) |item| {
        if (item.@"error".len > 0) {
            if (stderr) |writer| try writer.print("  ! rule {s}: {s}\n", .{ item.rule_id, item.@"error" });
            continue;
        }
        // Prefer the path the server reports (authoritative) but fall
        // back to the manifest-side path we had when building the
        // request, so a blank server path (older Hub, partial row)
        // still lands in the right cache slot.
        const target_path = if (item.path.len > 0)
            item.path
        else
            path_for_id.get(item.rule_id) orelse {
                if (stderr) |writer| try writer.print("  ! rule {s}: missing path in response\n", .{item.rule_id});
                continue;
            };
        writeToCache(allocator, cache_dir, cacheSubDirForRulePath(target_path), target_path, item.body) catch |err| {
            if (stderr) |writer| try writer.print("  ! rule {s}: write failed ({s})\n", .{ target_path, @errorName(err) });
            continue;
        };
        written += 1;
    }
    return written;
}

/// Decide the cache subdirectory a given artifact rule path writes
/// to. Reserved top-level names (`META_PROMPT.md`) land at the cache
/// root so loaders can read them without knowing the rule
/// namespace layout. Everything else lives under `cache/rule/` so
/// the rule namespace cannot collide with context.
fn cacheSubDirForRulePath(rule_path: []const u8) []const u8 {
    if (std.mem.eql(u8, rule_path, "META_PROMPT.md")) return "";
    return "rule";
}

/// Batch-fetch context file bodies. Mirrors `fetchRuleBatch` but
/// keyed by path inside a single workspace.
fn fetchContextBatch(
    allocator: std.mem.Allocator,
    hub: *HubClient,
    stderr: ?*std.Io.Writer,
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
            if (stderr) |writer| try writer.print("  ! context {s}: {s}\n", .{ item.path, item.@"error" });
            continue;
        }
        writeToCache(allocator, cache_dir, "context", item.path, item.body) catch |err| {
            if (stderr) |writer| try writer.print("  ! context {s}: write failed ({s})\n", .{ item.path, @errorName(err) });
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
            log.warn("failed to create directory {s}: {}", .{ path, err });
        }
    };
}

fn writeToCache(allocator: std.mem.Allocator, ws_cache_dir: []const u8, sub_dir: []const u8, name: []const u8, content: []const u8) !void {
    if (!path_util.isSafeRelative(name)) return error.UnsafePath;
    const dir_path = try std.fs.path.join(allocator, &.{ ws_cache_dir, sub_dir });
    defer allocator.free(dir_path);

    // Ensure the namespace subdirectory exists (cache/rule or
    // cache/context). `makeDirAbsolute` is the absolute-safe single-
    // level creator; the cache root above it is created by the
    // caller's `ensureDir(cache_dir)` before the loops start.
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open the namespace directory so nested content paths like
    // `archive/2026-03-22/foo.md` can be created with the
    // Dir-relative API the stdlib is designed around. This avoids
    // handing an absolute path to `Dir.makePath`, which is intended
    // for paths relative to the receiver.
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    if (std.fs.path.dirname(name)) |rel_parent| {
        try dir.makePath(rel_parent);
    }

    const file = try dir.createFile(name, .{ .truncate = true });
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
    try out.print("{s}Sync workspace rules and context files from Hub to local cache.\n", .{P});
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

test "stripHashPrefix removes sha256 algo prefix" {
    try testing.expectEqualStrings("abcdef", stripHashPrefix("sha256:abcdef"));
}

test "stripHashPrefix passes bare hex through unchanged" {
    try testing.expectEqualStrings("abcdef", stripHashPrefix("abcdef"));
}

test "stripHashPrefix handles empty input" {
    try testing.expectEqualStrings("", stripHashPrefix(""));
}

test "cacheSubDirForRulePath routes META_PROMPT to cache root" {
    try testing.expectEqualStrings("", cacheSubDirForRulePath("META_PROMPT.md"));
}

test "cacheSubDirForRulePath routes regular paths under rule/" {
    try testing.expectEqualStrings("rule", cacheSubDirForRulePath("coding/STYLE.md"));
    try testing.expectEqualStrings("rule", cacheSubDirForRulePath("workflow/CODING.md"));
}

test "localFileMatchesHash returns true on hash match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule");
    {
        const f = try tmp.dir.createFile("cache/rule/file.md", .{});
        defer f.close();
        try f.writeAll("hello");
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try tmp.dir.realpath("cache", &buf);

    // sha256 of "hello" is 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    const hello_sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const matches = try localFileMatchesHash(testing.allocator, cache_path, "rule", "file.md", hello_sha);
    try testing.expect(matches);
}

test "localFileMatchesHash returns false on hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule");
    {
        const f = try tmp.dir.createFile("cache/rule/file.md", .{});
        defer f.close();
        try f.writeAll("hello");
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try tmp.dir.realpath("cache", &buf);

    const matches = try localFileMatchesHash(testing.allocator, cache_path, "rule", "file.md", "0000000000000000000000000000000000000000000000000000000000000000");
    try testing.expect(!matches);
}

test "localFileMatchesHash returns false when file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try tmp.dir.realpath("cache", &buf);

    const matches = try localFileMatchesHash(testing.allocator, cache_path, "rule", "missing.md", "anyhashvalue");
    try testing.expect(!matches);
}

test "localFileMatchesHash returns false on empty remote hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("cache/rule");
    {
        const f = try tmp.dir.createFile("cache/rule/file.md", .{});
        defer f.close();
        try f.writeAll("hello");
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try tmp.dir.realpath("cache", &buf);

    const matches = try localFileMatchesHash(testing.allocator, cache_path, "rule", "file.md", "");
    try testing.expect(!matches);
}
