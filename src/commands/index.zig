const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const lib = @import("clumsies_lib");
const encoding = lib.encoding;

const MAX_FILE_SIZE = 10 * 1024 * 1024;

/// PromptRef represents a prompt reference in a bundle
pub const PromptRef = struct {
    hash: []const u8,
    group: []const u8,
    name: []const u8,
    description: []const u8,
    format: []const u8,
};

/// Free all owned fields in a PromptRef list
pub fn freePromptRefs(allocator: std.mem.Allocator, refs: *std.ArrayList(PromptRef)) void {
    for (refs.items) |ref| {
        allocator.free(ref.hash);
        allocator.free(ref.group);
        allocator.free(ref.name);
        allocator.free(ref.description);
        allocator.free(ref.format);
    }
    refs.deinit(allocator);
}

/// Merge new prompt refs into prompts/index.json, skipping duplicates by hash
pub fn updatePromptsIndex(allocator: std.mem.Allocator, registry_path: []const u8, refs: []const PromptRef) !void {
    const prompts_dir = try std.fs.path.join(allocator, &.{ registry_path, "prompts" });
    defer allocator.free(prompts_dir);
    fs.cwd().makePath(prompts_dir) catch {};

    const index_path = try std.fs.path.join(allocator, &.{ prompts_dir, "index.json" });
    defer allocator.free(index_path);

    var index_content: std.ArrayList(u8) = .empty;
    defer index_content.deinit(allocator);
    try index_content.appendSlice(allocator, "{\n  \"prompts\": [");

    var seen_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = seen_hashes.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(@constCast(key.*));
        }
        seen_hashes.deinit();
    }

    var first = true;
    const timestamp = std.time.timestamp();

    if (fs.openFileAbsolute(index_path, .{})) |file| {
        const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
            file.close();
            return;
        };
        file.close();
        defer allocator.free(content);

        if (std.json.parseFromSlice(std.json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value.object.get("prompts")) |prompts| {
                for (prompts.array.items) |item| {
                    const item_hash = if (item.object.get("hash")) |h| h.string else continue;

                    const hash_copy = allocator.dupe(u8, item_hash) catch continue;
                    seen_hashes.put(hash_copy, {}) catch {
                        allocator.free(hash_copy);
                    };

                    if (!first) try index_content.appendSlice(allocator, ",");
                    try appendPromptEntry(allocator, &index_content, item);
                    first = false;
                }
            }
        } else |_| {}
    } else |_| {}

    for (refs) |ref| {
        if (seen_hashes.contains(ref.hash)) continue;

        const esc_name = try encoding.jsonEscapeAlloc(allocator, ref.name);
        defer allocator.free(esc_name);
        const esc_desc = try encoding.jsonEscapeAlloc(allocator, ref.description);
        defer allocator.free(esc_desc);
        const esc_format = try encoding.jsonEscapeAlloc(allocator, ref.format);
        defer allocator.free(esc_format);
        const esc_group = try encoding.jsonEscapeAlloc(allocator, ref.group);
        defer allocator.free(esc_group);

        const entry = try std.fmt.allocPrint(allocator, "{s}\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"group\": \"{s}\",\n      \"created_at\": \"{d}\"\n    }}", .{
            if (first) "" else ",",
            ref.hash,
            esc_name,
            esc_desc,
            esc_format,
            esc_group,
            timestamp,
        });
        defer allocator.free(entry);
        try index_content.appendSlice(allocator, entry);
        first = false;
    }

    try index_content.appendSlice(allocator, "\n  ]\n}\n");

    const idx_out = try fs.createFileAbsolute(index_path, .{});
    defer idx_out.close();
    try idx_out.writeAll(index_content.items);
}

