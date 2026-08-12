//! CLI flag parser. Supports boolean flags (--yes), value flags (--agent codex), short forms
//! (-y, -a), and positional argument separation.
const std = @import("std");
const testing = std.testing;

pub const FlagKind = enum { boolean, value };

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
};

pub const ParseResult = struct {
    flags: [MAX_FLAGS]FlagState = [_]FlagState{.{}} ** MAX_FLAGS,

    pub fn boolean(self: *const ParseResult, comptime idx: usize) bool {
        return self.flags[idx].set;
    }

    pub fn value(self: *const ParseResult, comptime idx: usize) ?[]const u8 {
        return self.flags[idx].val;
    }

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
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
                try consumeValue(&result, specs, spec_idx, args, &i, err_ctx);
            } else {
                if (arg.len == 2) {
                    const ch = arg[1];
                    if (ch == 'h') return error.HelpRequested;
                    const spec_idx = findShort(specs, ch) orelse {
                        err_ctx.flag = arg;
                        return error.UnknownFlag;
                    };
                    try consumeValue(&result, specs, spec_idx, args, &i, err_ctx);
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
                            applyValue(&result, spec_idx, specs[spec_idx].kind, args[i]);
                        }
                    }
                }
            }
        } else {
            err_ctx.flag = arg;
            return error.UnexpectedArgument;
        }
    }

    return result;
}

fn consumeValue(result: *ParseResult, specs: []const FlagSpec, spec_idx: usize, args: []const []const u8, i: *usize, err_ctx: *ErrorContext) !void {
    switch (specs[spec_idx].kind) {
        .boolean => result.flags[spec_idx].set = true,
        .value => {
            if (i.* + 1 >= args.len) {
                err_ctx.flag = args[i.*];
                return error.MissingValue;
            }
            i.* += 1;
            applyValue(result, spec_idx, specs[spec_idx].kind, args[i.*]);
        },
    }
}

fn applyValue(result: *ParseResult, spec_idx: usize, kind: FlagKind, val: []const u8) void {
    switch (kind) {
        .boolean => unreachable,
        .value => result.flags[spec_idx].val = val,
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

test "parse short boolean flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"-a"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
}

test "parse long boolean flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"--alpha"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
}

test "parse combined short boolean flags" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
        .{ .short = 'b', .long = "beta", .kind = .boolean },
        .{ .short = 'c', .long = "charlie", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{"-abc"}, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
    try testing.expect(result.boolean(1));
    try testing.expect(result.boolean(2));
}

test "parse combined short flags with trailing value flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
        .{ .short = 'b', .long = "beta", .kind = .boolean },
        .{ .short = 'n', .long = "name", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    var result = try parse(&specs, testing.allocator, &.{ "-abn", "delta" }, &err_ctx);
    defer result.deinit(testing.allocator);
    try testing.expect(result.boolean(0));
    try testing.expect(result.boolean(1));
    try testing.expectEqualStrings("delta", result.value(2).?);
}

test "value flag before the end of a combined group errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'n', .long = "name", .kind = .value },
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
        .{ .short = 'b', .long = "beta", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-nab"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("-n", err_ctx.flag.?);
}

test "unknown long flag errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--foo"}, &err_ctx);
    try testing.expectError(error.UnknownFlag, result);
    try testing.expectEqualStrings("--foo", err_ctx.flag.?);
}

test "unknown short flag errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-x"}, &err_ctx);
    try testing.expectError(error.UnknownFlag, result);
    try testing.expectEqualStrings("-x", err_ctx.flag.?);
}

test "unexpected positional argument errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{ "-a", "extra" }, &err_ctx);
    try testing.expectError(error.UnexpectedArgument, result);
    try testing.expectEqualStrings("extra", err_ctx.flag.?);
}

test "short value flag without value errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'n', .long = "name", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-n"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("-n", err_ctx.flag.?);
}

test "long value flag without value errors" {
    const specs = [_]FlagSpec{
        .{ .short = 'n', .long = "name", .kind = .value },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--name"}, &err_ctx);
    try testing.expectError(error.MissingValue, result);
    try testing.expectEqualStrings("--name", err_ctx.flag.?);
}

test "short help flag returns HelpRequested" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-h"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}

test "long help flag returns HelpRequested" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"--help"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}

test "combined short flags stop on help flag" {
    const specs = [_]FlagSpec{
        .{ .short = 'a', .long = "alpha", .kind = .boolean },
    };
    var err_ctx: ErrorContext = .{};
    const result = parse(&specs, testing.allocator, &.{"-ah"}, &err_ctx);
    try testing.expectError(error.HelpRequested, result);
}
