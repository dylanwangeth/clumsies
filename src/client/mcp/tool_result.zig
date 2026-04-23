//! MCP tool response formatting. Builds the content envelope agents consume: success results
//! include human-readable text + machine-readable structuredContent; loaded rules include
//! parsed constraint IDs for the agent to reference in memory.refer calls.
const std = @import("std");
const encoding = @import("clumsies_lib").util.encoding;
const workspace_rule = @import("../rule.zig");
const tool_names = @import("tool_names.zig");

pub fn buildSuccessResult(allocator: std.mem.Allocator, structured_json: []const u8) ![]u8 {
    const esc_text = try encoding.jsonEscapeAlloc(allocator, structured_json);
    defer allocator.free(esc_text);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{s},\"isError\":false}}",
        .{ esc_text, structured_json },
    );
}

pub fn buildErrorResult(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const esc_message = try encoding.jsonEscapeAlloc(allocator, message);
    defer allocator.free(esc_message);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"structuredContent\":{{\"error\":\"{s}\"}},\"isError\":true}}",
        .{ esc_message, esc_message },
    );
}

pub fn serializeRuleList(
    allocator: std.mem.Allocator,
    items: []const workspace_rule.RuleItem,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        try appendRuleMetadata(allocator, &buf, item);
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

pub fn serializeLoadResultWithConstraints(
    allocator: std.mem.Allocator,
    result: *workspace_rule.LoadResult,
    workspace_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const esc_ws = try encoding.jsonEscapeAlloc(allocator, workspace_id);
    defer allocator.free(esc_ws);

    try buf.writer(allocator).print("{{\"workspaceId\":\"{s}\",\"items\":[", .{esc_ws});
    for (result.items.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(allocator, ',');

        if ((item.kind == .rule or item.kind == .workflow) and item.content != null) {
            var parsed = try workspace_rule.parseConstraints(allocator, item.content.?);
            defer parsed.deinit(allocator);

            try appendLoadedRuleWithConstraints(allocator, &buf, item, parsed.constraints.items);

            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '}') {
                buf.items.len -= 1;
            }

            try buf.appendSlice(allocator, ",\"constraints\":[");
            for (parsed.constraints.items, 0..) |c, cidx| {
                if (cidx > 0) try buf.append(allocator, ',');
                const esc_cid = try encoding.jsonEscapeAlloc(allocator, c.id);
                defer allocator.free(esc_cid);
                const esc_th = try encoding.jsonEscapeAlloc(allocator, c.text_hash);
                defer allocator.free(esc_th);
                try buf.writer(allocator).print(
                    "{{\"id\":\"{s}\",\"textHash\":\"{s}\"}}",
                    .{ esc_cid, esc_th },
                );
            }
            try buf.appendSlice(allocator, "]}");
        } else {
            try appendLoadedRule(allocator, &buf, item);
        }
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

fn appendRuleMetadata(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_rule.RuleItem,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);
    const esc_path = try encoding.jsonEscapeAlloc(allocator, item.path);
    defer allocator.free(esc_path);
    const esc_name = try encoding.jsonEscapeAlloc(allocator, item.name);
    defer allocator.free(esc_name);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"path\":\"{s}\",\"name\":\"{s}\",\"group\":",
        .{ esc_id, workspace_rule.kindToString(item.kind), esc_path, esc_name },
    );
    if (item.group) |group| {
        const esc_group = try encoding.jsonEscapeAlloc(allocator, group);
        defer allocator.free(esc_group);
        try buf.writer(allocator).print("\"{s}\"", .{esc_group});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.writer(allocator).print(",\"hash\":\"{s}\"", .{item.hash});
    if (item.description) |desc| {
        const esc_desc = try encoding.jsonEscapeAlloc(allocator, desc);
        defer allocator.free(esc_desc);
        try buf.writer(allocator).print(",\"description\":\"{s}\"", .{esc_desc});
    }
    if (item.has_draft) {
        try buf.appendSlice(allocator, ",\"hasDraft\":true");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendLoadedRule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_rule.LoadedRule,
) !void {
    return appendLoadedRuleWithConstraints(allocator, buf, item, &.{});
}

fn appendLoadedRuleWithConstraints(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    item: workspace_rule.LoadedRule,
    constraints: []const workspace_rule.ParsedConstraint,
) !void {
    const esc_id = try encoding.jsonEscapeAlloc(allocator, item.id);
    defer allocator.free(esc_id);
    const esc_path = try encoding.jsonEscapeAlloc(allocator, item.path);
    defer allocator.free(esc_path);

    try buf.writer(allocator).print(
        "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"path\":\"{s}\",\"changed\":{s},\"hash\":\"{s}\",\"hasDraft\":{s},",
        .{
            esc_id,
            workspace_rule.kindToString(item.kind),
            esc_path,
            if (item.changed) "true" else "false",
            item.hash,
            if (item.has_draft) "true" else "false",
        },
    );
    if (item.draft_base_hash) |bh| {
        const esc_bh = try encoding.jsonEscapeAlloc(allocator, bh);
        defer allocator.free(esc_bh);
        try buf.writer(allocator).print("\"draftBaseHash\":\"{s}\",", .{esc_bh});
    }
    try buf.appendSlice(allocator, "\"content\":");
    if (item.content) |content| {
        const needs_reminder = item.kind == .rule or item.kind == .workflow;
        if (needs_reminder) {
            var constraint_list_buf: std.ArrayList(u8) = .empty;
            defer constraint_list_buf.deinit(allocator);
            for (constraints) |c| {
                try constraint_list_buf.writer(allocator).print("  - {s}\n", .{c.id});
            }
            const constraint_list = if (constraint_list_buf.items.len > 0)
                constraint_list_buf.items
            else
                @as([]const u8, "  (no constraints parsed)\n");

            const reminder = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n---\n[clumsies] When you apply constraints from this rule, include them in a single {s} call at the end of your response.\nrefs entry fields: ruleId: {s}, ruleHash: {s}, constraintId: pick from below\n{s}---",
                .{ content, tool_names.refer, item.id, item.hash, constraint_list },
            );
            defer allocator.free(reminder);
            const esc_content = try encoding.jsonEscapeAlloc(allocator, reminder);
            defer allocator.free(esc_content);
            try buf.writer(allocator).print("\"{s}\"", .{esc_content});
        } else {
            const esc_content = try encoding.jsonEscapeAlloc(allocator, content);
            defer allocator.free(esc_content);
            try buf.writer(allocator).print("\"{s}\"", .{esc_content});
        }
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

test "buildSuccessResult wraps JSON in content envelope" {
    const allocator = std.testing.allocator;
    const result = try buildSuccessResult(allocator, "{\"count\":3}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"structuredContent\":{\"count\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"text\"") != null);
}

test "buildErrorResult sets isError true and includes message" {
    const allocator = std.testing.allocator;
    const result = try buildErrorResult(allocator, "workspace not found");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "workspace not found") != null);
}

test "buildErrorResult escapes special characters in message" {
    const allocator = std.testing.allocator;
    const result = try buildErrorResult(allocator, "path \"foo\\bar\"\nnewline");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"foo\\\\bar\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\nnewline") != null);
}

test "serializeRuleList produces valid items array" {
    const allocator = std.testing.allocator;
    const items = [_]workspace_rule.RuleItem{
        .{ .id = "p-1", .path = "rule/STYLE.md", .kind = .rule, .group = null, .hash = "abc123", .name = "STYLE", .priority = .normal },
    };
    const result = try serializeRuleList(allocator, &items);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"items\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"p-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"path\":\"rule/STYLE.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"kind\":\"rule\"") != null);
}
