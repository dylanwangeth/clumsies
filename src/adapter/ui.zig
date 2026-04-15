const std = @import("std");
const builtin = @import("builtin");
const styles = @import("../styles.zig");

const Color = styles.Color;
const P = styles.P;

pub const Choice = struct {
    key: []const u8,
    label: []const u8,
    description: []const u8,
};

pub fn promptChoice(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    choices: []const Choice,
    default_index: usize,
) !usize {
    if (canUseInteractivePrompt()) {
        return promptChoiceInteractive(stdout, prompt, choices, default_index) catch
            promptChoiceLine(stdout, allocator, prompt, choices, default_index);
    }

    return promptChoiceLine(stdout, allocator, prompt, choices, default_index);
}

pub fn promptYesNo(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_yes: bool,
) !bool {
    if (canUseInteractivePrompt()) {
        return promptYesNoInteractive(stdout, prompt, default_yes) catch
            promptYesNoLine(stdout, allocator, prompt, default_yes);
    }

    return promptYesNoLine(stdout, allocator, prompt, default_yes);
}

fn promptYesNoLine(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    default_yes: bool,
) !bool {
    while (true) {
        try stdout.print(
            "{s}{s}{s}{s} [{s}] ",
            .{ P, Color.bold, prompt, Color.reset, if (default_yes) "Y/n" else "y/N" },
        );
        try stdout.flush();
        const line_opt = try readLineTrimmedAlloc(allocator);
        if (line_opt == null) return default_yes;
        const line = line_opt.?;
        defer allocator.free(line);
        if (line.len == 0) return default_yes;
        if (std.ascii.eqlIgnoreCase(line, "y") or std.ascii.eqlIgnoreCase(line, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(line, "n") or std.ascii.eqlIgnoreCase(line, "no")) return false;
        try stdout.print("{s}{s}Please answer y or n.{s}\n", .{ P, Color.orange, Color.reset });
        try stdout.flush();
    }
}

fn promptChoiceLine(
    stdout: *std.Io.Writer,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    choices: []const Choice,
    default_index: usize,
) !usize {
    try stdout.print("{s}{s}{s}{s}{s}\n", .{ P, Color.bold, Color.orange, prompt, Color.reset });
    for (choices, 0..) |choice, idx| {
        if (choice.description.len != 0) {
            try stdout.print(
                "{s}  {s}{d}.{s} {s}{s}{s}  {s}{s}{s}{s}\n",
                .{
                    P,
                    Color.cyan,
                    idx + 1,
                    Color.reset,
                    Color.bold,
                    choice.label,
                    Color.reset,
                    Color.dim,
                    choice.description,
                    if (idx == default_index) " [default]" else "",
                    Color.reset,
                },
            );
        } else {
            try stdout.print(
                "{s}  {s}{d}.{s} {s}{s}{s}{s}\n",
                .{
                    P,
                    Color.cyan,
                    idx + 1,
                    Color.reset,
                    Color.bold,
                    choice.label,
                    if (idx == default_index) " [default]" else "",
                    Color.reset,
                },
            );
        }
    }

    while (true) {
        try stdout.print("{s}Enter choice {s}[{d}]{s}: ", .{ P, Color.dim, default_index + 1, Color.reset });
        try stdout.flush();
        const line_opt = try readLineTrimmedAlloc(allocator);
        if (line_opt == null) return default_index;
        const line = line_opt.?;
        defer allocator.free(line);
        if (line.len == 0) return default_index;

        const parsed_index = std.fmt.parseInt(usize, line, 10) catch null;
        if (parsed_index) |index| {
            if (index >= 1 and index <= choices.len) return index - 1;
        }

        for (choices, 0..) |choice, idx| {
            if (std.ascii.eqlIgnoreCase(line, choice.key) or std.ascii.eqlIgnoreCase(line, choice.label)) {
                return idx;
            }
        }

        try stdout.print(
            "{s}{s}Invalid choice.{s} Enter one of the numbers or names shown above.\n",
            .{ P, Color.orange, Color.reset },
        );
        try stdout.flush();
    }
}

fn promptChoiceInteractive(
    stdout: *std.Io.Writer,
    prompt: []const u8,
    choices: []const Choice,
    default_index: usize,
) !usize {
    if (comptime builtin.os.tag == .windows) return error.NotATerminal;
    if (choices.len == 0) return error.NoChoices;

    const stdin_fd = std.fs.File.stdin().handle;
    const old_termios = std.posix.tcgetattr(stdin_fd) catch return error.NotATerminal;
    var new_termios = old_termios;
    new_termios.lflag.ICANON = false;
    new_termios.lflag.ECHO = false;
    std.posix.tcsetattr(stdin_fd, .FLUSH, new_termios) catch return error.NotATerminal;
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, old_termios) catch {};

    try stdout.writeAll("\x1b[?25l");
    defer stdout.writeAll("\x1b[?25h") catch {};

    var selected_index = if (default_index < choices.len) default_index else 0;
    var rendered_lines = try renderChoiceFrame(stdout, prompt, choices, selected_index);

    while (true) {
        const key = try readMenuKey();
        switch (key) {
            .up => {
                const next_index = if (selected_index == 0) choices.len - 1 else selected_index - 1;
                if (next_index == selected_index) continue;
                selected_index = next_index;
                try rewindRenderedBlock(stdout, rendered_lines);
                rendered_lines = try renderChoiceFrame(stdout, prompt, choices, selected_index);
            },
            .down => {
                const next_index = if (selected_index + 1 >= choices.len) 0 else selected_index + 1;
                if (next_index == selected_index) continue;
                selected_index = next_index;
                try rewindRenderedBlock(stdout, rendered_lines);
                rendered_lines = try renderChoiceFrame(stdout, prompt, choices, selected_index);
            },
            .enter => {
                try rewindRenderedBlock(stdout, rendered_lines);
                try renderChoiceSummary(stdout, prompt, choices[selected_index].label);
                return selected_index;
            },
            .yes, .no => {},
            .other => {},
        }
    }
}

