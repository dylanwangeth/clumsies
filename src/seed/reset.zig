const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const Faker = @import("faker.zig");

const log = std.log.scoped(.seed);

// Track generated IDs so we can build relationships between entities
const SeedState = struct {
    user_ids: [data.USER_COUNT][24]u8 = undefined,
    user_names: [data.USER_COUNT][]const u8 = undefined,
    user_roles: [data.USER_COUNT][]const u8 = undefined,
    user_count: usize = 0,

    team_ids: [data.TEAM_COUNT][24]u8 = undefined,
    team_count: usize = 0,

    prompt_ids: [data.PROMPT_COUNT][24]u8 = undefined,
    prompt_hashes: [data.PROMPT_COUNT][24]u8 = undefined,
    prompt_kinds: [data.PROMPT_COUNT][]const u8 = undefined,
    prompt_count: usize = 0,

    bundle_ids: [data.BUNDLE_COUNT][24]u8 = undefined,
    bundle_count: usize = 0,

    ws_ids: [data.WORKSPACE_COUNT][24]u8 = undefined,
    ws_count: usize = 0,

    fn userId(self: *const SeedState, idx: usize) []const u8 {
        return &self.user_ids[idx];
    }

    fn teamId(self: *const SeedState, idx: usize) []const u8 {
        return &self.team_ids[idx];
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

    log.info("truncating all tables...", .{});
    _ = conn.exec(
        \\TRUNCATE orgs, users, tokens, workspaces, teams, team_members,
        \\  workspace_team_access, workspace_user_access, prompts, workspace_prompts,
        \\  context_branches, context_files, context_prs, context_pr_files, context_pr_comments,
        \\  bundles, bundle_prompts, prompt_prs, prompt_pr_comments,
        \\  trace_events, library_manifest, prompt_history
        \\CASCADE
    , .{}) catch |err| {
        log.err("truncate failed: {}", .{err});
        return err;
    };

    try seedOrg(conn);
    try seedUsers(conn, &faker, &state);
    try seedTeams(conn, &faker, &state);
    try seedTeamMembers(conn, &faker, &state);
    try seedPrompts(conn, &faker, &state);
    try seedBundles(conn, &faker, &state);
    try seedLibraryManifest(conn);
    try seedPromptHistory(conn, &faker, &state);
    try seedWorkspaces(conn, &faker, &state);
    try seedWorkspacePrompts(conn, &faker, &state);
    try seedWorkspaceAccess(conn, &faker, &state);
    try seedContextBranches(conn, &faker, &state);
    try seedContextFiles(conn, &faker, &state);
    try seedContextPrs(conn, &faker, &state);
    try seedPromptPrs(conn, &faker, &state);
    try seedTraceEvents(conn, &faker, &state);

    log.info("reset complete", .{});
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

    // Track used names to avoid duplicates
    var used_names: [data.USER_COUNT][]const u8 = undefined;
    var used_count: usize = 0;

    for (0..data.USER_COUNT) |i| {
        // Generate unique name
        var name: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            name = faker.firstName();
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

        const id = faker.hexId(&state.user_ids[i], "usr-");
        // First 2 users are maintainers, rest are members, last one is invited
        const role: []const u8 = if (i < 2) "maintainer" else "member";
        const password: []const u8 = if (i == data.USER_COUNT - 1) "!invited" else "testpass";

        state.user_names[i] = name;
        state.user_roles[i] = role;
        state.user_count = i + 1;

        _ = try conn.exec(
            "INSERT INTO users (user_id, org_id, username, password_hash, role) VALUES ($1, $2::uuid, $3, $4, $5)",
            .{ id, data.ORG_ID, name, password, role },
        );
    }
}

fn seedTeams(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} teams...", .{data.TEAM_COUNT});

    var used_names: [data.TEAM_COUNT][]const u8 = undefined;
    var used_count: usize = 0;

    for (0..data.TEAM_COUNT) |i| {
        var name: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            name = faker.teamName();
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

        const id = faker.hexId(&state.team_ids[i], "tm-");
        state.team_count = i + 1;

        _ = try conn.exec(
            "INSERT INTO teams (team_id, org_id, name) VALUES ($1, $2::uuid, $3)",
            .{ id, data.ORG_ID, name },
        );
    }
}

