const std = @import("std");
const types = @import("terminal_types.zig");

extern fn free(ptr: ?*anyopaque) callconv(.c) void;

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
extern fn term_restore_cursor(term: *types.Terminal, cursor: *types.Cursor) callconv(.c) void;
extern fn term_reverse_index(term: *types.Terminal) callconv(.c) void;
extern fn term_save_cursor(term: *types.Terminal) callconv(.c) void;
extern fn term_single_shift(term: *types.Terminal, designator: types.CharsetDesignator) callconv(.c) void;
extern fn term_update_ascii_printer(term: *types.Terminal) callconv(.c) void;

extern fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void;
extern fn osc_dispatch(term: *types.Terminal) callconv(.c) void;
extern fn osc_ensure_size(term: *types.Terminal, required: usize) callconv(.c) bool;
extern fn dcs_hook(term: *types.Terminal, final: u8) callconv(.c) void;
extern fn dcs_put(term: *types.Terminal, c: u8) callconv(.c) void;
extern fn dcs_unhook(term: *types.Terminal) callconv(.c) void;

extern fn sixel_overwrite_by_rectangle(term: *types.Terminal, row: c_int, col: c_int, height: c_int, width: c_int) callconv(.c) void;

extern fn vt_call_ascii_printer(term: *types.Terminal, c: u8) callconv(.c) void;
extern fn vt_tab_stops_insert_before(term: *types.Terminal, value: c_int) callconv(.c) void;
extern fn vt_tab_stops_push_back(term: *types.Terminal, value: c_int) callconv(.c) void;
extern fn vt_tab_stops_len(term: *types.Terminal) callconv(.c) c_int;
extern fn vt_tab_stops_back(term: *types.Terminal) callconv(.c) c_int;
extern fn vt_tab_stops_next_after(term: *types.Terminal, col: c_int) callconv(.c) c_int;

const CHARSET_ASCII: types.Charset = .ascii;
const CHARSET_GRAPHIC: types.Charset = .graphic;
const G0: types.CharsetDesignator = .g0;
const G1: types.CharsetDesignator = .g1;
const G2: types.CharsetDesignator = .g2;
const G3: types.CharsetDesignator = .g3;
const KEYPAD_APPLICATION: types.KeypadKeys = .application;
const KEYPAD_NUMERICAL: types.KeypadKeys = .numerical;

const STATE_GROUND: c_int = 0;
const STATE_ESCAPE: c_int = 1;
const STATE_ESCAPE_INTERMEDIATE: c_int = 2;
const STATE_CSI_ENTRY: c_int = 3;
const STATE_CSI_PARAM: c_int = 4;
const STATE_CSI_INTERMEDIATE: c_int = 5;
const STATE_CSI_IGNORE: c_int = 6;
const STATE_OSC_STRING: c_int = 7;
const STATE_DCS_ENTRY: c_int = 8;
const STATE_DCS_PARAM: c_int = 9;
const STATE_DCS_INTERMEDIATE: c_int = 10;
const STATE_DCS_IGNORE: c_int = 11;
const STATE_DCS_PASSTHROUGH: c_int = 12;
const STATE_SOS_PM_APC_STRING: c_int = 13;
const STATE_UTF8_21: c_int = 14;
const STATE_UTF8_31: c_int = 15;
const STATE_UTF8_32: c_int = 16;
const STATE_UTF8_41: c_int = 17;
const STATE_UTF8_42: c_int = 18;
const STATE_UTF8_43: c_int = 19;

fn term_reset_grapheme_state(term: *types.Terminal) void {
    // `term_reset_grapheme_state()` is a no-op without utf8proc (terminal.h);
    // the call site is compiled out instead.
    term.vt.grapheme_state = 0;
    term.vt.codepoint_merging_ok = false;
}

fn action_ignore(term: *types.Terminal) void {
    _ = term;
}

