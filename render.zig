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
