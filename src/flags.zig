const std = @import("std");
const testing = std.testing;

pub const FlagKind = enum { boolean, value, multi_value };

pub const FlagSpec = struct {
    short: ?u8,
    long: ?[]const u8,
    kind: FlagKind,
};

pub const ErrorContext = struct {
    flag: ?[]const u8 = null,
    short_buf: [2]u8 = undefined,
};

const MAX_FLAGS = 16;

const FlagState = struct {
    set: bool = false,
    val: ?[]const u8 = null,
    multi: std.ArrayList([]const u8) = .empty,
};

pub const ParseResult = struct {
    flags: [MAX_FLAGS]FlagState = [_]FlagState{.{}} ** MAX_FLAGS,
    positionals: std.ArrayList([]const u8) = .empty,

    pub fn boolean(self: *const ParseResult, comptime idx: usize) bool {
        return self.flags[idx].set;
    }

    pub fn value(self: *const ParseResult, comptime idx: usize) ?[]const u8 {
        return self.flags[idx].val;
    }

    pub fn multiValues(self: *const ParseResult, comptime idx: usize) []const []const u8 {
        return self.flags[idx].multi.items;
    }

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (&self.flags) |*f| {
            f.multi.deinit(allocator);
        }
        self.positionals.deinit(allocator);
    }
};

pub fn parse(specs: []const FlagSpec, allocator: std.mem.Allocator, args: []const []const u8, err_ctx: *ErrorContext) !ParseResult {
    if (specs.len > MAX_FLAGS) @panic("specs exceeds MAX_FLAGS");

    var result: ParseResult = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }

        if (arg.len >= 2 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (arg.len == 2) {
                    err_ctx.flag = arg;
                    return error.UnknownFlag;
                }
                const name = arg[2..];
                const spec_idx = findLong(specs, name) orelse {
                    err_ctx.flag = arg;
                    return error.UnknownFlag;
                };
                try consumeValue(&result, specs, spec_idx, args, &i, err_ctx, allocator);
            } else {
                if (arg.len == 2) {
                    const ch = arg[1];
                    if (ch == 'h') return error.HelpRequested;
                    const spec_idx = findShort(specs, ch) orelse {
                        err_ctx.flag = arg;
                        return error.UnknownFlag;
                    };
                    try consumeValue(&result, specs, spec_idx, args, &i, err_ctx, allocator);
                } else {
                    const chars = arg[1..];
                    for (chars, 0..) |ch, j| {
                        if (ch == 'h') return error.HelpRequested;
                        const spec_idx = findShort(specs, ch) orelse {
                            err_ctx.flag = arg;
                            return error.UnknownFlag;
                        };
                        const is_last = j == chars.len - 1;
                        if (specs[spec_idx].kind == .boolean) {
                            result.flags[spec_idx].set = true;
                        } else {
                            if (!is_last) {
                                err_ctx.short_buf = .{ '-', ch };
                                err_ctx.flag = &err_ctx.short_buf;
                                return error.MissingValue;
                            }
                            if (i + 1 >= args.len) {
                                err_ctx.short_buf = .{ '-', ch };
                                err_ctx.flag = &err_ctx.short_buf;
                                return error.MissingValue;
                            }
                            i += 1;
                            try applyValue(&result, spec_idx, specs[spec_idx].kind, args[i], allocator);
                        }
                    }
                }
            }
        } else {
            try result.positionals.append(allocator, arg);
        }
    }

    return result;
}

fn consumeValue(result: *ParseResult, specs: []const FlagSpec, spec_idx: usize, args: []const []const u8, i: *usize, err_ctx: *ErrorContext, allocator: std.mem.Allocator) !void {
    switch (specs[spec_idx].kind) {
        .boolean => result.flags[spec_idx].set = true,
        .value, .multi_value => {
            if (i.* + 1 >= args.len) {
                err_ctx.flag = args[i.*];
                return error.MissingValue;
            }
            i.* += 1;
            try applyValue(result, spec_idx, specs[spec_idx].kind, args[i.*], allocator);
        },
    }
}

