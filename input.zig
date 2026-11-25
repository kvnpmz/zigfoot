//! Zig port of input.c, started with the keyboard device setup (D4a):
//! keymap installation, keyboard enter/leave and the key-repeat timer.
//!
//! The protocol listeners themselves stay in input.c for now (they are
//! generated-struct layouts); everything they call is either here or in
//! terminal.zig.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

const Terminal = types.Terminal;
const Seat = types.Seat;

// ── C library / libxkbcommon ──────────────────────────────────────────────
const XKB_MOD_INVALID: u32 = 0xffffffff;
const XKB_KEYMAP_FORMAT_TEXT_V1: c_int = 1;
const XKB_KEYMAP_COMPILE_NO_FLAGS: c_int = 0;
const WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP: u32 = 0;
const WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1: u32 = 1;

const MOD_NAME_SHIFT = "Shift";
const MOD_NAME_ALT = "Mod1";
const MOD_NAME_CTRL = "Control";
const MOD_NAME_LOGO = "Mod4";
const MOD_NAME_CAPS = "Lock";
const MOD_NAME_NUM = "Mod2";

const VMOD_NAME_ALT = "Alt";
const VMOD_NAME_META = "Meta";
const VMOD_NAME_SUPER = "Super";
const VMOD_NAME_HYPER = "Hyper";
const VMOD_NAME_NUM = "NumLock";
const VMOD_NAME_SCROLL = "ScrollLock";
const VMOD_NAME_LEVEL3 = "LevelThree";
const VMOD_NAME_LEVEL5 = "LevelFive";

