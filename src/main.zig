const std = @import("std");
const fs = std.fs;
const commands = @import("commands/commands.zig");
const styles = @import("styles.zig");

const Color = styles.Color;
const P = styles.P;

const version = "0.4.0";

const Command = enum {
    search,
    detail,
    use,
    install,
    add,
    upgrade,
    config,
    zen,
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
    var keyword: ?[]const u8 = null;
    var search_mode: commands.search.SearchMode = .templates;
    var lang: ?[]const u8 = null;
    var entry_name: []const u8 = "CLAUDE.md";
    var force = false;
    var list = false;
    var config_args_start: usize = 0;

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
        } else if (std.mem.eql(u8, arg, "add")) {
            cmd = .add;
        } else if (std.mem.eql(u8, arg, "zen")) {
            cmd = .zen;
        } else if (std.mem.eql(u8, arg, "upgrade")) {
            cmd = .upgrade;
        } else if (std.mem.eql(u8, arg, "config")) {
            cmd = .config;
            config_args_start = i + 1;
            break; // Rest of args go to config command
        }
        // Options
        else if (std.mem.eql(u8, arg, "--command")) {
            search_mode = .command;
        } else if (std.mem.eql(u8, arg, "--conduct")) {
            search_mode = .conduct;
        } else if (std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                lang = args[i];
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
        // Positional argument
        else if (!std.mem.startsWith(u8, arg, "-")) {
            if (cmd == .search and keyword == null) {
                keyword = arg;
            } else if (template_name == null and (cmd == .detail or cmd == .use or cmd == .install or cmd == .add)) {
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
            try commands.help.run(stdout);
        },
        .search => {
            try commands.search.run(stdout, stderr, allocator, keyword, search_mode, lang);
        },
        .detail => {
            const name = template_name orelse {
                try stderr.print("\n{s}{s}{s}Error:{s} template name required\n{s}Usage: {s}clumsies detail <name> [--lang <code>]{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
                return;
            };
            const effective_lang = try commands.config.getLang(allocator, lang);
            defer allocator.free(effective_lang);
            try commands.detail.run(stdout, stderr, allocator, name, effective_lang);
        },
        .use => {
            const hash = template_name orelse {
                try stderr.print("\n{s}{s}{s}Error:{s} template hash required\n{s}Usage: {s}clumsies use <hash> [--lang <code>] [--name CURSOR.md]{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
                return;
            };
            const effective_lang = try commands.config.getLang(allocator, lang);
            defer allocator.free(effective_lang);
            try commands.use.run(stdout, stderr, allocator, hash, effective_lang, entry_name, force);
        },
        .install => {
            try commands.install.run(stdout, stderr, allocator, template_name, list, force);
        },
        .add => {
            const hash = template_name orelse {
                try stderr.print("\n{s}{s}{s}Error:{s} prompt hash required\n{s}Usage: {s}clumsies add <hash> [--force]{s}\n\n", .{ P, Color.bold, Color.red, Color.reset, P, Color.cyan, Color.reset });
                return;
            };
            try commands.add.run(stdout, stderr, allocator, hash, force);
        },
        .zen => {
            try commands.zen.run(stdout);
        },
        .upgrade => {
            try commands.upgrade.run(stdout, stderr, allocator, version);
        },
        .config => {
            const config_args = args[config_args_start..];
            try commands.config.run(stdout, stderr, allocator, config_args);
        },
    }
}
