//! Zig port of render.c, started with the drawing primitives (D3a):
//! colour conversion/dimming/brightening, the underline/strikeout/cursor
//! painters and `cursor_colors_for_cell()`.
//!
//! Everything that touches `pixman` goes through the real library symbols;
//! `pixman_int_to_fixed()` and the hard-coded operator/format constants are
//! mirrored here (they are macro/enum values, not ABI). `fcft_font` is *not*
//! mirrored: it is a library struct that may change between fcft releases, so
//! its metrics come from `terminal_shim_fcft_font_*()` accessors instead.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

const Terminal = types.Terminal;
const Attributes = types.Attributes;
const Cell = types.Cell;
const CursorStyle = types.CursorStyle;
const CursorUnfocusedStyle = types.CursorUnfocusedStyle;
const UnderlineStyle = types.UnderlineStyle;
const PtOrPx = types.PtOrPx;

// ─────────────────────────────────────────────────────────────────────────
// pixman
// ─────────────────────────────────────────────────────────────────────────

pub const PixmanColor = extern struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,
};

pub const PixmanRectangle16 = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

pub const PixmanImage = opaque {};

const PIXMAN_OP_SRC: c_int = 0x01;

extern fn pixman_image_fill_rectangles(
    op: c_int,
    image: *PixmanImage,
    color: *const PixmanColor,
    n_rects: c_int,
    rects: [*]const PixmanRectangle16,
) callconv(.c) c_int;

// ─────────────────────────────────────────────────────────────────────────
// foot / C shims
// ─────────────────────────────────────────────────────────────────────────

extern fn term_pt_or_px_as_pixels(term: *const Terminal, pt_or_px: *const PtOrPx) callconv(.c) c_int;
extern fn term_theme_get(term: *const Terminal) callconv(.c) *const types.ColorTheme;
extern fn wayl_do_linear_blending(wl: ?*const types.Wayland, conf: *const types.Config) callconv(.c) bool;

extern fn terminal_shim_fcft_font_ascent(font: *const anyopaque) callconv(.c) c_int;
extern fn terminal_shim_fcft_font_descent(font: *const anyopaque) callconv(.c) c_int;
extern fn terminal_shim_fcft_font_underline_position(font: *const anyopaque) callconv(.c) c_int;
extern fn terminal_shim_fcft_font_underline_thickness(font: *const anyopaque) callconv(.c) c_int;
extern fn terminal_shim_fcft_font_strikeout_position(font: *const anyopaque) callconv(.c) c_int;
extern fn terminal_shim_fcft_font_strikeout_thickness(font: *const anyopaque) callconv(.c) c_int;

/// The trapezoid path needs `pixman_trapezoid_t`, which C owns; keep the
/// geometry computation here and the composite call in the shim.
extern fn render_shim_curly_underline(
    pix: *PixmanImage,
    color: *const PixmanColor,
    x: c_int,
    top: c_int,
    bot: c_int,
    half_x: c_int,
    full_x: c_int,
    th: c_int,
) callconv(.c) void;

/// `srgb_decode_8_to_16_table[]` is generated into the build directory by
/// `scripts/srgb.py`.
extern const srgb_decode_8_to_16_table: [256]u16;

fn srgbDecode8To16(v: u8) u16 {
    return srgb_decode_8_to_16_table[v];
}

/// `struct fcft_font *`. Opaque by design, see the file comment.
pub const FcftFont = anyopaque;

fn fillRect(
    pix: *PixmanImage,
    color: *const PixmanColor,
    rects: []const PixmanRectangle16,
) void {
    _ = pixman_image_fill_rectangles(
        PIXMAN_OP_SRC, pix, color, @intCast(rects.len), rects.ptr);
}

// ─────────────────────────────────────────────────────────────────────────
// Colour helpers
// ─────────────────────────────────────────────────────────────────────────

export fn attrs_to_font(term: *const Terminal, attrs: *const align(4) Attributes) callconv(.c) ?*FcftFont {
    const idx: usize = @as(usize, @intFromBool(attrs.italic)) * 2 + @intFromBool(attrs.bold);
    return @ptrCast(term.fonts[idx]);
}

fn colorHexToPixmanSrgb(color: u32, alpha: u16) PixmanColor {
    return .{
        .alpha = alpha, // Consider alpha linear already?
        .red = srgbDecode8To16(@truncate(color >> 16)),
        .green = srgbDecode8To16(@truncate(color >> 8)),
        .blue = srgbDecode8To16(@truncate(color)),
    };
}

export fn color_hex_to_pixman_with_alpha(color: u32, alpha: u16, srgb: bool) callconv(.c) PixmanColor {
    var ret: PixmanColor = if (srgb)
        colorHexToPixmanSrgb(color, alpha)
    else
        .{
            .red = @truncate(((color >> 16) & 0xff) | ((color >> 8) & 0xff00)),
            .green = @truncate(((color >> 8) & 0xff) | (color & 0xff00)),
            .blue = @truncate((color & 0xff) | ((color << 8) & 0xff00)),
            .alpha = alpha,
        };

    ret.red = @intCast(@as(u32, ret.red) * alpha / 0xffff);
    ret.green = @intCast(@as(u32, ret.green) * alpha / 0xffff);
    ret.blue = @intCast(@as(u32, ret.blue) * alpha / 0xffff);

    return ret;
}

export fn color_hex_to_pixman(color: u32, srgb: bool) callconv(.c) PixmanColor {
    return color_hex_to_pixman_with_alpha(color, 0xffff, srgb);
}

fn iLerp(from: c_int, to: c_int, t: f32) c_int {
    return from + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(to - from)) * t));
}

export fn color_blend_towards(from: u32, to: u32, amount: f32) callconv(.c) u32 {
    if (amount == 0)
        return from;

    const t = 1 - 1 / amount;

    const alpha = from & 0xff000000;
    // C stores the (possibly negative / >255) lerp result in a uint8_t.
    const r: u8 = @truncate(@as(u32, @bitCast(iLerp(@intCast((from >> 16) & 0xff), @intCast((to >> 16) & 0xff), t))));
    const g: u8 = @truncate(@as(u32, @bitCast(iLerp(@intCast((from >> 8) & 0xff), @intCast((to >> 8) & 0xff), t))));
    const b: u8 = @truncate(@as(u32, @bitCast(iLerp(@intCast(from & 0xff), @intCast(to & 0xff), t))));

    return alpha | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

export fn color_dim(term: *const Terminal, color: u32) callconv(.c) u32 {
    const conf = term.conf.?;
    const custom_dim = conf.colors_dark.use_custom.dim;

    if (custom_dim != 0) {
        for (0..8) |i| {
            if ((custom_dim >> @intCast(i)) & 1 == 0)
                continue;

            if (term.colors.table[i] == color) {
                // "Regular" color, return the corresponding "dim"
                return conf.colors_dark.dim[i];
            } else if (term.colors.table[8 + i] == color) {
                // "Bright" color, return the corresponding "regular"
                return term.colors.table[i];
            }
        }
    }

    const theme = term_theme_get(term);

    return color_blend_towards(
        color,
        if (theme.dim_blend_towards == .blend_towards_black) 0x00000000 else 0x00ffffff,
        conf.dim.amount,
    );
}

export fn color_brighten(term: *const Terminal, color: u32) callconv(.c) u32 {
    // First try to match the color against the base 8 colors. If we find a
    // match, return the corresponding bright color.
    if (term.conf.?.bold_in_bright.palette_based) {
        for (0..8) |i| {
            if (term.colors.table[i] == color)
                return term.colors.table[i + 8];
        }
        return color;
    }

    return color_blend_towards(color, 0x00ffffff, term.conf.?.bold_in_bright.amount);
}

// ─────────────────────────────────────────────────────────────────────────
// Cursor / decoration painters
// ─────────────────────────────────────────────────────────────────────────

export fn draw_hollow_block(
    term: *const Terminal,
    pix: *PixmanImage,
    color: *const PixmanColor,
    x: c_int,
    y: c_int,
    cell_cols: c_int,
) callconv(.c) void {
    const scale: c_int = @intFromFloat(@round(term.scale));
    const width = @min(@min(scale, term.cell_width), term.cell_height);
    const cw = cell_cols * term.cell_width;

    fillRect(pix, color, &.{
        .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(cw), .height = @intCast(width) }, // top
        .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(width), .height = @intCast(term.cell_height) }, // left
        .{ .x = @intCast(x + cw - width), .y = @intCast(y), .width = @intCast(width), .height = @intCast(term.cell_height) }, // right
        .{ .x = @intCast(x), .y = @intCast(y + term.cell_height - width), .width = @intCast(cw), .height = @intCast(width) }, // bottom
    });
}

