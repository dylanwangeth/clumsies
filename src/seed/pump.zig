const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const Faker = @import("faker.zig");

const log = std.log.scoped(.pump);

// Copy a pg row string value into a stack buffer before row.deinit()
fn copyRowStr(dest: []u8, row: anytype, col: usize) ?[]const u8 {
    const val = row.get([]const u8, col) catch return null;
    if (val.len > dest.len) return null;
    @memcpy(dest[0..val.len], val);
    return dest[0..val.len];
}

pub fn run(pool: *pg.Pool, interval_ms: u64) !void {
    log.info("pump started (interval: {d}ms, Ctrl-C to stop)", .{interval_ms});

    var faker = Faker.init(std.heap.page_allocator);
    var tick: u64 = 0;

    while (true) {
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);

        const conn = pool.acquire() catch {
            log.warn("failed to acquire connection, retrying...", .{});
            continue;
        };
        defer conn.release();

        // Weighted random operation selection
        const roll = faker.intRange(u8, 0, 100);
        if (roll < 40) {
            traceSession(&faker, conn);
        } else if (roll < 55) {
            contextFileEdit(&faker, conn);
        } else if (roll < 70) {
            reviewComment(&faker, conn);
        } else if (roll < 80) {
            openPromptPr(&faker, conn);
        } else if (roll < 90) {
            resolvePromptPr(&faker, conn);
        } else {
            bumpRevision(conn);
        }

        tick += 1;
        if (tick % data.CLEANUP_INTERVAL == 0) {
            cleanup(conn);
            log.info("{d} operations completed (cleanup done)", .{tick});
        } else if (tick % 10 == 0) {
            log.info("{d} operations completed", .{tick});
        }
    }
}

