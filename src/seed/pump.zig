//! Synthetic attestation event generator. Simulates realistic user activity (multiple users, varying
//! session lengths, different refer frequencies) to populate the attestation pipeline with data for
//! TUI dashboard and analysis development.
const std = @import("std");
const pg = @import("pg");
const data = @import("data.zig");
const util_hash = @import("clumsies_lib").util.hash;
const local_attestation = @import("clumsies_client").attestation;

const log = std.log.scoped(.pump);

const PumpTick = struct {
    emit_count: u16,
    active_profile: data.PumpProfile,
    profile_switched: bool,
};

const EmitBatch = struct {
    emitted_count: u16 = 0,
    last_scenario: ?*const data.PumpScenario = null,
};

const PumpPlanner = struct {
    rng: std.Random.DefaultPrng,
    current_profile_idx: usize = 0,
    next_sweep_profile_idx: usize = if (data.PUMP_PROFILES.len > 1) 1 else 0,
    sweep_complete: bool = data.PUMP_PROFILES.len <= 1,
    profile_elapsed_ms: u64 = 0,
    session_budget: f32 = 0,
    scenario_cursor: usize = 0,
    total_sessions: u64 = 0,

    fn init() PumpPlanner {
        var seed: u64 = 0;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        return initWithSeed(seed);
    }

    fn initWithSeed(seed: u64) PumpPlanner {
        return .{
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    fn currentProfile(self: *const PumpPlanner) data.PumpProfile {
        return data.PUMP_PROFILES[self.current_profile_idx];
    }

    fn nextScenario(self: *PumpPlanner) *const data.PumpScenario {
        const idx = self.scenario_cursor % data.PUMP_SCENARIOS.len;
        self.scenario_cursor += 1;
        return &data.PUMP_SCENARIOS[idx];
    }

    fn planTick(self: *PumpPlanner, interval_ms: u64) PumpTick {
        var remaining_ms = interval_ms;
        var profile_switched = false;

        while (remaining_ms > 0) {
            const profile = self.currentProfile();
            const total_profile_ms = profileTotalMs(profile);
            const second_idx = @min(
                profile.session_rates.len - 1,
                @as(usize, @intCast(self.profile_elapsed_ms / std.time.ms_per_s)),
            );
            const second_progress_ms = self.profile_elapsed_ms % std.time.ms_per_s;
            const step_remaining_ms = std.time.ms_per_s - second_progress_ms;
            const profile_remaining_ms = total_profile_ms - self.profile_elapsed_ms;
            const slice_ms = @min(remaining_ms, @min(step_remaining_ms, profile_remaining_ms));
            const rate = profile.session_rates[second_idx];

            self.session_budget +=
                @as(f32, @floatFromInt(rate)) *
                @as(f32, @floatFromInt(slice_ms)) /
                @as(f32, @floatFromInt(std.time.ms_per_s));

            self.profile_elapsed_ms += slice_ms;
            remaining_ms -= slice_ms;

            if (self.profile_elapsed_ms == total_profile_ms) {
                profile_switched = true;
                self.advanceProfile();
            }
        }

        const whole_budget = @floor(self.session_budget);
        const max_emit_count = std.math.maxInt(u16);
        const emit_count: u16 = if (whole_budget > @as(f32, @floatFromInt(max_emit_count)))
            max_emit_count
        else
            @intFromFloat(whole_budget);
        self.session_budget -= @as(f32, @floatFromInt(emit_count));

        return .{
            .emit_count = emit_count,
            .active_profile = self.currentProfile(),
            .profile_switched = profile_switched,
        };
    }

    fn advanceProfile(self: *PumpPlanner) void {
        self.profile_elapsed_ms = 0;

        if (!self.sweep_complete) {
            self.current_profile_idx = self.next_sweep_profile_idx;
            self.next_sweep_profile_idx += 1;
            if (self.next_sweep_profile_idx >= data.PUMP_PROFILES.len) {
                self.sweep_complete = true;
            }
            return;
        }

        self.current_profile_idx = pickRandomProfileIndex(self.rng.random(), self.current_profile_idx);
    }
};

pub fn run(pool: *pg.Pool, interval_ms: u64) !void {
    log.info("pump started (interval: {d}ms, Ctrl-C to stop)", .{interval_ms});

    var tick: u64 = 0;
    var planner = PumpPlanner.init();
    const sleep_ns = std.math.mul(u64, interval_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);

    logActiveProfile(planner.currentProfile());

    while (true) {
        const conn = pool.acquire() catch {
            log.warn("failed to acquire connection, retrying...", .{});
            std.Thread.sleep(sleep_ns);
            continue;
        };
        defer conn.release();

        const plan = planner.planTick(interval_ms);
        const batch = emitBatch(conn, &planner, tick, plan.emit_count);

        tick += 1;
        if (tick % data.CLEANUP_INTERVAL == 0) {
            cleanupAttestation(conn);
            logBatchSummary(planner.total_sessions, plan.active_profile, batch, true);
        } else if (plan.profile_switched) {
            logActiveProfile(plan.active_profile);
            logBatchSummary(planner.total_sessions, plan.active_profile, batch, false);
        } else if (tick % 10 == 0) {
            logBatchSummary(planner.total_sessions, plan.active_profile, batch, false);
        }

        std.Thread.sleep(sleep_ns);
    }
}

fn emitBatch(conn: *pg.Conn, planner: *PumpPlanner, tick: u64, emit_count: u16) EmitBatch {
    var batch: EmitBatch = .{};

    for (0..emit_count) |slot_idx| {
        const scenario = planner.nextScenario();
        emitScenario(conn, scenario, tick, planner.total_sessions, @intCast(slot_idx));
        planner.total_sessions += 1;
        batch.emitted_count += 1;
        batch.last_scenario = scenario;
    }

    return batch;
}

fn emitScenario(
    conn: *pg.Conn,
    scenario: *const data.PumpScenario,
    tick: u64,
    session_serial: u64,
    slot_idx: u16,
) void {
    const timestamp_base = std.time.milliTimestamp() + @as(i64, @intCast(slot_idx * 10));

    var session_buf: [64]u8 = undefined;
    const session_id = std.fmt.bufPrint(&session_buf, "ses-seed-{d}-{d}-{d}", .{
        timestamp_base,
        tick,
        session_serial,
    }) catch return;

    insertAttestationEvent(conn, scenario.user_id, .{
        .ws_id = scenario.ws_id,
        .session_id = session_id,
        .event_id = 0,
        .ts = timestamp_base,
        .payload = .setup,
    });

    const input_hash = util_hash.sha256HexAlloc(std.heap.page_allocator, scenario.input) catch null;
    defer if (input_hash) |hash| std.heap.page_allocator.free(hash);

    insertAttestationEvent(conn, scenario.user_id, .{
        .ws_id = scenario.ws_id,
        .session_id = session_id,
        .event_id = 1,
        .ts = timestamp_base + 1,
        .payload = .{
            .user_prompt = .{
                .content = scenario.input,
                .content_hash = input_hash orelse "",
            },
        },
    });

    for (scenario.refers, 0..) |refer, idx| {
        const prompt = data.promptById(refer.prompt_id) orelse continue;
        const prompt_hash = util_hash.contentHash(prompt.content);
        insertAttestationEvent(conn, scenario.user_id, .{
            .ws_id = scenario.ws_id,
            .session_id = session_id,
            .event_id = @as(i64, @intCast(idx + 2)),
            .ts = timestamp_base + 2 + @as(i64, @intCast(idx)),
            .payload = .{
                .refer = .{
                    .prompt_id = prompt.id,
                    .prompt_hash = prompt_hash[0..],
                    .constraint_id = refer.constraint_id,
                    .reason = refer.reason,
                },
            },
        });
    }
}

fn insertAttestationEvent(conn: *pg.Conn, user_id: ?[]const u8, event: local_attestation.AttestationEvent) void {
    const type_tag = local_attestation.payloadTypeTag(event.payload);
    const prompt_id: ?[]const u8 = switch (event.payload) {
        .load => |p| p.prompt_id,
        .refer => |p| p.prompt_id,
        else => null,
    };
    const prompt_hash: ?[]const u8 = switch (event.payload) {
        .load => |p| p.prompt_hash,
        .refer => |p| p.prompt_hash,
        else => null,
    };
    const constraint_id: ?[]const u8 = switch (event.payload) {
        .refer => |p| p.constraint_id,
        else => null,
    };
    const reason: ?[]const u8 = switch (event.payload) {
        .refer => |p| p.reason,
        else => null,
    };
    const content: ?[]const u8 = switch (event.payload) {
        .user_prompt => |p| p.content,
        else => null,
    };
    const content_hash: ?[]const u8 = switch (event.payload) {
        .user_prompt => |p| p.content_hash,
        else => null,
    };

    _ = conn.exec(
        \\INSERT INTO attestation_events (user_id, ws_id, session_id, event_id, type, timestamp,
        \\  prompt_id, prompt_hash, constraint_id, reason, content, content_hash)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        \\ON CONFLICT (ws_id, session_id, event_id) DO NOTHING
    , .{
        user_id,
        event.ws_id,
        event.session_id,
        event.event_id,
        type_tag,
        event.ts,
        prompt_id,
        prompt_hash,
        constraint_id,
        reason,
        content,
        content_hash,
    }) catch |err| {
        log.warn("db attestation insert failed: {}", .{err});
    };

    local_attestation.appendAttestationEvent(std.heap.page_allocator, event) catch |err| {
        log.warn("local attestation append failed: {}", .{err});
    };
}

fn cleanupAttestation(conn: *pg.Conn) void {
    _ = conn.exec(
        \\DELETE FROM attestation_events
        \\WHERE (ws_id, session_id, event_id) IN (
        \\  SELECT ws_id, session_id, event_id
        \\  FROM attestation_events
        \\  ORDER BY timestamp DESC
        \\  OFFSET $1
        \\)
    , .{data.CAP_ATTESTATION_EVENTS}) catch |err| {
        log.warn("attestation cleanup failed: {}", .{err});
    };
}

fn logActiveProfile(profile: data.PumpProfile) void {
    log.info("profile {s} active (~{d} session/s)", .{
        profile.name,
        averageSessionRate(profile),
    });
}

fn logBatchSummary(total_sessions: u64, active_profile: data.PumpProfile, batch: EmitBatch, cleanup_done: bool) void {
    var summary_buf: [160]u8 = undefined;
    const summary = if (batch.last_scenario) |scenario|
        formatScenarioSummary(&summary_buf, scenario)
    else
        "latest: idle window";

    if (cleanup_done) {
        log.info("{d} sessions emitted [{s}] {s} (db cleanup done)", .{
            total_sessions,
            active_profile.name,
            summary,
        });
        return;
    }

    log.info("{d} sessions emitted [{s}] {s}", .{
        total_sessions,
        active_profile.name,
        summary,
    });
}

fn formatScenarioSummary(buf: *[160]u8, scenario: *const data.PumpScenario) []const u8 {
    const workspace = if (data.workspaceById(scenario.ws_id)) |ws| ws.name else scenario.ws_id;
    const user = if (data.userById(scenario.user_id)) |u| u.username else scenario.user_id;

    var input_buf: [80]u8 = undefined;
    const input = truncateForLog(&input_buf, scenario.input);

    return std.fmt.bufPrint(buf, "latest: {s} / {s} / {s}", .{
        workspace,
        user,
        input,
    }) catch "latest: seed activity";
}

fn truncateForLog(buf: []u8, text: []const u8) []const u8 {
    if (text.len <= buf.len) {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }

    if (buf.len <= 3) {
        @memcpy(buf, text[0..buf.len]);
        return buf;
    }

    const head_len = buf.len - 3;
    @memcpy(buf[0..head_len], text[0..head_len]);
    @memcpy(buf[head_len..], "...");
    return buf;
}

fn averageSessionRate(profile: data.PumpProfile) u16 {
    var total: u32 = 0;
    for (profile.session_rates) |rate| total += rate;
    const rounded = (total + profile.session_rates.len / 2) / profile.session_rates.len;
    return @intCast(rounded);
}

fn profileTotalMs(profile: data.PumpProfile) u64 {
    return @as(u64, @intCast(profile.session_rates.len)) * std.time.ms_per_s;
}

fn pickRandomProfileIndex(random: std.Random, current_idx: usize) usize {
    if (data.PUMP_PROFILES.len <= 1) return current_idx;

    var idx = current_idx;
    while (idx == current_idx) {
        idx = random.intRangeLessThan(usize, 0, data.PUMP_PROFILES.len);
    }
    return idx;
}

test "planner sweeps each profile before entering random rotation" {
    var planner = PumpPlanner.initWithSeed(7);

    try std.testing.expectEqual(@as(usize, 0), planner.current_profile_idx);
    for (1..data.PUMP_PROFILES.len) |expected_idx| {
        _ = planner.planTick(profileTotalMs(planner.currentProfile()));
        try std.testing.expectEqual(expected_idx, planner.current_profile_idx);
    }

    const before_random = planner.current_profile_idx;
    _ = planner.planTick(profileTotalMs(planner.currentProfile()));
    if (data.PUMP_PROFILES.len > 1) {
        try std.testing.expect(planner.current_profile_idx != before_random);
    }
}

test "planner preserves total profile volume across subsecond ticks" {
    var planner = PumpPlanner.initWithSeed(11);
    const profile = planner.currentProfile();
    const tick_ms: u64 = 250;
    const tick_count = @divExact(profileTotalMs(profile), tick_ms);

    var emitted: u32 = 0;
    for (0..tick_count) |_| {
        emitted += planner.planTick(tick_ms).emit_count;
    }

    var expected: u32 = 0;
    for (profile.session_rates) |rate| expected += rate;

    try std.testing.expectEqual(expected, emitted);
    if (data.PUMP_PROFILES.len > 1) {
        try std.testing.expectEqual(@as(usize, 1), planner.current_profile_idx);
    }
}

test "planner clamps oversized emit batches to u16 max" {
    var planner = PumpPlanner.initWithSeed(19);
    planner.session_budget = @as(f32, @floatFromInt(std.math.maxInt(u16))) + 42.5;

    const tick = planner.planTick(100);

    try std.testing.expectEqual(std.math.maxInt(u16), tick.emit_count);
    try std.testing.expectApproxEqAbs(@as(f32, 42.5), planner.session_budget, 0.001);
}
