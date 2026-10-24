const std = @import("std");
const types = @import("terminal_types.zig");

// TODO: port esc.c: esc_dispatch handles ESC + final byte (IND, NEL, RI, DECSC, ...).