/// Serialize a prompt JSON entry to a buffer
pub fn appendPromptEntry(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), item: std.json.Value) !void {
    const item_hash = if (item.object.get("hash")) |h| h.string else return;
    const item_name = if (item.object.get("name")) |n| n.string else "-";
    const item_desc = if (item.object.get("description")) |d| d.string else "-";
    const item_format = if (item.object.get("format")) |f| f.string else "md";
    const item_group = if (item.object.get("group")) |p| p.string else return error.MissingGroup;
    const item_created = if (item.object.get("created_at")) |c| c.string else "0";

    const esc_name = try encoding.jsonEscapeAlloc(allocator, item_name);
    defer allocator.free(esc_name);
    const esc_desc = try encoding.jsonEscapeAlloc(allocator, item_desc);
    defer allocator.free(esc_desc);
    const esc_format = try encoding.jsonEscapeAlloc(allocator, item_format);
    defer allocator.free(esc_format);
    const esc_group = try encoding.jsonEscapeAlloc(allocator, item_group);
    defer allocator.free(esc_group);

    const entry = try std.fmt.allocPrint(allocator, "\n    {{\n      \"hash\": \"{s}\",\n      \"name\": \"{s}\",\n      \"description\": \"{s}\",\n      \"format\": \"{s}\",\n      \"group\": \"{s}\",\n      \"created_at\": \"{s}\"\n    }}", .{ item_hash, esc_name, esc_desc, esc_format, esc_group, item_created });
    defer allocator.free(entry);
    try buf.appendSlice(allocator, entry);
}

/// Serialize a bundle JSON entry to a buffer (handles both new and old format)
pub fn appendBundleEntry(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), item: std.json.Value) !void {
    const item_name = if (item.object.get("name")) |n| n.string else return;
    const item_task = if (item.object.get("task")) |t| t.string else "-";
    const item_desc = if (item.object.get("description")) |d| d.string else "-";
    const item_created = if (item.object.get("created_at")) |c| c.string else "0";
    const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

    const esc_name = try encoding.jsonEscapeAlloc(allocator, item_name);
    defer allocator.free(esc_name);
    const esc_task = try encoding.jsonEscapeAlloc(allocator, item_task);
    defer allocator.free(esc_task);
    const esc_desc = try encoding.jsonEscapeAlloc(allocator, item_desc);
    defer allocator.free(esc_desc);

    const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{ esc_name, esc_task, esc_desc, item_created, item_meta });
    defer allocator.free(entry_start);
    try buf.appendSlice(allocator, entry_start);

    if (item.object.get("prompts")) |prompts| {
        for (prompts.array.items, 0..) |ref, idx| {
            const hash = if (ref.object.get("hash")) |h| h.string else continue;
            const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\" }}", .{
                if (idx > 0) "," else "",
                hash,
            });
            defer allocator.free(ref_entry);
            try buf.appendSlice(allocator, ref_entry);
        }
    }
    try buf.appendSlice(allocator, "]\n    }");
}

/// Append a prompt hash reference to a bundle JSON buffer, deduplicating by hash.
/// Returns true if the hash was actually added (not a duplicate).
pub fn appendBundlePromptRef(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), seen_hashes: *std.ArrayListUnmanaged([]const u8), prompt_first: *bool, hash: []const u8) !bool {
    for (seen_hashes.items) |seen_hash| {
        if (std.mem.eql(u8, seen_hash, hash)) return false;
    }

    try seen_hashes.append(allocator, hash);

    const ref_entry = try std.fmt.allocPrint(allocator, "{s}\n        {{ \"hash\": \"{s}\" }}", .{
        if (prompt_first.*) "" else ",",
        hash,
    });
    defer allocator.free(ref_entry);
    try buf.appendSlice(allocator, ref_entry);
    prompt_first.* = false;
    return true;
}

