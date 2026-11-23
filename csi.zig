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

// ─── Chunk C1: decset_decrst + decset + decrst ─────────────────────
// DECSET/DECRST — 65 DEC private modes (set/reset).

// libc
extern fn malloc(size: usize) callconv(.c) ?*anyopaque;

// term_* externs (many already declared in chunk A/B; adding only new ones)
extern fn term_damage_all(term: *types.Terminal) callconv(.c) void;
extern fn term_damage_margins(term: *types.Terminal) callconv(.c) void;
extern fn term_damage_view(term: *types.Terminal) callconv(.c) void;
extern fn term_cursor_home(term: *types.Terminal) callconv(.c) void;
extern fn term_cursor_to(term: *types.Terminal, row: c_int, col: c_int) callconv(.c) void;
extern fn term_cursor_blink_update(term: *types.Terminal) callconv(.c) void;
extern fn term_xcursor_update(term: *types.Terminal) callconv(.c) void;
extern fn term_restore_cursor(term: *types.Terminal, cursor: *types.Cursor) callconv(.c) void;
extern fn term_erase(term: *types.Terminal, start_row: c_int, start_col: c_int, end_row: c_int, end_col: c_int) callconv(.c) void;
extern fn term_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;
extern fn term_enable_app_sync_updates(term: *types.Terminal) callconv(.c) void;
extern fn term_disable_app_sync_updates(term: *types.Terminal) callconv(.c) void;
extern fn term_send_visibility_report(term: *types.Terminal) callconv(.c) void;
extern fn term_enable_size_notifications(term: *types.Terminal) callconv(.c) void;
extern fn term_disable_size_notifications(term: *types.Terminal) callconv(.c) void;
extern fn term_ime_enable(term: *types.Terminal) callconv(.c) void;
extern fn term_ime_disable(term: *types.Terminal) callconv(.c) void;

// selection.c
extern fn selection_cancel(term: *types.Terminal) callconv(.c) void;

// sixel.c
extern fn sixel_destroy(sixel: *types.Sixel) callconv(.c) void;



// ── Helpers for tll-style lists in terminal_types.zig ─────────────
// DamageList/SixelList are 'extern struct { head, tail, length }' in
// terminal_types.zig. They're byte-compatible with Tll(T) but not the
// same Zig type. These helpers avoid the @ptrCast dance.

fn freeDamageList(list: *types.DamageList) void {
    var it: ?*IntNode = @ptrCast(@alignCast(list.head));
    while (it) |node| {
        const next = node.next;
        free(@ptrCast(node));
        it = next;
    }
    list.length = 0;
    list.head = null;
    list.tail = null;
}

fn freeNode_removeSixel(list: *types.SixelList, node: *types.SixelNode) void {
    const prev = node.prev;
    const next = node.next;
    if (prev) |p| p.next = next else list.head = next;
    if (next) |n| n.prev = prev else list.tail = prev;
    free(@ptrCast(node));
    list.length -= 1;
}

// sixel-shim.c setters
extern fn sixel_set_scrolling(term: *types.Terminal, v: bool) callconv(.c) void;
extern fn sixel_set_use_private_palette(term: *types.Terminal, v: bool) callconv(.c) void;
extern fn sixel_set_cursor_right_of_graphics(term: *types.Terminal, v: bool) callconv(.c) void;

// csi-shim.c url accessor
extern fn csi_set_url_ime_reenable_after_url_mode(term: *types.Terminal, v: bool) callconv(.c) void;

// tll helpers

// ── decset_decrst ─────────────────────────────────────────────────
export fn decset_decrst(term: *types.Terminal, param: c_uint, enable: bool) callconv(.c) void {
    switch (param) {
        1 => { // DECCKM
            term.cursor_keys_mode = if (enable) .application else .normal;
        },
        5 => { // DECSCNM
            term.reverse = enable;
            term_damage_all(term);
            term_damage_margins(term);
        },
        6 => { // DECOM
            term.origin = if (enable) .relative else .absolute;
            term_cursor_home(term);
        },
        7 => { // DECAWM
            term.auto_margin = enable;
            const grid = term.grid orelse return;
            grid.cursor.lcf = false;
        },
        9 => {
            // X10 mouse tracking: unimplemented, warn only
        },
        12 => { // cursor blink
            term.cursor_blink.decset = enable;
            term_cursor_blink_update(term);
        },
        25 => { // DECTCEM
            term.hide_cursor = !enable;
        },
        45 => {
            term.reverse_wrap = enable;
        },
        66 => { // DECNKM
            term.keypad_keys_mode = if (enable) .application else .numerical;
        },
        67 => {
            // DECBKM: unimplemented, warn only
        },
        80 => {
            sixel_set_scrolling(term, !enable);
        },
        1000 => {
            if (enable) term.mouse_tracking = .click
            else if (term.mouse_tracking == .click) term.mouse_tracking = .none;
            term_xcursor_update(term);
        },
        1001 => {
            // highlight mouse tracking: unimplemented
        },
        1002 => {
            if (enable) term.mouse_tracking = .drag
            else if (term.mouse_tracking == .drag) term.mouse_tracking = .none;
            term_xcursor_update(term);
        },
        1003 => {
            if (enable) term.mouse_tracking = .motion
            else if (term.mouse_tracking == .motion) term.mouse_tracking = .none;
            term_xcursor_update(term);
        },
        1004 => {
            term.focus_events = enable;
            if (enable) {
                const report: []const u8 = if (term.kbd_focus) "\x1b[I" else "\x1b[O";
                term_to_slave(term, report.ptr, report.len);
            }
        },
        1005 => {
            // mouse UTF-8 mode: unimplemented
        },
        1006 => {
            if (enable) term.mouse_reporting = .sgr
            else if (term.mouse_reporting == .sgr) term.mouse_reporting = .normal;
        },
        1007 => {
            term.alt_scrolling = enable;
        },
        1015 => {
            if (enable) term.mouse_reporting = .urxvt
            else if (term.mouse_reporting == .urxvt) term.mouse_reporting = .normal;
        },
        1016 => {
            if (enable) term.mouse_reporting = .sgr_pixels
            else if (term.mouse_reporting == .sgr_pixels) term.mouse_reporting = .normal;
        },
        1034 => { // smm
            term.meta.eight_bit = enable;
        },
        1035 => { // numLock
            term.num_lock_modifier = enable;
        },
        1036 => { // metaSendsEscape
            term.meta.esc_prefix = enable;
        },
        1042 => {
            term.bell_action_enabled = enable;
        },
        1048 => {
            if (enable) term_save_cursor(term)
            else {
                const grid = term.grid orelse return;
                term_restore_cursor(term, &grid.saved_cursor);
            }
        },
        47, 1047, 1049 => {
            const alt_ptr: *types.Grid = &term.alt;
            if (enable and term.grid != alt_ptr) {
                selection_cancel(term);
                if (param == 1049) term_save_cursor(term);
                term.grid = alt_ptr;

                // Cursor retains position from normal grid
                const row = @min(term.normal.cursor.point.row, term.rows - 1);
                const col = @min(term.normal.cursor.point.col, term.cols - 1);
                term_cursor_to(term, row, col);

                freeDamageList(&term.normal.scroll_damage);
                term_erase(term, 0, 0, term.rows - 1, term.cols - 1);
            } else if (!enable and term.grid == alt_ptr) {
                selection_cancel(term);
                term.grid = &term.normal;

                // Cursor retains position from alt grid
                const row = @min(term.alt.cursor.point.row, term.rows - 1);
                const col = @min(term.alt.cursor.point.col, term.cols - 1);
                term_cursor_to(term, row, col);

                if (param == 1049) {
                    const grid = term.grid orelse return;
                    term_restore_cursor(term, &grid.saved_cursor);
                }

                // Delete all sixel images on the alt screen
                var it: ?*types.SixelNode = term.alt.sixel_images.head;
                while (it) |node| {
                    const next: ?*types.SixelNode = node.next;
                    sixel_destroy(&node.item);
                    freeNode_removeSixel(&term.alt.sixel_images, node);
                    it = next;
                }

                freeDamageList(&term.alt.scroll_damage);
                term_damage_view(term);
            }

            const cur_grid = term.grid orelse return;
            term.bits_affecting_ascii_printer._.sixels = cur_grid.sixel_images.length > 0;
            term_update_ascii_printer(term);
        },
        1070 => {
            sixel_set_use_private_palette(term, enable);
        },
        2004 => {
            term.bracketed_paste = enable;
        },
        2026 => {
            if (enable) term_enable_app_sync_updates(term)
            else term_disable_app_sync_updates(term);
        },
        2027 => {
            // FOOT_GRAPHEME_CLUSTERING guard — assume always on
            csi_set_grapheme_shaping_direct(term, enable);
        },
        2031 => {
            term.report_theme_changes = enable;
        },
        2033 => {
            term.visibility_reports = enable;
            if (enable) term_send_visibility_report(term);
        },
        2048 => {
            if (enable) term_enable_size_notifications(term)
            else term_disable_size_notifications(term);
        },
        8452 => {
            sixel_set_cursor_right_of_graphics(term, enable);
        },
        737769 => {
            if (enable) term_ime_enable(term)
            else {
                term_ime_disable(term);
                csi_set_url_ime_reenable_after_url_mode(term, false);
            }
        },
        else => {},
    }
}

