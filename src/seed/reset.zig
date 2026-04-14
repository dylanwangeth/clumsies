const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const Faker = @import("faker.zig");
const seed_hash = @import("hash.zig");
const password = @import("password.zig");
const clumsies_lib = @import("clumsies_lib");
const local_trace = clumsies_lib.trace;
const prompt_lib = clumsies_lib.prompt;

const log = std.log.scoped(.seed);

// Track generated IDs so we can build relationships between entities
const SeedState = struct {
    user_ids: [data.USER_COUNT][24]u8 = undefined,
    user_names: [data.USER_COUNT][]const u8 = undefined,
    user_roles: [data.USER_COUNT][]const u8 = undefined,
    user_count: usize = 0,

    prompt_ids: [data.PROMPT_COUNT][24]u8 = undefined,
    prompt_hashes: [data.PROMPT_COUNT][71]u8 = undefined,
    prompt_paths: [data.PROMPT_COUNT][80]u8 = undefined,
    prompt_path_lens: [data.PROMPT_COUNT]usize = .{0} ** data.PROMPT_COUNT,
    prompt_count: usize = 0,

    bundle_ids: [data.BUNDLE_COUNT][24]u8 = undefined,
    bundle_count: usize = 0,

    ws_ids: [data.WORKSPACE_COUNT][24]u8 = undefined,
    ws_count: usize = 0,

    fn userId(self: *const SeedState, idx: usize) []const u8 {
        return &self.user_ids[idx];
    }

    fn promptId(self: *const SeedState, idx: usize) []const u8 {
        return &self.prompt_ids[idx];
    }

    fn promptHash(self: *const SeedState, idx: usize) []const u8 {
        return &self.prompt_hashes[idx];
    }

    fn wsId(self: *const SeedState, idx: usize) []const u8 {
        return &self.ws_ids[idx];
    }
};

pub fn run(pool: *pg.Pool) !void {
    const conn = try pool.acquire();
    defer conn.release();

    var faker = Faker.init(std.heap.page_allocator);
    var state = SeedState{};

    clearExistingLocalTrace(conn);
    log.info("truncating all tables...", .{});
    _ = conn.exec(
        \\TRUNCATE orgs, users, tokens, workspaces, workspace_members, prompts, workspace_prompts,
        \\  context_files, context_prs, context_pr_operations, context_pr_comments,
        \\  bundles, bundle_prompts, prompt_prs, prompt_pr_operations, prompt_pr_comments,
        \\  trace_events, library_manifest, prompt_history
        \\CASCADE
    , .{}) catch |err| {
        log.err("truncate failed: {}", .{err});
        return err;
    };

    try seedOrg(conn);
    try seedUsers(conn, &faker, &state);
    try seedPrompts(conn, &faker, &state);
    try seedBundles(conn, &faker, &state);
    try seedLibraryManifest(conn);
    try seedPromptHistory(conn, &faker, &state);
    try seedWorkspaces(conn, &faker, &state);
    try seedWorkspacePrompts(conn, &faker, &state);
    try seedWorkspaceMembers(conn, &faker, &state);
    try seedContextFiles(conn, &faker, &state);
    try seedContextPrs(conn, &faker, &state);
    try seedPromptPrs(conn, &faker, &state);
    try seedTraceEvents(conn, &faker, &state);

    log.info("reset complete", .{});
}

fn clearExistingLocalTrace(conn: *pg.Conn) void {
    var result = conn.query("SELECT ws_id FROM workspaces", .{}) catch return;
    defer result.deinit();

    while (result.next() catch null) |row| {
        const ws_id = row.get([]const u8, 0) catch continue;
        if (!isSafeWorkspaceId(ws_id)) {
            log.warn("seed: skipping unsafe workspace id during local trace cleanup: {s}", .{ws_id});
            continue;
        }
        deleteLocalTraceFile(ws_id);
        deleteLocalCursorFile(ws_id);
    }
}

fn isSafeWorkspaceId(ws_id: []const u8) bool {
    if (std.mem.indexOfScalar(u8, ws_id, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, ws_id, '\\')) |_| return false;
    if (std.mem.indexOf(u8, ws_id, "..")) |_| return false;
    return true;
}

fn deleteLocalTraceFile(ws_id: []const u8) void {
    const alloc = std.heap.page_allocator;
    const path = local_trace.traceFilePath(alloc, ws_id) catch return;
    defer alloc.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("seed: local trace cleanup failed: {}", .{err}),
    };
}