fn applyValue(result: *ParseResult, spec_idx: usize, kind: FlagKind, val: []const u8, allocator: std.mem.Allocator) !void {
    switch (kind) {
        .boolean => unreachable,
        .value => result.flags[spec_idx].val = val,
        .multi_value => {
            var iter = std.mem.splitScalar(u8, val, ',');
            while (iter.next()) |part| {
                try result.flags[spec_idx].multi.append(allocator, part);
            }
        },
    }
}

fn findLong(specs: []const FlagSpec, name: []const u8) ?usize {
    for (specs, 0..) |spec, idx| {
        if (spec.long) |long| {
            if (std.mem.eql(u8, long, name)) return idx;
        }
    }
    return null;
}

fn findShort(specs: []const FlagSpec, ch: u8) ?usize {
    for (specs, 0..) |spec, idx| {
        if (spec.short) |short| {
            if (short == ch) return idx;
        }
    }
    return null;
}

test "single boolean short flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"-Q"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
}

test "single boolean long flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"--quiet-git"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
}

test "combined short boolean flags -psQ" {
    const specs = [_]FlagSpec{
        .{ .short = 'p', .long = "prompts", .kind = .boolean },
        .{ .short = 's', .long = "sync", .kind = .boolean },
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"-psQ"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
    try testing.expect(result.boolean(1));
    try testing.expect(result.boolean(2));
}

test "combined short flag + tail value -psg foo" {
    const specs = [_]FlagSpec{
        .{ .short = 'p', .long = "prompts", .kind = .boolean },
        .{ .short = 's', .long = "sync", .kind = .boolean },
        .{ .short = 'g', .long = "group", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "-psg", "conduct" }, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
    try testing.expect(result.boolean(1));
    try testing.expectEqualStrings("conduct", result.value(2).?);
}

test "value flag in middle of combined group errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .value },
        .{ .short = 'p', .long = "prompts", .kind = .boolean },
        .{ .short = 's', .long = "sync", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-gps"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("-g", err_ctx.flag.?);
}

test "unknown flag errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--foo"}, &err_ctx);
    try testing.expectError(error.UnknownFlag, result);
    try testing.expectEqualStrings("--foo", err_ctx.flag.?);
}

test "unknown short flag errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-x"}, &err_ctx);
    try testing.expectError(error.UnknownFlag, result);
    try testing.expectEqualStrings("-x", err_ctx.flag.?);
}

test "multi_value comma separated -g A,B,C" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .multi_value },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "-g", "A,B,C" }, &err_ctx);
    defer result.deinit(testing.allocator);
    const vals = result.multiValues(0);
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqualStrings("A", vals[0]);
    try testing.expectEqualStrings("B", vals[1]);
    try testing.expectEqualStrings("C", vals[2]);
}

test "multi_value repeated flag -g A -g B" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .multi_value },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "-g", "A", "-g", "B" }, &err_ctx);
    defer result.deinit(testing.allocator);
    const vals = result.multiValues(0);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("A", vals[0]);
    try testing.expectEqualStrings("B", vals[1]);
}

test "multi_value combo: -g A,B -g C" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .multi_value },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "-g", "A,B", "-g", "C" }, &err_ctx);
    defer result.deinit(testing.allocator);
    const vals = result.multiValues(0);
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqualStrings("A", vals[0]);
    try testing.expectEqualStrings("B", vals[1]);
    try testing.expectEqualStrings("C", vals[2]);
}

test "positional args collected" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "foo", "-Q", "bar" }, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
    try testing.expectEqual(@as(usize, 2), result.positionals.items.len);
    try testing.expectEqualStrings("foo", result.positionals.items[0]);
    try testing.expectEqualStrings("bar", result.positionals.items[1]);
}

test "MissingValue: flag at end without value" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-g"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("-g", err_ctx.flag.?);
}

test "MissingValue: long flag at end without value" {
    const specs = [_]FlagSpec{
        .{ .short = 'g', .long = "group", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--group"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("--group", err_ctx.flag.?);
}

test "-h returns HelpRequested" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-h"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}

test "--help returns HelpRequested" {
    const specs = [_]FlagSpec{
        .{ .short = 'Q', .long = "quiet-git", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--help"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}

test "combined flags with -h returns HelpRequested" {
    const specs = [_]FlagSpec{
        .{ .short = 'p', .long = "prompts", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-ph"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}
