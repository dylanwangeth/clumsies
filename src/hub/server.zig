const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const auth = @import("auth.zig");
const workspace_handler = @import("workspace.zig");
const library_handler = @import("library.zig");
const trace_handler = @import("trace.zig");
const collab_handler = @import("collab.zig");
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

    var server = try HttpServer.init(allocator, .{
        .address = .all(config.port),
    }, ctx);

    const router = try server.router(.{});

    // Auth
    router.post("/api/auth/login", auth.handleLogin, .{});
    router.post("/api/auth/refresh", auth.handleRefresh, .{});
    router.get("/api/auth/me", auth.handleMe, .{});
    router.delete("/api/auth/token", auth.handleRevokeToken, .{});

    // Workspaces
    router.post("/api/workspaces", workspace_handler.handleCreate, .{});
    router.get("/api/workspaces/:ws_id", workspace_handler.handleGet, .{});
    router.patch("/api/workspaces/:ws_id", workspace_handler.handleUpdate, .{});
    router.get("/api/workspaces/:ws_id/manifest", workspace_handler.handleGetManifest, .{});
    router.post("/api/workspaces/:ws_id/prompts", workspace_handler.handleAddPrompt, .{});
    router.delete("/api/workspaces/:ws_id/prompts/:prompt_id", workspace_handler.handleRemovePrompt, .{});
    router.get("/api/workspaces/:ws_id/files", workspace_handler.handleListFiles, .{});
    router.get("/api/workspaces/:ws_id/file/content", workspace_handler.handleGetFileContent, .{});
    router.put("/api/workspaces/:ws_id/file", workspace_handler.handlePutFile, .{});
    router.delete("/api/workspaces/:ws_id/file", workspace_handler.handleDeleteFile, .{});

    // Library
    router.get("/api/org/library/manifest", library_handler.handleGetManifest, .{});
    router.get("/api/org/library/prompts", library_handler.handleListPrompts, .{});
    router.get("/api/org/library/prompt", library_handler.handleGetPrompt, .{});
    router.get("/api/org/library/prompt/content", library_handler.handleGetPromptContent, .{});
    router.get("/api/org/bundles", library_handler.handleListBundles, .{});
    router.get("/api/org/bundles/:name", library_handler.handleGetBundle, .{});

    // Trace & Stats
    router.post("/api/traces", trace_handler.handleUpload, .{});
    router.get("/api/stats", trace_handler.handleOrgStats, .{});
    router.get("/api/stats/workspace/:ws_id", trace_handler.handleWorkspaceStats, .{});
    router.get("/api/stats/prompt/:prompt_id", trace_handler.handlePromptStats, .{});

    // Collaboration
    router.post("/api/org/proposals", collab_handler.handleCreateProposal, .{});
    router.get("/api/org/proposals", collab_handler.handleListProposals, .{});
    router.get("/api/org/proposals/:id", collab_handler.handleGetProposal, .{});
    router.put("/api/org/proposals/:id", collab_handler.handleUpdateProposal, .{});
    router.post("/api/org/proposals/:id/comments", collab_handler.handleAddComment, .{});
    router.get("/api/org/proposals/:id/comments", collab_handler.handleListComments, .{});

    return .{ .http = server };
}

pub fn deinit(self: *Server) void {
    self.http.deinit();
}

pub fn listen(self: *Server) !void {
    try self.http.listen();
}