// grapheme_shaping needs the csi-shim.c setter (already exists)
extern fn csi_set_grapheme_shaping(term: *types.Terminal, v: bool) callconv(.c) void;

// Helper: direct setter wrapper (name collision with shim fn avoided)
fn csi_set_grapheme_shaping_direct(term: *types.Terminal, v: bool) void {
    csi_set_grapheme_shaping(term, v);
}

export fn decset(term: *types.Terminal, param: c_uint) callconv(.c) void {
    decset_decrst(term, param, true);
}

export fn decrst(term: *types.Terminal, param: c_uint) callconv(.c) void {
    decset_decrst(term, param, false);
}

// ─── Chunk D: params_to_rectangular_area ──────────────────────────
// Parses 4 CSI params (top;left;bottom;right) into absolute coordinates.
// Returns false if the rectangle is degenerate.

extern fn term_row_rel_to_abs(term: *const types.Terminal, row: c_int) callconv(.c) c_int;

// Inline vt_param_get (was static inline in vt.h)
fn vtParamGet(term: *const types.Terminal, idx: usize, default_value: c_int) c_int {
    const value_mask: c_uint = 0x7fff_ffff;
    if (@as(usize, term.vt.params.idx) > idx) {
        const value: c_uint = term.vt.params.v[idx].value & value_mask;
        return if (value != 0) @intCast(value) else default_value;
    }
    return default_value;
}

export fn params_to_rectangular_area(
    term: *const types.Terminal,
    first_idx: c_int,
    top: *c_int,
    left: *c_int,
    bottom: *c_int,
    right: *c_int,
) callconv(.c) bool {
    const rel_top: c_int = vtParamGet(term, @intCast(first_idx + 0), 1) - 1;
    left.* = @min(vtParamGet(term, @intCast(first_idx + 1), 1) - 1, term.cols - 1);
    const rel_bottom: c_int = vtParamGet(term, @intCast(first_idx + 2), term.rows) - 1;
    right.* = @min(vtParamGet(term, @intCast(first_idx + 3), term.cols) - 1, term.cols - 1);

    if (rel_top > rel_bottom or left.* > right.*) return false;

    top.* = term_row_rel_to_abs(term, rel_top);
    bottom.* = term_row_rel_to_abs(term, rel_bottom);
    return true;
}

// ─── Chunk C2: decrpm + decrqm ─────────────────────────────────────
// DECRQM — DEC Private Mode Report. Returns the current state of a
// DEC private mode as a DECRPM status code (0..4).

const DecrpmStatus = enum(c_int) {
    not_recognized = 0,
    set = 1,
    reset = 2,
    permanently_set = 3,
    permanently_reset = 4,
};

fn decrpm(enabled: bool) DecrpmStatus {
    return if (enabled) .set else .reset;
}

// GRAPHEME_WIDTH_* enum values (from config.h)
const GRAPHEME_WIDTH_DOUBLE: c_int = 2;

extern fn csi_conf_grapheme_width_method(term: *types.Terminal) callconv(.c) c_int;

export fn decrqm(term: *const types.Terminal, param: c_uint) callconv(.c) DecrpmStatus {
    const t: *types.Terminal = @constCast(term);
    return switch (param) {
        1 => decrpm(term.cursor_keys_mode == .application),
        5 => decrpm(term.reverse),
        6 => decrpm(term.origin == .relative),
        7 => decrpm(term.auto_margin),
        9 => .permanently_reset,
        12 => decrpm(term.cursor_blink.decset),
        25 => decrpm(!term.hide_cursor),
        45 => decrpm(term.reverse_wrap),
        66 => decrpm(term.keypad_keys_mode == .application),
        67 => .permanently_reset,
        80 => decrpm(!sixel_get_scrolling(t)),
        1000 => decrpm(term.mouse_tracking == .click),
        1001 => .permanently_reset,
        1002 => decrpm(term.mouse_tracking == .drag),
        1003 => decrpm(term.mouse_tracking == .motion),
        1004 => decrpm(term.focus_events),
        1005 => .permanently_reset,
        1006 => decrpm(term.mouse_reporting == .sgr),
        1007 => decrpm(term.alt_scrolling),
        1015 => decrpm(term.mouse_reporting == .urxvt),
        1016 => decrpm(term.mouse_reporting == .sgr_pixels),
        1034 => decrpm(term.meta.eight_bit),
        1035 => decrpm(term.num_lock_modifier),
        1036 => decrpm(term.meta.esc_prefix),
        1042 => decrpm(term.bell_action_enabled),
        47, 1047, 1049 => decrpm(term.grid == &term.alt),
        1070 => decrpm(sixel_get_use_private_palette(t)),
        2004 => decrpm(term.bracketed_paste),
        2026 => decrpm(term.render.app_sync_updates.enabled),
        2027 => if (csi_conf_grapheme_width_method(t) != GRAPHEME_WIDTH_DOUBLE)
            .permanently_reset
        else
            decrpm(csi_grapheme_shaping(t)),
        2031 => decrpm(term.report_theme_changes),
        2033 => decrpm(term.visibility_reports),
        2048 => decrpm(csi_size_notifications(t)),
        8452 => decrpm(sixel_get_cursor_right_of_graphics(t)),
        737769 => decrpm(term_ime_is_enabled(t)),
        else => .not_recognized,
    };
}

