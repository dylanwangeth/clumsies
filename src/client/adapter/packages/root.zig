const std = @import("std");
const types = @import("types.zig");
const agy = @import("agy.zig");
const claude_code = @import("claude_code.zig");
const codex = @import("codex.zig");

pub const AdapterPackage = types.AdapterPackage;

const packages = [_]AdapterPackage{
    codex.package,
    claude_code.package,
    agy.package,
};

pub fn all() []const AdapterPackage {
    return &packages;
}

pub fn resolve(agent_name: []const u8) ?AdapterPackage {
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg.id, agent_name)) return pkg;
    }
    return null;
}
