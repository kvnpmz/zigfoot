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

// C-ABI mirrors now live in terminal_types.zig, where the generated ABI
// probe checks them. Keep the local names as aliases for callers.
pub const PixmanColor = types.PixmanColor;
pub const PixmanRectangle16 = types.PixmanRectangle16;

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

const PIXMAN_a8: u32 = 0x08018000;

extern fn pixman_composite_trapezoids(
    op: c_int,
    src: ?*PixmanImage,
    dst: *PixmanImage,
    mask_format: u32,
    x_src: c_int,
    y_src: c_int,
    x_dst: c_int,
    y_dst: c_int,
    n_traps: c_int,
    traps: [*]const types.PixmanTrapezoid,
) callconv(.c) void;

fn curlyUnderline(
    pix: *PixmanImage,
    color: *const PixmanColor,
    x: c_int,
    top: c_int,
    bot: c_int,
    half_x: c_int,
    full_x: c_int,
    th: c_int,
) void {
    const I = pixmanIntToFixed;
    // Characters sit on top of the curlies.
    const traps = [2]types.PixmanTrapezoid{
        .{
            .top = I(top),
            .bottom = I(bot),
            .left = .{ .p1 = .{ .x = I(x), .y = I(bot - th) }, .p2 = .{ .x = I(half_x), .y = I(top - th) } },
            .right = .{ .p1 = .{ .x = I(x), .y = I(bot + th) }, .p2 = .{ .x = I(half_x), .y = I(top + th) } },
        },
        .{
            .top = I(top),
            .bottom = I(bot),
            .left = .{ .p1 = .{ .x = I(half_x), .y = I(top + th) }, .p2 = .{ .x = I(full_x), .y = I(bot + th) } },
            .right = .{ .p1 = .{ .x = I(half_x), .y = I(top - th) }, .p2 = .{ .x = I(full_x), .y = I(bot - th) } },
        },
    };

    const fill = pixman_image_create_solid_fill(color);
    pixman_composite_trapezoids(PIXMAN_OP_OVER, fill, pix, PIXMAN_a8, 0, 0, 0, 0, 2, &traps);
    pixman_image_unref(fill);
}

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
    _ = pixman_image_fill_rectangles(PIXMAN_OP_SRC, pix, color, @intCast(rects.len), rects.ptr);
}

// ─────────────────────────────────────────────────────────────────────────
// Colour helpers
// ─────────────────────────────────────────────────────────────────────────

export fn attrs_to_font(term: *const Terminal, attrs: *align(4) const Attributes) callconv(.c) ?*FcftFont {
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

// enum in terminal.h: CURSOR_BLINK_ON is the zero value.
const CURSOR_BLINK_ON: c_int = 0;

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

            // C advances by thickness + spacing[i], where spacing starts
            // at thickness. The closed form therefore needs twice the
            // thickness before distributing the remainder.
            const base = thickness * 2 + extra;

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

            curlyUnderline(pix, color, x, top, bot, half_x, full_x, th);
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
            if (term.cursor_blink.state == CURSOR_BLINK_ON or !term.kbd_focus) {
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
            if (term.cursor_blink.state == CURSOR_BLINK_ON or !term.kbd_focus)
                draw_beam_cursor(term, pix, font, &cursor_color, x, y);
        },

        .underline => {
            if (term.cursor_blink.state == CURSOR_BLINK_ON or !term.kbd_focus)
                draw_underline_cursor(term, pix, font, &cursor_color, x, y, cols);
        },

        .hollow => {
            if (term.cursor_blink.state == CURSOR_BLINK_ON)
                draw_hollow_block(term, pix, &cursor_color, x, y, cols);
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Cursor dirtiness and the refresh flags (D3b)
// ─────────────────────────────────────────────────────────────────────────

// Aliases: terminal_types.zig owns the probed C mirrors.
pub const Timespec = types.Timespec;
const Itimerspec = types.Itimerspec;

const CLOCK_MONOTONIC: c_int = 1;
const LOG_CLASS_DEBUG: c_int = 4;

extern fn clock_gettime(clockid: c_int, tp: *Timespec) callconv(.c) c_int;
extern fn timerfd_settime(fd: c_int, flags: c_int, new: *const Itimerspec, old: ?*Itimerspec) callconv(.c) c_int;
extern fn timespec_sub(a: *const Timespec, b: *const Timespec, res: *Timespec) callconv(.c) void;
extern fn terminal_shim_grid_row(grid: *types.Grid, row_no: c_int) callconv(.c) *types.Row;
extern fn terminal_shim_urls_mode_active(term: *const Terminal) callconv(.c) bool;
extern fn term_icon(term: *const Terminal) callconv(.c) [*:0]const u8;
extern fn wayland_shim_xdg_toplevel_set_app_id(toplevel: ?*anyopaque, app_id: [*:0]const u8) callconv(.c) void;
extern fn wayland_shim_toplevel_icon_set(m: ?*anyopaque, toplevel: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;
extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

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

    // Same guard as render_update_title(): C dereferences unconditionally, and
    // the rate limiter can expire under valgrind, so the harness's bare window
    // reached wl_proxy_get_version(NULL) here (harness SIGSEGV, V-01 family).
    const window = term.window orelse return;
    const toplevel = window.xdg_toplevel orelse return;

    wayland_shim_xdg_toplevel_set_app_id(toplevel, app_id);
}

export fn render_refresh_icon(term: *Terminal) callconv(.c) void {
    if (term.wl.?.toplevel_icon_manager == null) {
        log_msg(
            LOG_CLASS_DEBUG,
            "render",
            "render.zig",
            @intCast(@src().line),
            "compositor does not implement xdg-toplevel-icon: " ++
                "ignoring request to refresh window icon",
        );
        return;
    }

    if (!rateLimit(lastUpdate(&term.render.icon.last_update), term.render.icon.timer_fd))
        return;

    const icon_name = term_icon(term);
    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "setting toplevel icon: %s", icon_name);

    wayland_shim_toplevel_icon_set(term.wl.?.toplevel_icon_manager, term.window.?.xdg_toplevel, icon_name);
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
        wayland_shim_surface_damage_buffer(surf, 0, term.margins.top + start_line * term.cell_height, term.margins.left, line_count * term.cell_height);
        // Right
        wayland_shim_surface_damage_buffer(surf, rmargin, term.margins.top + start_line * term.cell_height, term.margins.right, line_count * term.cell_height);
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
    color: *const PixmanColor,
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

fn clipRect(pix: *PixmanImage, x: c_int, y: c_int, width: c_int, height: c_int) void {
    var clip: Region32 = undefined;
    render_shim_region_init_rect(regionPtr(&clip), x, y, width, height);
    render_shim_set_clip_region(pix, regionPtr(&clip));
    render_shim_region_fini(regionPtr(&clip));
}
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

    clipRect(pix, x, y, render_width, height);

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
                    render_shim_composite(optPix(glyph.pix), null, pix, pen_x + letter_x_ofs + g_x, y + @as(c_int, term.font_baseline) - g_y, glyph.width, glyph.height);
                }
            } else {
                render_shim_composite(clr_pix, optPix(glyph.pix), pix, pen_x + letter_x_ofs + g_x, y + @as(c_int, term.font_baseline) - g_y, glyph.width, glyph.height);

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

                        render_shim_composite(clr_pix, optPix(g.pix), pix, pen_x + letter_x_ofs + x_ofs + g.x, y + @as(c_int, term.font_baseline) - g.y, g.width, g.height);
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
                                .base256 => underline_color = color_hex_to_pixman(term.colors.table[range.data.underline.color], gamma_correct),
                                .rgb => underline_color = color_hex_to_pixman(range.data.underline.color, gamma_correct),
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
            const url_color = color_hex_to_pixman(if (conf.colors_dark.use_custom.url)
                conf.colors_dark.url
            else
                term.colors.table[3], gamma_correct);

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
        0,
        img_start_row * term.cell_height,
        x,
        y,
        width,
        height,
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

// ─────────────────────────────────────────────────────────────────────────
// CSD buttons (D3h)
// ─────────────────────────────────────────────────────────────────────────

const SeatList = tll.Tll(types.Seat);

const PIXMAN_OP_OVER: c_int = 3;
const PIXMAN_a1: u32 = 0x01011000;

extern fn pixman_image_create_solid_fill(color: *const PixmanColor) callconv(.c) ?*PixmanImage;
extern fn pixman_image_unref(image: ?*PixmanImage) callconv(.c) void;
extern fn pixman_composite_triangles(
    op: c_int,
    src: ?*PixmanImage,
    dst: *PixmanImage,
    mask_format: u32,
    x_src: c_int,
    y_src: c_int,
    x_dst: c_int,
    y_dst: c_int,
    n_tris: c_int,
    tris: [*]const types.PixmanTriangle,
) callconv(.c) void;

fn pixmanIntToFixed(x: c_int) i32 {
    // pixman_int_to_fixed() is a C multiply that can overflow; wrapping
    // retains the machine result for that UB case and is exact in range.
    return x *% 65536;
}

fn closeButton(
    pix: *PixmanImage,
    color: *const PixmanColor,
    x_margin: c_int,
    y_margin: c_int,
    width: c_int,
    thick: c_int,
) void {
    const I = pixmanIntToFixed;
    const tri = [4]types.PixmanTriangle{
        .{
            .p1 = .{ .x = I(x_margin), .y = I(y_margin + thick) },
            .p2 = .{ .x = I(x_margin + width - thick), .y = I(y_margin + width) },
            .p3 = .{ .x = I(x_margin + thick), .y = I(y_margin) },
        },
        .{
            .p1 = .{ .x = I(x_margin + width), .y = I(y_margin + width - thick) },
            .p2 = .{ .x = I(x_margin + thick), .y = I(y_margin) },
            .p3 = .{ .x = I(x_margin + width - thick), .y = I(y_margin + width) },
        },
        .{
            .p1 = .{ .x = I(x_margin), .y = I(y_margin + width - thick) },
            .p2 = .{ .x = I(x_margin + width), .y = I(y_margin + thick) },
            .p3 = .{ .x = I(x_margin + thick), .y = I(y_margin + width) },
        },
        .{
            .p1 = .{ .x = I(x_margin + width), .y = I(y_margin + thick) },
            .p2 = .{ .x = I(x_margin), .y = I(y_margin + width - thick) },
            .p3 = .{ .x = I(x_margin + width - thick), .y = I(y_margin) },
        },
    };

    const src = pixman_image_create_solid_fill(color);
    pixman_composite_triangles(PIXMAN_OP_OVER, src, pix, PIXMAN_a1, 0, 0, 0, 0, 4, &tri);
    pixman_image_unref(src);
}

fn getCsdButtonFgColor(term: *const Terminal) PixmanColor {
    const conf = term.conf.?;
    var _color = conf.colors_dark.bg;
    var alpha: u16 = 0xffff;

    if (conf.csd.color._flags.buttons_set) {
        _color = conf.csd.color.buttons;
        alpha = @truncate((_color >> 24) | (_color >> 24 << 8));
    }

    return color_hex_to_pixman_with_alpha(_color, alpha, wayl_do_linear_blending(term.wl, conf));
}

/// Shared geometry: the button glyph is a square of at most a third of the
/// buffer, inset by `width/2` (or one scaled pixel) thickness.
const ButtonGeom = struct {
    width: c_int,
    thick: c_int,
    x_margin: c_int,
    y_margin: c_int,
};

fn buttonGeom(term: *const Terminal, buf: *const Buffer) ButtonGeom {
    const max_height = @divTrunc(buf.height, 3);
    const max_width = @divTrunc(buf.width, 3);

    const width = @min(max_height, max_width);
    const thick: c_int = @intFromFloat(@min(
        @as(f32, @floatFromInt(@divTrunc(width, 2))),
        1 * term.scale,
    ));

    const x_margin = @divTrunc(buf.width - width, 2);
    const y_margin = @divTrunc(buf.height - width, 2);

    std.debug.assert(x_margin + width - thick >= 0);
    std.debug.assert(width - 2 * thick >= 0);
    std.debug.assert(y_margin + width - thick >= 0);

    return .{ .width = width, .thick = thick, .x_margin = x_margin, .y_margin = y_margin };
}

export fn render_csd_button_minimize(term: *Terminal, buf: *Buffer) callconv(.c) void {
    const color = getCsdButtonFgColor(term);
    const g = buttonGeom(term, buf);
    const x = g.x_margin;
    const y = g.y_margin + g.width - g.thick;

    fillRect(bufferPix(buf), &color, &.{.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(g.width),
        .height = @intCast(g.thick),
    }});
}

export fn render_csd_button_maximize_maximized(term: *Terminal, buf: *Buffer) callconv(.c) void {
    const color = getCsdButtonFgColor(term);
    const g = buttonGeom(term, buf);
    const shrink: c_int = 1;
    const x = g.x_margin;
    const y = g.y_margin;
    const w = g.width;
    const t = g.thick;

    const inner: u16 = @intCast(w - 2 * t - shrink);

    fillRect(bufferPix(buf), &color, &.{
        .{ .x = @intCast(x + shrink), .y = @intCast(y + shrink), .width = @intCast(w - 2 * shrink), .height = @intCast(t) },
        .{ .x = @intCast(x + shrink), .y = @intCast(y + t), .width = @intCast(t), .height = inner },
        .{ .x = @intCast(x + w - t - shrink), .y = @intCast(y + t), .width = @intCast(t), .height = inner },
        .{ .x = @intCast(x + shrink), .y = @intCast(y + w - t - shrink), .width = @intCast(w - 2 * shrink), .height = @intCast(t) },
    });
}

export fn render_csd_button_maximize_window(term: *Terminal, buf: *Buffer) callconv(.c) void {
    const color = getCsdButtonFgColor(term);
    const g = buttonGeom(term, buf);
    const x = g.x_margin;
    const y = g.y_margin;
    const w = g.width;
    const t = g.thick;

    const inner: u16 = @intCast(w - 2 * t);

    fillRect(bufferPix(buf), &color, &.{
        .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(w), .height = @intCast(t) },
        .{ .x = @intCast(x), .y = @intCast(y + t), .width = @intCast(t), .height = inner },
        .{ .x = @intCast(x + w - t), .y = @intCast(y + t), .width = @intCast(t), .height = inner },
        .{ .x = @intCast(x), .y = @intCast(y + w - t), .width = @intCast(w), .height = @intCast(t) },
    });
}

export fn render_csd_button_maximize(term: *Terminal, buf: *Buffer) callconv(.c) void {
    if (term.window.?.is_maximized)
        render_csd_button_maximize_maximized(term, buf)
    else
        render_csd_button_maximize_window(term, buf);
}

export fn render_csd_button_close(term: *Terminal, buf: *Buffer) callconv(.c) void {
    const color = getCsdButtonFgColor(term);
    const g = buttonGeom(term, buf);

    closeButton(bufferPix(buf), &color, g.x_margin, g.y_margin, g.width, g.thick);
}

export fn any_pointer_is_on_button(term: *const Terminal, csd_surface: types.CsdSurface) callconv(.c) bool {
    const seats: *SeatList = @ptrCast(&term.wl.?.seats);

    if (seats.len() == 0)
        return false;

    var it = seats.foreach();
    while (it.next()) |node| {
        const seat = &node.item;

        if (seat.mouse.x < 0)
            continue;
        if (seat.mouse.y < 0)
            continue;

        const info = get_csd_data(term, csd_surface);
        if (seat.mouse.x > info.width)
            continue;

        if (seat.mouse.y > info.height)
            continue;
        return true;
    }

    return false;
}

// ─────────────────────────────────────────────────────────────────────────
// CSD borders, buttons and title (D3i)
// ─────────────────────────────────────────────────────────────────────────

extern fn ambstoc32(src: ?[*:0]const u8) callconv(.c) ?[*]u32;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn shm_get_many(
    chain: *types.ShmBufferChain,
    count: usize,
    widths: [*]c_int,
    heights: [*]c_int,
    bufs: [*]?*Buffer,
) callconv(.c) void;
extern fn wayland_shim_subsurface_set_position(sub: ?*anyopaque, x: c_int, y: c_int) callconv(.c) void;
extern fn render_shim_fcft_font_max_advance_x(font: *const FcftFont) callconv(.c) c_int;

const empty_wtext = [_:0]u32{0};

export fn render_csd_title(term: *Terminal, info: *const CsdData, buf: *Buffer) callconv(.c) void {
    const win = term.window.?;
    std.debug.assert(win.csd_mode == .yes);

    const surf = &win.csd.surface[@intFromEnum(types.CsdSurface.title)];
    if (info.width == 0 or info.height == 0)
        return;

    const conf = term.conf.?;

    var bg: u32 = if (conf.csd.color._flags.title_set)
        conf.csd.color.title
    else
        (@as(u32, 0xff) << 24) | conf.colors_dark.fg;
    var fg: u32 = if (conf.csd.color._flags.buttons_set)
        conf.csd.color.buttons
    else
        conf.colors_dark.bg;

    if (!term.visual_focus) {
        bg = color_dim(term, bg);
        fg = color_dim(term, fg);
    }

    const _title_text = ambstoc32(@ptrCast(term.window_title));
    const title_text: [*]const u32 = if (_title_text) |t| t else &empty_wtext;

    const font = win.csd.font;
    var margin: c_int = 0;
    if (font) |f| {
        const M = fcft_rasterize_char_utf32(f, 'M', term.font_subpixel);
        margin = if (M) |m| m.advance.x else render_shim_fcft_font_max_advance_x(f);
    }

    render_osd(term, surf, font, buf, title_text, fg, bg, @intCast(margin));
    csd_commit(term, &surf.surface, buf);

    if (_title_text) |t| free(@ptrCast(t));
}

export fn render_csd_border(term: *Terminal, surf_idx: types.CsdSurface, info: *const CsdData, buf: *Buffer) callconv(.c) void {
    const win = term.window.?;
    std.debug.assert(win.csd_mode == .yes);
    std.debug.assert(@intFromEnum(surf_idx) >= @intFromEnum(types.CsdSurface.left) and
        @intFromEnum(surf_idx) <= @intFromEnum(types.CsdSurface.bottom));

    const surf = &win.csd.surface[@intCast(@intFromEnum(surf_idx))].surface;

    if (info.width == 0 or info.height == 0)
        return;

    const conf = term.conf.?;
    const gamma_correct = wayl_do_linear_blending(term.wl, conf);

    {
        // Fully transparent - no need to do a color space transform
        const color = color_hex_to_pixman_with_alpha(0, 0, gamma_correct);
        render_csd_part(term, surf.surf, buf, info.width, info.height, &color);
    }

    // The "visible" border.
    const scale = term.scale;
    const bwidth = roundf(conf.csd.border_width * scale);
    const vwidth = roundf(conf.csd.border_width_visible * scale); // Visible size

    std.debug.assert(bwidth >= vwidth);

    const pix = bufferPix(buf);

    if (vwidth > 0) {
        var x: c_int = 0;
        var y: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;

        switch (surf_idx) {
            .top, .bottom => {
                x = bwidth - vwidth;
                y = if (surf_idx == .top) info.height - vwidth else 0;
                w = info.width - 2 * x;
                h = vwidth;
            },
            .left, .right => {
                x = if (surf_idx == .left) bwidth - vwidth else 0;
                y = 0;
                w = vwidth;
                h = info.height;
            },
            else => unreachable, // unexpected CSD surface type
        }

        std.debug.assert(x >= 0);
        std.debug.assert(y >= 0);
        std.debug.assert(w >= 0);
        std.debug.assert(h >= 0);

        std.debug.assert(x + w <= info.width);
        std.debug.assert(y + h <= info.height);

        var _color: u32 = if (conf.csd.color._flags.border_set)
            conf.csd.color.border
        else if (conf.csd.color._flags.title_set)
            conf.csd.color.title
        else
            (@as(u32, 0xff) << 24) | conf.colors_dark.fg;

        if (!term.visual_focus)
            _color = color_dim(term, _color);

        const alpha: u16 = @truncate((_color >> 24) | (_color >> 24 << 8));
        const color = color_hex_to_pixman_with_alpha(_color, alpha, gamma_correct);

        fillRect(pix, &color, &.{.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(w),
            .height = @intCast(h),
        }});
    }

    csd_commit(term, surf, buf);
}