export fn action_clear(term: *types.Terminal) callconv(.c) void {
    term.vt.params.idx = 0;
    term.vt.private = 0;
}

export fn action_execute(term: *types.Terminal, c: u8) callconv(.c) void {
    switch (c) {
        0 => {},
        0x07 => term_bell(term),
        0x08 => blk: {
            const grid = term.grid orelse break :blk;
            if (grid.cursor.lcf) {
                grid.cursor.lcf = false;
            } else {
                if (grid.cursor.point.col == 0 and term.reverse_wrap and term.auto_margin) {
                    if (grid.cursor.point.row <= term.scroll_region.start) {
                        // Don't wrap
                    } else {
                        term_cursor_to(term, grid.cursor.point.row - 1, term.cols - 1);
                    }
                } else {
                    term_cursor_left(term, 1);
                }
            }
        },
        0x09 => blk: {
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
        0x0a, 0x0b, 0x0c => term_linefeed(term),
        0x0d => term_carriage_return(term),
        0x0e => {
            term.charsets.selected = G1;
            term.bits_affecting_ascii_printer._.charset =
                term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
            term_update_ascii_printer(term);
        },
        0x0f => {
            term.charsets.selected = G0;
            term.bits_affecting_ascii_printer._.charset =
                term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
            term_update_ascii_printer(term);
        },
        else => {},
    }
}

export fn action_print(term: *types.Terminal, c: u8) callconv(.c) void {
    if (comptime types.grapheme_clustering)
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

export fn action_param_new(term: *types.Terminal, c: u8) callconv(.c) void {
    _ = c;
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

export fn action_param_new_subparam(term: *types.Terminal, c: u8) callconv(.c) void {
    _ = c;
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
    param.sub.cur = @ptrCast(sub_param_value);
    sub_param_value.* = 0;
}

export fn action_param(term: *types.Terminal, c: u8) callconv(.c) void {
    action_param_lazy_init(term);
    const param = term.vt.params.cur orelse return;
    const value: *c_uint = if (param.sub.cur) |sc| @ptrCast(sc) else &param.value;
    var v: c_uint = value.*;
    v = v *% 10 +% @as(c_uint, c - '0');
    value.* = v;
}

export fn action_collect(term: *types.Terminal, c: u8) callconv(.c) void {
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

export fn action_esc_dispatch(term: *types.Terminal, final: u8) callconv(.c) void {
    switch (term.vt.private) {
        0 => switch (final) {
            '7' => term_save_cursor(term),
            '8' => { const grid = term.grid orelse return; term_restore_cursor(term, &grid.saved_cursor); },
            'c' => term_reset(term, true),
            'n' => {
                term.charsets.selected = G2;
                term.bits_affecting_ascii_printer._.charset =
                    term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
                term_update_ascii_printer(term);
            },
            'o' => {
                term.charsets.selected = G3;
                term.bits_affecting_ascii_printer._.charset =
                    term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
                term_update_ascii_printer(term);
            },
            'D' => term_linefeed(term),
            'E' => { term_carriage_return(term); term_linefeed(term); },
            'H' => tab_set(term),
            'M' => term_reverse_index(term),
            'N' => term_single_shift(term, G2),
            'O' => term_single_shift(term, G3),
            '\\' => {},
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
                        term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
                    term_update_ascii_printer(term);
                },
                'B' => {
                    term.charsets.set[idx] = CHARSET_ASCII;
                    term.bits_affecting_ascii_printer._.charset =
                        term.charsets.set[@as(usize, @intCast(@intFromEnum(term.charsets.selected)))] != CHARSET_ASCII;
                    term_update_ascii_printer(term);
                },
                else => {},
            }
        },
        '#' => {
            if (final == '8') {
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

export fn action_csi_dispatch(term: *types.Terminal, c: u8) callconv(.c) void {
    csi_dispatch(term, c);
}

export fn action_osc_start(term: *types.Terminal, c: u8) callconv(.c) void {
    _ = c;
    term.vt.osc.idx = 0;
}

export fn action_osc_end(term: *types.Terminal, c: u8) callconv(.c) void {
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

export fn action_osc_put(term: *types.Terminal, c: u8) callconv(.c) void {
    if (!osc_ensure_size(term, term.vt.osc.idx + 1)) return;
    term.vt.osc.data.?[term.vt.osc.idx] = c;
    term.vt.osc.idx += 1;
}

export fn action_hook(term: *types.Terminal, c: u8) callconv(.c) void {
    dcs_hook(term, c);
}

export fn action_unhook(term: *types.Terminal, c: u8) callconv(.c) void {
    _ = c;
    dcs_unhook(term);
}

export fn action_put(term: *types.Terminal, c: u8) callconv(.c) void {
    dcs_put(term, c);
}

export fn action_utf8_print(term: *types.Terminal, wc: u32) callconv(.c) void {
    term_process_and_print_non_ascii(term, wc);
}

export fn action_utf8_21(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 = @as(u32, c & 0x1f) << 6;
}

export fn action_utf8_22(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f);
    action_utf8_print(term, term.vt.utf8);
}

export fn action_utf8_31(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 = @as(u32, c & 0x0f) << 12;
}

export fn action_utf8_32(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f) << 6;
}

export fn action_utf8_33(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f);
    const utf32 = term.vt.utf8;
    if (utf32 >= 0xd800 and utf32 <= 0xdfff) return;
    action_utf8_print(term, term.vt.utf8);
}

export fn action_utf8_41(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 = @as(u32, c & 0x07) << 18;
}

export fn action_utf8_42(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f) << 12;
}

export fn action_utf8_43(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f) << 6;
}

export fn action_utf8_44(term: *types.Terminal, c: u8) callconv(.c) void {
    term.vt.utf8 |= @as(u32, c & 0x3f);
    const utf32 = term.vt.utf8;
    if (utf32 > 0x10FFFF) return;
    action_utf8_print(term, term.vt.utf8);
}

fn anywhere(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x18, 0x1a => { action_execute(term, data); return STATE_GROUND; },
        0x1b => { action_clear(term); return STATE_ESCAPE; },
        0x80...0x9f => return STATE_GROUND,
        else => {},
    }
    return term.vt.state;
}

fn state_ground_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_GROUND; },
        0x20...0x7e => { action_print(term, data); return STATE_GROUND; },
        0xc2...0xdf => { action_utf8_21(term, data); return STATE_UTF8_21; },
        0xe0...0xef => { action_utf8_31(term, data); return STATE_UTF8_31; },
        0xf0...0xf4 => { action_utf8_41(term, data); return STATE_UTF8_41; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_escape_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_ESCAPE; },
        0x20...0x2f => { action_collect(term, data); return STATE_ESCAPE_INTERMEDIATE; },
        0x30...0x4f => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x50 => { action_clear(term); return STATE_DCS_ENTRY; },
        0x51...0x57 => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x58 => return STATE_SOS_PM_APC_STRING,
        0x59 => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x5a => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x5b => { action_clear(term); return STATE_CSI_ENTRY; },
        0x5c => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x5d => { action_osc_start(term, data); return STATE_OSC_STRING; },
        0x5e...0x5f => return STATE_SOS_PM_APC_STRING,
        0x60...0x7e => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x7f => { action_ignore(term); return STATE_ESCAPE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_escape_intermediate_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_ESCAPE_INTERMEDIATE; },
        0x20...0x2f => { action_collect(term, data); return STATE_ESCAPE_INTERMEDIATE; },
        0x30...0x7e => { action_esc_dispatch(term, data); return STATE_GROUND; },
        0x7f => { action_ignore(term); return STATE_ESCAPE_INTERMEDIATE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_csi_entry_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_CSI_ENTRY; },
        0x20...0x2f => { action_collect(term, data); return STATE_CSI_INTERMEDIATE; },
        0x30...0x39 => { action_param(term, data); return STATE_CSI_PARAM; },
        0x3a => { action_param_new_subparam(term, data); return STATE_CSI_PARAM; },
        0x3b => { action_param_new(term, data); return STATE_CSI_PARAM; },
        0x3c...0x3f => { action_collect(term, data); return STATE_CSI_PARAM; },
        0x40...0x7e => { action_csi_dispatch(term, data); return STATE_GROUND; },
        0x7f => { action_ignore(term); return STATE_CSI_ENTRY; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_csi_param_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_CSI_PARAM; },
        0x20...0x2f => { action_collect(term, data); return STATE_CSI_INTERMEDIATE; },
        0x30...0x39 => { action_param(term, data); return STATE_CSI_PARAM; },
        0x3a => { action_param_new_subparam(term, data); return STATE_CSI_PARAM; },
        0x3b => { action_param_new(term, data); return STATE_CSI_PARAM; },
        0x3c...0x3f => return STATE_CSI_IGNORE,
        0x40...0x7e => { action_csi_dispatch(term, data); return STATE_GROUND; },
        0x7f => { action_ignore(term); return STATE_CSI_PARAM; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_csi_intermediate_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_CSI_INTERMEDIATE; },
        0x20...0x2f => { action_collect(term, data); return STATE_CSI_INTERMEDIATE; },
        0x30...0x3f => return STATE_CSI_IGNORE,
        0x40...0x7e => { action_csi_dispatch(term, data); return STATE_GROUND; },
        0x7f => { action_ignore(term); return STATE_CSI_INTERMEDIATE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_csi_ignore_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_execute(term, data); return STATE_CSI_IGNORE; },
        0x20...0x3f => { action_ignore(term); return STATE_CSI_IGNORE; },
        0x40...0x7e => return STATE_GROUND,
        0x7f => { action_ignore(term); return STATE_CSI_IGNORE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_osc_string_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x07 => { action_osc_end(term, data); return STATE_GROUND; },
        0x00...0x06, 0x08...0x17, 0x19, 0x1c...0x1f => { action_ignore(term); return STATE_OSC_STRING; },
        0x18, 0x1a => { action_osc_end(term, data); action_execute(term, data); return STATE_GROUND; },
        0x1b => { action_osc_end(term, data); action_clear(term); return STATE_ESCAPE; },
        else => { action_osc_put(term, data); return STATE_OSC_STRING; },
    }
}