// ─── Chunk E1: csi_dispatch — helpers + externs ───────────────────

// Cursor movement
extern fn term_cursor_up(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_down(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_left(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_right(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_col(term: *types.Terminal, col: c_int) callconv(.c) void;

// Print/erase/scroll
extern fn term_print(term: *types.Terminal, wc: u32, width: c_int, insert: bool) callconv(.c) void;
extern fn term_erase_scrollback(term: *types.Terminal) callconv(.c) void;
extern fn term_scroll(term: *types.Terminal, amount: c_int) callconv(.c) void;
extern fn term_scroll_reverse(term: *types.Terminal, amount: c_int) callconv(.c) void;
extern fn term_scroll_partial(term: *types.Terminal, region: types.ScrollRegion, amount: c_int) callconv(.c) void;
extern fn term_scroll_reverse_partial(term: *types.Terminal, region: types.ScrollRegion, amount: c_int) callconv(.c) void;

// char32 / composed
extern fn csi_c32width(c: u32) callconv(.c) c_int;
extern fn composed_lookup(composed: ?*types.Composed, key: u32) callconv(.c) ?*types.Composed;

// libc
extern fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn snprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int;

// csi-shim.c config accessors
extern fn csi_conf_tweak_sixel(term: *types.Terminal) callconv(.c) bool;
extern fn csi_conf_security_osc52(term: *types.Terminal) callconv(.c) c_int;

const OSC52_ENABLED: c_int = 3;
const OSC52_COPY_ENABLED: c_int = 1;

// CELL_COMB_CHARS_LO from terminal_types.zig
const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;

// ── csi_dispatch ──────────────────────────────────────────────────
export fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void {
    switch (term.vt.private) {
        0 => case0Dispatch(term, final),
        else => {}, // TODO: cases '$', '>', '?', '!', '"', "'", '*', '+', '-', '=' as we fetch them
    }
}

// ── case 0: the big inner switch on `final` ──────────────────────
fn case0Dispatch(term: *types.Terminal, final: u8) void {
    switch (final) {
        'b' => blk: {
            if (term.vt.last_printed != 0) {
                const grid = term.grid orelse break :blk;
                const max_count: usize = @intCast(grid.num_rows * @as(c_int, @intCast(term.cols)));
                const count: c_int = @min(vtParamGet(term, 0, 1), @as(c_int, @intCast(max_count)));

                var width: c_int = undefined;
                if (term.vt.last_printed >= CELL_COMB_CHARS_LO) {
                    const comp = composed_lookup(term.composed, term.vt.last_printed - CELL_COMB_CHARS_LO);
                    if (comp) |c| {
                        width = if (c.forced_width > 0) c.forced_width else c.width;
                    } else {
                        break :blk;
                    }
                } else {
                    width = csi_c32width(term.vt.last_printed);
                }

                if (width > 0) {
                    var i: c_int = 0;
                    while (i < count) : (i += 1) {
                        term_print(term, term.vt.last_printed, width, false);
                    }
                }
            }
        },

        'c' => blk: {
            if (vtParamGet(term, 0, 0) != 0) break :blk;

            var reply: [32]u8 = undefined;
            const has_sixel = csi_conf_tweak_sixel(term);
            const osc52 = csi_conf_security_osc52(term);
            const has_osc52 = (osc52 == OSC52_ENABLED or osc52 == OSC52_COPY_ENABLED);

            const sixel_str: [*:0]const u8 = if (has_sixel) ";4" else "";
            const osc52_str: [*:0]const u8 = if (has_osc52) ";52" else "";

            const len = snprintf(&reply, reply.len, "\x1b[?62%s;22;28%sc", sixel_str, osc52_str);
            if (len > 0) {
                term_to_slave(term, &reply, @intCast(len));
            }
        },

        'd' => {
            const rel_row = vtParamGet(term, 0, 1) - 1;
            const row = term_row_rel_to_abs(term, rel_row);
            const grid = term.grid orelse return;
            term_cursor_to(term, row, grid.cursor.point.col);
        },

        'm' => csi_sgr(term),

        'A' => term_cursor_up(term, vtParamGet(term, 0, 1)),

        'e', 'B' => term_cursor_down(term, vtParamGet(term, 0, 1)),

        'a', 'C' => term_cursor_right(term, vtParamGet(term, 0, 1)),

        'D' => term_cursor_left(term, vtParamGet(term, 0, 1)),

        'E' => {
            term_cursor_down(term, vtParamGet(term, 0, 1));
            const grid = term.grid orelse return;
            term_cursor_left(term, grid.cursor.point.col);
        },

        'F' => {
            term_cursor_up(term, vtParamGet(term, 0, 1));
            const grid = term.grid orelse return;
            term_cursor_left(term, grid.cursor.point.col);
        },

        'g' => {
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                0 => {
                    const grid = term.grid orelse return;
                    var it: ?*IntNode = @ptrCast(@alignCast(term.tab_stops.head));
                    while (it) |node| {
                        const next: ?*IntNode = node.next;
                        if (node.item == grid.cursor.point.col) {
                            freeIntNode_remove(&term.tab_stops, node);
                        } else if (node.item > grid.cursor.point.col) {
                            break;
                        }
                        it = next;
                    }
                },
                3 => freeIntList(&term.tab_stops),
                else => {},
            }
        },

        '`', 'G' => {
            const col = @min(vtParamGet(term, 0, 1), term.cols) - 1;
            term_cursor_col(term, col);
        },

        'f', 'H' => {
            const rel_row = vtParamGet(term, 0, 1) - 1;
            const row = term_row_rel_to_abs(term, rel_row);
            const col = @min(vtParamGet(term, 1, 1), term.cols) - 1;
            term_cursor_to(term, row, col);
        },

        'J' => {
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                0 => {
                    const grid = term.grid orelse return;
                    term_erase(term, grid.cursor.point.row, grid.cursor.point.col, term.rows - 1, term.cols - 1);
                    grid.cursor.lcf = false;
                },
                1 => {
                    const grid = term.grid orelse return;
                    term_erase(term, 0, 0, grid.cursor.point.row, grid.cursor.point.col);
                    grid.cursor.lcf = false;
                },
                2 => {
                    term_erase(term, 0, 0, term.rows - 1, term.cols - 1);
                    if (term.grid) |g| g.cursor.lcf = false;
                },
                3 => term_erase_scrollback(term),
                else => {},
            }
        },

        'K' => {
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                0 => {
                    const grid = term.grid orelse return;
                    term_erase(term, grid.cursor.point.row, grid.cursor.point.col, grid.cursor.point.row, term.cols - 1);
                    grid.cursor.lcf = false;
                },
                1 => {
                    const grid = term.grid orelse return;
                    term_erase(term, grid.cursor.point.row, 0, grid.cursor.point.row, grid.cursor.point.col);
                    grid.cursor.lcf = false;
                },
                2 => {
                    const grid = term.grid orelse return;
                    term_erase(term, grid.cursor.point.row, 0, grid.cursor.point.row, term.cols - 1);
                    grid.cursor.lcf = false;
                },
                else => {},
            }
        },

        'L' => blk: {
            const grid = term.grid orelse break :blk;
            if (grid.cursor.point.row < term.scroll_region.start or grid.cursor.point.row >= term.scroll_region.end)
                break :blk;
            const count = @min(vtParamGet(term, 0, 1), term.scroll_region.end - grid.cursor.point.row);
            term_scroll_reverse_partial(term, .{ .start = grid.cursor.point.row, .end = term.scroll_region.end }, count);
            grid.cursor.lcf = false;
            grid.cursor.point.col = 0;
        },

        'M' => blk: {
            const grid = term.grid orelse break :blk;
            if (grid.cursor.point.row < term.scroll_region.start or grid.cursor.point.row >= term.scroll_region.end)
                break :blk;
            const count = @min(vtParamGet(term, 0, 1), term.scroll_region.end - grid.cursor.point.row);
            term_scroll_partial(term, .{ .start = grid.cursor.point.row, .end = term.scroll_region.end }, count);
            grid.cursor.lcf = false;
            grid.cursor.point.col = 0;
        },

        'P' => blk: {
            const grid = term.grid orelse break :blk;
            const cur_row = grid.cur_row orelse break :blk;
            const cells = cur_row.cells orelse break :blk;
            const count = @min(vtParamGet(term, 0, 1), term.cols - grid.cursor.point.col);
            const remaining = term.cols - (grid.cursor.point.col + count);
            const col: usize = @intCast(grid.cursor.point.col);
            const cnt: usize = @intCast(count);
            const rem: usize = @intCast(remaining);
            const cell_size = @sizeOf(types.Cell);
            _ = memmove(&cells[col], &cells[col + cnt], rem * cell_size);
            var c: usize = 0;
            while (c < rem) : (c += 1) {
                cells[col + c].attrs.clean = false;
            }
            cur_row.dirty = true;
            term_erase(term, grid.cursor.point.row, grid.cursor.point.col + remaining, grid.cursor.point.row, term.cols - 1);
            grid.cursor.lcf = false;
        },

        '@' => blk: {
            const grid = term.grid orelse break :blk;
            const cur_row = grid.cur_row orelse break :blk;
            const cells = cur_row.cells orelse break :blk;
            const count = @min(vtParamGet(term, 0, 1), term.cols - grid.cursor.point.col);
            const remaining = term.cols - (grid.cursor.point.col + count);
            const col: usize = @intCast(grid.cursor.point.col);
            const cnt: usize = @intCast(count);
            const rem: usize = @intCast(remaining);
            const cell_size = @sizeOf(types.Cell);
            _ = memmove(&cells[col + cnt], &cells[col], rem * cell_size);
            var c: usize = 0;
            while (c < rem) : (c += 1) {
                cells[col + cnt + c].attrs.clean = false;
            }
            cur_row.dirty = true;
            term_erase(term, grid.cursor.point.row, grid.cursor.point.col, grid.cursor.point.row, grid.cursor.point.col + count - 1);
            grid.cursor.lcf = false;
        },

        'S' => {
            const amount = @min(vtParamGet(term, 0, 1), term.scroll_region.end - term.scroll_region.start);
            term_scroll(term, amount);
        },

        'T' => {
            const amount = @min(vtParamGet(term, 0, 1), term.scroll_region.end - term.scroll_region.start);
            term_scroll_reverse(term, amount);
        },

        'X' => blk: {
            const grid = term.grid orelse break :blk;
            const count = @min(vtParamGet(term, 0, 1), term.cols - grid.cursor.point.col);
            term_erase(term, grid.cursor.point.row, grid.cursor.point.col, grid.cursor.point.row, grid.cursor.point.col + count - 1);
            grid.cursor.lcf = false;
        },

        'I' => {
            var count = vtParamGet(term, 0, 1);
            const grid = term.grid orelse return;
            var new_col = grid.cursor.point.col;
            var it: ?*IntNode = @ptrCast(@alignCast(term.tab_stops.head));
            while (it) |node| {
                if (node.item > new_col) {
                    count -= 1;
                    if (count < 0) break;
                    new_col = node.item;
                }
                it = node.next;
            }
            const lcf = grid.cursor.lcf;
            term_cursor_right(term, new_col - grid.cursor.point.col);
            if (term.grid) |g| g.cursor.lcf = lcf;
        },

        'Z' => {
            var count = vtParamGet(term, 0, 1);
            const grid = term.grid orelse return;
            var new_col = grid.cursor.point.col;
            var it: ?*IntNode = @ptrCast(@alignCast(term.tab_stops.tail));
            while (it) |node| {
                if (node.item < new_col) {
                    count -= 1;
                    if (count < 0) break;
                    new_col = node.item;
                }
                it = node.prev;
            }
            term_cursor_left(term, grid.cursor.point.col - new_col);
        },

        else => case0Extra(term, final),
    }
}

// ── Helpers for TllInt (tab_stops list) ──────────────────────────
const IntNode = extern struct {
    item: c_int,
    prev: ?*IntNode,
    next: ?*IntNode,
};
const IntList = types.TllInt;


fn freeIntNode_remove(list: *IntList, node: *IntNode) void {
    const prev = node.prev;
    const next = node.next;
    if (prev) |p| p.next = next else list.head = next;
    if (next) |n| n.prev = prev else list.tail = prev;
    free(@ptrCast(node));
    list.length -= 1;
}

fn freeIntList(list: *IntList) void {
    var it: ?*IntNode = @ptrCast(@alignCast(list.head));
    while (it) |node| {
        const next = node.next;
        free(@ptrCast(node));
        it = next;
    }
    list.length = 0;
    list.head = null;
    list.tail = null;
}

// ─── Chunk E2: case 0, additional finals (h/l/r/s/u/t/n) ──────────

extern fn term_set_window_title(term: *types.Terminal, title: [*:0]const u8) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xsnprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) callconv(.c) usize;
extern fn strlen(s: [*:0]const u8) callconv(.c) usize;