export fn render_csd_button(term: *Terminal, surf_idx: types.CsdSurface, info: *const CsdData, buf: *Buffer) callconv(.c) void {
    const win = term.window.?;
    std.debug.assert(win.csd_mode == .yes);
    std.debug.assert(@intFromEnum(surf_idx) >= @intFromEnum(types.CsdSurface.minimize) and
        @intFromEnum(surf_idx) <= @intFromEnum(types.CsdSurface.close));

    const surf = &win.csd.surface[@intCast(@intFromEnum(surf_idx))].surface;

    if (info.width == 0 or info.height == 0)
        return;

    const conf = term.conf.?;
    var _color: u32 = undefined;
    var alpha: u16 = 0xffff;
    var is_active = false;
    var is_set = false;
    var conf_color: ?*const u32 = null;

    switch (surf_idx) {
        .minimize => {
            _color = conf.colors_dark.table[4]; // blue
            is_set = conf.csd.color._flags.minimize_set;
            conf_color = &conf.csd.color.minimize;
            is_active = term.active_surface == .button_minimize and
                any_pointer_is_on_button(term, .minimize);
        },
        .maximize => {
            _color = conf.colors_dark.table[2]; // green
            is_set = conf.csd.color._flags.maximize_set;
            conf_color = &conf.csd.color.maximize;
            is_active = term.active_surface == .button_maximize and
                any_pointer_is_on_button(term, .maximize);
        },
        .close => {
            _color = conf.colors_dark.table[1]; // red
            is_set = conf.csd.color._flags.close_set;
            conf_color = &conf.csd.color.quit;
            is_active = term.active_surface == .button_close and
                any_pointer_is_on_button(term, .close);
        },
        else => unreachable, // unhandled surface type
    }

    if (is_active) {
        if (is_set) {
            _color = conf_color.?.*;
            alpha = @truncate((_color >> 24) | (_color >> 24 << 8));
        }
    } else {
        _color = 0;
        alpha = 0;
    }

    if (!term.visual_focus)
        _color = color_dim(term, _color);

    const gamma_correct = wayl_do_linear_blending(term.wl, conf);
    const color = color_hex_to_pixman_with_alpha(_color, alpha, gamma_correct);
    render_csd_part(term, surf.surf, buf, info.width, info.height, &color);

    switch (surf_idx) {
        .minimize => render_csd_button_minimize(term, buf),
        .maximize => render_csd_button_maximize(term, buf),
        .close => render_csd_button_close(term, buf),
        else => unreachable, // unhandled surface type
    }

    csd_commit(term, surf, buf);
}

export fn render_csd(term: *Terminal) callconv(.c) void {
    const win = term.window.?;
    std.debug.assert(win.csd_mode == .yes);

    if (win.is_fullscreen)
        return;

    const scale = term.scale;
    var infos: [types.CSD_SURF_COUNT]CsdData = undefined;
    var widths: [types.CSD_SURF_COUNT]c_int = undefined;
    var heights: [types.CSD_SURF_COUNT]c_int = undefined;

    for (0..types.CSD_SURF_COUNT) |i| {
        const surf_idx: types.CsdSurface = @enumFromInt(@as(c_int, @intCast(i)));
        infos[i] = get_csd_data(term, surf_idx);

        const width = infos[i].width;
        const height = infos[i].height;

        const surf = win.csd.surface[i].surface.surf;
        const sub = win.csd.surface[i].sub;

        std.debug.assert(surf != null);
        std.debug.assert(sub != null);

        if (width == 0 or height == 0) {
            widths[i] = 0;
            heights[i] = 0;
            wayland_shim_subsurface_set_position(sub, 0, 0);
            wayland_shim_surface_attach(surf, null, 0, 0);
            wayland_shim_surface_commit(surf);
            continue;
        }

        widths[i] = width;
        heights[i] = height;
        wayland_shim_subsurface_set_position(sub, roundf(fdiv(infos[i].x, scale)), roundf(fdiv(infos[i].y, scale)));
    }

    var bufs: [types.CSD_SURF_COUNT]?*Buffer = undefined;
    shm_get_many(@ptrCast(@alignCast(term.render.chains.csd.?)), types.CSD_SURF_COUNT, &widths, &heights, &bufs);

    var i: usize = @intFromEnum(types.CsdSurface.left);
    while (i <= @intFromEnum(types.CsdSurface.bottom)) : (i += 1)
        render_csd_border(term, @enumFromInt(@as(c_int, @intCast(i))), &infos[i], bufs[i].?);

    i = @intFromEnum(types.CsdSurface.minimize);
    while (i <= @intFromEnum(types.CsdSurface.close)) : (i += 1)
        render_csd_button(term, @enumFromInt(@as(c_int, @intCast(i))), &infos[i], bufs[i].?);

    render_csd_title(term, &infos[@intFromEnum(types.CsdSurface.title)], bufs[@intFromEnum(types.CsdSurface.title)].?);
}

// ─────────────────────────────────────────────────────────────────────────
// render_osd(): the small text painter (D3i)
// ─────────────────────────────────────────────────────────────────────────

const OSD_TEXT_RUN_SHAPING: c_int = 0x2; // FCFT_CAPABILITY_TEXT_RUN_SHAPING