fn traceSession(faker: *Faker, conn: *pg.Conn) void {
    // Pick a random workspace — copy into stack buffer before deinit
    var ws_buf: [64]u8 = undefined;
    var ws_id: []const u8 = undefined;
    {
        var row = (conn.row("SELECT ws_id FROM workspaces ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        ws_id = copyRowStr(&ws_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    // Get prompt IDs for refer events — copy into stack buffers
    var prompt_bufs: [3][64]u8 = undefined;
    var prompt_ids: [3]?[]const u8 = .{ null, null, null };
    var prompt_count: usize = 0;
    {
        var result = conn.query(
            "SELECT prompt_id FROM workspace_prompts WHERE ws_id = $1 ORDER BY random() LIMIT 3",
            .{ws_id},
        ) catch return;
        while (result.next() catch null) |prow| {
            if (prompt_count < 3) {
                const val = prow.get([]const u8, 0) catch continue;
                if (val.len <= prompt_bufs[prompt_count].len) {
                    @memcpy(prompt_bufs[prompt_count][0..val.len], val);
                    prompt_ids[prompt_count] = prompt_bufs[prompt_count][0..val.len];
                    prompt_count += 1;
                }
            }
        }
        result.deinit();
    }

    if (prompt_count == 0) return;

    var session_buf: [24]u8 = undefined;
    const session_id = faker.hexId(&session_buf, "ses-");

    const events = [_][]const u8{ "setup", "begin", "refer", "refer", "complete" };
    for (events, 0..) |event_type, ei| {
        const prompt_id: ?[]const u8 = if (std.mem.eql(u8, event_type, "refer"))
            prompt_ids[ei % prompt_count]
        else
            null;

        _ = conn.exec(
            "INSERT INTO trace_events (ws_id, session_id, event_id, type, timestamp, prompt_id) VALUES ($1, $2, $3, $4, (extract(epoch from now()) * 1000)::bigint, $5) ON CONFLICT DO NOTHING",
            .{ ws_id, session_id, @as(i64, @intCast(ei)), event_type, prompt_id },
        ) catch {};
    }
}

fn contextFileEdit(faker: *Faker, conn: *pg.Conn) void {
    var ws_buf: [64]u8 = undefined;
    var ws_id: []const u8 = undefined;
    {
        var row = (conn.row("SELECT ws_id FROM workspaces ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        ws_id = copyRowStr(&ws_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    var author_buf: [64]u8 = undefined;
    var author: []const u8 = undefined;
    {
        var row = (conn.row("SELECT username FROM users ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        author = copyRowStr(&author_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    var branch_buf: [40]u8 = undefined;
    const branch = faker.branchName(&branch_buf);

    _ = conn.exec(
        "INSERT INTO context_branches (ws_id, branch_name, base_revision, revision) VALUES ($1, $2, 0, 1) ON CONFLICT (ws_id, branch_name) DO UPDATE SET revision = context_branches.revision + 1",
        .{ ws_id, branch },
    ) catch {};

    var path_buf: [80]u8 = undefined;
    const path = faker.contextPath(&path_buf);
    var content_buf: [256]u8 = undefined;
    const content = faker.contextContent(&content_buf);

    _ = conn.exec(
        "INSERT INTO context_files (ws_id, branch_name, path, content, content_hash, author) VALUES ($1, $2, $3, $4, md5($4), $5) ON CONFLICT (ws_id, branch_name, path) DO UPDATE SET content = $4, content_hash = md5($4), updated_at = now()",
        .{ ws_id, branch, path, content, author },
    ) catch {};
}

fn reviewComment(faker: *Faker, conn: *pg.Conn) void {
    const body = faker.reviewComment();

    if (faker.boolean()) {
        // Comment on a context PR
        var pr_buf: [64]u8 = undefined;
        var pr_id: []const u8 = undefined;
        {
            var row = (conn.row("SELECT pr_id FROM context_prs WHERE status = 'open' ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
            pr_id = copyRowStr(&pr_buf, &row, 0) orelse {
                row.deinit() catch {};
                return;
            };
            row.deinit() catch {};
        }

        var author_buf: [64]u8 = undefined;
        var cmt_author: []const u8 = undefined;
        {
            var row = (conn.row("SELECT username FROM users ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
            cmt_author = copyRowStr(&author_buf, &row, 0) orelse {
                row.deinit() catch {};
                return;
            };
            row.deinit() catch {};
        }

        var id_buf: [24]u8 = undefined;
        const cmt_id = faker.hexId(&id_buf, "ccmt-");

        _ = conn.exec(
            "INSERT INTO context_pr_comments (comment_id, pr_id, author, body) VALUES ($1, $2, $3, $4)",
            .{ cmt_id, pr_id, cmt_author, body },
        ) catch {};
    } else {
        // Comment on a prompt PR
        var pr_buf: [64]u8 = undefined;
        var pr_id: []const u8 = undefined;
        {
            var row = (conn.row("SELECT pr_id FROM prompt_prs WHERE status = 'open' ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
            pr_id = copyRowStr(&pr_buf, &row, 0) orelse {
                row.deinit() catch {};
                return;
            };
            row.deinit() catch {};
        }

        var uid_buf: [64]u8 = undefined;
        var author_id: []const u8 = undefined;
        {
            var row = (conn.row("SELECT user_id FROM users ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
            author_id = copyRowStr(&uid_buf, &row, 0) orelse {
                row.deinit() catch {};
                return;
            };
            row.deinit() catch {};
        }

        var id_buf: [24]u8 = undefined;
        const cmt_id = faker.hexId(&id_buf, "pcmt-");

        _ = conn.exec(
            "INSERT INTO prompt_pr_comments (comment_id, pr_id, author_id, body) VALUES ($1, $2, $3, $4)",
            .{ cmt_id, pr_id, author_id, body },
        ) catch {};
    }
}

fn openPromptPr(faker: *Faker, conn: *pg.Conn) void {
    var pid_buf: [64]u8 = undefined;
    var hash_buf: [64]u8 = undefined;
    var kind_buf: [16]u8 = undefined;
    var prompt_id: []const u8 = undefined;
    var base_hash: []const u8 = undefined;
    var kind: []const u8 = undefined;
    {
        var row = (conn.row("SELECT prompt_id, content_hash, kind FROM prompts ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        prompt_id = copyRowStr(&pid_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        base_hash = copyRowStr(&hash_buf, &row, 1) orelse {
            row.deinit() catch {};
            return;
        };
        kind = copyRowStr(&kind_buf, &row, 2) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    var uid_buf: [64]u8 = undefined;
    var author_id: []const u8 = undefined;
    {
        var row = (conn.row("SELECT user_id FROM users WHERE role = 'member' ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        author_id = copyRowStr(&uid_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    var id_buf: [24]u8 = undefined;
    const pr_id = faker.hexId(&id_buf, "ppr-");
    const desc = faker.prDescription();
    var content_buf: [512]u8 = undefined;
    const content = faker.promptContent(&content_buf, kind, "Proposed Update");

    _ = conn.exec(
        "INSERT INTO prompt_prs (pr_id, org_id, prompt_id, author_id, base_hash, content, description, status) VALUES ($1, $2::uuid, $3, $4, $5, $6, $7, 'open')",
        .{ pr_id, data.ORG_ID, prompt_id, author_id, base_hash, content, desc },
    ) catch {};
}

fn resolvePromptPr(faker: *Faker, conn: *pg.Conn) void {
    var pr_buf: [64]u8 = undefined;
    var pr_id: []const u8 = undefined;
    {
        var row = (conn.row("SELECT pr_id FROM prompt_prs WHERE status = 'open' ORDER BY random() LIMIT 1", .{}) catch return) orelse return;
        pr_id = copyRowStr(&pr_buf, &row, 0) orelse {
            row.deinit() catch {};
            return;
        };
        row.deinit() catch {};
    }

    const new_status: []const u8 = if (faker.chance(60)) "accepted" else "rejected";

    _ = conn.exec(
        "UPDATE prompt_prs SET status = $1, updated_at = now() WHERE pr_id = $2",
        .{ new_status, pr_id },
    ) catch {};
}

fn cleanup(conn: *pg.Conn) void {
    // Delete oldest rows when tables exceed their caps.
    // Uses subqueries to identify rows to delete.

    _ = conn.exec(
        "DELETE FROM trace_events WHERE (ws_id, session_id, event_id) IN (SELECT ws_id, session_id, event_id FROM trace_events ORDER BY timestamp ASC LIMIT GREATEST(0, (SELECT count(*) FROM trace_events) - $1))",
        .{data.CAP_TRACE_EVENTS},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM context_pr_comments WHERE comment_id IN (SELECT comment_id FROM context_pr_comments ORDER BY created_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM context_pr_comments) - $1))",
        .{data.CAP_CONTEXT_PR_COMMENTS},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM prompt_pr_comments WHERE comment_id IN (SELECT comment_id FROM prompt_pr_comments ORDER BY created_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM prompt_pr_comments) - $1))",
        .{data.CAP_PROMPT_PR_COMMENTS},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM prompt_prs WHERE pr_id IN (SELECT pr_id FROM prompt_prs WHERE status != 'open' ORDER BY created_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM prompt_prs) - $1))",
        .{data.CAP_PROMPT_PRS},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM context_prs WHERE pr_id IN (SELECT pr_id FROM context_prs WHERE status NOT IN ('open') ORDER BY created_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM context_prs) - $1))",
        .{data.CAP_CONTEXT_PRS},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM context_files WHERE (ws_id, branch_name, path) IN (SELECT ws_id, branch_name, path FROM context_files ORDER BY updated_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM context_files) - $1))",
        .{data.CAP_CONTEXT_FILES},
    ) catch {};

    _ = conn.exec(
        "DELETE FROM context_branches WHERE (ws_id, branch_name) IN (SELECT ws_id, branch_name FROM context_branches WHERE branch_name != 'main' ORDER BY created_at ASC LIMIT GREATEST(0, (SELECT count(*) FROM context_branches) - $1))",
        .{data.CAP_CONTEXT_BRANCHES},
    ) catch {};
}

fn bumpRevision(conn: *pg.Conn) void {
    _ = conn.exec(
        "UPDATE workspaces SET revision = revision + 1 WHERE ws_id = (SELECT ws_id FROM workspaces ORDER BY random() LIMIT 1)",
        .{},
    ) catch {};

    _ = conn.exec(
        "UPDATE library_manifest SET revision = revision + 1 WHERE org_id = $1::uuid",
        .{data.ORG_ID},
    ) catch {};
}
