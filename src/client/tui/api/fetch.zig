const std = @import("std");
const HubClient = @import("../../hub_client.zig").HubClient;
const data = @import("../view_types.zig");
const model = @import("model.zig");
const parse = @import("parse.zig");
const state = @import("state.zig");

pub fn startFetch(
    api_state: *state.ApiState,
    hub_url: []const u8,
    access_token: []const u8,
) !std.Thread {
    const alloc = api_state.allocator();
    const url_copy = try alloc.dupe(u8, hub_url);
    const token_copy = try alloc.dupe(u8, access_token);
    api_state.mutex.lock();
    api_state.hub_url = url_copy;
    api_state.access_token = token_copy;
    api_state.fetch_busy = true;
    api_state.mutex.unlock();
    return std.Thread.spawn(.{}, fetchAll, .{ api_state, url_copy, token_copy });
}

pub fn refetchAllAsync(api_state: *state.ApiState) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null or api_state.access_token == null) {
        api_state.mutex.unlock();
        return;
    }
    api_state.fetch_busy = true;
    const hub_url = api_state.hub_url.?;
    const access_token = api_state.access_token.?;
    api_state.mutex.unlock();

    _ = std.Thread.spawn(.{}, fetchAll, .{ api_state, hub_url, access_token }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

pub fn fetchWorkspaceAsync(api_state: *state.ApiState, ws_id: []const u8) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return;
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const request_alloc = api_state.backing_allocator;
    const ws_id_copy = request_alloc.dupe(u8, ws_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    _ = std.Thread.spawn(.{}, fetchWorkspace, .{ api_state, ws_id_copy }) catch {
        request_alloc.free(ws_id_copy);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

pub fn fetchPromptPrsAsync(api_state: *state.ApiState, prompt_path: []const u8) bool {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return false;
    }
    if (api_state.prompt_prs_for_path) |cached| {
        if (std.mem.eql(u8, cached, prompt_path)) {
            api_state.mutex.unlock();
            return true;
        }
    }
    const lib = api_state.prompts orelse {
        api_state.mutex.unlock();
        return false;
    };
    const request_alloc = api_state.backing_allocator;
    const prompt_id: ?[]const u8 = for (lib) |lp| {
        if (std.mem.eql(u8, lp.path, prompt_path))
            break request_alloc.dupe(u8, lp.prompt_id) catch null;
    } else null;
    api_state.mutex.unlock();
    if (prompt_id == null) return false;

    const path_copy = request_alloc.dupe(u8, prompt_path) catch {
        request_alloc.free(prompt_id.?);
        return false;
    };

    api_state.mutex.lock();
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    _ = std.Thread.spawn(.{}, fetchPromptPrs, .{ api_state, path_copy, prompt_id.? }) catch {
        request_alloc.free(path_copy);
        request_alloc.free(prompt_id.?);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    return true;
}

pub fn fetchPromptContentAsync(api_state: *state.ApiState, prompt_path: []const u8) bool {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return false;
    }
    if (api_state.prompt_content_name) |cached| {
        if (std.mem.eql(u8, cached, prompt_path) and api_state.prompt_content != null) {
            api_state.mutex.unlock();
            return true;
        }
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const request_alloc = api_state.backing_allocator;
    const path_copy = request_alloc.dupe(u8, prompt_path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    _ = std.Thread.spawn(.{}, fetchPromptContent, .{ api_state, path_copy }) catch {
        request_alloc.free(path_copy);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    return true;
}

pub fn fetchWorkspaceContextContentAsync(
    api_state: *state.ApiState,
    ws_id: []const u8,
    path: []const u8,
) bool {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return false;
    }
    if (api_state.workspace_context_content_ws_id) |cached_ws_id| {
        if (api_state.workspace_context_content_path) |cached_path| {
            if (std.mem.eql(u8, cached_ws_id, ws_id) and
                std.mem.eql(u8, cached_path, path) and
                api_state.workspace_context_content != null)
            {
                api_state.mutex.unlock();
                return true;
            }
        }
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const request_alloc = api_state.backing_allocator;
    const ws_id_copy = request_alloc.dupe(u8, ws_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    const path_copy = request_alloc.dupe(u8, path) catch {
        request_alloc.free(ws_id_copy);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    _ = std.Thread.spawn(.{}, fetchWorkspaceContextContent, .{ api_state, ws_id_copy, path_copy }) catch {
        request_alloc.free(path_copy);
        request_alloc.free(ws_id_copy);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return false;
    };
    return true;
}

pub fn fetchPrDetailAsync(api_state: *state.ApiState, pr_id: []const u8) void {
    api_state.mutex.lock();
    if (api_state.fetch_busy or api_state.hub_url == null) {
        api_state.mutex.unlock();
        return;
    }
    if (api_state.pr_detail_id) |cached| {
        if (std.mem.eql(u8, cached, pr_id)) {
            api_state.mutex.unlock();
            return;
        }
    }
    api_state.fetch_busy = true;
    api_state.mutex.unlock();

    const request_alloc = api_state.backing_allocator;
    const id_copy = request_alloc.dupe(u8, pr_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    _ = std.Thread.spawn(.{}, fetchPrDetail, .{ api_state, id_copy }) catch {
        request_alloc.free(id_copy);
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    };
}

pub fn postAction(
    api_state: *state.ApiState,
    alloc: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) ![]const u8 {
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.mutex.unlock();
        return error.NotConnected;
    };
    const token = api_state.access_token orelse {
        api_state.mutex.unlock();
        return error.NotConnected;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(alloc, hub_url, token);
    const resp = switch (method) {
        .POST => try client.post(path, body orelse "{}"),
        .PUT => try client.put(path, body orelse "{}"),
        .PATCH => try client.patch(path, body orelse "{}"),
        .DELETE => try client.delete(path),
        else => return error.UnsupportedMethod,
    };
    defer resp.deinit();

    if (resp.status == .ok or resp.status == .created or resp.status == .no_content) {
        return alloc.dupe(u8, resp.body);
    }
    return error.RequestFailed;
}

fn fetchPromptPrs(
    api_state: *state.ApiState,
    prompt_path: []const u8,
    prompt_id: []const u8,
) void {
    const request_alloc = api_state.backing_allocator;
    defer request_alloc.free(prompt_path);
    defer request_alloc.free(prompt_id);

    const alloc = api_state.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(request_alloc, hub_url, token);
    const path = std.fmt.allocPrint(
        request_alloc,
        "/api/org/prompt-prs?prompt_id={s}",
        .{prompt_id},
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(path);

    const resp = client.get(path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer resp.deinit();

    var prs: ?[]const model.PromptPr = null;
    if (resp.status == .ok) {
        prs = parse.parsePromptPrs(alloc, resp.body);
    }

    const stored_prompt_path = alloc.dupe(u8, prompt_path) catch null;
    const stored_prompt_id = alloc.dupe(u8, prompt_id) catch null;

    api_state.mutex.lock();
    api_state.prompt_prs = prs;
    api_state.prompt_prs_for_path = stored_prompt_path;
    api_state.prompt_prs_for_id = stored_prompt_id;
    api_state.pr_detail_id = null;
    api_state.pr_detail_diff = null;
    api_state.pr_detail_comments = null;
    api_state.pr_detail_trace_refers = 0;
    api_state.pr_detail_op_type = null;
    api_state.pr_detail_op_current_path = null;
    api_state.pr_detail_op_new_path = null;
    api_state.pr_detail_op_index = 0;
    api_state.pr_detail_op_total = 0;
    api_state.fetch_busy = false;
    api_state.mutex.unlock();
}

fn fetchAll(
    api_state: *state.ApiState,
    hub_url: []const u8,
    access_token: []const u8,
) void {
    defer {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    }
    api_state.mutex.lock();
    api_state.status = .connecting;
    api_state.mutex.unlock();

    const alloc = api_state.allocator();

    state.refreshLocalState(api_state);

    var client = HubClient.init(alloc, hub_url, access_token);

    const me_resp = client.get("/api/auth/me") catch {
        setStatus(api_state, .error_network);
        return;
    };
    defer me_resp.deinit();

    if (me_resp.status == .unauthorized) {
        setStatus(api_state, .error_auth);
        return;
    }
    if (me_resp.status != .ok) {
        setStatus(api_state, .error_network);
        return;
    }

    const user = parse.parseUser(alloc, me_resp.body) orelse {
        setStatus(api_state, .error_network);
        return;
    };

    const directory = doFetchParse(
        &client,
        alloc,
        "/api/org/directory",
        model.DirectoryData,
        parse.parseDirectory,
    );
    const prompts_list = doFetchParse(
        &client,
        alloc,
        "/api/org/library/prompts",
        []const model.LibraryPrompt,
        parse.parseLibraryPrompts,
    );
    const org_stats = doFetchParse(
        &client,
        alloc,
        "/api/stats?period=daily&days=30",
        model.OrgStats,
        parse.parseOrgStats,
    );
    const bundles = doFetchParse(
        &client,
        alloc,
        "/api/org/bundles",
        []const model.BundleData,
        parse.parseBundles,
    );

    api_state.mutex.lock();
    api_state.current_user = user;
    api_state.directory = directory;
    api_state.prompts = prompts_list;
    api_state.bundles = bundles;
    api_state.org_stats = org_stats;
    api_state.status = .connected;
    api_state.mutex.unlock();
}

fn fetchPrDetail(api_state: *state.ApiState, pr_id: []const u8) void {
    const request_alloc = api_state.backing_allocator;
    defer request_alloc.free(pr_id);

    const alloc = api_state.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(request_alloc, hub_url, token);

    const detail_path = std.fmt.allocPrint(
        request_alloc,
        "/api/org/prompt-prs/{s}",
        .{pr_id},
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(detail_path);
    const detail_resp = client.get(detail_path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer detail_resp.deinit();

    var diff_lines: ?[]const []const u8 = null;
    var trace_refers: u16 = 0;
    var picked_op_type: ?[]const u8 = null;
    var picked_op_current_path: ?[]const u8 = null;
    var picked_op_new_path: ?[]const u8 = null;
    var picked_op_index: u16 = 0;
    var picked_op_total: u16 = 0;
    if (detail_resp.status == .ok) {
        const parsed_detail = std.json.parseFromSlice(
            @import("clumsies_lib").protocol.collab_api.PromptPrDetailResponse,
            alloc,
            detail_resp.body,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        ) catch null;
        if (parsed_detail) |p| {
            defer p.deinit();
            const target_id = blk: {
                api_state.mutex.lock();
                defer api_state.mutex.unlock();
                break :blk if (api_state.prompt_prs_for_id) |id|
                    request_alloc.dupe(u8, id) catch null
                else
                    null;
            };
            var pick_idx: ?usize = null;
            if (target_id) |tid| {
                defer request_alloc.free(tid);
                for (p.value.operations, 0..) |op, i| {
                    if (op.prompt_id) |pid| {
                        if (std.mem.eql(u8, pid, tid)) {
                            pick_idx = i;
                            break;
                        }
                    }
                }
            }
            if (pick_idx == null and p.value.operations.len > 0) pick_idx = 0;

            picked_op_total = @intCast(@min(p.value.operations.len, std.math.maxInt(u16)));
            if (pick_idx) |i| {
                const op = p.value.operations[i];
                const base = op.base_content orelse "";
                const proposed = op.content orelse "";
                diff_lines = computeDiffLines(alloc, base, proposed);
                picked_op_type = alloc.dupe(u8, op.type) catch null;
                if (op.current_path) |cp| picked_op_current_path = alloc.dupe(u8, cp) catch null;
                if (op.path) |np| picked_op_new_path = alloc.dupe(u8, np) catch null;
                picked_op_index = @intCast(@min(i, std.math.maxInt(u16)));
            }
            trace_refers = @intCast(@min(p.value.trace_summary.refer_count, std.math.maxInt(u16)));
        }
    }

    const comments_path = std.fmt.allocPrint(
        request_alloc,
        "/api/org/prompt-prs/{s}/comments",
        .{pr_id},
    ) catch null;
    var comments: ?[]const data.CommentEntry = null;
    if (comments_path) |cpath| {
        defer request_alloc.free(cpath);
        const c_resp = client.get(cpath) catch null;
        if (c_resp) |resp| {
            defer resp.deinit();
            if (resp.status == .ok) {
                comments = parse.parseComments(alloc, resp.body);
            }
        }
    }

    const stored_pr_id = alloc.dupe(u8, pr_id) catch null;
    api_state.mutex.lock();
    api_state.pr_detail_id = stored_pr_id;
    api_state.pr_detail_diff = diff_lines;
    api_state.pr_detail_comments = comments;
    api_state.pr_detail_trace_refers = trace_refers;
    api_state.pr_detail_op_type = picked_op_type;
    api_state.pr_detail_op_current_path = picked_op_current_path;
    api_state.pr_detail_op_new_path = picked_op_new_path;
    api_state.pr_detail_op_index = picked_op_index;
    api_state.pr_detail_op_total = picked_op_total;
    api_state.fetch_busy = false;
    api_state.mutex.unlock();
}

fn computeDiffLines(
    alloc: std.mem.Allocator,
    base: []const u8,
    proposed: []const u8,
) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var base_it = std.mem.splitScalar(u8, base, '\n');
    var prop_it = std.mem.splitScalar(u8, proposed, '\n');

    while (true) {
        const b = base_it.next();
        const p = prop_it.next();
        if (b == null and p == null) break;
        if (b != null and p != null and std.mem.eql(u8, b.?, p.?)) {
            lines.append(
                alloc,
                std.fmt.allocPrint(alloc, "  {s}", .{b.?}) catch continue,
            ) catch continue;
        } else {
            if (b) |bl| {
                lines.append(
                    alloc,
                    std.fmt.allocPrint(alloc, "- {s}", .{bl}) catch continue,
                ) catch continue;
            }
            if (p) |pl| {
                lines.append(
                    alloc,
                    std.fmt.allocPrint(alloc, "+ {s}", .{pl}) catch continue,
                ) catch continue;
            }
        }
    }
    return lines.items;
}

fn fetchWorkspace(api_state: *state.ApiState, ws_id: []const u8) void {
    const request_alloc = api_state.backing_allocator;
    defer request_alloc.free(ws_id);

    const alloc = api_state.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(request_alloc, hub_url, token);

    const files_path = std.fmt.allocPrint(
        request_alloc,
        "/api/workspaces/{s}/context/files",
        .{ws_id},
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(files_path);
    const files = doFetchParse(
        &client,
        alloc,
        files_path,
        []const model.ContextFileData,
        parse.parseContextFiles,
    );

    const manifest_path = std.fmt.allocPrint(
        request_alloc,
        "/api/workspaces/{s}/manifest",
        .{ws_id},
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(manifest_path);
    const ws_prompts = doFetchParse(
        &client,
        alloc,
        manifest_path,
        []const model.WsPromptData,
        parse.parseManifestPrompts,
    );

    const stored_ws_id = alloc.dupe(u8, ws_id) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };

    api_state.mutex.lock();
    api_state.ws_detail = .{
        .ws_id = stored_ws_id,
        .context_files = files orelse &.{},
        .ws_prompts = ws_prompts orelse &.{},
    };
    api_state.fetch_busy = false;
    api_state.mutex.unlock();
}

fn fetchPromptContent(api_state: *state.ApiState, prompt_path: []const u8) void {
    const request_alloc = api_state.backing_allocator;
    defer request_alloc.free(prompt_path);

    const alloc = api_state.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(request_alloc, hub_url, token);
    const encoded_path = std.fmt.allocPrint(request_alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = prompt_path }, .formatQuery),
    }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(encoded_path);
    const path = std.fmt.allocPrint(
        request_alloc,
        "/api/org/library/prompt/content?path={s}",
        .{encoded_path},
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(path);

    const resp = client.get(path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer resp.deinit();

    if (resp.status == .ok) {
        const parsed_content = std.json.parseFromSlice(
            @import("clumsies_lib").protocol.library_api.PromptContentResponse,
            alloc,
            resp.body,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        ) catch null;
        const content = if (parsed_content) |p| blk: {
            defer p.deinit();
            break :blk alloc.dupe(u8, p.value.body) catch null;
        } else null;
        const stored_path = alloc.dupe(u8, prompt_path) catch null;

        api_state.mutex.lock();
        api_state.prompt_content = content;
        api_state.prompt_content_name = stored_path;
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    } else {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    }
}

fn fetchWorkspaceContextContent(
    api_state: *state.ApiState,
    ws_id: []const u8,
    path: []const u8,
) void {
    const request_alloc = api_state.backing_allocator;
    defer request_alloc.free(ws_id);
    defer request_alloc.free(path);

    const alloc = api_state.allocator();
    api_state.mutex.lock();
    const hub_url = api_state.hub_url orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    const token = api_state.access_token orelse {
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    api_state.mutex.unlock();

    var client = HubClient.init(request_alloc, hub_url, token);
    const encoded_path = std.fmt.allocPrint(request_alloc, "{f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = path }, .formatQuery),
    }) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(encoded_path);
    const request_path = std.fmt.allocPrint(
        request_alloc,
        "/api/workspaces/{s}/context/file/content?path={s}",
        .{ ws_id, encoded_path },
    ) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer request_alloc.free(request_path);

    const resp = client.get(request_path) catch {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
        return;
    };
    defer resp.deinit();

    if (resp.status == .ok) {
        const content = alloc.dupe(u8, resp.body) catch null;
        const stored_ws_id = alloc.dupe(u8, ws_id) catch null;
        const stored_path = alloc.dupe(u8, path) catch null;
        api_state.mutex.lock();
        api_state.workspace_context_content = content;
        api_state.workspace_context_content_ws_id = stored_ws_id;
        api_state.workspace_context_content_path = stored_path;
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    } else {
        api_state.mutex.lock();
        api_state.fetch_busy = false;
        api_state.mutex.unlock();
    }
}

fn setStatus(api_state: *state.ApiState, status: state.ConnectionStatus) void {
    api_state.mutex.lock();
    api_state.status = status;
    api_state.mutex.unlock();
}

fn doFetchParse(
    client: *HubClient,
    alloc: std.mem.Allocator,
    path: []const u8,
    comptime T: type,
    comptime parseFn: *const fn (std.mem.Allocator, []const u8) ?T,
) ?T {
    const resp = client.get(path) catch return null;
    defer resp.deinit();
    if (resp.status != .ok) return null;
    return parseFn(alloc, resp.body);
}
