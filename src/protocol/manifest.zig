const ids = @import("ids.zig");

pub const WorkspaceManifest = struct {
    ws_id: []const u8,
    name: []const u8,
    revision: i64,
    prompts: []const PromptEntry,
    context: []const ContextEntry,
};

pub const PromptEntry = struct {
    prompt_id: []const u8,
    content_hash: []const u8,
};

pub const ContextEntry = struct {
    path: []const u8,
    content_hash: []const u8,
};

pub const LibraryManifest = struct {
    revision: i64,
    prompts: []const PromptEntry,
};
