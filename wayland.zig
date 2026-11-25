//! Zig port of wayland.c, started with the monitor/output layer (D2a).
//!
//! The listener tables stay in wayland.c for now: they are generated-protocol
//! types, so C is the cheaper place to pin their layout. The callbacks they
//! point at live here.

const std = @import("std");
const types = @import("terminal_types.zig");

const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_DEBUG: c_int = 4;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

// wayland-client: WL_OUTPUT_MODE_CURRENT
const WL_OUTPUT_MODE_CURRENT: u32 = 0x1;

fn freeString(p: ?[*:0]u8) void {
    free(@as(?*anyopaque, @ptrCast(p)));
}

fn strdupOrNull(s: [*c]const u8) ?[*:0]u8 {
    if (s == null)
        return null;
    return xstrdup(@ptrCast(s));
}

// ─────────────────────────────────────────────────────────────────────────
// Physical/logical DPI
// ─────────────────────────────────────────────────────────────────────────

fn outputUpdatePpi(mon: *types.Monitor) void {
    if (mon.dim.mm.width <= 0 or mon.dim.mm.height <= 0)
        return;

    var x_inches: f64 = @as(f64, @floatFromInt(mon.dim.mm.width)) * 0.03937008;
    var y_inches: f64 = @as(f64, @floatFromInt(mon.dim.mm.height)) * 0.03937008;

    const width: c_int = mon.dim.px_real.width;
    const height: c_int = mon.dim.px_real.height;

    mon.ppi.real.x = @intFromFloat(@as(f64, @floatFromInt(mon.dim.px_real.width)) / x_inches);
    mon.ppi.real.y = @intFromFloat(@as(f64, @floatFromInt(mon.dim.px_real.height)) / y_inches);

    // The *logical* size is affected by the transform
    switch (mon.transform) {
        .rot_90, .rot_270, .flipped_90, .flipped_270 => {
            const swap = x_inches;
            x_inches = y_inches;
            y_inches = swap;
        },

        .normal, .rot_180, .flipped, .flipped_180 => {},
    }

    const scaled_width: c_int = mon.dim.px_scaled.width;
    const scaled_height: c_int = mon.dim.px_scaled.height;

    mon.ppi.scaled.x = @intFromFloat(@as(f64, @floatFromInt(scaled_width)) / x_inches);
    mon.ppi.scaled.y = @intFromFloat(@as(f64, @floatFromInt(scaled_height)) / y_inches);

    const w_f: f64 = @floatFromInt(width);
    const h_f: f64 = @floatFromInt(height);
    const px_diag_physical = @sqrt(w_f * w_f + h_f * h_f);
    mon.dpi.physical = if (width == 0 and height == 0)
        96.0
    else
        @floatCast(px_diag_physical / @as(f64, mon.inch));

    const sw_f: f64 = @floatFromInt(scaled_width);
    const sh_f: f64 = @floatFromInt(scaled_height);
    const px_diag_scaled = @sqrt(sw_f * sw_f + sh_f * sh_f);
    mon.dpi.scaled = if (scaled_width == 0 and scaled_height == 0)
        96.0
    else
        @floatCast(px_diag_scaled / @as(f64, mon.inch) * @as(f64, @floatFromInt(mon.scale)));

    if (mon.dpi.physical > 1000) {
        if (mon.name) |name|
            log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "%s: DPI=%f (physical) is unreasonable, using 96 instead", name, @as(f64, mon.dpi.physical));
        mon.dpi.physical = 96.0;
    }

    if (mon.dpi.scaled > 1000) {
        if (mon.name) |name|
            log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "%s: DPI=%f (logical) is unreasonable, using 96 instead", name, @as(f64, mon.dpi.scaled));
        mon.dpi.scaled = 96.0;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// wl_output listener
// ─────────────────────────────────────────────────────────────────────────