export fn draw_beam_cursor(
    term: *const Terminal,
    pix: *PixmanImage,
    font: *const FcftFont,
    color: *const PixmanColor,
    x: c_int,
    y: c_int,
) callconv(.c) void {
    const baseline = y + term.font_baseline - terminal_shim_fcft_font_ascent(font);
    fillRect(pix, color, &.{.{
        .x = @intCast(x),
        .y = @intCast(baseline),
        .width = @intCast(term_pt_or_px_as_pixels(term, &term.conf.?.cursor.beam_thickness)),
        .height = @intCast(terminal_shim_fcft_font_ascent(font) + terminal_shim_fcft_font_descent(font)),
    }});
}

fn underlineOffset(term: *const Terminal, font: *const FcftFont) c_int {
    return term.font_baseline -
        (if (term.conf.?.use_custom_underline_offset)
            -term_pt_or_px_as_pixels(term, &term.conf.?.underline_offset)
        else
            terminal_shim_fcft_font_underline_position(font));
}

export fn draw_underline_cursor(
    term: *const Terminal,
    pix: *PixmanImage,
    font: *const FcftFont,
    color: *const PixmanColor,
    x: c_int,
    y: c_int,
    cols: c_int,
) callconv(.c) void {
    const thickness = if (term.conf.?.cursor.underline_thickness.px >= 0)
        term_pt_or_px_as_pixels(term, &term.conf.?.cursor.underline_thickness)
    else
        terminal_shim_fcft_font_underline_thickness(font);

    // Make sure the line isn't positioned below the cell
    const y_ofs = @min(underlineOffset(term, font) + thickness, term.cell_height - thickness);

    fillRect(pix, color, &.{.{
        .x = @intCast(x),
        .y = @intCast(y + y_ofs),
        .width = @intCast(cols * term.cell_width),
        .height = @intCast(thickness),
    }});
}

export fn draw_underline(
    term: *const Terminal,
    pix: *PixmanImage,
    font: *const FcftFont,
    color: *const PixmanColor,
    x: c_int,
    y: c_int,
    cols: c_int,
) callconv(.c) void {
    const thickness = if (term.conf.?.underline_thickness.px >= 0)
        term_pt_or_px_as_pixels(term, &term.conf.?.underline_thickness)
    else
        terminal_shim_fcft_font_underline_thickness(font);

    // Make sure the line isn't positioned below the cell
    const y_ofs = @min(underlineOffset(term, font), term.cell_height - thickness);

    fillRect(pix, color, &.{.{
        .x = @intCast(x),
        .y = @intCast(y + y_ofs),
        .width = @intCast(cols * term.cell_width),
        .height = @intCast(thickness),
    }});
}

/// Upper bound on the dots-per-cell buffer. `per_cell` is
/// `cell_width / thickness / 2`, so it only gets large with a very thin
/// underline in a very wide cell; the fallback below keeps the output
/// identical if that ever happens.
const max_dots = 256;

export fn draw_styled_underline(
    term: *const Terminal,
    pix: *PixmanImage,
    font: *const FcftFont,
    color: *const PixmanColor,
    style: UnderlineStyle,
    x: c_int,
    y: c_int,
    cols: c_int,
) callconv(.c) void {
    std.debug.assert(style != .none);

    if (style == .single) {
        draw_underline(term, pix, font, color, x, y, cols);
        return;
    }

    const thickness = if (term.conf.?.underline_thickness.px >= 0)
        term_pt_or_px_as_pixels(term, &term.conf.?.underline_thickness)
    else
        terminal_shim_fcft_font_underline_thickness(font);

    const y_ofs: c_int = switch (style) {
        .double, .curly => @min(underlineOffset(term, font), term.cell_height - thickness * 3),
        .dashed, .dotted => @min(underlineOffset(term, font), term.cell_height - thickness),
        .none, .single => unreachable,
    };

    const ceil_w = cols * term.cell_width;

    switch (style) {
        .double => fillRect(pix, color, &.{
            .{ .x = @intCast(x), .y = @intCast(y + y_ofs), .width = @intCast(ceil_w), .height = @intCast(thickness) },
            .{ .x = @intCast(x), .y = @intCast(y + y_ofs + thickness * 2), .width = @intCast(ceil_w), .height = @intCast(thickness) },
        }),

        .dashed => {
            const dash_w = @divTrunc(ceil_w, 3) + @intFromBool(@rem(ceil_w, 3) > 0);
            fillRect(pix, color, &.{
                .{ .x = @intCast(x), .y = @intCast(y + y_ofs), .width = @intCast(dash_w), .height = @intCast(thickness) },
                .{ .x = @intCast(x + dash_w * 2), .y = @intCast(y + y_ofs), .width = @intCast(dash_w), .height = @intCast(thickness) },
            });
        },

        .dotted => {
            // Number of dots per cell
            var per_cell = @divTrunc(@divTrunc(term.cell_width, thickness), 2);
            if (per_cell == 0)
                per_cell = 1;
            std.debug.assert(per_cell >= 1);

            // Spacing between dots: start with the same width as the dots
            // themselves, then widen them to consume the unused pixels.
            // The C version spreads the remainder round-robin over the gaps,
            // which is the closed form below (no VLA needed).
            const extra = @divTrunc(term.cell_width - (per_cell * 2) * thickness, per_cell);
            const extra_first = @rem(term.cell_width - (per_cell * 2) * thickness, per_cell);

            const spacing = struct {
                fn get(i: c_int, base: c_int, first: c_int) c_int {
                    return base + @intFromBool(i < first);
                }
            }.get;

            const base = thickness + extra;

            if (per_cell <= max_dots) {
                var rects_buf: [max_dots]PixmanRectangle16 = undefined;
                const rects = rects_buf[0..@intCast(per_cell)];

                var dot_x = x;
                for (rects, 0..) |*r, j| {
                    r.* = .{
                        .x = @intCast(dot_x),
                        .y = @intCast(y + y_ofs),
                        .width = @intCast(thickness),
                        .height = @intCast(thickness),
                    };
                    dot_x += spacing(@intCast(j), base, extra_first);
                }

                fillRect(pix, color, rects);
            } else {
                // Absurdly wide cell + hairline underline: one call per dot.
                var dot_x = x;
                for (0..@intCast(per_cell)) |j| {
                    fillRect(pix, color, &.{.{
                        .x = @intCast(dot_x),
                        .y = @intCast(y + y_ofs),
                        .width = @intCast(thickness),
                        .height = @intCast(thickness),
                    }});
                    dot_x += spacing(@intCast(j), base, extra_first);
                }
            }
        },

        .curly => {
            const top = y + y_ofs;
            const bot = top + thickness * 3;
            const half_x: c_int = @intFromFloat(@as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(ceil_w)) / 2.0);
            const full_x = x + ceil_w;

            const bt_2 = @as(f64, @floatFromInt(bot - top)) * @as(f64, @floatFromInt(bot - top));
            const th_2 = @as(f64, @floatFromInt(thickness)) * @as(f64, @floatFromInt(thickness));
            const hx_2 = @as(f64, @floatFromInt(ceil_w)) * @as(f64, @floatFromInt(ceil_w)) / 4.0;
            const th: c_int = @intFromFloat(@round(@sqrt(th_2 + (th_2 * bt_2 / hx_2)) / 2.0));

            render_shim_curly_underline(pix, color, x, top, bot, half_x, full_x, th);
        },

        .none, .single => unreachable,
    }
}