// csi-shim.c window helpers
extern fn csi_window_first_output_px_width(term: *types.Terminal) callconv(.c) c_int;
extern fn csi_window_first_output_px_height(term: *types.Terminal) callconv(.c) c_int;
extern fn csi_window_on_outputs_count(term: *types.Terminal) callconv(.c) c_int;
extern fn csi_window_title_stack_len(term: *types.Terminal) callconv(.c) usize;
extern fn csi_window_title_stack_push(term: *types.Terminal, title: ?[*:0]u8) callconv(.c) void;
extern fn csi_window_title_stack_pop(term: *types.Terminal) callconv(.c) ?[*:0]u8;

// ── Additional final cases ────────────────────────────────────────
fn case0Extra(term: *types.Terminal, final: u8) void {
    switch (final) {
        'h', 'l' => blk: {
            const param = vtParamGet(term, 0, 0);
            const sm = (final == 'h');
            if (param == 4) {
                term.insert_mode = sm;
                term.bits_affecting_ascii_printer._.insert_mode = sm;
                term_update_ascii_printer(term);
                break :blk;
            }
            // All other ECMA-48 SM/RM modes are unimplemented
        },

        'r' => {
            const start = vtParamGet(term, 0, 1);
            const end = @min(vtParamGet(term, 1, term.rows), term.rows);
            if (end > start) {
                term.scroll_region.start = start - 1;
                term.scroll_region.end = end;
                term_cursor_home(term);
            }
        },

        's' => term_save_cursor(term),

        'u' => {
            const grid = term.grid orelse return;
            term_restore_cursor(term, &grid.saved_cursor);
        },

        't' => {
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 24 => {}, // unimplemented
                11 => { // report iconified — always report not-iconified
                    term_to_slave(term, "\x1b[1t", 4);
                },
                13 => { // report window position — always (0,0)
                    const reply = "\x1b[3;0;0t";
                    switch (vtParamGet(term, 1, 0)) {
                        0, 2 => term_to_slave(term, reply.ptr, reply.len),
                        else => {},
                    }
                },
                14 => { // report window size in pixels
                    var width: c_int = -1;
                    var height: c_int = -1;
                    switch (vtParamGet(term, 1, 0)) {
                        0 => { // text area size
                            width = term.width - term.margins.left - term.margins.right;
                            height = term.height - term.margins.top - term.margins.bottom;
                        },
                        2 => { // window size
                            width = term.width;
                            height = term.height;
                        },
                        else => {},
                    }
                    if (width >= 0 and height >= 0) {
                        var reply: [64]u8 = undefined;
                        const n = xsnprintf(&reply, reply.len, "\x1b[4;%d;%dt", height, width);
                        term_to_slave(term, &reply, n);
                    }
                },
                15 => { // report screen size in pixels
                    const w = csi_window_first_output_px_width(term);
                    const h = csi_window_first_output_px_height(term);
                    if (w >= 0 and h >= 0) {
                        var reply: [64]u8 = undefined;
                        const n = xsnprintf(&reply, reply.len, "\x1b[5;%d;%dt", h, w);
                        term_to_slave(term, &reply, n);
                    } else {
                        term_to_slave(term, "\x1b[5;0;0t", 8);
                    }
                },
                16 => { // report cell size in pixels
                    var reply: [64]u8 = undefined;
                    const n = xsnprintf(&reply, reply.len, "\x1b[6;%d;%dt", term.cell_height, term.cell_width);
                    term_to_slave(term, &reply, n);
                },
                18 => { // text area size in chars
                    var reply: [64]u8 = undefined;
                    const n = xsnprintf(&reply, reply.len, "\x1b[8;%d;%dt", term.rows, term.cols);
                    term_to_slave(term, &reply, n);
                },
                19 => { // report screen size in chars
                    const w = csi_window_first_output_px_width(term);
                    const h = csi_window_first_output_px_height(term);
                    if (w >= 0 and h >= 0) {
                        var reply: [64]u8 = undefined;
                        const n = xsnprintf(&reply, reply.len, "\x1b[9;%d;%dt", @divTrunc(h, term.cell_height), @divTrunc(w, term.cell_width));
                        term_to_slave(term, &reply, n);
                    } else {
                        term_to_slave(term, "\x1b[9;0;0t", 8);
                    }
                },
                21 => {}, // report window title — disabled upstream
                22 => { // push window title
                    const what = vtParamGet(term, 1, 0);
                    if (what == 0 or what == 2) {
                        if (csi_window_title_stack_len(term) < 128) {
                            if (term.window_title) |title| {
                                const dup = xstrdup(@ptrCast(title));
                                csi_window_title_stack_push(term, dup);
                            } else {
                                const empty = xstrdup("");
                                csi_window_title_stack_push(term, empty);
                            }
                        }
                    }
                },
                23 => { // pop window title
                    const what = vtParamGet(term, 1, 0);
                    if (what == 0 or what == 2) {
                        if (csi_window_title_stack_len(term) > 0) {
                            const title = csi_window_title_stack_pop(term);
                            if (title) |t| {
                                term_set_window_title(term, t);
                                free(@ptrCast(t));
                            }
                        }
                    }
                },
                else => {},
            }
        },

        'n' => blk: {
            if (term.vt.params.idx == 0) break :blk;
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                5 => { // "Device OK"
                    term_to_slave(term, "\x1b[0n", 4);
                },
                6 => { // cursor position report
                    const grid = term.grid orelse break :blk;
                    const row: c_int = if (term.origin == .absolute)
                        grid.cursor.point.row
                    else
                        grid.cursor.point.row - term.scroll_region.start;
                    var reply: [64]u8 = undefined;
                    const n = xsnprintf(&reply, reply.len, "\x1b[%d;%dR", row + 1, grid.cursor.point.col + 1);
                    term_to_slave(term, &reply, n);
                },
                else => {},
            }
        },

        else => case0UnhandledDispatch(term, final),
    }
}

