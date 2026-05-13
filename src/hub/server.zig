//! Hub HTTP server setup. Configures routes for all API endpoints (auth, artifact, workspace,
//! context, collab, attestation, stats), applies CORS and rate limiting, and starts listening.
const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const auth = @import("auth.zig");
const workspace_handler = @import("workspace.zig");
const context_handler = @import("context.zig");
const artifact_handler = @import("artifact.zig");
const attestation_handler = @import("attestation.zig");
const collab_handler = @import("collab.zig");
const health_handler = @import("health.zig");
const review_handler = @import("review.zig");
const request_logger = @import("request_logger.zig");
const RateLimiter = @import("rate_limit.zig");
const Config = @import("config.zig");

const Server = @This();

http: HttpServer,

const HttpServer = httpz.Server(*Context);

pub const Context = struct {
    pool: *pg.Pool,
    config: Config,
    rate_limiter: *RateLimiter,
    auth_rate_limiter: *RateLimiter,
};

pub fn init(allocator: std.mem.Allocator, config: Config, pool: *pg.Pool) !Server {
    const ctx = try allocator.create(Context);

    const rl = try allocator.create(RateLimiter);
    rl.* = RateLimiter.init(allocator, 60, 200);

    const auth_rl = try allocator.create(RateLimiter);
    auth_rl.* = RateLimiter.init(allocator, 60, 10);

    ctx.* = .{
        .pool = pool,
        .config = config,
        .rate_limiter = rl,
        .auth_rate_limiter = auth_rl,
    };

    const listen_address = try resolveListenAddress(allocator, config.host, config.port);
    var server = try HttpServer.init(allocator, .{
        .address = .{ .addr = listen_address },
    }, ctx);

    const request_log_middleware = try server.middleware(request_logger, .{});
    const router = try server.router(.{ .middlewares = &.{request_log_middleware} });

    router.get("/api/health", health_handler.handle, .{});

    // Auth
    router.post("/api/auth/login", auth.handleLogin, .{});
    router.post("/api/auth/activate", auth.handleActivate, .{});
    router.post("/api/auth/refresh", auth.handleRefresh, .{});
    router.get("/api/auth/me", auth.handleMe, .{});
    router.patch("/api/auth/me", auth.handleUpdateMe, .{});
    router.delete("/api/auth/token", auth.handleRevokeToken, .{});

    // Org Members
    router.get("/api/members", auth.handleListMembers, .{});
    router.post("/api/members", auth.handleInviteMember, .{});
    router.patch("/api/members/:user_id", auth.handleChangeRole, .{});
    router.delete("/api/members/:user_id", auth.handleRemoveMember, .{});
    router.post("/api/members/:user_id/reissue-invite", auth.handleReissueInvite, .{});
    router.get("/api/prs", review_handler.handleListPrs, .{});

    // Workspaces
    router.post("/api/workspaces", workspace_handler.handleCreate, .{});
    router.get("/api/workspaces/:ws_id", workspace_handler.handleGet, .{});
    router.patch("/api/workspaces/:ws_id", workspace_handler.handleUpdate, .{});
    router.delete("/api/workspaces/:ws_id", workspace_handler.handleDelete, .{});
    router.get("/api/workspaces/:ws_id/manifest", workspace_handler.handleGetManifest, .{});
    router.post("/api/workspaces/:ws_id/rules", workspace_handler.handleAddRule, .{});
    router.post("/api/workspaces/:ws_id/rules/content", workspace_handler.handleBatchRuleContent, .{});
    router.post("/api/workspaces/:ws_id/rules/detach", workspace_handler.handleDetachRules, .{});
    router.delete("/api/workspaces/:ws_id/rules/:rule_id", workspace_handler.handleRemoveRule, .{});
    // Context
    router.get("/api/workspaces/:ws_id/context", context_handler.handleListFiles, .{});
    router.post("/api/workspaces/:ws_id/context/content", context_handler.handleBatchFileContent, .{});
    router.post("/api/workspaces/:ws_id/context/prs", context_handler.handleCreatePr, .{});
    router.get("/api/workspaces/:ws_id/context/prs", context_handler.handleListPrs, .{});
    router.get("/api/workspaces/:ws_id/context/prs/:pr_id", context_handler.handleGetPr, .{});
    router.put("/api/workspaces/:ws_id/context/prs/:pr_id", context_handler.handleUpdatePr, .{});
    router.post("/api/workspaces/:ws_id/context/prs/:pr_id/comments", context_handler.handleAddPrComment, .{});
    router.get("/api/workspaces/:ws_id/context/prs/:pr_id/comments", context_handler.handleListPrComments, .{});

    // Workspace Members
    router.get("/api/workspaces/:ws_id/members", workspace_handler.handleListMembers, .{});
    router.post("/api/workspaces/:ws_id/members", workspace_handler.handleInviteMember, .{});
    router.patch("/api/workspaces/:ws_id/members/:user_id", workspace_handler.handleChangeMemberRole, .{});
    router.delete("/api/workspaces/:ws_id/members/:user_id", workspace_handler.handleRemoveWsMember, .{});

    // Artifact
    router.get("/api/artifact/rules", artifact_handler.handleListRules, .{});
    router.post("/api/artifact/rules/content", artifact_handler.handleBatchRuleContent, .{});
    router.get("/api/bundles", artifact_handler.handleListBundles, .{});
    router.get("/api/bundles/:name", artifact_handler.handleGetBundle, .{});
    router.post("/api/bundles", artifact_handler.handleCreateBundle, .{});
    router.put("/api/bundles/:name", artifact_handler.handleUpdateBundle, .{});
    router.delete("/api/bundles/:name", artifact_handler.handleDeleteBundle, .{});

    // Attestation & Stats
    router.post("/api/attestations", attestation_handler.handleUpload, .{});
    router.get("/api/stats", attestation_handler.handleOrgStats, .{});
    router.get("/api/stats/workspace/:ws_id", attestation_handler.handleWorkspaceStats, .{});
    router.get("/api/stats/rule/:rule_id", attestation_handler.handleRuleStats, .{});

    // Rule PRs
    router.post("/api/prs", collab_handler.handleCreatePr, .{});
    router.get("/api/prs/:id", collab_handler.handleGetPr, .{});
    router.put("/api/prs/:id", collab_handler.handleUpdatePr, .{});
    router.post("/api/prs/:id/comments", collab_handler.handleAddComment, .{});
    router.get("/api/prs/:id/comments", collab_handler.handleListComments, .{});

    return .{ .http = server };
}

pub fn deinit(self: *Server) void {
    self.http.deinit();
}

fn resolveListenAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp(host, port)) |addr| return addr else |_| {}

    const addresses = std.net.getAddressList(allocator, host, port) catch
        return error.InvalidHost;
    defer addresses.deinit();
    if (addresses.addrs.len == 0) return error.InvalidHost;
    return addresses.addrs[0];
}

pub fn listen(self: *Server) !void {
    try self.http.listen();
}
