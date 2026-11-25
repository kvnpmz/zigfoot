//! Zig port of input.c, started with the keyboard device setup (D4a):
//! keymap installation, keyboard enter/leave and the key-repeat timer.
//!
//! The protocol listeners themselves stay in input.c for now (they are
//! generated-struct layouts); everything they call is either here or in
//! terminal.zig.

const std = @import("std");
const types = @import("terminal_types.zig");

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
