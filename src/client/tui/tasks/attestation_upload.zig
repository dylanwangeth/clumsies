const std = @import("std");
const attestation_upload = @import("../../attestation_upload.zig");
const workspace_config = @import("../../workspace_config.zig");
const state = @import("../api/state.zig");

pub fn start(api_state: *state.ApiState) !void {
    const gen = api_state.attestation_upload_pending.tryBegin() orelse return;
    const thread = std.Thread.spawn(.{}, worker, .{ api_state, gen }) catch |err| {
        api_state.attestation_upload_pending.complete(gen, .{ .failed = @errorName(err) });
        return err;
    };
    api_state.thread_registry.register(thread, api_state.backing_allocator) catch {};
}

fn worker(api_state: *state.ApiState, gen: u64) void {
    var arena = std.heap.ArenaAllocator.init(api_state.backing_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const workspaces = workspace_config.listWorkspaces(alloc) catch |err| switch (err) {
        error.NoConfigFound => {
            api_state.attestation_upload_pending.complete(gen, .{ .ok = .{} });
            return;
        },
        else => {
            api_state.attestation_upload_pending.complete(gen, .{ .failed = @errorName(err) });
            return;
        },
    };

    var summary: state.AttestationUploadSummary = .{ .workspace_count = workspaces.len };
    for (workspaces) |ws| {
        switch (attestation_upload.flushWorkspace(alloc, ws.ws_id)) {
            .flushed => |result| {
                summary.events_sent += result.events_sent;
                summary.batches_sent += result.batches_sent;
            },
            .not_authenticated => {
                api_state.attestation_upload_pending.complete(gen, .not_authenticated);
                return;
            },
            .failed => |err| {
                api_state.attestation_upload_pending.complete(gen, .{ .failed = @errorName(err) });
                return;
            },
        }
    }

    api_state.attestation_upload_pending.complete(gen, .{ .ok = summary });
}
