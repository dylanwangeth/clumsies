// Shared styles for CLI output

// ANSI color codes (Zig orange theme)
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const orange = "\x1b[38;5;214m"; // Zig orange (256-color mode)
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const cyan = "\x1b[36m";
};

// Left padding for all output (cargo style)
pub const P = "  ";