const MenuKey = enum {
    up,
    down,
    enter,
    yes,
    no,
    other,
};

fn canUseInteractivePrompt() bool {
    if (comptime builtin.os.tag == .windows) return false;
    return std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
}

fn promptYesNoInteractive(
    stdout: *std.Io.Writer,
    prompt: []const u8,
    default_yes: bool,
) !bool {
    if (comptime builtin.os.tag == .windows) return error.NotATerminal;
    const choices = [_]Choice{
        .{ .key = "yes", .label = "Yes", .description = "" },
        .{ .key = "no", .label = "No", .description = "" },
    };

    const stdin_fd = std.fs.File.stdin().handle;
    const old_termios = std.posix.tcgetattr(stdin_fd) catch return error.NotATerminal;
    var new_termios = old_termios;
    new_termios.lflag.ICANON = false;
    new_termios.lflag.ECHO = false;
    std.posix.tcsetattr(stdin_fd, .FLUSH, new_termios) catch return error.NotATerminal;
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, old_termios) catch {};

    try stdout.writeAll("\x1b[?25l");
    defer stdout.writeAll("\x1b[?25h") catch {};

    var selected_index: usize = if (default_yes) 0 else 1;
    var rendered_lines = try renderChoiceFrame(stdout, prompt, &choices, selected_index);

    while (true) {
        const key = try readMenuKey();
        switch (key) {
            .up => {
                const next_index = if (selected_index == 0) choices.len - 1 else selected_index - 1;
                if (next_index == selected_index) continue;
                selected_index = next_index;
                try rewindRenderedBlock(stdout, rendered_lines);
                rendered_lines = try renderChoiceFrame(stdout, prompt, &choices, selected_index);
            },
            .down => {
                const next_index = if (selected_index + 1 >= choices.len) 0 else selected_index + 1;
                if (next_index == selected_index) continue;
                selected_index = next_index;
                try rewindRenderedBlock(stdout, rendered_lines);
                rendered_lines = try renderChoiceFrame(stdout, prompt, &choices, selected_index);
            },
            .enter => {
                try rewindRenderedBlock(stdout, rendered_lines);
                try renderChoiceSummary(stdout, prompt, choices[selected_index].label);
                return selected_index == 0;
            },
            .yes => {
                try rewindRenderedBlock(stdout, rendered_lines);
                try renderChoiceSummary(stdout, prompt, "Yes");
                return true;
            },
            .no => {
                try rewindRenderedBlock(stdout, rendered_lines);
                try renderChoiceSummary(stdout, prompt, "No");
                return false;
            },
            .other => {},
        }
    }
}

