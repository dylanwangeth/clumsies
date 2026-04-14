const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const seed_hash = @import("hash.zig");
const clumsies_lib = @import("clumsies_lib");
const local_trace = clumsies_lib.trace;
const prompt_lib = clumsies_lib.prompt;

const log = std.log.scoped(.pump);

pub fn run(pool: *pg.Pool, interval_ms: u64) !void {
    log.info("pump started (interval: {d}ms, Ctrl-C to stop)", .{interval_ms});

    var tick: u64 = 0;
    const sleep_ns = std.math.mul(u64, interval_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);

    while (true) {
        const conn = pool.acquire() catch {
            log.warn("failed to acquire connection, retrying...", .{});
            std.Thread.sleep(sleep_ns);
            continue;
        };
        defer conn.release();

        emitScenario(conn, tick);

        tick += 1;
        if (tick % data.CLEANUP_INTERVAL == 0) {
            cleanupTrace(conn);
            log.info("{d} sessions emitted (db cleanup done)", .{tick});
        } else if (tick % 10 == 0) {
            log.info("{d} sessions emitted", .{tick});
        }

        std.Thread.sleep(sleep_ns);
    }
}

fn emitScenario(conn: *pg.Conn, tick: u64) void {
    const scenario = data.PUMP_SCENARIOS[tick % data.PUMP_SCENARIOS.len];
    const timestamp_base = std.time.milliTimestamp();

    var session_buf: [64]u8 = undefined;
    const session_id = std.fmt.bufPrint(&session_buf, "ses-seed-{d}-{d}", .{ timestamp_base, tick }) catch return;

    insertTraceEvent(conn, scenario.user_id, .{
        .ws_id = scenario.ws_id,
        .session_id = session_id,
        .event_id = 0,
        .type = "setup",
        .timestamp = timestamp_base,
    });

    const input_hash = prompt_lib.hashContentHexAlloc(std.heap.page_allocator, scenario.input) catch null;
    defer if (input_hash) |hash| std.heap.page_allocator.free(hash);

    insertTraceEvent(conn, scenario.user_id, .{
        .ws_id = scenario.ws_id,
        .session_id = session_id,
        .event_id = 1,
        .type = "session_input",
        .timestamp = timestamp_base + 1,
        .content = scenario.input,
        .content_hash = input_hash,
    });

    for (scenario.refers, 0..) |refer, idx| {
        const prompt = data.promptById(refer.prompt_id) orelse continue;
        const prompt_hash = seed_hash.contentHash(prompt.content);
        insertTraceEvent(conn, scenario.user_id, .{
            .ws_id = scenario.ws_id,
            .session_id = session_id,
            .event_id = @as(i64, @intCast(idx + 2)),
            .type = "refer",
            .timestamp = timestamp_base + 2 + @as(i64, @intCast(idx)),
            .prompt_id = prompt.id,
            .prompt_hash = prompt_hash[0..],
            .constraint_id = refer.constraint_id,
            .reason = refer.reason,
        });
    }
}

fn insertTraceEvent(conn: *pg.Conn, user_id: ?[]const u8, event: local_trace.TraceEvent) void {
    _ = conn.exec(
        \\INSERT INTO trace_events (user_id, ws_id, session_id, event_id, type, timestamp,
        \\  prompt_id, prompt_hash, constraint_id, override_base_hash, reason, content, content_hash)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
    , .{
        user_id,
        event.ws_id,
        event.session_id,
        event.event_id,
        event.type,
        event.timestamp,
        event.prompt_id,
        event.prompt_hash,
        event.constraint_id,
        event.override_base_hash,
        event.reason,
        event.content,
        event.content_hash,
    }) catch |err| {
        log.warn("db trace insert failed: {}", .{err});
    };

    local_trace.appendTraceEvent(std.heap.page_allocator, event) catch |err| {
        log.warn("local trace append failed: {}", .{err});
    };
}

fn cleanupTrace(conn: *pg.Conn) void {
    _ = conn.exec(
        \\DELETE FROM trace_events
        \\WHERE (ws_id, session_id, event_id) IN (
        \\  SELECT ws_id, session_id, event_id
        \\  FROM trace_events
        \\  ORDER BY timestamp DESC
        \\  OFFSET $1
        \\)
    , .{data.CAP_TRACE_EVENTS}) catch |err| {
        log.warn("trace cleanup failed: {}", .{err});
    };
}