extern fn xkb_keymap_unref(keymap: ?*anyopaque) callconv(.c) void;
extern fn xkb_state_unref(state: ?*anyopaque) callconv(.c) void;
extern fn xkb_keymap_new_from_buffer(
    context: ?*anyopaque,
    buffer: [*]const u8,
    length: usize,
    format: c_int,
    flags: c_int,
) callconv(.c) ?*anyopaque;
extern fn xkb_state_new(keymap: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn xkb_keymap_mod_get_index(keymap: ?*anyopaque, name: [*:0]const u8) callconv(.c) u32;
extern fn xkb_keymap_key_by_name(keymap: ?*anyopaque, name: [*:0]const u8) callconv(.c) u32;
extern fn xkb_keymap_num_layouts(keymap: ?*anyopaque) callconv(.c) u32;
extern fn xkb_state_update_mask(
    state: ?*anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) callconv(.c) c_int;
extern fn xkb_compose_state_reset(state: ?*anyopaque) callconv(.c) void;

extern fn mmap(
    addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: isize) callconv(.c) ?*anyopaque;
extern fn munmap(addr: ?*anyopaque, length: usize) callconv(.c) c_int;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn write(fd: c_int, buf: ?*const anyopaque, count: usize) callconv(.c) isize;
extern fn strerror(errnum: c_int) callconv(.c) [*:0]const u8;
extern fn __errno_location() callconv(.c) *c_int;
extern fn timerfd_settime(
    fd: c_int, flags: c_int, new_value: *const Itimerspec, old_value: ?*Itimerspec) callconv(.c) c_int;

extern fn key_binding_load_keymap(mgr: ?*anyopaque, seat: *Seat) callconv(.c) void;
extern fn key_binding_unload_keymap(mgr: ?*anyopaque, seat: *Seat) callconv(.c) void;
extern fn term_mouse_grabbed(term: *const Terminal, seat: *const Seat) callconv(.c) bool;
extern fn term_kbd_focus_in(term: *Terminal) callconv(.c) void;
extern fn term_kbd_focus_out(term: *Terminal) callconv(.c) void;
extern fn term_xcursor_update_for_seat(term: *Terminal, seat: *Seat) callconv(.c) void;
extern fn wayland_shim_surface_get_user_data(surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;
const LOG_CLASS_DEBUG: c_int = 4;

const EPOLLIN: c_int = 0x001;
const EPOLLOUT: c_int = 0x004;
const EPOLLHUP: c_int = 0x010;

const PROT_READ: c_int = 1;
const MAP_PRIVATE: c_int = 2;
const MAP_FAILED: usize = std.math.maxInt(usize);

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

const Itimerspec = extern struct {
    it_interval: Timespec,
    it_value: Timespec,
};

fn logDebug(comptime fmt: [*:0]const u8, args: anytype) void {
    _ = args;
    log_msg(LOG_CLASS_DEBUG, "input", "input.zig", @intCast(@src().line), fmt);
}

// ─────────────────────────────────────────────────────────────────────────
// fdm_write_pipe: hand a string to the client through a pipe, a chunk per
// EPOLLOUT, then drop the context. Used for e.g. the key-binding feedback.
// ─────────────────────────────────────────────────────────────────────────

const PipeContext = extern struct {
    text: ?[*:0]u8,
    idx: usize,
    left: usize,
};

export fn fdm_write_pipe(
    fdm: *anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    const ctx: *PipeContext = @ptrCast(@alignCast(data orelse return true));

    if (events & EPOLLHUP != 0)
        return pipeClosed(fdm, fd, ctx);

    std.debug.assert(events & EPOLLOUT != 0);
    const written = write(fd, ctx.text.? + ctx.idx, ctx.left);

    if (written < 0) {
        log_msg(
            LOG_CLASS_WARNING, "input", "input.zig", @intCast(@src().line),
            "failed to write to pipe: %s", strerror(__errno_location().*));
        return pipeClosed(fdm, fd, ctx);
    }

    std.debug.assert(@as(usize, @intCast(written)) <= ctx.left);
    ctx.idx += @intCast(written);
    ctx.left -= @intCast(written);

    if (ctx.left == 0)
        return pipeClosed(fdm, fd, ctx);

    return true;
}

fn pipeClosed(fdm: *anyopaque, fd: c_int, ctx: *PipeContext) bool {
    free(ctx.text);
    free(ctx);
    _ = fdm_del(fdm, fd);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────
// Key repeat timer
// ─────────────────────────────────────────────────────────────────────────

export fn start_repeater(seat: *Seat, key: u32) callconv(.c) bool {
    const repeat = &seat.kbd.repeat;

    if (repeat.dont_re_repeat)
        return true;

    if (repeat.rate == 0)
        return true;

    var t = Itimerspec{
        .it_value = .{
            .tv_sec = 0,
            .tv_nsec = @as(isize, repeat.delay) * 1_000_000,
        },
        .it_interval = .{
            .tv_sec = 0,
            .tv_nsec = @divTrunc(1_000_000_000, @as(isize, repeat.rate)),
        },
    };

    if (t.it_value.tv_nsec >= 1_000_000_000) {
        t.it_value.tv_sec += @divTrunc(t.it_value.tv_nsec, 1_000_000_000);
        t.it_value.tv_nsec = @rem(t.it_value.tv_nsec, 1_000_000_000);
    }
    if (t.it_interval.tv_nsec >= 1_000_000_000) {
        t.it_interval.tv_sec += @divTrunc(t.it_interval.tv_nsec, 1_000_000_000);
        t.it_interval.tv_nsec = @rem(t.it_interval.tv_nsec, 1_000_000_000);
    }

    if (timerfd_settime(repeat.fd, 0, &t, null) < 0) {
        log_errno(
            LOG_CLASS_ERROR, "input", "input.zig", @intCast(@src().line),
            "%s: failed to arm keyboard repeat timer", seat.name.?);
        return false;
    }

    repeat.key = key;
    return true;
}

export fn stop_repeater(seat: *Seat, key: u32) callconv(.c) bool {
    const repeat = &seat.kbd.repeat;

    if (key != @as(u32, @bitCast(@as(i32, -1))) and key != repeat.key)
        return true;

    const off = Itimerspec{
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
    };

    if (timerfd_settime(repeat.fd, 0, &off, null) < 0) {
        log_errno(
            LOG_CLASS_ERROR, "input", "input.zig", @intCast(@src().line),
            "%s: failed to disarm keyboard repeat timer", seat.name.?);
        return false;
    }

    return true;
}

// ─────────────────────────────────────────────────────────────────────────
// keyboard_keymap / keyboard_enter / keyboard_leave
// ─────────────────────────────────────────────────────────────────────────

/// Install the keymap the compositor sent over a memfd: build the xkb state,
/// cache the modifier indices, and work out which modifiers the legacy and
/// kitty protocols consider significant.
export fn keyboard_keymap(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    format: u32,
    fd: c_int,
    size: u32,
) callconv(.c) void {
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));
    const wayl = seat.wayl.?;

    log_msg(
        LOG_CLASS_DEBUG, "input", "input.zig", @intCast(@src().line),
        "keyboard_keymap: keyboard=%p (format=%u, size=%u)", wl_keyboard, format, size);

    // Free old keymap state
    if (seat.kbd.xkb_keymap) |keymap| {
        xkb_keymap_unref(keymap);
        seat.kbd.xkb_keymap = null;
    }
    if (seat.kbd.xkb_state) |state| {
        xkb_state_unref(state);
        seat.kbd.xkb_state = null;
    }

    key_binding_unload_keymap(wayl.key_binding_manager, seat);

    // Verify the keymap is in a format we understand
    switch (format) {
        WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 => {},
        WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP => return closeFd(fd),
        else => {
            log_msg(
                LOG_CLASS_WARNING, "input", "input.zig", @intCast(@src().line),
                "unrecognized keymap format: %u", format);
            return closeFd(fd);
        },
    }

    const mapped = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (@intFromPtr(mapped) == MAP_FAILED) {
        log_errno(
            LOG_CLASS_ERROR, "input", "input.zig", @intCast(@src().line),
            "failed to mmap keyboard keymap");
        return closeFd(fd);
    }

    const map_str: [*]const u8 = @ptrCast(mapped.?);

    if (seat.kbd.xkb) |xkb| {
        seat.kbd.xkb_keymap = xkb_keymap_new_from_buffer(
            xkb, map_str, size, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    }

    _ = munmap(mapped, size);

    if (seat.kbd.xkb_keymap) |keymap| {
        seat.kbd.xkb_state = xkb_state_new(keymap);

        seat.kbd.mod_shift = xkb_keymap_mod_get_index(keymap, MOD_NAME_SHIFT);
        seat.kbd.mod_alt = xkb_keymap_mod_get_index(keymap, MOD_NAME_ALT);
        seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(keymap, MOD_NAME_CTRL);
        seat.kbd.mod_super = xkb_keymap_mod_get_index(keymap, MOD_NAME_LOGO);
        seat.kbd.mod_caps = xkb_keymap_mod_get_index(keymap, MOD_NAME_CAPS);
        seat.kbd.mod_num = xkb_keymap_mod_get_index(keymap, MOD_NAME_NUM);

        // Significant modifiers in the legacy keyboard protocol
        seat.kbd.legacy_significant = 0;
        if (seat.kbd.mod_shift != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_shift);
        if (seat.kbd.mod_alt != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_alt);
        if (seat.kbd.mod_ctrl != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_ctrl);
        if (seat.kbd.mod_super != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_super);

        // Significant modifiers in the kitty keyboard protocol
        seat.kbd.kitty_significant = seat.kbd.legacy_significant;
        if (seat.kbd.mod_caps != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_caps);
        if (seat.kbd.mod_num != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= @as(u32, 1) << @intCast(seat.kbd.mod_num);

        // Some compositors set the *virtual* modifiers (Alt, Meta, Super,
        // Hyper, NumLock, ScrollLock, LevelThree/Five) in addition to the
        // real ones. Since foot's shortcut matching makes very few
        // assumptions about modifier indices, those extra bits break
        // matching (Mod1+b would need Alt+Mod1+b). Mutter is known to do
        // this - ignore the virtual modifiers outright.
        {
            const alt = xkb_keymap_mod_get_index(keymap, VMOD_NAME_ALT);
            const meta = xkb_keymap_mod_get_index(keymap, VMOD_NAME_META);
            const super = xkb_keymap_mod_get_index(keymap, VMOD_NAME_SUPER);
            const hyper = xkb_keymap_mod_get_index(keymap, VMOD_NAME_HYPER);
            const num_lock = xkb_keymap_mod_get_index(keymap, VMOD_NAME_NUM);
            const scroll_lock = xkb_keymap_mod_get_index(keymap, VMOD_NAME_SCROLL);
            const level_three = xkb_keymap_mod_get_index(keymap, VMOD_NAME_LEVEL3);
            const level_five = xkb_keymap_mod_get_index(keymap, VMOD_NAME_LEVEL5);

            var ignore: u32 = 0;
            if (alt != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(alt);
            if (meta != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(meta);
            if (super != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(super);
            if (hyper != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(hyper);
            if (num_lock != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(num_lock);
            if (scroll_lock != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(scroll_lock);
            if (level_three != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(level_three);
            if (level_five != XKB_MOD_INVALID) ignore |= @as(u32, 1) << @intCast(level_five);

            seat.kbd.virtual_modifiers = ignore;
        }

        seat.kbd.key_arrow_up = xkb_keymap_key_by_name(keymap, "UP");
        seat.kbd.key_arrow_down = xkb_keymap_key_by_name(keymap, "DOWN");
    }

    key_binding_load_keymap(wayl.key_binding_manager, seat);

    closeFd(fd);
}

fn closeFd(fd: c_int) void {
    _ = close(fd);
}

export fn keyboard_enter(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    serial: u32,
    surface: ?*anyopaque,
    keys: ?*anyopaque,
) callconv(.c) void {
    _ = keys;
    std.debug.assert(serial != 0);

    if (surface == null) {
        // Seen on Hyprland
        log_msg(
            LOG_CLASS_WARNING, "input", "input.zig", @intCast(@src().line),
            "compositor sent keyboard_enter event with a NULL surface");
        return;
    }

    const seat: *Seat = @ptrCast(@alignCast(data orelse return));
    const win: *types.WlWindow = @ptrCast(@alignCast(
        wayland_shim_surface_get_user_data(surface) orelse return));
    const term: *Terminal = @ptrCast(@alignCast(win.term.?));

    log_msg(
        LOG_CLASS_DEBUG, "input", "input.zig", @intCast(@src().line),
        "%s: keyboard_enter: keyboard=%p, serial=%u, surface=%p",
        seat.name.?, wl_keyboard, serial, surface);

    term_kbd_focus_in(term);
    seat.kbd_focus = term;
    seat.kbd.serial = serial;
}

export fn keyboard_leave(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    serial: u32,
    surface: ?*anyopaque,
) callconv(.c) void {
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    log_msg(
        LOG_CLASS_DEBUG, "input", "input.zig", @intCast(@src().line),
        "keyboard_leave: keyboard=%p, serial=%u, surface=%p",
        wl_keyboard, serial, surface);

    if (seat.kbd_focus != null and surface != null) {
        // Seen on Sway 1.2: a leave without a surface
        const win: *types.WlWindow = @ptrCast(@alignCast(
            wayland_shim_surface_get_user_data(surface).?));
        std.debug.assert(@as(*Terminal, @ptrCast(@alignCast(win.term.?))) == seat.kbd_focus.?);
    }

    const old_focused = seat.kbd_focus;
    seat.kbd_focus = null;

    _ = stop_repeater(seat, @bitCast(@as(i32, -1)));
    seat.kbd.shift = false;
    seat.kbd.alt = false;
    seat.kbd.ctrl = false;
    seat.kbd.super = false;

    if (seat.kbd.xkb_compose_state) |compose_state|
        xkb_compose_state_reset(compose_state);

    if (seat.kbd.xkb_state) |xkb_state| {
        if (seat.kbd.xkb_keymap) |keymap| {
            const layout_count = xkb_keymap_num_layouts(keymap);
            var i: u32 = 0;
            while (i < layout_count) : (i += 1)
                _ = xkb_state_update_mask(xkb_state, 0, 0, 0, i, i, i);
        }
    }

    if (old_focused) |term| {
        seat.pointer.hidden = false;
        term_xcursor_update_for_seat(term, seat);
        term_kbd_focus_out(term);
    } else {
        // Sway bug: a keyboard_leave() (and keyboard_key()) without a prior
        // keyboard_enter().
        log_msg(
            LOG_CLASS_WARNING, "input", "input.zig", @intCast(@src().line),
            "compositor sent keyboard_leave event without a keyboard_enter " ++
                "event: surface=%p", surface);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Modifier helpers (D4b1): the xkb state queries every protocol function
// goes through, plus the keyboard repeat-info listener.
// ─────────────────────────────────────────────────────────────────────────

const XKB_STATE_MODS_LOCKED: u32 = 1 << 2;
const XKB_STATE_MODS_EFFECTIVE: u32 = 1 << 3;
const XKB_CONSUMED_MODE_XKB: c_int = 0;

// Keysyms from xkbcommon-keysyms.h.
const XKB_KEY_Shift_L: u32 = 0xffe1;
const XKB_KEY_Hyper_R: u32 = 0xffee;
const XKB_KEY_ISO_Lock: u32 = 0xfe01;
const XKB_KEY_ISO_Last_Group_Lock: u32 = 0xfe0f;
const XKB_KEY_Mode_switch: u32 = 0xff7e;
const XKB_KEY_Num_Lock: u32 = 0xff7f;

extern fn xkb_state_serialize_mods(state: ?*anyopaque, components: u32) callconv(.c) u32;
extern fn xkb_state_key_get_consumed_mods2(
    state: ?*anyopaque, key: u32, mode: c_int) callconv(.c) u32;
extern fn xkb_keymap_mod_get_name(keymap: ?*anyopaque, idx: u32) callconv(.c) ?[*:0]const u8;

/// The currently effective modifiers, and (optionally) the ones the key
/// consumed. `filter_locked` drops the locked (CapsLock/NumLock) mods.
export fn get_current_modifiers(
    seat: *const Seat,
    effective: ?*u32,
    consumed: ?*u32,
    key: u32,
    filter_locked: bool,
) callconv(.c) void {
    const state = seat.kbd.xkb_state;

    if (state == null) {
        if (effective) |e| e.* = 0;
        if (consumed) |c| c.* = 0;
        return;
    }

    const locked = xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED);

    if (effective) |e| {
        e.* = xkb_state_serialize_mods(state, XKB_STATE_MODS_EFFECTIVE);
        if (filter_locked)
            e.* &= ~locked;
    }

    if (consumed) |c| {
        c.* = xkb_state_key_get_consumed_mods2(state, key, XKB_CONSUMED_MODE_XKB);
        if (filter_locked)
            c.* &= ~locked;
    }
}

/// Modifier keys proper: Shift_L..Hyper_R, the ISO_* group/lock keys,
/// Mode_switch and Num_Lock.
export fn keysym_is_modifier(keysym: u32) callconv(.c) bool {
    return
        (keysym >= XKB_KEY_Shift_L and keysym <= XKB_KEY_Hyper_R) or
        (keysym >= XKB_KEY_ISO_Lock and keysym <= XKB_KEY_ISO_Last_Group_Lock) or
        keysym == XKB_KEY_Mode_switch or
        keysym == XKB_KEY_Num_Lock;
}

/// Render a modifier mask as "Mod1+Shift" (or "<none>"). C used strcat() into
/// a caller-provided buffer; this appends with an explicit length so a short
/// buffer truncates instead of overflowing (it never does in practice).
export fn modifier_string(
    mods: u32,
    sz: usize,
    mod_str: [*]u8,
    seat: *const Seat,
) callconv(.c) void {
    if (sz == 0)
        return;

    mod_str[0] = 0;
    var len: usize = 0;

    const keymap = seat.kbd.xkb_keymap orelse {
        if (sz >= "<none>".len + 1)
            @memcpy(mod_str[0.."<none>".len], "<none>");
        mod_str["<none>".len] = 0;
        return;
    };

    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        if (mods & (@as(u32, 1) << @intCast(i)) == 0)
            continue;

        const name = xkb_keymap_mod_get_name(keymap, i) orelse continue;
        const n = std.mem.len(name);

        if (len + n + 1 >= sz)
            break;

        @memcpy(mod_str[len .. len + n], name[0..n]);
        len += n;
        mod_str[len] = '+';
        len += 1;
    }

    if (len > 0) {
        // Strip the last '+'
        len -= 1;
        mod_str[len] = 0;
    }

    if (len == 0) {
        const none = "<none>";
        const n = @min(none.len, sz - 1);
        @memcpy(mod_str[0..n], none[0..n]);
        mod_str[n] = 0;
    }
}

export fn keyboard_repeat_info(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = wl_keyboard;
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    log_msg(
        LOG_CLASS_DEBUG, "input", "input.zig", @intCast(@src().line),
        "keyboard repeat: rate=%d, delay=%d", rate, delay);

    seat.kbd.repeat.rate = rate;
    seat.kbd.repeat.delay = delay;
}

// ─────────────────────────────────────────────────────────────────────────
// The VT key tables (D4b2), translated from keymap.h.
//
// `modifiers` uses the MOD_* bits from keymap.h; the MODIFY_OTHER_KEYS_STATE1
// / _2 bits mark entries that only apply when modifyOtherKeys mode 1 / 2 is
// active. `seq` is what gets sent to the client. KeyData is field-for-field
// identical to C's struct key_data (three enums and a pointer), so
// keymap_lookup() can keep returning a pointer into these tables.
// ─────────────────────────────────────────────────────────────────────────

pub const MOD_NONE: c_int = 0x00;
pub const MOD_ANY: c_int = 0x01;
pub const MOD_SHIFT: c_int = 0x02;
pub const MOD_ALT: c_int = 0x04;
pub const MOD_CTRL: c_int = 0x08;
pub const MOD_META: c_int = 0x10;
pub const MOD_MODIFY_OTHER_KEYS_STATE1: c_int = 0x20;
pub const MOD_MODIFY_OTHER_KEYS_STATE2: c_int = 0x40;

pub const CURSOR_KEYS_DONTCARE: c_int = 0;
pub const CURSOR_KEYS_NORMAL: c_int = 1;
pub const CURSOR_KEYS_APPLICATION: c_int = 2;

pub const KEYPAD_DONTCARE: c_int = 0;
pub const KEYPAD_NUMERICAL: c_int = 1;
pub const KEYPAD_APPLICATION: c_int = 2;

pub const KeyData = extern struct {
    modifiers: c_int,
    cursor_keys: c_int,
    keypad_keys: c_int,
    seq: [*:0]const u8,
};

const key_escape = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;2;27~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x1b" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;4;27~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;5;27~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;6;27~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;7;27~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;8;27~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;9;27~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;10;27~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;11;27~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;12;27~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;13;27~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;14;27~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;15;27~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;16;27~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b" },
};

const key_return = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;2;13~" },
    .{ .modifiers = 36, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\r" },
    .{ .modifiers = 68, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;3;13~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;4;13~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;5;13~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;6;13~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;7;13~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;8;13~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;9;13~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;10;13~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;11;13~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;12;13~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;13;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;14;13~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;15;13~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;16;13~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\r" },
};

const key_tab = [_]KeyData{
    .{ .modifiers = 34, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[Z" },
    .{ .modifiers = 66, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;2;9~" },
    .{ .modifiers = 36, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\t" },
    .{ .modifiers = 68, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;3;9~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;4;9~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;5;9~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;6;9~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;7;9~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;8;9~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;9;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;10;9~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;11;9~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;12;9~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;13;9~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;14;9~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;15;9~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;16;9~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\t" },
};

const key_iso_left_tab = [_]KeyData{
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;4;9~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;6;9~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;8;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;10;9~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;12;9~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;14;9~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;16;9~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[Z" },
};

const key_backspace = [_]KeyData{
    .{ .modifiers = 34, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x7f" },
    .{ .modifiers = 36, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x7f" },
    .{ .modifiers = 38, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x7f" },
    .{ .modifiers = 42, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x08" },
    .{ .modifiers = 44, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x08" },
    .{ .modifiers = 46, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x08" },
    .{ .modifiers = 48, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x7f" },
    .{ .modifiers = 50, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x7f" },
    .{ .modifiers = 52, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x7f" },
    .{ .modifiers = 54, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x7f" },
    .{ .modifiers = 56, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x08" },
    .{ .modifiers = 58, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x08" },
    .{ .modifiers = 60, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x08" },
    .{ .modifiers = 62, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b\x08" },
    .{ .modifiers = 66, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;2;127~" },
    .{ .modifiers = 68, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;3;127~" },
    .{ .modifiers = 70, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;4;127~" },
    .{ .modifiers = 74, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;6;8~" },
    .{ .modifiers = 76, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;7;8~" },
    .{ .modifiers = 78, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;8;8~" },
    .{ .modifiers = 80, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;9;127~" },
    .{ .modifiers = 82, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;10;127~" },
    .{ .modifiers = 84, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;11;127~" },
    .{ .modifiers = 86, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;12;127~" },
    .{ .modifiers = 88, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;13;8~" },
    .{ .modifiers = 90, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;14;8~" },
    .{ .modifiers = 92, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;15;8~" },
    .{ .modifiers = 94, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[27;16;8~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x08" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x7f" },
};

const key_up = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2A" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3A" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4A" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5A" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6A" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7A" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8A" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9A" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10A" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11A" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12A" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13A" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14A" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15A" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16A" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOA" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[A" },
};

const key_down = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2B" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3B" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4B" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5B" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6B" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7B" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8B" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9B" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10B" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11B" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12B" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13B" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14B" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15B" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16B" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOB" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[B" },
};

const key_right = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2C" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3C" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4C" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5C" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6C" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7C" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8C" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9C" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10C" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11C" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12C" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13C" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14C" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15C" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16C" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOC" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[C" },
};

const key_left = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2D" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3D" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4D" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5D" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6D" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7D" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8D" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9D" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10D" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11D" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12D" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13D" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14D" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15D" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16D" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOD" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[D" },
};

const key_home = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2H" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3H" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4H" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5H" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6H" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7H" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8H" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9H" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10H" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11H" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12H" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13H" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14H" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15H" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16H" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOH" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[H" },
};

const key_end = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2F" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3F" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4F" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5F" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6F" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7F" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8F" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9F" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10F" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11F" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12F" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13F" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14F" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15F" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16F" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOF" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[F" },
};

const key_insert = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2~" },
};

const key_delete = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3~" },
};

const key_pageup = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5~" },
};

const key_pagedown = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6~" },
};

const key_f1 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2P" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3P" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4P" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5P" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6P" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7P" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8P" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9P" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10P" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11P" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12P" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13P" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14P" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15P" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16P" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1bOP" },
};

const key_f2 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2Q" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3Q" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4Q" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5Q" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6Q" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7Q" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8Q" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9Q" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10Q" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11Q" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12Q" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13Q" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14Q" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15Q" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16Q" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1bOQ" },
};

const key_f3 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2R" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3R" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4R" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5R" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6R" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7R" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8R" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9R" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10R" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11R" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12R" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13R" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14R" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15R" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16R" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1bOR" },
};

const key_f4 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2S" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3S" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4S" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5S" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6S" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7S" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8S" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9S" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10S" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11S" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12S" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13S" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14S" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15S" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16S" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1bOS" },
};

const key_f5 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15~" },
};

const key_f6 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17~" },
};

const key_f7 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18~" },
};

const key_f8 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19~" },
};

const key_f9 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20~" },
};

const key_f10 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21~" },
};

const key_f11 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23~" },
};

const key_f12 = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24~" },
};

const key_f13 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2P" },
};

const key_f14 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2Q" },
};

const key_f15 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2R" },
};

const key_f16 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2S" },
};

const key_f17 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;2~" },
};

const key_f18 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;2~" },
};

const key_f19 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;2~" },
};

const key_f20 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;2~" },
};

const key_f21 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;2~" },
};

const key_f22 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;2~" },
};

const key_f23 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;2~" },
};

const key_f24 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[24;2~" },
};

const key_f25 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5P" },
};

const key_f26 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5Q" },
};

const key_f27 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5R" },
};

const key_f28 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5S" },
};

const key_f29 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[15;5~" },
};

const key_f30 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[17;5~" },
};

const key_f31 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[18;5~" },
};

const key_f32 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[19;5~" },
};

const key_f33 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[20;5~" },
};

const key_f34 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[21;5~" },
};

const key_f35 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[23;5~" },
};

const key_kp_up = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2A" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3A" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4A" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5A" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6A" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7A" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8A" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9A" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10A" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11A" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12A" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13A" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14A" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15A" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16A" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[A" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOA" },
};

const key_kp_down = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2B" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3B" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4B" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5B" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6B" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7B" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8B" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9B" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10B" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11B" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12B" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13B" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14B" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15B" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16B" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[B" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOB" },
};

const key_kp_right = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2C" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3C" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4C" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5C" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6C" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7C" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8C" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9C" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10C" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11C" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12C" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13C" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14C" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15C" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16C" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[C" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOC" },
};

const key_kp_left = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2D" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3D" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4D" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5D" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6D" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7D" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8D" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9D" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10D" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11D" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12D" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13D" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14D" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15D" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16D" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[D" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOD" },
};

const key_kp_begin = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2E" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3E" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4E" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5E" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6E" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7E" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8E" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9E" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10E" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11E" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12E" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13E" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14E" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15E" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16E" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[E" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOE" },
};

const key_kp_home = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2H" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3H" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4H" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5H" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6H" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7H" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8H" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9H" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10H" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11H" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12H" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13H" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14H" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15H" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16H" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[H" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOH" },
};

const key_kp_end = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;2F" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;3F" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;4F" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;5F" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;6F" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;7F" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;8F" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;9F" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;10F" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;11F" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;12F" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;13F" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;14F" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;15F" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[1;16F" },
    .{ .modifiers = 1, .cursor_keys = 1, .keypad_keys = 0, .seq = "\x1b[F" },
    .{ .modifiers = 1, .cursor_keys = 2, .keypad_keys = 0, .seq = "\x1bOF" },
};

const key_kp_insert = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[2~" },
};

const key_kp_delete = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[3~" },
};

const key_kp_pageup = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[5~" },
};

const key_kp_pagedown = [_]KeyData{
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;2~" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;3~" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;4~" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;5~" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;6~" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;7~" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;8~" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;9~" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;10~" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;11~" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;12~" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;13~" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;14~" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;15~" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6;16~" },
    .{ .modifiers = 1, .cursor_keys = 0, .keypad_keys = 0, .seq = "\x1b[6~" },
};

const key_kp_enter = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOM" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2M" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3M" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4M" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5M" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6M" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7M" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8M" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9M" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10M" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11M" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12M" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13M" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14M" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15M" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16M" },
};

