const std = @import("std");
const types = @import("terminal_types.zig");

// ── libc externs ──────────────────────────────────────────────────
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;

// ── term_* externs ────────────────────────────────────────────────
extern fn term_bell(term: *types.Terminal) callconv(.c) void;
extern fn term_carriage_return(term: *types.Terminal) callconv(.c) void;
extern fn term_cursor_home(term: *types.Terminal) callconv(.c) void;
extern fn term_cursor_left(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_right(term: *types.Terminal, count: c_int) callconv(.c) void;
extern fn term_cursor_to(term: *types.Terminal, row: c_int, col: c_int) callconv(.c) void;
extern fn term_fill(term: *types.Terminal, row: c_int, col: c_int, c: u8, count: c_int, insert: bool) callconv(.c) void;
extern fn term_linefeed(term: *types.Terminal) callconv(.c) void;
extern fn term_process_and_print_non_ascii(term: *types.Terminal, wc: u32) callconv(.c) void;
extern fn term_reset(term: *types.Terminal, explicit: bool) callconv(.c) void;
extern fn term_reset_grapheme_state(term: *types.Terminal) callconv(.c) void;
extern fn term_restore_cursor(term: *types.Terminal, cursor: *types.Cursor) callconv(.c) void;
extern fn term_reverse_index(term: *types.Terminal) callconv(.c) void;
extern fn term_save_cursor(term: *types.Terminal) callconv(.c) void;
extern fn term_single_shift(term: *types.Terminal, designator: types.CharsetDesignator) callconv(.c) void;
extern fn term_update_ascii_printer(term: *types.Terminal) callconv(.c) void;

// ── Other VT dispatch (Zig, from csi/osc/dcs .zig) ───────────────
extern fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void;
extern fn osc_dispatch(term: *types.Terminal) callconv(.c) void;
extern fn osc_ensure_size(term: *types.Terminal, required: usize) callconv(.c) bool;
extern fn dcs_hook(term: *types.Terminal, final: u8) callconv(.c) void;
extern fn dcs_put(term: *types.Terminal, c: u8) callconv(.c) void;
extern fn dcs_unhook(term: *types.Terminal) callconv(.c) void;

// ── sixel.c (still C) ─────────────────────────────────────────────
extern fn sixel_overwrite_by_rectangle(term: *types.Terminal, row: c_int, col: c_int, height: c_int, width: c_int) callconv(.c) void;

// ── vt-shim.c ─────────────────────────────────────────────────────
extern fn vt_call_ascii_printer(term: *types.Terminal, c: u8) callconv(.c) void;
extern fn vt_tab_stops_insert_before(term: *types.Terminal, value: c_int) callconv(.c) void;
extern fn vt_tab_stops_push_back(term: *types.Terminal, value: c_int) callconv(.c) void;
extern fn vt_tab_stops_len(term: *types.Terminal) callconv(.c) c_int;
extern fn vt_tab_stops_back(term: *types.Terminal) callconv(.c) c_int;
extern fn vt_tab_stops_next_after(term: *types.Terminal, col: c_int) callconv(.c) c_int;

// ── Charset/Keypad enum values ────────────────────────────────────
const CHARSET_ASCII: types.Charset = .ascii;
const CHARSET_GRAPHIC: types.Charset = .graphic;
const G0: types.CharsetDesignator = .g0;
const G1: types.CharsetDesignator = .g1;
const G2: types.CharsetDesignator = .g2;
const G3: types.CharsetDesignator = .g3;
const KEYPAD_APPLICATION: types.KeypadKeys = .application;
const KEYPAD_NUMERICAL: types.KeypadKeys = .numerical;

// ── Action handlers ───────────────────────────────────────────────

pub fn action_ignore(term: *types.Terminal) void {
    _ = term;
}

pub fn action_clear(term: *types.Terminal) void {
    term.vt.params.idx = 0;
    term.vt.private = 0;
}

pub fn action_execute(term: *types.Terminal, c: u8) void {
    switch (c) {
        0 => {},
        0x07 => term_bell(term), // BEL
        0x08 => blk: { // BS
            const grid = term.grid orelse break :blk;
            if (grid.cursor.lcf) {
                grid.cursor.lcf = false;
            } else {
                if (grid.cursor.point.col == 0 and term.reverse_wrap and term.auto_margin) {
                    if (grid.cursor.point.row <= term.scroll_region.start) {
                        // Don't wrap past the scrolling region
                    } else {
                        term_cursor_to(term, grid.cursor.point.row - 1, term.cols - 1);
                    }
                } else {
                    term_cursor_left(term, 1);
                }
            }
        },
        0x09 => blk: { // HT
            const grid = term.grid orelse break :blk;
            const start_col = grid.cursor.point.col;
            const next = vt_tab_stops_next_after(term, start_col);
            const new_col: c_int = if (next > 0) next else term.cols - 1;

            const row = grid.cur_row orelse break :blk;
            const cells = row.cells orelse break :blk;

            const start_wc = cells[@intCast(start_col)].wc;
            var emit_tab_char = (start_wc == 0 or start_wc == 0x20);

            var c_idx: c_int = start_col + 1;
            while (c_idx < new_col) : (c_idx += 1) {
                const wc = cells[@intCast(c_idx)].wc;
                if (!(wc == 0 or wc == 0x20)) {
                    emit_tab_char = false;
                    break;
                }
            }

            if (emit_tab_char) {
                row.dirty = true;
                cells[@intCast(start_col)].wc = 0x09;
                cells[@intCast(start_col)].attrs.clean = false;

                c_idx = start_col + 1;
                while (c_idx < new_col) : (c_idx += 1) {
                    cells[@intCast(c_idx)].wc = 0x20;
                    cells[@intCast(c_idx)].attrs.clean = false;
                }
            }

            const lcf = grid.cursor.lcf;
            term_cursor_right(term, new_col - start_col);
            if (term.grid) |g| g.cursor.lcf = lcf;
        },
        0x0a, 0x0b, 0x0c => term_linefeed(term), // LF, VT, FF
        0x0d => term_carriage_return(term), // CR
        0x0e => { // SO — shift out
            term.charsets.selected = G1;
            term.bits_affecting_ascii_printer._.charset =
                term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
            term_update_ascii_printer(term);
        },
        0x0f => { // SI — shift in
            term.charsets.selected = G0;
            term.bits_affecting_ascii_printer._.charset =
                term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
            term_update_ascii_printer(term);
        },
        else => {},
    }
}

pub fn action_print(term: *types.Terminal, c: u8) void {
    term_reset_grapheme_state(term);
    vt_call_ascii_printer(term, c);
}

fn action_param_lazy_init(term: *types.Terminal) void {
    if (term.vt.params.idx != 0) return;
    const param = &term.vt.params.v[0];
    term.vt.params.cur = param;
    param.value = 0;
    param.sub.idx = 0;
    param.sub.cur = null;
    term.vt.params.idx = 1;
}

pub fn action_param_new(term: *types.Terminal, c: u8) void {
    _ = c; // c == ';'
    action_param_lazy_init(term);

    const max_params: usize = 16;
    var param: *types.VtParam = undefined;

    if (term.vt.params.idx >= max_params) {
        param = &term.vt.params.dummy;
    } else {
        param = &term.vt.params.v[term.vt.params.idx];
        term.vt.params.idx += 1;
    }

    term.vt.params.cur = param;
    param.value = 0;
    param.sub.idx = 0;
    param.sub.cur = null;
}

pub fn action_param_new_subparam(term: *types.Terminal, c: u8) void {
    _ = c; // c == ':'
    action_param_lazy_init(term);

    const param = term.vt.params.cur orelse return;
    const max_sub_params: usize = 16;

    var sub_param_value: *c_uint = undefined;
    if (param.sub.idx >= max_sub_params) {
        sub_param_value = &param.sub.dummy;
    } else {
        sub_param_value = &param.sub.value[param.sub.idx];
        param.sub.idx += 1;
    }
    param.sub.cur = sub_param_value;
    sub_param_value.* = 0;
}

pub fn action_param(term: *types.Terminal, c: u8) void {
    action_param_lazy_init(term);
    const param = term.vt.params.cur orelse return;

    const value: *c_uint = if (param.sub.cur) |sc| sc else &param.value;

    var v: c_uint = value.*;
    v = v *% 10 +% (c - '0');
    value.* = v;
}

pub fn action_collect(term: *types.Terminal, c: u8) void {
    if ((term.vt.private & 0xff) == 0) {
        term.vt.private = c;
    } else if (((term.vt.private >> 8) & 0xff) == 0) {
        term.vt.private |= @as(u32, c) << 8;
    } else if (((term.vt.private >> 16) & 0xff) == 0) {
        term.vt.private |= @as(u32, c) << 16;
    } else if (((term.vt.private >> 24) & 0xff) == 0) {
        term.vt.private |= @as(u32, c) << 24;
    }
}

fn tab_set(term: *types.Terminal) void {
    const grid = term.grid orelse return;
    const col = grid.cursor.point.col;

    const len = vt_tab_stops_len(term);
    if (len == 0 or vt_tab_stops_back(term) < col) {
        vt_tab_stops_push_back(term, col);
        return;
    }
    vt_tab_stops_insert_before(term, col);
}

pub fn action_esc_dispatch(term: *types.Terminal, final: u8) void {
    switch (term.vt.private) {
        0 => switch (final) {
            '7' => term_save_cursor(term),
            '8' => { const grid = term.grid orelse return; term_restore_cursor(term, &grid.saved_cursor); },
            'c' => term_reset(term, true),
            'n' => { // LS2
                term.charsets.selected = G2;
                term.bits_affecting_ascii_printer._.charset =
                    term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
                term_update_ascii_printer(term);
            },
            'o' => { // LS3
                term.charsets.selected = G3;
                term.bits_affecting_ascii_printer._.charset =
                    term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
                term_update_ascii_printer(term);
            },
            'D' => term_linefeed(term),
            'E' => { term_carriage_return(term); term_linefeed(term); },
            'H' => tab_set(term),
            'M' => term_reverse_index(term),
            'N' => term_single_shift(term, G2),
            'O' => term_single_shift(term, G3),
            '\\' => {}, // ST
            '=' => term.keypad_keys_mode = KEYPAD_APPLICATION,
            '>' => term.keypad_keys_mode = KEYPAD_NUMERICAL,
            else => {},
        },
        '(', ')', '*', '+' => {
            const idx = term.vt.private - '(';
            switch (final) {
                '0' => {
                    term.charsets.set[idx] = CHARSET_GRAPHIC;
                    term.bits_affecting_ascii_printer._.charset =
                        term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
                    term_update_ascii_printer(term);
                },
                'B' => {
                    term.charsets.set[idx] = CHARSET_ASCII;
                    term.bits_affecting_ascii_printer._.charset =
                        term.charsets.set[@intFromEnum(term.charsets.selected)] != CHARSET_ASCII;
                    term_update_ascii_printer(term);
                },
                else => {},
            }
        },
        '#' => {
            if (final == '8') { // DECALN
                sixel_overwrite_by_rectangle(term, 0, 0, term.rows, term.cols);
                term.scroll_region.start = 0;
                term.scroll_region.end = term.rows;
                var r: c_int = 0;
                while (r < term.rows) : (r += 1) {
                    term_fill(term, r, 0, 'E', term.cols, false);
                }
                term_cursor_home(term);
            }
        },
        else => {},
    }
}

pub fn action_csi_dispatch(term: *types.Terminal, c: u8) void {
    csi_dispatch(term, c);
}

pub fn action_osc_start(term: *types.Terminal, c: u8) void {
    _ = c;
    term.vt.osc.idx = 0;
}

pub fn action_osc_end(term: *types.Terminal, c: u8) void {
    if (!osc_ensure_size(term, term.vt.osc.idx + 1)) return;
    term.vt.osc.data.?[term.vt.osc.idx] = 0;
    term.vt.osc.bel = (c == 0x07);
    osc_dispatch(term);

    if (term.vt.osc.idx >= 4096) {
        const data = term.vt.osc.data;
        free(if (data) |d| @ptrCast(d) else null);
        term.vt.osc.data = null;
        term.vt.osc.size = 0;
    }
}

pub fn action_osc_put(term: *types.Terminal, c: u8) void {
    if (!osc_ensure_size(term, term.vt.osc.idx + 1)) return;
    term.vt.osc.data.?[term.vt.osc.idx] = c;
    term.vt.osc.idx += 1;
}

pub fn action_hook(term: *types.Terminal, c: u8) void {
    dcs_hook(term, c);
}

pub fn action_unhook(term: *types.Terminal, c: u8) void {
    _ = c;
    dcs_unhook(term);
}

pub fn action_put(term: *types.Terminal, c: u8) void {
    dcs_put(term, c);
}

pub fn action_utf8_print(term: *types.Terminal, wc: u32) void {
    term_process_and_print_non_ascii(term, wc);
}

// UTF-8 state machine — added in chunk B