fn renderChoiceFrame(
    stdout: *std.Io.Writer,
    prompt: []const u8,
    choices: []const Choice,
    selected_index: usize,
) !usize {
    var rendered_lines: usize = 0;

    try stdout.print("{s}{s}?{s} {s}\n", .{ P, Color.green, Color.reset, prompt });
    rendered_lines += 1;

    for (choices, 0..) |choice, idx| {
        if (idx == selected_index) {
            if (choice.description.len != 0) {
                try stdout.print(
                    "{s}{s}>{s} {s}{s}{s}  {s}{s}{s}\n",
                    .{
                        P,
                        Color.green,
                        Color.reset,
                        Color.bold,
                        choice.label,
                        Color.reset,
                        Color.dim,
                        choice.description,
                        Color.reset,
                    },
                );
            } else {
                try stdout.print(
                    "{s}{s}>{s} {s}{s}{s}\n",
                    .{ P, Color.green, Color.reset, Color.bold, choice.label, Color.reset },
                );
            }
        } else {
            if (choice.description.len != 0) {
                try stdout.print(
                    "{s}  {s}  {s}{s}{s}\n",
                    .{ P, choice.label, Color.dim, choice.description, Color.reset },
                );
            } else {
                try stdout.print("{s}  {s}\n", .{ P, choice.label });
            }
        }
        rendered_lines += 1;
    }

    try stdout.flush();
    return rendered_lines;
}

fn renderChoiceSummary(stdout: *std.Io.Writer, prompt: []const u8, label: []const u8) !void {
    try stdout.print(
        "{s}{s}?{s} {s} {s}{s}{s}\n",
        .{ P, Color.green, Color.reset, prompt, Color.cyan, label, Color.reset },
    );
    try stdout.flush();
}

fn rewindRenderedBlock(stdout: *std.Io.Writer, rendered_lines: usize) !void {
    if (rendered_lines == 0) return;
    try stdout.print("\r\x1b[{d}A\x1b[0J", .{rendered_lines});
}

fn readMenuKey() !MenuKey {
    const stdin = std.fs.File.stdin();
    var byte: [1]u8 = undefined;

    while (true) {
        const n = try stdin.read(&byte);
        if (n == 0) return .enter;

        switch (byte[0]) {
            '\r', '\n' => return .enter,
            'k', 'K' => return .up,
            'j', 'J' => return .down,
            'y', 'Y' => return .yes,
            'n', 'N' => return .no,
            '\x1b' => {
                var seq: [2]u8 = undefined;
                const first = try stdin.read(seq[0..1]);
                if (first == 0) return .other;
                const second = try stdin.read(seq[1..2]);
                if (second == 0) return .other;
                if (seq[0] == '[' and seq[1] == 'A') return .up;
                if (seq[0] == '[' and seq[1] == 'B') return .down;
                return .other;
            },
            else => return .other,
        }
    }
}

fn readLineTrimmedAlloc(allocator: std.mem.Allocator) !?[]u8 {
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.fs.File.stdin().read(&byte) catch return null;
        if (n == 0) {
            if (line_buf.items.len == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        try line_buf.append(allocator, byte[0]);
    }

    const line = try allocator.dupe(u8, std.mem.trim(u8, line_buf.items, " \t\r"));
    return @as(?[]u8, line);
}
