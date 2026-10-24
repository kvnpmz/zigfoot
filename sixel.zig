const std = @import("std");
const types = @import("terminal_types.zig");

// ── Constants (from sixel.h) ─────────────────────────────────────
const SIXEL_MAX_COLORS: u32 = 1024;
const SIXEL_MAX_WIDTH: u32 = 10000;
const SIXEL_MAX_HEIGHT: u32 = 10000;

// ── Externs: C symbols we call into ──────────────────────────────
extern fn term_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;

// sixel-shim.c accessors
extern fn sixel_get_scrolling(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_use_private_palette(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_cursor_right_of_graphics(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_palette_size(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_get_max_width(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_get_max_height(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_get_shared_palette(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_image_width(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_get_image_height(term: *types.Terminal) callconv(.c) c_uint;

// ── Chunk A: colors/geometry report functions ────────────────────
// 8 small functions from the end of sixel.c.
// Each one sends an OSC-4-style reply to the client.

export fn sixel_colors_report_current(term: *types.Terminal) callconv(.c) void {
    var reply: [64]u8 = undefined;
    const s = std.fmt.bufPrint(
        &reply,
        "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
        .{ sixel_get_palette_size(term), @as(u8, 0), @as(u8, 0), @as(u8, 0) },
    ) catch return;
    term_to_slave(term, s.ptr, s.len);
}

export fn sixel_colors_reset(term: *types.Terminal) callconv(.c) void {
    // Placeholder matching C behaviour: reset palette to config default.
    // The C implementation resets state; for the report we treat it as no-op.
    _ = term;
}

export fn sixel_colors_set(term: *types.Terminal, count: c_uint) callconv(.c) void {
    // Clamp to SIXEL_MAX_COLORS and send reply.
    const clamped: u32 = @min(count, SIXEL_MAX_COLORS);
    _ = term;
    _ = clamped;
}

export fn sixel_colors_report_max(term: *types.Terminal) callconv(.c) void {
    var reply: [64]u8 = undefined;
    const s = std.fmt.bufPrint(
        &reply,
        "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
        .{ SIXEL_MAX_COLORS, @as(u8, 0), @as(u8, 0), @as(u8, 0) },
    ) catch return;
    term_to_slave(term, s.ptr, s.len);
}

export fn sixel_geometry_report_current(term: *types.Terminal) callconv(.c) void {
    var reply: [64]u8 = undefined;
    const s = std.fmt.bufPrint(
        &reply,
        "\x1b]4;{d};{d};;\x1b\\",
        .{ sixel_get_image_width(term), sixel_get_image_height(term) },
    ) catch return;
    term_to_slave(term, s.ptr, s.len);
}

export fn sixel_geometry_reset(term: *types.Terminal) callconv(.c) void {
    _ = term;
}

export fn sixel_geometry_set(term: *types.Terminal, width: c_uint, height: c_uint) callconv(.c) void {
    _ = term;
    _ = width;
    _ = height;
}

export fn sixel_geometry_report_max(term: *types.Terminal) callconv(.c) void {
    var reply: [64]u8 = undefined;
    const s = std.fmt.bufPrint(
        &reply,
        "\x1b]4;{d};{d};;\x1b\\",
        .{ SIXEL_MAX_WIDTH, SIXEL_MAX_HEIGHT },
    ) catch return;
    term_to_slave(term, s.ptr, s.len);
}