extern fn render_shim_fcft_font_height(font: *const FcftFont) callconv(.c) c_int;
extern fn render_shim_fcft_has_text_run() callconv(.c) bool;
extern fn render_shim_fcft_text_run(
    font: *FcftFont,
    len: usize,
    text: [*]const u32,
    subpixel: c_int,
    out_glyphs: *[*]const ?*FcftGlyph,
    out_count: *usize,
) callconv(.c) ?*anyopaque;
extern fn render_shim_fcft_text_run_destroy(run: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_set_opaque_region(
    compositor: ?*anyopaque,
    surf: ?*anyopaque,
    width: c_int,
    height: c_int,
    is_opaque: bool,
) callconv(.c) void;
extern fn quirk_weston_subsurface_desync_on(sub: ?*anyopaque) callconv(.c) void;
extern fn quirk_weston_subsurface_desync_off(sub: ?*anyopaque) callconv(.c) void;

fn c32Len(s: [*]const u32) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

export fn render_osd(
    term: *Terminal,
    sub_surf: *const types.WaylSubSurface,
    font: ?*FcftFont,
    buf: *Buffer,
    text: [*]const u32,
    _fg: u32,
    _bg: u32,
    x_in: c_uint,
) callconv(.c) void {
    var x = x_in;
    const pix = bufferPix(buf);

    clipRect(pix, 0, 0, buf.width, buf.height);

    const gamma_correct = wayl_do_linear_blending(term.wl, term.conf.?);
    const alpha: u16 = @truncate((_bg >> 24) | (_bg >> 24 << 8));
    const bg = color_hex_to_pixman_with_alpha(_bg, alpha, gamma_correct);

    fillRect(pix, &bg, &.{.{
        .x = 0,
        .y = 0,
        .width = @intCast(buf.width),
        .height = @intCast(buf.height),
    }});

    const fg = color_hex_to_pixman(_fg, gamma_correct);
    const x_ofs: c_int = term.font_x_ofs;

    const len = c32Len(text);

    var text_run: ?*anyopaque = null;
    var glyphs: []const ?*FcftGlyph = &.{};
    var small: [64]?*FcftGlyph = undefined;
    var glyph_count: usize = 0;

    if (font) |f| {
        if (render_shim_fcft_has_text_run()) {
            var run_glyphs: [*]const ?*FcftGlyph = undefined;
            var run_count: usize = 0;
            text_run = render_shim_fcft_text_run(f, len, text, term.font_subpixel, &run_glyphs, &run_count);

            if (text_run != null) {
                glyphs = run_glyphs[0..run_count];
                glyph_count = run_count;
            }
        }

        if (text_run == null) {
            // Fall back to per-character rasterization. `small` is only
            // enough for the OSD strings foot draws (a few dozen
            // characters); anything longer is truncated, which the
            // compositor clamps anyway.
            for (0..len) |i| {
                if (glyph_count == small.len)
                    break;
                const glyph = fcft_rasterize_char_utf32(f, text[i], term.font_subpixel) orelse continue;
                small[glyph_count] = glyph;
                glyph_count += 1;
            }
            glyphs = small[0..glyph_count];
        }
    }

    const src = render_shim_solid_fill(&fg).?;

    // Calculate baseline
    var y: c_uint = 0;
    if (font) |f| {
        const line_height = buf.height;
        const font_height = @max(render_shim_fcft_font_height(f), terminal_shim_fcft_font_ascent(f) + terminal_shim_fcft_font_descent(f));
        const glyph_top_y: c_int = @intFromFloat(@round(@as(f64, @floatFromInt(line_height - font_height)) / 2.0));
        y = @intCast(@as(c_int, term.font_y_ofs) + glyph_top_y + terminal_shim_fcft_font_ascent(f));

        for (glyphs) |maybe_glyph| {
            const glyph = maybe_glyph orelse continue;

            if (glyph.is_color_glyph) {
                render_shim_composite(optPix(glyph.pix), null, pix, @as(c_int, @intCast(x)) + x_ofs + glyph.x, @as(c_int, @intCast(y)) - glyph.y, glyph.width, glyph.height);
            } else {
                render_shim_composite(src, optPix(glyph.pix), pix, @as(c_int, @intCast(x)) + x_ofs + glyph.x, @as(c_int, @intCast(y)) - glyph.y, glyph.width, glyph.height);
            }

            x = @intCast(@as(c_int, @intCast(x)) + glyph.advance.x);
        }
    }

    render_shim_fcft_text_run_destroy(text_run);
    render_shim_image_unref(src);
    render_shim_clip_clear(pix);

    quirk_weston_subsurface_desync_on(sub_surf.sub);
    wayl_surface_scale(term.window.?, @constCast(&sub_surf.surface), buf, term.scale);
    wayland_shim_surface_attach(sub_surf.surface.surf, buf.wl_buf, 0, 0);
    wayland_shim_surface_damage_buffer(sub_surf.surface.surf, 0, 0, buf.width, buf.height);

    wayland_shim_set_opaque_region(term.wl.?.compositor, sub_surf.surface.surf, buf.width, buf.height, alpha == 0xffff);

    wayland_shim_surface_commit(sub_surf.surface.surf);
    quirk_weston_subsurface_desync_off(sub_surf.sub);
}

// ─────────────────────────────────────────────────────────────────────────
// IME preedit and the overlay surface (D3j)
// ─────────────────────────────────────────────────────────────────────────

const OVERLAY_NONE: c_int = 0;
const OVERLAY_SEARCH: c_int = 1;
const OVERLAY_FLASH: c_int = 2;
const OVERLAY_UNICODE_MODE: c_int = 3;

pub const PixmanBox32 = types.PixmanBox32;

/// Opaque storage for `pixman_region32_t` (a 16-byte extents box plus a data
/// pointer = 24 bytes on LP64, the same size as `Render.last_overlay_clip`).
/// The operations stay in terminal-shim.c so the pixman type is never
/// mirrored; Zig only owns the bytes.
const Region32 = extern struct {
    extents: [4]i32,
    data: ?*anyopaque,
};

comptime {
    std.debug.assert(@sizeOf(Region32) == 24);
    std.debug.assert(@sizeOf(PixmanBox32) == 16);
}

fn regionPtr(r: *Region32) *anyopaque {
    return @ptrCast(r);
}

extern fn render_shim_region_init(r: *anyopaque) callconv(.c) void;
extern fn render_shim_region_init_rect(r: *anyopaque, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void;
extern fn render_shim_region_fini(r: *anyopaque) callconv(.c) void;
extern fn render_shim_region_copy(dst: *anyopaque, src: *const anyopaque) callconv(.c) void;
extern fn render_shim_region_clear(r: *anyopaque) callconv(.c) void;
extern fn render_shim_region_subtract(dst: *anyopaque, a: *const anyopaque, b: *const anyopaque) callconv(.c) void;
extern fn render_shim_region_union(dst: *anyopaque, a: *const anyopaque, b: *const anyopaque) callconv(.c) void;
extern fn render_shim_region_extents(r: *const anyopaque, out: *PixmanBox32) callconv(.c) void;
extern fn render_shim_set_clip_region(pix: *PixmanImage, r: ?*const anyopaque) callconv(.c) void;
extern fn render_shim_single_pixel_buffer(
    manager: ?*anyopaque,
    r: u32,
    g: u32,
    b: u32,
    a: u32,
) callconv(.c) ?*anyopaque;
extern fn shm_shim_wl_buffer_destroy(wl_buffer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_surface_set_buffer_scale(surf: ?*anyopaque, scale: i32) callconv(.c) void;
extern fn wayland_shim_viewport_set_destination(viewport: ?*anyopaque, width: i32, height: i32) callconv(.c) void;
extern fn terminal_shim_grid_row_in_view(grid: *types.Grid, row: c_int) callconv(.c) ?*types.Row;
extern fn shm_get_buffer(chain: *types.ShmBufferChain, width: c_int, height: c_int) callconv(.c) ?*Buffer;
extern fn shm_did_not_use_buf(buf: *Buffer) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn c32width(c: u32) callconv(.c) c_int;
extern fn term_ime_set_cursor_rect(term: *Terminal, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void;

/// search.h's `struct search_match_iterator` / `search_matches_*()`.
const SearchMatchIterator = extern struct {
    term: *Terminal,
    start: types.Coord,
};

extern fn search_matches_new_iter(term: *Terminal) callconv(.c) SearchMatchIterator;
extern fn search_matches_next(iter: *SearchMatchIterator) callconv(.c) types.Range;

fn renderImePreeditForSeat(term: *Terminal, seat: *types.Seat, buf: *Buffer) void {
    const preedit = &seat.ime.preedit;

    if (preedit.cells == null)
        return;

    if (term.is_searching)
        return;

    const gamma_correct = wayl_do_linear_blending(term.wl, term.conf.?);
    const grid = term.grid.?;

    // Adjust cursor position to viewport
    var cursor = grid.cursor.point;
    cursor.row += grid.offset;
    cursor.row -= grid.view;
    cursor.row &= grid.num_rows - 1;

    if (cursor.row < 0 or cursor.row >= term.rows)
        return;

    var cells_needed: c_int = preedit.count;

    if (preedit.cursor.start == cells_needed and
        preedit.cursor.end == cells_needed)
    {
        // Cursor will be drawn *after* the pre-edit string, i.e. in the cell
        // *after*. This means we need to copy, and dirty, one extra cell from
        // the original grid, or we'll leave trailing "cursors" after us if
        // the user deletes text while pre-editing.
        cells_needed += 1;
    }

    const row_idx: c_int = cursor.row;
    var col_idx: c_int = cursor.col;
    var ime_ofs: c_int = 0; // Offset into the pre-edit string to render from

    const cells_left: c_int = term.cols - cursor.col;
    var cells_used: c_int = @min(cells_needed, term.cols);

    // Adjust start of pre-edit text to the left if the string doesn't fit
    if (cells_left < cells_used)
        col_idx -= cells_used - cells_left;

    const preedit_cells: [*]const Cell = @ptrCast(@alignCast(preedit.cells.?));

    if (cells_needed > cells_used) {
        const start = preedit.cursor.start;
        const end = preedit.cursor.end;

        if (start == end) {
            // Ensure *end* of the pre-edit string is visible
            ime_ofs = cells_needed - cells_used;
        } else {
            // Ensure the *beginning* of the cursor-area is visible
            ime_ofs = start;

            // Display as much as possible of the pre-edit string
            if (cells_needed - ime_ofs < cells_used)
                ime_ofs = cells_needed - cells_used;
        }

        // Make sure we don't start in the middle of a character
        while (ime_ofs < cells_needed and
            preedit_cells[@intCast(ime_ofs)].wc >= CELL_SPACER)
        {
            ime_ofs += 1;
        }
    }

    std.debug.assert(col_idx >= 0);
    std.debug.assert(col_idx < term.cols);

    const row = terminal_shim_grid_row_in_view(grid, row_idx) orelse return;

    // Don't start the pre-edit text in the middle of a double-width character
    while (col_idx > 0 and row.cells.?[@intCast(col_idx)].wc >= CELL_SPACER) {
        cells_used += 1;
        col_idx -= 1;
    }

    // Copy original content (render_cell() reads cell data directly from the
    // grid), and mark all cells dirty, so they are re-rendered when the
    // pre-edit text is modified or removed.
    const real_cells: [*]Cell = @ptrCast(@alignCast(
        xmalloc(@as(usize, @intCast(cells_used)) * @sizeOf(Cell)) orelse unreachable,
    ));
    for (0..@intCast(cells_used)) |i| {
        const idx = @as(usize, @intCast(col_idx)) + i;
        std.debug.assert(idx < term.cols);
        real_cells[i] = row.cells.?[idx];
        real_cells[i].attrs.clean = false;
    }
    row.dirty = true;

    // Render pre-edit text
    std.debug.assert(preedit_cells[@intCast(ime_ofs)].wc < CELL_SPACER);
    var i: c_int = 0;
    var idx: c_int = ime_ofs;
    while (idx < preedit.count) : ({
        i += 1;
        idx += 1;
    }) {
        const cell = &preedit_cells[@intCast(idx)];

        if (cell.wc >= CELL_SPACER)
            continue;

        const width = @max(1, c32width(cell.wc));
        if (col_idx + i + width > term.cols)
            break;

        row.cells.?[@intCast(col_idx + i)] = cell.*;
        _ = render_cell(term, bufferPix(buf), null, row, row_idx, col_idx + i, false);
    }

    const start = preedit.cursor.start - ime_ofs;
    const end = preedit.cursor.end - ime_ofs;

    if (!preedit.cursor.hidden) {
        const start_cell = &preedit_cells[0];

        const fg = color_hex_to_pixman(term.colors.fg, gamma_correct);
        const bg = color_hex_to_pixman(term.colors.bg, gamma_correct);

        var cursor_color: PixmanColor = undefined;
        var text_color: PixmanColor = undefined;
        cursor_colors_for_cell(term, start_cell, &fg, &bg, &cursor_color, &text_color, gamma_correct);

        const x: c_int = term.margins.left + (col_idx + start) * term.cell_width;
        const y: c_int = term.margins.top + row_idx * term.cell_height;

        if (end == start) {
            // Bar
            if (start >= 0) {
                if (attrs_to_font(term, &start_cell.attrs)) |font| {
                    draw_beam_cursor(term, bufferPix(buf), font, &cursor_color, x, y);
                }
            }
            term_ime_set_cursor_rect(term, x, y, 1, term.cell_height);
        } else if (end > start) {
            // Hollow cursor
            if (start >= 0 and end <= term.cols) {
                const cols = end - start;
                draw_hollow_block(term, bufferPix(buf), &cursor_color, x, y, cols);
            }

            term_ime_set_cursor_rect(term, x, y, (end - start) * term.cell_width, term.cell_height);
        }
    }

    // Restore original content (but do not render)
    for (0..@intCast(cells_used)) |n| {
        row.cells.?[@as(usize, @intCast(col_idx)) + n] = real_cells[n];
    }
    free(real_cells);

    const damage_x = term.margins.left + col_idx * term.cell_width;
    const damage_y = term.margins.top + row_idx * term.cell_height;
    const damage_w = cells_used * term.cell_width;
    const damage_h = term.cell_height;

    wayland_shim_surface_damage_buffer(term.window.?.surface.surf, damage_x, damage_y, damage_w, damage_h);
}

export fn render_ime_preedit(term: *Terminal, buf: *Buffer) callconv(.c) void {
    // meson.build refuses -Dime=false for this branch (the Zig mirrors assume
    // IME support), so the C's FOOT_IME_ENABLED arm is always taken.
    const seats: *SeatList = @ptrCast(&term.wl.?.seats);
    var it = seats.foreach();
    while (it.next()) |node| {
        const seat = &node.item;
        if (seat.kbd_focus == term)
            renderImePreeditForSeat(term, seat, buf);
    }
}

fn renderOverlaySinglePixel(term: *Terminal, style: c_int, color: PixmanColor) void {
    const wayl = term.wl.?;
    const overlay = &term.window.?.overlay;
    var buf: ?*anyopaque = null;

    std.debug.assert(style == OVERLAY_UNICODE_MODE or style == OVERLAY_FLASH);
    std.debug.assert(wayl.single_pixel_manager != null);
    std.debug.assert(overlay.surface.viewport != null);

    quirk_weston_subsurface_desync_on(overlay.sub);

    if (style != term.render.last_overlay_style) {
        buf = render_shim_single_pixel_buffer(
            wayl.single_pixel_manager,
            @intFromFloat(@as(f64, @floatFromInt(color.red)) / 0xffff * 0xffffffff),
            @intFromFloat(@as(f64, @floatFromInt(color.green)) / 0xffff * 0xffffffff),
            @intFromFloat(@as(f64, @floatFromInt(color.blue)) / 0xffff * 0xffffffff),
            @intFromFloat(@as(f64, @floatFromInt(color.alpha)) / 0xffff * 0xffffffff),
        );

        wayland_shim_surface_set_buffer_scale(overlay.surface.surf, 1);
        wayland_shim_surface_attach(overlay.surface.surf, buf, 0, 0);
    }

    wayland_shim_viewport_set_destination(
        overlay.surface.viewport,
        @intFromFloat(@round(@as(f32, @floatFromInt(term.width)) / term.scale)),
        @intFromFloat(@round(@as(f32, @floatFromInt(term.height)) / term.scale)),
    );

    wayland_shim_subsurface_set_position(overlay.sub, 0, 0);

    wayland_shim_surface_damage_buffer(overlay.surface.surf, 0, 0, term.width, term.height);

    wayland_shim_surface_commit(overlay.surface.surf);
    quirk_weston_subsurface_desync_off(overlay.sub);

    term.render.last_overlay_style = style;

    if (buf) |b| {
        shm_shim_wl_buffer_destroy(b);
    }
}

export fn render_overlay(term: *Terminal) callconv(.c) void {
    const overlay = &term.window.?.overlay;
    const unicode_mode_active = term.unicode_mode.active;

    const style: c_int = if (term.is_searching)
        OVERLAY_SEARCH
    else if (term.flash.active)
        OVERLAY_FLASH
    else if (unicode_mode_active)
        OVERLAY_UNICODE_MODE
    else
        OVERLAY_NONE;

    if (style == OVERLAY_NONE) {
        if (term.render.last_overlay_style != OVERLAY_NONE) {
            // Unmap overlay sub-surface
            wayland_shim_surface_attach(overlay.surface.surf, null, 0, 0);
            wayland_shim_surface_commit(overlay.surface.surf);
            term.render.last_overlay_style = OVERLAY_NONE;
            term.render.last_overlay_buf = null;
        }
        return;
    }

    var color: PixmanColor = undefined;

    switch (style) {
        OVERLAY_SEARCH, OVERLAY_UNICODE_MODE => color = .{
            .red = 0,
            .green = 0,
            .blue = 0,
            .alpha = 0x7fff,
        },

        OVERLAY_FLASH => color = color_hex_to_pixman_with_alpha(
            term.conf.?.colors_dark.flash,
            @truncate(term.conf.?.colors_dark.flash_alpha),
            wayl_do_linear_blending(term.wl, term.conf.?),
        ),

        else => unreachable,
    }

    const single_pixel =
        (style == OVERLAY_UNICODE_MODE or style == OVERLAY_FLASH) and
        term.wl.?.single_pixel_manager != null and
        overlay.surface.viewport != null;

    if (single_pixel) {
        renderOverlaySinglePixel(term, style, color);
        return;
    }

    const chain: *types.ShmBufferChain = @ptrCast(@alignCast(term.render.chains.overlay.?));
    const buf = shm_get_buffer(chain, term.width, term.height) orelse return;
    const pix = bufferPix(buf);

    render_shim_set_clip_region(pix, null);

    // Bounding rectangle of damaged areas - for wl_surface_damage_buffer()
    var damage_bounds: PixmanBox32 = undefined;

    if (style == OVERLAY_SEARCH) {
        // Only update the areas that changed since the last frame:
        // clear the cells that are now selected but weren't, and dim the
        // cells that were selected but aren't anymore.
        const see_through: *Region32 = @ptrCast(&term.render.last_overlay_clip);
        var old_see_through: Region32 = undefined;

        const buffer_reuse =
            term.render.last_overlay_buf == @as(?*anyopaque, @ptrCast(buf)) and
            style == term.render.last_overlay_style and
            buf.age == 0;

        if (!buffer_reuse) {
            // Can't reuse last frame's damage - set to full window, to
            // ensure *everything* is updated
            render_shim_region_init_rect(regionPtr(&old_see_through), 0, 0, buf.width, buf.height);
        } else {
            // Use last frame's saved region
            render_shim_region_init(regionPtr(&old_see_through));
            render_shim_region_copy(regionPtr(&old_see_through), regionPtr(see_through));
        }

        render_shim_region_clear(regionPtr(see_through));

        // Build region consisting of all current search matches
        var iter = search_matches_new_iter(term);
        var match = search_matches_next(&iter);
        while (match.start.row >= 0) : (match = search_matches_next(&iter)) {
            var r = match.start.row;
            var start_col = match.start.col;
            const end_row = match.end.row;

            while (true) {
                const end_col = if (r == end_row) match.end.col else term.cols - 1;

                const x = term.margins.left + start_col * term.cell_width;
                const y = term.margins.top + r * term.cell_height;
                const width = (end_col + 1 - start_col) * term.cell_width;
                const height = term.cell_height;

                render_shim_region_union_rect(regionPtr(see_through), x, y, width, height);

                r += 1;
                if (r > end_row)
                    break;

                start_col = 0;
            }
        }

        // Areas that need to be cleared: cells that were dimmed in the last
        // frame but are now see-through
        var new_see_through: Region32 = undefined;
        render_shim_region_init(regionPtr(&new_see_through));

        if (buffer_reuse) {
            render_shim_region_subtract(regionPtr(&new_see_through), regionPtr(see_through), regionPtr(&old_see_through));
        } else {
            // Buffer content is unknown - explicitly clear *all* current
            // see-through areas
            render_shim_region_copy(regionPtr(&new_see_through), regionPtr(see_through));
        }
        render_shim_set_clip_region(pix, regionPtr(&new_see_through));

        // Areas that need to be dimmed: cells that were cleared in the last
        // frame but are not anymore
        var new_dimmed: Region32 = undefined;
        render_shim_region_init(regionPtr(&new_dimmed));
        render_shim_region_subtract(regionPtr(&new_dimmed), regionPtr(&old_see_through), regionPtr(see_through));
        render_shim_region_fini(regionPtr(&old_see_through));

        // Total affected area
        var damage: Region32 = undefined;
        render_shim_region_init(regionPtr(&damage));
        render_shim_region_union(regionPtr(&damage), regionPtr(&new_see_through), regionPtr(&new_dimmed));
        render_shim_region_extents(regionPtr(&damage), &damage_bounds);

        // Clear cells that became selected in this frame.
        fillRect(pix, &.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }, &.{.{
            .x = 0,
            .y = 0,
            .width = @intCast(term.width),
            .height = @intCast(term.height),
        }});

        // Set clip region for the newly dimmed cells. The actual paint call
        // is done below.
        render_shim_set_clip_region(pix, regionPtr(&new_dimmed));

        render_shim_region_fini(regionPtr(&new_see_through));
        render_shim_region_fini(regionPtr(&new_dimmed));
        render_shim_region_fini(regionPtr(&damage));
    } else if (term.render.last_overlay_buf == @as(?*anyopaque, @ptrCast(buf)) and
        style == term.render.last_overlay_style)
    {
        std.debug.assert(style == OVERLAY_FLASH or style == OVERLAY_UNICODE_MODE);
        shm_did_not_use_buf(buf);
        return;
    } else {
        render_shim_set_clip_region(pix, null);
        damage_bounds = .{ .x1 = 0, .y1 = 0, .x2 = buf.width, .y2 = buf.height };
    }

    fillRect(pix, &color, &.{.{
        .x = 0,
        .y = 0,
        .width = @intCast(term.width),
        .height = @intCast(term.height),
    }});

    quirk_weston_subsurface_desync_on(overlay.sub);
    wayl_surface_scale(term.window.?, &overlay.surface, buf, term.scale);
    wayland_shim_subsurface_set_position(overlay.sub, 0, 0);
    wayland_shim_surface_attach(overlay.surface.surf, buf.wl_buf, 0, 0);

    wayland_shim_surface_damage_buffer(
        overlay.surface.surf,
        damage_bounds.x1,
        damage_bounds.y1,
        damage_bounds.x2 - damage_bounds.x1,
        damage_bounds.y2 - damage_bounds.y1,
    );

    wayland_shim_surface_commit(overlay.surface.surf);
    quirk_weston_subsurface_desync_off(overlay.sub);

    buf.age = 0;
    term.render.last_overlay_buf = buf;
    term.render.last_overlay_style = style;
}

// ─────────────────────────────────────────────────────────────────────────
// Presentation feedback and the renderer object (D3k1)
// ─────────────────────────────────────────────────────────────────────────

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;

extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

const Fdm = opaque {};

/// fdm.h's `fdm_hook_t`.
const FdmHook = *const fn (*Fdm, ?*anyopaque) callconv(.c) void;
const FDM_HOOK_PRIORITY_NORMAL: c_int = 1;

extern fn fdm_hook_add(
    fdm: *Fdm,
    hook: FdmHook,
    data: ?*anyopaque,
    priority: c_int,
) callconv(.c) bool;
extern fn fdm_hook_del(fdm: *Fdm, hook: FdmHook, priority: c_int) callconv(.c) bool;

/// `struct renderer`: two pointers, matching the old C struct. `grid_render()`
/// and the frame hook read `renderer.wayl`, so the layout has to agree.
const Renderer = extern struct {
    fdm: *Fdm,
    wayl: *types.Wayland,
};

comptime {
    std.debug.assert(@sizeOf(Renderer) == 2 * @sizeOf(usize));
}

extern fn render_shim_presentation_feedback_destroy(fb: ?*anyopaque) callconv(.c) void;

const PresentationStatistics = struct {
    total: usize = 0,
    zero: usize = 0,
    one: usize = 0,
    two: usize = 0,
};

var presentation_statistics = PresentationStatistics{};

export fn render_shim_presentation_stat_add(frames: c_uint) callconv(.c) void {
    presentation_statistics.total += 1;

    if (frames >= 2)
        presentation_statistics.two += 1
    else if (frames >= 1)
        presentation_statistics.one += 1
    else
        presentation_statistics.zero += 1;
}

/// Exit-time summary of the presentation frame counts.
///
/// C kept this in a `__attribute__((destructor))` in terminal-shim.c, which the
/// C runtime runs after `main` returns. Zig has no destructor attribute with
/// the same ordering across linkers, so main.zig calls this as its last
/// statement — after `log_deinit()`, which only closes syslog, i.e. at the same
/// point in the process's life. Keeping it here also keeps the counters, which
/// are Zig globals, out of C.
export fn render_log_presentation_statistics() callconv(.c) void {
    const stats = presentation_statistics;
    if (stats.total == 0)
        return;

    const total: f64 = @floatFromInt(stats.total);
    log_msg(
        LOG_CLASS_INFO,
        "render",
        "render.zig",
        @intCast(@src().line),
        "presentation statistics: zero=%f%%, one=%f%%, two=%f%%",
        100.0 * @as(f64, @floatFromInt(stats.zero)) / total,
        100.0 * @as(f64, @floatFromInt(stats.one)) / total,
        100.0 * @as(f64, @floatFromInt(stats.two)) / total,
    );
}

export fn render_init(fdm: *Fdm, wayl: *types.Wayland) callconv(.c) ?*Renderer {
    const raw = std.c.malloc(@sizeOf(Renderer)) orelse {
        log_errno(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "malloc() failed");
        return null;
    };

    const renderer: *Renderer = @ptrCast(@alignCast(raw));
    renderer.* = .{ .fdm = fdm, .wayl = wayl };

    if (!fdm_hook_add(fdm, &fdm_hook_refresh_pending_terminals, renderer, FDM_HOOK_PRIORITY_NORMAL)) {
        log_msg(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "failed to register FDM hook");
        free(renderer);
        return null;
    }

    return renderer;
}

export fn render_destroy(renderer: ?*Renderer) callconv(.c) void {
    const r = renderer orelse return;

    _ = fdm_hook_del(r.fdm, &fdm_hook_refresh_pending_terminals, FDM_HOOK_PRIORITY_NORMAL);
    free(r);
}

/// Appends to `buf` at `len`, truncating like snprintf() when it does not fit.
fn appendMsg(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const piece = std.fmt.bufPrint(buf[len.*..], fmt, args) catch return;
    len.* += piece.len;
}

/// How many monitor frames a commit took. `presented()` logs this and buckets
/// it into the exit-time statistics; exported so the harness can pin it.
fn presentationFrameCount(total_us: i64, refresh: f32) c_uint {
    if (!(refresh > 0))
        return 0;

    const sec = @divTrunc(total_us, 1_000_000);
    const usec = @mod(total_us, 1_000_000);
    const diff: f64 =
        @as(f64, @floatFromInt(sec)) * 1_000_000.0 + @as(f64, @floatFromInt(usec));

    return @intFromFloat(diff / (1_000_000.0 / @as(f64, refresh)));
}

export fn render_presentation_frame_count(total_us: i64, refresh: f32) callconv(.c) c_uint {
    return presentationFrameCount(total_us, refresh);
}

fn presentationCtxNew(
    term: *Terminal,
    input_sec: i64,
    input_usec: i64,
    commit_sec: i64,
    commit_usec: i64,
) *types.PresentationContext {
    const raw = xmalloc(@sizeOf(types.PresentationContext)) orelse unreachable;
    const ctx: *types.PresentationContext = @ptrCast(@alignCast(raw));
    ctx.* = .{
        .term = term,
        .input = .{ .tv_sec = input_sec, .tv_usec = input_usec },
        .commit = .{ .tv_sec = commit_sec, .tv_usec = commit_usec },
    };
    return ctx;
}

export fn sync_output(
    data: ?*anyopaque,
    wp_presentation_feedback: ?*anyopaque,
    output: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = wp_presentation_feedback;
    _ = output;
}

export fn presented(
    data: ?*anyopaque,
    wp_presentation_feedback: ?*anyopaque,
    tv_sec_hi: u32,
    tv_sec_lo: u32,
    tv_nsec: u32,
    refresh: u32,
    seq_hi: u32,
    seq_lo: u32,
    flags: u32,
) callconv(.c) void {
    _ = refresh;
    _ = seq_hi;
    _ = seq_lo;
    _ = flags;

    const ctx: *types.PresentationContext = @ptrCast(@alignCast(data.?));
    const term = ctx.term orelse return;

    const in_sec = ctx.input.tv_sec;
    const in_usec = ctx.input.tv_usec;
    const commit_sec = ctx.commit.tv_sec;
    const commit_usec = ctx.commit.tv_usec;

    const presented_sec: i64 = @as(i64, tv_sec_hi) << 32 | @as(i64, tv_sec_lo);
    const presented_usec: i64 = @as(i64, tv_nsec / 1000);

    const presented_us = presented_sec * 1_000_000 + presented_usec;
    const input_us = in_sec * 1_000_000 + in_usec;
    const commit_us = commit_sec * 1_000_000 + commit_usec;

    const use_input = input_us > 0 and presented_us > input_us;

    if (use_input) {
        if (presented_us < input_us)
            return;
    } else if (presented_us < commit_us) {
        return;
    }

    log_msg(
        LOG_CLASS_DEBUG,
        "render",
        "render.zig",
        @intCast(@src().line),
        "commit: %lu s %lu µs, presented: %lu s %lu µs",
        @as(u64, @intCast(commit_sec)),
        @as(u64, @intCast(commit_usec)),
        @as(u64, @intCast(presented_sec)),
        @as(u64, @intCast(presented_usec)),
    );

    var msg_buf: [1025]u8 = undefined;
    var msg_len: usize = 0;

    if (use_input) {
        appendMsg(&msg_buf, &msg_len, "input - {d} µs -> ", .{commit_us - input_us});
    }
    appendMsg(&msg_buf, &msg_len, "commit - {d} µs -> ", .{presented_us - commit_us});

    const total_us = if (use_input) presented_us - input_us else presented_us - commit_us;
    appendMsg(&msg_buf, &msg_len, "presented (total: {d} µs)", .{total_us});
    msg_buf[msg_len] = 0;

    var frame_count: c_uint = 0;
    // terminal_types.Tll is head-only; cast to the typed list to read the
    // front monitor (same three-word head layout).
    const on_outputs: *tll.Tll(?*const types.Monitor) =
        @ptrCast(&term.window.?.on_outputs);
    if (on_outputs.len() > 0) {
        if (on_outputs.head.?.item) |mon| {
            frame_count = presentationFrameCount(total_us, mon.refresh);
        }
    }

    render_shim_presentation_stat_add(frame_count);

    const msg: [*:0]const u8 = @ptrCast(&msg_buf);
    if (frame_count >= 2) {
        log_msg(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "%s (more than %u frames)", msg, frame_count);
    } else if (frame_count >= 1) {
        log_msg(LOG_CLASS_WARNING, "render", "render.zig", @intCast(@src().line), "%s (more than %u frames)", msg, frame_count);
    } else {
        log_msg(LOG_CLASS_INFO, "render", "render.zig", @intCast(@src().line), "%s (more than %u frames)", msg, frame_count);
    }

    render_shim_presentation_feedback_destroy(wp_presentation_feedback);
    free(ctx);
}

export fn discarded(
    data: ?*anyopaque,
    wp_presentation_feedback: ?*anyopaque,
) callconv(.c) void {
    render_shim_presentation_feedback_destroy(wp_presentation_feedback);
    free(data);
}

// ─────────────────────────────────────────────────────────────────────────
// Damage re-application (D3k2a)
// ─────────────────────────────────────────────────────────────────────────

extern fn term_damage_view(term: *Terminal) callconv(.c) void;
fn freeDamageList(list: *types.DamageList) void {
    var node = list.head;
    while (node) |n| {
        const next = n.next;
        free(n);
        node = next;
    }

    list.head = null;
    list.tail = null;
    list.length = 0;
}

export fn force_full_repaint(term: *Terminal, buf: *Buffer) callconv(.c) void {
    freeDamageList(&term.grid.?.scroll_damage);
    render_margin(term, buf, 0, term.rows, true);
    term_damage_view(term);
}

export fn reapply_old_damage(term: *Terminal, new_buf: *Buffer, old: *Buffer) callconv(.c) void {
    if (new_buf.age > 1) {
        const len =
            @as(usize, @intCast(new_buf.height)) * @as(usize, @intCast(new_buf.stride));
        const dst: [*]u8 = @ptrCast(new_buf.data.?);
        const src: [*]u8 = @ptrCast(old.data.?);
        @memcpy(dst[0..len], src[0..len]);
        return;
    }

    var dirty: Region32 = undefined;
    render_shim_region_init(regionPtr(&dirty));

    // Figure out the current frame's damage region.
    //
    // Without scroll damage we can subtract this frame's damage from the last
    // frame's, so we don't copy areas that are about to be overwritten
    // anyway. The scan is row based: a half-damaged row is copied whole and
    // then partially overwritten while rendering.
    //
    // Since we're scanning the whole viewport anyway, also track whether
    // *all* cells are to be updated - then just re-render everything.
    var full_repaint_needed = true;

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const row = terminal_shim_grid_row_in_view(term.grid.?, r) orelse continue;

        if (!row.dirty) {
            full_repaint_needed = false;
            continue;
        }

        var row_all_dirty = true;
        var c: c_int = 0;
        while (c < term.cols) : (c += 1) {
            if (row.cells.?[@intCast(c)].attrs.clean) {
                row_all_dirty = false;
                full_repaint_needed = false;
                break;
            }
        }

        if (row_all_dirty) {
            render_shim_region_union_rect(
                regionPtr(&dirty),
                term.margins.left,
                term.margins.top + r * term.cell_height,
                term.width - term.margins.left - term.margins.right,
                term.cell_height,
            );
        }
    }

    if (full_repaint_needed) {
        // C returns here without pixman_region32_fini(), leaking the region
        // it just built; free it before taking the same branch.
        render_shim_region_fini(regionPtr(&dirty));
        force_full_repaint(term, new_buf);
        return;
    }

    // TODO: re-apply last frame's scroll damage. We used to, but it was
    // buggy; if it comes back, the buf->dirty updates in
    // grid_render_scroll()/_reverse() have to go too.

    const pix = bufferPix(new_buf);
    const old_dirty = old.dirty.?;

    if (term.grid.?.scroll_damage.length == 0) {
        // The damage region computed above is only valid once this frame's
        // scroll damage has been applied, so only subtract it when there is
        // none.
        render_shim_region_subtract(regionPtr(&dirty), old_dirty, regionPtr(&dirty));
        render_shim_set_clip_region(pix, regionPtr(&dirty));
    } else {
        // Copy *all* of the last frame's damaged areas
        render_shim_set_clip_region(pix, old_dirty);
    }

    render_shim_composite_op(
        PIXMAN_OP_SRC,
        optPix(old.pix.?[0]),
        null,
        pix,
        0,
        0,
        0,
        0,
        term.width,
        term.height,
    );

    render_shim_set_clip_region(pix, null);
    render_shim_region_fini(regionPtr(&dirty));
}

// ─────────────────────────────────────────────────────────────────────────
// Scrollback indicator and render timer (D3k2b)
// ─────────────────────────────────────────────────────────────────────────

extern fn wayl_win_subsurface_new(
    win: *types.WlWindow,
    surf: *types.WaylSubSurface,
    allow_pointer_input: bool,
) callconv(.c) bool;
extern fn wayl_win_subsurface_destroy(surf: ?*types.WaylSubSurface) callconv(.c) void;
extern fn mbsntoc32(dst: ?[*]u32, src: [*c]const u8, nms: usize, len: usize) callconv(.c) usize;

/// `roundf(scale * ceilf(v / scale))`: snap a pixel size outwards to the
/// buffer scale.
fn snapToScale(v: c_int, scale: f32) c_int {
    return @intFromFloat(@round(scale * @ceil(@as(f32, @floatFromInt(v)) / scale)));
}

/// `roundf(v / scale)`: sub-surface positions are surface-local.
fn roundfDiv(v: c_int, scale: f32) c_int {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) / scale));
}

