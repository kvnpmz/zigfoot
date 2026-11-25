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

// ── Chunk A: colors/geometry report functions ────────────────────

export fn sixel_colors_report_current(term: *types.Terminal) callconv(.c) void {
    var reply: [24]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?1;0;%uS", term.sixel.palette_size);
    term_to_slave(term, &reply, n);
}

export fn sixel_colors_reset(term: *types.Terminal) callconv(.c) void {
    const old = term.sixel.palette;
    free(if (old) |p| @ptrCast(p) else null);
    term.sixel.palette = null;

    term.sixel.palette_size = SIXEL_MAX_COLORS;
    sixel_colors_report_current(term);
}

export fn sixel_colors_set(term: *types.Terminal, count_in: c_uint) callconv(.c) void {
    const new_size: u32 = @min(@max(@as(u32, 2), count_in), SIXEL_MAX_COLORS);

    const priv = term.sixel.private_palette;
    free(if (priv) |p| @ptrCast(p) else null);
    const shared = term.sixel.shared_palette;
    free(if (shared) |p| @ptrCast(p) else null);
    term.sixel.private_palette = null;
    term.sixel.shared_palette = null;

    term.sixel.palette_size = new_size;
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
        term.sixel.max_width,
    );
    const h: u32 = @min(
        @as(u32, @intCast(term.rows * term.cell_height)),
        term.sixel.max_height,
    );

    var reply: [64]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?2;0;%u;%uS", w, h);
    term_to_slave(term, &reply, n);
}

export fn sixel_geometry_reset(term: *types.Terminal) callconv(.c) void {
    term.sixel.max_width = SIXEL_MAX_WIDTH;
    term.sixel.max_height = SIXEL_MAX_HEIGHT;
    sixel_geometry_report_current(term);
}

export fn sixel_geometry_set(term: *types.Terminal, width: c_uint, height: c_uint) callconv(.c) void {
    term.sixel.max_width = width;
    term.sixel.max_height = height;
    sixel_geometry_report_current(term);
}