export fn draw_strikeout(
    term: *const Terminal,
    pix: *PixmanImage,
    font: *const FcftFont,
    color: *const PixmanColor,
    x: c_int,
    y: c_int,
    cols: c_int,
) callconv(.c) void {
    const thickness = if (term.conf.?.strikeout_thickness.px >= 0)
        term_pt_or_px_as_pixels(term, &term.conf.?.strikeout_thickness)
    else
        terminal_shim_fcft_font_strikeout_thickness(font);

    // Try to center custom strikeout
    const position = if (term.conf.?.strikeout_thickness.px >= 0)
        terminal_shim_fcft_font_strikeout_position(font) -
            roundToCInt(@as(f64, @floatFromInt(terminal_shim_fcft_font_strikeout_thickness(font))) / 2.0) +
            roundToCInt(@as(f64, @floatFromInt(thickness)) / 2.0)
    else
        terminal_shim_fcft_font_strikeout_position(font);

    fillRect(pix, color, &.{.{
        .x = @intCast(x),
        .y = @intCast(y + term.font_baseline - position),
        .width = @intCast(cols * term.cell_width),
        .height = @intCast(thickness),
    }});
}

fn roundToCInt(v: f64) c_int {
    return @intFromFloat(@round(v));
}

export fn cursor_colors_for_cell(
    term: *const Terminal,
    cell: *const Cell,
    fg: *const PixmanColor,
    bg: *const PixmanColor,
    cursor_color: *PixmanColor,
    text_color: *PixmanColor,
    gamma_correct: bool,
) callconv(.c) void {
    _ = cell;

    if (term.colors.cursor_bg >> 31 != 0)
        cursor_color.* = color_hex_to_pixman(term.colors.cursor_bg, gamma_correct)
    else
        cursor_color.* = fg.*;

    if (term.colors.cursor_fg >> 31 != 0)
        text_color.* = color_hex_to_pixman(term.colors.cursor_fg, gamma_correct)
    else {
        std.debug.assert(bg.alpha == 0xffff);
        text_color.* = bg.*;
    }

    if (text_color.red == cursor_color.red and
        text_color.green == cursor_color.green and
        text_color.blue == cursor_color.blue)
    {
        text_color.* = bg.*;
        cursor_color.* = fg.*;

        if (text_color.red == cursor_color.red and
            text_color.green == cursor_color.green and
            text_color.blue == cursor_color.blue)
        {
            cursor_color.red = ~cursor_color.red;
            cursor_color.green = ~cursor_color.green;
            cursor_color.blue = ~cursor_color.blue;
        }
    }
}

export fn draw_cursor(
    term: *const Terminal,
    cell: *const Cell,
    font: *const FcftFont,
    pix: *PixmanImage,
    fg: *PixmanColor,
    bg: *const PixmanColor,
    x: c_int,
    y: c_int,
    cols: c_int,
) callconv(.c) void {
    var cursor_color: PixmanColor = undefined;
    var text_color: PixmanColor = undefined;
    cursor_colors_for_cell(
        term,
        cell,
        fg,
        bg,
        &cursor_color,
        &text_color,
        wayl_do_linear_blending(term.wl, term.conf.?),
    );

    if (!term.kbd_focus) {
        switch (term.conf.?.cursor.unfocused_style) {
            .unchanged => {},
            .hollow => {
                draw_hollow_block(term, pix, &cursor_color, x, y, cols);
                return;
            },
            .none => return,
        }
    }

    switch (term.cursor_style) {
        .block => {
            if (term.cursor_blink.state != 0 or !term.kbd_focus) {
                fg.* = text_color;
                fillRect(pix, &cursor_color, &.{.{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .width = @intCast(cols * term.cell_width),
                    .height = @intCast(term.cell_height),
                }});
            }
        },

        .beam => {
            if (term.cursor_blink.state != 0 or !term.kbd_focus)
                draw_beam_cursor(term, pix, font, &cursor_color, x, y);
        },

        .underline => {
            if (term.cursor_blink.state != 0 or !term.kbd_focus)
                draw_underline_cursor(term, pix, font, &cursor_color, x, y, cols);
        },

        .hollow => {
            if (term.cursor_blink.state != 0)
                draw_hollow_block(term, pix, &cursor_color, x, y, cols);
        },
    }

}

// ─────────────────────────────────────────────────────────────────────────
// Cursor dirtiness and the refresh flags (D3b)
// ─────────────────────────────────────────────────────────────────────────

pub const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

const Itimerspec = extern struct {
    it_interval: Timespec,
    it_value: Timespec,
};

const CLOCK_MONOTONIC: c_int = 1;
const LOG_CLASS_DEBUG: c_int = 4;

extern fn clock_gettime(clockid: c_int, tp: *Timespec) callconv(.c) c_int;
extern fn timerfd_settime(fd: c_int, flags: c_int, new: *const Itimerspec, old: ?*Itimerspec) callconv(.c) c_int;
extern fn timespec_sub(a: *const Timespec, b: *const Timespec, res: *Timespec) callconv(.c) void;
extern fn terminal_shim_grid_row(grid: *types.Grid, row_no: c_int) callconv(.c) *types.Row;
extern fn terminal_shim_urls_mode_active(term: *const Terminal) callconv(.c) bool;
extern fn render_update_title(term: *Terminal) callconv(.c) void;
extern fn term_icon(term: *const Terminal) callconv(.c) [*:0]const u8;
extern fn wayland_shim_xdg_toplevel_set_app_id(toplevel: ?*anyopaque, app_id: [*:0]const u8) callconv(.c) void;
extern fn wayland_shim_toplevel_icon_set(m: ?*anyopaque, toplevel: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

/// Rate limit for title/app-id/icon updates: at most one update per 8333 µs.
const UPDATE_INTERVAL_NS: isize = 8333 * 1000;

export fn dirty_old_cursor(term: *Terminal) callconv(.c) void {
    if (term.render.last_cursor.row != null and !term.render.last_cursor.hidden) {
        const row = term.render.last_cursor.row.?;
        const cell = &row.cells.?[@intCast(term.render.last_cursor.col)];
        cell.attrs.clean = false;
        row.dirty = true;
    }

    // Remember current cursor position, for the next frame
    term.render.last_cursor.row = terminal_shim_grid_row(term.grid.?, term.grid.?.cursor.point.row);
    term.render.last_cursor.col = term.grid.?.cursor.point.col;
    term.render.last_cursor.hidden = term.hide_cursor;
}

export fn dirty_cursor(term: *Terminal) callconv(.c) void {
    if (term.hide_cursor)
        return;

    const cursor = &term.grid.?.cursor.point;
    const row = terminal_shim_grid_row(term.grid.?, cursor.row);
    const cell = &row.cells.?[@intCast(cursor.col)];
    cell.attrs.clean = false;
    row.dirty = true;
}

export fn render_refresh(term: *Terminal) callconv(.c) void {
    term.render.refresh.grid = true;
}

export fn render_refresh_csd(term: *Terminal) callconv(.c) void {
    if (term.window.?.csd_mode == .yes)
        term.render.refresh.csd = true;
}

export fn render_refresh_search(term: *Terminal) callconv(.c) void {
    if (term.is_searching)
        term.render.refresh.search = true;
}

export fn render_refresh_urls(term: *Terminal) callconv(.c) void {
    if (terminal_shim_urls_mode_active(term))
        term.render.refresh.urls = true;
}

fn lastUpdate(raw: *[16]u8) *Timespec {
    return @ptrCast(@alignCast(raw));
}

/// Shared by the title/app-id/icon updaters: if the previous update was less
/// than one interval ago, arm `timer_fd` for the remainder and return false.
fn rateLimit(last: *Timespec, timer_fd: c_int) bool {
    var now: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
        return false;

    var diff: Timespec = undefined;
    timespec_sub(&now, last, &diff);

    if (diff.tv_sec == 0 and diff.tv_nsec < UPDATE_INTERVAL_NS) {
        const timeout = Itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{ .tv_nsec = UPDATE_INTERVAL_NS - diff.tv_nsec, .tv_sec = 0 },
        };
        _ = timerfd_settime(timer_fd, 0, &timeout, null);
        return false;
    }

    last.* = now;
    return true;
}

export fn render_refresh_title(term: *Terminal) callconv(.c) void {
    if (rateLimit(lastUpdate(&term.render.title.last_update), term.render.title.timer_fd))
        render_update_title(term);

    render_refresh_csd(term);
}