/// `(int)roundf(3. * scale)`: the indicator/timer padding.
fn osdMargin(scale: f32) c_int {
    return @intFromFloat(@round(@as(f64, 3.0 * scale)));
}

/// C-facing hook for the headless render parity corpus.
export fn render_parity_osd_margin(scale: f32) callconv(.c) c_int {
    return osdMargin(scale);
}

export fn render_scrollback_position(term: *Terminal) callconv(.c) void {
    const conf = term.conf.?;

    if (conf.scrollback.indicator.position == .none)
        return;

    const win = term.window.?;
    const grid = term.grid.?;

    if (grid.view == grid.offset) {
        if (win.scrollback_indicator.surface.surf != null) {
            wayl_win_subsurface_destroy(&win.scrollback_indicator);
        }
        return;
    }

    if (win.scrollback_indicator.surface.surf == null) {
        if (!wayl_win_subsurface_new(win, &win.scrollback_indicator, false)) {
            log_msg(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "failed to create scrollback indicator surface");
            return;
        }
    }

    std.debug.assert(win.scrollback_indicator.surface.surf != null);
    std.debug.assert(win.scrollback_indicator.sub != null);

    // Find the absolute row number of the scrollback start
    var scrollback_start: c_int = grid.offset + term.rows;
    var empty_rows: c_int = 0;
    while (grid.rows.?[@intCast(scrollback_start & (grid.num_rows - 1))] == null) {
        scrollback_start += 1;
        empty_rows += 1;
    }

    // Rebase the viewport against the scrollback start (so that 0 is at the
    // beginning of the scrollback)
    var rebased_view: c_int = grid.view - scrollback_start + grid.num_rows;
    rebased_view &= grid.num_rows - 1;

    // How much of the scrollback is actually used?
    const populated_rows: c_int = grid.num_rows - empty_rows;
    std.debug.assert(populated_rows > 0);
    std.debug.assert(populated_rows <= grid.num_rows);

    // How far down in the scrollback we are:
    //    0% -> at the beginning, 100% -> at the bottom
    const percent: f64 = if (rebased_view + term.rows == populated_rows)
        1.0
    else
        @as(f64, @floatFromInt(rebased_view)) /
            @as(f64, @floatFromInt(populated_rows - term.rows));

    var text_buf: [64]u32 = undefined;
    var text: [*]const u32 = &text_buf;
    var cell_count: c_int = 0;

    switch (conf.scrollback.indicator.format) {
        .percentage => {
            var str_buf: [8]u8 = undefined;
            const str = std.fmt.bufPrintZ(&str_buf, "{d}%", .{@as(c_int, @intFromFloat(100.0 * percent))}) catch unreachable;
            _ = mbsntoc32(&text_buf, str.ptr, text_buf.len, str.len);
            cell_count = 3;
        },

        .lineno => {
            var str_buf: [64]u8 = undefined;
            const str = std.fmt.bufPrintZ(&str_buf, "{d}", .{rebased_view + 1}) catch unreachable;
            _ = mbsntoc32(&text_buf, str.ptr, text_buf.len, str.len);
            cell_count = @intFromFloat(@ceil(@log10(@as(f32, @floatFromInt(grid.num_rows)))));
        },

        .text => {
            text = conf.scrollback.indicator.text.?;
            cell_count = @intCast(c32Len(text));
        },
    }

    const scale = term.scale;
    const margin = osdMargin(scale);

    var width: c_int = margin + cell_count * term.cell_width + margin;
    var height: c_int = margin + term.cell_height + margin;

    width = snapToScale(width, scale);
    height = snapToScale(height, scale);

    // Where to render - parent relative coordinates
    var surf_top: c_int = 0;
    switch (conf.scrollback.indicator.position) {
        .none => unreachable,

        .fixed => surf_top = term.cell_height - margin,

        .relative => {
            var lines: c_int = term.rows - 2; // Avoid the first and last row
            if (term.is_searching) {
                // Don't collide with the scrollback search box
                lines -= 1;
            }

            lines = @max(lines, 0);

            const pixels: c_int = @max(lines * term.cell_height - height + 2 * margin, 0);
            surf_top = term.cell_height - margin +
                @as(c_int, @intFromFloat(percent * @as(f64, @floatFromInt(pixels))));
        },
    }

    var x: c_int = term.width - margin - width;
    var y: c_int = term.margins.top + surf_top;

    x = snapToScale(x, scale);
    y = snapToScale(y, scale);

    if (y + height > term.height) {
        wayland_shim_surface_attach(win.scrollback_indicator.surface.surf, null, 0, 0);
        wayland_shim_surface_commit(win.scrollback_indicator.surface.surf);
        return;
    }

    const chain: *types.ShmBufferChain =
        @ptrCast(@alignCast(term.render.chains.scrollback_indicator.?));
    const buf = shm_get_buffer(chain, width, height) orelse return;

    wayland_shim_subsurface_set_position(win.scrollback_indicator.sub, roundfDiv(x, scale), roundfDiv(y, scale));

    var fg: u32 = term.colors.table[0];
    var bg: u32 = term.colors.table[8 + 4];
    if (conf.colors_dark.use_custom.scrollback_indicator) {
        fg = conf.colors_dark.scrollback_indicator.fg;
        bg = conf.colors_dark.scrollback_indicator.bg;
    }

    render_osd(
        term,
        &win.scrollback_indicator,
        @ptrCast(term.fonts[0]),
        buf,
        text,
        fg,
        0xff000000 | bg,
        @intCast(width - margin - @as(c_int, @intCast(c32Len(text))) * term.cell_width),
    );
}

export fn render_render_timer(term: *Terminal, render_time: Timespec) callconv(.c) void {
    const win = term.window.?;

    const usecs: f64 =
        @as(f64, @floatFromInt(render_time.tv_sec)) * 1000000.0 +
        @as(f64, @floatFromInt(render_time.tv_nsec)) / 1000.0;

    var str_buf: [256]u8 = undefined;
    const str = std.fmt.bufPrintZ(&str_buf, "{d:.2} µs", .{usecs}) catch unreachable;

    var text_buf: [256]u32 = undefined;
    _ = mbsntoc32(&text_buf, str.ptr, text_buf.len, str.len);

    const text: [*]const u32 = &text_buf;

    const scale = term.scale;
    const cell_count: c_int = @intCast(c32Len(text));
    const margin = osdMargin(scale);

    var width: c_int = margin + cell_count * term.cell_width + margin;
    var height: c_int = margin + term.cell_height + margin;

    width = snapToScale(width, scale);
    height = snapToScale(height, scale);

    const chain: *types.ShmBufferChain =
        @ptrCast(@alignCast(term.render.chains.render_timer.?));
    const buf = shm_get_buffer(chain, width, height) orelse return;

    wayland_shim_subsurface_set_position(
        win.render_timer.sub,
        roundfDiv(margin, scale),
        roundfDiv(term.margins.top + term.cell_height - margin, scale),
    );

    render_osd(
        term,
        &win.render_timer,
        @ptrCast(term.fonts[0]),
        buf,
        text,
        term.colors.table[0],
        0xff000000 | term.colors.table[8 + 1],
        @intCast(margin),
    );
}

// ─────────────────────────────────────────────────────────────────────────
// The search box (D3k3)
// ─────────────────────────────────────────────────────────────────────────

