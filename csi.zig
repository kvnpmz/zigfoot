const std = @import("std");
const types = @import("terminal_types.zig");

pub export fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void {
    _ = term;
    switch (final) {
        // TODO: transcribe foot csi.c — this is ~2000 lines of finals '@'..'~'
        else => {},
    }
}

// ─── Chunk A: sgr_reset + csi_sgr ──────────────────────────────────
// SGR = Select Graphic Rendition (text attributes: bold, dim, colors, ...)
// Handles CSI ... m sequences.

// libc
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

// terminal.c helper (currently C, will become Zig later)
extern fn term_update_ascii_printer(term: *types.Terminal) callconv(.c) void;

// Colors constants
const COLOR_DEFAULT: types.ColorSource = .default;
const COLOR_BASE16: types.ColorSource = .base16;
const COLOR_BASE256: types.ColorSource = .base256;
const COLOR_RGB: types.ColorSource = .rgb;

// UnderlineStyle constants (from config.h line 223)
const UNDERLINE_NONE: c_int = -1;   // any negative value
const UNDERLINE_SINGLE: c_int = 0;
const UNDERLINE_DOUBLE: c_int = 1;
const UNDERLINE_CURLY: c_int = 2;
const UNDERLINE_DOTTED: c_int = 3;
const UNDERLINE_DASHED: c_int = 4;

// ── sgr_reset ─────────────────────────────────────────────────────
export fn sgr_reset(term: *types.Terminal) callconv(.c) void {
    term.vt.attrs = std.mem.zeroes(types.Attributes);
    term.vt.underline = std.mem.zeroes(types.UnderlineRangeData);

    term.bits_affecting_ascii_printer._.underline_style = false;
    term.bits_affecting_ascii_printer._.underline_color = false;
    term_update_ascii_printer(term);
}