export fn output_geometry(
    data: ?*anyopaque,
    wl_output: ?*anyopaque,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: c_int,
    make: [*c]const u8,
    model: [*c]const u8,
    transform: c_int,
) callconv(.c) void {
    _ = wl_output;
    _ = x;
    _ = y;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));

    freeString(mon.make);
    freeString(mon.model);

    mon.dim.mm.width = physical_width;
    mon.dim.mm.height = physical_height;
    const mw: f64 = @floatFromInt(mon.dim.mm.width);
    const mh: f64 = @floatFromInt(mon.dim.mm.height);
    mon.inch = @floatCast(@sqrt(mw * mw + mh * mh) * 0.03937008);
    mon.make = strdupOrNull(make);
    mon.model = strdupOrNull(model);
    mon.subpixel = @enumFromInt(subpixel);
    mon.transform = @enumFromInt(transform);

    outputUpdatePpi(mon);
}

export fn output_mode(
    data: ?*anyopaque,
    wl_output: ?*anyopaque,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = wl_output;
    if ((flags & WL_OUTPUT_MODE_CURRENT) == 0)
        return;

    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    mon.refresh = @as(f32, @floatFromInt(refresh)) / 1000.0;
    mon.dim.px_real.width = width;
    mon.dim.px_real.height = height;
    outputUpdatePpi(mon);
}

export fn output_scale(data: ?*anyopaque, wl_output: ?*anyopaque, factor: i32) callconv(.c) void {
    _ = wl_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    mon.scale = factor;
    outputUpdatePpi(mon);
}

export fn output_name(data: ?*anyopaque, wl_output: ?*anyopaque, name: [*c]const u8) callconv(.c) void {
    _ = wl_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    freeString(mon.name);
    mon.name = strdupOrNull(name);
}

export fn output_description(data: ?*anyopaque, wl_output: ?*anyopaque, description: [*c]const u8) callconv(.c) void {
    _ = wl_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    freeString(mon.description);
    mon.description = strdupOrNull(description);
}

// ─────────────────────────────────────────────────────────────────────────
// zxdg_output_v1 listener
// ─────────────────────────────────────────────────────────────────────────

export fn xdg_output_handle_logical_position(
    data: ?*anyopaque,
    xdg_output: ?*anyopaque,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = xdg_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    mon.x = x;
    mon.y = y;
}

export fn xdg_output_handle_logical_size(
    data: ?*anyopaque,
    xdg_output: ?*anyopaque,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = xdg_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    mon.dim.px_scaled.width = width;
    mon.dim.px_scaled.height = height;
    outputUpdatePpi(mon);
}

export fn xdg_output_handle_name(
    data: ?*anyopaque,
    xdg_output: ?*anyopaque,
    name: [*c]const u8,
) callconv(.c) void {
    _ = xdg_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    freeString(mon.name);
    mon.name = strdupOrNull(name);
}

export fn xdg_output_handle_description(
    data: ?*anyopaque,
    xdg_output: ?*anyopaque,
    description: [*c]const u8,
) callconv(.c) void {
    _ = xdg_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    freeString(mon.description);
    mon.description = strdupOrNull(description);
}

// ─────────────────────────────────────────────────────────────────────────
// wp_presentation listener
// ─────────────────────────────────────────────────────────────────────────

export fn clock_id(data: ?*anyopaque, wp_presentation: ?*anyopaque, clk_id: u32) callconv(.c) void {
    _ = wp_presentation;
    const wayl: *types.Wayland = @ptrCast(@alignCast(data.?));
    wayl.presentation_clock_id = clk_id;
    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "presentation clock ID: %u", clk_id);
}

// ─────────────────────────────────────────────────────────────────────────
// Surface scaling
// ─────────────────────────────────────────────────────────────────────────