const key_kp_divide = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOo" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2o" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3o" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4o" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5o" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6o" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7o" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8o" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9o" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10o" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11o" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12o" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13o" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14o" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15o" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16o" },
};

const key_kp_multiply = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOj" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2j" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3j" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4j" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5j" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6j" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7j" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8j" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9j" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10j" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11j" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12j" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13j" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14j" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15j" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16j" },
};

const key_kp_subtract = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOm" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2m" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3m" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4m" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5m" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6m" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7m" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8m" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9m" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10m" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11m" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12m" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13m" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14m" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15m" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16m" },
};

const key_kp_add = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOk" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2k" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3k" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4k" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5k" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6k" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7k" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8k" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9k" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10k" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11k" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12k" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13k" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14k" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15k" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16k" },
};

const key_kp_separator = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOl" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2l" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3l" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4l" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5l" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6l" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7l" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8l" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9l" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10l" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11l" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12l" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13l" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14l" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15l" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16l" },
};

const key_kp_decimal = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOn" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2n" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3n" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4n" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5n" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6n" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7n" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8n" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9n" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10n" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11n" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12n" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13n" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14n" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15n" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16n" },
};

const key_kp_0 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOp" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2p" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3p" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4p" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5p" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6p" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7p" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8p" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9p" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10p" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11p" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12p" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13p" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14p" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15p" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16p" },
};

const key_kp_1 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOq" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2q" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3q" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4q" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5q" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6q" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7q" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8q" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9q" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10q" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11q" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12q" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13q" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14q" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15q" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16q" },
};

const key_kp_2 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOr" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2r" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3r" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4r" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5r" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6r" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7r" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8r" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9r" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10r" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11r" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12r" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13r" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14r" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15r" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16r" },
};

const key_kp_3 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOs" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2s" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3s" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4s" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5s" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6s" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7s" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8s" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9s" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10s" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11s" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12s" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13s" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14s" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15s" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16s" },
};

const key_kp_4 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOt" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2t" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3t" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4t" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5t" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6t" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7t" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8t" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9t" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10t" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11t" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12t" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13t" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14t" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15t" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16t" },
};

const key_kp_5 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOu" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2u" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3u" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4u" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5u" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6u" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7u" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8u" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9u" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10u" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11u" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12u" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13u" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14u" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15u" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16u" },
};

const key_kp_6 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOv" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2v" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3v" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4v" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5v" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6v" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7v" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8v" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9v" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10v" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11v" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12v" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13v" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14v" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15v" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16v" },
};

const key_kp_7 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOw" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2w" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3w" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4w" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5w" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6w" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7w" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8w" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9w" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10w" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11w" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12w" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13w" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14w" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15w" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16w" },
};

const key_kp_8 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOx" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2x" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3x" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4x" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5x" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6x" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7x" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8x" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9x" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10x" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11x" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12x" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13x" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14x" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15x" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16x" },
};