extern fn c32ncpy(dst: [*]u32, src: [*]const u32, n: usize) callconv(.c) [*]u32;
extern fn c32ncat(dst: [*]u32, src: [*]const u32, n: usize) callconv(.c) [*]u32;
extern fn c32cat(dst: [*]u32, src: [*]const u32) callconv(.c) [*]u32;
extern fn c32swidth(s: [*]const u32, n: usize) callconv(.c) c_int;
extern fn wayland_shim_set_opaque_region_rect(
    compositor: ?*anyopaque,
    surf: ?*anyopaque,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void;

/// The window-relative position of a search-box coordinate (C's WINDOW_X/Y).
fn windowX(margin: usize, x: c_int) c_int {
    return @as(c_int, @intCast(margin)) + x;
}

fn windowY(term: *const Terminal, margin: usize, height: usize, y: c_int) c_int {
    return term.height - @as(c_int, @intCast(margin)) -
        @as(c_int, @intCast(height)) + y;
}

/// The three-way adjustment of `term.render.search_glyph_offset`: keep the
/// cursor visible, then pull the offset back when free space is left. Kept
/// separate so the harness can pin the arithmetic without a compositor.
fn searchBoxGlyphOffset(
    glyph_offset_in: usize,
    visible_cells: usize,
    total_cells: usize,
    cursor_cell_idx: usize,
) usize {
    var glyph_offset = glyph_offset_in;

    if (cursor_cell_idx < glyph_offset) {
        // Shift to the *left*, making *this* character the first visible one
        glyph_offset = cursor_cell_idx;
    } else if (cursor_cell_idx > glyph_offset +| visible_cells) {
        // Shift to the *right*, making *this* character the last visible one
        glyph_offset = cursor_cell_idx - @min(cursor_cell_idx, visible_cells);
    }

    // Adjust the offset if there is free space available
    if (total_cells -| glyph_offset < visible_cells) {
        glyph_offset = total_cells -| @min(total_cells, visible_cells);
    }

    return glyph_offset;
}

export fn render_search_box_glyph_offset(
    glyph_offset: usize,
    visible_cells: usize,
    total_cells: usize,
    cursor_cell_idx: usize,
) callconv(.c) usize {
    return searchBoxGlyphOffset(glyph_offset, visible_cells, total_cells, cursor_cell_idx);
}

export fn render_search_box(term: *Terminal) callconv(.c) void {
    const win = term.window.?;
    std.debug.assert(win.search.sub != null);

    // The IME pre-edit text is merged into the search string at the cursor.
    // (C's TODO: multi-seat is not handled.)
    var ime_seat: ?*types.Seat = null;
    {
        const seats: *SeatList = @ptrCast(&term.wl.?.seats);
        var it = seats.foreach();
        while (it.next()) |node| {
            if (node.item.kbd_focus == term) {
                ime_seat = &node.item;
                break;
            }
        }
    }

    const search = &term.search;
    const preedit_text: ?[*]u32 = if (ime_seat) |s| s.ime.preedit.text else null;

    var text_len: usize = search.len;
    if (preedit_text) |pt| text_len += c32Len(pt);

    const text_raw = xmalloc((text_len + 1) * @sizeOf(u32)) orelse unreachable;
    const text: [*]u32 = @ptrCast(@alignCast(text_raw));
    text[0] = 0;

    const sbuf: [*]const u32 = search.buf orelse &empty_wtext;

    // Everything up to the cursor
    _ = c32ncpy(text, sbuf, search.cursor);
    text[search.cursor] = 0;

    // The pre-edit text goes in at the cursor ...
    if (preedit_text) |pt| _ = c32cat(text, pt);

    // ... and everything after it follows
    _ = c32ncat(text, sbuf + search.cursor, search.len - search.cursor);

    // The width of each character, in cells
    const widths_raw = xmalloc((text_len + 1) * @sizeOf(c_int)) orelse unreachable;
    const widths: [*]c_int = @ptrCast(@alignCast(widths_raw));
    for (0..text_len) |i| widths[i] = @max(0, c32width(text[i]));
    widths[text_len] = 0;

    const total_cells: usize = @intCast(c32swidth(text, text_len));
    const wanted_visible_cells: usize = @max(20, total_cells);

    const scale = term.scale;
    std.debug.assert(scale >= 1.0);
    const margin: usize = @intCast(osdMargin(scale));

    const term_width: usize = @intCast(@max(term.width, 0));
    const term_height: usize = @intCast(@max(term.height, 0));
    const cell_width: usize = @intCast(@max(term.cell_width, 1));
    const cell_height: usize = @intCast(@max(term.cell_height, 1));

    var width: usize = term_width -| 2 * margin;
    var height: usize = @min(
        term_height -| 2 * margin,
        margin + cell_height + margin,
    );

    width = @intCast(snapToScale(@intCast(width), scale));
    height = @intCast(snapToScale(@intCast(height), scale));

    const visible_width: usize = @min(
        term_width -| 2 * margin,
        margin + wanted_visible_cells * cell_width + margin,
    );

    const visible_cells: usize = (visible_width -| 2 * margin) / cell_width;
    var glyph_offset: usize = term.render.search_glyph_offset;

    const chain: *types.ShmBufferChain = @ptrCast(@alignCast(term.render.chains.search.?));
    const buf = shm_get_buffer(chain, @intCast(width), @intCast(height)) orelse return;
    const pix = bufferPix(buf);

    clipRect(pix, 0, 0, @intCast(width), @intCast(height));

    const is_match = search.match_len == text_len;
    const custom_colors = if (is_match)
        term.conf.?.colors_dark.use_custom.search_box_match
    else
        term.conf.?.colors_dark.use_custom.search_box_no_match;

    // Background - yellow on empty/match, red on mismatch (by default)
    const gamma_correct = wayl_do_linear_blending(term.wl, term.conf.?);
    const color = color_hex_to_pixman(
        if (is_match)
            (if (custom_colors) term.conf.?.colors_dark.search_box.match.bg else term.colors.table[3])
        else
            (if (custom_colors) term.conf.?.colors_dark.search_box.no_match.bg else term.colors.table[1]),
        gamma_correct,
    );

    fillRect(pix, &color, &.{.{
        .x = @intCast(width - visible_width),
        .y = 0,
        .width = @intCast(visible_width),
        .height = @intCast(height),
    }});

    const transparent = color_hex_to_pixman_with_alpha(0, 0, gamma_correct);
    fillRect(pix, &transparent, &.{.{
        .x = 0,
        .y = 0,
        .width = @intCast(width - visible_width),
        .height = @intCast(height),
    }});

    const font: ?*FcftFont = @ptrCast(term.fonts[0]);
    const x_left: c_int = @intCast(width - visible_width + margin);
    const x_ofs: c_int = term.font_x_ofs;
    var x: c_int = x_left;
    const y: c_int = @intCast(margin);

    const fg = color_hex_to_pixman(
        if (custom_colors)
            (if (is_match) term.conf.?.colors_dark.search_box.match.fg else term.conf.?.colors_dark.search_box.no_match.fg)
        else
            term.colors.table[0],
        gamma_correct,
    );

    // Move the offset we start rendering at, to ensure the cursor is visible
    {
        var i: usize = 0;
        var cell_idx: usize = 0;
        while (i <= search.cursor) : (i += 1) {
            if (i == search.cursor) {
                if (ime_seat) |s| {
                    if (s.ime.preedit.cells != null) {
                        if (s.ime.preedit.cursor.start == s.ime.preedit.cursor.end) {
                            // All IMEs seen so far keep the cursor at index 0,
                            // so ensure the *end* of the pre-edit is visible
                            cell_idx += @intCast(@max(s.ime.preedit.count, 0));
                        } else if (cell_idx +
                            @as(usize, @intCast(@max(s.ime.preedit.cursor.start, 0))) > glyph_offset)
                        {
                            // Predict which way the text will shift
                            cell_idx += @intCast(@max(s.ime.preedit.cursor.end, 0));
                        } else {
                            cell_idx += @intCast(@max(s.ime.preedit.cursor.start, 0));
                        }
                    }
                }

                glyph_offset = searchBoxGlyphOffset(glyph_offset, visible_cells, total_cells, cell_idx);
                term.render.search_glyph_offset = glyph_offset;

                break;
            }

            cell_idx += @intCast(widths[i]);
        }
    }

    // Ensure the offset is at a character boundary
    {
        var i: usize = 0;
        var cell_idx: usize = 0;
        while (i <= text_len) : (i += 1) {
            if (cell_idx >= glyph_offset) {
                glyph_offset = cell_idx;
                term.render.search_glyph_offset = glyph_offset;
                break;
            }
            cell_idx += @intCast(widths[i]);
        }
    }

    // Render the search string, starting at 'glyph_offset' (in cells)
    var i: usize = 0;
    var cell_idx: usize = 0;
    var ch_width: c_int = widths[0];
    var next_cell_idx: usize = @intCast(@max(ch_width, 0));

    while (i < text_len) : ({
        i += 1;
        cell_idx = next_cell_idx;
        ch_width = widths[i];
        next_cell_idx += @intCast(@max(ch_width, 0));
    }) {
        // Render the cursor
        if (i == search.cursor) {
            const have_preedit = if (ime_seat) |s| s.ime.preedit.cells != null else false;
            const hidden = if (ime_seat) |s| s.ime.preedit.cursor.hidden else false;

            if (have_preedit and !hidden) {
                const s = ime_seat.?;

                // The cursor may be outside the visible area:
                // cell_idx - glyph_offset can be negative
                const diff: i64 =
                    @as(i64, @intCast(cell_idx)) - @as(i64, @intCast(glyph_offset));
                const cells_left: c_int = @intCast(
                    @as(i64, @intCast(visible_cells)) - @max(diff, 0),
                );

                const start: c_int = s.ime.preedit.cursor.start +
                    @as(c_int, @intCast(@min(diff, 0)));
                const end: c_int = s.ime.preedit.cursor.end +
                    @as(c_int, @intCast(@min(diff, 0)));

                if (start == end) {
                    const count: c_int = @min(s.ime.preedit.count, cells_left);

                    // Underline the entire visible part of the pre-edit text
                    draw_underline(term, pix, font.?, &fg, x, y, count);

                    // Bar-styled cursor, if in the visible area
                    if (start >= 0 and start <= @as(c_int, @intCast(visible_cells))) {
                        draw_beam_cursor(term, pix, font.?, &fg, x + start * term.cell_width, y);
                    }

                    term_ime_set_cursor_rect(
                        term,
                        windowX(margin, x + start * term.cell_width),
                        windowY(term, margin, height, y),
                        1,
                        term.cell_height,
                    );
                } else {
                    // Underline everything before and after the cursor
                    const count1: c_int = @min(start, cells_left);
                    const count2: c_int = @max(@min(
                        s.ime.preedit.count - s.ime.preedit.cursor.end,
                        cells_left - end,
                    ), 0);

                    draw_underline(term, pix, font.?, &fg, x, y, count1);
                    draw_underline(term, pix, font.?, &fg, x + end * term.cell_width, y, count2);

                    // TODO: partially hidden rectangles
                    if (start >= 0 and end <= @as(c_int, @intCast(visible_cells))) {
                        draw_hollow_block(term, pix, &fg, x + start * term.cell_width, y, end - start);
                    }

                    term_ime_set_cursor_rect(
                        term,
                        windowX(margin, x + start * term.cell_width),
                        windowY(term, margin, height, y),
                        term.cell_width * (end - start),
                        term.cell_height,
                    );
                }
            } else if (!have_preedit) {
                // The cursor *should* be in the visible area
                std.debug.assert(cell_idx >= glyph_offset);
                std.debug.assert(cell_idx <= glyph_offset + visible_cells);

                draw_beam_cursor(term, pix, font.?, &fg, x, y);
                term_ime_set_cursor_rect(term, windowX(margin, x), windowY(term, margin, height, y), 1, term.cell_height);
            }
        }

        if (next_cell_idx >= glyph_offset and
            next_cell_idx - glyph_offset > visible_cells)
        {
            // Beyond the visible area - nothing more to render
            break;
        }

        if (cell_idx < glyph_offset) {
            // Not yet at the visible part of the string
            continue;
        }

        const glyph = fcft_rasterize_char_utf32(font.?, text[i], term.font_subpixel) orelse continue;

        if (glyph.is_color_glyph) {
            render_shim_composite(
                optPix(glyph.pix),
                null,
                pix,
                x + x_ofs + glyph.x,
                y + @as(c_int, term.font_baseline) - glyph.y,
                glyph.width,
                glyph.height,
            );
        } else {
            // Zero-width characters need an extra offset
            const combining_ofs: c_int = if (ch_width == 0)
                (if (glyph.x < 0)
                    ch_width * term.cell_width
                else
                    (ch_width - 1) * term.cell_width)
            else
                0;

            const src = render_shim_solid_fill(&fg).?;
            render_shim_composite(
                src,
                optPix(glyph.pix),
                pix,
                x + x_ofs + combining_ofs + glyph.x,
                y + @as(c_int, term.font_baseline) - glyph.y,
                glyph.width,
                glyph.height,
            );
            render_shim_image_unref(src);
        }

        x += ch_width * term.cell_width;
    }

    const have_preedit_cells =
        if (ime_seat) |s| s.ime.preedit.cells != null else false;

    if (!have_preedit_cells and search.cursor >= search.len) {
        draw_beam_cursor(term, pix, font.?, &fg, x, y);
        term_ime_set_cursor_rect(term, windowX(margin, x), windowY(term, margin, height, y), 1, term.cell_height);
    }

    quirk_weston_subsurface_desync_on(win.search.sub);

    // TODO: this is only necessary on a window resize
    wayland_shim_subsurface_set_position(
        win.search.sub,
        roundfDiv(@intCast(margin), scale),
        roundfDiv(@max(
            term.height - @as(c_int, @intCast(height)) - @as(c_int, @intCast(margin)),
            0,
        ), scale),
    );

    wayl_surface_scale(win, &win.search.surface, buf, scale);
    wayland_shim_surface_attach(win.search.surface.surf, buf.wl_buf, 0, 0);
    wayland_shim_surface_damage_buffer(win.search.surface.surf, 0, 0, @intCast(width), @intCast(height));

    wayland_shim_set_opaque_region_rect(
        term.wl.?.compositor,
        win.search.surface.surf,
        @intCast(width - visible_width),
        0,
        @intCast(visible_width),
        @intCast(height),
    );

    wayland_shim_surface_commit(win.search.surface.surf);
    quirk_weston_subsurface_desync_off(win.search.sub);

    free(text_raw);
    free(widths_raw);
}

// ─────────────────────────────────────────────────────────────────────────
// URL jump labels (D3k4)
// ─────────────────────────────────────────────────────────────────────────

extern fn c32cpy(dst: [*]u32, src: [*]const u32) callconv(.c) [*]u32;
extern fn c32ncasecmp(s1: [*]const u32, s2: [*]const u32, n: usize) callconv(.c) c_int;
extern fn toc32upper(c: u32) callconv(.c) u32;

const ELLIPSIS: u32 = 0x2026;
const colon_space = [_:0]u32{ ':', ' ' };

/// One label's geometry and text, built in the first pass so the second pass
/// can allocate all buffers at once with shm_get_many().
const UrlLabel = extern struct {
    url: *const types.WlUrl,
    text: [*]u32,
    x: c_int,
    y: c_int,
};

/// Builds the jump-label text in `label` and returns how many cells it
/// occupies, or 0 when nothing is left to show. The buffer must hold
/// `key_len + 2 + url_len + 1` chars. The label is the upper-cased key, then
/// ": " and the URL (or just the key), with the already-entered key
/// characters blanked and an ellipsis where it overflows `max_cols`.
fn buildUrlLabel(
    label: [*]u32,
    key: [*]const u32,
    url_wchars: [*]const u32,
    show_url: bool,
    entered_key_len: usize,
    max_cols: c_int,
) c_int {
    const key_len = c32Len(key);
    const chars: usize = key_len + (if (show_url) 2 + c32Len(url_wchars) else 0);
    label[chars] = 0;

    if (show_url) {
        _ = c32cpy(label, key);
        _ = c32cat(label, &colon_space);
        _ = c32cat(label, url_wchars);
    } else {
        _ = c32ncpy(label, key, chars);
    }

    // Upper case the key characters
    var i: usize = 0;
    while (i < key_len) : (i += 1)
        label[i] = toc32upper(label[i]);

    // Blank the characters the user has already typed
    i = 0;
    while (i < entered_key_len) : (i += 1)
        label[i] = ' ';

    // Truncate so the label does not extend outside the window, without
    // cutting a double-width character in half
    var cols: c_int = 0;
    i = 0;
    while (i <= c32Len(label)) : (i += 1) {
        const width_so_far: c_int = c32swidth(label, i);

        if (width_so_far == -1)
            continue;

        if (width_so_far >= max_cols) {
            if (i > 0)
                label[i - 1] = ELLIPSIS;
            label[i] = 0;
            cols = max_cols;
            break;
        }

        cols = width_so_far;
    }

    return cols;
}

/// Same as buildUrlLabel(), with a C-friendly signature, for the harness.
export fn render_url_format_label(
    label: [*]u32,
    key: [*]const u32,
    url: ?[*]const u32,
    show_url: bool,
    entered_key_len: usize,
    max_cols: c_int,
) callconv(.c) c_int {
    return buildUrlLabel(label, key, url orelse &empty_wtext, show_url, entered_key_len, max_cols);
}

export fn render_urls(term: *Terminal) callconv(.c) void {
    const win = term.window.?;
    const urls: *tll.Tll(types.WlUrl) = @ptrCast(&win.urls);
    const url_count = urls.len();
    std.debug.assert(url_count > 0);

    const scale = term.scale;
    const x_margin: c_int = @intFromFloat(@round(2.0 * @as(f64, scale)));
    const y_margin: c_int = @intFromFloat(@round(1.0 * @as(f64, scale)));

    const grid = term.grid.?;

    // View start, counted from the *current* scrollback start
    const scrollback_end: c_int = (grid.offset + term.rows) & (grid.num_rows - 1);
    const view_start: c_int =
        (grid.view - scrollback_end + grid.num_rows) & (grid.num_rows - 1);
    const view_end: c_int = view_start + term.rows - 1;

    const show_url = term.url.show_uri_on_jump_label;
    const entered_key_len = c32Len(&term.url.keys);

    // Pass one: build each label and its geometry, but do not render yet.
    const info_raw = xmalloc(url_count * @sizeOf(UrlLabel)) orelse unreachable;
    const info: [*]UrlLabel = @ptrCast(@alignCast(info_raw));
    const widths_raw = xmalloc(url_count * @sizeOf(c_int)) orelse unreachable;
    const widths: [*]c_int = @ptrCast(@alignCast(widths_raw));
    const heights_raw = xmalloc(url_count * @sizeOf(c_int)) orelse unreachable;
    const heights: [*]c_int = @ptrCast(@alignCast(heights_raw));

    var render_count: usize = 0;

    var it = urls.foreach();
    while (it.next()) |node| {
        const item = &node.item;
        const url: *const types.Url = @ptrCast(@alignCast(item.url orelse continue));
        const key = url.key orelse continue;

        const surf = item.surf.surface.surf;
        const sub_surf = item.surf.sub;
        if (surf == null or sub_surf == null)
            continue;

        var hide = false;
        const pos = &url.range.start;
        const row_abs: c_int =
            (pos.row - scrollback_end + grid.num_rows) & (grid.num_rows - 1);

        if (row_abs < view_start or row_abs > view_end)
            hide = true;
        if (c32Len(key) <= entered_key_len)
            hide = true;
        if (c32ncasecmp(&term.url.keys, key, entered_key_len) != 0)
            hide = true;

        if (hide) {
            wayland_shim_surface_attach(surf, null, 0, 0);
            wayland_shim_surface_commit(surf);
            continue;
        }

        const col: c_int = pos.col;
        var row: c_int = pos.row - grid.view;
        while (row < 0)
            row += grid.num_rows;
        row &= grid.num_rows - 1;

        // Position the label slightly above and to the left
        var x: c_int = col * term.cell_width - @divTrunc(15 * term.cell_width, 10);
        var y: c_int = row * term.cell_height - @divTrunc(5 * term.cell_height, 10);

        // Don't position it outside our window
        if (x < -term.margins.left)
            x = -term.margins.left;
        if (y < -term.margins.top)
            y = -term.margins.top;

        // Maximum width of the label, in pixels
        const max_width: c_int =
            term.width - term.margins.left - term.margins.right - x;
        const max_cols: c_int = @divTrunc(max_width, term.cell_width);

        const key_len = c32Len(key);
        const url_str = url.url orelse continue;
        const url_str_len = std.mem.len(url_str);

        var url_len: usize = mbsntoc32(null, url_str, url_str_len + 1, 0);
        if (url_len == std.math.maxInt(usize))
            url_len = 0;

        const url_wchars_raw = xmalloc((url_len + 1) * @sizeOf(u32)) orelse unreachable;
        const url_wchars: [*]u32 = @ptrCast(@alignCast(url_wchars_raw));
        _ = mbsntoc32(url_wchars, url_str, url_str_len + 1, url_len + 1);

        // Format the label, not yet subject to any size limitations
        const label_raw = xmalloc(
            (key_len + (if (show_url) 2 + url_len else 0) + 1) * @sizeOf(u32),
        ) orelse unreachable;
        const label: [*]u32 = @ptrCast(@alignCast(label_raw));

        const cols = buildUrlLabel(label, key, url_wchars, show_url, entered_key_len, max_cols);

        free(url_wchars_raw);

        if (cols == 0) {
            free(label_raw);
            continue;
        }

        const width: c_int = snapToScale(x_margin + cols * term.cell_width + x_margin, scale);
        const height: c_int = snapToScale(y_margin + term.cell_height + y_margin, scale);

        // The label buffer is heap allocated (C's was a VLA and got copied
        // with xc32dup()); it is freed by the second pass.
        info[render_count] = .{
            .url = item,
            .text = label,
            .x = x,
            .y = y,
        };
        widths[render_count] = width;
        heights[render_count] = height;
        render_count += 1;
    }

    if (render_count == 0) {
        free(info_raw);
        free(widths_raw);
        free(heights_raw);
        return;
    }

    // Pass two: one shared SHM pool for every label
    const chain: *types.ShmBufferChain = @ptrCast(@alignCast(term.render.chains.url.?));
    const bufs_raw = xmalloc(render_count * @sizeOf(?*Buffer)) orelse unreachable;
    const bufs: [*]?*Buffer = @ptrCast(@alignCast(bufs_raw));

    shm_get_many(chain, render_count, widths, heights, bufs);

    const fg: u32 = if (term.conf.?.colors_dark.use_custom.jump_label)
        term.conf.?.colors_dark.jump_label.fg
    else
        term.colors.table[0];
    const bg: u32 = if (term.conf.?.colors_dark.use_custom.jump_label)
        term.conf.?.colors_dark.jump_label.bg
    else
        term.colors.table[3];

    var n: usize = 0;
    while (n < render_count) : (n += 1) {
        const sub_surf = &info[n].url.surf;
        const label = info[n].text;
        const x = info[n].x;
        const y = info[n].y;

        std.debug.assert(sub_surf.surface.surf != null);
        std.debug.assert(sub_surf.sub != null);

        const buf = bufs[n] orelse {
            free(@ptrCast(label));
            continue;
        };

        wayland_shim_subsurface_set_position(
            sub_surf.sub,
            roundfDiv(term.margins.left + x, scale),
            roundfDiv(term.margins.top + y, scale),
        );

        render_osd(
            term,
            sub_surf,
            @ptrCast(term.fonts[0]),
            buf,
            label,
            fg,
            0xff000000 | bg,
            @intCast(x_margin),
        );

        free(@ptrCast(label));
    }

    free(info_raw);
    free(widths_raw);
    free(heights_raw);
    free(bufs_raw);
}

// ─────────────────────────────────────────────────────────────────────────
// Size notifications (D3l3a)
// ─────────────────────────────────────────────────────────────────────────

extern fn render_shim_tiocswinsz(ptmx: c_int, rows: c_int, cols: c_int, xpixel: c_int, ypixel: c_int) callconv(.c) c_int;
extern fn term_send_size_notification(term: *Terminal) callconv(.c) void;
extern fn term_ptmx_pause(term: *Terminal) callconv(.c) void;
extern fn term_ptmx_resume(term: *Terminal) callconv(.c) void;
extern fn sixel_reflow_grid(term: *Terminal, grid: *types.Grid) callconv(.c) void;
extern fn grid_free(grid: ?*types.Grid) callconv(.c) void;
extern fn grid_resize_and_reflow(
    grid: *types.Grid,
    term: *Terminal,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
    tracking_points_count: usize,
    tracking_points: ?[*]const *types.Coord,
) callconv(.c) void;
extern fn fdm_add(
    fdm: *anyopaque,
    fd: c_int,
    events: c_int,
    handler: *const fn (*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) bool,
    data: ?*anyopaque,
) callconv(.c) bool;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;
extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
extern fn close(fd: c_int) callconv(.c) c_int;

const EPOLLIN: c_int = 0x001;
const TFD_CLOEXEC: c_int = 0x80000;
const TFD_NONBLOCK: c_int = 0x800;

/// TIOCSWINSZ on the pty master, then the size-notification escape (if any).
export fn tiocswinsz(term: *Terminal) callconv(.c) void {
    if (term.ptmx < 0)
        return;

    if (render_shim_tiocswinsz(term.ptmx, term.rows, term.cols, term.cols * term.cell_width, term.rows * term.cell_height) < 0) {
        log_errno(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "TIOCSWINSZ");
    }

    term_send_size_notification(term);
}

/// Finish an interactive resize: reflow the grid stashed when the resize
/// started to the *current* dimensions, and swap it back in.
export fn delayed_reflow_of_normal_grid(term: *Terminal) callconv(.c) void {
    const resizing = &term.interactive_resizing;
    if (resizing.grid == null)
        return;

    std.debug.assert(resizing.new_rows > 0);

    if (term.grid == &term.normal)
        term.selection.coords = resizing.selection_coords;

    var tracking_points = [_]*types.Coord{
        &term.selection.coords.start,
        &term.selection.coords.end,
    };

    grid_resize_and_reflow(
        resizing.grid.?,
        term,
        resizing.new_rows,
        term.normal.num_cols,
        resizing.old_screen_rows,
        term.rows,
        if (term.selection.coords.end.row >= 0) tracking_points.len else 0,
        &tracking_points,
    );

    // Replace the current, truncated, "normal" grid with the reflowed one
    grid_free(&term.normal);
    term.normal = resizing.grid.?.*;
    free(resizing.grid.?);

    term.hide_cursor = resizing.old_hide_cursor != 0;

    // Reset
    resizing.grid = null;
    resizing.old_screen_rows = 0;
    resizing.new_rows = 0;
    resizing.old_hide_cursor = 0;
    resizing.selection_coords = .{
        .start = .{ .col = -1, .row = -1 },
        .end = .{ .col = -1, .row = -1 },
    };

    // Invalidate render pointers
    render_wait_for_preapply_damage(term);
    if (term.render.last_buf) |raw| {
        shm_unref(@ptrCast(@alignCast(raw)));
        term.render.last_buf = null;
    }
    term.render.last_cursor.row = null;

    const scroll_damage: *tll.Tll(types.Damage) = @ptrCast(&term.normal.scroll_damage);
    scroll_damage.freeList();

    sixel_reflow_grid(term, &term.normal);

    if (term.grid == &term.normal) {
        term_damage_view(term);
        render_refresh(term);
    }

    term_ptmx_resume(term);
}

/// The TIOCSWINSZ timer fired: the interactive resize paused long enough to
/// apply the real size and reflow.
export fn fdm_tiocswinsz(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fd;
    const term: *Terminal = @ptrCast(@alignCast(data orelse return false));

    if (events & EPOLLIN != 0) {
        tiocswinsz(term);
        delayed_reflow_of_normal_grid(term);
    }

    const win = term.window.?;
    if (win.resize_timeout_fd >= 0) {
        _ = fdm_del(fdm.?, win.resize_timeout_fd);
        win.resize_timeout_fd = -1;
    }
    return true;
}

/// Tell the client about the new terminal size: immediately, or after
/// `resize_delay_ms` of silence while an interactive resize is in progress.
export fn send_dimensions_to_client(term: *Terminal) callconv(.c) void {
    const win = term.window.?;
    const conf = term.conf.?;

    if (!win.is_resizing or conf.resize_delay_ms == 0) {
        // Send new dimensions to client immediately
        tiocswinsz(term);
        delayed_reflow_of_normal_grid(term);

        // And make sure to reset and deallocate a lingering timer
        if (win.resize_timeout_fd >= 0) {
            _ = fdm_del(term.fdm.?, win.resize_timeout_fd);
            win.resize_timeout_fd = -1;
        }
        return;
    }

    // Send new dimensions to client "in a while"
    std.debug.assert(win.is_resizing and conf.resize_delay_ms > 0);

    var fd = win.resize_timeout_fd;
    const delay_ms: u16 = conf.resize_delay_ms;
    var successfully_scheduled = false;

    if (fd < 0) {
        // Lazy create timer fd
        fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        if (fd < 0) {
            log_errno(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "failed to create TIOCSWINSZ timer");
        } else if (!fdm_add(term.fdm.?, fd, EPOLLIN, &fdm_tiocswinsz, term)) {
            _ = close(fd);
            fd = -1;
        }

        win.resize_timeout_fd = fd;
    }

    if (fd >= 0) {
        // Reset timeout
        const timeout = Itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{
                .tv_sec = @intCast(@divTrunc(delay_ms, 1000)),
                .tv_nsec = @intCast(@as(u32, delay_ms % 1000) * 1_000_000),
            },
        };

        if (timerfd_settime(fd, 0, &timeout, null) < 0) {
            log_errno(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "failed to arm TIOCSWINSZ timer");
            _ = fdm_del(term.fdm.?, fd);
            win.resize_timeout_fd = -1;
        } else {
            successfully_scheduled = true;
        }
    }

    if (!successfully_scheduled) {
        tiocswinsz(term);
        delayed_reflow_of_normal_grid(term);
    }
}

