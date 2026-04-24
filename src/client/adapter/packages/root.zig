const std = @import("std");
const types = @import("types.zig");
const claude_code = @import("claude_code.zig");
const codex = @import("codex.zig");
const gemini_cli = @import("gemini_cli.zig");

pub const AdapterPackage = types.AdapterPackage;

const packages = [_]AdapterPackage{
    codex.package,
    claude_code.package,
    gemini_cli.package,
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