fn case0UnhandledDispatch(term: *types.Terminal, final: u8) void {
    _ = term;
    _ = final;
}

// ─── Chunk E3a: case '?' private branch ───────────────────────────
// DECSET/DECRST/DECRQM/XTSAVE/XTRESTORE/XTSMGRAPHICS/XTMODKEYS/kitty


// csi-shim.c config/term accessors
extern fn csi_modify_other_keys_2(term: *types.Terminal) callconv(.c) bool;
extern fn csi_set_modify_other_keys_2(term: *types.Terminal, v: bool) callconv(.c) void;

// sixel_colors_* / sixel_geometry_* — Zig exports from sixel.zig
extern fn sixel_colors_report_current(term: *types.Terminal) callconv(.c) void;
extern fn sixel_colors_reset(term: *types.Terminal) callconv(.c) void;
extern fn sixel_colors_set(term: *types.Terminal, count: c_uint) callconv(.c) void;
extern fn sixel_colors_report_max(term: *types.Terminal) callconv(.c) void;
extern fn sixel_geometry_report_current(term: *types.Terminal) callconv(.c) void;
extern fn sixel_geometry_reset(term: *types.Terminal) callconv(.c) void;
extern fn sixel_geometry_set(term: *types.Terminal, w: c_uint, h: c_uint) callconv(.c) void;
extern fn sixel_geometry_report_max(term: *types.Terminal) callconv(.c) void;

