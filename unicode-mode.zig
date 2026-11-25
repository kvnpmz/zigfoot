const std = @import("std");
const types = @import("terminal_types.zig");

//
// unicode-mode.c ported to Zig: the Ctrl+Shift+u hexadecimal input mode.
//
// struct seat is mirrored in terminal_types.zig (chunk B2), so the two
// keyboard fields this file touches are read directly;
// MB_CUR_MAX is still a C macro and comes from terminal-shim.c.
//

const LOG_CLASS_DEBUG: c_int = 4;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;

extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh_search(term: *types.Terminal) callconv(.c) void;
extern fn search_add_chars(term: *types.Terminal, text: [*]const u8, len: usize) callconv(.c) void;
extern fn search_find_next(term: *types.Terminal, direction: c_int) callconv(.c) void;
extern fn term_to_slave(term: *types.Terminal, data: *const anyopaque, len: usize) callconv(.c) bool;

extern fn terminal_shim_mb_cur_max() callconv(.c) usize;

const MbState = opaque {};
extern fn c32rtomb(s: [*]u8, c32: u32, ps: *MbState) callconv(.c) usize;

// <xkbcommon/xkbcommon-keysyms.h>
const XKB_KEY_Return: u32 = 0xff0d;
const XKB_KEY_space: u32 = 0x0020;
const XKB_KEY_KP_Enter: u32 = 0xff8d;
const XKB_KEY_KP_Space: u32 = 0xff80;
const XKB_KEY_Escape: u32 = 0xff1b;
const XKB_KEY_q: u32 = 0x0071;
const XKB_KEY_c: u32 = 0x0063;
const XKB_KEY_d: u32 = 0x0064;
const XKB_KEY_g: u32 = 0x0067;
const XKB_KEY_BackSpace: u32 = 0xff08;
const XKB_KEY_0: u32 = 0x0030;
const XKB_KEY_9: u32 = 0x0039;
const XKB_KEY_KP_0: u32 = 0xffb0;
const XKB_KEY_KP_9: u32 = 0xffb9;
const XKB_KEY_a: u32 = 0x0061;
const XKB_KEY_f: u32 = 0x0066;
const XKB_KEY_A: u32 = 0x0041;
const XKB_KEY_F: u32 = 0x0046;

const SEARCH_BACKWARD_SAME_POSITION: c_int = 0; // enum search_direction

fn logDbg(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{
        LOG_CLASS_DEBUG,
        "unicode-input",
        "unicode-mode.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

export fn unicode_mode_activate(term: *types.Terminal) callconv(.c) void {
    if (term.unicode_mode.active)
        return;

    term.unicode_mode.active = true;
    term.unicode_mode.character = 0;
    term.unicode_mode.count = 0;
    unicode_mode_updated(term);
}

export fn unicode_mode_deactivate(term: *types.Terminal) callconv(.c) void {
    if (!term.unicode_mode.active)
        return;

    term.unicode_mode.active = false;
    unicode_mode_updated(term);
}

export fn unicode_mode_updated(term: ?*types.Terminal) callconv(.c) void {
    const t = term orelse return;

    if (t.is_searching)
        render_refresh_search(t)
    else
        render_refresh(t);
}

export fn unicode_mode_input(
    seat: *types.Seat,
    term: *types.Terminal,
    sym: u32,
) callconv(.c) void {
    if (sym == XKB_KEY_Return or
        sym == XKB_KEY_space or
        sym == XKB_KEY_KP_Enter or
        sym == XKB_KEY_KP_Space)
    {
        var utf8: [32]u8 = undefined; // MB_CUR_MAX <= 16 on every supported locale
        std.debug.assert(terminal_shim_mb_cur_max() <= utf8.len);

        var ps_buf: [128]u8 align(@alignOf(usize)) = std.mem.zeroes([128]u8);
        const ps: *MbState = @ptrCast(&ps_buf);

        const chars = c32rtomb(&utf8, term.unicode_mode.character, ps);

        logDbg("Unicode input: 0x%06x -> %.*s", .{
            term.unicode_mode.character,
            @as(c_int, @intCast(if (chars == std.math.maxInt(usize)) 0 else chars)),
            &utf8,
        });

        if (chars != std.math.maxInt(usize)) {
            if (term.is_searching) {
                search_add_chars(term, &utf8, chars);
                search_find_next(term, SEARCH_BACKWARD_SAME_POSITION);
            } else {
                _ = term_to_slave(term, &utf8, chars);
            }
        }

        seat.kbd.last_shortcut_sym = sym;
        unicode_mode_deactivate(term);
    } else if (sym == XKB_KEY_Escape or
        sym == XKB_KEY_q or
        (seat.kbd.ctrl and
            (sym == XKB_KEY_c or sym == XKB_KEY_d or sym == XKB_KEY_g)))
    {
        seat.kbd.last_shortcut_sym = sym;
        unicode_mode_deactivate(term);
    } else if (sym == XKB_KEY_BackSpace) {
        if (term.unicode_mode.count > 0) {
            term.unicode_mode.character >>= 4;
            term.unicode_mode.count -= 1;
            unicode_mode_updated(term);
        }
    } else if (term.unicode_mode.count < 6) {
        var digit: c_int = -1;

        // 0-9, a-f, A-F
        if (sym >= XKB_KEY_0 and sym <= XKB_KEY_9)
            digit = @intCast(sym - XKB_KEY_0)
        else if (sym >= XKB_KEY_KP_0 and sym <= XKB_KEY_KP_9)
            digit = @intCast(sym - XKB_KEY_KP_0)
        else if (sym >= XKB_KEY_a and sym <= XKB_KEY_f)
            digit = @intCast(0xa + (sym - XKB_KEY_a))
        else if (sym >= XKB_KEY_A and sym <= XKB_KEY_F)
            digit = @intCast(0xa + (sym - XKB_KEY_A));

        if (digit >= 0) {
            std.debug.assert(digit >= 0 and digit <= 0xf);
            term.unicode_mode.character <<= 4;
            term.unicode_mode.character |= @as(u32, @intCast(digit));
            term.unicode_mode.count += 1;
            unicode_mode_updated(term);
        }
    }
}
