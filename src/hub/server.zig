const std = @import("std");
const httpz = @import("httpz");
const pg = @import("pg");
const auth = @import("auth.zig");
const workspace_handler = @import("workspace.zig");
const context_handler = @import("context.zig");
const team_handler = @import("team.zig");
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

    // Org Members
    router.get("/api/org/members", auth.handleListMembers, .{});
    router.post("/api/org/members", auth.handleInviteMember, .{});
    router.patch("/api/org/members/:user_id", auth.handleChangeRole, .{});
    router.delete("/api/org/members/:user_id", auth.handleRemoveMember, .{});

    // Teams
    router.post("/api/org/teams", team_handler.handleCreateTeam, .{});
    router.get("/api/org/teams", team_handler.handleListTeams, .{});
    router.get("/api/org/teams/:team_id", team_handler.handleGetTeam, .{});
    router.delete("/api/org/teams/:team_id", team_handler.handleDeleteTeam, .{});
    router.post("/api/org/teams/:team_id/members", team_handler.handleAddTeamMember, .{});
    router.delete("/api/org/teams/:team_id/members/:user_id", team_handler.handleRemoveTeamMember, .{});

    // Workspaces
    router.post("/api/workspaces", workspace_handler.handleCreate, .{});
    router.get("/api/workspaces/:ws_id", workspace_handler.handleGet, .{});
    router.patch("/api/workspaces/:ws_id", workspace_handler.handleUpdate, .{});
    router.delete("/api/workspaces/:ws_id", workspace_handler.handleDelete, .{});
    router.get("/api/workspaces/:ws_id/manifest", workspace_handler.handleGetManifest, .{});
    router.post("/api/workspaces/:ws_id/prompts", workspace_handler.handleAddPrompt, .{});
    router.delete("/api/workspaces/:ws_id/prompts/:prompt_id", workspace_handler.handleRemovePrompt, .{});
    // Context
    router.get("/api/workspaces/:ws_id/context/branches", context_handler.handleListBranches, .{});
    router.get("/api/workspaces/:ws_id/context/files", context_handler.handleListFiles, .{});
    router.get("/api/workspaces/:ws_id/context/file/content", context_handler.handleGetFileContent, .{});
    router.put("/api/workspaces/:ws_id/context/file", context_handler.handlePutFile, .{});
    router.delete("/api/workspaces/:ws_id/context/file", context_handler.handleDeleteFile, .{});
    router.post("/api/workspaces/:ws_id/context/prs", context_handler.handleCreatePr, .{});
    router.get("/api/workspaces/:ws_id/context/prs", context_handler.handleListPrs, .{});
    router.get("/api/workspaces/:ws_id/context/prs/:pr_id", context_handler.handleGetPr, .{});
    router.put("/api/workspaces/:ws_id/context/prs/:pr_id", context_handler.handleUpdatePr, .{});
    router.post("/api/workspaces/:ws_id/context/prs/:pr_id/comments", context_handler.handleAddPrComment, .{});
    router.post("/api/workspaces/:ws_id/context/branches/:branch/rebase", context_handler.handleRebase, .{});

    // Workspace Access Control
    router.get("/api/workspaces/:ws_id/access", workspace_handler.handleGetAccess, .{});
    router.put("/api/workspaces/:ws_id/access/teams/:team_id", workspace_handler.handleGrantTeamAccess, .{});
    router.delete("/api/workspaces/:ws_id/access/teams/:team_id", workspace_handler.handleRevokeTeamAccess, .{});
    router.put("/api/workspaces/:ws_id/access/users/:user_id", workspace_handler.handleGrantUserAccess, .{});
    router.delete("/api/workspaces/:ws_id/access/users/:user_id", workspace_handler.handleRevokeUserAccess, .{});

    // Library
    router.get("/api/org/library/manifest", library_handler.handleGetManifest, .{});
    router.get("/api/org/library/prompts", library_handler.handleListPrompts, .{});
    router.get("/api/org/library/prompt", library_handler.handleGetPrompt, .{});
    router.get("/api/org/library/prompt/content", library_handler.handleGetPromptContent, .{});
    router.get("/api/org/bundles", library_handler.handleListBundles, .{});
    router.get("/api/org/bundles/:name", library_handler.handleGetBundle, .{});
    router.post("/api/org/bundles", library_handler.handleCreateBundle, .{});
    router.put("/api/org/bundles/:name", library_handler.handleUpdateBundle, .{});
    router.delete("/api/org/bundles/:name", library_handler.handleDeleteBundle, .{});

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
