const std = @import("std");
const attestation_upload = @import("../../attestation_upload.zig");
const HubClient = @import("../../hub_client.zig").HubClient;
const workspace_config = @import("../../workspace_config.zig");
const state = @import("../api/state.zig");

const log = std.log.scoped(.attestation_upload);

const ApiStateUploader = struct {
    allocator: std.mem.Allocator,
    api_state: *state.ApiState,
    last_status: ?std.http.Status = null,

    const AuthSnapshot = struct {
        hub_url: []const u8,
        access_token: []const u8,

        fn deinit(self: AuthSnapshot, allocator: std.mem.Allocator) void {
            allocator.free(self.hub_url);
            allocator.free(self.access_token);
        }
    };

    fn post(ctx: *anyopaque, body: []const u8) !bool {
        const self: *ApiStateUploader = @ptrCast(@alignCast(ctx));
        const snapshot = try self.snapshotAuth();
        defer snapshot.deinit(self.allocator);

        var client = HubClient.init(self.allocator, snapshot.hub_url, snapshot.access_token);
        client.client_id = self.api_state.clientIdHex();
        defer client.deinit();
        var response = client.post("/api/attestations", body) catch |err| {
            log.warn("POST /api/attestations transport error: {}", .{err});
            return err;
        };
        var response_active = true;
        defer if (response_active) response.deinit();

        if (response.status == .unauthorized) {
            const tokens = self.api_state.refreshAuthTokens(self.allocator, snapshot.access_token) catch |err| {
                log.warn("POST /api/attestations refresh failed: {s}", .{@errorName(err)});
                self.last_status = response.status;
                return false;
            };
            defer tokens.deinit(self.allocator);
            response.deinit();
            response_active = false;

            var retry_client = HubClient.init(self.allocator, snapshot.hub_url, tokens.access_token);
            retry_client.client_id = self.api_state.clientIdHex();
            defer retry_client.deinit();
            response = retry_client.post("/api/attestations", body) catch |err| {
                log.warn("POST /api/attestations transport error: {}", .{err});
                return err;
            };
            response_active = true;
        }

        self.last_status = response.status;
        if (@intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300) {
            return true;
        }
        log.warn(
            "POST /api/attestations rejected status={d} body={s}",
            .{ @intFromEnum(response.status), response.body },
        );
        return false;
    }

    fn uploader(self: *ApiStateUploader) @import("../../batch_upload.zig").Uploader {
        return .{ .ctx = @ptrCast(self), .postFn = ApiStateUploader.post };
    }

    fn snapshotAuth(self: *ApiStateUploader) !AuthSnapshot {
        self.api_state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.api_state.mutex.unlock(std.Options.debug_io);
        const hub_url = self.api_state.hub_url orelse return error.NotAuthenticated;
        const access_token = self.api_state.access_token orelse return error.NotAuthenticated;
        return .{
            .hub_url = try self.allocator.dupe(u8, hub_url),
            .access_token = try self.allocator.dupe(u8, access_token),
        };
    }
};

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
    var uploader: ApiStateUploader = .{ .allocator = alloc, .api_state = api_state };
    for (workspaces) |ws| {
        switch (attestation_upload.flushWorkspaceWithUploader(alloc, ws.ws_id, uploader.uploader())) {
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
