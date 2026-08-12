//! ANSI color codes and formatting constants for CLI output. Provides a consistent visual
//! language across all CLI commands (adapt, sync, login, etc.).

// ANSI color codes
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const orange = "\x1b[38;5;214m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const cyan = "\x1b[36m";
};

// Left padding (empty: no universal padding; indent only after colon-terminated lines)
pub const P = "";