// ZIG: decset/decrst/xtsave/xtrestore/decrqm — but these are `export fn` in same file.
// Direct calls (no extern).

const DECRPM_NOT_RECOGNIZED: c_uint = 0;

fn caseQuestion(term: *types.Terminal, final: u8) void {
    switch (final) {
        'h' => { // DECSET
            var i: usize = 0;
            while (i < term.vt.params.idx) : (i += 1) {
                decset(term, term.vt.params.v[i].value);
            }
        },
        'l' => { // DECRST
            var i: usize = 0;
            while (i < term.vt.params.idx) : (i += 1) {
                decrst(term, term.vt.params.v[i].value);
            }
        },
        's' => { // XTSAVE
            var i: usize = 0;
            while (i < term.vt.params.idx) : (i += 1) {
                xtsave(term, term.vt.params.v[i].value);
            }
        },
        'r' => { // XTRESTORE
            var i: usize = 0;
            while (i < term.vt.params.idx) : (i += 1) {
                xtrestore(term, term.vt.params.v[i].value);
            }
        },
        'S' => blk: { // XTSMGRAPHICS — sixel colors/geometry
            if (!csi_conf_tweak_sixel(term)) break :blk;
            const target = vtParamGet(term, 0, 0);
            const operation = vtParamGet(term, 1, 0);
            switch (target) {
                1 => switch (operation) {
                    1 => sixel_colors_report_current(term),
                    2 => sixel_colors_reset(term),
                    3 => sixel_colors_set(term, @intCast(vtParamGet(term, 2, 0))),
                    4 => sixel_colors_report_max(term),
                    else => {},
                },
                2 => switch (operation) {
                    1 => sixel_geometry_report_current(term),
                    2 => sixel_geometry_reset(term),
                    3 => sixel_geometry_set(term, @intCast(vtParamGet(term, 2, 0)), @intCast(vtParamGet(term, 3, 0))),
                    4 => sixel_geometry_report_max(term),
                    else => {},
                },
                else => {},
            }
        },
        'm' => { // XTQMODKEYS — query modifier keys
            const resource = vtParamGet(term, 0, 0);
            var value: c_int = -1;
            switch (resource) {
                0 => value = 0, // modifyKeyboard
                1, 2 => value = 1, // modifyCursorKeys/modifyFunctionKeys
                4 => value = if (csi_modify_other_keys_2(term)) 2 else 1, // modifyOtherKeys
                else => {},
            }
            if (value >= 0) {
                var reply: [16]u8 = .{0} ** 16;
                const chars = snprintf(&reply, reply.len, "\x1b[>%d;%dm", resource, value);
                if (chars > 0) term_to_slave(term, &reply, @intCast(chars));
            }
        },
        'n' => { // XTWINOPS theme report / DECRQM for insert mode
            const param = vtParamGet(term, 0, 0);
            switch (param) {
                996 => { // query theme mode
                    var reply: [16]u8 = .{0} ** 16;
                    const chars = snprintf(&reply, reply.len, "\x1b[?997;%dn",
                        if (term.colors.active_theme == .dark) @as(c_int, 1) else @as(c_int, 2));
                    if (chars > 0) term_to_slave(term, &reply, @intCast(chars));
                },
                998 => term_send_visibility_report(term),
                else => {},
            }
        },
        'p' => { // DECRQM for SM/RM modes (ANSI private mode query)
            const param = vtParamGet(term, 0, 0);
            const status: DecrpmStatus = if (param == 4)
                (if (term.insert_mode) .set else .reset)
            else
                .not_recognized;
            var reply: [32]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1b[%u;%u$y", param, @intFromEnum(status));
            term_to_slave(term, &reply, n);
        },
        'u' => { // kitty keyboard protocol query
            const grid = term.grid orelse return;
            const flags: u32 = @bitCast(grid.kitty_kbd.flags[grid.kitty_kbd.idx]);
            var reply: [8]u8 = undefined;
            const chars = snprintf(&reply, reply.len, "\x1b[?%uu", flags);
            if (chars > 0) term_to_slave(term, &reply, @intCast(chars));
        },
        else => {},
    }
}

// ─── Chunk E3b-1: private branches >, <, ' ', !, =, ?$ ────────────

// externs
extern fn term_reset(term: *types.Terminal, explicit: bool) callconv(.c) void;

// csi-shim.c version + config accessors
extern fn csi_foot_version_major() callconv(.c) c_uint;
extern fn csi_foot_version_minor() callconv(.c) c_uint;
extern fn csi_foot_version_patch() callconv(.c) c_uint;
extern fn csi_foot_version_extra() callconv(.c) [*:0]const u8;
extern fn csi_conf_cursor_style(term: *types.Terminal) callconv(.c) c_int;
extern fn csi_conf_cursor_blink_enabled(term: *types.Terminal) callconv(.c) bool;

const KITTY_KBD_SUPPORTED: c_int = 0x1f;

// ── case '>' — secondary DA, XTVERSION, XTMODKEYS, kitty kbd push ──
fn caseGreater(term: *types.Terminal, final: u8) void {
    switch (final) {
        'c' => blk: { // secondary DA
            if (vtParamGet(term, 0, 0) != 0) break :blk;
            var reply: [64]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1b[>1;%02u%02u%02u;0c",
                csi_foot_version_major(),
                csi_foot_version_minor(),
                csi_foot_version_patch());
            term_to_slave(term, &reply, n);
        },
        'm' => { // XTMODKEYS set
            if (term.vt.params.idx == 0) return; // reset all — no-op
            const resource = vtParamGet(term, 0, 0);
            const value = vtParamGet(term, 1, -1);
            switch (resource) {
                0 => {},
                1, 2 => {}, // modifyCursorKeys/modifyFunctionKeys ignored
                4 => csi_set_modify_other_keys_2(term, value == 2),
                else => {},
            }
        },
        'n' => { // XTMODKEYS reset
            const resource = vtParamGet(term, 0, 2);
            switch (resource) {
                0, 1, 2 => {},
                4 => csi_set_modify_other_keys_2(term, false),
                else => {},
            }
        },
        'u' => { // kitty kbd push
            const flags: u32 = @intCast(vtParamGet(term, 0, 0) & KITTY_KBD_SUPPORTED);
            const grid = term.grid orelse return;
            var idx = grid.kitty_kbd.idx;
            if (idx + 1 >= grid.kitty_kbd.flags.len) {
                idx = 0;
            } else {
                idx += 1;
            }
            grid.kitty_kbd.flags[idx] = @intCast(flags);
            grid.kitty_kbd.idx = idx;
        },
        'q' => blk: { // XTVERSION
            if (vtParamGet(term, 0, 0) != 0) break :blk;
            const extra = csi_foot_version_extra();
            const sep: [*:0]const u8 = if (extra[0] != 0) "-" else "";
            var reply: [64]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1bP>|foot(%u.%u.%u%s%s)\x1b\\",
                csi_foot_version_major(),
                csi_foot_version_minor(),
                csi_foot_version_patch(),
                sep, extra);
            term_to_slave(term, &reply, n);
        },
        else => {},
    }
}