/// The window size a `cols` x `rows` grid needs, padding and scale included.
/// (C keeps the running value in an `int`, so the padding term is truncated
/// before the scale rounding - mirrored here with an int accumulator.)
export fn set_size_from_grid(
    term: *Terminal,
    width: ?*c_int,
    height: ?*c_int,
    cols: c_int,
    rows: c_int,
) callconv(.c) void {
    const conf = term.conf.?;
    const scale: f32 = term.scale;

    // Nominal grid dimensions
    var new_width: c_int = cols * term.cell_width;
    var new_height: c_int = rows * term.cell_height;

    // C multiplies padding in float, truncates it, then adds it to the
    // integer grid size. Keep both steps in that order.
    const pad_w: c_int = @intFromFloat(@as(f32, @floatFromInt(conf.pad_left + conf.pad_right)) * scale);
    const pad_h: c_int = @intFromFloat(@as(f32, @floatFromInt(conf.pad_top + conf.pad_bottom)) * scale);
    new_width += pad_w;
    new_height += pad_h;

    // The inner division is float; only round() widens to double.
    new_width = @intFromFloat(@round(@as(f64, scale) * @round(@as(f64, @as(f32, @floatFromInt(new_width)) / scale))));
    new_height = @intFromFloat(@round(@as(f64, scale) * @round(@as(f64, @as(f32, @floatFromInt(new_height)) / scale))));

    if (width) |w| w.* = new_width;
    if (height) |h| h.* = new_height;
}
// ─────────────────────────────────────────────────────────────────────────
// render_resize (D3l3b)
// ─────────────────────────────────────────────────────────────────────────

const RESIZE_FORCE: u8 = 1 << 0;
const RESIZE_BY_CELLS: u8 = 1 << 1;
const RESIZE_KEEP_GRID: u8 = 1 << 2;

extern fn mouse_coord_pixel_to_cell(seat: *anyopaque, term: *const Terminal, x: c_int, y: c_int) callconv(.c) void;
extern fn term_disable_app_sync_updates(term: *Terminal) callconv(.c) void;
extern fn urls_reset(term: *Terminal) callconv(.c) void;
extern fn selection_cancel(term: *Terminal) callconv(.c) void;
extern fn selection_finalize(seat: ?*anyopaque, term: *Terminal, serial: u32) callconv(.c) void;
extern fn grid_row_alloc(cols: c_int, initialize: bool) callconv(.c) *types.Row;
extern fn grid_resize_without_reflow(
    grid: *types.Grid,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
) callconv(.c) void;
extern fn sixel_reflow(term: *Terminal) callconv(.c) void;
extern fn wayland_shim_xdg_toplevel_set_min_size(toplevel: ?*anyopaque, width: c_int, height: c_int) callconv(.c) void;
extern fn wayland_shim_xdg_surface_set_window_geometry(surface: ?*anyopaque, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void;

fn roundF(v: f64) c_int {
    return @intFromFloat(@round(v));
}

/// `roundf(v)`: multiply or divide in f32, then widen for round().
fn roundfF(v: f32) c_int {
    return @intFromFloat(@round(@as(f64, v)));
}

/// next power of two >= n, as C's `1 << (32 - __builtin_clz(n))`.
fn ceilPow2(n: u32) u32 {
    std.debug.assert(n > 0);
    return @as(u32, 1) << @intCast(32 - @clz(n));
}

/// The configure/resize entry point: work out the window size the compositor
/// asked for, derive the grid from it, resize both grids (reflowing the
/// normal one, truncating while an interactive resize is in progress) and
/// tell the client + compositor about the result.
export fn render_resize(
    term: *Terminal,
    width_in: c_int,
    height_in: c_int,
    opts: u8,
) callconv(.c) bool {
    if (term.shutdown.in_progress)
        return false;

    const window = term.window.?;
    const conf = term.conf.?;

    if (!window.is_configured)
        return false;

    if (term.cell_width == 0 and term.cell_height == 0)
        return false;

    const is_floating =
        !window.is_maximized and
        !window.is_fullscreen and
        !window.is_tiled;

    // Convert logical size to physical size
    // C multiplies in `float` and only the round() call widens; a f64
    // multiply can land on the other side of a rounding boundary at the
    // fractional-scaling values (e.g. 1.05f: C 11, f64 10).
    const scale: f32 = term.scale;
    var width: c_int = roundF(@as(f64, @as(f32, @floatFromInt(width_in)) * scale));
    var height: c_int = roundF(@as(f64, @as(f32, @floatFromInt(height_in)) * scale));

    // If the grid should be kept, the size should be overridden
    if (is_floating and (opts & RESIZE_KEEP_GRID) != 0)
        set_size_from_grid(term, &width, &height, term.cols, term.rows);

    if (width == 0) {
        // The compositor is letting us choose the width
        if (term.stashed_width != 0) {
            // If a default size is requested, prefer the "last used" size
            width = term.stashed_width;
        } else switch (conf.size.type) {
            .px => {
                width = @intCast(conf.size.width);

                if (wayl_win_csd_borders_visible(window))
                    width -= 2 * @as(c_int, conf.csd.border_width_visible);

                width = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
            },
            .cells => set_size_from_grid(
                term,
                &width,
                null,
                @intCast(conf.size.width),
                @intCast(conf.size.height),
            ),
        }
    }

    if (height == 0) {
        // The compositor is letting us choose the height
        if (term.stashed_height != 0) {
            // If a default size is requested, prefer the "last used" size
            height = term.stashed_height;
        } else switch (conf.size.type) {
            .px => {
                height = @intCast(conf.size.height);

                // Take CSDs into account
                if (wayl_win_csd_titlebar_visible(window))
                    height -= @as(c_int, conf.csd.title_height);

                if (wayl_win_csd_borders_visible(window))
                    height -= 2 * @as(c_int, conf.csd.border_width_visible);

                height = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);
            },
            .cells => set_size_from_grid(
                term,
                null,
                &height,
                @intCast(conf.size.width),
                @intCast(conf.size.height),
            ),
        }
    }

    // Don't shrink the grid too much
    const min_cols: c_int = 1;
    const min_rows: c_int = 1;

    // Minimum window size (must be divisible by the scaling factor)
    const min_width: c_int = roundF(scale * @ceil(@as(f64, @floatFromInt(min_cols * term.cell_width)) / scale));
    const min_height: c_int = roundF(scale * @ceil(@as(f64, @floatFromInt(min_rows * term.cell_height)) / scale));

    width = @max(width, min_width);
    height = @max(height, min_height);

    // Padding
    const max_pad_x: c_int = @divTrunc(width - min_width, 2);
    const max_pad_y: c_int = @divTrunc(height - min_height, 2);
    const pad_left: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(max_pad_x)), scale * @as(f64, @floatFromInt(conf.pad_left))));
    const pad_right: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(max_pad_x)), scale * @as(f64, @floatFromInt(conf.pad_right))));
    const pad_top: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(max_pad_y)), scale * @as(f64, @floatFromInt(conf.pad_top))));
    const pad_bottom: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(max_pad_y)), scale * @as(f64, @floatFromInt(conf.pad_bottom))));

    if (is_floating and
        (opts & RESIZE_BY_CELLS) != 0 and
        conf.resize_by_cells)
    {
        // If resizing in cell increments, restrict the width and height
        width = @divTrunc(width - (pad_left + pad_right), term.cell_width) *
            term.cell_width + (pad_left + pad_right);
        width = @max(min_width, roundF(scale * @round(@as(f64, @floatFromInt(width)) / scale)));

        height = @divTrunc(height - (pad_top + pad_bottom), term.cell_height) *
            term.cell_height + (pad_top + pad_bottom);
        height = @max(min_height, roundF(scale * @round(@as(f64, @floatFromInt(height)) / scale)));
    }

    if ((opts & RESIZE_FORCE) == 0 and
        width == term.width and
        height == term.height and
        scale == @as(f64, term.scale))
    {
        return false;
    }

    // Cancel an application initiated "Synchronized Update"
    term_disable_app_sync_updates(term);

    // Drop out of URL mode
    urls_reset(term);

    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "resized: size=%dx%d (scale=%.2f)", width, height, term.scale);

    term.width = width;
    term.height = height;

    // Screen rows/cols before resize
    const old_cols = term.cols;
    const old_rows = term.rows;

    // Screen rows/cols after resize
    const new_cols: c_int = @divTrunc(term.width - (pad_left + pad_right), term.cell_width);
    const new_rows: c_int = @divTrunc(term.height - (pad_top + pad_bottom), term.cell_height);

    // Requirements for scrollback: the total number of rows (visible +
    // scrollback) must be a power of two and representable in a signed int.
    const max_scrollback: u32 = (@as(u32, 0x7fffffff) >> 1) + 1;
    const scrollback_lines_not_yet_power_of_two: u32 = @min(
        @as(u64, term.render.scrollback_lines) + @as(u64, @intCast(new_rows)) - 1,
        @as(u64, max_scrollback),
    );

    // Grid rows/cols after resize
    const new_normal_grid_rows: c_int = @intCast(@min(ceilPow2(scrollback_lines_not_yet_power_of_two), max_scrollback));
    const new_alt_grid_rows: c_int = @intCast(@min(ceilPow2(@intCast(new_rows)), max_scrollback));

    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "grid rows: %d", new_normal_grid_rows);

    std.debug.assert(new_cols >= 1);
    std.debug.assert(new_rows >= 1);

    // Margins
    const grid_width = new_cols * term.cell_width;
    const grid_height = new_rows * term.cell_height;
    const total_x_pad = term.width - grid_width;
    const total_y_pad = term.height - grid_height;

    const centered_padding =
        conf.center_when == .always or
        (conf.center_when == .maximized_and_fullscreen and
            (window.is_fullscreen or window.is_maximized)) or
        (conf.center_when == .fullscreen and window.is_fullscreen);

    if (centered_padding and !window.is_resizing) {
        term.margins.left = @divTrunc(total_x_pad, 2);
        term.margins.top = @divTrunc(total_y_pad, 2);
    } else {
        term.margins.left = pad_left;
        term.margins.top = pad_top;
    }
    term.margins.right = total_x_pad - term.margins.left;
    term.margins.bottom = total_y_pad - term.margins.top;

    std.debug.assert(term.margins.left >= pad_left);
    std.debug.assert(term.margins.right >= pad_right);
    std.debug.assert(term.margins.top >= pad_top);
    std.debug.assert(term.margins.bottom >= pad_bottom);

    var skip_reflow = false;

    if (new_cols == old_cols and new_rows == old_rows) {
        log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "grid layout unaffected; skipping reflow");
        term.interactive_resizing.new_rows = new_normal_grid_rows;
        skip_reflow = true;
    }

    if (!skip_reflow) {
        // Since text reflow is slow, don't do it *while* resizing. Only do it
        // when done, or after "pausing" the resize for long enough (the
        // TIOCSWINSZ timer, see send_dimensions_to_client()). To be able to
        // do the final reflow correctly we need a copy of the grid as it was
        // before the resize started.
        if (window.is_resizing and conf.resize_delay_ms > 0) {
            const resizing = &term.interactive_resizing;

            if (resizing.grid == null) {
                term_ptmx_pause(term);

                // Stash the current 'normal' grid, as-is, to be used when
                // doing the final reflow
                resizing.old_screen_rows = term.rows;
                resizing.old_cols = term.cols;
                resizing.old_hide_cursor = @intFromBool(term.hide_cursor);
                const stash: *types.Grid = @ptrCast(@alignCast(xmalloc(@sizeOf(types.Grid)).?));
                stash.* = term.normal;
                resizing.grid = stash;

                if (term.grid == &term.normal) {
                    resizing.selection_coords = term.selection.coords;
                    term.selection.coords.start.row -= term.grid.?.view;
                    term.selection.coords.end.row -= term.grid.?.view;
                }
            } else {
                // We'll replace the current temporary grid, with a new one
                // (again based on the original grid)
                grid_free(&term.normal);
            }

            const orig = resizing.grid.?;

            // Copy the current viewport (of the original grid) to a new grid
            // that is used during the resize. Sixels and OSC-8 URLs are
            // thrown away here; they are restored by the final reflow.
            var g = std.mem.zeroes(types.Grid);
            g.num_rows = @intCast(ceilPow2(@intCast(resizing.old_screen_rows)));
            g.num_cols = resizing.old_cols;
            g.offset = 0;
            g.view = 0;
            g.cursor = orig.cursor;
            g.saved_cursor = orig.saved_cursor;
            g.rows = @ptrCast(@alignCast(xcalloc(@intCast(g.num_rows), @sizeOf(?*types.Row)).?));
            g.cur_row = null;
            g.kitty_kbd = orig.kitty_kbd;

            var i: usize = 0;
            var j: c_int = orig.view;
            while (i < @as(usize, @intCast(resizing.old_screen_rows))) : ({
                i += 1;
                j = (j + 1) & (orig.num_rows - 1);
            }) {
                const dst_row = grid_row_alloc(g.num_cols, false);
                g.rows.?[i] = dst_row;

                const n_cells: usize = @intCast(g.num_cols);
                @memcpy(
                    dst_row.cells.?[0..n_cells],
                    orig.rows.?[@intCast(j)].?.cells.?[0..n_cells],
                );

                const src_extra = orig.rows.?[@intCast(j)].?.extra;
                if (src_extra) |ex| {
                    const src = &ex.underline_ranges;
                    if (src.count != 0) {
                        // Copy underline ranges
                        const count: usize = @intCast(src.count);
                        const dst_extra: *types.RowData = @ptrCast(@alignCast(xcalloc(1, @sizeOf(types.RowData)).?));
                        dst_row.extra = dst_extra;

                        const dst = &dst_extra.underline_ranges;
                        const v: [*]types.RowRange = @ptrCast(@alignCast(xmalloc(count * @sizeOf(types.RowRange)).?));
                        dst.v = v;
                        dst.count = @intCast(count);
                        dst.size = @intCast(count);
                        @memcpy(v[0..count], src.v.?[0..count]);
                    }
                }
            }

            term.normal = g;
            term.hide_cursor = true;
        }

        if (term.grid == &term.alt) {
            selection_cancel(term);
        } else {
            // Don't cancel, but make sure there aren't any ongoing selections
            // after the resize
            const seats: *tll.Tll(types.Seat) = @ptrCast(&term.wl.?.seats);
            var it = seats.foreach();
            while (it.next()) |node| {
                const seat = &node.item;
                if (seat.kbd_focus == term)
                    selection_finalize(seat, term, seat.pointer.serial);
            }
        }

        // Ensure mouse col/row coordinates are still valid
        const seats: *tll.Tll(types.Seat) = @ptrCast(&term.wl.?.seats);
        var it = seats.foreach();
        while (it.next()) |node| {
            const seat = &node.item;
            if (seat.mouse_focus == term)
                mouse_coord_pixel_to_cell(seat, term, seat.mouse.x, seat.mouse.y);
        }

        // TODO: if the selection_finalize() call above is ever removed (i.e.
        // if selections may span a resize), the selection's pivot point
        // coordinates *must* be added to the tracking points list.
        if (window.is_resizing and conf.resize_delay_ms > 0) {
            // Simple truncating resize, *while* an interactive resize is
            // ongoing.
            const resizing = &term.interactive_resizing;
            std.debug.assert(resizing.grid != null);
            std.debug.assert(new_normal_grid_rows > 0);
            resizing.new_rows = new_normal_grid_rows;

            grid_resize_without_reflow(
                &term.normal,
                new_alt_grid_rows,
                new_cols,
                resizing.old_screen_rows,
                new_rows,
            );
        } else {
            // Full text reflow
            var old_normal_rows = old_rows;

            const resizing = &term.interactive_resizing;
            if (resizing.grid != null) {
                // Throw away the current, truncated, "normal" grid, and use
                // the original grid instead (from before the resize started)
                grid_free(&term.normal);
                term.normal = resizing.grid.?.*;
                free(resizing.grid.?);

                term.hide_cursor = resizing.old_hide_cursor != 0;
                term.selection.coords = resizing.selection_coords;

                old_normal_rows = resizing.old_screen_rows;

                resizing.grid = null;
                resizing.old_screen_rows = 0;
                resizing.new_rows = 0;
                resizing.old_hide_cursor = 0;
                resizing.selection_coords = .{
                    .start = .{ .col = -1, .row = -1 },
                    .end = .{ .col = -1, .row = -1 },
                };
                term_ptmx_resume(term);
            }

            var tracking_points = [_]*types.Coord{
                &term.selection.coords.start,
                &term.selection.coords.end,
            };

            grid_resize_and_reflow(
                &term.normal,
                term,
                new_normal_grid_rows,
                new_cols,
                old_normal_rows,
                new_rows,
                if (term.selection.coords.end.row >= 0) tracking_points.len else 0,
                &tracking_points,
            );
        }

        grid_resize_without_reflow(&term.alt, new_alt_grid_rows, new_cols, old_rows, new_rows);

        // Reset tab stops
        const tab_stops: *tll.Tll(c_int) = @ptrCast(&term.tab_stops);
        tab_stops.freeList();
        var c: c_int = 0;
        while (c < new_cols) : (c += 8)
            tab_stops.pushBack(c);

        term.cols = new_cols;
        term.rows = new_rows;

        sixel_reflow(term);

        log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "resized: grid: cols=%d, rows=%d " ++
            "(left-margin=%d, right-margin=%d, top-margin=%d, bottom-margin=%d)", term.cols, term.rows, term.margins.left, term.margins.right, term.margins.top, term.margins.bottom);

        if (term.scroll_region.start >= term.rows)
            term.scroll_region.start = 0;
        if (term.scroll_region.end > term.rows or
            term.scroll_region.end >= old_rows)
        {
            term.scroll_region.end = term.rows;
        }

        term.render.last_cursor.row = null;
    }

    // Signal TIOCSWINSZ
    send_dimensions_to_client(term);

    if (is_floating) {
        // Stash current size, to enable us to restore it when we're being
        // un-maximized/fullscreened/tiled
        term.stashed_width = term.width;
        term.stashed_height = term.height;
    }

    {
        const title_shown = wayl_win_csd_titlebar_visible(window);
        const border_shown = wayl_win_csd_borders_visible(window);

        const title: c_int = if (title_shown)
            roundfF(@as(f32, @floatFromInt(conf.csd.title_height)) * scale)
        else
            0;
        const border: c_int = if (border_shown)
            roundfF(@as(f32, @floatFromInt(conf.csd.border_width_visible)) * scale)
        else
            0;

        // Must use surface logical coordinates (same calculations as
        // get_csd_data(), but with different inputs)
        const toplevel_min_width = roundfDiv(border, scale) +
            roundfDiv(min_width, scale) +
            roundfDiv(border, scale);

        const toplevel_min_height = roundfDiv(border, scale) +
            roundfDiv(title, scale) +
            roundfDiv(min_height, scale) +
            roundfDiv(border, scale);

        const toplevel_width = roundfDiv(border, scale) +
            roundfDiv(term.width, scale) +
            roundfDiv(border, scale);

        const toplevel_height = roundfDiv(border, scale) +
            roundfDiv(title, scale) +
            roundfDiv(term.height, scale) +
            roundfDiv(border, scale);

        const x = roundfDiv(-border, scale);
        const y = roundfDiv(-title, scale) - roundfDiv(border, scale);

        wayland_shim_xdg_toplevel_set_min_size(window.xdg_toplevel, toplevel_min_width, toplevel_min_height);
        wayland_shim_xdg_surface_set_window_geometry(window.xdg_surface, x, y, toplevel_width, toplevel_height);
    }

    const normal_damage: *tll.Tll(types.Damage) = @ptrCast(&term.normal.scroll_damage);
    const alt_damage: *tll.Tll(types.Damage) = @ptrCast(&term.alt.scroll_damage);
    normal_damage.freeList();
    alt_damage.freeList();

    render_wait_for_preapply_damage(term);
    if (term.render.last_buf) |raw| {
        shm_unref(@ptrCast(@alignCast(raw)));
        term.render.last_buf = null;
    }
    term_damage_view(term);
    render_refresh_csd(term);
    render_refresh_search(term);
    render_refresh(term);

    return true;
}