fn deleteLocalCursorFile(ws_id: []const u8) void {
    const alloc = std.heap.page_allocator;
    const path = local_trace.cursorFilePath(alloc, ws_id) catch return;
    defer alloc.free(path);

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("seed: local cursor cleanup failed: {}", .{err}),
    };
}

fn appendLocalTraceEvent(ws_id: []const u8, session_id: []const u8, event_id: i64, event_type: []const u8, timestamp: i64, prompt_id: ?[]const u8, content: ?[]const u8, content_hash: ?[]const u8) void {
    local_trace.appendTraceEvent(std.heap.page_allocator, .{
        .ws_id = ws_id,
        .session_id = session_id,
        .event_id = event_id,
        .type = event_type,
        .timestamp = timestamp,
        .prompt_id = prompt_id,
        .content = content,
        .content_hash = content_hash,
    }) catch |err| {
        log.warn("seed: local trace append failed: {}", .{err});
    };
}

test "isSafeWorkspaceId rejects path traversal markers" {
    try std.testing.expect(isSafeWorkspaceId("ws-seed-default"));
    try std.testing.expect(!isSafeWorkspaceId("../escape"));
    try std.testing.expect(!isSafeWorkspaceId("nested/ws"));
    try std.testing.expect(!isSafeWorkspaceId("nested\\ws"));
}

fn seedOrg(conn: *pg.Conn) !void {
    log.info("seeding org...", .{});
    _ = try conn.exec(
        "INSERT INTO orgs (org_id, name) VALUES ($1::uuid, $2)",
        .{ data.ORG_ID, data.ORG_NAME },
    );
}

fn seedUsers(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} users...", .{data.USER_COUNT});

    var hash_buf: [128]u8 = undefined;
    const active_password_hash = try password.hashPassword(data.SEED_PASSWORD, &hash_buf);

    for (data.SEED_USERNAMES, 0..) |name, i| {
        const id = faker.hexId(&state.user_ids[i], "usr-");
        // Keep reset aligned with ensure: only the base admin user is a maintainer.
        const role: []const u8 = if (std.mem.eql(u8, name, data.BASE_MAINTAINER_USERNAME)) "maintainer" else "member";
        const is_invited = i >= data.USER_COUNT - 2;
        const status: []const u8 = if (is_invited) "invited" else "active";
        const password_hash: []const u8 = if (is_invited) "!invited" else active_password_hash;

        state.user_names[i] = name;
        state.user_roles[i] = role;
        state.user_count = i + 1;

        _ = try conn.exec(
            "INSERT INTO users (user_id, org_id, username, password_hash, role, status) VALUES ($1, $2::uuid, $3, $4, $5, $6)",
            .{ id, data.ORG_ID, name, password_hash, role, status },
        );
    }
}

fn seedPrompts(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} prompts...", .{data.PROMPT_COUNT});

    const mpf_content =
        "# clumsies Protocol Bootstrap\n\nUse memory.search to discover rules, memory.load to read them, memory.refer to declare what you applied.\n";
    const mpf_hash = seed_hash.contentHash(mpf_content);

    _ = conn.exec(
        "INSERT INTO prompts (prompt_id, org_id, path, content, content_hash) VALUES ($1, $2::uuid, $3, $4, $5) ON CONFLICT (prompt_id) DO NOTHING",
        .{
            "p-mpf",
            data.ORG_ID,
            "META_PROMPT.md",
            mpf_content,
            mpf_hash[0..],
        },
    ) catch |err| log.warn("MPF seed insert failed: {}", .{err});

    for (0..data.PROMPT_COUNT) |i| {
        const id = faker.hexId(&state.prompt_ids[i], "p-");

        var path_buf: [80]u8 = undefined;
        var path: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            path = faker.promptPath(&path_buf);
            var duplicate = false;
            for (0..state.prompt_count) |j| {
                if (std.mem.eql(u8, state.prompt_paths[j][0..state.prompt_path_lens[j]], path)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) break;
        }
        @memcpy(state.prompt_paths[i][0..path.len], path);
        state.prompt_path_lens[i] = path.len;
        const stable_path = state.prompt_paths[i][0..path.len];

        const kind: []const u8 = if (std.mem.startsWith(u8, stable_path, "rule/")) "rule" else "workflow";

        var content_buf: [512]u8 = undefined;
        const content = faker.promptContent(&content_buf, kind, stable_path);
        state.prompt_hashes[i] = seed_hash.contentHash(content);

        _ = conn.exec(
            "INSERT INTO prompts (prompt_id, org_id, path, content, content_hash) VALUES ($1, $2::uuid, $3, $4, $5)",
            .{ id, data.ORG_ID, stable_path, content, state.promptHash(i) },
        ) catch |err| {
            log.warn("prompt insert failed: {}", .{err});
            continue;
        };

        state.prompt_count = i + 1;
    }
}

