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

export fn sixel_colors_set(term: *types.Terminal, count_in: c_uint) callconv(.c) void {
    const new_size: u32 = @min(@max(@as(u32, 2), count_in), SIXEL_MAX_COLORS);

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

// ── Chunk B1: color_decode_srgb + sixel_fini ─────────────────────
// color_decode_srgb is not yet called from Zig (its callers —
// sixel_init and decgci — are still in C); it is exported for the
// upcoming chunk that ports those callers.

extern const srgb_decode_8_to_16_table: [256]u16;
extern const srgb_decode_8_to_8_table: [256]u8;

extern fn sixel_wayl_do_linear_blending(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_shm_chain_bit_depth(term: *types.Terminal) callconv(.c) c_int;
extern fn sixel_wl_have_argb2101010(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_wl_have_abgr2101010(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_conf_sixel_palette_entries(term: *types.Terminal) callconv(.c) usize;
extern fn sixel_conf_sixel_palette_copy(term: *types.Terminal, dst: [*]u32, max: usize) callconv(.c) void;
extern fn sixel_pixman_fmt_a8r8g8b8() callconv(.c) c_uint;
extern fn sixel_pixman_fmt_a2r10g10b10() callconv(.c) c_uint;
extern fn sixel_pixman_fmt_a2b10g10r10() callconv(.c) c_uint;
extern fn sixel_pixman_type_argb() callconv(.c) c_int;

export fn sixel_fini(term: *types.Terminal) callconv(.c) void {
    if (term.sixel.image.data) |p| free(@ptrCast(p));
    if (term.sixel.private_palette) |p| free(@ptrCast(p));
    if (term.sixel.shared_palette) |p| free(@ptrCast(p));
}


// ── color_decode_srgb (was sixel.c line ~22) ─────────────────────
// Uses srgb_decode_8_to_8_table / srgb_decode_8_to_16_table (extern from
// build/srgb.h), and the pixman format code stored in term.sixel.pixman_fmt.


export fn color_decode_srgb(term: *types.Terminal, r_in: u16, g_in: u16, b_in: u16) callconv(.c) u32 {
    var r: u32 = r_in;
    var g: u32 = g_in;
    var b: u32 = b_in;

    if (term.sixel.linear_blending) {
        if (term.sixel.use_10bit) {
            r = @as(u32, srgb_decode_8_to_16_table[r]) >> 6;
            g = @as(u32, srgb_decode_8_to_16_table[g]) >> 6;
            b = @as(u32, srgb_decode_8_to_16_table[b]) >> 6;
        } else {
            r = srgb_decode_8_to_8_table[r];
            g = srgb_decode_8_to_8_table[g];
            b = srgb_decode_8_to_8_table[b];
        }
    } else {
        if (term.sixel.use_10bit) {
            r <<= 2;
            g <<= 2;
            b <<= 2;
        }
    }

    var color: u32 = undefined;
    if (term.sixel.use_10bit) {
        const fmt: u32 = @intCast(term.sixel.pixman_fmt);
        const type_bits = (fmt >> 16) & 0x3f;
        const pixman_type_argb: u32 = @intCast(sixel_pixman_type_argb());
        if (type_bits == pixman_type_argb) {
            color = (@as(u32, 0x3) << 30) | (r << 20) | (g << 10) | b;
        } else {
            color = (@as(u32, 0x3) << 30) | (b << 20) | (g << 10) | r;
        }
    } else {
        color = (@as(u32, 0xff) << 24) | (r << 16) | (g << 8) | b;
    }
    return color;
}

// ── Chunk B2: sixel put-handler chain ────────────────────────────
// Ports sixel.c lines 1429-2143. Split into sub-chunks to stay under
// the client's per-message truncation limit.
//
// Static state from sixel.c:
//   static size_t count;   -- incremented by sixel_put_*, reset in sixel_init
var count: usize = 0;

extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xcalloc(n: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn wmemset(wstr: [*]u32, wc: u32, n: usize) callconv(.c) [*]u32;
extern fn hsl_to_rgb(hue: c_int, sat: c_int, lum: c_int) callconv(.c) u32;

// SixelState enum values (match SixelState in terminal_types.zig)
const SIXEL_DECSIXEL: c_int = 0;
const SIXEL_DECGRA: c_int = 1;
const SIXEL_DECGRI: c_int = 2;
const SIXEL_DECGCI: c_int = 3;

fn memset_u32(data: [*]u32, value: u32, n: usize) void {
    // C: wmemset((wchar_t *)data, (wchar_t)value, count);
    _ = wmemset(data, value, n);
}

fn sixel_add_generic(term: *types.Terminal, data_in: [*]u32, stride: c_int, color: u32, sixel_in: u8) void {
    const pan: c_int = term.sixel.pan;
    var data = data_in;
    var sixel = sixel_in;

    var i: c_int = 0;
    while (i < 6) : (i += 1) {
        if (sixel & 1 != 0) {
            var r: c_int = 0;
            while (r < pan) : (r += 1) {
                data[0] = color;
                data += @intCast(stride);
            }
        } else {
            data += @intCast(stride * pan);
        }
        sixel >>= 1;
    }
    // C: xassert(sixel == 0); -- no-op in release
}

fn sixel_add_ar_11(term: *types.Terminal, data_in: [*]u32, stride: c_int, color: u32, sixel: u8) void {
    _ = term; // C: xassert(term->sixel.pan == 1);
    var data = data_in;

    if (sixel & 0x01 != 0) data[0] = color;
    data += @intCast(stride);
    if (sixel & 0x02 != 0) data[0] = color;
    data += @intCast(stride);
    if (sixel & 0x04 != 0) data[0] = color;
    data += @intCast(stride);
    if (sixel & 0x08 != 0) data[0] = color;
    data += @intCast(stride);
    if (sixel & 0x10 != 0) data[0] = color;
    data += @intCast(stride);
    if (sixel & 0x20 != 0) data[0] = color;
}

fn sixel_add_many_generic(term: *types.Terminal, c: u8, count_in: c_uint) void {
    var count_v: c_uint = count_in;
    const col: c_int = term.sixel.pos.col;
    var width: c_int = term.sixel.image.width;

    count_v *= @intCast(term.sixel.pad);

    if (col + @as(c_int, @intCast(count_v)) - 1 >= width) {
        resize_horizontally(term, col + @as(c_int, @intCast(count_v)));
        width = term.sixel.image.width;
        const rem = @max(width - col, 0);
        count_v = @min(count_v, @as(c_uint, @intCast(rem)));
        if (count_v == 0) return;
    }

    const color = term.sixel.color;
    const data = term.sixel.image.p.?;
    const end = data + count_v;

    term.sixel.pos.col = col + @as(c_int, @intCast(count_v));
    term.sixel.image.p = end;
    term.sixel.image.bottom_pixel |= c;

    var i: usize = 0;
    while (i < count_v) : (i += 1) {
        sixel_add_generic(term, data + i, width, color, c);
    }
}

fn sixel_add_one_ar_11(term: *types.Terminal, c: u8) void {
    // C: xassert(term->sixel.pan == 1); xassert(term->sixel.pad == 1);
    // NOTE: faithfully reproduces a C quirk — `count` here refers to the
    // file-static global, not a local. Since count is 0 at the point this
    // runs (only sixel_put_* increments it, after this function returns),
    // the resize branch always returns early. Preserved as-is.

    const col: c_int = term.sixel.pos.col;
    var width: c_int = term.sixel.image.width;

    if (col >= width) {
        resize_horizontally(term, col + @as(c_int, @intCast(count)));
        width = term.sixel.image.width;
        const rem = @max(width - col, 0);
        const new_count = @min(count, @as(usize, @intCast(rem)));
        if (new_count == 0) return;
        // C assigns to the global `count` here, but never reads it below.
        count = new_count;
    }

    const data = term.sixel.image.p.?;

    term.sixel.pos.col += 1;
    term.sixel.image.p = data + 1;
    term.sixel.image.bottom_pixel |= c;

    sixel_add_ar_11(term, data, width, term.sixel.color, c);
}

fn sixel_add_many_ar_11(term: *types.Terminal, c: u8, count_in: c_uint) void {
    // C: xassert(term->sixel.pan == 1); xassert(term->sixel.pad == 1);

    var count_v: c_uint = count_in;
    const col: c_int = term.sixel.pos.col;
    var width: c_int = term.sixel.image.width;

    if (col + @as(c_int, @intCast(count_v)) - 1 >= width) {
        resize_horizontally(term, col + @as(c_int, @intCast(count_v)));
        width = term.sixel.image.width;
        const rem = @max(width - col, 0);
        count_v = @min(count_v, @as(c_uint, @intCast(rem)));
        if (count_v == 0) return;
    }

    const color = term.sixel.color;
    const data = term.sixel.image.p.?;
    const end = data + count_v;

    term.sixel.pos.col += @as(c_int, @intCast(count_v));
    term.sixel.image.p = end;
    term.sixel.image.bottom_pixel |= c;

    var i: usize = 0;
    while (i < count_v) : (i += 1) {
        sixel_add_ar_11(term, data + i, width, color, c);
    }
}


// ── Chunk B2 (sub-chunk b): resize_* functions ──────────────────

fn resize_horizontally(term: *types.Terminal, new_width_mutable: c_int) void {
    var new_width: c_int = new_width_mutable;

    if (new_width > @as(c_int, @intCast(term.sixel.max_width))) {
        new_width = @intCast(term.sixel.max_width);
    }

    if (term.sixel.image.width >= new_width) return;

    const sixel_row_height: c_int = 6 * term.sixel.pan;

    const old_data: ?[*]u32 = term.sixel.image.data;
    const old_width: c_int = term.sixel.image.width;
    const new_width_actual: c_int = new_width;

    var height: c_int = undefined;
    if (term.sixel.image.height == 0) {
        height = sixel_row_height;
        term.sixel.image.height = height;
        term.sixel.image.alloc_height = sixel_row_height;
    } else {
        height = term.sixel.image.height;
    }

    const alloc_height: c_int = @divTrunc(height + sixel_row_height - 1, sixel_row_height) * sixel_row_height;

    const new_data_ptr: [*]u32 = @ptrCast(@alignCast(xmalloc(
        @as(usize, @intCast(new_width_actual)) *
        @as(usize, @intCast(alloc_height)) *
        @sizeOf(u32),
    )));

    const bg: u32 = if (term.sixel.transparent_bg) 0 else term.sixel.palette.?[0];

    // Copy old rows, initialize new columns to background
    const new_width_u: usize = @intCast(new_width_actual);
    const old_width_u: usize = @intCast(old_width);
    const alloc_height_u: usize = @intCast(alloc_height);

    var row: usize = 0;
    while (row < alloc_height_u) : (row += 1) {
        const n = new_data_ptr + row * new_width_u;
        if (old_data) |od| {
            if (old_width_u > 0) {
                const o = od + row * old_width_u;
                @memcpy(n[0..old_width_u], o[0..old_width_u]);
            }
        }
        if (new_width_u > old_width_u) {
            memset_u32(n + old_width_u, bg, new_width_u - old_width_u);
        }
    }

    if (old_data) |od| free(@ptrCast(od));

    term.sixel.image.data = new_data_ptr;
    term.sixel.image.width = new_width_actual;

    const ofs: usize = @intCast(term.sixel.pos.row * new_width_actual + term.sixel.pos.col);
    term.sixel.image.p = new_data_ptr + ofs;
}

fn resize_vertically(term: *types.Terminal, new_height: c_int) bool {
    if (new_height > @as(c_int, @intCast(term.sixel.max_height))) {
        return false;
    }

    const old_data: ?[*]u32 = term.sixel.image.data;
    const width: c_int = term.sixel.image.width;
    const old_height: c_int = term.sixel.image.height;
    const sixel_row_height: c_int = 6 * term.sixel.pan;

    const alloc_height: c_int = @divTrunc(new_height + sixel_row_height - 1, sixel_row_height) * sixel_row_height;

    if (width == 0) {
        term.sixel.image.height = new_height;
        term.sixel.image.alloc_height = alloc_height;
        return true;
    }

    const new_size: usize = @as(usize, @intCast(width)) *
                            @as(usize, @intCast(alloc_height)) *
                            @sizeOf(u32);
    const r = realloc(if (old_data) |p| @ptrCast(p) else null, new_size);
    if (r == null) return false;
    const new_data: [*]u32 = @ptrCast(@alignCast(r.?));

    const bg: u32 = if (term.sixel.transparent_bg) 0 else term.sixel.palette.?[0];

    const old_height_u: usize = @intCast(old_height);
    const width_u: usize = @intCast(width);
    const alloc_height_u: usize = @intCast(alloc_height);
    if (alloc_height_u > old_height_u) {
        memset_u32(
            new_data + old_height_u * width_u,
            bg,
            (alloc_height_u - old_height_u) * width_u,
        );
    }

    term.sixel.image.height = new_height;
    term.sixel.image.alloc_height = alloc_height;

    const ofs: usize = @intCast(term.sixel.pos.row * width + term.sixel.pos.col);
    term.sixel.image.data = new_data;
    term.sixel.image.p = new_data + ofs;

    return true;
}

fn resize(term: *types.Terminal, new_width_mutable: c_int, new_height_mutable: c_int) bool {
    var new_width: c_int = new_width_mutable;
    var new_height: c_int = new_height_mutable;

    if (new_width > @as(c_int, @intCast(term.sixel.max_width))) {
        new_width = @intCast(term.sixel.max_width);
    }
    if (new_height > @as(c_int, @intCast(term.sixel.max_height))) {
        new_height = @intCast(term.sixel.max_height);
    }
    if (new_height == 0) {
        new_height = 6 * term.sixel.pan;
    }

    const old_data: ?[*]u32 = term.sixel.image.data;
    const old_width: c_int = term.sixel.image.width;
    const old_height: c_int = term.sixel.image.height;

    if (old_width == new_width and old_height == new_height) return true;

    const sixel_row_height: c_int = 6 * term.sixel.pan;
    const alloc_new_height: c_int = @divTrunc(new_height + sixel_row_height - 1, sixel_row_height) * sixel_row_height;

    const bg: u32 = if (term.sixel.transparent_bg) 0 else term.sixel.palette.?[0];

    const initialize_bg: bool = !term.sixel.transparent_bg or new_width == old_width;

    var new_data: [*]u32 = undefined;

    const new_width_u: usize = @intCast(new_width);
    const old_width_u: usize = @intCast(old_width);
    const old_height_u: usize = @intCast(old_height);
    const alloc_new_height_u: usize = @intCast(alloc_new_height);

    if (new_width == old_width) {
        const new_size: usize = new_width_u * alloc_new_height_u * @sizeOf(u32);
        const r = realloc(if (old_data) |p| @ptrCast(p) else null, new_size);
        if (r == null) return false;
        new_data = @ptrCast(@alignCast(r.?));
    } else {
        const pixels: usize = new_width_u * alloc_new_height_u;
        if (initialize_bg) {
            new_data = @ptrCast(@alignCast(xmalloc(pixels * @sizeOf(u32))));
        } else {
            new_data = @ptrCast(@alignCast(xcalloc(pixels, @sizeOf(u32))));
        }

        const row_copy_count: usize = @min(old_height_u, alloc_new_height_u);
        var row: usize = 0;
        while (row < row_copy_count) : (row += 1) {
            const n = new_data + row * new_width_u;
            const o = old_data.? + row * old_width_u;
            @memcpy(n[0..old_width_u], o[0..old_width_u]);
            if (new_width_u > old_width_u) {
                memset_u32(n + old_width_u, bg, new_width_u - old_width_u);
            }
        }
        if (old_data) |p| free(@ptrCast(p));
    }

    if (initialize_bg and alloc_new_height_u > old_height_u) {
        memset_u32(
            new_data + old_height_u * new_width_u,
            bg,
            (alloc_new_height_u - old_height_u) * new_width_u,
        );
    }

    term.sixel.image.data = new_data;
    term.sixel.image.width = new_width;
    term.sixel.image.height = new_height;
    term.sixel.image.alloc_height = alloc_new_height;

    const ofs: usize = @intCast(term.sixel.pos.row * new_width + term.sixel.pos.col);
    term.sixel.image.p = new_data + ofs;

    return true;
}

// ── Chunk B2 (sub-chunk c): decsixel + decgra ────────────────────

fn decsixel_generic(term: *types.Terminal, c: u8) void {
    switch (c) {
        '"' => {
            term.sixel.state = @enumFromInt(SIXEL_DECGRA);
            term.sixel.param = 0;
            term.sixel.param_idx = 0;
        },
        '!' => {
            term.sixel.state = @enumFromInt(SIXEL_DECGRI);
            term.sixel.param = 0;
            term.sixel.param_idx = 0;
            term.sixel.repeat_count = 1;
        },
        '#' => {
            term.sixel.state = @enumFromInt(SIXEL_DECGCI);
            term.sixel.color_idx = 0;
            term.sixel.param = 0;
            term.sixel.param_idx = 0;
        },
        '$' => {
            if (term.sixel.pos.col <= @as(c_int, @intCast(term.sixel.max_width))) {
                term.sixel.pos.col = 0;
                const ofs: usize = @intCast(term.sixel.pos.row * term.sixel.image.width);
                term.sixel.image.p = term.sixel.image.data.? + ofs;
            }
        },
        '-' => {
            term.sixel.pos.row += 6 * term.sixel.pan;
            term.sixel.pos.col = 0;
            term.sixel.image.bottom_pixel = 0;
            const ofs: usize = @intCast(term.sixel.pos.row * term.sixel.image.width);
            term.sixel.image.p = term.sixel.image.data.? + ofs;

            if (term.sixel.pos.row >= term.sixel.image.alloc_height) {
                if (!resize_vertically(term, term.sixel.pos.row + 6 * term.sixel.pan)) {
                    term.sixel.pos.col =
                        @as(c_int, @intCast(term.sixel.max_width)) + 1 * term.sixel.pad;
                }
            }
        },
        '?', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
        'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
        '[', '\\', ']', '^', '_', '`',
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
        'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
        '{', '|', '}', '~' => {
            sixel_add_many_generic(term, c - 63, 1);
        },
        ' ', '\n', '\r' => {},
        else => {},
    }
}

fn decsixel_ar_11(term: *types.Terminal, c: u8) void {
    if (c >= '?' and c <= '~') {
        sixel_add_one_ar_11(term, c - 63);
    } else {
        decsixel_generic(term, c);
    }
}

fn decgra(term: *types.Terminal, c: u8) void {
    switch (c) {
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
            term.sixel.param *= 10;
            term.sixel.param += @as(c_uint, @intCast(c - '0'));
        },
        ';' => {
            if (term.sixel.param_idx < 5) {
                term.sixel.params[term.sixel.param_idx] = term.sixel.param;
                term.sixel.param_idx += 1;
            }
            term.sixel.param = 0;
        },
        else => blk: {
            if (term.sixel.param_idx < 5) {
                term.sixel.params[term.sixel.param_idx] = term.sixel.param;
                term.sixel.param_idx += 1;
            }

            const nparams: c_uint = term.sixel.param_idx;
            var pan: c_uint = if (nparams > 0) term.sixel.params[0] else 0;
            var pad: c_uint = if (nparams > 1) term.sixel.params[1] else 0;
            var ph: c_uint = if (nparams > 2) term.sixel.params[2] else 0;
            var pv: c_uint = if (nparams > 3) term.sixel.params[3] else 0;

            pan = if (pan > 0) @min(pan, 5) else 1;
            pad = if (pad > 0) @min(pad, 5) else 1;

            if (term.sixel.image.width == 0 and term.sixel.image.height == 0) {
                term.sixel.pan = @intCast(pan);
                term.sixel.pad = @intCast(pad);
            } else {
                pan = @intCast(term.sixel.pan);
                pad = @intCast(term.sixel.pad);
            }

            pv *= pan;
            ph *= pad;

            if (ph >= @as(c_uint, @intCast(term.sixel.image.height)) and
                pv >= @as(c_uint, @intCast(term.sixel.image.width)) and
                ph <= term.sixel.max_height and
                pv <= term.sixel.max_width)
            {
                _ = resize(term, @intCast(pv), @intCast(ph));
            }

            term.sixel.state = @enumFromInt(SIXEL_DECSIXEL);

            const h = term.vt.dcs.put_handler orelse unreachable;
            if (pan == 1 and pad == 1) {
                h(@ptrCast(term), c);
            } else {
                h(@ptrCast(term), c);
            }
            break :blk;
        },
    }
}

// ── Chunk B2 (sub-chunk d): decgri + decgci + sixel_put_* ────────

fn decgri_generic(term: *types.Terminal, c: u8) void {
    if (c >= '0' and c <= '9') {
        var param: c_uint = term.sixel.param;
        param *= 10;
        param += @as(c_uint, @intCast(c - '0'));
        term.sixel.repeat_count = param;
        term.sixel.param = param;
        return;
    }
    if (c >= '?' and c <= '~') {
        var count_v: c_uint = term.sixel.repeat_count;
        if (count_v == 0) count_v = 1;
        sixel_add_many_generic(term, c - 63, count_v);
        term.sixel.state = @enumFromInt(SIXEL_DECSIXEL);
        return;
    }

    term.sixel.state = @enumFromInt(SIXEL_DECSIXEL);
    if (term.vt.dcs.put_handler) |h| {
        h(@ptrCast(term), c);
    }
}

fn decgri_ar_11(term: *types.Terminal, c: u8) void {
    if (c >= '?' and c <= '~') {
        var count_v: c_uint = term.sixel.repeat_count;
        if (count_v == 0) count_v = 1;
        sixel_add_many_ar_11(term, c - 63, count_v);
        term.sixel.state = @enumFromInt(SIXEL_DECSIXEL);
    } else {
        decgri_generic(term, c);
    }
}


fn decgci(term: *types.Terminal, c: u8) void {
    if (c >= '0' and c <= '9') {
        term.sixel.param *= 10;
        term.sixel.param += @as(c_uint, @intCast(c - '0'));
        return;
    }
    if (c == ';') {
        if (term.sixel.param_idx < 5) {
            term.sixel.params[term.sixel.param_idx] = term.sixel.param;
            term.sixel.param_idx += 1;
        }
        term.sixel.param = 0;
        return;
    }

    if (term.sixel.param_idx < 5) {
        term.sixel.params[term.sixel.param_idx] = term.sixel.param;
        term.sixel.param_idx += 1;
    }

    const nparams: c_uint = term.sixel.param_idx;

    if (nparams > 0) {
        const ps: c_uint = term.sixel.palette_size;
        term.sixel.color_idx = @intCast(@min(term.sixel.params[0], ps - 1));
    }

    if (nparams > 4) {
        const format: c_uint = term.sixel.params[1];
        const c1: c_uint = term.sixel.params[2];
        const c2: c_uint = term.sixel.params[3];
        const c3: c_uint = term.sixel.params[4];
        const idx: usize = @intCast(term.sixel.color_idx);

        switch (format) {
            1 => {
                var hue: c_int = @intCast(@min(c1, 360));
                const lum: c_int = @intCast(@min(c2, 100));
                const sat: c_int = @intCast(@min(c3, 100));
                hue = @mod(hue + 240, 360);
                const rgb = hsl_to_rgb(hue, sat, lum);
                term.sixel.palette.?[idx] = (@as(u32, 0xff) << 24) | rgb;
            },
            2 => {
                const r: u16 = @intCast(@divTrunc(255 * @as(c_int, @min(c1, 100)), 100));
                const g: u16 = @intCast(@divTrunc(255 * @as(c_int, @min(c2, 100)), 100));
                const b: u16 = @intCast(@divTrunc(255 * @as(c_int, @min(c3, 100)), 100));
                term.sixel.palette.?[idx] = color_decode_srgb(term, r, g, b);
            },
            else => {},
        }
    } else {
        const idx: usize = @intCast(term.sixel.color_idx);
        term.sixel.color = term.sixel.palette.?[idx];
    }

    term.sixel.state = @enumFromInt(SIXEL_DECSIXEL);

    if (term.sixel.pan == 1 and term.sixel.pad == 1) {
        decsixel_ar_11(term, c);
    } else {
        decsixel_generic(term, c);
    }
}

export fn sixel_put_generic(term_opaque: ?*anyopaque, c: u8) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(term_opaque orelse unreachable));
    switch (term.sixel.state) {
        .DECSIXEL => decsixel_generic(term, c),
        .DECGRA => decgra(term, c),
        .DECGRI => decgri_generic(term, c),
        .DECGCI => decgci(term, c),
    }
    count += 1;
}

export fn sixel_put_ar_11(term_opaque: ?*anyopaque, c: u8) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(term_opaque orelse unreachable));
    switch (term.sixel.state) {
        .DECSIXEL => decsixel_ar_11(term, c),
        .DECGRA => decgra(term, c),
        .DECGRI => decgri_ar_11(term, c),
        .DECGCI => decgci(term, c),
    }
    count += 1;
}