// ── csi_sgr ───────────────────────────────────────────────────────
export fn csi_sgr(term: *types.Terminal) callconv(.c) void {
    const params = &term.vt.params.v;
    const n: usize = @intCast(term.vt.params.idx);

    if (n == 0) {
        sgr_reset(term);
        return;
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const param: c_int = @intCast(params[i].value);

        switch (param) {
            0 => sgr_reset(term),

            1 => term.vt.attrs.bold = true,
            2 => term.vt.attrs.dim = true,
            3 => term.vt.attrs.italic = true,

            4 => {
                term.vt.attrs.underline = true;
                term.vt.underline.style = UNDERLINE_SINGLE;

                if (params[i].sub.idx == 1) {
                    const style: c_int = @intCast(params[i].sub.value[0]);

                    switch (style) {
                        UNDERLINE_NONE => {
                            term.vt.attrs.underline = false;
                            term.vt.underline.style = UNDERLINE_NONE;
                            term.bits_affecting_ascii_printer._.underline_style = false;
                        },
                        UNDERLINE_SINGLE,
                        UNDERLINE_DOUBLE,
                        UNDERLINE_CURLY,
                        UNDERLINE_DOTTED,
                        UNDERLINE_DASHED => {
                            term.vt.underline.style = style;
                            term.bits_affecting_ascii_printer._.underline_style = style > UNDERLINE_SINGLE;
                        },
                        else => {
                            term.vt.attrs.underline = false;
                            term.vt.underline.style = UNDERLINE_NONE;
                            term.bits_affecting_ascii_printer._.underline_style = false;
                        },
                    }
                } else {
                    term.bits_affecting_ascii_printer._.underline_style = false;
                }
                term_update_ascii_printer(term);
            },

            5 => term.vt.attrs.blink = true,
            6 => {}, // rapid blink ignored
            7 => term.vt.attrs.reverse = true,
            8 => term.vt.attrs.conceal = true,
            9 => term.vt.attrs.strikethrough = true,

            21 => {
                term.vt.attrs.underline = true;
                term.vt.underline.style = UNDERLINE_DOUBLE;
                term.bits_affecting_ascii_printer._.underline_style = true;
                term_update_ascii_printer(term);
            },

            22 => {
                term.vt.attrs.bold = false;
                term.vt.attrs.dim = false;
            },
            23 => term.vt.attrs.italic = false,
            24 => {
                term.vt.attrs.underline = false;
                term.vt.underline.style = UNDERLINE_NONE;
                term.bits_affecting_ascii_printer._.underline_style = false;
                term_update_ascii_printer(term);
            },
            25 => term.vt.attrs.blink = false,
            26 => {},
            27 => term.vt.attrs.reverse = false,
            28 => term.vt.attrs.conceal = false,
            29 => term.vt.attrs.strikethrough = false,

            // Regular foreground colors
            30, 31, 32, 33, 34, 35, 36, 37 => {
                term.vt.attrs.fg_src = @intCast(@intFromEnum(COLOR_BASE16));
                term.vt.attrs.fg = @intCast(param - 30);
            },

            38, 48, 58 => {
                var color: u32 = 0;
                var src: types.ColorSource = .default;
                var handled = true;

                // Indexed: 38;5;<idx>
                if (n - i - 1 >= 2 and params[i + 1].value == 5) {
                    src = COLOR_BASE256;
                    const idx: u32 = @min(params[i + 2].value, 255);
                    color = idx;
                    i += 2;
                }
                // RGB: 38;2;<r>;<g>;<b>
                else if (n - i - 1 >= 4 and params[i + 1].value == 2) {
                    const r: u32 = @intCast(params[i + 2].value & 0xff);
                    const g: u32 = @intCast(params[i + 3].value & 0xff);
                    const b: u32 = @intCast(params[i + 4].value & 0xff);
                    src = COLOR_RGB;
                    color = (r << 16) | (g << 8) | b;
                    i += 4;
                }
                // Indexed: 38:5:<idx>
                else if (params[i].sub.idx >= 2 and params[i].sub.value[0] == 5) {
                    src = COLOR_BASE256;
                    color = @min(params[i].sub.value[1], 255);
                }
                // RGB: 38:2:<cs>:r:g:b OR 38:2:r:g:b
                else if (params[i].sub.idx >= 4 and params[i].sub.value[0] == 2) {
                    const have_cs: bool = params[i].sub.idx >= 5;
                    const cs_off: usize = if (have_cs) 0 else 1;
                    const r_idx: usize = 2 - cs_off;
                    const g_idx: usize = 3 - cs_off;
                    const b_idx: usize = 4 - cs_off;
                    const r: u32 = params[i].sub.value[r_idx] & 0xff;
                    const g: u32 = params[i].sub.value[g_idx] & 0xff;
                    const b: u32 = params[i].sub.value[b_idx] & 0xff;
                    src = COLOR_RGB;
                    color = (r << 16) | (g << 8) | b;
                } else {
                    handled = false;
                }

                if (!handled) break;

                if (param == 58) {
                    term.vt.underline.color_src = src;
                    term.vt.underline.color = color;
                    term.bits_affecting_ascii_printer._.underline_color = true;
                    term_update_ascii_printer(term);
                } else if (param == 38) {
                    term.vt.attrs.fg_src = @intCast(@intFromEnum(src));
                    term.vt.attrs.fg = @intCast(color);
                } else {
                    term.vt.attrs.bg_src = @intCast(@intFromEnum(src));
                    term.vt.attrs.bg = @intCast(color);
                }
            },

            39 => term.vt.attrs.fg_src = @intFromEnum(COLOR_DEFAULT),

            // Regular background colors
            40, 41, 42, 43, 44, 45, 46, 47 => {
                term.vt.attrs.bg_src = @intCast(@intFromEnum(COLOR_BASE16));
                term.vt.attrs.bg = @intCast(param - 40);
            },

            49 => term.vt.attrs.bg_src = @intFromEnum(COLOR_DEFAULT),

            59 => {
                term.vt.underline.color_src = COLOR_DEFAULT;
                term.vt.underline.color = 0;
                term.bits_affecting_ascii_printer._.underline_color = false;
                term_update_ascii_printer(term);
            },

            // Bright foreground colors
            90, 91, 92, 93, 94, 95, 96, 97 => {
                term.vt.attrs.fg_src = @intCast(@intFromEnum(COLOR_BASE16));
                term.vt.attrs.fg = @intCast(param - 90 + 8);
            },

            // Bright background colors
            100, 101, 102, 103, 104, 105, 106, 107 => {
                term.vt.attrs.bg_src = @intCast(@intFromEnum(COLOR_BASE16));
                term.vt.attrs.bg = @intCast(param - 100 + 8);
            },

            else => {}, // UNHANDLED_SGR — logged in C, no-op in Zig for now
        }
    }
}