// ── case '<' — kitty kbd pop ──────────────────────────────────────
fn caseLess(term: *types.Terminal, final: u8) void {
    if (final != 'u') return;
    const grid = term.grid orelse return;
    const count: c_int = @min(vtParamGet(term, 0, 1), @as(c_int, @intCast(grid.kitty_kbd.flags.len)));
    var idx = grid.kitty_kbd.idx;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        grid.kitty_kbd.flags[idx] = 0;
        if (idx == 0) {
            idx = @intCast(grid.kitty_kbd.flags.len - 1);
        } else {
            idx -= 1;
        }
    }
    grid.kitty_kbd.idx = idx;
}

// ── case ' ' — DECSCUSR cursor style ──────────────────────────────
fn caseSpace(term: *types.Terminal, final: u8) void {
    if (final != 'q') return;
    const param = vtParamGet(term, 0, 0);
    switch (param) {
        0 => {
            term.cursor_style = @enumFromInt(csi_conf_cursor_style(term));
            term.cursor_blink.deccsusr = csi_conf_cursor_blink_enabled(term);
            term_cursor_blink_update(term);
        },
        1, 2 => {
            term.cursor_style = if (csi_conf_cursor_style(term) == 3) .hollow else .block;
        },
        3, 4 => { term.cursor_style = .underline; },
        5, 6 => { term.cursor_style = .beam; },
        else => {},
    }
    if (param > 0 and param <= 6) {
        term.cursor_blink.deccsusr = (param & 1) != 0;
        term_cursor_blink_update(term);
    }
}

// ── case '!' — DECSTR soft reset ──────────────────────────────────
fn caseBang(term: *types.Terminal, final: u8) void {
    if (final != 'p') return;
    term_reset(term, false);
}

// ── case '=' — tertiary DA + kitty kbd set ───────────────────────
fn caseEquals(term: *types.Terminal, final: u8) void {
    switch (final) {
        'c' => { // tertiary DA
            if (vtParamGet(term, 0, 0) != 0) return;
            term_to_slave(term, "\x1bP!|464f4f54\x1b\\", 14);
        },
        'u' => { // kitty kbd set (mode 1/2/3)
            const flag_set: u32 = @intCast(vtParamGet(term, 0, 0) & KITTY_KBD_SUPPORTED);
            const mode = vtParamGet(term, 1, 1);
            const grid = term.grid orelse return;
            const idx = grid.kitty_kbd.idx;
            switch (mode) {
                1 => grid.kitty_kbd.flags[idx] = @intCast(flag_set),
                2 => grid.kitty_kbd.flags[idx] |= @intCast(flag_set),
                3 => grid.kitty_kbd.flags[idx] &= ~@as(types.KittyKbdFlags, @intCast(flag_set)),
                else => {},
            }
        },
        else => {},
    }
}

// ── case 0x243f ("?$") — DECRQM for DEC private modes ────────────
fn caseQuestionDollar(term: *types.Terminal, final: u8) void {
    if (final != 'p') return;
    const param: c_uint = @intCast(vtParamGet(term, 0, 0));
    const status = decrqm(term, param);
    var reply: [32]u8 = undefined;
    const n = xsnprintf(&reply, reply.len, "\x1b[?%u;%u$y", param, @intFromEnum(status));
    term_to_slave(term, &reply, n);
}

// ─── Chunk E3b-2: private branches $ and # ────────────────────────

// externs
extern fn grid_row(grid: *types.Grid, row_no: c_int) callconv(.c) ?*types.Row;
extern fn grid_row_uri_range_erase(row: *types.Row, start: c_int, end: c_int) callconv(.c) void;
extern fn sixel_overwrite_by_rectangle(term: *types.Terminal, row: c_int, col: c_int, height: c_int, width: c_int) callconv(.c) void;
extern fn term_fill(term: *types.Terminal, row: c_int, col: c_int, c: u8, count: c_int, insert: bool) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;