// ─────────────────────────────────────────────────────────────────────────
// grid_render (D3l2)
// ─────────────────────────────────────────────────────────────────────────

extern fn selection_dirty_cells(term: *Terminal) callconv(.c) void;
extern fn wayl_win_scale(win: *types.WlWindow, buf: *const Buffer) callconv(.c) void;
extern fn timespec_add(a: *const Timespec, b: *const Timespec, res: *Timespec) callconv(.c) void;
extern fn render_shim_region_rectangles(r: *anyopaque, count: *c_int) callconv(.c) ?[*]PixmanBox32;
extern fn render_shim_add_frame_callback(surf: ?*anyopaque, data: *anyopaque) callconv(.c) ?*anyopaque;
extern fn render_shim_presentation_commit_time(wl: *types.Wayland, sec: *i64, nsec: *i64) callconv(.c) void;
extern fn render_shim_presentation_feedback_new(wl: *types.Wayland, surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn render_shim_presentation_feedback_add(fb: *anyopaque, ctx: *anyopaque) callconv(.c) void;

/// Only set once the compositor has refused a buffer release 10 frames in a
/// row; the warning is emitted at most once per process (C used a `static`).
var have_warned_slow_release = false;

fn renderQueueLen(term: *const Terminal) usize {
    const queue: *const tll.Tll(c_int) = @ptrCast(&term.render.workers.queue);
    return queue.len();
}

/// Dirty every cell that shares an overflowing glyph run with a dirty cell.
///
/// Given two adjacent cells where the first overflows into the second, both
/// have to be re-rendered if either one is dirty - so a single dirty cell in
/// the middle of a run re-dirties the whole run. Walking left to right: when a
/// dirty cell is found, back-fill the clean, non-confined cells before it,
/// then sweep forward (marking the first non-confined cell dirty as well) and
/// resume the outer loop *after* the confined cell, which is what C's
/// reuse-the-outer-pointer trick amounts to.
fn dirtyOverflowingGlyphs(term: *Terminal) void {
    const grid = term.grid.?;

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const row = terminal_shim_grid_row_in_view(grid, r) orelse unreachable;
        if (!row.dirty)
            continue;

        const cells = row.cells.?;
        var col: c_int = 0;
        while (col < term.cols) : (col += 1) {
            if (cells[@intCast(col)].attrs.clean)
                continue;

            var back: c_int = col - 1;
            while (back >= 0) : (back -= 1) {
                const c = &cells[@intCast(back)];
                if (c.attrs.confined)
                    break;
                if (!c.attrs.clean)
                    break;
                c.attrs.clean = false;
            }

            var fwd: c_int = col;
            while (fwd < term.cols) : (fwd += 1) {
                const c = &cells[@intCast(fwd)];
                c.attrs.clean = false;
                if (c.attrs.confined)
                    break;
            }
            col = fwd;
        }
    }
}

/// Harness entry point: the overflowing-glyph pre-pass without a frame.
export fn render_dirty_overflowing_glyphs(term: *Terminal) callconv(.c) void {
    dirtyOverflowingGlyphs(term);
}

/// Render one frame: buffer selection, damage bookkeeping, the worker hand-off
/// and the wayland commit. `render.c` only keeps the protocol glue.
export fn grid_render(term: *Terminal) callconv(.c) void {
    if (term.shutdown.in_progress)
        return;

    var start_time: Timespec = undefined;
    var start_wait_preapply: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    var stop_wait_preapply = start_wait_preapply;
    var start_double_buffering = start_wait_preapply;
    var stop_double_buffering = start_wait_preapply;

    // Might be a thread doing pre-applied damage
    if (term.render.preapply_last_frame_damage and
        term.render.workers.preapplied_damage.buf != null)
    {
        _ = clock_gettime(CLOCK_MONOTONIC, &start_wait_preapply);
        render_wait_for_preapply_damage(term);
        _ = clock_gettime(CLOCK_MONOTONIC, &stop_wait_preapply);
    }

    if (term.conf.?.tweak.render_timer != .none)
        _ = clock_gettime(CLOCK_MONOTONIC, &start_time);

    std.debug.assert(term.width > 0);
    std.debug.assert(term.height > 0);

    const chain: *types.ShmBufferChain = @ptrCast(@alignCast(term.render.chains.grid.?));
    const buf = shm_get_buffer(chain, term.width, term.height).?;

    // Dirty old and current cursor cell, to ensure they're repainted
    dirty_old_cursor(term);
    dirty_cursor(term);

    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "buffer age: %u (%p)", @as(c_uint, buf.age), @as(*anyopaque, buf));

    var last_buf: ?*Buffer = null;
    if (term.render.last_buf) |raw|
        last_buf = @ptrCast(@alignCast(raw));

    if (last_buf == null or
        last_buf.?.width != buf.width or
        last_buf.?.height != buf.height or
        term.render.margins)
    {
        force_full_repaint(term, buf);
    } else if (buf.age > 0) {
        const prev = last_buf.?;
        std.debug.assert(prev != buf);
        std.debug.assert(prev.width == buf.width);
        std.debug.assert(prev.height == buf.height);

        term.render.frames_since_last_immediate_release += 1;
        if (term.render.frames_since_last_immediate_release > 10) {
            if (!term.render.preapply_last_frame_damage and
                term.conf.?.tweak.preapply_damage and
                term.render.workers.count > 0)
            {
                log_msg(LOG_CLASS_INFO, "render", "render.zig", @intCast(@src().line), "enabling pre-applied frame damage");
                term.render.preapply_last_frame_damage = true;
            } else if (!have_warned_slow_release and
                !term.render.preapply_last_frame_damage)
            {
                log_msg(LOG_CLASS_WARNING, "render", "render.zig", @intCast(@src().line), "compositor is not releasing buffers immediately; " ++
                    "expect lower rendering performance");
                have_warned_slow_release = true;
            }
        }

        _ = clock_gettime(CLOCK_MONOTONIC, &start_double_buffering);
        reapply_old_damage(term, buf, prev);
        _ = clock_gettime(CLOCK_MONOTONIC, &stop_double_buffering);
    } else if (!term.render.preapply_last_frame_damage) {
        term.render.frames_since_last_immediate_release = 0;
    }

    if (term.render.last_buf) |raw| {
        shm_unref(@ptrCast(@alignCast(raw)));
        term.render.last_buf = null;
    }

    term.render.last_buf = buf;
    shm_addref(buf);
    buf.age = 0;

    const grid = term.grid.?;

    // Apply the pending scroll damage. A full-view scroll while the view is
    // inside the scrollback has to be skipped: the rows it moved are not the
    // ones on screen.
    const scroll_damage: *tll.Tll(types.Damage) = @ptrCast(&grid.scroll_damage);
    while (scroll_damage.len() > 0) {
        const dmg = scroll_damage.popFront();
        switch (dmg.type) {
            .scroll => if (grid.view == grid.offset)
                grid_render_scroll(term, buf, &dmg),
            .scroll_reverse => if (grid.view == grid.offset)
                grid_render_scroll_reverse(term, buf, &dmg),
            .scroll_in_view => grid_render_scroll(term, buf, &dmg),
            .scroll_reverse_in_view => grid_render_scroll_reverse(term, buf, &dmg),
        }
    }

    // Selected cells normally have their 'selected' bit set when the
    // selection is made. If a cell is printed to while the selection is
    // active the bit is cleared, and checking for that in term_print() would
    // be too expensive. Synchronise here instead: linear in selected cells
    // rather than in updated cells.
    selection_dirty_cells(term);

    // Translate offset-relative row to view-relative, unless the cursor is
    // hidden, in which case -1.
    var cursor: types.Coord = .{ .col = -1, .row = -1 };
    if (!term.hide_cursor) {
        cursor = grid.cursor.point;
        cursor.row += grid.offset;
        cursor.row -= grid.view;
        cursor.row &= grid.num_rows - 1;
    }

    if (term.conf.?.tweak.overflowing_glyphs)
        dirtyOverflowingGlyphs(term);

    // (C's _DEBUG row/cell consistency checks are not part of this port.)

    var damage: Region32 = undefined;
    render_shim_region_init(regionPtr(&damage));

    render_sixel_images(term, bufferPix(buf), regionPtr(&damage), &cursor);

    const lock: *anyopaque = @ptrCast(&term.render.workers.lock);
    const start: *anyopaque = @ptrCast(&term.render.workers.start);
    const done: *anyopaque = @ptrCast(&term.render.workers.done);
    const queue: *tll.Tll(c_int) = @ptrCast(&term.render.workers.queue);
    const worker_count: usize = term.render.workers.count;

    if (worker_count > 0) {
        _ = mtx_lock(lock);
        term.render.workers.buf = buf;
        var i: usize = 0;
        while (i < worker_count) : (i += 1)
            _ = sem_post(start);

        std.debug.assert(renderQueueLen(term) == 0);
    }

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const row = terminal_shim_grid_row_in_view(grid, r) orelse unreachable;
        if (!row.dirty)
            continue;

        row.dirty = false;

        if (worker_count > 0) {
            queue.pushBack(r);
        } else {
            const cursor_col: c_int = if (cursor.row == r) cursor.col else -1;
            render_row(term, bufferPix(buf), regionPtr(&damage), row, r, cursor_col);
        }
    }

    // Signal the workers the frame is done
    if (worker_count > 0) {
        var i: usize = 0;
        while (i < worker_count) : (i += 1)
            queue.pushBack(-1);
        _ = mtx_unlock(lock);

        i = 0;
        while (i < worker_count) : (i += 1)
            _ = sem_wait(done);
        term.render.workers.buf = null;
    }

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        render_shim_region_union(regionPtr(&damage), regionPtr(&damage), dirtyRegionPtr(buf, i + 1));
    }
    render_shim_region_union(dirtyRegionPtr(buf, 0), dirtyRegionPtr(buf, 0), regionPtr(&damage));

    const surf = term.window.?.surface.surf;
    {
        var box_count: c_int = 0;
        if (render_shim_region_rectangles(regionPtr(&damage), &box_count)) |boxes| {
            var b: usize = 0;
            while (b < box_count) : (b += 1) {
                const box = boxes[b];
                wayland_shim_surface_damage_buffer(surf, box.x1, box.y1, box.x2 - box.x1, box.y2 - box.y1);
            }
        }
    }

    render_shim_region_fini(regionPtr(&damage));

    render_overlay(term);
    render_ime_preedit(term, buf);
    render_scrollback_position(term);

    if (term.conf.?.tweak.render_timer != .none) {
        var end_time: Timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &end_time);

        var wait_time: Timespec = undefined;
        timespec_sub(&stop_wait_preapply, &start_wait_preapply, &wait_time);

        var render_time: Timespec = undefined;
        timespec_sub(&end_time, &start_time, &render_time);

        var double_buffering_time: Timespec = undefined;
        timespec_sub(&stop_double_buffering, &start_double_buffering, &double_buffering_time);

        const pre = &term.render.workers.preapplied_damage;
        var preapply_damage: Timespec = undefined;
        timespec_sub(workersTimespec(&pre.stop), workersTimespec(&pre.start), &preapply_damage);

        var total_render_time: Timespec = undefined;
        timespec_add(&render_time, &double_buffering_time, &total_render_time);
        timespec_add(&wait_time, &total_render_time, &total_render_time);

        switch (term.conf.?.tweak.render_timer) {
            .log, .both => log_msg(
                LOG_CLASS_INFO,
                "render",
                "render.zig",
                @intCast(@src().line),
                "frame rendered in %lds %9ldns " ++
                    "(%lds %9ldns wait, %lds %9ldns rendering, " ++
                    "%lds %9ldns double buffering) not included: " ++
                    "%lds %ldns pre-apply damage",
                total_render_time.tv_sec,
                total_render_time.tv_nsec,
                wait_time.tv_sec,
                wait_time.tv_nsec,
                render_time.tv_sec,
                render_time.tv_nsec,
                double_buffering_time.tv_sec,
                double_buffering_time.tv_nsec,
                preapply_damage.tv_sec,
                preapply_damage.tv_nsec,
            ),
            .none, .osd => {},
        }

        switch (term.conf.?.tweak.render_timer) {
            .osd, .both => render_render_timer(term, total_render_time),
            .log, .none => {},
        }
    }

    std.debug.assert(grid.offset >= 0 and grid.offset < grid.num_rows);
    std.debug.assert(grid.view >= 0 and grid.view < grid.num_rows);

    const window = term.window.?;
    std.debug.assert(window.frame_callback == null);
    window.frame_callback = render_shim_add_frame_callback(surf, term);

    wayl_win_scale(window, buf);

    if (term.wl.?.presentation != null and term.conf.?.presentation_timings) {
        var commit_sec: i64 = 0;
        var commit_nsec: i64 = 0;
        render_shim_presentation_commit_time(term.wl.?, &commit_sec, &commit_nsec);

        const feedback = render_shim_presentation_feedback_new(term.wl.?, surf);
        if (feedback == null) {
            log_msg(LOG_CLASS_WARNING, "render", "render.zig", @intCast(@src().line), "failed to create presentation feedback");
        } else {
            const input_time = workersTimespec(&term.render.input_time);
            const ctx = presentationCtxNew(
                term,
                input_time.tv_sec,
                @divTrunc(input_time.tv_nsec, 1000),
                commit_sec,
                @divTrunc(commit_nsec, 1000),
            );
            render_shim_presentation_feedback_add(feedback.?, ctx);

            input_time.tv_sec = 0;
            input_time.tv_nsec = 0;
        }
    }

    if (term.conf.?.tweak.damage_whole_window) {
        wayland_shim_surface_damage_buffer(surf, 0, 0, 0x7fffffff, 0x7fffffff);
    }

    wayland_shim_surface_attach(surf, buf.wl_buf, 0, 0);
    wayland_shim_surface_commit(surf);
}

// ─────────────────────────────────────────────────────────────────────────
// Render worker thread (D3l1)
// ─────────────────────────────────────────────────────────────────────────

// The semaphores/mutex/condition variable are byte blobs in the mirror (their
// pthread layout is opaque to Zig, but the size is pinned by the ABI probe),
// so they are passed through by address - same approach as terminal.zig's
// initialize_render_workers().
extern fn sem_wait(sem: *anyopaque) callconv(.c) c_int;
extern fn sem_post(sem: *anyopaque) callconv(.c) c_int;
extern fn mtx_lock(mtx: *anyopaque) callconv(.c) c_int;
extern fn mtx_unlock(mtx: *anyopaque) callconv(.c) c_int;
extern fn cnd_signal(cond: *anyopaque) callconv(.c) c_int;
extern fn cnd_wait(cond: *anyopaque, mtx: *anyopaque) callconv(.c) c_int;
extern fn render_shim_block_all_signals() callconv(.c) void;
extern fn render_shim_set_thread_name(name: [*:0]const u8) callconv(.c) c_int;
extern fn shm_unref(buf: ?*Buffer) callconv(.c) void;
extern fn shm_addref(buf: *Buffer) callconv(.c) void;

/// render.h's `struct render_worker_context` (my_id comes first).
const RenderWorkerContext = extern struct {
    my_id: c_int,
    _pad: [4]u8 = undefined,
    term: *Terminal,
};

/// `&buf->dirty[idx]`: the dirty-region array the workers write to.
fn dirtyRegionPtr(buf: *Buffer, idx: usize) *anyopaque {
    const regions: [*]Region32 = @ptrCast(@alignCast(buf.dirty.?));
    return regionPtr(&regions[idx]);
}

fn workersTimespec(field: *[16]u8) *Timespec {
    return @ptrCast(@alignCast(field));
}

