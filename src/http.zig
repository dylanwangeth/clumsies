const std = @import("std");

const REGISTRY_BASE = "https://raw.githubusercontent.com/lilhammerfun/clumsies-registry/main";

pub const RELEASES_BASE = "https://github.com/lilhammerfun/clumsies/releases/latest/download";

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

/// Template metadata from templates/index.json
pub const TemplateInfo = struct {
    name: []const u8,
    task: []const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
    languages: [][]const u8,
};

/// Templates index result
pub const TemplatesIndex = struct {
    templates: []TemplateInfo,
    allocator: std.mem.Allocator,
    json_str: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *TemplatesIndex) void {
        for (self.templates) |tmpl| {
            self.allocator.free(tmpl.languages);
        }
        self.allocator.free(self.templates);
        self.parsed.deinit();
        self.allocator.free(self.json_str);
    }
};

/// Fetch templates/index.json
pub fn fetchTemplatesIndex(allocator: std.mem.Allocator) HttpError!TemplatesIndex {
    const body = try downloadFile(allocator, "templates/index.json");
    errdefer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        allocator.free(body);
        return HttpError.InvalidResponse;
    };
    errdefer parsed.deinit();

    const templates_val = parsed.value.object.get("templates") orelse {
        return HttpError.InvalidResponse;
    };

    var templates_list: std.ArrayListUnmanaged(TemplateInfo) = .{};
    errdefer templates_list.deinit(allocator);

    for (templates_val.array.items) |item| {
        const obj = item.object;

        var languages_list: std.ArrayListUnmanaged([]const u8) = .{};
        if (obj.get("languages")) |langs_val| {
            for (langs_val.array.items) |lang| {
                languages_list.append(allocator, lang.string) catch return HttpError.OutOfMemory;
            }
        }

        const info = TemplateInfo{
            .name = if (obj.get("name")) |v| v.string else "",
            .task = if (obj.get("task")) |v| v.string else "",
            .description = if (obj.get("description")) |v| v.string else "",
            .author = if (obj.get("author")) |v| v.string else "",
            .version = if (obj.get("version")) |v| v.string else "",
            .languages = languages_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        };

        templates_list.append(allocator, info) catch return HttpError.OutOfMemory;
    }

    return .{
        .templates = templates_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        .allocator = allocator,
        .json_str = body,
        .parsed = parsed,
    };
}

/// Template meta.json structure
pub const TemplateMeta = struct {
    name: []const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
    prompts_en: [][]const u8,
    prompts_zh: [][]const u8,
    files: [][]const u8,
};

/// Result for template meta
pub const TemplateMetaResult = struct {
    meta: TemplateMeta,
    allocator: std.mem.Allocator,
    json_str: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *TemplateMetaResult) void {
        self.allocator.free(self.meta.prompts_en);
        self.allocator.free(self.meta.prompts_zh);
        self.allocator.free(self.meta.files);
        self.parsed.deinit();
        self.allocator.free(self.json_str);
    }
};

