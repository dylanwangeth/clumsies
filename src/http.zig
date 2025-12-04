const std = @import("std");

const REGISTRY_BASE = "https://raw.githubusercontent.com/dylanwangeth/clumsies-registry/main";
const API_BASE = "https://api.github.com/repos/dylanwangeth/clumsies-registry";
const INDEX_URL = REGISTRY_BASE ++ "/index.json";

pub const HttpError = error{
    RequestFailed,
    InvalidResponse,
    NotFound,
    RateLimited,
    OutOfMemory,
};

/// Download a file from the registry
pub fn downloadFile(allocator: std.mem.Allocator, path: []const u8) HttpError![]const u8 {
    const url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ REGISTRY_BASE, path }) catch return HttpError.OutOfMemory;
    defer allocator.free(url);

    return fetchUrl(allocator, url);
}

/// Fetch content from a URL
pub fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) HttpError![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return HttpError.InvalidResponse;

    // Use allocating writer for response body
    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    var redirect_buffer: [8 * 1024]u8 = undefined;

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .redirect_buffer = &redirect_buffer,
        .response_writer = &response_writer.writer,
    }) catch return HttpError.RequestFailed;

    if (result.status == .not_found) {
        return HttpError.NotFound;
    }

    if (result.status == .forbidden or result.status == .too_many_requests) {
        return HttpError.RateLimited;
    }

    if (result.status != .ok) {
        return HttpError.RequestFailed;
    }

    return response_writer.toOwnedSlice() catch return HttpError.OutOfMemory;
}

/// Template metadata from index.json
pub const TemplateMeta = struct {
    name: []const u8,
    task: []const u8,
    keywords: [][]const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
};

/// Result struct for template index
pub const TemplateIndex = struct {
    templates: []TemplateMeta,
    allocator: std.mem.Allocator,
    json_str: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *TemplateIndex) void {
        self.parsed.deinit();
        self.allocator.free(self.json_str);
    }
};

/// Fetch remote index.json
pub fn fetchIndex(allocator: std.mem.Allocator) HttpError!TemplateIndex {
    const body = try fetchUrl(allocator, INDEX_URL);
    errdefer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        allocator.free(body);
        return HttpError.InvalidResponse;
    };
    errdefer parsed.deinit();

    const templates_val = parsed.value.object.get("templates") orelse {
        return HttpError.InvalidResponse;
    };

    var templates_list: std.ArrayListUnmanaged(TemplateMeta) = .{};
    errdefer templates_list.deinit(allocator);

    for (templates_val.array.items) |item| {
        const obj = item.object;

        // Parse keywords array
        var keywords_list: std.ArrayListUnmanaged([]const u8) = .{};
        if (obj.get("keywords")) |kw_val| {
            for (kw_val.array.items) |kw| {
                keywords_list.append(allocator, kw.string) catch return HttpError.OutOfMemory;
            }
        }

        const meta = TemplateMeta{
            .name = if (obj.get("name")) |v| v.string else "",
            .task = if (obj.get("task")) |v| v.string else "",
            .keywords = keywords_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
            .description = if (obj.get("description")) |v| v.string else "",
            .author = if (obj.get("author")) |v| v.string else "",
            .version = if (obj.get("version")) |v| v.string else "",
        };

        templates_list.append(allocator, meta) catch return HttpError.OutOfMemory;
    }

    return .{
        .templates = templates_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        .allocator = allocator,
        .json_str = body,
        .parsed = parsed,
    };
}

/// Result struct for file list
pub const FileList = struct {
    items: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FileList) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
    }
};

/// Get list of files in a template directory using GitHub API
pub fn listTemplateFiles(allocator: std.mem.Allocator, template_name: []const u8) HttpError!FileList {
    const url = std.fmt.allocPrint(
        allocator,
        "{s}/git/trees/main?recursive=1",
        .{API_BASE},
    ) catch return HttpError.OutOfMemory;
    defer allocator.free(url);

    const body = try fetchUrl(allocator, url);
    defer allocator.free(body);

    // Parse JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return HttpError.InvalidResponse;
    };
    defer parsed.deinit();

    const tree = parsed.value.object.get("tree") orelse return HttpError.InvalidResponse;

    var files: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (files.items) |item| {
            allocator.free(item);
        }
        files.deinit(allocator);
    }

    const prefix = std.fmt.allocPrint(allocator, "{s}/", .{template_name}) catch return HttpError.OutOfMemory;
    defer allocator.free(prefix);

    for (tree.array.items) |item| {
        const obj = item.object;
        const item_type = obj.get("type") orelse continue;
        if (!std.mem.eql(u8, item_type.string, "blob")) continue;

        const path = obj.get("path") orelse continue;
        const path_str = path.string;

        // Only include files from this template
        if (std.mem.startsWith(u8, path_str, prefix)) {
            const duped = allocator.dupe(u8, path_str) catch return HttpError.OutOfMemory;
            files.append(allocator, duped) catch return HttpError.OutOfMemory;
        }
    }

    const items = files.toOwnedSlice(allocator) catch return HttpError.OutOfMemory;
    return .{ .items = items, .allocator = allocator };
}
