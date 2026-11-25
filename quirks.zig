//! Port of quirks.c.
//!
//! On weston (8.0), synchronized subsurfaces aren't updated correctly: they
//! appear to render once, but after that updates are sporadic. Adding explicit
//! parent surface commits right after the subsurface commit doesn't help (and
//! would be useless anyway, since it would defeat the purpose of having the
//! subsurface synchronized in the first place). The workaround is to put the
//! CSD subsurfaces in desync mode while they are being updated.
//!
//! Everything that touches `struct wl_window` or wayland-client's static
//! inline request wrappers goes through terminal-shim.c until Track B mirrors
//! those structs.

const types = @import("terminal_types.zig");

const LOG_CLASS_WARNING: c_int = 2;

extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

extern fn quirk_shim_subsurface_set_desync(sub: *anyopaque) void;
extern fn quirk_shim_subsurface_set_sync(sub: *anyopaque) void;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;

var is_weston_state: bool = false;
var is_weston_initialized: bool = false;

fn isWeston() bool {
    if (!is_weston_initialized) {
        is_weston_initialized = true;
        is_weston_state = getenv("WESTON_CONFIG_FILE") != null;

        if (is_weston_state) {
            log_msg(
                LOG_CLASS_WARNING,
                "quirks",
                "quirks.zig",
                @intCast(@src().line),
                "applying wl_subsurface_set_desync() workaround for weston",
            );
        }
    }

    return is_weston_state;
}

export fn quirk_weston_subsurface_desync_on(sub: ?*anyopaque) callconv(.c) void {
    if (!isWeston())
        return;

    quirk_shim_subsurface_set_desync(sub orelse return);
}

export fn quirk_weston_subsurface_desync_off(sub: ?*anyopaque) callconv(.c) void {
    if (!isWeston())
        return;

    quirk_shim_subsurface_set_sync(sub orelse return);
}

/// The CSD subsurfaces the workaround walks. Returns null when the window is
/// missing (the headless harness runs without one), which is also the case
/// where the quirk must stay inert.
fn csdSurfaces(term: *types.Terminal) ?[]types.WaylSubSurface {
    const win = term.window orelse return null;
    return &win.csd.surface;
}

export fn quirk_weston_csd_on(term: *types.Terminal) callconv(.c) void {
    const win = term.window orelse return;
    if (win.csd_mode != .yes)
        return;
    if (win.is_fullscreen)
        return;

    for (csdSurfaces(term) orelse return) |*surf|
        quirk_weston_subsurface_desync_on(surf.sub);
}

export fn quirk_weston_csd_off(term: *types.Terminal) callconv(.c) void {
    const win = term.window orelse return;
    if (win.csd_mode != .yes)
        return;
    if (win.is_fullscreen)
        return;

    for (csdSurfaces(term) orelse return) |*surf|
        quirk_weston_subsurface_desync_off(surf.sub);
}