const key_kp_9 = [_]KeyData{
    .{ .modifiers = 0, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bOy" },
    .{ .modifiers = 2, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO2y" },
    .{ .modifiers = 4, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO3y" },
    .{ .modifiers = 6, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO4y" },
    .{ .modifiers = 8, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO5y" },
    .{ .modifiers = 10, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO6y" },
    .{ .modifiers = 12, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO7y" },
    .{ .modifiers = 14, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO8y" },
    .{ .modifiers = 16, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO9y" },
    .{ .modifiers = 18, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO10y" },
    .{ .modifiers = 20, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO11y" },
    .{ .modifiers = 22, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO12y" },
    .{ .modifiers = 24, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO13y" },
    .{ .modifiers = 26, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO14y" },
    .{ .modifiers = 28, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO15y" },
    .{ .modifiers = 30, .cursor_keys = 0, .keypad_keys = 2, .seq = "\x1bO16y" },
};

/// The table for `sym`, or null. Mirrors keymap.h's switch statement.
export fn keymap_data_for_sym(sym: u32, count: *usize) callconv(.c) ?[*]const KeyData {
    switch (sym) {
        0xff1b => { // XKB_KEY_Escape
            count.* = key_escape.len;
            return &key_escape;
        },
        0xff0d => { // XKB_KEY_Return
            count.* = key_return.len;
            return &key_return;
        },
        0xfe20 => { // XKB_KEY_ISO_Left_Tab
            count.* = key_iso_left_tab.len;
            return &key_iso_left_tab;
        },
        0xff09 => { // XKB_KEY_Tab
            count.* = key_tab.len;
            return &key_tab;
        },
        0xff08 => { // XKB_KEY_BackSpace
            count.* = key_backspace.len;
            return &key_backspace;
        },
        0xff52 => { // XKB_KEY_Up
            count.* = key_up.len;
            return &key_up;
        },
        0xff54 => { // XKB_KEY_Down
            count.* = key_down.len;
            return &key_down;
        },
        0xff53 => { // XKB_KEY_Right
            count.* = key_right.len;
            return &key_right;
        },
        0xff51 => { // XKB_KEY_Left
            count.* = key_left.len;
            return &key_left;
        },
        0xff50 => { // XKB_KEY_Home
            count.* = key_home.len;
            return &key_home;
        },
        0xff57 => { // XKB_KEY_End
            count.* = key_end.len;
            return &key_end;
        },
        0xff63 => { // XKB_KEY_Insert
            count.* = key_insert.len;
            return &key_insert;
        },
        0xffff => { // XKB_KEY_Delete
            count.* = key_delete.len;
            return &key_delete;
        },
        0xff55 => { // XKB_KEY_Page_Up
            count.* = key_pageup.len;
            return &key_pageup;
        },
        0xff56 => { // XKB_KEY_Page_Down
            count.* = key_pagedown.len;
            return &key_pagedown;
        },
        0xffbe => { // XKB_KEY_F1
            count.* = key_f1.len;
            return &key_f1;
        },
        0xffbf => { // XKB_KEY_F2
            count.* = key_f2.len;
            return &key_f2;
        },
        0xffc0 => { // XKB_KEY_F3
            count.* = key_f3.len;
            return &key_f3;
        },
        0xffc1 => { // XKB_KEY_F4
            count.* = key_f4.len;
            return &key_f4;
        },
        0xffc2 => { // XKB_KEY_F5
            count.* = key_f5.len;
            return &key_f5;
        },
        0xffc3 => { // XKB_KEY_F6
            count.* = key_f6.len;
            return &key_f6;
        },
        0xffc4 => { // XKB_KEY_F7
            count.* = key_f7.len;
            return &key_f7;
        },
        0xffc5 => { // XKB_KEY_F8
            count.* = key_f8.len;
            return &key_f8;
        },
        0xffc6 => { // XKB_KEY_F9
            count.* = key_f9.len;
            return &key_f9;
        },
        0xffc7 => { // XKB_KEY_F10
            count.* = key_f10.len;
            return &key_f10;
        },
        0xffc8 => { // XKB_KEY_F11
            count.* = key_f11.len;
            return &key_f11;
        },
        0xffc9 => { // XKB_KEY_F12
            count.* = key_f12.len;
            return &key_f12;
        },
        0xffca => { // XKB_KEY_F13
            count.* = key_f13.len;
            return &key_f13;
        },
        0xffcb => { // XKB_KEY_F14
            count.* = key_f14.len;
            return &key_f14;
        },
        0xffcc => { // XKB_KEY_F15
            count.* = key_f15.len;
            return &key_f15;
        },
        0xffcd => { // XKB_KEY_F16
            count.* = key_f16.len;
            return &key_f16;
        },
        0xffce => { // XKB_KEY_F17
            count.* = key_f17.len;
            return &key_f17;
        },
        0xffcf => { // XKB_KEY_F18
            count.* = key_f18.len;
            return &key_f18;
        },
        0xffd0 => { // XKB_KEY_F19
            count.* = key_f19.len;
            return &key_f19;
        },
        0xffd1 => { // XKB_KEY_F20
            count.* = key_f20.len;
            return &key_f20;
        },
        0xffd2 => { // XKB_KEY_F21
            count.* = key_f21.len;
            return &key_f21;
        },
        0xffd3 => { // XKB_KEY_F22
            count.* = key_f22.len;
            return &key_f22;
        },
        0xffd4 => { // XKB_KEY_F23
            count.* = key_f23.len;
            return &key_f23;
        },
        0xffd5 => { // XKB_KEY_F24
            count.* = key_f24.len;
            return &key_f24;
        },
        0xffd6 => { // XKB_KEY_F25
            count.* = key_f25.len;
            return &key_f25;
        },
        0xffd7 => { // XKB_KEY_F26
            count.* = key_f26.len;
            return &key_f26;
        },
        0xffd8 => { // XKB_KEY_F27
            count.* = key_f27.len;
            return &key_f27;
        },
        0xffd9 => { // XKB_KEY_F28
            count.* = key_f28.len;
            return &key_f28;
        },
        0xffda => { // XKB_KEY_F29
            count.* = key_f29.len;
            return &key_f29;
        },
        0xffdb => { // XKB_KEY_F30
            count.* = key_f30.len;
            return &key_f30;
        },
        0xffdc => { // XKB_KEY_F31
            count.* = key_f31.len;
            return &key_f31;
        },
        0xffdd => { // XKB_KEY_F32
            count.* = key_f32.len;
            return &key_f32;
        },
        0xffde => { // XKB_KEY_F33
            count.* = key_f33.len;
            return &key_f33;
        },
        0xffdf => { // XKB_KEY_F34
            count.* = key_f34.len;
            return &key_f34;
        },
        0xffe0 => { // XKB_KEY_F35
            count.* = key_f35.len;
            return &key_f35;
        },
        0xff97 => { // XKB_KEY_KP_Up
            count.* = key_kp_up.len;
            return &key_kp_up;
        },
        0xff99 => { // XKB_KEY_KP_Down
            count.* = key_kp_down.len;
            return &key_kp_down;
        },
        0xff98 => { // XKB_KEY_KP_Right
            count.* = key_kp_right.len;
            return &key_kp_right;
        },
        0xff96 => { // XKB_KEY_KP_Left
            count.* = key_kp_left.len;
            return &key_kp_left;
        },
        0xff9d => { // XKB_KEY_KP_Begin
            count.* = key_kp_begin.len;
            return &key_kp_begin;
        },
        0xff95 => { // XKB_KEY_KP_Home
            count.* = key_kp_home.len;
            return &key_kp_home;
        },
        0xff9c => { // XKB_KEY_KP_End
            count.* = key_kp_end.len;
            return &key_kp_end;
        },
        0xff9e => { // XKB_KEY_KP_Insert
            count.* = key_kp_insert.len;
            return &key_kp_insert;
        },
        0xff9f => { // XKB_KEY_KP_Delete
            count.* = key_kp_delete.len;
            return &key_kp_delete;
        },
        0xff9a => { // XKB_KEY_KP_Page_Up
            count.* = key_kp_pageup.len;
            return &key_kp_pageup;
        },
        0xff9b => { // XKB_KEY_KP_Page_Down
            count.* = key_kp_pagedown.len;
            return &key_kp_pagedown;
        },
        0xff8d => { // XKB_KEY_KP_Enter
            count.* = key_kp_enter.len;
            return &key_kp_enter;
        },
        0xffaf => { // XKB_KEY_KP_Divide
            count.* = key_kp_divide.len;
            return &key_kp_divide;
        },
        0xffaa => { // XKB_KEY_KP_Multiply
            count.* = key_kp_multiply.len;
            return &key_kp_multiply;
        },
        0xffad => { // XKB_KEY_KP_Subtract
            count.* = key_kp_subtract.len;
            return &key_kp_subtract;
        },
        0xffab => { // XKB_KEY_KP_Add
            count.* = key_kp_add.len;
            return &key_kp_add;
        },
        0xffac => { // XKB_KEY_KP_Separator
            count.* = key_kp_separator.len;
            return &key_kp_separator;
        },
        0xffae => { // XKB_KEY_KP_Decimal
            count.* = key_kp_decimal.len;
            return &key_kp_decimal;
        },
        0xffb0 => { // XKB_KEY_KP_0
            count.* = key_kp_0.len;
            return &key_kp_0;
        },
        0xffb1 => { // XKB_KEY_KP_1
            count.* = key_kp_1.len;
            return &key_kp_1;
        },
        0xffb2 => { // XKB_KEY_KP_2
            count.* = key_kp_2.len;
            return &key_kp_2;
        },
        0xffb3 => { // XKB_KEY_KP_3
            count.* = key_kp_3.len;
            return &key_kp_3;
        },
        0xffb4 => { // XKB_KEY_KP_4
            count.* = key_kp_4.len;
            return &key_kp_4;
        },
        0xffb5 => { // XKB_KEY_KP_5
            count.* = key_kp_5.len;
            return &key_kp_5;
        },
        0xffb6 => { // XKB_KEY_KP_6
            count.* = key_kp_6.len;
            return &key_kp_6;
        },
        0xffb7 => { // XKB_KEY_KP_7
            count.* = key_kp_7.len;
            return &key_kp_7;
        },
        0xffb8 => { // XKB_KEY_KP_8
            count.* = key_kp_8.len;
            return &key_kp_8;
        },
        0xffb9 => { // XKB_KEY_KP_9
            count.* = key_kp_9.len;
            return &key_kp_9;
        },
        else => return null,
    }
}

/// The sequence to send for `sym` with `mods`, honouring the terminal's
/// cursor-key / keypad mode and the modifyOtherKeys state.
export fn keymap_lookup(
    term: *Terminal,
    sym: u32,
    mods: c_int,
) callconv(.c) ?*const KeyData {
    var count: usize = 0;
    const info = keymap_data_for_sym(sym, &count) orelse return null;

    const cursor_keys_mode: c_int = @intFromEnum(term.cursor_keys_mode);
    const keypad_keys_mode: c_int = if (term.num_lock_modifier)
        KEYPAD_NUMERICAL
    else
        @intFromEnum(term.keypad_keys_mode);

    var j: usize = 0;
    while (j < count) : (j += 1) {
        var modifiers = info[j].modifiers;

        if (modifiers & MOD_MODIFY_OTHER_KEYS_STATE1 != 0) {
            if (term.modify_other_keys_2)
                continue;
            modifiers &= ~MOD_MODIFY_OTHER_KEYS_STATE1;
        }
        if (modifiers & MOD_MODIFY_OTHER_KEYS_STATE2 != 0) {
            if (!term.modify_other_keys_2)
                continue;
            modifiers &= ~MOD_MODIFY_OTHER_KEYS_STATE2;
        }

        if (modifiers != MOD_ANY and modifiers != mods)
            continue;

        if (info[j].cursor_keys != CURSOR_KEYS_DONTCARE and
            info[j].cursor_keys != cursor_keys_mode)
            continue;

        if (info[j].keypad_keys != KEYPAD_DONTCARE and
            info[j].keypad_keys != keypad_keys_mode)
            continue;

        return &info[j];
    }

    return null;
}

// kitty-keymap.h's kitty_keymap[] (D4b2b), translated to Zig.
//
// The C struct was packed (u32 sym, u16 key, one byte of final+is_modifier);
// the C table is gone now, so the Zig struct only needs the same *fields*.
// The table *must* stay sorted by sym: kitty_kbd_protocol() binary-searches
// it (the generator asserts that).
pub const KittyKeyData = packed struct {
    sym: u32,
    key: u16,
    final: u7,
    is_modifier: bool,
};


const kitty_keymap = [_]KittyKeyData{
    .{ .sym = 0xfe03, .key = 57453, .final = 'u', .is_modifier = true },
    .{ .sym = 0xfe11, .key = 57454, .final = 'u', .is_modifier = true },
    .{ .sym = 0xfe20, .key = 9, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff08, .key = 127, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff09, .key = 9, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff0d, .key = 13, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff13, .key = 57362, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff14, .key = 57359, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff1b, .key = 27, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff50, .key = 1, .final = 'H', .is_modifier = false },
    .{ .sym = 0xff51, .key = 1, .final = 'D', .is_modifier = false },
    .{ .sym = 0xff52, .key = 1, .final = 'A', .is_modifier = false },
    .{ .sym = 0xff53, .key = 1, .final = 'C', .is_modifier = false },
    .{ .sym = 0xff54, .key = 1, .final = 'B', .is_modifier = false },
    .{ .sym = 0xff55, .key = 5, .final = '~', .is_modifier = false },
    .{ .sym = 0xff56, .key = 6, .final = '~', .is_modifier = false },
    .{ .sym = 0xff57, .key = 1, .final = 'F', .is_modifier = false },
    .{ .sym = 0xff61, .key = 57361, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff63, .key = 2, .final = '~', .is_modifier = false },
    .{ .sym = 0xff67, .key = 57363, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff7f, .key = 57360, .final = 'u', .is_modifier = true },
    .{ .sym = 0xff8d, .key = 57414, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff95, .key = 57423, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff96, .key = 57417, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff97, .key = 57419, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff98, .key = 57418, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff99, .key = 57420, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff9a, .key = 57421, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff9b, .key = 57422, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff9c, .key = 57424, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff9d, .key = 1, .final = 'E', .is_modifier = false },
    .{ .sym = 0xff9e, .key = 57425, .final = 'u', .is_modifier = false },
    .{ .sym = 0xff9f, .key = 57426, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffaa, .key = 57411, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffab, .key = 57413, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffac, .key = 57416, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffad, .key = 57412, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffae, .key = 57409, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffaf, .key = 57410, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb0, .key = 57399, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb1, .key = 57400, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb2, .key = 57401, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb3, .key = 57402, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb4, .key = 57403, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb5, .key = 57404, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb6, .key = 57405, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb7, .key = 57406, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb8, .key = 57407, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffb9, .key = 57408, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffbd, .key = 57415, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffbe, .key = 1, .final = 'P', .is_modifier = false },
    .{ .sym = 0xffbf, .key = 1, .final = 'Q', .is_modifier = false },
    .{ .sym = 0xffc0, .key = 13, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc1, .key = 1, .final = 'S', .is_modifier = false },
    .{ .sym = 0xffc2, .key = 15, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc3, .key = 17, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc4, .key = 18, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc5, .key = 19, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc6, .key = 20, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc7, .key = 21, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc8, .key = 23, .final = '~', .is_modifier = false },
    .{ .sym = 0xffc9, .key = 24, .final = '~', .is_modifier = false },
    .{ .sym = 0xffca, .key = 57376, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffcb, .key = 57377, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffcc, .key = 57378, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffcd, .key = 57379, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffce, .key = 57380, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffcf, .key = 57381, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd0, .key = 57382, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd1, .key = 57383, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd2, .key = 57384, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd3, .key = 57385, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd4, .key = 57386, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd5, .key = 57387, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd6, .key = 57388, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd7, .key = 57389, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd8, .key = 57390, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffd9, .key = 57391, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffda, .key = 57392, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffdb, .key = 57393, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffdc, .key = 57394, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffdd, .key = 57395, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffde, .key = 57396, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffdf, .key = 57397, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffe0, .key = 57398, .final = 'u', .is_modifier = false },
    .{ .sym = 0xffe1, .key = 57441, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe2, .key = 57447, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe3, .key = 57442, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe4, .key = 57448, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe5, .key = 57358, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe7, .key = 57446, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe8, .key = 57452, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffe9, .key = 57443, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffea, .key = 57449, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffeb, .key = 57444, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffec, .key = 57450, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffed, .key = 57445, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffee, .key = 57451, .final = 'u', .is_modifier = true },
    .{ .sym = 0xffff, .key = 3, .final = '~', .is_modifier = false },
    .{ .sym = 0x1008ff11, .key = 57438, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff12, .key = 57440, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff13, .key = 57439, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff14, .key = 57428, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff15, .key = 57432, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff16, .key = 57436, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff17, .key = 57435, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff1c, .key = 57437, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff31, .key = 57429, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff3e, .key = 57434, .final = 'u', .is_modifier = false },
    .{ .sym = 0x1008ff97, .key = 57433, .final = 'u', .is_modifier = false },
};

// ─────────────────────────────────────────────────────────────────────────
// The keyboard protocols (D4b2b): the legacy (VT/xterm-style) encoder and the
// kitty keyboard protocol encoder.
// ─────────────────────────────────────────────────────────────────────────

const WL_KEYBOARD_KEY_STATE_RELEASED: c_int = 0;
const WL_KEYBOARD_KEY_STATE_PRESSED: c_int = 1;

const XKB_COMPOSE_COMPOSING: c_int = 1;
const XKB_COMPOSE_COMPOSED: c_int = 2;

const XKB_KEY_UP_DIR: c_int = 0;
const XKB_KEY_DOWN_DIR: c_int = 1;

const XKB_KEY_a: u32 = 0x61;
const XKB_KEY_z: u32 = 0x7a;
const XKB_KEY_Return: u32 = 0xff0d;
const XKB_KEY_BackSpace: u32 = 0xff08;
const XKB_KEY_Tab: u32 = 0xff09;

// kitty keyboard protocol flag bits (kitty-keymap.h / terminal.h).
const KITTY_KBD_DISAMBIGUATE: u32 = 0x001;
const KITTY_KBD_REPORT_EVENT: u32 = 0x002;
const KITTY_KBD_REPORT_ALTERNATE: u32 = 0x004;
const KITTY_KBD_REPORT_ALL: u32 = 0x008;
const KITTY_KBD_REPORT_ASSOCIATED: u32 = 0x010;

/// input.c's `struct kbd_ctx`: everything the protocol encoders need about
/// one key event, resolved by key_press_release().
pub const KbdCtx = extern struct {
    layout: u32,
    key: u32,
    sym: u32,

    level0_syms: extern struct {
        syms: ?[*]const u32,
        count: usize,
    },

    mods: u32,
    consumed: u32,

    utf8: extern struct {
        buf: ?[*]const u8,
        count: usize,
    },
    utf32: ?[*]u32,

    compose_status: c_int,
    key_state: c_int,
};

extern fn xkb_state_key_get_layout(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn xkb_keymap_key_get_syms_by_level(
    keymap: ?*anyopaque,
    key: u32,
    layout: u32,
    level: u32,
    syms_out: *?[*]const u32,
) callconv(.c) c_int;
extern fn xkb_keysym_to_lower(sym: u32) callconv(.c) u32;
extern fn xkb_keysym_to_utf32(sym: u32) callconv(.c) u32;
extern fn xkb_state_update_key(state: ?*anyopaque, key: u32, direction: c_int) callconv(.c) c_int;
extern fn terminal_shim_isc32print(c32: u32) callconv(.c) bool;
extern fn term_to_slave(term: *Terminal, data: ?*const anyopaque, len: usize) callconv(.c) bool;
extern fn c32rtomb(s: [*]u8, wc: u32, ps: *anyopaque) callconv(.c) usize;


/// C's `is_control_key()`: 0x40..0x7f.
fn isControlKey(x: u32) bool {
    return x >= 0x40 and x <= 0x7f;
}

/// C's `IS_CTRL()`: C0 controls and DEL/C1.
fn isCtrlByte(x: u8) bool {
    return x < 0x20 or (x >= 0x7f and x <= 0x9f);
}

fn emit(term: *Terminal, data: []const u8) void {
    _ = term_to_slave(term, data.ptr, data.len);
}


/// The xterm modifier parameter used in CSI 27 ; <mod> ; <sym> ~.
fn modParam(mods: c_int) u8 {
    return switch (mods) {
        MOD_SHIFT => 2,
        MOD_ALT => 3,
        MOD_SHIFT | MOD_ALT => 4,
        MOD_CTRL => 5,
        MOD_SHIFT | MOD_CTRL => 6,
        MOD_ALT | MOD_CTRL => 7,
        MOD_SHIFT | MOD_ALT | MOD_CTRL => 8,
        MOD_META => 9,
        MOD_META | MOD_SHIFT => 10,
        MOD_META | MOD_ALT => 11,
        MOD_META | MOD_SHIFT | MOD_ALT => 12,
        MOD_META | MOD_CTRL => 13,
        MOD_META | MOD_SHIFT | MOD_CTRL => 14,
        MOD_META | MOD_ALT | MOD_CTRL => 15,
        MOD_META | MOD_SHIFT | MOD_ALT | MOD_CTRL => 16,
        else => 0,
    };
}

/// The legacy (i.e. non-kitty) encoder: MOD_ANY key tables first, then
/// modifyOtherKeys, then the meta/alt strategies.
export fn legacy_kbd_protocol(
    seat: *Seat,
    term: *Terminal,
    ctx: *const KbdCtx,
) callconv(.c) bool {
    if (ctx.key_state != WL_KEYBOARD_KEY_STATE_PRESSED)
        return false;
    if (ctx.compose_status == XKB_COMPOSE_COMPOSING)
        return false;

    var keymap_mods: c_int = MOD_NONE;
    if (seat.kbd.shift) keymap_mods |= MOD_SHIFT;
    if (seat.kbd.alt) keymap_mods |= MOD_ALT;
    if (seat.kbd.ctrl) keymap_mods |= MOD_CTRL;
    if (seat.kbd.super) keymap_mods |= MOD_META;

    const sym = ctx.sym;
    const count = ctx.utf8.count;
    const utf8 = ctx.utf8.buf;


    if (keymap_lookup(term, sym, keymap_mods)) |keymap| {
        emit(term, std.mem.span(keymap.seq));
        return true;
    }

    if (count == 0)
        return false;

    const ctrl_is_in_effect = (keymap_mods & MOD_CTRL) != 0;
    const ctrl_seq = isControlKey(sym) or
        (count == 1 and isCtrlByte(utf8.?[0]));

    var modify_other_keys2_in_effect = false;

    if (term.modify_other_keys_2) {
        // Mimic XTerm: with shift held, 'A'-'Z' are encoded as a CSI, other
        // upper-case symbols (e.g. 'Ö') are emitted as-is.
        const shift_mask: u32 = @as(u32, 1) << @intCast(seat.kbd.mod_shift);
        if ((ctx.mods & ~shift_mask & seat.kbd.legacy_significant) != 0) {
            modify_other_keys2_in_effect = true;
        } else {
            const layout_idx = xkb_state_key_get_layout(seat.kbd.xkb_state, ctx.key);

            // The pressed key's base symbol: for 'A' (shift-a) that's 'a'.
            var base_syms: ?[*]const u32 = null;
            const base_count = xkb_keymap_key_get_syms_by_level(
                seat.kbd.xkb_keymap, ctx.key, layout_idx, 0, &base_syms);

            const lower_cased_sym = xkb_keysym_to_lower(sym);
            var i: usize = 0;
            while (i < @as(usize, @intCast(base_count))) : (i += 1) {
                const s = base_syms.?[i];
                if (lower_cased_sym == s and s >= XKB_KEY_a and s <= XKB_KEY_z) {
                    modify_other_keys2_in_effect = true;
                    break;
                }
            }
        }
    }


    if (keymap_mods != MOD_NONE and
        (modify_other_keys2_in_effect or (ctrl_is_in_effect and !ctrl_seq)))
    {
        const modify_param = modParam(keymap_mods);
        std.debug.assert(modify_param != 0);

        var reply: [32]u8 = undefined;
        const n = std.fmt.bufPrint(&reply, "\x1b[27;{d};{d}~", .{ modify_param, sym }) catch
            return false;
        emit(term, n);
    } else if (keymap_mods & MOD_ALT != 0) {
        // Alt is either an ESC prefix, the 8th bit, or ignored entirely.
        if (term.meta.esc_prefix) {
            emit(term, "\x1b");
            emit(term, utf8.?[0..count]);
        } else if (term.meta.eight_bit and count == 1) {
            const wc: u32 = 0x80 | utf8.?[0];

            var utf8_meta: [8]u8 = undefined;
            var state: [4]usize = .{ 0, 0, 0, 0 };
            const chars = c32rtomb(&utf8_meta, wc, &state);

            if (chars != @as(usize, @bitCast(@as(isize, -1))))
                emit(term, utf8_meta[0..chars])
            else
                emit(term, utf8.?[0..count]);
        } else {
            // Alt ignored
            emit(term, utf8.?[0..count]);
        }
    } else {
        emit(term, utf8.?[0..count]);
    }

    return true;
}

fn kittyLookup(sym: u32) ?*const KittyKeyData {
    // The table is sorted; C used bsearch().
    var lo: usize = 0;
    var hi: usize = kitty_keymap.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = &kitty_keymap[mid];
        if (e.sym == sym)
            return e;
        if (e.sym < sym)
            lo = mid + 1
        else
            hi = mid;
    }
    return null;
}

/// The kitty keyboard protocol encoder.
export fn kitty_kbd_protocol(
    seat: *Seat,
    term: *Terminal,
    ctx: *const KbdCtx,
) callconv(.c) bool {
    const repeating = seat.kbd.repeat.dont_re_repeat;
    const pressed = ctx.key_state == WL_KEYBOARD_KEY_STATE_PRESSED and !repeating;
    const released = ctx.key_state == WL_KEYBOARD_KEY_STATE_RELEASED;
    const composing = ctx.compose_status == XKB_COMPOSE_COMPOSING;
    const composed = ctx.compose_status == XKB_COMPOSE_COMPOSED;

    const grid = term.grid.?;
    const flags: u32 = @bitCast(@intFromEnum(grid.kitty_kbd.flags[grid.kitty_kbd.idx]));

    const disambiguate = flags & KITTY_KBD_DISAMBIGUATE != 0;
    const report_events = flags & KITTY_KBD_REPORT_EVENT != 0;
    const report_alternate = flags & KITTY_KBD_REPORT_ALTERNATE != 0;
    const report_all_as_escapes = flags & KITTY_KBD_REPORT_ALL != 0;

    if (!report_events and released)
        return false;

    // TODO: should we even bother with this, or just say it's not supported?
    if (!disambiguate and !report_all_as_escapes and pressed)
        return legacy_kbd_protocol(seat, term, ctx);

    const sym = ctx.sym;
    const utf32 = ctx.utf32;
    const utf8 = ctx.utf8.buf;
    const count = ctx.utf8.count;

    // Look up sym in the pre-defined keysym table
    const info = kittyLookup(sym);
    std.debug.assert(info == null or info.?.sym == sym);

    var mods: u32 = 0;
    var locked: u32 = 0;
    var consumed: u32 = ctx.consumed;

    if (info != null and info.?.is_modifier) {
        // The xkb state reflects the state *before* this key event, so a
        // modifier key does not report itself. The kitty protocol requires
        // it to, so update the state, read it back, and (deliberately) do
        // not revert - see the comment in the C original.
        _ = xkb_state_update_key(
            seat.kbd.xkb_state, ctx.key, if (pressed) XKB_KEY_DOWN_DIR else XKB_KEY_UP_DIR);

        get_current_modifiers(seat, &mods, null, 0, false);

        locked = xkb_state_serialize_mods(seat.kbd.xkb_state, XKB_STATE_MODS_LOCKED);
        consumed = xkb_state_key_get_consumed_mods2(
            seat.kbd.xkb_state, ctx.key, XKB_CONSUMED_MODE_XKB);
    } else {
        // Same as ctx.mods, but *without* filtering locked modifiers
        get_current_modifiers(seat, &mods, null, 0, false);
        locked = xkb_state_serialize_mods(seat.kbd.xkb_state, XKB_STATE_MODS_LOCKED);
    }

    mods &= seat.kbd.kitty_significant;
    consumed &= seat.kbd.kitty_significant;

    // Locked modifiers are part of the protocol, but only when the key would
    // otherwise produce a CSIu: if it would produce plain text, emit text.
    var is_text = count > 0 and utf32 != null and (mods & ~locked & ~consumed) == 0;
    if (utf32) |u| {
        var i: usize = 0;
        while (u[i] != 0) : (i += 1) {
            if (!terminal_shim_isc32print(u[i])) {
                is_text = false;
                break;
            }
        }
    }

    const report_associated_text =
        (flags & KITTY_KBD_REPORT_ASSOCIATED != 0) and is_text and !released;

    if (composing and !(info != null and info.?.is_modifier)) {
        // We never emit anything while composing, *except* modifiers (and
        // only in report-all-keys-as-escape-codes mode).
        return false;
    }

    if (!composing and !report_all_as_escapes) {
        if ((mods & ~locked & ~consumed) == 0) {
            switch (sym) {
                XKB_KEY_Return => {
                    if (!released)
                        emit(term, "\r");
                    return true;
                },
                XKB_KEY_BackSpace => {
                    if (!released)
                        emit(term, "\x7f");
                    return true;
                },
                XKB_KEY_Tab => {
                    if (!released)
                        emit(term, "\t");
                    return true;
                },
                else => {},
            }
        }

        // Plain-text without modifiers, or composed text, is emitted as-is
        if (is_text and !released) {
            emit(term, utf8.?[0..count]);
            return true;
        }
    }

    // ── emit_escapes ──────────────────────────────────────────────────────
    var encoded_mods: u32 = 0;
    inline for (.{
        .{ "mod_shift", 0 },
        .{ "mod_alt", 1 },
        .{ "mod_ctrl", 2 },
        .{ "mod_super", 3 },
        .{ "mod_caps", 6 },
        .{ "mod_num", 7 },
    }) |spec| {
        const idx = @field(seat.kbd, spec[0]);
        if (idx != XKB_MOD_INVALID) {
            if (mods & (@as(u32, 1) << @intCast(idx)) != 0)
                encoded_mods |= @as(u32, 1) << spec[1];
        }
    }
    encoded_mods += 1;

    var unshifted: i32 = -1;
    var shifted: i32 = -1;
    var base: i32 = -1;
    var final: u8 = 'u';

    if (info) |i| {
        // Use the code from the lookup table (cursor keys, enter, tab, ...)
        if (!i.is_modifier or report_all_as_escapes) {
            shifted = @intCast(i.key);
            final = @intCast(i.final);
        }
    } else {
        // Use the keysym (typically its Unicode codepoint value)
        shifted = if (composed)
            @bitCast(utf32.?[0])
        else
            @bitCast(xkb_keysym_to_utf32(sym));

        final = 'u';
    }

    if (shifted <= 0)
        return false;

    // The symbol the pressed key produces in the base layout (layout 0).
    var base_syms: ?[*]const u32 = null;
    const base_sym_count = xkb_keymap_key_get_syms_by_level(
        seat.kbd.xkb_keymap, ctx.key, 0, 0, &base_syms);
    if (base_sym_count > 0) {
        const utf32_base = xkb_keysym_to_utf32(base_syms.?[0]);
        if (utf32_base != 0)
            base = @bitCast(utf32_base);
    }

    // If a non-significant modifier generated the symbol, keep the shifted
    // codepoint: those modifiers cannot be encoded, so using the base symbol
    // would lose them (e.g. AltGr+2 = '@' on a Swedish layout).
    const use_level0_sym =
        (ctx.mods & ~seat.kbd.kitty_significant) == 0 and ctx.level0_syms.count > 0;

    unshifted = if (use_level0_sym) @bitCast(xkb_keysym_to_utf32(ctx.level0_syms.syms.?[0])) else 0;

    std.debug.assert(encoded_mods >= 1);

    var event_buf: [4]u8 = .{ 0, 0, 0, 0 };
    if (report_events) {
        // Note: this deviates slightly from kitty, which omits the ":1"
        // sub-parameter for key press events.
        event_buf[0] = ':';
        event_buf[1] = '0' + @as(u8, if (pressed) 1 else if (repeating) 2 else 3);
    }
    const event = std.mem.sliceTo(&event_buf, 0);

    var buf: [128]u8 = undefined;
    var len: usize = 0;

    const key: i32 = if (unshifted > 0 and
        terminal_shim_isc32print(@bitCast(unshifted)) and !composed)
        unshifted
    else
        shifted;
    const alternate = shifted;

    if (final == 'u' or final == '~') {
        len += (std.fmt.bufPrint(buf[len..], "\x1b[{d}", .{key}) catch return false).len;

        if (report_alternate) {
            const emit_alternate = alternate > 0 and alternate != key;
            const emit_base = base > 0 and base != key and base != alternate and
                terminal_shim_isc32print(@bitCast(base));

            if (emit_alternate)
                len += (std.fmt.bufPrint(buf[len..], ":{d}", .{alternate}) catch return false).len;

            if (emit_base)
                len += (std.fmt.bufPrint(
                    buf[len..], "{s}:{d}", .{ if (!emit_alternate) ":" else "", base }) catch return false).len;
        }

        const emit_mods = encoded_mods > 1 or event.len > 0;
        if (emit_mods)
            len += (std.fmt.bufPrint(buf[len..], ";{d}{s}", .{ encoded_mods, event }) catch return false).len;

        if (report_associated_text) {
            len += (std.fmt.bufPrint(
                buf[len..], "{s};{d}", .{ if (!emit_mods) ";" else "", utf32.?[0] }) catch return false).len;

            // Additional text codepoints
            if (utf32.?[0] != 0) {
                var i: usize = 1;
                while (utf32.?[i] != 0) : (i += 1) {
                    len += (std.fmt.bufPrint(buf[len..], ":{d}", .{utf32.?[i]}) catch return false).len;
                }
            }
        }

        len += (std.fmt.bufPrint(buf[len..], "{c}", .{final}) catch return false).len;
    } else {
        if (encoded_mods > 1 or event.len > 0)
            len += (std.fmt.bufPrint(
                buf[len..], "\x1b[1;{d}{s}{c}", .{ encoded_mods, event, final }) catch return false).len
        else
            len += (std.fmt.bufPrint(buf[len..], "\x1b[{c}", .{final}) catch return false).len;
    }

    return term_to_slave(term, &buf, len);
}

// ─────────────────────────────────────────────────────────────────────────
// Pointer helpers (D4d1): the small coordinate/state functions the pointer
// listeners are built on.
// ─────────────────────────────────────────────────────────────────────────

/// Forget all pressed buttons and the double/triple-click state.
export fn mouse_button_state_reset(seat: *Seat) callconv(.c) void {
    const buttons: *tll.Tll(types.ButtonTracker) = @ptrCast(&seat.mouse.buttons);
    buttons.freeList();

    seat.mouse.count = 0;
    seat.mouse.last_released_button = 0;
    seat.mouse.last_time = .{ .tv_sec = 0, .tv_nsec = 0 };
}

/// Translate an x/y pixel coordinate to a cell coordinate, clamping inside the
/// grid (i.e. a pointer in the margins lands on the first/last cell).
export fn mouse_coord_pixel_to_cell(
    seat: *Seat,
    term: *const Terminal,
    x: c_int,
    y: c_int,
) callconv(.c) void {
    if (x < term.margins.left)
        seat.mouse.col = 0
    else if (x >= term.width - term.margins.right)
        seat.mouse.col = term.cols - 1
    else
        seat.mouse.col = @divTrunc(x - term.margins.left, term.cell_width);

    if (y < term.margins.top)
        seat.mouse.row = 0
    else if (y >= term.height - term.margins.bottom)
        seat.mouse.row = term.rows - 1
    else
        seat.mouse.row = @divTrunc(y - term.margins.top, term.cell_height);
}

/// True while a touch gesture owns the pointer (so emulated pointer events can
/// be ignored).
export fn touch_is_active(seat: *const Seat) callconv(.c) bool {
    if (seat.wl_touch == null)
        return false;

    // Read the state as a plain int: the C enum has a negative member
    // (TOUCH_STATE_INHIBITED = -1), and switching on the mirrored Zig enum
    // here mis-compiled in ReleaseSafe (it reported "active" for idle).
    const state: c_int = @bitCast(@intFromEnum(seat.touch.state));
    return switch (state) {
        @intFromEnum(types.TouchState.inhibited),
        @intFromEnum(types.TouchState.idle),
        => false,

        @intFromEnum(types.TouchState.held),
        @intFromEnum(types.TouchState.dragging),
        @intFromEnum(types.TouchState.scrolling),
        => true,

        else => false,
    };
}

/// The scroll amount multiplier: the configured scrollback multiplier on the
/// normal grid, or on the alternate grid only when the mouse is grabbed and
/// alternate scrolling is enabled.
export fn mouse_scroll_multiplier(term: *const Terminal, seat: *const Seat) callconv(.c) f64 {
    const grid = term.grid.?;
    const use_multiplier =
        grid == &term.normal or
        (term_mouse_grabbed(term, seat) and term.alt_scrolling);

    return if (use_multiplier) term.conf.?.scrollback.multiplier else 1.0;
}

// ─────────────────────────────────────────────────────────────────────────
// keyboard_modifiers (D4b3)
// ─────────────────────────────────────────────────────────────────────────

extern fn xkb_state_mod_index_is_active(
    state: ?*anyopaque, idx: u32, components: u32) callconv(.c) c_int;

/// The compositor's modifier state changed: feed it to xkb, cache the four
/// modifiers foot cares about (for mouse events and shortcut matching), and
/// refresh the cursor if the pointer is over the grid.
export fn keyboard_modifiers(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    serial: u32,
    mods_depressed_in: u32,
    mods_latched_in: u32,
    mods_locked_in: u32,
    group: u32,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = serial;

    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    // Some compositors (Mutter) report virtual modifiers in addition to the
    // real ones; they must not take part in any matching.
    const mods_depressed = mods_depressed_in & ~seat.kbd.virtual_modifiers;
    const mods_latched = mods_latched_in & ~seat.kbd.virtual_modifiers;
    const mods_locked = mods_locked_in & ~seat.kbd.virtual_modifiers;

    // (C logged the three masks via modifier_string() under _DEBUG; the
    // harness builds with -D_DEBUG but Zig has no such switch, and the
    // strings are only useful when debugging interactively.)
    if (seat.kbd.xkb_state) |state| {
        _ = xkb_state_update_mask(
            state, mods_depressed, mods_latched, mods_locked, 0, 0, group);

        // Update the state of the modifiers we're interested in, for e.g.
        // mouse events.
        seat.kbd.shift = seat.kbd.mod_shift != XKB_MOD_INVALID and
            xkb_state_mod_index_is_active(
                state, seat.kbd.mod_shift, XKB_STATE_MODS_EFFECTIVE) == 1;
        seat.kbd.alt = seat.kbd.mod_alt != XKB_MOD_INVALID and
            xkb_state_mod_index_is_active(
                state, seat.kbd.mod_alt, XKB_STATE_MODS_EFFECTIVE) == 1;
        seat.kbd.ctrl = seat.kbd.mod_ctrl != XKB_MOD_INVALID and
            xkb_state_mod_index_is_active(
                state, seat.kbd.mod_ctrl, XKB_STATE_MODS_EFFECTIVE) == 1;
        seat.kbd.super = seat.kbd.mod_super != XKB_MOD_INVALID and
            xkb_state_mod_index_is_active(
                state, seat.kbd.mod_super, XKB_STATE_MODS_EFFECTIVE) == 1;
    }

    if (seat.kbd_focus) |focused| {
        if (focused.active_surface == .grid)
            term_xcursor_update_for_seat(focused, seat);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// key_press_release (D4b4): the dispatcher between key events, the binding
// matchers and the two protocol encoders.
// ─────────────────────────────────────────────────────────────────────────

const XKB_KEYSYM_MAX: u32 = 0x1fffff;
const WL_KEYBOARD_KEY_STATE_RELEASED_C: c_int = 0;
const WL_KEYBOARD_KEY_STATE_PRESSED_C: c_int = 1;
const XKB_COMPOSE_CANCELLED: c_int = 3;

extern fn clock_gettime(clockid: c_int, tp: *Timespec) callconv(.c) c_int;
extern fn xkb_keymap_key_repeats(keymap: ?*anyopaque, key: u32) callconv(.c) c_int;
extern fn xkb_state_key_get_one_sym(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn xkb_compose_state_feed(state: ?*anyopaque, sym: u32) callconv(.c) c_int;
extern fn xkb_compose_state_get_status(state: ?*anyopaque) callconv(.c) c_int;
extern fn xkb_compose_state_get_utf8(
    state: ?*anyopaque, buffer: ?[*]u8, size: usize) callconv(.c) c_int;
extern fn xkb_state_key_get_utf8(
    state: ?*anyopaque, key: u32, buffer: ?[*]u8, size: usize) callconv(.c) c_int;
extern fn xkb_state_key_get_utf32(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn key_binding_for(
    mgr: ?*anyopaque, conf: *const types.Config, seat: *Seat) callconv(.c) ?*types.KeyBindingSet;
extern fn unicode_mode_input(seat: *Seat, term: *Terminal, sym: u32) callconv(.c) void;
extern fn search_input(
    seat: *Seat,
    term: *Terminal,
    bindings: *const types.KeyBindingSet,
    key: u32,
    sym: u32,
    mods: u32,
    consumed: u32,
    raw_syms: [*c]const u32,
    raw_count: usize,
    serial: u32,
) callconv(.c) void;
extern fn urls_input(
    seat: *Seat,
    term: *Terminal,
    bindings: *const types.KeyBindingSet,
    key: u32,
    sym: u32,
    mods: u32,
    consumed: u32,
    raw_syms: [*c]const u32,
    raw_count: usize,
    serial: u32,
) callconv(.c) void;
extern fn execute_binding(
    seat: *Seat,
    term: *Terminal,
    binding: *const types.KeyBinding,
    serial: u32,
    amount: c_int,
) callconv(.c) bool;
extern fn term_reset_view(term: *Terminal) callconv(.c) void;
extern fn selection_cancel(term: *Terminal) callconv(.c) void;
extern fn ambstoc32(src: [*c]const u8) callconv(.c) ?[*]u32;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xcalloc(n: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn terminal_shim_urls_mode_active(term: *const Terminal) callconv(.c) bool;

fn bindingList(set: *const types.KeyBindingSet, comptime field: []const u8) *tll.Tll(types.KeyBinding) {
    return @ptrCast(@constCast(&@field(set, field)));
}

export fn key_press_release(
    seat: *Seat,
    term: *Terminal,
    serial: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    std.debug.assert(serial != 0);

    seat.kbd.serial = serial;

    const keymap = seat.kbd.xkb_keymap orelse return;
    const xkb_state = seat.kbd.xkb_state orelse return;
    if (seat.kbd.xkb == null)
        return;

    const pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED_C;
    const released = state == WL_KEYBOARD_KEY_STATE_RELEASED_C;

    if (released)
        _ = stop_repeater(seat, key);

    if (pressed)
        seat.kbd.last_shortcut_sym = XKB_KEYSYM_MAX + 1;

    const should_repeat = pressed and xkb_keymap_key_repeats(keymap, key) != 0;

    const sym = xkb_state_key_get_one_sym(xkb_state, key);

    const conf = term.conf.?;

    if (pressed and conf.mouse.hide_when_typing and !keysym_is_modifier(sym)) {
        seat.pointer.hidden = true;
        term_xcursor_update_for_seat(term, seat);
    }

    var compose_status: c_int = 0; // XKB_COMPOSE_NOTHING
    if (seat.kbd.xkb_compose_state) |compose| {
        if (pressed)
            _ = xkb_compose_state_feed(compose, sym);
        compose_status = xkb_compose_state_get_status(compose);
    }

    const composed = compose_status == XKB_COMPOSE_COMPOSED;

    var mods: u32 = 0;
    var consumed: u32 = 0;
    get_current_modifiers(seat, &mods, &consumed, key, true);

    const layout_idx = xkb_state_key_get_layout(xkb_state, key);

    var raw_syms: ?[*]const u32 = null;
    const raw_count_signed = xkb_keymap_key_get_syms_by_level(
        keymap, key, layout_idx, 0, &raw_syms);
    const raw_count: usize = @intCast(@max(raw_count_signed, 0));

    const bindings = key_binding_for(
        seat.wayl.?.key_binding_manager, conf, seat) orelse return;

    if (term.unicode_mode.active) {
        if (pressed)
            unicode_mode_input(seat, term, sym);
        return;
    } else if (term.is_searching) {
        if (pressed) {
            if (should_repeat)
                _ = start_repeater(seat, key);

            search_input(
                seat, term, bindings, key, sym, mods, consumed,
                raw_syms, raw_count, serial);
        }
        return;
    } else if (terminal_shim_urls_mode_active(term)) {
        if (pressed) {
            if (should_repeat)
                _ = start_repeater(seat, key);

            urls_input(
                seat, term, bindings, key, sym, mods, consumed,
                raw_syms, raw_count, serial);
        }
        return;
    }

    var handled = false;

    maybe_repeat: {
        // ── user configurable bindings ────────────────────────────────────
        if (pressed) {
            const key_bindings = bindingList(bindings, "key");

            // Match untranslated symbols
            var it = key_bindings.foreach();
            while (it.next()) |node| {
                const bind = &node.item;

                if (bind.mods != mods or bind.mods == 0)
                    continue;

                var i: usize = 0;
                while (i < raw_count) : (i += 1) {
                    if (bind._u.k.sym == raw_syms.?[i] and
                        execute_binding(seat, term, bind, serial, 1))
                    {
                        seat.kbd.last_shortcut_sym = sym;
                        break :maybe_repeat;
                    }
                }
            }

            // Match translated symbol
            var it2 = key_bindings.foreach();
            while (it2.next()) |node| {
                const bind = &node.item;

                if (bind._u.k.sym == sym and
                    bind.mods == (mods & ~consumed) and
                    execute_binding(seat, term, bind, serial, 1))
                {
                    seat.kbd.last_shortcut_sym = sym;
                    break :maybe_repeat;
                }
            }

            // Match raw key code
            var it3 = key_bindings.foreach();
            while (it3.next()) |node| {
                const bind = &node.item;

                if (bind.mods != mods or bind.mods == 0)
                    continue;

                const codes: *tll.Tll(c_int) = @ptrCast(
                    @constCast(&bind._u.k.key_codes));
                var cit = codes.foreach();
                while (cit.next()) |cnode| {
                    if (cnode.item == @as(c_int, @intCast(key)) and
                        execute_binding(seat, term, bind, serial, 1))
                    {
                        seat.kbd.last_shortcut_sym = sym;
                        break :maybe_repeat;
                    }
                }
            }
        }

        if (released and seat.kbd.last_shortcut_sym == sym) {
            // Don't process a release event that corresponds to a triggered
            // shortcut: the press was consumed, so its release must not emit
            // an escape (which also used to reset the viewport).
            break :maybe_repeat;
        }

        if (compose_status == XKB_COMPOSE_CANCELLED)
            break :maybe_repeat;

        // ── compose, and maybe emit "normal" characters ───────────────────
        std.debug.assert(seat.kbd.xkb_compose_state != null or !composed);

        var count_signed: c_int = 0;
        if (composed) {
            count_signed = xkb_compose_state_get_utf8(seat.kbd.xkb_compose_state, null, 0);
        } else {
            count_signed = xkb_state_key_get_utf8(xkb_state, key, null, 0);
        }
        const count: usize = @intCast(@max(count_signed, 0));

        var buf: [32]u8 = undefined;
        var heap_utf8: ?[*]u8 = null;
        var utf8: [*]u8 = &buf;
        if (count >= buf.len) {
            heap_utf8 = @ptrCast(xmalloc(count + 1).?);
            utf8 = heap_utf8.?;
        }

        var utf32: ?[*]u32 = null;

        if (composed) {
            _ = xkb_compose_state_get_utf8(
                seat.kbd.xkb_compose_state, utf8, count + 1);

            if (count > 0)
                utf32 = ambstoc32(utf8);
        } else {
            _ = xkb_state_key_get_utf8(xkb_state, key, utf8, count + 1);

            const allocated: [*]u32 = @ptrCast(@alignCast(xcalloc(2, @sizeOf(u32)).?));
            allocated[0] = xkb_state_key_get_utf32(xkb_state, key);
            allocated[1] = 0;
            utf32 = allocated;
        }

        const ctx = KbdCtx{
            .layout = layout_idx,
            .key = key,
            .sym = sym,
            .level0_syms = .{ .syms = raw_syms, .count = raw_count },
            .mods = mods,
            .consumed = consumed,
            .utf8 = .{ .buf = utf8, .count = count },
            .utf32 = utf32,
            .compose_status = compose_status,
            .key_state = @intCast(state),
        };

        const flags: u32 = @bitCast(@intFromEnum(
            term.grid.?.kitty_kbd.flags[term.grid.?.kitty_kbd.idx]));
        handled = if (flags != 0)
            kitty_kbd_protocol(seat, term, &ctx)
        else
            legacy_kbd_protocol(seat, term, &ctx);

        if (composed and released)
            xkb_compose_state_reset(seat.kbd.xkb_compose_state);

        if (heap_utf8) |h|
            free(h);

        if (handled and !keysym_is_modifier(sym)) {
            term_reset_view(term);
            selection_cancel(term);
        }

        if (utf32) |u|
            free(u);
    }

    // maybe_repeat:
    _ = clock_gettime(
        @intCast(term.wl.?.presentation_clock_id),
        @ptrCast(@alignCast(&term.render.input_time)),
    );

    if (should_repeat)
        _ = start_repeater(seat, key);
}

// ─────────────────────────────────────────────────────────────────────────
// The last keyboard wrappers (D4b5): keyboard_key(), input_repeat() and
// alternate_scroll(). With these, every keyboard entry point is Zig.
// ─────────────────────────────────────────────────────────────────────────

const BTN_FORWARD: c_int = 0x115;
const BTN_BACK: c_int = 0x116;

/// The wl_keyboard.key listener: evdev keycodes are 8 lower than xkb's.
export fn keyboard_key(
    data: ?*anyopaque,
    wl_keyboard: ?*anyopaque,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = wl_keyboard;
    _ = time;

    const seat: *Seat = @ptrCast(@alignCast(data orelse return));
    const term = seat.kbd_focus orelse return;

    key_press_release(seat, term, serial, key + 8, state);
}

/// The repeat timer fired: re-deliver the key as a press.
export fn input_repeat(seat: *Seat, key: u32) callconv(.c) void {
    // Should be cleared as soon as we lose focus
    std.debug.assert(seat.kbd_focus != null);
    const term = seat.kbd_focus.?;

    key_press_release(seat, term, seat.kbd.serial, key, WL_KEYBOARD_KEY_STATE_PRESSED_C);
}

/// Alternate scrolling: on the alternate grid, a scroll is turned into Up/Down
/// key presses (unless the application asked for mouse reporting).
export fn alternate_scroll(seat: *Seat, amount: c_int, button: c_int) callconv(.c) void {
    if (seat.wl_keyboard == null)
        return;

    // Should be cleared in the leave event
    std.debug.assert(seat.mouse_focus != null);
    const term = seat.mouse_focus.?;

    std.debug.assert(button == BTN_BACK or button == BTN_FORWARD);

    const key: u32 = if (button == BTN_BACK)
        seat.kbd.key_arrow_up
    else
        seat.kbd.key_arrow_down;

    var i: c_int = 0;
    while (i < amount) : (i += 1)
        key_press_release(seat, term, seat.kbd.serial, key, WL_KEYBOARD_KEY_STATE_PRESSED_C);

    key_press_release(seat, term, seat.kbd.serial, key, WL_KEYBOARD_KEY_STATE_RELEASED_C);
}

// ─────────────────────────────────────────────────────────────────────────
// Mouse bindings and scrolling (D4d2a)
// ─────────────────────────────────────────────────────────────────────────

const BTN_WHEEL_BACK: c_int = 0x11c;
const BTN_WHEEL_FORWARD: c_int = 0x11d;
const BTN_WHEEL_LEFT: c_int = 0x11e;
const BTN_WHEEL_RIGHT: c_int = 0x11f;

const WL_POINTER_AXIS_VERTICAL_SCROLL: u32 = 0;

extern fn term_mouse_down(
    term: *Terminal,
    button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    shift: bool,
    alt: bool,
    ctrl: bool,
) callconv(.c) void;
extern fn term_mouse_up(
    term: *Terminal,
    button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    shift: bool,
    alt: bool,
    ctrl: bool,
) callconv(.c) void;

/// The mouse binding matching `button` for this seat, if any.
///
/// With a keyboard, bindings are matched *with* modifiers (the selection
/// overrides are masked out first) and the highest click count wins. Without
/// one, the config's mouse bindings are matched without modifiers at all, and
/// the result is a synthesized static binding.
export fn match_mouse_binding(
    seat: *const Seat,
    term: *const Terminal,
    button: c_int,
) callconv(.c) ?*const types.KeyBinding {
    if (seat.wl_keyboard != null and seat.kbd.xkb_state != null) {
        // Seat has a keyboard: use mouse bindings *with* modifiers
        const bindings = key_binding_for(
            term.wl.?.key_binding_manager, term.conf.?, @constCast(seat)) orelse return null;

        var mods: u32 = 0;
        get_current_modifiers(seat, &mods, null, 0, true);

        // Ignore the selection-override modifiers when matching
        mods &= ~bindings.selection_overrides;

        var result: ?*const types.KeyBinding = null;

        const mouse_list: *tll.Tll(types.KeyBinding) = @ptrCast(
            @constCast(&bindings.mouse));
        var it = mouse_list.foreach();
        while (it.next()) |node| {
            const binding = &node.item;

            if (binding._u.m.button != @as(u32, @intCast(button)))
                continue; // Wrong button

            if (binding.mods != mods)
                continue; // Modifier mismatch

            if (binding._u.m.count > seat.mouse.count)
                continue; // Not the right click count

            if (result == null or binding._u.m.count > result.?._u.m.count)
                result = binding;
        }

        return result;
    }

    // Seat does NOT have a keyboard: use the config's mouse bindings
    // *without* modifiers
    var found: ?*const types.ConfigKeyBinding = null;
    const conf = term.conf.?;

    var i: usize = 0;
    while (i < conf.bindings.mouse.count) : (i += 1) {
        const binding = &conf.bindings.mouse.arr.?[i];

        if (binding._u.m.button != button)
            continue; // Wrong button

        if (binding._u.m.count > seat.mouse.count)
            continue; // Incorrect click count

        const modifiers: *tll.Tll([*:0]u8) = @ptrCast(@constCast(&binding.modifiers));
        if (modifiers.len() > 0)
            continue; // Binding has modifiers

        if (found == null or binding._u.m.count > found.?._u.m.count)
            found = binding;
    }

    if (found) |match| {
        const Static = struct {
            var bind: types.KeyBinding = undefined;
        };
        Static.bind = std.mem.zeroes(types.KeyBinding);
        Static.bind.action = match.action;
        Static.bind.aux = @ptrCast(@constCast(&match.aux));
        return &Static.bind;
    }

    return null;
}

/// Turn a scroll event into either a mouse report (if the application grabbed
/// the mouse), a binding match, or plain button presses.
export fn mouse_scroll(seat: *Seat, amount: c_int, axis: u32) callconv(.c) void {
    const term = seat.mouse_focus orelse return;

    const button: c_int = if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL)
        (if (amount < 0) BTN_WHEEL_BACK else BTN_WHEEL_FORWARD)
    else
        (if (amount < 0) BTN_WHEEL_LEFT else BTN_WHEEL_RIGHT);
    const count = if (amount < 0) -amount else amount;

    if (term_mouse_grabbed(term, seat)) {
        seat.mouse.count = 1;

        if (match_mouse_binding(seat, term, button)) |match| {
            _ = execute_binding(seat, term, match, seat.pointer.serial, count);
        }

        seat.mouse.last_released_button = button;
    } else if (seat.mouse.col >= 0 and seat.mouse.row >= 0) {
        std.debug.assert(seat.mouse.col < term.cols);
        std.debug.assert(seat.mouse.row < term.rows);

        var i: c_int = 0;
        while (i < count) : (i += 1) {
            term_mouse_down(
                term, button, seat.mouse.row, seat.mouse.col,
                seat.mouse.y - term.margins.top,
                seat.mouse.x - term.margins.left,
                seat.kbd.shift, seat.kbd.alt, seat.kbd.ctrl);
        }

        term_mouse_up(
            term, button, seat.mouse.row, seat.mouse.col,
            seat.mouse.y - term.margins.top,
            seat.mouse.x - term.margins.left,
            seat.kbd.shift, seat.kbd.alt, seat.kbd.ctrl);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Binding-action constants (D4c groundwork)
//
// The values are emitted by asking the C compiler (scripts/gen_bind_enums.sh),
// so they cannot drift from key-binding.h / config.h.
// ─────────────────────────────────────────────────────────────────────────

pub const BINDING_AUX_NONE: c_int = 0;
pub const BINDING_AUX_PIPE: c_int = 1;
pub const BINDING_AUX_REGEX: c_int = 3;
pub const BINDING_AUX_TEXT: c_int = 2;
pub const BIND_ACTION_CLIPBOARD_COPY: c_int = 10;
pub const BIND_ACTION_CLIPBOARD_PASTE: c_int = 11;
pub const BIND_ACTION_COUNT: c_int = 48;
pub const BIND_ACTION_FONT_SIZE_DOWN: c_int = 15;
pub const BIND_ACTION_FONT_SIZE_RESET: c_int = 16;
pub const BIND_ACTION_FONT_SIZE_UP: c_int = 14;
pub const BIND_ACTION_FULLSCREEN: c_int = 20;
pub const BIND_ACTION_KEY_COUNT: c_int = 38;
pub const BIND_ACTION_MAXIMIZE: c_int = 19;
pub const BIND_ACTION_MINIMIZE: c_int = 18;
pub const BIND_ACTION_NONE: c_int = 0;
pub const BIND_ACTION_NOOP: c_int = 1;
pub const BIND_ACTION_PIPE_COMMAND_OUTPUT: c_int = 24;
pub const BIND_ACTION_PIPE_SCROLLBACK: c_int = 21;
pub const BIND_ACTION_PIPE_SELECTED: c_int = 23;
pub const BIND_ACTION_PIPE_VIEW: c_int = 22;
pub const BIND_ACTION_PRIMARY_PASTE: c_int = 12;
pub const BIND_ACTION_PROMPT_NEXT: c_int = 30;
pub const BIND_ACTION_PROMPT_PREV: c_int = 29;
pub const BIND_ACTION_QUIT: c_int = 32;
pub const BIND_ACTION_REGEX_COPY: c_int = 34;
pub const BIND_ACTION_REGEX_LAUNCH: c_int = 33;
pub const BIND_ACTION_SCROLLBACK_DOWN_HALF_PAGE: c_int = 6;
pub const BIND_ACTION_SCROLLBACK_DOWN_LINE: c_int = 7;
pub const BIND_ACTION_SCROLLBACK_DOWN_MOUSE: c_int = 39;
pub const BIND_ACTION_SCROLLBACK_DOWN_PAGE: c_int = 5;
pub const BIND_ACTION_SCROLLBACK_END: c_int = 9;
pub const BIND_ACTION_SCROLLBACK_HOME: c_int = 8;
pub const BIND_ACTION_SCROLLBACK_UP_HALF_PAGE: c_int = 3;
pub const BIND_ACTION_SCROLLBACK_UP_LINE: c_int = 4;
pub const BIND_ACTION_SCROLLBACK_UP_MOUSE: c_int = 38;
pub const BIND_ACTION_SCROLLBACK_UP_PAGE: c_int = 2;
pub const BIND_ACTION_SEARCH_CANCEL: c_int = 9;
pub const BIND_ACTION_SEARCH_CLIPBOARD_PASTE: c_int = 33;
pub const BIND_ACTION_SEARCH_COMMIT: c_int = 10;
pub const BIND_ACTION_SEARCH_COUNT: c_int = 36;
pub const BIND_ACTION_SEARCH_DELETE_NEXT: c_int = 21;
pub const BIND_ACTION_SEARCH_DELETE_NEXT_WORD: c_int = 22;
pub const BIND_ACTION_SEARCH_DELETE_PREV: c_int = 19;
pub const BIND_ACTION_SEARCH_DELETE_PREV_WORD: c_int = 20;
pub const BIND_ACTION_SEARCH_DELETE_TO_END: c_int = 24;
pub const BIND_ACTION_SEARCH_DELETE_TO_START: c_int = 23;
pub const BIND_ACTION_SEARCH_EDIT_END: c_int = 18;
pub const BIND_ACTION_SEARCH_EDIT_HOME: c_int = 17;
pub const BIND_ACTION_SEARCH_EDIT_LEFT: c_int = 13;
pub const BIND_ACTION_SEARCH_EDIT_LEFT_WORD: c_int = 14;
pub const BIND_ACTION_SEARCH_EDIT_RIGHT: c_int = 15;
pub const BIND_ACTION_SEARCH_EDIT_RIGHT_WORD: c_int = 16;
pub const BIND_ACTION_SEARCH_EXTEND_BACKWARD_CHAR: c_int = 29;
pub const BIND_ACTION_SEARCH_EXTEND_BACKWARD_WORD: c_int = 30;
pub const BIND_ACTION_SEARCH_EXTEND_BACKWARD_WORD_WS: c_int = 31;
pub const BIND_ACTION_SEARCH_EXTEND_CHAR: c_int = 25;
pub const BIND_ACTION_SEARCH_EXTEND_LINE_DOWN: c_int = 28;
pub const BIND_ACTION_SEARCH_EXTEND_LINE_UP: c_int = 32;
pub const BIND_ACTION_SEARCH_EXTEND_WORD: c_int = 26;
pub const BIND_ACTION_SEARCH_EXTEND_WORD_WS: c_int = 27;
pub const BIND_ACTION_SEARCH_FIND_NEXT: c_int = 12;
pub const BIND_ACTION_SEARCH_FIND_PREV: c_int = 11;
pub const BIND_ACTION_SEARCH_NONE: c_int = 0;
pub const BIND_ACTION_SEARCH_PRIMARY_PASTE: c_int = 34;
pub const BIND_ACTION_SEARCH_SCROLLBACK_DOWN_HALF_PAGE: c_int = 5;
pub const BIND_ACTION_SEARCH_SCROLLBACK_DOWN_LINE: c_int = 6;
pub const BIND_ACTION_SEARCH_SCROLLBACK_DOWN_PAGE: c_int = 4;
pub const BIND_ACTION_SEARCH_SCROLLBACK_END: c_int = 8;
pub const BIND_ACTION_SEARCH_SCROLLBACK_HOME: c_int = 7;
pub const BIND_ACTION_SEARCH_SCROLLBACK_UP_HALF_PAGE: c_int = 2;
pub const BIND_ACTION_SEARCH_SCROLLBACK_UP_LINE: c_int = 3;
pub const BIND_ACTION_SEARCH_SCROLLBACK_UP_PAGE: c_int = 1;
pub const BIND_ACTION_SEARCH_START: c_int = 13;
pub const BIND_ACTION_SEARCH_UNICODE_INPUT: c_int = 35;
pub const BIND_ACTION_SELECT_BEGIN: c_int = 40;
pub const BIND_ACTION_SELECT_BEGIN_BLOCK: c_int = 41;
pub const BIND_ACTION_SELECT_EXTEND: c_int = 42;
pub const BIND_ACTION_SELECT_EXTEND_CHAR_WISE: c_int = 43;
pub const BIND_ACTION_SELECT_QUOTE: c_int = 46;
pub const BIND_ACTION_SELECT_ROW: c_int = 47;
pub const BIND_ACTION_SELECT_WORD: c_int = 44;
pub const BIND_ACTION_SELECT_WORD_WS: c_int = 45;
pub const BIND_ACTION_SHOW_URLS_COPY: c_int = 25;
pub const BIND_ACTION_SHOW_URLS_LAUNCH: c_int = 26;
pub const BIND_ACTION_SHOW_URLS_PERSISTENT: c_int = 27;
pub const BIND_ACTION_SPAWN_TERMINAL: c_int = 17;
pub const BIND_ACTION_TEXT_BINDING: c_int = 28;
pub const BIND_ACTION_THEME_SWITCH_DARK: c_int = 35;
pub const BIND_ACTION_THEME_SWITCH_LIGHT: c_int = 36;
pub const BIND_ACTION_THEME_TOGGLE: c_int = 37;
pub const BIND_ACTION_UNICODE_INPUT: c_int = 31;
pub const BIND_ACTION_URL_CANCEL: c_int = 1;
pub const BIND_ACTION_URL_COUNT: c_int = 3;
pub const BIND_ACTION_URL_NONE: c_int = 0;
pub const BIND_ACTION_URL_TOGGLE_URL_ON_JUMP_LABEL: c_int = 2;

// terminal.h's two small enums, transcribed in declaration order (the
// generator that produces the rest needs their names from this header).
pub const SELECTION_NONE: c_int = 0;
pub const SELECTION_CHAR_WISE: c_int = 1;
pub const SELECTION_WORD_WISE: c_int = 2;
pub const SELECTION_QUOTE_WISE: c_int = 3;
pub const SELECTION_LINE_WISE: c_int = 4;
pub const SELECTION_BLOCK: c_int = 5;

pub const URL_ACTION_COPY: c_int = 0;
pub const URL_ACTION_LAUNCH: c_int = 1;
pub const URL_ACTION_PERSISTENT: c_int = 2;
