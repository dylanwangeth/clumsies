const std = @import("std");

pub fn CoalescedRequest(comptime Request: type) type {
    return struct {
        const Self = @This();

        pending: ?Request = null,
        due_tick: u64 = 0,

        pub fn schedule(self: *Self, current_tick: u64, delay_ticks: u64, request: Request) void {
            if (self.pending) |existing| {
                if (existing.eql(request)) return;
            }
            self.pending = request;
            self.due_tick = current_tick + delay_ticks;
        }

        pub fn ready(self: *const Self, current_tick: u64) ?Request {
            const request = self.pending orelse return null;
            if (current_tick < self.due_tick) return null;
            return request;
        }

        pub fn clear(self: *Self) void {
            self.pending = null;
            self.due_tick = 0;
        }

        pub fn hasPending(self: *const Self) bool {
            return self.pending != null;
        }
    };
}

const TestRequest = struct {
    value: []const u8,

    fn eql(self: TestRequest, other: TestRequest) bool {
        return std.mem.eql(u8, self.value, other.value);
    }
};

test "CoalescedRequest waits until due tick" {
    var scheduler: CoalescedRequest(TestRequest) = .{};
    scheduler.schedule(10, 2, .{ .value = "a" });

    try std.testing.expect(scheduler.ready(11) == null);
    try std.testing.expectEqualStrings("a", scheduler.ready(12).?.value);
}

test "CoalescedRequest keeps identical request deadline" {
    var scheduler: CoalescedRequest(TestRequest) = .{};
    scheduler.schedule(10, 2, .{ .value = "a" });
    scheduler.schedule(11, 2, .{ .value = "a" });

    try std.testing.expectEqual(@as(u64, 12), scheduler.due_tick);
}

test "CoalescedRequest replaces changed request and deadline" {
    var scheduler: CoalescedRequest(TestRequest) = .{};
    scheduler.schedule(10, 2, .{ .value = "a" });
    scheduler.schedule(11, 2, .{ .value = "b" });

    try std.testing.expectEqual(@as(u64, 13), scheduler.due_tick);
    try std.testing.expectEqualStrings("b", scheduler.ready(13).?.value);
}