fn caseDollar(term: *types.Terminal, final: u8) void {
    switch (final) {
        'r' => blk: { // DECCARA — change attributes in rectangular area
            var top: c_int = 0;
            var left: c_int = 0;
            var bottom: c_int = 0;
            var right: c_int = 0;
            if (!params_to_rectangular_area(term, 0, &top, &left, &bottom, &right)) break :blk;

            const grid = term.grid orelse break :blk;
            var r: c_int = top;
            while (r <= bottom) : (r += 1) {
                const row = grid_row(grid, r) orelse continue;
                row.dirty = true;
                const cells = row.cells orelse continue;
                var c: c_int = left;
                while (c <= right) : (c += 1) {
                    const a = &cells[@intCast(c)].attrs;
                    a.clean = false;
                    var i: usize = 4;
                    while (i < term.vt.params.idx) : (i += 1) {
                        switch (@as(c_int, @intCast(term.vt.params.v[i].value))) {
                            0 => { a.bold = false; a.underline = false; a.blink = false; a.reverse = false; },
                            1 => a.bold = true,
                            4 => a.underline = true,
                            5 => a.blink = true,
                            7 => a.reverse = true,
                            22 => a.bold = false,
                            24 => a.underline = false,
                            25 => a.blink = false,
                            27 => a.reverse = false,
                            else => {},
                        }
                    }
                }
            }
        },
        't' => blk: { // DECRARA — reverse attributes in rectangular area
            var top: c_int = 0;
            var left: c_int = 0;
            var bottom: c_int = 0;
            var right: c_int = 0;
            if (!params_to_rectangular_area(term, 0, &top, &left, &bottom, &right)) break :blk;
            const grid = term.grid orelse break :blk;
            var r: c_int = top;
            while (r <= bottom) : (r += 1) {
                const row = grid_row(grid, r) orelse continue;
                row.dirty = true;
                const cells = row.cells orelse continue;
                var c: c_int = left;
                while (c <= right) : (c += 1) {
                    const a = &cells[@intCast(c)].attrs;
                    a.clean = false;
                    var i: usize = 4;
                    while (i < term.vt.params.idx) : (i += 1) {
                        switch (@as(c_int, @intCast(term.vt.params.v[i].value))) {
                            0 => { a.bold = !a.bold; a.underline = !a.underline; a.blink = !a.blink; a.reverse = !a.reverse; },
                            1 => a.bold = !a.bold,
                            4 => a.underline = !a.underline,
                            5 => a.blink = !a.blink,
                            7 => a.reverse = !a.reverse,
                            else => {},
                        }
                    }
                }
            }
        },
        'v' => blk: { // DECCRA — copy rectangular area
            var src_top: c_int = 0;
            var src_left: c_int = 0;
            var src_bottom: c_int = 0;
            var src_right: c_int = 0;
            if (!params_to_rectangular_area(term, 0, &src_top, &src_left, &src_bottom, &src_right)) break :blk;

            const src_page = vtParamGet(term, 4, 1);
            const dst_rel_top = vtParamGet(term, 5, 1) - 1;
            const dst_left = @min(vtParamGet(term, 6, 1) - 1, term.cols - 1);
            const dst_page = vtParamGet(term, 7, 1);
            if (src_page != 1 or dst_page != 1) break :blk;

            const dst_rel_bottom = dst_rel_top + (src_bottom - src_top);
            const dst_right = @min(dst_left + (src_right - src_left), term.cols - 1);
            const dst_top = term_row_rel_to_abs(term, dst_rel_top);
            const dst_bottom = term_row_rel_to_abs(term, dst_rel_bottom);
            if (dst_left > dst_right or dst_top > dst_bottom) break :blk;

            const row_count: c_int = @min(src_bottom - src_top, dst_bottom - dst_top) + 1;
            const cell_count: c_int = @min(src_right - src_left, dst_right - dst_left) + 1;

            sixel_overwrite_by_rectangle(term, dst_top, dst_left, row_count, cell_count);

            const grid = term.grid orelse break :blk;
            const cell_size = @sizeOf(types.Cell);
            const row_count_u: usize = @intCast(row_count);
            const cell_count_u: usize = @intCast(cell_count);

            // Save src cells
            const copy_ptr = xmalloc(row_count_u * @sizeOf(?[*]types.Cell)) orelse break :blk;
            const copy: [*]?[*]types.Cell = @ptrCast(@alignCast(copy_ptr));

            var r: c_int = 0;
            while (r < row_count) : (r += 1) {
                const row_buf = xmalloc(cell_count_u * cell_size) orelse break;
                const row_cells: [*]types.Cell = @ptrCast(@alignCast(row_buf));
                const src_row = grid_row(grid, src_top + r) orelse continue;
                const src_cells = src_row.cells orelse continue;
                _ = memcpy(row_cells, &src_cells[@intCast(src_left)], cell_count_u * cell_size);
                copy[@intCast(r)] = row_cells;
            }

            // Paste into dst cells
            r = 0;
            while (r < row_count) : (r += 1) {
                const dst_row = grid_row(grid, dst_top + r) orelse continue;
                dst_row.dirty = true;
                const dst_cells = dst_row.cells orelse continue;
                const copy_row = copy[@intCast(r)] orelse continue;
                _ = memcpy(&dst_cells[@intCast(dst_left)], copy_row, cell_count_u * cell_size);
                free(@ptrCast(copy_row));

                var c: c_int = 0;
                while (c < cell_count) : (c += 1) {
                    dst_cells[@intCast(dst_left + c)].attrs.clean = false;
                }

                if (dst_row.extra != null) {
                    grid_row_uri_range_erase(dst_row, dst_left, dst_right);
                }
            }
            free(@ptrCast(copy));
        },
        'x' => blk: { // DECFRA — fill rectangular area with char
            const ch = vtParamGet(term, 0, 0);
            if (!((ch >= 32 and ch < 126) or ch >= 160)) break :blk;

            var top: c_int = 0;
            var left: c_int = 0;
            var bottom: c_int = 0;
            var right: c_int = 0;
            if (!params_to_rectangular_area(term, 1, &top, &left, &bottom, &right)) break :blk;

            sixel_overwrite_by_rectangle(term, top, left, bottom - top + 1, right - left + 1);

            var r: c_int = top;
            while (r <= bottom) : (r += 1) {
                term_fill(term, r, left, @intCast(ch), right - left + 1, true);
            }
        },
        'z' => blk: { // DECERA — erase rectangular area
            var top: c_int = 0;
            var left: c_int = 0;
            var bottom: c_int = 0;
            var right: c_int = 0;
            if (!params_to_rectangular_area(term, 0, &top, &left, &bottom, &right)) break :blk;

            sixel_overwrite_by_rectangle(term, top, left, bottom - top + 1, right - left + 1);

            var r: c_int = top;
            while (r <= bottom) : (r += 1) {
                term_erase(term, r, left, r, right);
            }
        },
        else => {},
    }
}

// ── case '#' — color stack push/pop/report ───────────────────────
fn caseHash(term: *types.Terminal, final: u8) void {
    switch (final) {
        'P' => blk: { // XTPUSHCOLORS
            var slot = vtParamGet(term, 0, 0);
            if (slot == 0) slot = @intCast(term.color_stack.idx + 1);

            const max_slot: c_int = 128;
            if (slot > max_slot) slot = max_slot;

            if (term.color_stack.size < @as(usize, @intCast(slot))) {
                const new_size: usize = @intCast(slot);
                const new_ptr = xrealloc(
                    if (term.color_stack.stack) |s| @ptrCast(s) else null,
                    new_size * @sizeOf(types.Colors),
                ) orelse break :blk;
                term.color_stack.stack = @ptrCast(@alignCast(new_ptr));

                var i: usize = term.color_stack.size;
                while (i < new_size - 1) : (i += 1) {
                    const stack = term.color_stack.stack orelse break;
                    _ = memcpy(&stack[i], &term.colors, @sizeOf(types.Colors));
                }
                term.color_stack.size = new_size;
            }

            term.color_stack.idx = @intCast(slot);
            const stack = term.color_stack.stack orelse break :blk;
            _ = memcpy(&stack[@as(usize, @intCast(slot - 1))], &term.colors, @sizeOf(types.Colors));
        },
        'Q' => blk: { // XTPOPCOLORS
            var slot = vtParamGet(term, 0, 0);
            if (slot == 0) slot = @intCast(term.color_stack.idx);

            if (slot > 0 and @as(usize, @intCast(slot)) <= term.color_stack.size) {
                const stack = term.color_stack.stack orelse break :blk;
                _ = memcpy(&term.colors, &stack[@as(usize, @intCast(slot - 1))], @sizeOf(types.Colors));
                term.color_stack.idx = @intCast(slot - 1);
                term_damage_view(term);
                term_damage_margins(term);
            }
        },
        'R' => { // XTREPORTCOLORS
            var reply: [64]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1b[?%zu;%zu#Q",
                term.color_stack.idx, term.color_stack.size);
            term_to_slave(term, &reply, n);
        },
        else => {},
    }
}

