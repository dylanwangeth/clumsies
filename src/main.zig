const std = @import("std");
const fs = std.fs;
const commands = @import("commands.zig");

const version = "0.2.2";

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const orange = "\x1b[38;5;214m";
    const red = "\x1b[31m";
    const cyan = "\x1b[36m";
};

// Left padding for all output
const P = "  ";

const Command = enum {
    search,
    detail,
    use,
    install,
    help,
    version,
    none,
};

pub fn main() !void {
    // Setup buffered stdout/stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command and options
    var cmd: Command = .none;
    var template_name: ?[]const u8 = null;
    var task_filter: ?[]const u8 = null;
    var keyword_filter: ?[]const u8 = null;
    var lang: ?commands.Language = null;
    var entry_name: []const u8 = "CLAUDE.md";
    var force = false;
    var list = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Global flags
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cmd = .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            cmd = .version;
        }
        // Commands
        else if (std.mem.eql(u8, arg, "search")) {
            cmd = .search;
        } else if (std.mem.eql(u8, arg, "detail")) {
            cmd = .detail;
        } else if (std.mem.eql(u8, arg, "use")) {
            cmd = .use;
        } else if (std.mem.eql(u8, arg, "install")) {
            cmd = .install;
        }
        // Options
        else if (std.mem.eql(u8, arg, "--task") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 < args.len) {
                i += 1;
                task_filter = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--kw") or std.mem.eql(u8, arg, "-k")) {
            if (i + 1 < args.len) {
                i += 1;
                keyword_filter = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                const lang_arg = args[i];
                if (std.mem.eql(u8, lang_arg, "zh") or std.mem.eql(u8, lang_arg, "cn") or std.mem.eql(u8, lang_arg, "chinese")) {
                    lang = .zh;
                } else if (std.mem.eql(u8, lang_arg, "en") or std.mem.eql(u8, lang_arg, "english")) {
                    lang = .en;
                } else {
                    try stderr.print("\n{s}{s}{s}Error:{s} Unknown language: {s}. Use {s}'en'{s} or {s}'zh'{s}.\n\n", .{ P, Color.bold, Color.red, Color.reset, lang_arg, Color.cyan, Color.reset, Color.cyan, Color.reset });
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                i += 1;
                entry_name = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            if (cmd == .install) {
                list = true;
            }
        }
        // Positional argument (template name)
        else if (!std.mem.startsWith(u8, arg, "-")) {
            if (template_name == null and (cmd == .detail or cmd == .use or cmd == .install)) {
                template_name = arg;
            }
        }
    }

    // Execute command
    switch (cmd) {
        .version => {
            try stdout.print("\n{s}{s}{s}clumsies{s} {s}\n\n", .{ P, Color.bold, Color.orange, Color.reset, version });
        },
        .help, .none => {
            try commands.printHelp(stdout);
        },
        .search => {
            try commands.cmdSearch(stdout, stderr, allocator, task_filter, keyword_filter);
        },
        .detail => {
            const name = template_name orelse {
                try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies detail <name> [--lang en|zh]{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
                return;
            };
            try commands.cmdDetail(stdout, stderr, allocator, name, lang orelse .en);
        },
        .use => {
            const name = template_name orelse {
                try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies use <name> [--lang en|zh] [--name CURSOR.md]{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
                return;
            };
            try commands.cmdUse(stdout, stderr, allocator, name, lang orelse .en, entry_name, force);
        },
        .install => {
            try commands.cmdInstall(stdout, stderr, allocator, template_name, list, force);
        },
    }
}
