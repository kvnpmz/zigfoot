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

        // TODO: cases 'h', 'l' (DECSET/DECRST), 'n' (DECRQM), 'q', 'r', 's', 'u', 't', '>', etc.
        // and the outer `private` branches ('$', '>', '?', ...)
        // — will be added in chunk E2/E3.

        else => {},
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