extern fn term_fractional_scaling(term: *const types.Terminal) callconv(.c) bool;
extern fn term_preferred_buffer_scale(term: *const types.Terminal) callconv(.c) bool;
// Generated-protocol static inlines, wrapped in terminal-shim.c.
extern fn wayland_shim_surface_set_buffer_scale(surf: ?*anyopaque, scale: i32) callconv(.c) void;
extern fn wayland_shim_viewport_set_destination(viewport: ?*anyopaque, width: i32, height: i32) callconv(.c) void;
extern fn bug(
    file: [*:0]const u8,
    line: c_int,
    func: [*:0]const u8,
    fmt: [*:0]const u8,
    ...
) callconv(.c) noreturn;

fn surfaceScaleExplicitWidthHeight(
    win: *const types.WlWindow,
    surf: *const types.WaylSurface,
    width: c_int,
    height: c_int,
    scale: f32,
    verify: bool,
) void {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    if (term_fractional_scaling(term)) {
        log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "scaling by a factor of %.2f using fractional scaling (width=%d, height=%d) ", scale, width, height);

        if (verify) {
            const w2: c_int = @intFromFloat(@round(scale * @round(@as(f32, @floatFromInt(width)) / scale)));
            if (w2 != width)
                bug(@src().file, @intCast(@src().line), "surface_scale_explicit_width_height", "width=%d is not valid with scaling factor %.2f (%d != %d)", width, scale, w2, width);

            const h2: c_int = @intFromFloat(@round(scale * @round(@as(f32, @floatFromInt(height)) / scale)));
            if (h2 != height)
                bug(@src().file, @intCast(@src().line), "surface_scale_explicit_width_height", "height=%d is not valid with scaling factor %.2f (%d != %d)", height, scale, h2, height);
        }

        std.debug.assert(surf.viewport != null);
        wayland_shim_surface_set_buffer_scale(surf.surf, 1);
        wayland_shim_viewport_set_destination(
            surf.viewport,
            @intFromFloat(@round(@as(f32, @floatFromInt(width)) / scale)),
            @intFromFloat(@round(@as(f32, @floatFromInt(height)) / scale)),
        );
    } else {
        const mode: [*:0]const u8 = if (term_preferred_buffer_scale(term))
            "wl_surface.preferred_buffer_scale"
        else
            "legacy mode";
        log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "scaling by a factor of %.2f using %s (width=%d, height=%d)", scale, mode, width, height);

        std.debug.assert(scale == @floor(scale));
        const iscale: c_int = @intFromFloat(@floor(scale));

        if (verify) {
            if (@mod(width, iscale) != 0)
                bug(@src().file, @intCast(@src().line), "surface_scale_explicit_width_height", "width=%d is not valid with scaling factor %.2f (%d %% %d != 0)", width, scale, width, iscale);

            if (@mod(height, iscale) != 0)
                bug(@src().file, @intCast(@src().line), "surface_scale_explicit_width_height", "height=%d is not valid with scaling factor %.2f (%d %% %d != 0)", height, scale, height, iscale);
        }

        wayland_shim_surface_set_buffer_scale(surf.surf, iscale);
    }
}

export fn wayl_surface_scale_explicit_width_height(
    win: *const types.WlWindow,
    surf: *const types.WaylSurface,
    width: c_int,
    height: c_int,
    scale: f32,
) callconv(.c) void {
    surfaceScaleExplicitWidthHeight(win, surf, width, height, scale, false);
}

export fn wayl_surface_scale(
    win: *const types.WlWindow,
    surf: *const types.WaylSurface,
    buf: *const types.Buffer,
    scale: f32,
) callconv(.c) void {
    surfaceScaleExplicitWidthHeight(win, surf, buf.width, buf.height, scale, true);
}

export fn wayl_win_scale(win: *types.WlWindow, buf: *const types.Buffer) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    wayl_surface_scale(win, &win.surface, buf, term.scale);
}

// ─────────────────────────────────────────────────────────────────────────
// CSD visibility
// ─────────────────────────────────────────────────────────────────────────

export fn wayl_win_csd_titlebar_visible(win: *const types.WlWindow) callconv(.c) bool {
    return win.csd_mode == .yes and
        !win.is_fullscreen and
        !(win.is_maximized and blk: {
        const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
        break :blk term.conf.?.csd.hide_when_maximized;
    });
}