export fn render_refresh_app_id(term: *Terminal) callconv(.c) void {
    if (!rateLimit(lastUpdate(&term.render.app_id.last_update), term.render.app_id.timer_fd))
        return;

    const app_id: [*:0]const u8 =
        if (term.app_id) |id| id else term.conf.?.app_id.?;

    wayland_shim_xdg_toplevel_set_app_id(term.window.?.xdg_toplevel, app_id);
}

export fn render_refresh_icon(term: *Terminal) callconv(.c) void {
    if (term.wl.?.toplevel_icon_manager == null) {
        log_msg(
            LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line),
            "compositor does not implement xdg-toplevel-icon: " ++
                "ignoring request to refresh window icon",
        );
        return;
    }

    if (!rateLimit(lastUpdate(&term.render.icon.last_update), term.render.icon.timer_fd))
        return;

    const icon_name = term_icon(term);
    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line),
        "setting toplevel icon: %s", icon_name);

    wayland_shim_toplevel_icon_set(
        term.wl.?.toplevel_icon_manager, term.window.?.xdg_toplevel, icon_name);
}

// ─────────────────────────────────────────────────────────────────────────
// Row / margin painting (D3c)
// ─────────────────────────────────────────────────────────────────────────

const Buffer = types.Buffer;

extern fn render_shim_region_union_rect(
    region: ?*anyopaque,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void;
extern fn wayland_shim_surface_damage_buffer(
    surface: ?*anyopaque,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void;

export fn render_row(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    row: *types.Row,
    row_no: c_int,
    cursor_col: c_int,
) callconv(.c) void {
    var col = term.cols - 1;
    while (col >= 0) : (col -= 1)
        _ = render_cell(term, pix, damage, row, row_no, col, cursor_col == col);
}

fn bufferPix(buf: *Buffer) *PixmanImage {
    return @ptrCast(@alignCast(buf.pix.?[0].?));
}

export fn render_urgency(term: *Terminal, buf: *Buffer) callconv(.c) void {
    const red = term.colors.table[1];
    const bg = color_hex_to_pixman(red, wayl_do_linear_blending(term.wl, term.conf.?));

    const width = @min(
        @min(term.margins.left, term.margins.right),
        @min(term.margins.top, term.margins.bottom),
    );

    fillRect(bufferPix(buf), &bg, &.{
        // Top
        .{ .x = 0, .y = 0, .width = @intCast(term.width), .height = @intCast(width) },
        // Bottom
        .{ .x = 0, .y = @intCast(term.height - width), .width = @intCast(term.width), .height = @intCast(width) },
        // Left
        .{ .x = 0, .y = @intCast(width), .width = @intCast(width), .height = @intCast(term.height - 2 * width) },
        // Right
        .{ .x = @intCast(term.width - width), .y = @intCast(width), .width = @intCast(width), .height = @intCast(term.height - 2 * width) },
    });
}

export fn render_margin(
    term: *Terminal,
    buf: *Buffer,
    start_line: c_int,
    end_line: c_int,
    apply_damage: bool,
) callconv(.c) void {
    // Fill area outside the cell grid with the default background color
    const rmargin = term.width - term.margins.right;
    const bmargin = term.height - term.margins.bottom;
    const line_count = end_line - start_line;

    const gamma_correct = wayl_do_linear_blending(term.wl, term.conf.?);
    const _bg = if (!term.reverse) term.colors.bg else term.colors.fg;
    var alpha = term.colors.alpha;

    if (term.window.?.is_fullscreen) {
        // Disable alpha in fullscreen - see render_cell() for details
        alpha = 0xffff;
    }

    const bg = color_hex_to_pixman_with_alpha(_bg, alpha, gamma_correct);

    const y_ofs: i16 = @intCast(term.margins.top + start_line * term.cell_height);

    fillRect(bufferPix(buf), &bg, &.{
        // Top
        .{ .x = 0, .y = 0, .width = @intCast(term.width), .height = @intCast(term.margins.top) },
        // Bottom
        .{ .x = 0, .y = @intCast(bmargin), .width = @intCast(term.width), .height = @intCast(term.margins.bottom) },
        // Left
        .{ .x = 0, .y = y_ofs, .width = @intCast(term.margins.left), .height = @intCast(line_count * term.cell_height) },
        // Right
        .{ .x = @intCast(rmargin), .y = y_ofs, .width = @intCast(term.margins.right), .height = @intCast(line_count * term.cell_height) },
    });

    if (term.render.urgency)
        render_urgency(term, buf);

    // Ensure the updated regions are copied to the next frame's buffer when
    // we're double buffering
    render_shim_region_union_rect(buf.dirty, 0, 0, term.width, term.margins.top);
    render_shim_region_union_rect(buf.dirty, 0, bmargin, term.width, term.margins.bottom);
    render_shim_region_union_rect(buf.dirty, 0, 0, term.margins.left, term.height);
    render_shim_region_union_rect(buf.dirty, rmargin, 0, term.margins.right, term.height);

    if (apply_damage) {
        const surf = term.window.?.surface.surf;

        // Top
        wayland_shim_surface_damage_buffer(surf, 0, 0, term.width, term.margins.top);
        // Bottom
        wayland_shim_surface_damage_buffer(surf, 0, bmargin, term.width, term.margins.bottom);
        // Left
        wayland_shim_surface_damage_buffer(
            surf, 0, term.margins.top + start_line * term.cell_height,
            term.margins.left, line_count * term.cell_height);
        // Right
        wayland_shim_surface_damage_buffer(
            surf, rmargin, term.margins.top + start_line * term.cell_height,
            term.margins.right, line_count * term.cell_height);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// CSD geometry (D3d)
// ─────────────────────────────────────────────────────────────────────────

pub const CsdData = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

extern fn wayl_win_csd_borders_visible(win: *const types.WlWindow) callconv(.c) bool;
extern fn wayl_win_csd_titlebar_visible(win: *const types.WlWindow) callconv(.c) bool;
extern fn wayl_surface_scale(
    win: *types.WlWindow,
    surf: *types.WaylSurface,
    buf: *Buffer,
    scale: f32,
) callconv(.c) void;
extern fn wayland_shim_surface_attach(surf: ?*anyopaque, buffer: ?*anyopaque, x: i32, y: i32) callconv(.c) void;
extern fn wayland_shim_surface_commit(surf: ?*anyopaque) callconv(.c) void;

fn roundf(v: f32) c_int {
    return @intFromFloat(@round(v));
}

fn fdiv(a: c_int, b: f32) f32 {
    return @as(f32, @floatFromInt(a)) / b;
}

export fn get_csd_data(term: *const Terminal, surf_idx: types.CsdSurface) callconv(.c) CsdData {
    const win = term.window.?;
    std.debug.assert(win.csd_mode == .yes);

    const borders_visible = wayl_win_csd_borders_visible(win);
    const title_visible = wayl_win_csd_titlebar_visible(win);

    const scale = term.scale;
    const conf = term.conf.?;

    const border_width: c_int = if (borders_visible)
        roundf(conf.csd.border_width * scale)
    else
        0;

    const title_height: c_int = if (title_visible)
        roundf(conf.csd.title_height * scale)
    else
        0;

    const button_width: c_int = if (title_visible)
        roundf(conf.csd.button_width * scale)
    else
        0;

    var remaining_width = term.width;

    const button_close_width: c_int = if (remaining_width >= button_width) button_width else 0;
    remaining_width -= button_close_width;
    const button_close_start = remaining_width;

    const button_maximize_width: c_int = if (remaining_width >= button_width and
        win.wm_capabilities.maximize) button_width else 0;
    remaining_width -= button_maximize_width;
    const button_maximize_start = remaining_width;

    const button_minimize_width: c_int = if (remaining_width >= button_width and
        win.wm_capabilities.minimize) button_width else 0;
    remaining_width -= button_minimize_width;
    const button_minimize_start = remaining_width;

    // With fractional scaling, we must ensure the offset, when divided by
    // the scale (in set_position()), and then scaled back (by the
    // compositor), matches the actual pixel count made up by the titlebar
    // and the border.
    const top_offset = roundf(scale * (@as(f32, @floatFromInt(roundf(fdiv(-title_height, scale)))) -
        @as(f32, @floatFromInt(roundf(fdiv(border_width, scale))))));

    const top_bottom_width = roundf(scale *
        (@as(f32, @floatFromInt(term.width)) + 2 * @as(f32, @floatFromInt(roundf(fdiv(border_width, scale))))));

    const left_right_height = roundf(scale *
        (@as(f32, @floatFromInt(roundf(fdiv(title_height, scale)))) +
            @as(f32, @floatFromInt(term.height))));

    return switch (surf_idx) {
        .title => .{ .x = 0, .y = -title_height, .width = term.width, .height = title_height },
        .left => .{ .x = -border_width, .y = -title_height, .width = border_width, .height = left_right_height },
        .right => .{ .x = term.width, .y = -title_height, .width = border_width, .height = left_right_height },
        .top => .{ .x = -border_width, .y = top_offset, .width = top_bottom_width, .height = border_width },
        .bottom => .{ .x = -border_width, .y = term.height, .width = top_bottom_width, .height = border_width },

        // Positioned relative to CSD_SURF_TITLE
        .minimize => .{ .x = button_minimize_start, .y = 0, .width = button_minimize_width, .height = title_height },
        .maximize => .{ .x = button_maximize_start, .y = 0, .width = button_maximize_width, .height = title_height },
        .close => .{ .x = button_close_start, .y = 0, .width = button_close_width, .height = title_height },
    };
}

export fn csd_commit(term: *Terminal, surf: *types.WaylSurface, buf: *Buffer) callconv(.c) void {
    wayl_surface_scale(term.window.?, surf, buf, term.scale);
    wayland_shim_surface_attach(surf.surf, buf.wl_buf, 0, 0);
    wayland_shim_surface_damage_buffer(surf.surf, 0, 0, buf.width, buf.height);
    wayland_shim_surface_commit(surf.surf);
}

export fn render_csd_part(
    term: *Terminal,
    surf: ?*anyopaque,
    buf: *Buffer,
    width: c_int,
    height: c_int,
    color: *PixmanColor,
) callconv(.c) void {
    _ = surf;
    _ = width;
    _ = height;
    std.debug.assert(term.window.?.csd_mode == .yes);

    fillRect(bufferPix(buf), color, &.{.{
        .x = 0,
        .y = 0,
        .width = @intCast(buf.width),
        .height = @intCast(buf.height),
    }});
}

// ─────────────────────────────────────────────────────────────────────────
// render_cell() (D3e)
// ─────────────────────────────────────────────────────────────────────────

const FcftGlyph = types.FcftGlyph;
const Composed = types.Composed;
const CellAttrs = types.Attributes;

const FcftGrapheme = extern struct {
    cols: c_int,
    count: usize,
    glyphs: [*]?*FcftGlyph,
};

// enum color_source, stored as a 2-bit field in `struct attributes`.
const COLOR_DEFAULT: u2 = 0;
const COLOR_BASE16: u2 = 1;
const COLOR_BASE256: u2 = 2;
const COLOR_RGB: u2 = 3;

const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

const GLYPH_BOX_DRAWING_FIRST: u32 = 0x2500;
const GLYPH_BOX_DRAWING_LAST: u32 = 0x259F;
const GLYPH_BOX_DRAWING_COUNT: usize = GLYPH_BOX_DRAWING_LAST - GLYPH_BOX_DRAWING_FIRST + 1;

const GLYPH_BRAILLE_FIRST: u32 = 0x2800;
const GLYPH_BRAILLE_LAST: u32 = 0x28FF;
const GLYPH_BRAILLE_COUNT: usize = GLYPH_BRAILLE_LAST - GLYPH_BRAILLE_FIRST + 1;

const GLYPH_OCTANTS_FIRST: u32 = 0x1CD00;
const GLYPH_OCTANTS_LAST: u32 = 0x1CDE5;
const GLYPH_OCTANTS_COUNT: usize = GLYPH_OCTANTS_LAST - GLYPH_OCTANTS_FIRST + 1;

const GLYPH_LEGACY_FIRST: u32 = 0x1FB00;
const GLYPH_LEGACY_LAST: u32 = 0x1FB9B;
const GLYPH_LEGACY_COUNT: usize = GLYPH_LEGACY_LAST - GLYPH_LEGACY_FIRST + 1;


extern fn fcft_rasterize_char_utf32(font: *const FcftFont, cp: u32, subpixel: c_int) callconv(.c) ?*FcftGlyph;
extern fn fcft_rasterize_grapheme_utf32(
    font: *const FcftFont,
    len: usize,
    chars: [*]const u32,
    subpixel: c_int,
) callconv(.c) ?*const FcftGrapheme;
extern fn composed_lookup(root: ?*Composed, key: u32) callconv(.c) ?*Composed;
extern fn box_drawing(term: *const Terminal, wc: u32) callconv(.c) ?*FcftGlyph;
extern fn term_arm_blink_timer(term: *Terminal) callconv(.c) void;
extern fn xcalloc(n: usize, size: usize) callconv(.c) ?*anyopaque;

extern fn render_shim_clip_rect(pix: *PixmanImage, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void;
extern fn render_shim_clip_clear(pix: *PixmanImage) callconv(.c) void;
extern fn render_shim_solid_fill(color: *const PixmanColor) callconv(.c) ?*PixmanImage;
extern fn render_shim_image_unref(pix: *PixmanImage) callconv(.c) void;
extern fn render_shim_composite(
    src: ?*PixmanImage,
    mask: ?*PixmanImage,
    dest: *PixmanImage,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void;
extern fn render_shim_workers_lock(term: *Terminal) callconv(.c) void;
extern fn render_shim_workers_unlock(term: *Terminal) callconv(.c) void;

/// `struct fcft_glyph **` held in `term.custom_glyphs`.
fn optPix(p: ?*anyopaque) ?*PixmanImage {
    return if (p) |ptr| @ptrCast(ptr) else null;
}

fn glyphTable(ptr: *?*anyopaque) [*]?*FcftGlyph {
    return @ptrCast(@alignCast(ptr.* orelse @panic("glyph table not allocated")));
}

fn customGlyph(
    term: *Terminal,
    base: u32,
) struct { glyph: ?*FcftGlyph, cols: c_int } {
    var table: *?*anyopaque = undefined;
    var count: usize = undefined;
    var idx: usize = undefined;

    if (base >= GLYPH_LEGACY_FIRST) {
        table = &term.custom_glyphs.legacy;
        count = GLYPH_LEGACY_COUNT;
        idx = base - GLYPH_LEGACY_FIRST;
    } else if (base >= GLYPH_OCTANTS_FIRST) {
        table = &term.custom_glyphs.octants;
        count = GLYPH_OCTANTS_COUNT;
        idx = base - GLYPH_OCTANTS_FIRST;
    } else if (base >= GLYPH_BRAILLE_FIRST) {
        table = &term.custom_glyphs.braille;
        count = GLYPH_BRAILLE_COUNT;
        idx = base - GLYPH_BRAILLE_FIRST;
    } else {
        table = &term.custom_glyphs.box_drawing;
        count = GLYPH_BOX_DRAWING_COUNT;
        idx = base - GLYPH_BOX_DRAWING_FIRST;
    }

    if (table.* == null)
        table.* = xcalloc(count, @sizeOf(?*FcftGlyph));

    const glyphs = glyphTable(table);
    if (glyphs[idx] != null)
        return .{ .glyph = glyphs[idx], .cols = glyphs[idx].?.cols };

    render_shim_workers_lock(term);

    // Another thread may have instantiated it while we acquired the lock
    var single = glyphs[idx];
    if (single == null) {
        single = box_drawing(term, base);
        glyphs[idx] = single;
    }

    render_shim_workers_unlock(term);

    if (single == null)
        return .{ .glyph = null, .cols = 1 };

    return .{ .glyph = single, .cols = single.?.cols };
}

export fn render_cell(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    row: *types.Row,
    row_no: c_int,
    col: c_int,
    has_cursor: bool,
) callconv(.c) c_int {
    const cell = &row.cells.?[@intCast(col)];
    if (cell.attrs.clean)
        return 0;

    cell.attrs.clean = true;
    cell.attrs.confined = true;

    const width = term.cell_width;
    const height = term.cell_height;
    const x = term.margins.left + col * width;
    const y = term.margins.top + row_no * height;

    var _fg: u32 = 0;
    var _bg: u32 = 0;

    var alpha: u16 = 0xffff;
    const is_selected = cell.attrs.selected;

    // Use cell specific color, if set, otherwise the default colors
    // (possible reversed)
    switch (cell.attrs.fg_src) {
        COLOR_RGB => _fg = cell.attrs.fg,
        COLOR_BASE16, COLOR_BASE256 => {
            std.debug.assert(@as(usize, cell.attrs.fg) < term.colors.table.len);
            _fg = term.colors.table[cell.attrs.fg];
        },
        else => _fg = if (term.reverse) term.colors.bg else term.colors.fg,
    }

    switch (cell.attrs.bg_src) {
        COLOR_RGB => _bg = cell.attrs.bg,
        COLOR_BASE16, COLOR_BASE256 => {
            std.debug.assert(@as(usize, cell.attrs.bg) < term.colors.table.len);
            _bg = term.colors.table[cell.attrs.bg];
        },
        else => _bg = if (term.reverse) term.colors.fg else term.colors.bg,
    }

    if (is_selected) {
        const cell_fg = _fg;
        const cell_bg = _bg;

        const custom_fg = term.colors.selection_fg >> 24 == 0;
        const custom_bg = term.colors.selection_bg >> 24 == 0;
        const custom_both = custom_fg and custom_bg;

        if (custom_both) {
            _fg = term.colors.selection_fg;
            _bg = term.colors.selection_bg;
        } else if (custom_bg) {
            _bg = term.colors.selection_bg;
            _fg = if (cell.attrs.reverse) cell_bg else cell_fg;
        } else if (custom_fg) {
            _fg = term.colors.selection_fg;
            _bg = if (cell.attrs.reverse) cell_fg else cell_bg;
        } else {
            _bg = cell_fg;
            _fg = cell_bg;
        }

        if (_fg == _bg) {
            // Invert bg when selected/highlighted text has same fg/bg
            _bg = ~_bg;
            alpha = 0xffff;
        }
    } else {
        if (cell.attrs.reverse) {
            const swap = _fg;
            _fg = _bg;
            _bg = swap;
        } else if (!term.window.?.is_fullscreen and term.colors.alpha != 0xffff) {
            switch (term.conf.?.colors_dark.alpha_mode) {
                .default => {
                    if (cell.attrs.bg_src == COLOR_DEFAULT)
                        alpha = term.colors.alpha;
                },
                .matching => {
                    const bg_src = cell.attrs.bg_src;
                    if (bg_src == COLOR_DEFAULT or
                        ((bg_src == COLOR_BASE16 or bg_src == COLOR_BASE256) and
                            term.colors.table[cell.attrs.bg] == term.colors.bg) or
                        (bg_src == COLOR_RGB and cell.attrs.bg == term.colors.bg))
                    {
                        alpha = term.colors.alpha;
                    }
                },
                .all => alpha = term.colors.alpha,
            }

            // Disable transparency when fullscreened (see render_margin()).
            std.debug.assert(alpha == 0xffff);
        }
    }

    if (cell.attrs.dim)
        _fg = color_dim(term, _fg);
    if (term.conf.?.bold_in_bright.enabled and cell.attrs.bold)
        _fg = color_brighten(term, _fg);

    if (cell.attrs.blink and term.blink.state == .off)
        _fg = color_blend_towards(_fg, 0x00000000, term.conf.?.dim.amount);

    const gamma_correct = wayl_do_linear_blending(term.wl, term.conf.?);
    var fg = color_hex_to_pixman(_fg, gamma_correct);
    const bg = color_hex_to_pixman_with_alpha(_bg, alpha, gamma_correct);

    const font = attrs_to_font(term, &cell.attrs).?;
    var composed: ?*Composed = null;
    var grapheme: ?*const FcftGrapheme = null;
    var single: ?*FcftGlyph = null;
    var glyphs: []const ?*FcftGlyph = &.{};
    var glyph_count: c_int = 0;

    var base = cell.wc;
    var cell_cols: c_int = 1;

    const conf = term.conf.?;

    if (base != 0) {
        const is_custom_range =
            (base >= GLYPH_BOX_DRAWING_FIRST and base <= GLYPH_BOX_DRAWING_LAST) or
            (base >= GLYPH_BRAILLE_FIRST and base <= GLYPH_BRAILLE_LAST) or
            (base >= GLYPH_LEGACY_FIRST and base <= GLYPH_LEGACY_LAST) or
            (base >= GLYPH_OCTANTS_FIRST and base <= GLYPH_OCTANTS_LAST);

        if (is_custom_range and !conf.box_drawings_uses_font_glyphs) {
            const r = customGlyph(term, base);
            if (r.glyph) |g| {
                single = g;
                glyph_count = 1;
                glyphs = @as([*]const ?*FcftGlyph, @ptrCast(&single))[0..1];
                cell_cols = r.cols;
            }
        } else if (base >= CELL_COMB_CHARS_LO and base <= CELL_COMB_CHARS_HI) {
            const c = composed_lookup(term.composed, base - CELL_COMB_CHARS_LO).?;
            composed = c;
            base = c.chars.?[0];

            if (conf.can_shape_grapheme and conf.tweak.grapheme_shaping)
                grapheme = fcft_rasterize_grapheme_utf32(font, c.count, c.chars.?, term.font_subpixel);

            if (grapheme) |g| {
                const forced_width = c.forced_width;
                cell_cols = if (forced_width > 0) forced_width else g.cols;

                composed = null;
                glyphs = g.glyphs[0..g.count];
                glyph_count = @intCast(g.count);

                if (forced_width > 0)
                    glyph_count = @min(glyph_count, forced_width);
            }
        }

        if (single == null and grapheme == null) {
            if (base >= CELL_SPACER) {
                glyph_count = 0;
                cell_cols = 1;
            } else {
                std.debug.assert(base != 0);
                single = fcft_rasterize_char_utf32(font, base, term.font_subpixel);
                if (single == null) {
                    glyph_count = 0;
                    cell_cols = 1;
                } else {
                    glyph_count = 1;
                    glyphs = @as([*]const ?*FcftGlyph, @ptrCast(&single))[0..1];

                    const forced_width: u8 = if (composed) |c| c.forced_width else 0;
                    cell_cols = if (forced_width > 0) @intCast(forced_width) else single.?.cols;
                }
            }
        }
    }

    const cols_left = term.cols - col;
    cell_cols = @max(1, @min(cell_cols, cols_left));

    // Determine cells that will bleed into their right neighbor and remember
    // them for cleanup in the next frame.
    var render_width: c_int = cell_cols * width;
    if (conf.tweak.overflowing_glyphs and glyph_count > 0 and cols_left > cell_cols) {
        var glyph_width: c_int = 0;
        var advance: c_int = 0;
        for (glyphs) |maybe_g| {
            const g = maybe_g.?;
            glyph_width = @max(glyph_width, advance + g.x + g.width);
            advance += g.advance.x;
        }

        if (glyph_width > render_width) {
            render_width = @min(glyph_width, render_width + width);

            var i: c_int = 0;
            while (i < cell_cols) : (i += 1)
                row.cells.?[@intCast(col + i)].attrs.confined = false;
        }
    }

    render_shim_clip_rect(pix, x, y, render_width, height);

    if (damage) |d|
        render_shim_region_union_rect(d, x, y, render_width, height);

    // Background
    fillRect(pix, &bg, &.{.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(cell_cols * width),
        .height = @intCast(height),
    }});

    if (cell.attrs.blink and term.blink.fd < 0) {
        // TODO: use a custom lock for this?
        render_shim_workers_lock(term);
        term_arm_blink_timer(term);
        render_shim_workers_unlock(term);
    }

    var early_cursor = false;

    if (has_cursor and term.cursor_style == .block and term.kbd_focus) {
        const bg_without_alpha = color_hex_to_pixman(_bg, gamma_correct);
        draw_cursor(term, cell, font, pix, &fg, &bg_without_alpha, x, y, cell_cols);
    }

    if (cell.wc == 0 or cell.wc >= CELL_SPACER or cell.wc == '\t' or
        (cell.attrs.conceal and !is_selected))
    {
        early_cursor = true;
    }

    if (!early_cursor) {
        const clr_pix = render_shim_solid_fill(&fg).?;
        var pen_x = x;
        const cell_width = term.cell_width;

        var i: usize = 0;
        while (i < @as(usize, @intCast(glyph_count))) : (i += 1) {
            const letter_x_ofs: c_int = if (i == 0) @as(c_int, term.font_x_ofs) else 0;

            const glyph = glyphs[i] orelse continue;

            var g_x = glyph.x;
            const g_y = glyph.y;

            if (i > 0 and glyph.x >= 0 and cell_cols == 1)
                g_x -= cell_width;

            if (glyph.is_color_glyph) {
                // Glyph surface is a pre-rendered image (typically colour emoji)
                if (!(cell.attrs.blink and term.blink.state == .off)) {
                    render_shim_composite(
                        optPix(glyph.pix), null, pix,
                        pen_x + letter_x_ofs + g_x,
                        y + @as(c_int, term.font_baseline) - g_y,
                        glyph.width, glyph.height);
                }
            } else {
                render_shim_composite(
                    clr_pix, optPix(glyph.pix), pix,
                    pen_x + letter_x_ofs + g_x,
                    y + @as(c_int, term.font_baseline) - g_y,
                    glyph.width, glyph.height);

                // Combining characters
                if (composed) |c| {
                    std.debug.assert(glyph_count == 1);

                    var j: usize = 1;
                    while (j < c.count) : (j += 1) {
                        const g = fcft_rasterize_char_utf32(font, c.chars.?[j], term.font_subpixel) orelse continue;

                        // Fonts _should_ assume the pen position is now
                        // *after* the base glyph, and thus use negative
                        // offsets for combining glyphs; accommodate both.
                        const x_ofs: c_int = if (cell_cols == 1)
                            (if (g.x < 0) cell_cols * cell_width else (cell_cols - 1) * cell_width)
                        else
                            0;

                        if (cell_cols > 1)
                            pen_x += cell_width;

                        render_shim_composite(
                            clr_pix, optPix(g.pix), pix,
                            pen_x + letter_x_ofs + x_ofs + g.x,
                            y + @as(c_int, term.font_baseline) - g.y,
                            g.width, g.height);
                    }
                }
            }

            pen_x += if (cell_cols > 1) cell_width else glyph.advance.x;
        }

        render_shim_image_unref(clr_pix);

        // Underline
        if (cell.attrs.underline) {
            var underline_color = fg;
            var underline_style: UnderlineStyle = .single;

            // Check if cell has a styled underline. This lookup is fairly
            // expensive...
            if (row.extra) |extra| {
                const ranges = extra.underline_ranges;
                if (ranges.v) |v| {
                    var ri: usize = 0;
                    while (ri < @as(usize, @intCast(ranges.count))) : (ri += 1) {
                        const range = &v[ri];

                        if (range.start > col)
                            break;

                        if (range.start <= col and col <= range.end) {
                            switch (range.data.underline.color_src) {
                                .base256 => underline_color = color_hex_to_pixman(
                                    term.colors.table[range.data.underline.color], gamma_correct),
                                .rgb => underline_color = color_hex_to_pixman(
                                    range.data.underline.color, gamma_correct),
                                .default => {},
                                .base16 => unreachable, // underline color can't be base-16
                            }

                            underline_style = range.data.underline.style;
                            break;
                        }
                    }
                }
            }

            draw_styled_underline(term, pix, font, &underline_color, underline_style, x, y, cell_cols);
        }

        if (cell.attrs.strikethrough)
            draw_strikeout(term, pix, font, &fg, x, y, cell_cols);

        if (cell.attrs.url and conf.url.style != .none) {
            const url_color = color_hex_to_pixman(
                if (conf.colors_dark.use_custom.url)
                    conf.colors_dark.url
                else
                    term.colors.table[3],
                gamma_correct);

            draw_styled_underline(term, pix, font, &url_color, conf.url.style, x, y, cell_cols);
        }
    }

    if (has_cursor and (term.cursor_style != .block or !term.kbd_focus)) {
        const bg_without_alpha = color_hex_to_pixman(_bg, gamma_correct);
        draw_cursor(term, cell, font, pix, &fg, &bg_without_alpha, x, y, cell_cols);
    }

    render_shim_clip_clear(pix);
    return cell_cols;
}

// ─────────────────────────────────────────────────────────────────────────
// Scroll damage (D3f)
// ─────────────────────────────────────────────────────────────────────────

const Damage = types.Damage;

extern fn shm_can_scroll(buf: *const Buffer) callconv(.c) bool;
extern fn shm_scroll(
    buf: *Buffer,
    rows: c_int,
    top_margin: c_int,
    top_keep_rows: c_int,
    bottom_margin: c_int,
    bottom_keep_rows: c_int,
) callconv(.c) bool;

export fn grid_render_scroll(term: *Terminal, buf: *Buffer, dmg: *const Damage) callconv(.c) void {
    const region_size: c_int = dmg.region.end - dmg.region.start;

    if (dmg.lines >= region_size) {
        // The entire scroll region will be scrolled out (i.e. replaced)
        return;
    }

    const height: c_int = (region_size - dmg.lines) * term.cell_height;
    std.debug.assert(height > 0);

    const dst_y = term.margins.top + (dmg.region.start + 0) * term.cell_height;
    const src_y = term.margins.top + (dmg.region.start + dmg.lines) * term.cell_height;

    // SHM scrolling needs to first "move" (punch hole + allocate)
    // dmg->lines number of lines, and then we need to restore the bottom
    // scroll region. If the total number of lines is less than half the
    // screen - use SHM. Otherwise use memmove.
    const try_shm_scroll = shm_can_scroll(buf) and
        (dmg.lines + dmg.region.start + (term.rows - dmg.region.end)) < @divTrunc(term.rows, 2);

    var did_shm_scroll = false;

    if (try_shm_scroll) {
        did_shm_scroll = shm_scroll(
            buf,
            @as(c_int, dmg.lines) * term.cell_height,
            term.margins.top,
            dmg.region.start * term.cell_height,
            term.margins.bottom,
            (term.rows - dmg.region.end) * term.cell_height,
        );
    }

    if (did_shm_scroll) {
        // Restore margins
        render_margin(term, buf, dmg.region.end - dmg.lines, term.rows, false);
    } else {
        // Fallback for when we either cannot do SHM scrolling, or it failed
        const raw: [*]u8 = @ptrCast(buf.data.?);
        const stride: usize = @intCast(buf.stride);
        const len: usize = @as(usize, @intCast(height)) * stride;
        const dst = raw + @as(usize, @intCast(dst_y)) * stride;
        const src = raw + @as(usize, @intCast(src_y)) * stride;
        std.mem.copyForwards(u8, dst[0..len], src[0..len]);
    }

    wayland_shim_surface_damage_buffer(
        term.window.?.surface.surf,
        term.margins.left,
        dst_y,
        term.width - term.margins.left - term.margins.right,
        height,
    );

    // TODO: remove this if re-enabling scroll damage when re-applying last
    // frame's damage (see reapply_old_damage())
    render_shim_region_union_rect(buf.dirty, 0, dst_y, buf.width, height);
}

export fn grid_render_scroll_reverse(term: *Terminal, buf: *Buffer, dmg: *const Damage) callconv(.c) void {
    const region_size: c_int = dmg.region.end - dmg.region.start;

    if (dmg.lines >= region_size) {
        // The entire scroll region will be scrolled out (i.e. replaced)
        return;
    }

    const height: c_int = (region_size - dmg.lines) * term.cell_height;
    std.debug.assert(height > 0);

    const src_y = term.margins.top + (dmg.region.start + 0) * term.cell_height;
    const dst_y = term.margins.top + (dmg.region.start + dmg.lines) * term.cell_height;

    const try_shm_scroll = shm_can_scroll(buf) and
        (dmg.lines + dmg.region.start + (term.rows - dmg.region.end)) < @divTrunc(term.rows, 2);

    var did_shm_scroll = false;

    if (try_shm_scroll) {
        did_shm_scroll = shm_scroll(
            buf,
            -@as(c_int, dmg.lines) * term.cell_height,
            term.margins.top,
            dmg.region.start * term.cell_height,
            term.margins.bottom,
            (term.rows - dmg.region.end) * term.cell_height,
        );
    }

    if (did_shm_scroll) {
        // Restore margins
        render_margin(term, buf, dmg.region.start, dmg.region.start + dmg.lines, false);
    } else {
        // Fallback for when we either cannot do SHM scrolling, or it failed
        const raw: [*]u8 = @ptrCast(buf.data.?);
        const stride: usize = @intCast(buf.stride);
        const len: usize = @as(usize, @intCast(height)) * stride;
        const dst = raw + @as(usize, @intCast(dst_y)) * stride;
        const src = raw + @as(usize, @intCast(src_y)) * stride;
        // Reverse scrolling copies upwards, so the regions overlap the other
        // way round: use memmove semantics.
        std.mem.copyBackwards(u8, dst[0..len], src[0..len]);
    }

    wayland_shim_surface_damage_buffer(
        term.window.?.surface.surf,
        term.margins.left,
        dst_y,
        term.width - term.margins.left - term.margins.right,
        height,
    );

    render_shim_region_union_rect(buf.dirty, 0, dst_y, buf.width, height);
}

// ─────────────────────────────────────────────────────────────────────────
// Sixel painting (D3g)
// ─────────────────────────────────────────────────────────────────────────

const Sixel = types.Sixel;
const SixelList = tll.Tll(Sixel);

extern fn sixel_sync_cache(term: *const Terminal, six: *Sixel) callconv(.c) void;
extern fn render_shim_composite_op(
    op: c_int,
    src: ?*PixmanImage,
    mask: ?*PixmanImage,
    dest: *PixmanImage,
    src_x: c_int,
    src_y: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void;

fn renderSixelChunk(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    sixel: *const Sixel,
    term_start_row: c_int,
    img_start_row: c_int,
    count: c_int,
) void {
    // Translate row/column to x/y pixel values
    const x = term.margins.left + sixel.pos.col * term.cell_width;
    const y = term.margins.top + term_start_row * term.cell_height;

    // Width/height, in pixels - and don't touch the window margins
    const width = @max(0, @min(sixel.width, term.width - x - term.margins.right));
    const height = @max(0, @min(
        @min(count * term.cell_height, sixel.height - img_start_row * term.cell_height),
        term.height - y - term.margins.bottom,
    ));

    // Verify we're not stepping outside the grid
    std.debug.assert(x >= term.margins.left);
    std.debug.assert(y >= term.margins.top);
    std.debug.assert(width == 0 or x + width <= term.width - term.margins.right);
    std.debug.assert(height == 0 or y + height <= term.height - term.margins.bottom);

    render_shim_composite_op(
        if (sixel.@"opaque") 0x01 else 0x03, // PIXMAN_OP_SRC : PIXMAN_OP_OVER
        optPix(sixel.pix),
        null,
        pix,
        0, img_start_row * term.cell_height,
        x, y,
        width, height,
    );

    if (damage) |d|
        render_shim_region_union_rect(d, x, y, width, height);
}

fn renderSixel(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    cursor: *const types.Coord,
    sixel: *const Sixel,
) void {
    std.debug.assert(sixel.pix != null);
    std.debug.assert(sixel.width >= 0);
    std.debug.assert(sixel.height >= 0);

    const grid = term.grid.?;
    const view_end = (grid.view + term.rows - 1) & (grid.num_rows - 1);
    const last_row_needs_erase = @rem(sixel.height, term.cell_height) != 0;
    const last_col_needs_erase = @rem(sixel.width, term.cell_width) != 0;

    var chunk_img_start: c_int = -1; // Image-relative start row of chunk
    var chunk_term_start: c_int = -1; // Viewport relative start row of chunk
    var chunk_row_count: c_int = 0; // Number of rows to emit

    // Iterate all sixel rows:
    //  - ignore rows that aren't visible on-screen
    //  - ignore rows that aren't dirty (they have already been rendered)
    //  - chunk consecutive dirty rows into a 'chunk'
    //  - emit (render) chunk as soon as a row isn't visible, or is clean
    //  - emit final chunk after we've iterated all rows
    var _abs_row_no = sixel.pos.row;
    while (_abs_row_no < sixel.pos.row + sixel.rows) : (_abs_row_no += 1) {
        const abs_row_no = _abs_row_no & (grid.num_rows - 1);
        const term_row_no =
            (abs_row_no - grid.view + grid.num_rows) & (grid.num_rows - 1);

        // Check if row is in the visible viewport
        const visible = if (view_end >= grid.view)
            // Not wrapped
            abs_row_no >= grid.view and abs_row_no <= view_end
        else
            // Wrapped
            abs_row_no >= grid.view or abs_row_no <= view_end;

        if (!visible) {
            if (chunk_row_count != 0) {
                renderSixelChunk(term, pix, damage, sixel, chunk_term_start, chunk_img_start, chunk_row_count);
                chunk_term_start = -1;
                chunk_img_start = -1;
                chunk_row_count = 0;
            }
            continue;
        }

        // Is the row dirty?
        const row = grid.rows.?[@intCast(abs_row_no)] orelse unreachable;

        if (!row.dirty) {
            if (chunk_row_count != 0) {
                renderSixelChunk(term, pix, damage, sixel, chunk_term_start, chunk_img_start, chunk_row_count);
                chunk_term_start = -1;
                chunk_img_start = -1;
                chunk_row_count = 0;
            }
            continue;
        }

        const cursor_col: c_int = if (cursor.row == term_row_no) cursor.col else -1;

        // If image contains transparent parts, render all (dirty) cells
        // beneath it. If image is opaque, loop cells and set their 'clean'
        // bit, to prevent the grid renderer from overwriting the sixel. If
        // the last sixel row only partially covers the cell row, 'erase' the
        // cell by rendering it.
        if (!sixel.@"opaque") {
            // TODO: multithreading
            render_row(term, pix, damage, row, term_row_no, cursor_col);
        } else {
            const cells = row.cells.?;
            var col = sixel.pos.col;
            const end = @min(sixel.pos.col + sixel.cols, term.cols);
            while (col < end) : (col += 1) {
                const cell = &cells[@intCast(col)];

                if (!cell.attrs.clean) {
                    const last_row = abs_row_no == sixel.pos.row + sixel.rows - 1;
                    const last_col = col == sixel.pos.col + sixel.cols - 1;

                    if ((last_row_needs_erase and last_row) or
                        (last_col_needs_erase and last_col))
                    {
                        _ = render_cell(term, pix, damage, row, term_row_no, col, cursor_col == col);
                    } else {
                        cell.attrs.clean = true;
                        cell.attrs.confined = true;
                    }
                }
            }
        }

        if (chunk_term_start == -1) {
            std.debug.assert(chunk_img_start == -1);
            chunk_term_start = term_row_no;
            chunk_img_start = _abs_row_no - sixel.pos.row;
            chunk_row_count = 1;
        } else {
            chunk_row_count += 1;
        }
    }

    if (chunk_row_count != 0)
        renderSixelChunk(term, pix, damage, sixel, chunk_term_start, chunk_img_start, chunk_row_count);
}

export fn render_sixel_images(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    cursor: *const types.Coord,
) callconv(.c) void {
    const grid = term.grid.?;
    const sixels: *SixelList = @ptrCast(&grid.sixel_images);

    if (sixels.len() == 0)
        return;

    const scrollback_end = (grid.offset + term.rows) & (grid.num_rows - 1);
    const view_start = (grid.view - scrollback_end + grid.num_rows) & (grid.num_rows - 1);
    const view_end = view_start + term.rows - 1;

    var it = sixels.foreach();
    while (it.next()) |node| {
        const six = &node.item;
        const start = (six.pos.row - scrollback_end + grid.num_rows) & (grid.num_rows - 1);
        const end = start + six.rows - 1;

        if (start > view_end) {
            // Sixel starts after view ends, no need to try to render it
            continue;
        } else if (end < view_start) {
            // Image ends before view starts. Since the image list is sorted,
            // we can safely stop here
            break;
        }

        sixel_sync_cache(term, &node.item);
        renderSixel(term, pix, damage, cursor, &node.item);
    }
}