fn state_dcs_entry_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_ignore(term); return STATE_DCS_ENTRY; },
        0x20...0x2f => { action_collect(term, data); return STATE_DCS_INTERMEDIATE; },
        0x30...0x39 => { action_param(term, data); return STATE_DCS_PARAM; },
        0x3a => return STATE_DCS_IGNORE,
        0x3b => { action_param_new(term, data); return STATE_DCS_PARAM; },
        0x3c...0x3f => { action_collect(term, data); return STATE_DCS_PARAM; },
        0x40...0x7e => { action_hook(term, data); return STATE_DCS_PASSTHROUGH; },
        0x7f => { action_ignore(term); return STATE_DCS_ENTRY; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_dcs_param_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_ignore(term); return STATE_DCS_PARAM; },
        0x20...0x2f => { action_collect(term, data); return STATE_DCS_INTERMEDIATE; },
        0x30...0x39 => { action_param(term, data); return STATE_DCS_PARAM; },
        0x3a => return STATE_DCS_IGNORE,
        0x3b => { action_param_new(term, data); return STATE_DCS_PARAM; },
        0x3c...0x3f => return STATE_DCS_IGNORE,
        0x40...0x7e => { action_hook(term, data); return STATE_DCS_PASSTHROUGH; },
        0x7f => { action_ignore(term); return STATE_DCS_PARAM; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_dcs_intermediate_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f => { action_ignore(term); return STATE_DCS_INTERMEDIATE; },
        0x20...0x2f => { action_collect(term, data); return STATE_DCS_INTERMEDIATE; },
        0x30...0x3f => return STATE_DCS_IGNORE,
        0x40...0x7e => { action_hook(term, data); return STATE_DCS_PASSTHROUGH; },
        0x7f => { action_ignore(term); return STATE_DCS_INTERMEDIATE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_dcs_ignore_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x1f, 0x20...0x7f => { action_ignore(term); return STATE_DCS_IGNORE; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_dcs_passthrough_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x7e => { action_put(term, data); return STATE_DCS_PASSTHROUGH; },
        0x7f => { action_ignore(term); return STATE_DCS_PASSTHROUGH; },
        0x18, 0x1a => { action_unhook(term, data); action_execute(term, data); return STATE_GROUND; },
        0x1b => { action_unhook(term, data); action_clear(term); return STATE_ESCAPE; },
        0x80...0x9f => { action_unhook(term, data); return STATE_GROUND; },
        else => return STATE_DCS_PASSTHROUGH,
    }
}

fn state_sos_pm_apc_string_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x00...0x17, 0x19, 0x1c...0x7f => { action_ignore(term); return STATE_SOS_PM_APC_STRING; },
        else => {},
    }
    return anywhere(term, data);
}