fn seedTeamMembers(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    // Each team gets 2-4 random members
    for (0..state.team_count) |ti| {
        const member_count = faker.intRange(usize, 2, @min(5, state.user_count));
        var added: [data.USER_COUNT]bool = .{false} ** data.USER_COUNT;
        var count: usize = 0;

        while (count < member_count) {
            const ui = faker.intRange(usize, 0, state.user_count);
            if (added[ui]) continue;
            added[ui] = true;
            count += 1;

            _ = conn.exec(
                "INSERT INTO team_members (team_id, user_id) VALUES ($1, $2)",
                .{ state.teamId(ti), state.userId(ui) },
            ) catch |err| {
                log.warn("team_member insert failed: {}", .{err});
            };
        }
    }
}

fn seedPrompts(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding {d} prompts...", .{data.PROMPT_COUNT});

    var used_names: [data.PROMPT_COUNT][80]u8 = undefined;
    var used_name_lens: [data.PROMPT_COUNT]usize = .{0} ** data.PROMPT_COUNT;
    var used_count: usize = 0;

    for (0..data.PROMPT_COUNT) |i| {
        const id = faker.hexId(&state.prompt_ids[i], "p-");
        const hash = faker.hexId(&state.prompt_hashes[i], "sha256:");

        // Generate unique canonical_name
        var name_buf: [80]u8 = undefined;
        var canonical_name: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            canonical_name = faker.promptCanonicalName(&name_buf);
            var duplicate = false;
            for (0..used_count) |j| {
                if (std.mem.eql(u8, used_names[j][0..used_name_lens[j]], canonical_name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) break;
        }
        @memcpy(used_names[used_count][0..canonical_name.len], canonical_name);
        used_name_lens[used_count] = canonical_name.len;
        used_count += 1;

        const kind = faker.promptKind();
        state.prompt_kinds[i] = kind;

        var content_buf: [512]u8 = undefined;
        const content = faker.promptContent(&content_buf, kind, canonical_name);

        _ = conn.exec(
            "INSERT INTO prompts (prompt_id, org_id, canonical_name, kind, content, content_hash) VALUES ($1, $2::uuid, $3, $4, $5, $6)",
            .{ id, data.ORG_ID, canonical_name, kind, content, hash },
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

    // Give ~40% of prompts 1-3 history entries
    for (0..state.prompt_count) |i| {
        if (!faker.chance(40)) continue;

        const history_count = faker.intRange(usize, 1, 4);
        for (0..history_count) |h| {
            var hash_buf: [24]u8 = undefined;
            const hash = faker.hexId(&hash_buf, "sha256:");
            var interval_buf: [64]u8 = undefined;
            const interval = faker.pastInterval(&interval_buf, 30 - @as(u32, @intCast(h * 7)));

            var content_buf: [256]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "# Historical version {d}\n\nPrevious version of this prompt.", .{h + 1}) catch "# History";

            _ = conn.exec(
                "INSERT INTO prompt_history (prompt_id, content_hash, content, merged_at) VALUES ($1, $2, $3, now() - $4::interval) ON CONFLICT DO NOTHING",
                .{ state.promptId(i), hash, content, interval },
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

fn seedWorkspaceAccess(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    // Grant teams access to workspaces
    for (0..state.ws_count) |wi| {
        const team_grants = faker.intRange(usize, 1, @min(3, state.team_count + 1));
        for (0..team_grants) |ti| {
            if (ti >= state.team_count) break;
            const level = faker.pick([]const u8, &data.ACCESS_LEVELS);
            _ = conn.exec(
                "INSERT INTO workspace_team_access (ws_id, team_id, level) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), state.teamId(ti), level },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }

    // Grant some individual users direct access
    for (0..state.ws_count) |wi| {
        if (!faker.chance(60)) continue;
        const ui = faker.intRange(usize, 0, state.user_count);
        const level = faker.pick([]const u8, &data.ACCESS_LEVELS);
        _ = conn.exec(
            "INSERT INTO workspace_user_access (ws_id, user_id, level) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
            .{ state.wsId(wi), state.userId(ui), level },
        ) catch |err| {
            log.warn("seed: {}", .{err});
        };
    }
}

fn seedContextBranches(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding context branches...", .{});

    for (0..state.ws_count) |wi| {
        // Every workspace gets a main branch
        _ = conn.exec(
            "INSERT INTO context_branches (ws_id, branch_name, base_revision, revision) VALUES ($1, 'main', 0, $2) ON CONFLICT DO NOTHING",
            .{ state.wsId(wi), faker.intRange(i32, 1, 5) },
        ) catch |err| {
            log.warn("seed: {}", .{err});
        };

        // 1-2 feature branches
        const branch_count = faker.intRange(usize, 1, 3);
        for (0..branch_count) |_| {
            var name_buf: [40]u8 = undefined;
            const branch_name = faker.branchName(&name_buf);
            _ = conn.exec(
                "INSERT INTO context_branches (ws_id, branch_name, base_revision, revision) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), branch_name, faker.intRange(i32, 0, 3), faker.intRange(i32, 1, 6) },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}

fn seedContextFiles(conn: *pg.Conn, faker: *Faker, state: *SeedState) !void {
    log.info("seeding context files...", .{});

    for (0..state.ws_count) |wi| {
        // 2-4 files on main
        const file_count = faker.intRange(usize, 2, 5);
        for (0..file_count) |_| {
            var path_buf: [80]u8 = undefined;
            const path = faker.contextPath(&path_buf);
            var content_buf: [256]u8 = undefined;
            const content = faker.contextContent(&content_buf);
            const author = state.user_names[faker.intRange(usize, 0, state.user_count)];

            _ = conn.exec(
                "INSERT INTO context_files (ws_id, branch_name, path, content, content_hash, author) VALUES ($1, 'main', $2, $3, md5($3), $4) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), path, content, author },
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
        var branch_buf: [40]u8 = undefined;
        const branch = faker.branchName(&branch_buf);
        const desc = faker.prDescription();
        const status = faker.pick([]const u8, &data.CONTEXT_PR_STATUSES);

        _ = conn.exec(
            "INSERT INTO context_prs (pr_id, ws_id, author, branch_name, description, status) VALUES ($1, $2, $3, $4, $5, $6)",
            .{ pr_id, state.wsId(wi), author, branch, desc, status },
        ) catch |err| {
            log.warn("seed: {}", .{err});
        };

        // 1-3 files per PR
        const file_count = faker.intRange(usize, 1, 4);
        for (0..file_count) |_| {
            var path_buf: [80]u8 = undefined;
            const path = faker.contextPath(&path_buf);
            _ = conn.exec(
                "INSERT INTO context_pr_files (pr_id, path) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                .{ pr_id, path },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }

        // 0-3 comments per PR
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
        // Only non-maintainer members create prompt PRs (index >= 2)
        const author_idx = faker.intRange(usize, 2, state.user_count);
        const desc = faker.prDescription();
        const status = faker.pick([]const u8, &data.PROMPT_PR_STATUSES);

        var content_buf: [512]u8 = undefined;
        const content = faker.promptContent(&content_buf, state.prompt_kinds[pi], "Updated Version");

        _ = conn.exec(
            "INSERT INTO prompt_prs (pr_id, org_id, prompt_id, author_id, base_hash, content, description, status) VALUES ($1, $2::uuid, $3, $4, $5, $6, $7, $8)",
            .{ pr_id, data.ORG_ID, state.promptId(pi), state.userId(author_idx), state.promptHash(pi), content, desc, status },
        ) catch |err| {
            log.warn("seed: {}", .{err});
        };

        // 0-3 review comments
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
            const event_type = faker.pick([]const u8, &data.TRACE_EVENT_TYPES);
            var interval_buf: [64]u8 = undefined;
            const interval = faker.pastInterval(&interval_buf, 30);

            const is_refer = std.mem.eql(u8, event_type, "refer");
            const prompt_id: ?[]const u8 = if (is_refer)
                state.promptId(faker.intRange(usize, 0, state.prompt_count))
            else
                null;

            const event_id: i64 = @intCast(si * data.TRACE_EVENTS_PER_SESSION + ei);

            _ = conn.exec(
                "INSERT INTO trace_events (ws_id, session_id, event_id, type, timestamp, prompt_id) VALUES ($1, $2, $3, $4, (extract(epoch from (now() - $5::interval)) * 1000)::bigint, $6) ON CONFLICT DO NOTHING",
                .{ state.wsId(wi), session_id, event_id, event_type, interval, prompt_id },
            ) catch |err| {
                log.warn("seed: {}", .{err});
            };
        }
    }
}