/// Add prompt hashes to an existing bundle in bundles/index.json.
/// Returns the number of prompts actually added (excluding duplicates).
pub fn addPromptsToBundle(allocator: std.mem.Allocator, registry_path: []const u8, bundle_name: []const u8, hashes: []const []const u8) !usize {
    const index_path = try std.fs.path.join(allocator, &.{ registry_path, "bundles/index.json" });
    defer allocator.free(index_path);

    const idx_file = fs.openFileAbsolute(index_path, .{}) catch return error.BundleIndexNotFound;
    const idx_content = idx_file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        idx_file.close();
        return error.BundleIndexNotFound;
    };
    idx_file.close();
    defer allocator.free(idx_content);

    const idx_parsed = std.json.parseFromSlice(std.json.Value, allocator, idx_content, .{}) catch
        return error.BundleIndexNotFound;
    defer idx_parsed.deinit();

    const bundles = idx_parsed.value.object.get("bundles") orelse return error.BundleNotFound;

    var new_index: std.ArrayListUnmanaged(u8) = .empty;
    defer new_index.deinit(allocator);
    try new_index.appendSlice(allocator, "{\n  \"bundles\": [");

    var b_first = true;
    var prompts_added: usize = 0;
    var found_bundle = false;

    for (bundles.array.items) |item| {
        const item_name = if (item.object.get("name")) |n| n.string else continue;

        if (!b_first) try new_index.appendSlice(allocator, ",");
        b_first = false;

        if (std.mem.eql(u8, item_name, bundle_name)) {
            found_bundle = true;
            const item_task = if (item.object.get("task")) |t| t.string else "-";
            const item_desc = if (item.object.get("description")) |d| d.string else "-";
            const item_created = if (item.object.get("created_at")) |c| c.string else "0";
            const item_meta = if (item.object.get("meta_prompt")) |m| m.string else "";

            const esc_name = try encoding.jsonEscapeAlloc(allocator, item_name);
            defer allocator.free(esc_name);
            const esc_task = try encoding.jsonEscapeAlloc(allocator, item_task);
            defer allocator.free(esc_task);
            const esc_desc = try encoding.jsonEscapeAlloc(allocator, item_desc);
            defer allocator.free(esc_desc);

            const entry_start = try std.fmt.allocPrint(allocator, "\n    {{\n      \"name\": \"{s}\",\n      \"task\": \"{s}\",\n      \"description\": \"{s}\",\n      \"created_at\": \"{s}\",\n      \"meta_prompt\": \"{s}\",\n      \"prompts\": [", .{ esc_name, esc_task, esc_desc, item_created, item_meta });
            defer allocator.free(entry_start);
            try new_index.appendSlice(allocator, entry_start);

            var prompt_first = true;
            var seen_hashes: std.ArrayListUnmanaged([]const u8) = .empty;
            defer seen_hashes.deinit(allocator);

            // Keep existing prompts
            if (item.object.get("prompts")) |existing_prompts| {
                for (existing_prompts.array.items) |ref| {
                    const ref_hash = if (ref.object.get("hash")) |h| h.string else continue;
                    _ = try appendBundlePromptRef(allocator, &new_index, &seen_hashes, &prompt_first, ref_hash);
                }
            }

            // Add new prompt hashes
            for (hashes) |hash| {
                if (try appendBundlePromptRef(allocator, &new_index, &seen_hashes, &prompt_first, hash)) {
                    prompts_added += 1;
                }
            }

            try new_index.appendSlice(allocator, "]\n    }");
        } else {
            try appendBundleEntry(allocator, &new_index, item);
        }
    }
    try new_index.appendSlice(allocator, "\n  ]\n}\n");

    if (!found_bundle) return error.BundleNotFound;

    const idx_out = fs.createFileAbsolute(index_path, .{}) catch return error.BundleIndexNotFound;
    defer idx_out.close();
    idx_out.writeAll(new_index.items) catch return error.BundleIndexNotFound;

    return prompts_added;
}

fn writeTestFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn readTmpFile(allocator: std.mem.Allocator, dir: std.fs.Dir, sub_path: []const u8) ![]const u8 {
    const file = try dir.openFile(sub_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, MAX_FILE_SIZE);
}

fn tmpDirAbsolutePath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    return tmp.dir.realpath(".", buf) catch "";
}

test "updatePromptsIndex: creates new index from empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const refs = [_]PromptRef{.{
        .hash = "aabbccdd",
        .name = "TEST",
        .description = "a test prompt",
        .format = "md",
        .group = "rule",
    }};
    try updatePromptsIndex(testing.allocator, path, &refs);

    const content = try readTmpFile(testing.allocator, tmp.dir, "prompts/index.json");
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const prompts = parsed.value.object.get("prompts").?;
    try testing.expectEqual(@as(usize, 1), prompts.array.items.len);
    try testing.expectEqualStrings("aabbccdd", prompts.array.items[0].object.get("hash").?.string);
    try testing.expectEqualStrings("TEST", prompts.array.items[0].object.get("name").?.string);
}

