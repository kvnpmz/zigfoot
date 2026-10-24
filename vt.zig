const std = @import("std");
const types = @import("terminal_types.zig");

// TODO: port vt.c: vt_from_terminal, vt_feed, UTF-8 iteration, C0/C1 handling.
// This is the second-largest file after terminal.c — do NOT stub it away.
