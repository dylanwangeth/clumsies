const std = @import("std");

pub fn nowNanos() i128 {
    return @intCast(std.Io.Clock.real.now(std.Options.debug_io).nanoseconds);
}

pub fn nowMillis() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

pub fn nowMicros() i64 {
    return @intCast(@divTrunc(nowNanos(), std.time.ns_per_us));
}

pub fn nowSeconds() i64 {
    return @divTrunc(nowMillis(), std.time.ms_per_s);
}