export fn wayl_win_csd_borders_visible(win: *const types.WlWindow) callconv(.c) bool {
    return win.csd_mode == .yes and
        !win.is_fullscreen and
        !win.is_maximized;
}

// ─────────────────────────────────────────────────────────────────────────
// Urgency, activation and the system bell
// ─────────────────────────────────────────────────────────────────────────

extern fn wayl_get_activation_token(
    wayl: *types.Wayland,
    seat: ?*types.Seat,
    serial: u32,
    win: *types.WlWindow,
    cb: types.ActivationTokenCb,
    cb_data: ?*anyopaque,
) callconv(.c) bool;
extern fn wayland_shim_xdg_system_bell_ring(bell: ?*anyopaque, surface: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_xdg_activation_activate(activation: ?*anyopaque, token: [*:0]const u8, surface: ?*anyopaque) callconv(.c) void;

fn waylandOf(win: anytype) *types.Wayland {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    return @ptrCast(@alignCast(term.wl.?));
}

fn activationTokenForUrgencyDone(token: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const wayl = waylandOf(win);

    win.urgency_token_is_pending = false;
    wayland_shim_xdg_activation_activate(wayl.xdg_activation, token, win.surface.surf);
}

export fn wayl_win_set_urgent(win: *types.WlWindow) callconv(.c) bool {
    if (win.urgency_token_is_pending) {
        // We already have a pending token. Don't request another one,
        // to avoid flooding the Wayland socket
        return true;
    }

    const success = wayl_get_activation_token(
        waylandOf(win),
        null,
        0,
        win,
        &activationTokenForUrgencyDone,
        win,
    );

    if (success) {
        win.urgency_token_is_pending = true;
        return true;
    }

    return false;
}

export fn wayl_win_ring_bell(win: *const types.WlWindow) callconv(.c) bool {
    const wayl = waylandOf(win);

    if (wayl.system_bell == null) {
        const S = struct {
            var have_warned: bool = false;
        };

        if (!S.have_warned) {
            log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement the XDG system bell protocol");
            S.have_warned = true;
        }

        return false;
    }

    wayland_shim_xdg_system_bell_ring(wayl.system_bell, win.surface.surf);
    return true;
}

export fn wayl_do_linear_blending(wayl: *const types.Wayland, conf: *const types.Config) callconv(.c) bool {
    return conf.gamma_correct and wayl.color_management.img_description != null;
}

// ─────────────────────────────────────────────────────────────────────────
// Window surfaces
//
// wl_surface/wl_subsurface/wl_region/wp_viewport are almost entirely static
// inline wrappers in the generated headers, so each entry point has a
// wayland_shim_* forwarder in terminal-shim.c.
// ─────────────────────────────────────────────────────────────────────────

const WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL: u32 = 0;

extern fn wayland_shim_compositor_create_surface(compositor: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_compositor_create_region(compositor: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_subcompositor_get_subsurface(
    subcompositor: ?*anyopaque,
    surface: ?*anyopaque,
    parent: ?*anyopaque,
) callconv(.c) ?*anyopaque;
extern fn wayland_shim_viewporter_get_viewport(viewporter: ?*anyopaque, surface: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_color_manager_get_surface(manager: ?*anyopaque, surface: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_color_management_set_image_description(cm_surface: ?*anyopaque, img: ?*anyopaque, intent: u32) callconv(.c) void;
extern fn wayland_shim_color_management_surface_destroy(cm_surface: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_surface_destroy(surf: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_surface_set_user_data(surf: ?*anyopaque, data: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_surface_set_input_region(surf: ?*anyopaque, region: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_region_destroy(region: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_subsurface_destroy(sub: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_viewport_destroy(viewport: ?*anyopaque) callconv(.c) void;
extern fn quirk_shim_subsurface_set_sync(sub: ?*anyopaque) callconv(.c) void;

const LOG_CLASS_ERROR: c_int = 1;

export fn wayl_win_subsurface_new_with_custom_parent(
    win: *types.WlWindow,
    parent: ?*anyopaque,
    surf: *types.WaylSubSurface,
    allow_pointer_input: bool,
) callconv(.c) bool {
    const wayl = waylandOf(win);
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    surf.surface.surf = null;
    surf.surface.viewport = null;
    surf.sub = null;

    const main_surface = wayland_shim_compositor_create_surface(wayl.compositor);

    if (main_surface == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to instantiate surface for sub-surface");
        return false;
    }

    surf.surface.color_management = null;
    if (term.conf.?.gamma_correct and wayl.color_management.img_description != null) {
        std.debug.assert(wayl.color_management.manager != null);

        surf.surface.color_management = wayland_shim_color_manager_get_surface(
            wayl.color_management.manager,
            main_surface,
        );

        wayland_shim_color_management_set_image_description(
            surf.surface.color_management,
            wayl.color_management.img_description,
            WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL,
        );
    }

    const sub = wayland_shim_subcompositor_get_subsurface(
        wayl.sub_compositor,
        main_surface,
        parent,
    );

    if (sub == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to instantiate sub-surface");
        wayland_shim_surface_destroy(main_surface);
        return false;
    }

    var viewport: ?*anyopaque = null;
    if (wayl.viewporter != null) {
        viewport = wayland_shim_viewporter_get_viewport(wayl.viewporter, main_surface);
        if (viewport == null) {
            log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to instantiate viewport for sub-surface");
            wayland_shim_subsurface_destroy(sub);
            wayland_shim_surface_destroy(main_surface);
            return false;
        }
    }

    wayland_shim_surface_set_user_data(main_surface, win);
    quirk_shim_subsurface_set_sync(sub);

    // Disable pointer and touch events
    if (!allow_pointer_input) {
        const empty = wayland_shim_compositor_create_region(wayl.compositor);
        wayland_shim_surface_set_input_region(main_surface, empty);
        wayland_shim_region_destroy(empty);
    }

    surf.surface.surf = main_surface;
    surf.sub = sub;
    surf.surface.viewport = viewport;
    return true;
}

export fn wayl_win_subsurface_new(
    win: *types.WlWindow,
    surf: *types.WaylSubSurface,
    allow_pointer_input: bool,
) callconv(.c) bool {
    return wayl_win_subsurface_new_with_custom_parent(win, win.surface.surf, surf, allow_pointer_input);
}

export fn wayl_win_subsurface_destroy(surf_in: ?*types.WaylSubSurface) callconv(.c) void {
    const surf = surf_in orelse return;

    if (surf.surface.color_management != null) {
        wayland_shim_color_management_surface_destroy(surf.surface.color_management);
        surf.surface.color_management = null;
    }

    if (surf.surface.viewport != null) {
        wayland_shim_viewport_destroy(surf.surface.viewport);
        surf.surface.viewport = null;
    }

    if (surf.sub != null) {
        wayland_shim_subsurface_destroy(surf.sub);
        surf.sub = null;
    }

    if (surf.surface.surf != null) {
        wayland_shim_surface_destroy(surf.surface.surf);
        surf.surface.surf = null;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Display flush / roundtrip
// ─────────────────────────────────────────────────────────────────────────

extern fn wl_display_flush(display: ?*anyopaque) callconv(.c) c_int;
extern fn wl_display_read_events(display: ?*anyopaque) callconv(.c) c_int;
extern fn wl_display_dispatch_pending(display: ?*anyopaque) callconv(.c) c_int;
extern fn wl_display_cancel_read(display: ?*anyopaque) callconv(.c) void;
extern fn wl_display_roundtrip(display: ?*anyopaque) callconv(.c) c_int;
extern fn wl_display_prepare_read(display: ?*anyopaque) callconv(.c) c_int;
extern fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) callconv(.c) c_int;
extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn log_errno_provided(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    errnum: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn __errno_location() callconv(.c) *c_int;

const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const EPIPE: c_int = 32;
const POLLOUT: c_short = 0x4;
const POLLHUP: c_short = 0x10;

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

fn errno() *c_int {
    return __errno_location();
}

export fn wayl_flush(wayl: *types.Wayland) callconv(.c) void {
    while (true) {
        const r = wl_display_flush(wayl.display);
        if (r >= 0) {
            // Most likely code path - the flush succeed
            return;
        }

        if (errno().* == EINTR) {
            // Unlikely
            continue;
        }

        if (errno().* != EAGAIN) {
            const saved_errno = errno().*;

            if (errno().* == EPIPE) {
                _ = wl_display_read_events(wayl.display);
                _ = wl_display_dispatch_pending(wayl.display);
            }

            log_errno_provided(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), saved_errno, "failed to flush wayland socket");
            return;
        }

        // Socket buffer is full - need to wait for it to become
        // writeable again
        std.debug.assert(errno().* == EAGAIN);

        while (true) {
            var fds = [_]PollFd{.{ .fd = wayl.fd, .events = POLLOUT, .revents = 0 }};

            const r2 = poll(&fds, fds.len, -1);

            if (r2 < 0) {
                if (errno().* == EINTR)
                    continue;

                log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to poll");
                return;
            }

            if (fds[0].revents & POLLHUP != 0)
                return;

            std.debug.assert(fds[0].revents & POLLOUT != 0);
            break;
        }
    }
}

export fn wayl_roundtrip(wayl: *types.Wayland) callconv(.c) void {
    wl_display_cancel_read(wayl.display);
    if (wl_display_roundtrip(wayl.display) < 0) {
        log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to roundtrip Wayland display");
        return;
    }

    // I suspect the roundtrip above clears the pending queue, and
    // that prepare_read() will always succeed in the first call. But,
    // better safe than sorry...

    while (wl_display_prepare_read(wayl.display) != 0) {
        if (wl_display_dispatch_pending(wayl.display) < 0) {
            log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to dispatch pending Wayland events");
            return;
        }
    }
    wayl_flush(wayl);
}

// ─────────────────────────────────────────────────────────────────────────
// Client-side cursor theme
// ─────────────────────────────────────────────────────────────────────────

extern fn wl_cursor_theme_load(name: ?[*:0]const u8, size: c_int, shm: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wl_cursor_theme_destroy(theme: ?*anyopaque) callconv(.c) void;
extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn strtol(nptr: [*:0]const u8, endptr: *?[*:0]u8, base: c_int) callconv(.c) c_long;

const LOG_CLASS_INFO: c_int = 3;

export fn wayl_reload_xcursor_theme(seat: *types.Seat, new_scale: f32) callconv(.c) bool {
    if (seat.pointer.theme != null and seat.pointer.scale == new_scale) {
        // We already have a theme loaded, and the scale hasn't changed
        return true;
    }

    if (seat.pointer.theme != null) {
        std.debug.assert(seat.pointer.scale != new_scale);
        wl_cursor_theme_destroy(seat.pointer.theme);
        seat.pointer.theme = null;
        seat.pointer.cursor = null;
    }

    if (seat.pointer.shape_device != null) {
        // Using server side cursors
        return true;
    }

    var xcursor_size: c_int = 24;

    {
        const env_cursor_size = getenv("XCURSOR_SIZE");
        if (env_cursor_size) |size_str| {
            errno().* = 0;
            var end: ?[*:0]u8 = null;
            const size = strtol(size_str, &end, 10);

            if (errno().* == 0 and end != null and end.?[0] == 0 and size > 0)
                xcursor_size = @intCast(size)
            else
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "XCURSOR_SIZE '%s' is invalid, defaulting to 24", size_str);
        }
    }

    const xcursor_theme = getenv("XCURSOR_THEME");

    log_msg(
        LOG_CLASS_INFO,
        "wayland",
        "wayland.zig",
        @intCast(@src().line),
        "cursor theme: %s, size: %d, scale: %.2f",
        if (xcursor_theme) |t| t else @as([*:0]const u8, "(null)"),
        xcursor_size,
        new_scale,
    );

    const seat_wayl: *types.Wayland = @ptrCast(@alignCast(seat.wayl.?));
    seat.pointer.theme = wl_cursor_theme_load(
        xcursor_theme,
        @intFromFloat(@as(f32, @floatFromInt(xcursor_size)) * new_scale),
        seat_wayl.shm,
    );

    if (seat.pointer.theme == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to load cursor theme");
        return false;
    }

    seat.pointer.scale = new_scale;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────
// Client-side decorations
// ─────────────────────────────────────────────────────────────────────────

extern fn fcft_destroy(font: ?*anyopaque) callconv(.c) void;
extern fn fcft_from_name(count: usize, names: [*]const [*:0]const u8, attributes: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn shm_purge(chain: ?*anyopaque) callconv(.c) void;

fn csdReloadFont(win: *types.WlWindow, old_scale: f32) void {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    const conf = term.conf.?;

    const scale = term.scale;

    const enable_csd = win.csd_mode == .yes and !win.is_fullscreen;
    if (!enable_csd)
        return;
    if (win.csd.font != null and scale == old_scale)
        return;

    fcft_destroy(win.csd.font);

    var patterns_buf: [64][*:0]const u8 = undefined;
    std.debug.assert(conf.csd.font.count <= patterns_buf.len);
    const patterns = patterns_buf[0..conf.csd.font.count];
    for (0..conf.csd.font.count) |i|
        patterns[i] = conf.csd.font.arr.?[i].pattern.?;

    var pixelsize: [32]u8 = undefined;
    const px: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(conf.csd.title_height)) * scale));
    _ = snprintf(&pixelsize, pixelsize.len, "pixelsize=%u", @as(c_uint, @intCast(px)));

    log_msg(
        LOG_CLASS_DEBUG,
        "wayland",
        "wayland.zig",
        @intCast(@src().line),
        "loading CSD font \"%s:%s\" (old-scale=%.2f, scale=%.2f)",
        patterns[0],
        @as([*:0]const u8, @ptrCast(&pixelsize)),
        old_scale,
        scale,
    );

    win.csd.font = fcft_from_name(conf.csd.font.count, patterns.ptr, @ptrCast(&pixelsize));
}

export fn csd_instantiate(win: *types.WlWindow) callconv(.c) void {
    const wayl = waylandOf(win);
    std.debug.assert(@intFromPtr(wayl) != 0);

    const minimize: usize = @intFromEnum(types.CsdSurface.minimize);
    var i: usize = 0;
    while (i < minimize) : (i += 1) {
        const ret = wayl_win_subsurface_new(win, &win.csd.surface[i], true);
        if (!ret) bug(@src().file, @intCast(@src().line), "csd_instantiate", "assertion failed");
    }

    while (i < types.CSD_SURF_COUNT) : (i += 1) {
        const ret = wayl_win_subsurface_new_with_custom_parent(
            win,
            win.csd.surface[@intFromEnum(types.CsdSurface.title)].surface.surf,
            &win.csd.surface[i],
            true,
        );
        if (!ret) bug(@src().file, @intCast(@src().line), "csd_instantiate", "assertion failed");
    }

    csdReloadFont(win, -1.0);
}

export fn csd_destroy(win: *types.WlWindow) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    const window = term.window.?;
    fcft_destroy(window.csd.font);
    window.csd.font = null;

    for (&win.csd.surface) |*surface|
        wayl_win_subsurface_destroy(surface);
    shm_purge(term.render.chains.csd);
}

export fn csd_reload_font(win: *types.WlWindow, old_scale: f32) callconv(.c) void {
    csdReloadFont(win, old_scale);
}