/// Fetch template meta.json
pub fn fetchTemplateMeta(allocator: std.mem.Allocator, template_name: []const u8) HttpError!TemplateMetaResult {
    const path = std.fmt.allocPrint(allocator, "templates/{s}/meta.json", .{template_name}) catch return HttpError.OutOfMemory;
    defer allocator.free(path);

    const body = try downloadFile(allocator, path);
    errdefer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        allocator.free(body);
        return HttpError.InvalidResponse;
    };
    errdefer parsed.deinit();

    const obj = parsed.value.object;

    // Parse prompts.en array
    var prompts_en: std.ArrayListUnmanaged([]const u8) = .{};
    if (obj.get("prompts")) |prompts_obj| {
        if (prompts_obj.object.get("en")) |en_val| {
            for (en_val.array.items) |hash| {
                prompts_en.append(allocator, hash.string) catch return HttpError.OutOfMemory;
            }
        }
    }

    // Parse prompts.zh array
    var prompts_zh: std.ArrayListUnmanaged([]const u8) = .{};
    if (obj.get("prompts")) |prompts_obj| {
        if (prompts_obj.object.get("zh")) |zh_val| {
            for (zh_val.array.items) |hash| {
                prompts_zh.append(allocator, hash.string) catch return HttpError.OutOfMemory;
            }
        }
    }

    // Parse files array
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    if (obj.get("files")) |files_val| {
        for (files_val.array.items) |f| {
            files.append(allocator, f.string) catch return HttpError.OutOfMemory;
        }
    }

    return .{
        .meta = .{
            .name = if (obj.get("name")) |v| v.string else "",
            .description = if (obj.get("description")) |v| v.string else "",
            .author = if (obj.get("author")) |v| v.string else "",
            .version = if (obj.get("version")) |v| v.string else "",
            .prompts_en = prompts_en.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
            .prompts_zh = prompts_zh.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
            .files = files.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        },
        .allocator = allocator,
        .json_str = body,
        .parsed = parsed,
    };
}

/// Prompt metadata from prompts/index.json
pub const PromptMeta = struct {
    hash: []const u8,
    type: []const u8,
    task: []const u8,
    lang: []const u8,
    path: []const u8,
    author: []const u8,
    name: []const u8,
    description: []const u8,
};

/// Prompts index result
pub const PromptsIndex = struct {
    prompts: []PromptMeta,
    allocator: std.mem.Allocator,
    json_str: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *PromptsIndex) void {
        self.allocator.free(self.prompts);
        self.parsed.deinit();
        self.allocator.free(self.json_str);
    }

    pub fn findByHash(self: *const PromptsIndex, hash: []const u8) ?PromptMeta {
        for (self.prompts) |p| {
            if (std.mem.eql(u8, p.hash, hash)) {
                return p;
            }
        }
        return null;
    }
};

/// Fetch prompts/index.json
pub fn fetchPromptsIndex(allocator: std.mem.Allocator) HttpError!PromptsIndex {
    const body = try downloadFile(allocator, "prompts/index.json");
    errdefer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        allocator.free(body);
        return HttpError.InvalidResponse;
    };
    errdefer parsed.deinit();

    const prompts_val = parsed.value.object.get("prompts") orelse {
        return HttpError.InvalidResponse;
    };

    var prompts_list: std.ArrayListUnmanaged(PromptMeta) = .{};
    errdefer prompts_list.deinit(allocator);

    for (prompts_val.array.items) |item| {
        const obj = item.object;

        var name: []const u8 = "";
        var description: []const u8 = "";
        if (obj.get("publication")) |pub_obj| {
            name = if (pub_obj.object.get("name")) |v| v.string else "";
            description = if (pub_obj.object.get("description")) |v| v.string else "";
        }

        const meta = PromptMeta{
            .hash = if (obj.get("hash")) |v| v.string else "",
            .type = if (obj.get("type")) |v| v.string else "",
            .task = if (obj.get("task")) |v| v.string else "",
            .lang = if (obj.get("lang")) |v| v.string else "",
            .path = if (obj.get("path")) |v| v.string else "",
            .author = if (obj.get("author")) |v| v.string else "",
            .name = name,
            .description = description,
        };

        prompts_list.append(allocator, meta) catch return HttpError.OutOfMemory;
    }

    return .{
        .prompts = prompts_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        .allocator = allocator,
        .json_str = body,
        .parsed = parsed,
    };
}

/// Fetch prompt content by hash
pub fn fetchPromptContent(allocator: std.mem.Allocator, hash: []const u8) HttpError![]const u8 {
    const path = std.fmt.allocPrint(allocator, "prompts/{s}.md", .{hash}) catch return HttpError.OutOfMemory;
    defer allocator.free(path);

    return downloadFile(allocator, path);
}