export fn sixel_geometry_report_max(term: *types.Terminal) callconv(.c) void {
    const w = term.sixel.max_width;
    const h = term.sixel.max_height;

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

// ── sixel-shim.c: wayland/shm/config helpers ──────────────────────
// The bodies used to live in sixel-shim.c. Calls that had no C callers
// now go straight through these exports; C still reaches the same ABI.
extern fn wayl_do_linear_blending(wayl: ?*const types.Wayland, conf: ?*const types.Config) callconv(.c) bool;
extern fn shm_chain_bit_depth(chain: *const types.ShmBufferChain) callconv(.c) c_int;

export fn sixel_wayl_do_linear_blending(term: *types.Terminal) callconv(.c) bool {
    return wayl_do_linear_blending(term.wl, term.conf);
}

export fn sixel_shm_chain_bit_depth(term: *types.Terminal) callconv(.c) c_int {
    // C assumed the grid chain exists; do not unwrap a NULL mirror field.
    const chain: *const types.ShmBufferChain =
        @ptrCast(@alignCast(term.render.chains.grid orelse return 0));
    return shm_chain_bit_depth(chain);
}

export fn sixel_conf_sixel_palette_copy(
    term: *types.Terminal,
    dst: [*]u32,
    max: usize,
) callconv(.c) void {
    const conf = term.conf orelse return;
    const src = &conf.colors_dark.sixel;
    const cnt = @min(src.len, max);
    for (0..cnt) |i| dst[i] = src[i];
}
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
        '?', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '[', '\\', ']', '^', '_', '`', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '{', '|', '}', '~' => {
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

fn wlHaveArgb2101010(term: *types.Terminal) bool {
    const wl = term.wl orelse return false;
    return wl._shm_format_bits.argb2101010;
}

fn wlHaveAbgr2101010(term: *types.Terminal) bool {
    const wl = term.wl orelse return false;
    return wl._shm_format_bits.abgr2101010;
}

// csi.zig (XTSAVE) still reaches these through the C ABI; the bodies are
// Zig now, so the shim functions are gone.
export fn sixel_get_scrolling(term: *const types.Terminal) callconv(.c) bool {
    return sixelFlag(term, 0x01);
}

export fn sixel_set_scrolling(term: *types.Terminal, v: bool) callconv(.c) void {
    sixelSetFlag(term, 0x01, v);
}

export fn sixel_get_use_private_palette(term: *const types.Terminal) callconv(.c) bool {
    return sixelFlag(term, 0x02);
}

export fn sixel_set_use_private_palette(term: *types.Terminal, v: bool) callconv(.c) void {
    sixelSetFlag(term, 0x02, v);
}

export fn sixel_get_cursor_right_of_graphics(term: *const types.Terminal) callconv(.c) bool {
    return sixelFlag(term, 0x04);
}

export fn sixel_set_cursor_right_of_graphics(term: *types.Terminal, v: bool) callconv(.c) void {
    sixelSetFlag(term, 0x04, v);
}

/// C: bool scrolling:1, use_private_palette:1, cursor_right_of_graphics:1
fn sixelFlag(term: *const types.Terminal, mask: u8) bool {
    return term.sixel._sixel_flags & mask != 0;
}

fn sixelSetFlag(term: *types.Terminal, comptime mask: u8, v: bool) void {
    if (v)
        term.sixel._sixel_flags |= mask
    else
        term.sixel._sixel_flags &= ~mask;
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

// ── Chunk C: destroy / erase / insert / scroll / init ────────────
// Ports sixel.c lines 167-450, plus sixel_init.
// verify_* functions from C are #if defined(_DEBUG) — empty in
// release builds, so we omit them and their calls entirely.

extern fn pixman_image_unref(image: ?*anyopaque) callconv(.c) void;
extern fn grid_row_abs_to_sb(grid: *const types.Grid, screen_rows: c_int, abs_row: c_int) callconv(.c) c_int;
extern fn term_update_ascii_printer(term: *types.Terminal) callconv(.c) void;
extern fn sixel_conf_colors_dark_sixel_ptr(term: *types.Terminal) callconv(.c) [*]const u32;

// ── tll helpers for SixelList ────────────────────────────────────
fn sixelListLen(list: *const types.SixelList) usize {
    return list.length;
}

fn sixelListPushBack(list: *types.SixelList, item: types.Sixel) void {
    const node = @as(*types.SixelNode, @ptrCast(@alignCast(xmalloc(@sizeOf(types.SixelNode)))));
    node.* = .{
        .item = item,
        .prev = list.tail,
        .next = null,
    };
    if (list.tail) |t| {
        t.next = node;
    } else {
        list.head = node;
    }
    list.tail = node;
    list.length += 1;
}

fn sixelListInsertBefore(list: *types.SixelList, before: *types.SixelNode, item: types.Sixel) void {
    const node = @as(*types.SixelNode, @ptrCast(@alignCast(xmalloc(@sizeOf(types.SixelNode)))));
    node.* = .{
        .item = item,
        .prev = before.prev,
        .next = before,
    };
    if (before.prev) |p| {
        p.next = node;
    } else {
        list.head = node;
    }
    before.prev = node;
    list.length += 1;
}

fn sixelListRemove(list: *types.SixelList, node: *types.SixelNode) void {
    if (node.prev) |p| {
        p.next = node.next;
    } else {
        list.head = node.next;
    }
    if (node.next) |n| {
        n.prev = node.prev;
    } else {
        list.tail = node.prev;
    }
    list.length -= 1;
    free(@ptrCast(node));
}

fn sixelListFree(list: *types.SixelList) void {
    var it = list.head;
    while (it) |node| {
        const next = node.next;
        free(@ptrCast(node));
        it = next;
    }
    list.head = null;
    list.tail = null;
    list.length = 0;
}

// ── destroy / invalidate cache ───────────────────────────────────
export fn sixel_invalidate_cache(six: *types.Sixel) callconv(.c) void {
    if (six.scaled.pix) |p| pixman_image_unref(p);
    if (six.scaled.data) |d| free(d);
    six.scaled.pix = null;
    six.scaled.data = null;
    six.scaled.width = -1;
    six.scaled.height = -1;

    six.pix = null;
    six.width = -1;
    six.height = -1;
}

export fn sixel_destroy(six: *types.Sixel) callconv(.c) void {
    sixel_invalidate_cache(six);

    if (six.original.pix) |p| pixman_image_unref(p);
    if (six.original.data) |d| free(d);
    six.original.pix = null;
    six.original.data = null;
}

export fn sixel_destroy_all(term: *types.Terminal) callconv(.c) void {
    var it = term.normal.sixel_images.head;
    while (it) |node| : (it = node.next) {
        sixel_destroy(&node.item);
    }
    var it2 = term.alt.sixel_images.head;
    while (it2) |node| : (it2 = node.next) {
        sixel_destroy(&node.item);
    }
    sixelListFree(&term.normal.sixel_images);
    sixelListFree(&term.alt.sixel_images);
}

export fn sixel_erase(term: *types.Terminal, six: *types.Sixel) callconv(.c) void {
    const grid = term.grid.?;
    const mask: c_int = grid.num_rows - 1;

    var i: c_int = 0;
    while (i < six.rows) : (i += 1) {
        const r: c_int = (six.pos.row + i) & mask;
        const row = grid.rows.?[@intCast(r)] orelse continue;
        row.dirty = true;

        const col_end = @min(six.pos.col + six.cols, term.cols);
        var c: c_int = six.pos.col;
        while (c < col_end) : (c += 1) {
            row.cells.?[@intCast(c)].attrs.clean = false;
        }
    }
    sixel_destroy(six);
}

// ── insert / scroll ──────────────────────────────────────────────
export fn sixel_insert(term: *types.Terminal, six_in: types.Sixel) callconv(.c) void {
    var six = six_in;
    const grid = term.grid.?;
    const end_row = grid_row_abs_to_sb(grid, term.rows, six.pos.row + six.rows - 1);

    var it = grid.sixel_images.head;
    while (it) |node| : (it = node.next) {
        const rebased = grid_row_abs_to_sb(
            grid,
            term.rows,
            node.item.pos.row + node.item.rows - 1,
        );
        if (rebased < end_row) {
            sixelListInsertBefore(&grid.sixel_images, node, six);
            return;
        }
    }
    sixelListPushBack(&grid.sixel_images, six);
    _ = &six;
}

export fn sixel_scroll_up(term: *types.Terminal, rows: c_int) callconv(.c) void {
    const grid = term.grid.?;
    if (sixelListLen(&grid.sixel_images) == 0) return;

    var it = grid.sixel_images.tail;
    while (it) |node| {
        const prev = node.prev;
        const six = &node.item;
        const six_start = grid_row_abs_to_sb(grid, term.rows, six.pos.row);
        if (six_start < rows) {
            sixel_erase(term, six);
            sixelListRemove(&grid.sixel_images, node);
        }
        it = prev;
    }

    term.bits_affecting_ascii_printer._.sixels =
        sixelListLen(&grid.sixel_images) > 0;
    term_update_ascii_printer(term);
}

export fn sixel_scroll_down(term: *types.Terminal, rows: c_int) callconv(.c) void {
    const grid = term.grid.?;
    if (sixelListLen(&grid.sixel_images) == 0) return;

    // xassert(grid.num_rows >= rows);

    var it = grid.sixel_images.head;
    while (it) |node| {
        const next = node.next;
        const six = &node.item;
        const six_end = grid_row_abs_to_sb(
            grid,
            term.rows,
            six.pos.row + six.rows - 1,
        );
        if (six_end >= grid.num_rows - rows) {
            sixel_erase(term, six);
            sixelListRemove(&grid.sixel_images, node);
        } else {
            break;
        }
        it = next;
    }

    term.bits_affecting_ascii_printer._.sixels =
        sixelListLen(&grid.sixel_images) > 0;
    term_update_ascii_printer(term);
}

// ── sixel_init ───────────────────────────────────────────────────
// Returns a put-handler fn ptr chosen by pan/pad.
// ABI: `sixel_put` = void (*)(struct terminal *, uint8_t).
export fn sixel_init(term: *types.Terminal, p1: c_int, p2: c_int, p3: c_int) callconv(.c) ?*const fn (?*anyopaque, u8) callconv(.c) void {
    _ = p3;

    // C: xassert(term->sixel.image.data == NULL);
    // C: xassert(term->sixel.palette_size <= SIXEL_MAX_COLORS);

    const pad: c_int = 1;
    const pan: c_int = if (p1 == 2) 5 else if (p1 == 3 or p1 == 4) 3 else if (p1 == 7 or p1 == 8 or p1 == 9) 1 else 2;

    term.sixel.state = .DECSIXEL;
    term.sixel.pos = .{ .col = 0, .row = 0 };
    term.sixel.color_idx = 0;
    term.sixel.pan = pan;
    term.sixel.pad = pad;
    term.sixel.param = 0;
    term.sixel.param_idx = 0;
    @memset(&term.sixel.params, 0);
    term.sixel.transparent_bg = (p2 == 1);
    term.sixel.image.data = null;
    term.sixel.image.p = null;
    term.sixel.image.width = 0;
    term.sixel.image.height = 0;
    term.sixel.image.alloc_height = 0;
    term.sixel.image.bottom_pixel = 0;
    term.sixel.linear_blending = sixel_wayl_do_linear_blending(term);
    term.sixel.pixman_fmt = @intCast(sixel_pixman_fmt_a8r8g8b8());

    // SHM_BITS_10 = 1 in shm.h enum
    if (sixel_shm_chain_bit_depth(term) >= 1) {
        if (wlHaveArgb2101010(term)) {
            term.sixel.use_10bit = true;
            term.sixel.pixman_fmt = @intCast(sixel_pixman_fmt_a2r10g10b10());
        } else if (wlHaveAbgr2101010(term)) {
            term.sixel.use_10bit = true;
            term.sixel.pixman_fmt = @intCast(sixel_pixman_fmt_a2b10g10r10());
        }
    }

    const conf_entries = term.conf.?.colors_dark.sixel.len;
    const palette_size: usize = term.sixel.palette_size;
    const active_palette_entries: usize = @min(conf_entries, palette_size);

    if (types.sixelGetUsePrivatePalette(term)) {
        // C: xassert(term->sixel.private_palette == NULL);
        const new_pal: [*]u32 = @ptrCast(@alignCast(xcalloc(
            term.sixel.palette_size,
            @sizeOf(u32),
        )));
        term.sixel.private_palette = new_pal;
        sixel_conf_sixel_palette_copy(term, new_pal, active_palette_entries);

        if (term.sixel.linear_blending or term.sixel.use_10bit) {
            var i: usize = 0;
            while (i < active_palette_entries) : (i += 1) {
                const v = new_pal[i];
                const rr: u16 = @intCast((v >> 16) & 0xff);
                const gg: u16 = @intCast((v >> 8) & 0xff);
                const bb: u16 = @intCast(v & 0xff);
                new_pal[i] = color_decode_srgb(term, rr, gg, bb);
            }
        }
        term.sixel.palette = new_pal;
    } else {
        if (term.sixel.shared_palette == null) {
            const new_pal: [*]u32 = @ptrCast(@alignCast(xcalloc(
                term.sixel.palette_size,
                @sizeOf(u32),
            )));
            term.sixel.shared_palette = new_pal;
            sixel_conf_sixel_palette_copy(term, new_pal, active_palette_entries);

            if (term.sixel.linear_blending or term.sixel.use_10bit) {
                var i: usize = 0;
                while (i < active_palette_entries) : (i += 1) {
                    const v = new_pal[i];
                    const rr: u16 = @intCast((v >> 16) & 0xff);
                    const gg: u16 = @intCast((v >> 8) & 0xff);
                    const bb: u16 = @intCast(v & 0xff);
                    new_pal[i] = color_decode_srgb(term, rr, gg, bb);
                }
            }
        }
        term.sixel.palette = term.sixel.shared_palette;
    }

    count = 0;
    return if (pan == 1 and pad == 1) &sixel_put_ar_11 else &sixel_put_generic;
}

// ── Chunk D: overwrite family ────────────────────────────────────
// Pixman extern declarations. `pixman_image_t` is an opaque union;
// treat as anyopaque. `pixman_bool_t` = int, `pixman_op_t` = int,
// `pixman_fixed_t`/`int16_t` per header.

const PixmanImage = anyopaque;

const PixmanColor = extern struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,
};

const PixmanBox32 = extern struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
};

const PixmanRegion32 = extern struct {
    extents: PixmanBox32,
    data: ?*anyopaque,
};

extern fn pixman_image_get_width(image: ?*PixmanImage) callconv(.c) c_int;
extern fn pixman_image_get_height(image: ?*PixmanImage) callconv(.c) c_int;
extern fn pixman_image_get_data(image: ?*PixmanImage) callconv(.c) ?[*]u32;
extern fn pixman_image_composite32(
    op: c_int,
    src: ?*PixmanImage,
    mask: ?*PixmanImage,
    dest: ?*PixmanImage,
    src_x: i32,
    src_y: i32,
    mask_x: i32,
    mask_y: i32,
    dest_x: i32,
    dest_y: i32,
    width: c_int,
    height: c_int,
) callconv(.c) void;
extern fn pixman_image_create_solid_fill(color: *const PixmanColor) callconv(.c) ?*PixmanImage;
extern fn pixman_image_create_bits_no_clear(
    format: c_uint,
    width: c_int,
    height: c_int,
    bits: ?*anyopaque,
    rowstride_bytes: c_int,
) callconv(.c) ?*PixmanImage;

extern fn pixman_region32_init(region: *PixmanRegion32) callconv(.c) void;
extern fn pixman_region32_init_rect(
    region: *PixmanRegion32,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
) callconv(.c) void;
extern fn pixman_region32_init_rects(
    region: *PixmanRegion32,
    boxes: [*]const PixmanBox32,
    count: c_int,
) callconv(.c) c_int;
extern fn pixman_region32_fini(region: *PixmanRegion32) callconv(.c) void;
extern fn pixman_region32_intersect(
    new_reg: *PixmanRegion32,
    reg1: *const PixmanRegion32,
    reg2: *const PixmanRegion32,
) callconv(.c) c_int;
extern fn pixman_region32_subtract(
    reg_d: *PixmanRegion32,
    reg_m: *const PixmanRegion32,
    reg_s: *const PixmanRegion32,
) callconv(.c) c_int;
extern fn pixman_region32_not_empty(region: *const PixmanRegion32) callconv(.c) c_int;
extern fn pixman_region32_rectangles(
    region: *const PixmanRegion32,
    n_rects: *c_int,
) callconv(.c) [*]PixmanBox32;

const PIXMAN_OP_SRC: c_int = 0x01;
const PIXMAN_OP_OVER_REVERSE: c_int = 0x04;

// ── blend_new_image_over_old ─────────────────────────────────────
fn blend_new_image_over_old(
    term: *const types.Terminal,
    six: *const types.Sixel,
    six_rect: *PixmanRegion32,
    row: c_int,
    col: c_int,
    pix: *?*PixmanImage,
    opaque_out: *bool,
) void {
    const six_ofs_x: c_int = six.pos.col * six.cell_width;
    const six_ofs_y: c_int = six.pos.row * six.cell_height;
    const img_ofs_x: c_int = col * six.cell_width;
    const img_ofs_y: c_int = row * six.cell_height;
    const img_width: c_int = pixman_image_get_width(pix.*);
    const img_height: c_int = pixman_image_get_height(pix.*);

    var pix_rect: PixmanRegion32 = undefined;
    pixman_region32_init_rect(
        &pix_rect,
        img_ofs_x,
        img_ofs_y,
        @intCast(img_width),
        @intCast(img_height),
    );

    var intersection: PixmanRegion32 = undefined;
    pixman_region32_init(&intersection);
    _ = pixman_region32_intersect(&intersection, six_rect, &pix_rect);

    var n_rects: c_int = -1;
    const boxes = pixman_region32_rectangles(&intersection, &n_rects);

    if (n_rects == 0) {
        pixman_region32_fini(&intersection);
        pixman_region32_fini(&pix_rect);
        return;
    }

    const box = &boxes[0];

    if (!opaque_out.*) {
        pixman_image_composite32(
            PIXMAN_OP_OVER_REVERSE,
            @ptrCast(six.original.pix),
            null,
            pix.*,
            box.x1 - six_ofs_x,
            box.y1 - six_ofs_y,
            0,
            0,
            box.x1 - img_ofs_x,
            box.y1 - img_ofs_y,
            box.x2 - box.x1,
            box.y2 - box.y1,
        );
    }

    const bounding_x: c_int = if (six_ofs_x + six.original.width > img_ofs_x + img_width)
        @min(
            six_ofs_x + six.original.width,
            @divTrunc(box.x2 + six.cell_width - 1, six.cell_width) * six.cell_width,
        )
    else
        box.x2;
    const bounding_y: c_int = if (six_ofs_y + six.original.height > img_ofs_y + img_height)
        @min(
            six_ofs_y + six.original.height,
            @divTrunc(box.y2 + six.cell_height - 1, six.cell_height) * six.cell_height,
        )
    else
        box.y2;

    const required_width: c_int = bounding_x - img_ofs_x;
    const required_height: c_int = bounding_y - img_ofs_y;

    const new_width: c_int = @max(img_width, required_width);
    const new_height: c_int = @max(img_height, required_height);

    if (new_width <= img_width and new_height <= img_height) {
        pixman_region32_fini(&intersection);
        pixman_region32_fini(&pix_rect);
        return;
    }

    if (!six.@"opaque") {
        opaque_out.* = false;
    }

    const stride: c_int = new_width * @sizeOf(u32);
    const new_data: [*]u32 = @ptrCast(@alignCast(xmalloc(
        @as(usize, @intCast(stride)) * @as(usize, @intCast(new_height)),
    )));
    const pix2: ?*PixmanImage = pixman_image_create_bits_no_clear(
        @intCast(term.sixel.pixman_fmt),
        new_width,
        new_height,
        new_data,
        stride,
    );

    pixman_image_composite32(
        PIXMAN_OP_SRC,
        pix.*,
        null,
        pix2,
        0,
        0,
        0,
        0,
        0,
        0,
        img_width,
        img_height,
    );

    pixman_image_composite32(
        PIXMAN_OP_SRC,
        @ptrCast(six.original.pix),
        null,
        pix2,
        box.x1 - six_ofs_x,
        box.y2 - six_ofs_y,
        0,
        0,
        box.x1 - img_ofs_x,
        box.y2 - img_ofs_y,
        bounding_x - box.x1,
        bounding_y - box.y2,
    );

    pixman_image_composite32(
        PIXMAN_OP_SRC,
        @ptrCast(six.original.pix),
        null,
        pix2,
        box.x2 - six_ofs_x,
        box.y1 - six_ofs_y,
        0,
        0,
        box.x2 - img_ofs_x,
        box.y1 - img_ofs_y,
        bounding_x - box.x2,
        bounding_y - box.y1,
    );

    // Fill uninitialized regions with transparent
    var uninitialized_boxes: [2]PixmanBox32 = .{
        .{
            .x1 = img_ofs_x + img_width,
            .y1 = img_ofs_y,
            .x2 = img_ofs_x + new_width,
            .y2 = img_ofs_y + new_height,
        },
        .{
            .x1 = img_ofs_x,
            .y1 = img_ofs_y + img_height,
            .x2 = img_ofs_x + new_width,
            .y2 = img_ofs_y + new_height,
        },
    };
    var uninitialized: PixmanRegion32 = undefined;
    _ = pixman_region32_init_rects(&uninitialized, &uninitialized_boxes, 2);

    var diff: PixmanRegion32 = undefined;
    pixman_region32_init(&diff);
    _ = pixman_region32_subtract(&diff, &uninitialized, six_rect);

    if (pixman_region32_not_empty(&diff) != 0) {
        var solid: PixmanColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
        const src = pixman_image_create_solid_fill(&solid);

        var cnt: c_int = -1;
        const rects = pixman_region32_rectangles(&diff, &cnt);

        var i: c_int = 0;
        while (i < cnt) : (i += 1) {
            const r = &rects[@intCast(i)];
            pixman_image_composite32(
                PIXMAN_OP_SRC,
                src,
                null,
                pix2,
                0,
                0,
                0,
                0,
                r.x1 - img_ofs_x,
                r.y1 - img_ofs_y,
                r.x2 - r.x1,
                r.y2 - r.y1,
            );
        }

        pixman_image_unref(src);
        opaque_out.* = false;
    }

    pixman_region32_fini(&diff);
    pixman_region32_fini(&uninitialized);

    // Replace old pixmap with new
    if (pix.*) |p| {
        const old_data = pixman_image_get_data(p);
        if (old_data) |d| free(@ptrCast(d));
        pixman_image_unref(p);
    }
    pix.* = pix2;

    pixman_region32_fini(&intersection);
    pixman_region32_fini(&pix_rect);
}

// ── D2: sixel_overwrite + _sixel_overwrite_by_rectangle ─────────

fn sixel_overwrite_internal(
    term: *types.Terminal,
    six: *types.Sixel,
    row: c_int,
    col: c_int,
    height: c_int,
    width: c_int,
    pix: ?*?*PixmanImage,
    opaque_out: ?*bool,
) void {
    var six_rect: PixmanRegion32 = undefined;
    pixman_region32_init_rect(
        &six_rect,
        six.pos.col * six.cell_width,
        six.pos.row * six.cell_height,
        @intCast(six.original.width),
        @intCast(six.original.height),
    );

    var overwrite_rect: PixmanRegion32 = undefined;
    pixman_region32_init_rect(
        &overwrite_rect,
        col * six.cell_width,
        row * six.cell_height,
        @intCast(width * six.cell_width),
        @intCast(height * six.cell_height),
    );

    if (pix != null) {
        blend_new_image_over_old(term, six, &six_rect, row, col, pix.?, opaque_out.?);
    }

    var diff: PixmanRegion32 = undefined;
    pixman_region32_init(&diff);
    _ = pixman_region32_subtract(&diff, &six_rect, &overwrite_rect);

    pixman_region32_fini(&six_rect);
    pixman_region32_fini(&overwrite_rect);

    var n_rects: c_int = -1;
    const boxes = pixman_region32_rectangles(&diff, &n_rects);

    var i: c_int = 0;
    while (i < n_rects) : (i += 1) {
        const box = &boxes[@intCast(i)];

        // C: xassert(boxes[i].x1 % six->cell_width == 0);
        //    xassert(boxes[i].y1 % six->cell_height == 0);

        const new_col: c_int = @divTrunc(box.x1, six.cell_width);
        const new_row: c_int = @divTrunc(box.y1, six.cell_height);

        const new_width: c_int = box.x2 - box.x1;
        const new_height: c_int = box.y2 - box.y1;

        const new_data: [*]u32 = @ptrCast(@alignCast(xmalloc(
            @as(usize, @intCast(new_width)) *
                @as(usize, @intCast(new_height)) *
                @sizeOf(u32),
        )));
        const old_data: [*]const u32 = @ptrCast(@alignCast(six.original.data));

        const x_ofs: c_int = box.x1 - six.pos.col * six.cell_width;
        const y_ofs: c_int = box.y1 - six.pos.row * six.cell_height;

        var j: usize = 0;
        while (j < @as(usize, @intCast(new_height))) : (j += 1) {
            const dst_off: usize = j * @as(usize, @intCast(new_width));
            const src_off: usize =
                (@as(usize, @intCast(y_ofs)) + j) *
                @as(usize, @intCast(six.original.width)) +
                @as(usize, @intCast(x_ofs));
            @memcpy(
                new_data[dst_off .. dst_off + @as(usize, @intCast(new_width))],
                old_data[src_off .. src_off + @as(usize, @intCast(new_width))],
            );
        }

        const new_pix: ?*PixmanImage = pixman_image_create_bits_no_clear(
            @intCast(term.sixel.pixman_fmt),
            new_width,
            new_height,
            new_data,
            new_width * @sizeOf(u32),
        );

        const new_six: types.Sixel = .{
            .pix = null,
            .width = -1,
            .height = -1,
            .pos = .{ .col = new_col, .row = new_row },
            .cols = @divTrunc(new_width + six.cell_width - 1, six.cell_width),
            .rows = @divTrunc(new_height + six.cell_height - 1, six.cell_height),
            .@"opaque" = six.@"opaque",
            .cell_width = six.cell_width,
            .cell_height = six.cell_height,
            .original = .{
                .data = @ptrCast(new_data),
                .pix = @ptrCast(new_pix),
                .width = new_width,
                .height = new_height,
            },
            .scaled = .{
                .data = null,
                .pix = null,
                .width = -1,
                .height = -1,
            },
        };

        sixel_insert(term, new_six);
    }

    pixman_region32_fini(&diff);
}

export fn _sixel_overwrite_by_rectangle(
    term: *types.Terminal,
    row: c_int,
    col: c_int,
    height: c_int,
    width: c_int,
    pix: ?*?*PixmanImage,
    opaque_out: ?*bool,
) callconv(.c) void {
    const start: c_int = row;
    const end: c_int = row + height - 1;

    const scrollback_rel_start: c_int = grid_row_abs_to_sb(term.grid.?, term.rows, start);

    var it = term.grid.?.sixel_images.head;
    while (it) |node| {
        const next_node = node.next;
        const six = &node.item;

        const six_start: c_int = six.pos.row;
        const six_end: c_int = six_start + six.rows - 1;
        const six_scrollback_rel_end: c_int = grid_row_abs_to_sb(
            term.grid.?,
            term.rows,
            six_end,
        );

        if (six_scrollback_rel_end < scrollback_rel_start) {
            break;
        }

        if ((start <= six_start and end >= six_start) or
            (start <= six_end and end >= six_end) or
            (start >= six_start and end <= six_end))
        {
            const col_start: c_int = six.pos.col;
            const col_end: c_int = six.pos.col + six.cols - 1;

            if ((col <= col_start and col + width - 1 >= col_start) or
                (col <= col_end and col + width - 1 >= col_end) or
                (col >= col_start and col + width - 1 <= col_end))
            {
                var to_be_erased: types.Sixel = six.*;
                sixelListRemove(&term.grid.?.sixel_images, node);

                sixel_overwrite_internal(term, &to_be_erased, start, col, height, width, pix, opaque_out);
                sixel_erase(term, &to_be_erased);
            }
        }

        it = next_node;
    }
}

// ── D3: public overwrite wrappers ───────────────────────────────

export fn sixel_overwrite_by_rectangle(
    term: *types.Terminal,
    row: c_int,
    col: c_int,
    height: c_int,
    width: c_int,
) callconv(.c) void {
    const grid = term.grid.?;
    if (sixelListLen(&grid.sixel_images) == 0) return;

    const start: c_int = (grid.offset + row) & (grid.num_rows - 1);
    const end: c_int = (start + height - 1) & (grid.num_rows - 1);
    const wraps: bool = end < start;

    if (wraps) {
        const rows_to_wrap_around: c_int = grid.num_rows - start;
        _sixel_overwrite_by_rectangle(term, start, col, rows_to_wrap_around, width, null, null);
        _sixel_overwrite_by_rectangle(term, 0, col, height - rows_to_wrap_around, width, null, null);
    } else {
        _sixel_overwrite_by_rectangle(term, start, col, height, width, null, null);
    }

    term.bits_affecting_ascii_printer._.sixels =
        sixelListLen(&term.grid.?.sixel_images) > 0;
    term_update_ascii_printer(term);
}

export fn sixel_overwrite_by_row(
    term: *types.Terminal,
    _row: c_int,
    col_in: c_int,
    width_in: c_int,
) callconv(.c) void {
    var col: c_int = col_in;
    var width: c_int = width_in;
    _ = &col;

    const grid = term.grid.?;
    if (col + width > grid.num_cols) {
        width = grid.num_cols - col;
    }

    if (sixelListLen(&grid.sixel_images) == 0) return;

    const row: c_int = (grid.offset + _row) & (grid.num_rows - 1);
    const scrollback_rel_row: c_int = grid_row_abs_to_sb(grid, term.rows, row);

    var it = grid.sixel_images.head;
    while (it) |node| {
        const next_node = node.next;
        const six = &node.item;
        const six_start: c_int = six.pos.row;
        const six_end: c_int = (six_start + six.rows - 1) & (grid.num_rows - 1);

        const six_scrollback_rel_end: c_int = grid_row_abs_to_sb(grid, term.rows, six_end);

        if (six_scrollback_rel_end < scrollback_rel_row) {
            break;
        }

        if (row >= six_start and row <= six_end) {
            const col_start: c_int = six.pos.col;
            const col_end: c_int = six.pos.col + six.cols - 1;

            if ((col <= col_start and col + width - 1 >= col_start) or
                (col <= col_end and col + width - 1 >= col_end) or
                (col >= col_start and col + width - 1 <= col_end))
            {
                var to_be_erased: types.Sixel = six.*;
                sixelListRemove(&grid.sixel_images, node);

                sixel_overwrite_internal(term, &to_be_erased, row, col, 1, width, null, null);
                sixel_erase(term, &to_be_erased);
            }
        }

        it = next_node;
    }

    term.bits_affecting_ascii_printer._.sixels =
        sixelListLen(&term.grid.?.sixel_images) > 0;
    term_update_ascii_printer(term);
}

export fn sixel_overwrite_at_cursor(term: *types.Terminal, width: c_int) callconv(.c) void {
    const grid = term.grid.?;
    if (sixelListLen(&grid.sixel_images) == 0) return;
    sixel_overwrite_by_row(
        term,
        grid.cursor.point.row,
        grid.cursor.point.col,
        width,
    );
}

export fn sixel_cell_size_changed(term: *types.Terminal) callconv(.c) void {
    var it = term.normal.sixel_images.head;
    while (it) |node| : (it = node.next) {
        sixel_invalidate_cache(&node.item);
    }
    var it2 = term.alt.sixel_images.head;
    while (it2) |node| : (it2 = node.next) {
        sixel_invalidate_cache(&node.item);
    }
}

// ── Chunk E: sync_cache + reflow + unhook ────────────────────────

extern fn term_linefeed(term: *types.Terminal) callconv(.c) void;
extern fn term_cursor_to(term: *types.Terminal, row: c_int, col: c_int) callconv(.c) void;
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;

// pixman_fixed_t = int32_t (16.16 fixed point)
const PixmanTransform = extern struct {
    matrix: [3][3]i32,
};
const PixmanFTransform = extern struct {
    m: [3][3]f64,
};

extern fn pixman_f_transform_init_scale(t: *PixmanFTransform, sx: f64, sy: f64) callconv(.c) void;
extern fn pixman_transform_from_pixman_f_transform(
    t: *PixmanTransform,
    ft: *const PixmanFTransform,
) callconv(.c) c_int;
extern fn pixman_image_set_transform(
    image: ?*PixmanImage,
    transform: ?*const PixmanTransform,
) callconv(.c) c_int;
extern fn pixman_image_set_filter(
    image: ?*PixmanImage,
    filter: c_int,
    filter_params: ?[*]const i32,
    n_filter_params: c_int,
) callconv(.c) void;

const PIXMAN_FILTER_BILINEAR: c_int = 4;

export fn sixel_sync_cache(term: *const types.Terminal, six: *types.Sixel) callconv(.c) void {
    if (six.pix != null) {
        return;
    }

    if (six.cell_width == term.cell_width and six.cell_height == term.cell_height) {
        six.pix = six.original.pix;
        six.width = six.original.width;
        six.height = six.original.height;
    } else {
        const width_ratio: f64 =
            @as(f64, @floatFromInt(term.cell_width)) / @as(f64, @floatFromInt(six.cell_width));
        const height_ratio: f64 =
            @as(f64, @floatFromInt(term.cell_height)) / @as(f64, @floatFromInt(six.cell_height));

        var scale: PixmanFTransform = undefined;
        pixman_f_transform_init_scale(&scale, 1.0 / width_ratio, 1.0 / height_ratio);

        var scale32: PixmanTransform = undefined;
        _ = pixman_transform_from_pixman_f_transform(&scale32, &scale);

        _ = pixman_image_set_transform(
            @ptrCast(six.original.pix),
            &scale32,
        );
        pixman_image_set_filter(
            @ptrCast(six.original.pix),
            PIXMAN_FILTER_BILINEAR,
            null,
            0,
        );

        const scaled_width: c_int = @intFromFloat(@as(f64, @floatFromInt(six.original.width)) * width_ratio);
        const scaled_height: c_int = @intFromFloat(@as(f64, @floatFromInt(six.original.height)) * height_ratio);
        const scaled_stride: c_int = scaled_width * @sizeOf(u32);

        const scaled_data: [*]u8 = @ptrCast(@alignCast(xmalloc(
            @as(usize, @intCast(scaled_height)) *
                @as(usize, @intCast(scaled_stride)),
        )));
        const scaled_pix: ?*PixmanImage = pixman_image_create_bits_no_clear(
            @intCast(term.sixel.pixman_fmt),
            scaled_width,
            scaled_height,
            @ptrCast(scaled_data),
            scaled_stride,
        );

        pixman_image_composite32(
            PIXMAN_OP_SRC,
            @ptrCast(six.original.pix),
            null,
            scaled_pix,
            0,
            0,
            0,
            0,
            0,
            0,
            scaled_width,
            scaled_height,
        );

        _ = pixman_image_set_transform(@ptrCast(six.original.pix), null);

        six.scaled.data = @ptrCast(scaled_data);
        six.scaled.pix = @ptrCast(scaled_pix);
        six.pix = @ptrCast(scaled_pix);
        six.scaled.width = scaled_width;
        six.width = scaled_width;
        six.scaled.height = scaled_height;
        six.height = scaled_height;
    }
}

export fn sixel_reflow_grid(term: *types.Terminal, grid: *types.Grid) callconv(.c) void {
    // Swap term.grid to `grid` temporarily
    const active_grid: *types.Grid = term.grid.?;
    term.grid = grid;

    // Collect current sixels into a temporary list (preserving order)
    var copy_head: ?*types.SixelNode = null;
    var copy_tail: ?*types.SixelNode = null;
    var copy_len: usize = 0;
    var it = grid.sixel_images.head;
    while (it) |node| {
        const new_node = @as(*types.SixelNode, @ptrCast(@alignCast(xmalloc(@sizeOf(types.SixelNode)))));
        new_node.* = .{
            .item = node.item,
            .prev = copy_tail,
            .next = null,
        };
        if (copy_tail) |t| {
            t.next = new_node;
        } else {
            copy_head = new_node;
        }
        copy_tail = new_node;
        copy_len += 1;
        it = node.next;
    }
    var copy: types.SixelList = .{
        .head = copy_head,
        .tail = copy_tail,
        .length = copy_len,
    };

    // Free the real list's nodes (not items — items are now in `copy`)
    sixelListFree(&grid.sixel_images);

    // Iterate copy in reverse (from tail to head)
    var cur = copy.tail;
    while (cur) |node| {
        const prev_node = node.prev;

        const start: c_int = node.item.pos.row;
        const end: c_int = (start + node.item.rows - 1) & (grid.num_rows - 1);

        var destroyed = false;

        if (end < start) {
            sixel_destroy(&node.item);
            destroyed = true;
        } else if (node.item.rows > grid.num_rows) {
            sixel_destroy(&node.item);
            destroyed = true;
        } else {
            // Drop sixels that now cross scrollback end border
            var last_row: c_int = -1;
            var j: c_int = 0;
            while (j < node.item.rows) : (j += 1) {
                const row_no = grid_row_abs_to_sb(term.grid.?, term.rows, node.item.pos.row + j);
                if (last_row != -1 and last_row >= row_no) {
                    sixel_destroy(&node.item);
                    destroyed = true;
                    break;
                }
                last_row = row_no;
            }
        }

        if (!destroyed) {
            var pix_opt: ?*PixmanImage = @ptrCast(node.item.original.pix);
            var opaque_tmp: bool = node.item.@"opaque";

            _sixel_overwrite_by_rectangle(
                term,
                node.item.pos.row,
                node.item.pos.col,
                node.item.rows,
                node.item.cols,
                &pix_opt,
                &opaque_tmp,
            );

            const new_pix_ptr: ?*anyopaque = @ptrCast(pix_opt);
            if (node.item.original.data != @as(?*anyopaque, @ptrCast(pixman_image_get_data(pix_opt)))) {
                node.item.original.data = @ptrCast(pixman_image_get_data(pix_opt));
                node.item.original.width = pixman_image_get_width(pix_opt);
                node.item.original.height = pixman_image_get_height(pix_opt);
                node.item.cols = @divTrunc(node.item.original.width + node.item.cell_width - 1, node.item.cell_width);
                node.item.rows = @divTrunc(node.item.original.height + node.item.cell_height - 1, node.item.cell_height);
                sixel_invalidate_cache(&node.item);
            }
            node.item.original.pix = new_pix_ptr;
            node.item.@"opaque" = opaque_tmp;

            sixel_insert(term, node.item);
        }

        cur = prev_node;
    }

    sixelListFree(&copy);
    term.grid = active_grid;
}

export fn sixel_reflow(term: *types.Terminal) callconv(.c) void {
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const grid: *types.Grid = if (i == 0) &term.normal else &term.alt;
        sixel_reflow_grid(term, grid);
    }
}