test "updatePromptsIndex: appends to existing index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("prompts");
    try writeTestFile(tmp.dir, "prompts/index.json",
        \\{"prompts":[{"hash":"existing1","name":"OLD","description":"-","format":"md","group":"rule","created_at":"0"}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const refs = [_]PromptRef{.{
        .hash = "newhash2",
        .name = "NEW",
        .description = "new one",
        .format = "md",
        .group = "cmd",
    }};
    try updatePromptsIndex(testing.allocator, path, &refs);

    const content = try readTmpFile(testing.allocator, tmp.dir, "prompts/index.json");
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const prompts = parsed.value.object.get("prompts").?;
    try testing.expectEqual(@as(usize, 2), prompts.array.items.len);
}

test "updatePromptsIndex: skips duplicate hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("prompts");
    try writeTestFile(tmp.dir, "prompts/index.json",
        \\{"prompts":[{"hash":"samehash","name":"OLD","description":"-","format":"md","group":"rule","created_at":"0"}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const refs = [_]PromptRef{.{
        .hash = "samehash",
        .name = "DUPLICATE",
        .description = "should be skipped",
        .format = "md",
        .group = "rule",
    }};
    try updatePromptsIndex(testing.allocator, path, &refs);

    const content = try readTmpFile(testing.allocator, tmp.dir, "prompts/index.json");
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const prompts = parsed.value.object.get("prompts").?;
    try testing.expectEqual(@as(usize, 1), prompts.array.items.len);
    try testing.expectEqualStrings("OLD", prompts.array.items[0].object.get("name").?.string);
}

test "updatePromptsIndex: escapes special chars in name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const refs = [_]PromptRef{.{
        .hash = "abc123",
        .name = "has\"quotes",
        .description = "desc with\nnewline",
        .format = "md",
        .group = "rule",
    }};
    try updatePromptsIndex(testing.allocator, path, &refs);

    const content = try readTmpFile(testing.allocator, tmp.dir, "prompts/index.json");
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const prompts = parsed.value.object.get("prompts").?;
    try testing.expectEqual(@as(usize, 1), prompts.array.items.len);
    try testing.expectEqualStrings("has\"quotes", prompts.array.items[0].object.get("name").?.string);
}

test "addPromptsToBundle: adds prompts to existing bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json",
        \\{"bundles":[{"name":"test-bundle","task":"-","description":"test","created_at":"0","meta_prompt":"","prompts":[{"hash":"existing1"}]}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const hashes = [_][]const u8{"newhash2"};
    const added = try addPromptsToBundle(testing.allocator, path, "test-bundle", &hashes);
    try testing.expectEqual(@as(usize, 1), added);

    const content = try readTmpFile(testing.allocator, tmp.dir, "bundles/index.json");
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const bundles = parsed.value.object.get("bundles").?;
    const bundle = bundles.array.items[0];
    const prompts = bundle.object.get("prompts").?;
    try testing.expectEqual(@as(usize, 2), prompts.array.items.len);
    try testing.expectEqualStrings("existing1", prompts.array.items[0].object.get("hash").?.string);
    try testing.expectEqualStrings("newhash2", prompts.array.items[1].object.get("hash").?.string);
}

test "addPromptsToBundle: skips duplicate hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json",
        \\{"bundles":[{"name":"test-bundle","task":"-","description":"test","created_at":"0","meta_prompt":"","prompts":[{"hash":"existing1"}]}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const hashes = [_][]const u8{"existing1"};
    const added = try addPromptsToBundle(testing.allocator, path, "test-bundle", &hashes);
    try testing.expectEqual(@as(usize, 0), added);
}

test "addPromptsToBundle: returns error for nonexistent bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundles");
    try writeTestFile(tmp.dir, "bundles/index.json",
        \\{"bundles":[{"name":"other","task":"-","description":"test","created_at":"0","meta_prompt":"","prompts":[]}]}
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmpDirAbsolutePath(&tmp, &buf);

    const hashes = [_][]const u8{"abc123"};
    try testing.expectError(error.BundleNotFound, addPromptsToBundle(testing.allocator, path, "nonexistent", &hashes));
}

test "appendPromptEntry: missing group returns error" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"hash":"abc123","name":"TEST","description":"-","format":"md","created_at":"0"}
    , .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try testing.expectError(error.MissingGroup, appendPromptEntry(testing.allocator, &buf, parsed.value));
}