fn state_utf8_21_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_22(term, data); return STATE_GROUND; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

fn state_utf8_31_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_32(term, data); return STATE_UTF8_32; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

fn state_utf8_32_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_33(term, data); return STATE_GROUND; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

fn state_utf8_41_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_42(term, data); return STATE_UTF8_42; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

fn state_utf8_42_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_43(term, data); return STATE_UTF8_43; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

fn state_utf8_43_switch(term: *types.Terminal, data: u8) c_int {
    switch (data) {
        0x80...0xbf => { action_utf8_44(term, data); return STATE_GROUND; },
        else => { action_utf8_print(term, 0xfffd); return state_ground_switch(term, data); },
    }
}

export fn vt_from_slave(term: *types.Terminal, data: [*]const u8, len: usize) callconv(.c) void {
    var current_state: c_int = term.vt.state;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const b = data[i];
        current_state = switch (current_state) {
            STATE_GROUND => state_ground_switch(term, b),
            STATE_ESCAPE => state_escape_switch(term, b),
            STATE_ESCAPE_INTERMEDIATE => state_escape_intermediate_switch(term, b),
            STATE_CSI_ENTRY => state_csi_entry_switch(term, b),
            STATE_CSI_PARAM => state_csi_param_switch(term, b),
            STATE_CSI_INTERMEDIATE => state_csi_intermediate_switch(term, b),
            STATE_CSI_IGNORE => state_csi_ignore_switch(term, b),
            STATE_OSC_STRING => state_osc_string_switch(term, b),
            STATE_DCS_ENTRY => state_dcs_entry_switch(term, b),
            STATE_DCS_PARAM => state_dcs_param_switch(term, b),
            STATE_DCS_INTERMEDIATE => state_dcs_intermediate_switch(term, b),
            STATE_DCS_IGNORE => state_dcs_ignore_switch(term, b),
            STATE_DCS_PASSTHROUGH => state_dcs_passthrough_switch(term, b),
            STATE_SOS_PM_APC_STRING => state_sos_pm_apc_string_switch(term, b),
            STATE_UTF8_21 => state_utf8_21_switch(term, b),
            STATE_UTF8_31 => state_utf8_31_switch(term, b),
            STATE_UTF8_32 => state_utf8_32_switch(term, b),
            STATE_UTF8_41 => state_utf8_41_switch(term, b),
            STATE_UTF8_42 => state_utf8_42_switch(term, b),
            STATE_UTF8_43 => state_utf8_43_switch(term, b),
            else => STATE_GROUND,
        };
        term.vt.state = current_state;
    }
}
