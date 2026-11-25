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

export fn attrs_to_font(term: *const Terminal, attrs: *const Attributes) callconv(.c) ?*FcftFont {
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

extern fn render_cell(
    term: *Terminal,
    pix: *PixmanImage,
    damage: ?*anyopaque,
    row: *types.Row,
    row_no: c_int,
    col: c_int,
    has_cursor: bool,
) callconv(.c) c_int;
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