export fn sixel_unhook(term: *types.Terminal) callconv(.c) void {
    if (term.sixel.pos.row < term.sixel.image.height and
        term.sixel.pos.row + 6 * term.sixel.pan >= term.sixel.image.height)
    {
        term.sixel.image.height = term.sixel.image.alloc_height;
    }

    if (term.sixel.pos.col > 0) {
        const bits: c_int = @bitSizeOf(c_uint);
        const leading_zeroes: c_int = if (term.sixel.image.bottom_pixel == 0)
            bits
        else
            @intCast(@clz(@as(u32, term.sixel.image.bottom_pixel)));
        const rows_to_trim: c_int = leading_zeroes + 6 - bits;

        if (term.sixel.pos.row + 6 * term.sixel.pan >= term.sixel.image.alloc_height) {
            const trimmed_height: c_int =
                term.sixel.image.alloc_height - rows_to_trim * term.sixel.pan;

            if (term.sixel.transparent_bg) {
                term.sixel.image.height = trimmed_height;
            } else {
                if (trimmed_height > term.sixel.image.height) {
                    term.sixel.image.height = trimmed_height;
                }
            }
        }

        term.sixel.pos.row += 6 * term.sixel.pan;
        term.sixel.pos.row -= rows_to_trim * term.sixel.pan;
    }

    var pixel_row_idx: c_int = 0;
    var pixel_rows_left: c_int = term.sixel.image.height;
    const stride: c_int = term.sixel.image.width * @sizeOf(u32);

    const do_scroll: bool = types.sixelGetScrolling(term);

    var rows_avail: c_int = if (do_scroll)
        @divTrunc(term.sixel.image.height + term.cell_height - 1, term.cell_height)
    else
        term.scroll_region.end;

    var start_row: c_int = if (do_scroll) term.grid.?.cursor.point.row else 0;
    const start_col: c_int = if (do_scroll) term.grid.?.cursor.point.col else 0;

    const rows_needed: c_int =
        @divTrunc(term.sixel.image.height + term.cell_height - 1, term.cell_height);

    var free_image_data: bool = true;

    while (pixel_rows_left > 0 and
        rows_avail > 0 and
        rows_needed <= term.grid.?.num_rows)
    {
        const cur_row: c_int = (term.grid.?.offset + start_row) & (term.grid.?.num_rows - 1);
        const rows_left_until_wrap_around: c_int = term.grid.?.num_rows - cur_row;
        const usable_rows: c_int = @min(rows_avail, rows_left_until_wrap_around);

        const pixel_rows_avail: c_int = usable_rows * term.cell_height;

        const width: c_int = term.sixel.image.width;
        const height: c_int = @min(pixel_rows_left, pixel_rows_avail);

        var img_data: [*]u32 = undefined;
        if (pixel_row_idx == 0 and height == pixel_rows_left) {
            img_data = term.sixel.image.data.?;
            free_image_data = false;
        } else {
            const alloc_size: usize =
                @as(usize, @intCast(height)) * @as(usize, @intCast(stride));
            img_data = @ptrCast(@alignCast(xmalloc(alloc_size)));
            const src_bytes: [*]const u8 = @ptrCast(term.sixel.image.data.?);
            const src_off: usize = @as(usize, @intCast(pixel_row_idx)) * @as(usize, @intCast(stride));
            const dst_bytes: [*]u8 = @ptrCast(img_data);
            @memcpy(dst_bytes[0..alloc_size], src_bytes[src_off .. src_off + alloc_size]);
        }

        var image: types.Sixel = .{
            .pix = null,
            .width = -1,
            .height = -1,
            .rows = @divTrunc(height + term.cell_height - 1, term.cell_height),
            .cols = @divTrunc(width + term.cell_width - 1, term.cell_width),
            .pos = .{ .col = start_col, .row = cur_row },
            .@"opaque" = !term.sixel.transparent_bg,
            .cell_width = term.cell_width,
            .cell_height = term.cell_height,
            .original = .{
                .data = @ptrCast(img_data),
                .pix = null,
                .width = width,
                .height = height,
            },
            .scaled = .{
                .data = null,
                .pix = null,
                .width = -1,
                .height = -1,
            },
        };

        const new_pix = pixman_image_create_bits_no_clear(
            @intCast(term.sixel.pixman_fmt),
            image.original.width,
            image.original.height,
            @ptrCast(img_data),
            stride,
        );
        image.original.pix = @ptrCast(new_pix);

        pixel_row_idx += height;
        pixel_rows_left -= height;
        rows_avail -= image.rows;

        if (do_scroll) {
            const linefeed_count: c_int = if (rows_avail == 0)
                @max(0, image.rows - 1)
            else
                image.rows;

            var i: c_int = 0;
            while (i < linefeed_count) : (i += 1) {
                term_linefeed(term);
            }

            if (rows_avail == 0) {
                var row: c_int = term.grid.?.cursor.point.row;

                const pixel_rows: c_int = if (pixel_rows_left > 0)
                    image.original.height
                else
                    term.sixel.pos.row;
                const term_rows: c_int =
                    @divTrunc(pixel_rows + term.cell_height - 1, term.cell_height);

                row -= (image.rows - term_rows);

                const new_col: c_int = if (types.sixelGetCursorRightOfGraphics(term))
                    @min(image.pos.col + image.cols, term.cols - 1)
                else
                    image.pos.col;
                term_cursor_to(term, @max(0, row), new_col);
            }

            term.sixel.pos.row -= image.original.height;
        }

        // Dirty touched cells
        var ii: c_int = 0;
        while (ii < image.rows) : (ii += 1) {
            const r = term.grid.?.rows.?[@intCast(cur_row + ii)] orelse continue;
            r.dirty = true;

            const col_end = @min(image.pos.col + image.cols, term.cols);
            var cc: c_int = image.pos.col;
            while (cc < col_end) : (cc += 1) {
                r.cells.?[@intCast(cc)].attrs.clean = false;
            }
        }

        var pix_opt: ?*PixmanImage = new_pix;
        var opaque_tmp: bool = image.@"opaque";

        _sixel_overwrite_by_rectangle(
            term,
            image.pos.row,
            image.pos.col,
            image.rows,
            image.cols,
            &pix_opt,
            &opaque_tmp,
        );

        if (image.original.data != @as(?*anyopaque, @ptrCast(pixman_image_get_data(pix_opt)))) {
            image.original.data = @ptrCast(pixman_image_get_data(pix_opt));
            image.original.width = pixman_image_get_width(pix_opt);
            image.original.height = pixman_image_get_height(pix_opt);
            image.cols = @divTrunc(image.original.width + image.cell_width - 1, image.cell_width);
            image.rows = @divTrunc(image.original.height + image.cell_height - 1, image.cell_height);
            sixel_invalidate_cache(&image);
        }
        image.original.pix = @ptrCast(pix_opt);
        image.@"opaque" = opaque_tmp;

        sixel_insert(term, image);

        if (do_scroll) {
            start_row = term.grid.?.cursor.point.row;
        } else {
            start_row -= image.rows;
        }
    }

    if (free_image_data) {
        if (term.sixel.image.data) |d| free(@ptrCast(d));
    }

    term.sixel.image.data = null;
    term.sixel.image.p = null;
    term.sixel.image.width = 0;
    term.sixel.image.height = 0;
    term.sixel.pos = .{ .col = 0, .row = 0 };

    if (term.sixel.private_palette) |p| free(@ptrCast(p));
    term.sixel.private_palette = null;

    term.bits_affecting_ascii_printer._.sixels =
        sixelListLen(&term.grid.?.sixel_images) > 0;
    term_update_ascii_printer(term);
    render_refresh(term);
}