/// Fetch template file (CLAUDE.md)
pub fn fetchTemplateFile(allocator: std.mem.Allocator, template_name: []const u8, lang: []const u8, filename: []const u8) HttpError![]const u8 {
    const path = std.fmt.allocPrint(allocator, "templates/{s}/files/{s}/{s}", .{ template_name, lang, filename }) catch return HttpError.OutOfMemory;
    defer allocator.free(path);

    return downloadFile(allocator, path);
}

/// Strip YAML frontmatter from markdown content
pub fn stripFrontmatter(content: []const u8) []const u8 {
    if (content.len < 4) return content;

    // Check if content starts with "---"
    if (!std.mem.startsWith(u8, content, "---")) {
        return content;
    }

    // Find the closing "---"
    var i: usize = 3;
    while (i < content.len) {
        if (content[i] == '\n') {
            const remaining = content[i + 1 ..];
            if (std.mem.startsWith(u8, remaining, "---")) {
                // Skip past the closing "---" and any following newline
                var end_idx = i + 1 + 3;
                if (end_idx < content.len and content[end_idx] == '\n') {
                    end_idx += 1;
                }
                return content[end_idx..];
            }
        }
        i += 1;
    }

    return content;
}

// Keep old API for backward compatibility during transition
pub const TemplateMeta_Old = struct {
    name: []const u8,
    task: []const u8,
    keywords: [][]const u8,
    files: [][]const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
};

pub const TemplateIndex = struct {
    templates: []TemplateMeta_Old,
    allocator: std.mem.Allocator,
    json_str: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *TemplateIndex) void {
        for (self.templates) |tmpl| {
            self.allocator.free(tmpl.keywords);
            self.allocator.free(tmpl.files);
        }
        self.allocator.free(self.templates);
        self.parsed.deinit();
        self.allocator.free(self.json_str);
    }
};

/// Fetch remote index.json - redirects to new API
pub fn fetchIndex(allocator: std.mem.Allocator) HttpError!TemplateIndex {
    // Fetch new templates index
    var templates_idx = try fetchTemplatesIndex(allocator);
    defer templates_idx.deinit();

    // Convert to old format for backward compatibility
    var templates_list: std.ArrayListUnmanaged(TemplateMeta_Old) = .{};
    errdefer templates_list.deinit(allocator);

    for (templates_idx.templates) |tmpl| {
        // For each template, fetch its meta to get file list
        var meta_result = fetchTemplateMeta(allocator, tmpl.name) catch {
            // Skip templates that can't be fetched
            continue;
        };
        defer meta_result.deinit();

        // Build files list from template structure
        var files_list: std.ArrayListUnmanaged([]const u8) = .{};

        // Add entry files for each language
        for (tmpl.languages) |lang| {
            for (meta_result.meta.files) |file| {
                const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ lang, file }) catch continue;
                files_list.append(allocator, file_path) catch continue;
            }
        }

        // Add prompts (we'll store hashes as file paths for install to process)
        for (meta_result.meta.prompts_en) |hash| {
            const path = std.fmt.allocPrint(allocator, "prompts/{s}", .{hash}) catch continue;
            files_list.append(allocator, path) catch continue;
        }

        const empty_keywords: [][]const u8 = allocator.alloc([]const u8, 0) catch return HttpError.OutOfMemory;

        const old_meta = TemplateMeta_Old{
            .name = tmpl.name,
            .task = "",
            .keywords = empty_keywords,
            .files = files_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
            .description = tmpl.description,
            .author = tmpl.author,
            .version = tmpl.version,
        };

        templates_list.append(allocator, old_meta) catch return HttpError.OutOfMemory;
    }

    // Create a minimal parsed result
    const empty_json = "{}";
    const empty_json_owned = allocator.dupe(u8, empty_json) catch return HttpError.OutOfMemory;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, empty_json_owned, .{}) catch return HttpError.InvalidResponse;

    return .{
        .templates = templates_list.toOwnedSlice(allocator) catch return HttpError.OutOfMemory,
        .allocator = allocator,
        .json_str = empty_json_owned,
        .parsed = parsed,
    };
}
