const std = @import("std");
const types = @import("terminal_types.zig");

// ── Constants (from sixel.h) ─────────────────────────────────────
const SIXEL_MAX_COLORS: u32 = 1024;
const SIXEL_MAX_WIDTH: u32 = 10000;
const SIXEL_MAX_HEIGHT: u32 = 10000;

// ── Externs ──────────────────────────────────────────────────────
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

extern fn term_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;
extern fn xsnprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) callconv(.c) usize;

// sixel-shim.c accessors
extern fn sixel_get_scrolling(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_use_private_palette(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_cursor_right_of_graphics(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_palette_size(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_set_palette_size(term: *types.Terminal, v: c_uint) callconv(.c) void;
extern fn sixel_get_max_width(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_set_max_width(term: *types.Terminal, v: c_uint) callconv(.c) void;
extern fn sixel_get_max_height(term: *types.Terminal) callconv(.c) c_uint;
extern fn sixel_set_max_height(term: *types.Terminal, v: c_uint) callconv(.c) void;
extern fn sixel_get_palette(term: *types.Terminal) callconv(.c) ?[*]u32;
extern fn sixel_set_palette(term: *types.Terminal, p: ?[*]u32) callconv(.c) void;
extern fn sixel_get_private_palette(term: *types.Terminal) callconv(.c) ?[*]u32;
extern fn sixel_set_private_palette(term: *types.Terminal, p: ?[*]u32) callconv(.c) void;
extern fn sixel_get_shared_palette(term: *types.Terminal) callconv(.c) ?[*]u32;
extern fn sixel_set_shared_palette(term: *types.Terminal, p: ?[*]u32) callconv(.c) void;

// ── Chunk A: colors/geometry report functions ────────────────────

export fn sixel_colors_report_current(term: *types.Terminal) callconv(.c) void {
    var reply: [24]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?1;0;%uS", sixel_get_palette_size(term));
    term_to_slave(term, &reply, n);
}

export fn sixel_colors_reset(term: *types.Terminal) callconv(.c) void {
    const old = sixel_get_palette(term);
    free(if (old) |p| @ptrCast(p) else null);
    sixel_set_palette(term, null);

    sixel_set_palette_size(term, SIXEL_MAX_COLORS);
    sixel_colors_report_current(term);
}

export fn sixel_colors_set(term: *types.Terminal, count: c_uint) callconv(.c) void {
    const new_size: u32 = @min(@max(@as(u32, 2), count), SIXEL_MAX_COLORS);

    const priv = sixel_get_private_palette(term);
    free(if (priv) |p| @ptrCast(p) else null);
    const shared = sixel_get_shared_palette(term);
    free(if (shared) |p| @ptrCast(p) else null);
    sixel_set_private_palette(term, null);
    sixel_set_shared_palette(term, null);

    sixel_set_palette_size(term, new_size);
    sixel_colors_report_current(term);
}

export fn sixel_colors_report_max(term: *types.Terminal) callconv(.c) void {
    var reply: [24]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?1;0;%uS", SIXEL_MAX_COLORS);
    term_to_slave(term, &reply, n);
}

export fn sixel_geometry_report_current(term: *types.Terminal) callconv(.c) void {
    const w: u32 = @min(
        @as(u32, @intCast(term.cols * term.cell_width)),
        sixel_get_max_width(term),
    );
    const h: u32 = @min(
        @as(u32, @intCast(term.rows * term.cell_height)),
        sixel_get_max_height(term),
    );

    var reply: [64]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?2;0;%u;%uS", w, h);
    term_to_slave(term, &reply, n);
}

export fn sixel_geometry_reset(term: *types.Terminal) callconv(.c) void {
    sixel_set_max_width(term, SIXEL_MAX_WIDTH);
    sixel_set_max_height(term, SIXEL_MAX_HEIGHT);
    sixel_geometry_report_current(term);
}

export fn sixel_geometry_set(term: *types.Terminal, width: c_uint, height: c_uint) callconv(.c) void {
    sixel_set_max_width(term, width);
    sixel_set_max_height(term, height);
    sixel_geometry_report_current(term);
}

export fn sixel_geometry_report_max(term: *types.Terminal) callconv(.c) void {
    const w = sixel_get_max_width(term);
    const h = sixel_get_max_height(term);

    var reply: [64]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?2;0;%u;%uS", w, h);
    term_to_slave(term, &reply, n);
}
