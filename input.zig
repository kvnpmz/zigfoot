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