export fn render_worker_thread(ctx_in: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *RenderWorkerContext = @ptrCast(@alignCast(ctx_in orelse return null));
    const term = ctx.term;
    const my_id = ctx.my_id;
    free(ctx);

    render_shim_block_all_signals();

    var title_buf: [24]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "zigfoot:render:{d}", .{my_id}) catch "zigfoot:render";
    if (render_shim_set_thread_name(title.ptr) < 0) {
        log_errno(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "render worker %d: failed to set process title", my_id);
    }

    const start: *anyopaque = @ptrCast(&term.render.workers.start);
    const done: *anyopaque = @ptrCast(&term.render.workers.done);
    const lock: *anyopaque = @ptrCast(&term.render.workers.lock);
    const queue: *tll.Tll(c_int) = @ptrCast(&term.render.workers.queue);

    while (true) {
        _ = sem_wait(start);

        // NULL until grid_render() hands the workers a frame: the -1 and -2
        // control codes never touch it, so this stays optional (and matching
        // the C original, which happily reads the NULL).
        var buf: ?*Buffer = if (term.render.workers.buf) |b|
            @ptrCast(@alignCast(b))
        else
            null;

        var frame_done = false;

        // Translate the offset-relative cursor row to the view
        var cursor: types.Coord = .{ .col = -1, .row = -1 };
        if (!term.hide_cursor) {
            const grid = term.grid.?;
            cursor = grid.cursor.point;
            cursor.row += grid.offset;
            cursor.row -= grid.view;
            cursor.row &= grid.num_rows - 1;
        }

        while (!frame_done) {
            _ = mtx_lock(lock);
            std.debug.assert(queue.len() > 0);

            const row_no = queue.popFront();
            _ = mtx_unlock(lock);

            switch (row_no) {
                -1 => {
                    frame_done = true;
                    _ = sem_post(done);
                },

                -2 => return null,

                -3 => {
                    const pre = &term.render.workers.preapplied_damage;
                    const pre_lock: *anyopaque = @ptrCast(@alignCast(&pre.lock));
                    const pre_cond: *anyopaque = @ptrCast(@alignCast(&pre.cond));

                    if (term.conf.?.tweak.render_timer != .none) {
                        _ = clock_gettime(CLOCK_MONOTONIC, workersTimespec(&pre.start));
                    }

                    _ = mtx_lock(pre_lock);
                    const pre_buf: *Buffer = @ptrCast(@alignCast(pre.buf.?));
                    buf = pre_buf;

                    if (term.render.last_buf) |last_raw| {
                        const last_buf: *Buffer = @ptrCast(@alignCast(last_raw));
                        _ = mtx_unlock(pre_lock);

                        var dmg: Region32 = undefined;
                        render_shim_region_init(regionPtr(&dmg));

                        if (pre_buf.age == 0) {
                            // No need to do anything
                        } else if (pre_buf.age == 1) {
                            render_shim_region_copy(regionPtr(&dmg), last_buf.dirty.?);
                        } else {
                            render_shim_region_init_rect(regionPtr(&dmg), 0, 0, pre_buf.width, pre_buf.height);
                        }

                        const pix = bufferPix(pre_buf);
                        render_shim_set_clip_region(pix, regionPtr(&dmg));
                        render_shim_composite_op(
                            PIXMAN_OP_SRC,
                            optPix(last_buf.pix.?[@intCast(my_id)]),
                            null,
                            pix,
                            0, // src_x
                            0, // src_y
                            0, // dest_x
                            0, // dest_y
                            pre_buf.width,
                            pre_buf.height,
                        );
                        render_shim_region_fini(regionPtr(&dmg));

                        pre_buf.age = 0;
                        shm_unref(last_buf);
                        shm_addref(pre_buf);
                        term.render.last_buf = pre_buf;

                        _ = mtx_lock(pre_lock);
                    }

                    pre.buf = null;
                    _ = cnd_signal(pre_cond);
                    _ = mtx_unlock(pre_lock);

                    if (term.conf.?.tweak.render_timer != .none) {
                        _ = clock_gettime(CLOCK_MONOTONIC, workersTimespec(&pre.stop));
                    }

                    frame_done = true;
                },

                else => {
                    const row =
                        terminal_shim_grid_row_in_view(term.grid.?, row_no) orelse continue;
                    const cursor_col: c_int =
                        if (cursor.row == row_no) cursor.col else -1;

                    render_row(
                        term,
                        optPix(buf.?.pix.?[@intCast(my_id)]).?,
                        dirtyRegionPtr(buf.?, @intCast(my_id)),
                        row,
                        row_no,
                        cursor_col,
                    );
                },
            }
        }
    }
}

export fn render_wait_for_preapply_damage(term: *Terminal) callconv(.c) void {
    if (!term.render.preapply_last_frame_damage)
        return;

    const pre = &term.render.workers.preapplied_damage;
    if (pre.buf == null)
        return;

    const pre_lock: *anyopaque = @ptrCast(@alignCast(&pre.lock));
    const pre_cond: *anyopaque = @ptrCast(@alignCast(&pre.cond));

    _ = mtx_lock(pre_lock);
    while (pre.buf != null) {
        _ = cnd_wait(pre_cond, pre_lock);
    }
    _ = mtx_unlock(pre_lock);
}

// ─────────────────────────────────────────────────────────────────────────
// Cursor, frame callback and the FDM hooks (D3l4) — the last of render.c
// ─────────────────────────────────────────────────────────────────────────

extern fn render_shim_add_xcursor_callback(surf: ?*anyopaque, data: *anyopaque) callconv(.c) ?*anyopaque;
extern fn render_shim_cursor_theme_get_cursor(theme: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn render_shim_cursor_image_0(cursor: ?*anyopaque, width: *i32, height: *i32, hotspot_x: *i32, hotspot_y: *i32) callconv(.c) bool;
extern fn render_shim_cursor_image_0_buffer(cursor: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn render_shim_pointer_set_cursor(pointer: ?*anyopaque, serial: u32, surf: ?*anyopaque, hotspot_x: i32, hotspot_y: i32) callconv(.c) void;
extern fn render_shim_cursor_shape_device_v1_set_shape(device: ?*anyopaque, serial: u32, shape: u32) callconv(.c) void;
extern fn render_shim_xdg_toplevel_set_title(toplevel: ?*anyopaque, title: [*:0]const u8) callconv(.c) void;
extern fn render_shim_callback_destroy(callback: ?*anyopaque) callconv(.c) void;
extern fn cursor_shape_to_server_shape(shape: c_int) callconv(.c) c_int;
extern fn cursor_string_to_server_shape(xcursor: [*:0]const u8, bound_version: c_int) callconv(.c) c_int;
extern fn cursor_shape_to_string(shape: c_int) callconv(.c) [*c]const [*c]const u8;
extern fn wayl_surface_scale_explicit_width_height(
    win: *const types.WlWindow,
    surf: *const types.WaylSurface,
    width: c_int,
    height: c_int,
    scale: f32,
) callconv(.c) void;
extern fn ime_update_cursor_rect(seat: *types.Seat) callconv(.c) void;
extern fn quirk_weston_csd_on(term: *Terminal) callconv(.c) void;
extern fn quirk_weston_csd_off(term: *Terminal) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xstrndup(s: [*:0]const u8, n: usize) callconv(.c) [*:0]u8;

fn streqOpt(a: ?[*:0]const u8, b: ?[*:0]const u8) bool {
    if (a == null or b == null)
        return a == null and b == null;
    return std.mem.orderZ(u8, a.?, b.?) == .eq;
}

/// Truncate long UTF-8 strings to `max_len` bytes, on a codepoint boundary?
/// C uses strlen()/xstrndup() directly - same here.
export fn render_update_title(term: *Terminal) callconv(.c) void {
    const max_len: usize = 2048;

    // C dereferenced `term->window->xdg_toplevel` unconditionally. A real
    // window always has one by the time a title change arrives; the harness
    // builds a bare window, which made the rate-limit test timing-dependent
    // under valgrind (Invalid read in wl_proxy_get_version).
    const window = term.window orelse return;
    const toplevel = window.xdg_toplevel orelse return;

    var title: [*:0]const u8 = "Zigfoot";
    if (term.window_title) |t|
        title = t;

    var copy: ?[*:0]u8 = null;
    if (std.mem.len(title) > max_len) {
        copy = xstrndup(title, max_len);
        title = copy.?;
    }

    render_shim_xdg_toplevel_set_title(toplevel, title);
    if (copy) |c|
        free(c);
}

/// The compositor is ready for another frame: run the deferred work that was
/// queued while the previous frame was in flight, then render.
export fn frame_callback(
    data: ?*anyopaque,
    wl_callback: ?*anyopaque,
    callback_data: u32,
) callconv(.c) void {
    _ = callback_data;
    const term: *Terminal = @ptrCast(@alignCast(data orelse return));
    const window = term.window.?;

    std.debug.assert(window.frame_callback == wl_callback);
    render_shim_callback_destroy(wl_callback);
    window.frame_callback = null;

    const grid = term.render.pending.grid;
    const csd = term.render.pending.csd;
    const search = term.is_searching and term.render.pending.search;
    const urls = terminal_shim_urls_mode_active(term) and term.render.pending.urls;

    term.render.pending.grid = false;
    term.render.pending.csd = false;
    term.render.pending.search = false;
    term.render.pending.urls = false;

    const original_grid = term.grid;
    if (terminal_shim_urls_mode_active(term)) {
        std.debug.assert(term.url.grid_snapshot != null);
        term.grid = term.url.grid_snapshot;
    }

    if (csd and window.csd_mode == .yes) {
        quirk_weston_csd_on(term);
        render_csd(term);
        quirk_weston_csd_off(term);
    }

    if (search)
        render_search_box(term);

    if (urls)
        render_urls(term);

    if ((grid and !term.delayed_render_timer.is_armed) or (csd or search or urls))
        grid_render(term);

    const seats: *tll.Tll(types.Seat) = @ptrCast(&term.wl.?.seats);
    var it = seats.foreach();
    while (it.next()) |node| {
        const seat = &node.item;
        if (seat.ime_focus == term)
            ime_update_cursor_rect(seat);
    }

    term.grid = original_grid;
}

export fn render_xcursor_is_valid(
    seat: *const types.Seat,
    cursor: ?[*:0]const u8,
) callconv(.c) bool {
    if (cursor == null)
        return false;
    if (seat.pointer.theme == null)
        return false;
    return render_shim_cursor_theme_get_cursor(seat.pointer.theme, cursor.?) != null;
}

/// Install the cursor the seat asked for: cursor-shape-v1 when the compositor
/// supports it, a client-side cursor surface otherwise.
fn renderXcursorUpdate(seat: *types.Seat) void {
    // If called from a frame callback, we may no longer have mouse focus
    if (seat.mouse_focus == null)
        return;

    const pointer = &seat.pointer;
    std.debug.assert(pointer.shape != .none);

    const surf = pointer.surface.surf;

    if (pointer.shape == .hidden) {
        // Hide cursor
        log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "hiding cursor using client-side NULL-surface");
        wayland_shim_surface_attach(surf, null, 0, 0);
        render_shim_pointer_set_cursor(seat.wl_pointer, pointer.serial, surf, 0, 0);
        wayland_shim_surface_commit(surf);
        return;
    }

    const shape = pointer.shape;
    const xcursor = pointer.last_custom_xcursor;

    if (pointer.shape_device) |device| {
        std.debug.assert(shape != .custom or xcursor != null);

        const custom_shape: c_int = if (shape == .custom and xcursor != null)
            cursor_string_to_server_shape(xcursor.?, seat.wayl.?.shape_manager_version)
        else
            0;

        if (shape != .custom or custom_shape != 0) {
            std.debug.assert(custom_shape == 0 or shape == .custom);

            const wp_shape: c_int = if (custom_shape != 0)
                custom_shape
            else
                cursor_shape_to_server_shape(@intFromEnum(shape));

            log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "setting %scursor shape using cursor-shape-v1", @as([*:0]const u8, if (custom_shape != 0) "custom " else ""));

            render_shim_cursor_shape_device_v1_set_shape(device, pointer.serial, @intCast(wp_shape));

            return;
        }
    }

    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "setting %scursor shape using a client-side cursor surface", @as([*:0]const u8, if (pointer.shape == .custom) "custom " else ""));

    if (pointer.cursor == null) {
        // Normally we never get here with a NULL cursor: an update is only
        // scheduled after the image loaded. But the pointer may move - and
        // the new cursor fail to load - before the scheduled update runs.
        return;
    }

    var width: i32 = 0;
    var height: i32 = 0;
    var hotspot_x: i32 = 0;
    var hotspot_y: i32 = 0;
    if (!render_shim_cursor_image_0(pointer.cursor, &width, &height, &hotspot_x, &hotspot_y)) {
        return;
    }

    const scale = pointer.scale;
    const buf = render_shim_cursor_image_0_buffer(pointer.cursor);

    wayl_surface_scale_explicit_width_height(seat.mouse_focus.?.window.?, &pointer.surface, width, height, scale);

    wayland_shim_surface_attach(surf, buf, 0, 0);

    render_shim_pointer_set_cursor(
        seat.wl_pointer,
        pointer.serial,
        surf,
        @intFromFloat(@as(f32, @floatFromInt(hotspot_x)) / scale),
        @intFromFloat(@as(f32, @floatFromInt(hotspot_y)) / scale),
    );

    wayland_shim_surface_damage_buffer(surf, 0, 0, 0x7fffffff, 0x7fffffff);

    std.debug.assert(pointer.xcursor_callback == null);
    pointer.xcursor_callback = render_shim_add_xcursor_callback(surf, seat);

    wayland_shim_surface_commit(surf);
}

export fn xcursor_callback(
    data: ?*anyopaque,
    wl_callback: ?*anyopaque,
    callback_data: u32,
) callconv(.c) void {
    _ = callback_data;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    std.debug.assert(seat.pointer.xcursor_callback == wl_callback);
    render_shim_callback_destroy(wl_callback);
    seat.pointer.xcursor_callback = null;

    if (seat.pointer.xcursor_pending) {
        renderXcursorUpdate(seat);
        seat.pointer.xcursor_pending = false;
    }
}

/// The render FDM hook: walk every terminal and render the ones with pending
/// refresh flags, then flush pending cursor updates.
export fn fdm_hook_refresh_pending_terminals(
    fdm: *Fdm,
    data: ?*anyopaque,
) callconv(.c) void {
    _ = fdm;
    const renderer: *Renderer = @ptrCast(@alignCast(data orelse return));
    const wayl = renderer.wayl;

    const terms: *tll.Tll(?*anyopaque) = @ptrCast(&wayl.terms);
    var it = terms.foreach();
    while (it.next()) |node| {
        const term: *Terminal = @ptrCast(@alignCast(node.item orelse continue));

        if (term.shutdown.in_progress or !term.window.?.is_configured)
            continue;

        const grid = term.render.refresh.grid;
        const csd = term.render.refresh.csd;
        const search = term.is_searching and term.render.refresh.search;
        const urls = terminal_shim_urls_mode_active(term) and term.render.refresh.urls;

        if (!(grid or csd or search or urls))
            continue;

        if (term.render.app_sync_updates.enabled and !(csd or search or urls))
            continue;

        term.render.refresh.grid = false;
        term.render.refresh.csd = false;
        term.render.refresh.search = false;
        term.render.refresh.urls = false;

        const window = term.window.?;

        if (window.frame_callback == null) {
            const original_grid = term.grid;
            if (terminal_shim_urls_mode_active(term)) {
                std.debug.assert(term.url.grid_snapshot != null);
                term.grid = term.url.grid_snapshot;
            }

            if (csd and window.csd_mode == .yes) {
                quirk_weston_csd_on(term);
                render_csd(term);
                quirk_weston_csd_off(term);
            }
            if (search)
                render_search_box(term);
            if (urls)
                render_urls(term);
            if (grid or csd or search or urls)
                grid_render(term);

            const seats: *tll.Tll(types.Seat) = @ptrCast(&term.wl.?.seats);
            var sit = seats.foreach();
            while (sit.next()) |snode| {
                const seat = &snode.item;
                if (seat.ime_focus == term)
                    ime_update_cursor_rect(seat);
            }

            term.grid = original_grid;
        } else {
            // Tells the frame callback to render again
            term.render.pending.grid = term.render.pending.grid or grid;
            term.render.pending.csd = term.render.pending.csd or csd;
            term.render.pending.search = term.render.pending.search or search;
            term.render.pending.urls = term.render.pending.urls or urls;
        }
    }

    const seats: *tll.Tll(types.Seat) = @ptrCast(&wayl.seats);
    var sit = seats.foreach();
    while (sit.next()) |node| {
        const seat = &node.item;
        if (seat.pointer.xcursor_pending) {
            if (seat.pointer.xcursor_callback == null) {
                renderXcursorUpdate(seat);
                seat.pointer.xcursor_pending = false;
            } else {
                // Frame callback will call renderXcursorUpdate()
            }
        }
    }
}

/// Ask for `shape` on `seat`. Only records the request: the FDM hook (or the
/// cursor's frame callback) does the actual work.
export fn render_xcursor_set(
    seat: *types.Seat,
    term: *Terminal,
    shape: types.CursorShape,
) callconv(.c) bool {
    const pointer = &seat.pointer;

    if (pointer.theme == null and pointer.shape_device == null)
        return false;

    if (seat.mouse_focus == null) {
        pointer.shape = .none;
        return true;
    }

    if (seat.mouse_focus != term) {
        // This terminal doesn't have mouse focus
        return true;
    }

    if (pointer.shape == shape and
        !(shape == .custom and
            !streqOpt(pointer.last_custom_xcursor, term.mouse_user_cursor)))
    {
        return true;
    }

    if (shape == .hidden) {
        pointer.cursor = null;
        free(pointer.last_custom_xcursor);
        pointer.last_custom_xcursor = null;
    } else if (pointer.shape_device == null) {
        pointer.cursor = null;

        if (shape == .custom) {
            const custom = term.mouse_user_cursor;
            std.debug.assert(custom != null);
            if (custom) |name| {
                pointer.cursor = render_shim_cursor_theme_get_cursor(pointer.theme, name);
                if (pointer.cursor != null) {
                    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "loaded xcursor %s", name);
                }
            }
        } else {
            const names = cursor_shape_to_string(@intFromEnum(shape));
            std.debug.assert(names[0] != null);

            var i: usize = 0;
            while (names[i] != null) : (i += 1) {
                pointer.cursor = render_shim_cursor_theme_get_cursor(pointer.theme, names[i]);
                if (pointer.cursor != null) {
                    log_msg(LOG_CLASS_DEBUG, "render", "render.zig", @intCast(@src().line), "loaded xcursor %s", names[i]);
                    break;
                }
            }
        }

        if (pointer.cursor == null) {
            const first: [*:0]const u8 = if (shape == .custom)
                term.mouse_user_cursor.?
            else
                cursor_shape_to_string(@intFromEnum(shape))[0];
            log_msg(LOG_CLASS_ERROR, "render", "render.zig", @intCast(@src().line), "failed to load xcursor pointer '%s', and all of its fallbacks", first);
            return false;
        }
    } else {
        // Server-side cursors - no need to load anything
    }

    if (shape == .custom) {
        free(pointer.last_custom_xcursor);
        pointer.last_custom_xcursor = xstrdup(term.mouse_user_cursor.?);
    }

    // FDM hook takes care of actual rendering
    pointer.shape = shape;
    pointer.xcursor_pending = true;
    return true;
}

/// Called from shm.c when the compositor releases a buffer: pre-apply the
/// last frame's damage to it, so the next frame starts with the diff already
/// copied. That shortens the time between the frame callback and the commit,
/// which is what lets the compositor push the callback closer to vblank.
export fn render_buffer_release_callback(buf: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const buffer: *Buffer = @ptrCast(@alignCast(buf orelse return));
    const term: *Terminal = @ptrCast(@alignCast(data orelse return));

    if (buffer.age != 1)
        return;

    if (!term.render.preapply_last_frame_damage)
        return;

    const last_buf: ?*Buffer = if (term.render.last_buf) |raw|
        @ptrCast(@alignCast(raw))
    else
        null;

    if (last_buf == null)
        return;

    if (last_buf.?.age != 0)
        return;

    if (buffer.width != last_buf.?.width)
        return;

    if (buffer.height != last_buf.?.height)
        return;

    const pre = &term.render.workers.preapplied_damage;
    const pre_lock: *anyopaque = @ptrCast(@alignCast(&pre.lock));
    const pre_cond_unused: *anyopaque = @ptrCast(@alignCast(&pre.cond));
    _ = pre_cond_unused;

    std.debug.assert(term.render.workers.count > 0);
    std.debug.assert(last_buf.? != buffer);

    _ = mtx_lock(pre_lock);
    if (pre.buf != null) {
        _ = mtx_unlock(pre_lock);
        return;
    }

    std.debug.assert(pre.buf == null);
    pre.buf = buffer;
    workersTimespec(&pre.start).* = .{ .tv_sec = 0, .tv_nsec = 0 };
    workersTimespec(&pre.stop).* = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = mtx_unlock(pre_lock);

    const lock: *anyopaque = @ptrCast(&term.render.workers.lock);
    const queue: *tll.Tll(c_int) = @ptrCast(&term.render.workers.queue);

    _ = mtx_lock(lock);
    _ = sem_post(@ptrCast(&term.render.workers.start));
    std.debug.assert(renderQueueLen(term) == 0);
    queue.pushBack(-3);
    _ = mtx_unlock(lock);
}
