const std = @import("std");
const types = @import("terminal_types.zig");



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

// ─── Chunk B: xtsave + xtrestore ───────────────────────────────────
// Save/restore of DEC private mode state (XTSAVE / XTRESTORE).

// Externs for values not directly in terminal_types.zig
extern fn term_save_cursor(term: *types.Terminal) callconv(.c) void;
extern fn term_ime_is_enabled(term: *types.Terminal) callconv(.c) bool;
extern fn decset_decrst(term: *types.Terminal, param: c_uint, enable: bool) callconv(.c) void;

extern fn csi_xtsave_get(term: *types.Terminal, bit: c_uint) callconv(.c) bool;
extern fn csi_grapheme_shaping(term: *types.Terminal) callconv(.c) bool;
extern fn csi_size_notifications(term: *types.Terminal) callconv(.c) bool;
extern fn csi_xtsave_set(term: *types.Terminal, bit: c_uint, v: bool) callconv(.c) void;

// sixel-shim.c accessors (already exist)
extern fn sixel_get_scrolling(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_use_private_palette(term: *types.Terminal) callconv(.c) bool;
extern fn sixel_get_cursor_right_of_graphics(term: *types.Terminal) callconv(.c) bool;

// xtsave bit indices (matches C declaration order in terminal.h)
const XTSAVE_ORIGIN: c_uint = 0;
const XTSAVE_APPLICATION_CURSOR_KEYS: c_uint = 1;
const XTSAVE_APPLICATION_KEYPAD_KEYS: c_uint = 2;
const XTSAVE_REVERSE: c_uint = 3;
const XTSAVE_SHOW_CURSOR: c_uint = 4;
const XTSAVE_REVERSE_WRAP: c_uint = 5;
const XTSAVE_AUTO_MARGIN: c_uint = 6;
const XTSAVE_CURSOR_BLINK: c_uint = 7;
const XTSAVE_BRACKETED_PASTE: c_uint = 8;
const XTSAVE_FOCUS_EVENTS: c_uint = 9;
const XTSAVE_VISIBILITY_REPORTS: c_uint = 10;
const XTSAVE_ALT_SCROLLING: c_uint = 11;
const XTSAVE_MOUSE_CLICK: c_uint = 12;
const XTSAVE_MOUSE_DRAG: c_uint = 13;
const XTSAVE_MOUSE_MOTION: c_uint = 14;
const XTSAVE_MOUSE_SGR: c_uint = 15;
const XTSAVE_MOUSE_URXVT: c_uint = 16;
const XTSAVE_MOUSE_SGR_PIXELS: c_uint = 17;
const XTSAVE_META_EIGHT_BIT: c_uint = 18;
const XTSAVE_META_ESC_PREFIX: c_uint = 19;
const XTSAVE_NUM_LOCK_MODIFIER: c_uint = 20;
const XTSAVE_BELL_ACTION_ENABLED: c_uint = 21;
const XTSAVE_ALT_SCREEN: c_uint = 22;
const XTSAVE_IME: c_uint = 23;
const XTSAVE_APP_SYNC_UPDATES: c_uint = 24;
const XTSAVE_GRAPHEME_SHAPING: c_uint = 25;
const XTSAVE_REPORT_THEME_CHANGES: c_uint = 26;
const XTSAVE_SIZE_NOTIFICATIONS: c_uint = 27;
const XTSAVE_SIXEL_DISPLAY_MODE: c_uint = 28;
const XTSAVE_SIXEL_PRIVATE_PALETTE: c_uint = 29;
const XTSAVE_SIXEL_CURSOR_RIGHT_OF_GRAPHICS: c_uint = 30;

// Enum values we compare against (from terminal_types.zig)
const CURSOR_KEYS_APPLICATION: types.CursorKeys = .application;
const KEYPAD_APPLICATION: types.KeypadKeys = .application;
const MOUSE_X10: types.MouseTracking = .x10;
const MOUSE_CLICK: types.MouseTracking = .click;
const MOUSE_DRAG: types.MouseTracking = .drag;
const MOUSE_MOTION: types.MouseTracking = .motion;
const MOUSE_UTF8: types.MouseReporting = .utf8;
const MOUSE_SGR: types.MouseReporting = .sgr;
const MOUSE_URXVT: types.MouseReporting = .urxvt;
const MOUSE_SGR_PIXELS: types.MouseReporting = .sgr_pixels;

// ── xtsave ────────────────────────────────────────────────────────
export fn xtsave(term: *types.Terminal, param: c_uint) callconv(.c) void {
    switch (param) {
        1 => csi_xtsave_set(term, XTSAVE_APPLICATION_CURSOR_KEYS, term.cursor_keys_mode == CURSOR_KEYS_APPLICATION),
        5 => csi_xtsave_set(term, XTSAVE_REVERSE, term.reverse),
        6 => csi_xtsave_set(term, XTSAVE_ORIGIN, @intFromEnum(term.origin) != 0),
        7 => csi_xtsave_set(term, XTSAVE_AUTO_MARGIN, term.auto_margin),
        9 => {}, // mouse_x10 disabled
        12 => csi_xtsave_set(term, XTSAVE_CURSOR_BLINK, term.cursor_blink.decset),
        25 => csi_xtsave_set(term, XTSAVE_SHOW_CURSOR, !term.hide_cursor),
        45 => csi_xtsave_set(term, XTSAVE_REVERSE_WRAP, term.reverse_wrap),
        47 => csi_xtsave_set(term, XTSAVE_ALT_SCREEN, term.grid == &term.alt),
        66 => csi_xtsave_set(term, XTSAVE_APPLICATION_KEYPAD_KEYS, term.keypad_keys_mode == KEYPAD_APPLICATION),
        67 => {},
        80 => csi_xtsave_set(term, XTSAVE_SIXEL_DISPLAY_MODE, !sixel_get_scrolling(term)),
        1000 => csi_xtsave_set(term, XTSAVE_MOUSE_CLICK, term.mouse_tracking == MOUSE_CLICK),
        1001 => {},
        1002 => csi_xtsave_set(term, XTSAVE_MOUSE_DRAG, term.mouse_tracking == MOUSE_DRAG),
        1003 => csi_xtsave_set(term, XTSAVE_MOUSE_MOTION, term.mouse_tracking == MOUSE_MOTION),
        1004 => csi_xtsave_set(term, XTSAVE_FOCUS_EVENTS, term.focus_events),
        1005 => {}, // mouse_utf8 disabled
        1006 => csi_xtsave_set(term, XTSAVE_MOUSE_SGR, term.mouse_reporting == MOUSE_SGR),
        1007 => csi_xtsave_set(term, XTSAVE_ALT_SCROLLING, term.alt_scrolling),
        1015 => csi_xtsave_set(term, XTSAVE_MOUSE_URXVT, term.mouse_reporting == MOUSE_URXVT),
        1016 => csi_xtsave_set(term, XTSAVE_MOUSE_SGR_PIXELS, term.mouse_reporting == MOUSE_SGR_PIXELS),
        1034 => csi_xtsave_set(term, XTSAVE_META_EIGHT_BIT, term.meta.eight_bit),
        1035 => csi_xtsave_set(term, XTSAVE_NUM_LOCK_MODIFIER, term.num_lock_modifier),
        1036 => csi_xtsave_set(term, XTSAVE_META_ESC_PREFIX, term.meta.esc_prefix),
        1042 => csi_xtsave_set(term, XTSAVE_BELL_ACTION_ENABLED, term.bell_action_enabled),
        1047 => csi_xtsave_set(term, XTSAVE_ALT_SCREEN, term.grid == &term.alt),
        1048 => term_save_cursor(term),
        1049 => csi_xtsave_set(term, XTSAVE_ALT_SCREEN, term.grid == &term.alt),
        1070 => csi_xtsave_set(term, XTSAVE_SIXEL_PRIVATE_PALETTE, sixel_get_use_private_palette(term)),
        2004 => csi_xtsave_set(term, XTSAVE_BRACKETED_PASTE, term.bracketed_paste),
        2026 => csi_xtsave_set(term, XTSAVE_APP_SYNC_UPDATES, term.render.app_sync_updates.enabled),
        2027 => csi_xtsave_set(term, XTSAVE_GRAPHEME_SHAPING, csi_grapheme_shaping(term)),
        2031 => csi_xtsave_set(term, XTSAVE_REPORT_THEME_CHANGES, term.report_theme_changes),
        2033 => csi_xtsave_set(term, XTSAVE_VISIBILITY_REPORTS, term.visibility_reports),
        2048 => csi_xtsave_set(term, XTSAVE_SIZE_NOTIFICATIONS, csi_size_notifications(term)),
        8452 => csi_xtsave_set(term, XTSAVE_SIXEL_CURSOR_RIGHT_OF_GRAPHICS, sixel_get_cursor_right_of_graphics(term)),
        737769 => csi_xtsave_set(term, XTSAVE_IME, term_ime_is_enabled(term)),
        else => {},
    }
}

// ── xtrestore ─────────────────────────────────────────────────────
export fn xtrestore(term: *types.Terminal, param: c_uint) callconv(.c) void {
    var enable: bool = false;
    switch (param) {
        1 => enable = csi_xtsave_get(term, XTSAVE_APPLICATION_CURSOR_KEYS),
        5 => enable = csi_xtsave_get(term, XTSAVE_REVERSE),
        6 => enable = csi_xtsave_get(term, XTSAVE_ORIGIN),
        7 => enable = csi_xtsave_get(term, XTSAVE_AUTO_MARGIN),
        9 => return,
        12 => enable = csi_xtsave_get(term, XTSAVE_CURSOR_BLINK),
        25 => enable = csi_xtsave_get(term, XTSAVE_SHOW_CURSOR),
        45 => enable = csi_xtsave_get(term, XTSAVE_REVERSE_WRAP),
        47 => enable = csi_xtsave_get(term, XTSAVE_ALT_SCREEN),
        66 => enable = csi_xtsave_get(term, XTSAVE_APPLICATION_KEYPAD_KEYS),
        67 => return,
        80 => enable = csi_xtsave_get(term, XTSAVE_SIXEL_DISPLAY_MODE),
        1000 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_CLICK),
        1001 => return,
        1002 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_DRAG),
        1003 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_MOTION),
        1004 => enable = csi_xtsave_get(term, XTSAVE_FOCUS_EVENTS),
        1005 => return,
        1006 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_SGR),
        1007 => enable = csi_xtsave_get(term, XTSAVE_ALT_SCROLLING),
        1015 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_URXVT),
        1016 => enable = csi_xtsave_get(term, XTSAVE_MOUSE_SGR_PIXELS),
        1034 => enable = csi_xtsave_get(term, XTSAVE_META_EIGHT_BIT),
        1035 => enable = csi_xtsave_get(term, XTSAVE_NUM_LOCK_MODIFIER),
        1036 => enable = csi_xtsave_get(term, XTSAVE_META_ESC_PREFIX),
        1042 => enable = csi_xtsave_get(term, XTSAVE_BELL_ACTION_ENABLED),
        1047 => enable = csi_xtsave_get(term, XTSAVE_ALT_SCREEN),
        1048 => enable = true,
        1049 => enable = csi_xtsave_get(term, XTSAVE_ALT_SCREEN),
        1070 => enable = csi_xtsave_get(term, XTSAVE_SIXEL_PRIVATE_PALETTE),
        2004 => enable = csi_xtsave_get(term, XTSAVE_BRACKETED_PASTE),
        2026 => enable = csi_xtsave_get(term, XTSAVE_APP_SYNC_UPDATES),
        2027 => enable = csi_xtsave_get(term, XTSAVE_GRAPHEME_SHAPING),
        2031 => enable = csi_xtsave_get(term, XTSAVE_REPORT_THEME_CHANGES),
        2033 => enable = csi_xtsave_get(term, XTSAVE_VISIBILITY_REPORTS),
        2048 => enable = csi_xtsave_get(term, XTSAVE_SIZE_NOTIFICATIONS),
        8452 => enable = csi_xtsave_get(term, XTSAVE_SIXEL_CURSOR_RIGHT_OF_GRAPHICS),
        737769 => enable = csi_xtsave_get(term, XTSAVE_IME),
        else => return,
    }

    decset_decrst(term, param, enable);
}