fn seedBundles(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} bundles...", .{data.BUNDLE_COUNT});

    var used_names: [data.BUNDLE_COUNT][]const u8 = undefined;
    var used_count: usize = 0;

    for (0..data.BUNDLE_COUNT) |i| {
        const id = faker.hexId(&state.bundle_ids[i], "bnd-");

        // Generate unique bundle name
        var name: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            name = faker.bundleName();
            var duplicate = false;
            for (used_names[0..used_count]) |used| {
                if (std.mem.eql(u8, used, name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) break;
        }
        used_names[used_count] = name;
        used_count += 1;

        const desc = faker.bundleDescription();

        _ = conn.exec(
            "INSERT INTO bundles (bundle_id, org_id, name, description) VALUES ($1, $2::uuid, $3, $4)",
            .{ id, data.ORG_ID, name, desc },
        ) catch |err| {
            log.warn("bundle insert failed: {}", .{err});
            continue;
        };

        state.bundle_count = i + 1;

        // Each bundle gets 3-6 random prompts
        if (state.prompt_count < 1) continue;
        const max_prompts = @min(7, state.prompt_count + 1);
        const min_prompts = @min(3, state.prompt_count);
        const target = if (min_prompts >= max_prompts) min_prompts else faker.intRange(usize, min_prompts, max_prompts);
        var added: [data.PROMPT_COUNT]bool = .{false} ** data.PROMPT_COUNT;
        var count: usize = 0;
        while (count < target) {
            const pi = faker.intRange(usize, 0, state.prompt_count);
            if (added[pi]) continue;
            added[pi] = true;
            count += 1;

            _ = conn.exec(
                "INSERT INTO bundle_prompts (bundle_id, prompt_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                .{ &state.bundle_ids[i], state.promptId(pi) },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedLibraryManifest(conn: *pg.Conn) !void {
    _ = try conn.exec(
        "INSERT INTO library_manifest (org_id, revision) VALUES ($1::uuid, 7)",
        .{data.ORG_ID},
    );
}

fn seedPromptHistory(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding prompt history...", .{});

    for (0..state.prompt_count) |i| {
        if (!faker.chance(40)) continue;

        const history_count = faker.intRange(usize, 1, 4);
        for (0..history_count) |h| {
            var interval_buf: [64]u8 = undefined;
            const interval = faker.pastInterval(&interval_buf, 30 - @as(u32, @intCast(h * 7)));

            var content_buf: [256]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "# Historical version {d}\n\nPrevious version of this prompt.", .{h + 1}) catch "# History";
            const hash = seed_hash.contentHash(content);
            const path = state.prompt_paths[i][0..state.prompt_path_lens[i]];

            _ = conn.exec(
                "INSERT INTO prompt_history (prompt_id, content_hash, path, content, merged_at) VALUES ($1, $2, $3, $4, now() - $5::interval) ON CONFLICT DO NOTHING",
                .{ state.promptId(i), hash[0..], path, content, interval },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedWorkspaces(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} workspaces...", .{data.WORKSPACE_COUNT});

    var used_names: [data.WORKSPACE_COUNT][40]u8 = undefined;
    var used_name_lens: [data.WORKSPACE_COUNT]usize = .{0} ** data.WORKSPACE_COUNT;
    var used_count: usize = 0;

    for (0..data.WORKSPACE_COUNT) |i| {
        const id = faker.hexId(&state.ws_ids[i], "ws-");

        // Generate unique workspace name
        var name_buf: [40]u8 = undefined;
        var name: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            name = faker.workspaceName(&name_buf);
            var duplicate = false;
            for (0..used_count) |j| {
                if (std.mem.eql(u8, used_names[j][0..used_name_lens[j]], name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) break;
        }
        @memcpy(used_names[used_count][0..name.len], name);
        used_name_lens[used_count] = name.len;
        used_count += 1;

        const revision = faker.intRange(i32, 1, 20);

        _ = conn.exec(
            "INSERT INTO workspaces (ws_id, org_id, name, revision) VALUES ($1, $2::uuid, $3, $4)",
            .{ id, data.ORG_ID, name, revision },
        ) catch |err| {
            log.warn("workspace insert failed: {}", .{err});
            continue;
        };

        state.ws_count = i + 1;
    }
}

fn seedWorkspacePrompts(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    if (state.prompt_count < 1) return;
    // Each workspace gets 3-6 random prompts
    for (0..state.ws_count) |wi| {
        const max_p = @min(7, state.prompt_count + 1);
        const min_p = @min(3, state.prompt_count);
        const count = if (min_p >= max_p) min_p else faker.intRange(usize, min_p, max_p);
        var added: [data.PROMPT_COUNT]bool = .{false} ** data.PROMPT_COUNT;
        var n: usize = 0;
        while (n < count) {
            const pi = faker.intRange(usize, 0, state.prompt_count);
            if (added[pi]) continue;
            added[pi] = true;
            n += 1;

            _ = conn.exec(
                "INSERT INTO workspace_prompts (ws_id, prompt_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), state.promptId(pi) },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedWorkspaceMembers(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    for (0..state.ws_count) |wi| {
        // Choose a random user as the workspace creator (admin)
        const creator = faker.intRange(usize, 0, state.user_count);
        _ = conn.exec(
            "INSERT INTO workspace_members (ws_id, user_id, role) VALUES ($1, $2, 'admin') ON CONFLICT DO NOTHING",
            .{ state.wsId(wi), state.userId(creator) },
        ) catch |err| {
            log.warn("seed: {}", .{err});
        };

        // Add 2-4 random members
        const member_count = faker.intRange(usize, 2, @min(5, state.user_count));
        var added: [data.USER_COUNT]bool = .{false} ** data.USER_COUNT;
        added[creator] = true;
        var count: usize = 0;

        while (count < member_count) {
            const ui = faker.intRange(usize, 0, state.user_count);
            if (added[ui]) continue;
            added[ui] = true;
            count += 1;

            const role = faker.pick([]const u8, &data.WS_MEMBER_ROLES);
            _ = conn.exec(
                "INSERT INTO workspace_members (ws_id, user_id, role) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), state.userId(ui), role },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedContextFiles(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding context files...", .{});

    for (0..state.ws_count) |wi| {
        const file_count = faker.intRange(usize, 2, 5);
        for (0..file_count) |_| {
            var path_buf: [80]u8 = undefined;
            const path = faker.contextPath(&path_buf);
            var content_buf: [256]u8 = undefined;
            const content = faker.contextContent(&content_buf);
            const author = state.user_names[faker.intRange(usize, 0, state.user_count)];

            var cid_buf: [24]u8 = undefined;
            const cid = faker.hexId(&cid_buf, "ctx-");

            _ = conn.exec(
                "INSERT INTO context_files (context_id, ws_id, path, content, content_hash, author) VALUES ($1, $2, $3, $4, md5($4), $5) ON CONFLICT DO NOTHING",
                .{ cid, state.wsId(wi), path, content, author },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedContextPrs(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} context PRs...", .{data.CONTEXT_PR_COUNT});

    for (0..data.CONTEXT_PR_COUNT) |_| {
        var id_buf: [24]u8 = undefined;
        const pr_id = faker.hexId(&id_buf, "cpr-");
        const wi = faker.intRange(usize, 0, state.ws_count);
        const author = state.user_names[faker.intRange(usize, 0, state.user_count)];
        const desc = faker.prDescription();
        const status = faker.pick([]const u8, &data.CONTEXT_PR_STATUSES);

        _ = conn.exec(
            "INSERT INTO context_prs (pr_id, ws_id, author, description, status) VALUES ($1, $2, $3, $4, $5)",
            .{ pr_id, state.wsId(wi), author, desc, status },
        ) catch |err| {
            log.warn("seed: {}", .{err});
            continue;
        };

        const op_count = faker.intRange(usize, 1, 4);
        for (0..op_count) |opi| {
            var path_buf: [80]u8 = undefined;
            const path = faker.contextPath(&path_buf);
            var content_buf: [256]u8 = undefined;
            const new_content = faker.contextContent(&content_buf);
            _ = conn.exec(
                \\INSERT INTO context_pr_operations (pr_id, op_index, type, context_id, base_hash, content, path)
                \\VALUES ($1, $2, 'create', NULL, NULL, $3, $4)
            , .{ pr_id, @as(i32, @intCast(opi)), new_content, path }) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }

        const comment_count = faker.intRange(usize, 0, 4);
        for (0..comment_count) |_| {
            var cmt_id_buf: [24]u8 = undefined;
            const cmt_id = faker.hexId(&cmt_id_buf, "ccmt-");
            const cmt_author = state.user_names[faker.intRange(usize, 0, state.user_count)];
            const body = faker.reviewComment();

            _ = conn.exec(
                "INSERT INTO context_pr_comments (comment_id, pr_id, author, body) VALUES ($1, $2, $3, $4)",
                .{ cmt_id, pr_id, cmt_author, body },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedPromptPrs(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} prompt PRs...", .{data.PROMPT_PR_COUNT});

    for (0..data.PROMPT_PR_COUNT) |_| {
        var id_buf: [24]u8 = undefined;
        const pr_id = faker.hexId(&id_buf, "ppr-");
        const pi = faker.intRange(usize, 0, state.prompt_count);
        const author_idx = faker.intRange(usize, 2, state.user_count);
        const desc = faker.prDescription();
        const status = faker.pick([]const u8, &data.PROMPT_PR_STATUSES);

        _ = conn.exec(
            "INSERT INTO prompt_prs (pr_id, org_id, author_id, description, status) VALUES ($1, $2::uuid, $3, $4, $5)",
            .{ pr_id, data.ORG_ID, state.userId(author_idx), desc, status },
        ) catch |err| {
            log.warn("seed: {}", .{err});
            continue;
        };

        var content_buf: [512]u8 = undefined;
        const path = state.prompt_paths[pi][0..state.prompt_path_lens[pi]];
        const kind: []const u8 = if (std.mem.startsWith(u8, path, "rule/")) "rule" else "workflow";
        const content = faker.promptContent(&content_buf, kind, "Updated Version");

        _ = conn.exec(
            \\INSERT INTO prompt_pr_operations (pr_id, op_index, type, prompt_id, base_hash, content, path)
            \\VALUES ($1, 0, 'modify', $2, $3, $4, NULL)
        , .{ pr_id, state.promptId(pi), state.promptHash(pi), content }) catch |err| {
            log.warn("seed: {}", .{err});
        };

        const comment_count = faker.intRange(usize, 0, 4);
        for (0..comment_count) |_| {
            var cmt_id_buf: [24]u8 = undefined;
            const cmt_id = faker.hexId(&cmt_id_buf, "pcmt-");
            const reviewer_idx = faker.intRange(usize, 0, state.user_count);
            const body = faker.reviewComment();

            _ = conn.exec(
                "INSERT INTO prompt_pr_comments (comment_id, pr_id, author_id, body) VALUES ($1, $2, $3, $4)",
                .{ cmt_id, pr_id, state.userId(reviewer_idx), body },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedTraceEvents(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding trace events ({d} sessions)...", .{data.TRACE_SESSION_COUNT});

    for (0..data.TRACE_SESSION_COUNT) |si| {
        var session_buf: [24]u8 = undefined;
        const session_id = faker.hexId(&session_buf, "ses-");
        const wi = faker.intRange(usize, 0, state.ws_count);

        for (0..data.TRACE_EVENTS_PER_SESSION) |ei| {
            const event_type: []const u8 = if (ei == 0)
                "setup"
            else
                faker.pick([]const u8, &data.TRACE_EVENT_TYPES);
            const timestamp = std.time.milliTimestamp() + faker.pastDaysMs(30);

            const is_refer = std.mem.eql(u8, event_type, "refer");
            const prompt_id: ?[]const u8 = if (is_refer)
                state.promptId(faker.intRange(usize, 0, state.prompt_count))
            else
                null;
            var content_buf: [256]u8 = undefined;
            const content: ?[]const u8 = if (std.mem.eql(u8, event_type, "session_input"))
                faker.sessionInput(&content_buf)
            else
                null;
            const content_hash: ?[]const u8 = if (content) |body|
                prompt_lib.hashContentHexAlloc(std.heap.page_allocator, body) catch |err| blk: {
                    log.warn("seed: session input hash failed: {}", .{err});
                    break :blk null;
                }
            else
                null;
            defer if (content_hash) |hash| std.heap.page_allocator.free(hash);

            const event_id: i64 = @intCast(si * data.TRACE_EVENTS_PER_SESSION + ei);

            _ = conn.exec(
                "INSERT INTO trace_events (ws_id, session_id, event_id, type, timestamp, prompt_id, content, content_hash) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), session_id, event_id, event_type, timestamp, prompt_id, content, content_hash },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
            appendLocalTraceEvent(state.wsId(wi), session_id, event_id, event_type, timestamp, prompt_id, content, content_hash);
        }
    }
}
