//! Zig port of wayland.c, started with the monitor/output layer (D2a).
//!
//! The listener tables stay in wayland.c for now: they are generated-protocol
//! types, so C is the cheaper place to pin their layout. The callbacks they
//! point at live here.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

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

// ─────────────────────────────────────────────────────────────────────────
// Monitor lifecycle / output changes
// ─────────────────────────────────────────────────────────────────────────

extern fn wayland_shim_zxdg_output_destroy(xdg: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_wl_output_release(output: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_wl_output_destroy(output: ?*anyopaque) callconv(.c) void;
extern fn term_update_scale(term: *types.Terminal) callconv(.c) bool;
extern fn term_font_dpi_changed(term: *types.Terminal, old_scale: f32) callconv(.c) bool;
extern fn term_font_subpixel_changed(term: *types.Terminal) callconv(.c) void;
extern fn render_resize(term: *types.Terminal, width: c_int, height: c_int, opts: c_int) callconv(.c) bool;

// render.h: enum resize_options
const RESIZE_KEEP_GRID: c_int = 0x0;
const RESIZE_FORCE: c_int = 0x1;

export fn monitor_destroy(mon: *types.Monitor) callconv(.c) void {
    if (mon.xdg != null)
        wayland_shim_zxdg_output_destroy(mon.xdg);
    if (mon.output != null) {
        if (mon.use_output_release)
            wayland_shim_wl_output_release(mon.output)
        else
            wayland_shim_wl_output_destroy(mon.output);
    }
    freeString(mon.make);
    freeString(mon.model);
    freeString(mon.name);
    freeString(mon.description);
}

fn updateTermForOutputChange(term: *types.Terminal) void {
    const old_scale = term.scale;
    const logical_width = @as(f32, @floatFromInt(term.width)) / old_scale;
    const logical_height = @as(f32, @floatFromInt(term.height)) / old_scale;

    // Note: order matters! term_update_scale() must come first
    const scale_updated = term_update_scale(term);
    const fonts_updated = term_font_dpi_changed(term, old_scale);
    term_font_subpixel_changed(term);

    csd_reload_font(term.window.?, old_scale);

    var resize_opts: c_int = RESIZE_KEEP_GRID;

    if (fonts_updated) {
        // If the fonts have been updated, the cell dimensions have
        // changed. This requires a "forced" resize, since the surface
        // buffer dimensions may not have been updated (in which case
        // render_resize() normally shortcuts and returns early).
        resize_opts |= RESIZE_FORCE;
    } else if (!scale_updated) {
        // No need to resize if neither scale nor fonts have changed
        return;
    } else if (term.conf.?.dpi_aware) {
        // If fonts are sized according to DPI, it is possible for the
        // cell size to remain the same when display scale changes. This
        // will not change the surface buffer dimensions, but will change
        // the logical size of the window, so force a resize.
        resize_opts |= RESIZE_FORCE;
    }

    _ = render_resize(
        term,
        @intFromFloat(@round(logical_width)),
        @intFromFloat(@round(logical_height)),
        resize_opts,
    );
}

fn updateTermsOnMonitor(mon: *types.Monitor) void {
    const wayl: *types.Wayland = @ptrCast(@alignCast(mon.wayl.?));

    // terminal_types.zig mirrors only the three-word tll head; the operating
    // list type (with iteration) is tll.zig's.
    const TerminalList = tll.Tll(?*anyopaque);
    const terms: *const TerminalList = @ptrCast(&wayl.terms);

    var it = (@constCast(terms)).foreach();
    while (it.next()) |node| {
        const term: *types.Terminal = @ptrCast(@alignCast(node.item.?));
        if (term.shutdown.in_progress)
            continue;

        const OutputList = tll.Tll(?*const types.Monitor);
        const outputs: *const OutputList = @ptrCast(&term.window.?.on_outputs);

        var it2 = (@constCast(outputs)).foreach();
        while (it2.next()) |node2| {
            if (node2.item == mon) {
                updateTermForOutputChange(term);
                break;
            }
        }
    }
}

export fn update_term_for_output_change(term: *types.Terminal) callconv(.c) void {
    updateTermForOutputChange(term);
}

export fn output_done(data: ?*anyopaque, wl_output: ?*anyopaque) callconv(.c) void {
    _ = wl_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    updateTermsOnMonitor(mon);
}

export fn xdg_output_handle_done(data: ?*anyopaque, xdg_output: ?*anyopaque) callconv(.c) void {
    _ = xdg_output;
    const mon: *types.Monitor = @ptrCast(@alignCast(data.?));
    updateTermsOnMonitor(mon);
}

// ─────────────────────────────────────────────────────────────────────────
// Window teardown
// ─────────────────────────────────────────────────────────────────────────

extern fn wayland_shim_surface_attach(surf: ?*anyopaque, buffer: ?*anyopaque, x: i32, y: i32) callconv(.c) void;
extern fn wayland_shim_surface_commit(surf: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_surface_get_user_data(surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_wl_callback_destroy(callback: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_xdg_surface_destroy(xdg_surface: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_xdg_toplevel_destroy(xdg_toplevel: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_xdg_toplevel_decoration_destroy(decoration: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_fractional_scale_destroy(scale: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_destroy_background_effect(effect: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_xdg_activation_token_destroy(token: ?*anyopaque) callconv(.c) void;
extern fn render_wait_for_preapply_damage(term: *types.Terminal) callconv(.c) void;
extern fn fdm_del(fdm: ?*anyopaque, fd: c_int) callconv(.c) bool;

const TOUCH_STATE_IDLE: c_int = 0;

extern fn close(fd: c_int) callconv(.c) c_int;

export fn wayl_win_destroy(win_in: ?*types.WlWindow) callconv(.c) void {
    const win = win_in orelse return;

    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    const wayl = waylandOf(win);

    if (win.csd.move_timeout_fd != -1)
        _ = close(win.csd.move_timeout_fd);

    // wl_touch has no leave event, so the unmapping below cannot drop touch
    // focus the way it drops keyboard and pointer focus. Reset it here, or a
    // wl_touch.up/motion dispatched from the roundtrips below runs against
    // this window after it has been destroyed.
    {
        const SeatList = tll.Tll(types.Seat);
        const seats: *const SeatList = @ptrCast(&wayl.seats);
        var it = (@constCast(seats)).foreach();
        while (it.next()) |node| {
            const seat = &node.item;

            if (seat.touch.surface != null and
                wayland_shim_surface_get_user_data(seat.touch.surface) == @as(?*anyopaque, win))
            {
                seat.touch.state = @enumFromInt(TOUCH_STATE_IDLE);
                seat.touch.surface = null;
            }
        }
    }

    // First, unmap all surfaces to trigger things like keyboard_leave() and
    // wl_pointer_leave(). This ensures we remove all references to *this*
    // window from the global wayland struct (since it no longer has neither
    // keyboard nor mouse focus).

    if (win.render_timer.surface.surf != null) {
        wayland_shim_surface_attach(win.render_timer.surface.surf, null, 0, 0);
        wayland_shim_surface_commit(win.render_timer.surface.surf);
    }

    if (win.scrollback_indicator.surface.surf != null) {
        wayland_shim_surface_attach(win.scrollback_indicator.surface.surf, null, 0, 0);
        wayland_shim_surface_commit(win.scrollback_indicator.surface.surf);
    }

    if (win.overlay.surface.surf != null) {
        wayland_shim_surface_attach(win.overlay.surface.surf, null, 0, 0);
        wayland_shim_surface_commit(win.overlay.surface.surf);
    }

    // Scrollback search
    if (win.search.surface.surf != null) {
        wayland_shim_surface_attach(win.search.surface.surf, null, 0, 0);
        wayland_shim_surface_commit(win.search.surface.surf);
    }

    // URLs
    {
        const UrlList = tll.Tll(types.WlUrl);
        const urls: *UrlList = @ptrCast(&win.urls);
        var it = (@constCast(urls)).foreach();
        while (it.next()) |node| {
            wayland_shim_surface_attach(node.item.surf.surface.surf, null, 0, 0);
            wayland_shim_surface_commit(node.item.surf.surface.surf);
        }
    }

    // CSD
    for (&win.csd.surface) |*surface| {
        if (surface.surface.surf != null) {
            wayland_shim_surface_attach(surface.surface.surf, null, 0, 0);
            wayland_shim_surface_commit(surface.surface.surf);
        }
    }

    wayl_roundtrip(wayl);

    // Main window
    win.unmapped = true;
    wayland_shim_surface_attach(win.surface.surf, null, 0, 0);
    wayland_shim_surface_commit(win.surface.surf);
    wayl_roundtrip(wayl);

    {
        const OutputList = tll.Tll(?*const types.Monitor);
        const outputs: *OutputList = @ptrCast(&win.on_outputs);
        outputs.freeList();
    }

    {
        const UrlList = tll.Tll(types.WlUrl);
        const urls: *UrlList = @ptrCast(&win.urls);
        var it = (@constCast(urls)).foreach();
        while (it.next()) |node| {
            wayl_win_subsurface_destroy(&node.item.surf);
            urls.removeNode(node);
        }
    }

    render_wait_for_preapply_damage(term);

    csd_destroy(win);
    wayl_win_subsurface_destroy(&win.search);
    wayl_win_subsurface_destroy(&win.scrollback_indicator);
    wayl_win_subsurface_destroy(&win.render_timer);
    wayl_win_subsurface_destroy(&win.overlay);

    shm_purge(term.render.chains.search);
    shm_purge(term.render.chains.scrollback_indicator);
    shm_purge(term.render.chains.render_timer);
    shm_purge(term.render.chains.grid);
    shm_purge(term.render.chains.url);
    shm_purge(term.render.chains.csd);

    {
        const TokenList = tll.Tll(?*types.XdgActivationTokenContext);
        const tokens: *TokenList = @ptrCast(&win.xdg_tokens);
        var it = (@constCast(tokens)).foreach();
        while (it.next()) |node| {
            wayland_shim_xdg_activation_token_destroy(node.item.?.xdg_token);
            free(@as(?*anyopaque, @ptrCast(node.item)));

            tokens.removeNode(node);
        }
    }

    if (win.surface.background_effect != null)
        wayland_shim_destroy_background_effect(win.surface.background_effect);

    if (win.surface.color_management != null)
        wayland_shim_color_management_surface_destroy(win.surface.color_management);
    if (win.fractional_scale != null)
        wayland_shim_fractional_scale_destroy(win.fractional_scale);
    if (win.surface.viewport != null)
        wayland_shim_viewport_destroy(win.surface.viewport);
    if (win.frame_callback != null)
        wayland_shim_wl_callback_destroy(win.frame_callback);
    if (win.xdg_toplevel_decoration != null)
        wayland_shim_xdg_toplevel_decoration_destroy(win.xdg_toplevel_decoration);
    if (win.xdg_toplevel != null)
        wayland_shim_xdg_toplevel_destroy(win.xdg_toplevel);
    if (win.xdg_surface != null)
        wayland_shim_xdg_surface_destroy(win.xdg_surface);
    if (win.surface.surf != null)
        wayland_shim_surface_destroy(win.surface.surf);

    wayl_roundtrip(waylandOf(win));

    if (win.resize_timeout_fd >= 0)
        _ = fdm_del(wayl.fdm, win.resize_timeout_fd);
    free(@as(?*anyopaque, @ptrCast(win)));
}

// ─────────────────────────────────────────────────────────────────────────
// Window creation
// ─────────────────────────────────────────────────────────────────────────

extern fn calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn wayland_shim_fractional_scale_get(m: ?*anyopaque, surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_background_effect_get(m: ?*anyopaque, surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_xdg_wm_base_get_xdg_surface(shell: ?*anyopaque, surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_xdg_surface_get_toplevel(xdg_surface: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_xdg_toplevel_set_app_id(toplevel: ?*anyopaque, app_id: [*:0]const u8) callconv(.c) void;
extern fn wayland_shim_toplevel_tag_set(m: ?*anyopaque, toplevel: ?*anyopaque, tag: [*:0]const u8) callconv(.c) void;
extern fn wayland_shim_toplevel_icon_set(m: ?*anyopaque, toplevel: ?*anyopaque, name: [*:0]const u8) callconv(.c) void;
extern fn wayland_shim_decoration_get(m: ?*anyopaque, toplevel: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_decoration_set_mode(decoration: ?*anyopaque, mode: u32) callconv(.c) void;
extern fn wayland_shim_add_surface_listener(surf: ?*anyopaque, win: *types.WlWindow) callconv(.c) void;
extern fn wayland_shim_add_fractional_scale_listener(scale: ?*anyopaque, win: *types.WlWindow) callconv(.c) void;
extern fn wayland_shim_add_xdg_surface_listener(xdg_surface: ?*anyopaque, win: *types.WlWindow) callconv(.c) void;
extern fn wayland_shim_add_xdg_toplevel_listener(toplevel: ?*anyopaque, win: *types.WlWindow) callconv(.c) void;
extern fn wayland_shim_add_decoration_listener(decoration: ?*anyopaque, win: *types.WlWindow) callconv(.c) void;

const ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE: u32 = 1;
const ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE: u32 = 2;

export fn wayl_win_init(term: *types.Terminal, token: [*c]const u8) callconv(.c) ?*types.WlWindow {
    const wayl = waylandOf2(term);
    const conf = term.conf.?;

    const win: *types.WlWindow = @ptrCast(@alignCast(calloc(1, @sizeOf(types.WlWindow)) orelse {
        log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "calloc() failed");
        return null;
    }));

    win.term = term;
    win.csd_mode = .unknown;
    win.csd.move_timeout_fd = -1;
    win.resize_timeout_fd = -1;
    win.scale = -1.0;

    win.wm_capabilities.maximize = true;
    win.wm_capabilities.minimize = true;

    win.surface.surf = wayland_shim_compositor_create_surface(wayl.compositor);
    if (win.surface.surf == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to create wayland surface");
        return winInitFail(win);
    }

    wayland_shim_add_surface_listener(win.surface.surf, win);

    if (wayl.fractional_scale_manager != null and wayl.viewporter != null) {
        win.surface.viewport = wayland_shim_viewporter_get_viewport(wayl.viewporter, win.surface.surf);

        win.fractional_scale = wayland_shim_fractional_scale_get(
            wayl.fractional_scale_manager,
            win.surface.surf,
        );
        wayland_shim_add_fractional_scale_listener(win.fractional_scale, win);
    }

    if (wayl.background_effect_manager != null) {
        win.surface.background_effect = wayland_shim_background_effect_get(
            wayl.background_effect_manager,
            win.surface.surf,
        );
    }

    wayl_win_alpha_changed(win);

    win.xdg_surface = wayland_shim_xdg_wm_base_get_xdg_surface(wayl.shell, win.surface.surf);
    wayland_shim_add_xdg_surface_listener(win.xdg_surface, win);

    win.xdg_toplevel = wayland_shim_xdg_surface_get_toplevel(win.xdg_surface);
    wayland_shim_add_xdg_toplevel_listener(win.xdg_toplevel, win);

    wayland_shim_xdg_toplevel_set_app_id(win.xdg_toplevel, conf.app_id.?);

    if (conf.toplevel_tag != null and conf.toplevel_tag.?[0] != 0) {
        if (wayl.toplevel_tag_manager != null) {
            wayland_shim_toplevel_tag_set(wayl.toplevel_tag_manager, win.xdg_toplevel, conf.toplevel_tag.?);
        } else {
            log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement the xdg-toplevel-tag protocol");
        }
    }

    if (wayl.toplevel_icon_manager != null) {
        const app_id: [*:0]const u8 = if (term.app_id) |a| a else conf.app_id.?;

        wayland_shim_toplevel_icon_set(
            wayl.toplevel_icon_manager,
            win.xdg_toplevel,
            if (std.mem.eql(u8, std.mem.span(app_id), "footclient")) "foot" else app_id,
        );
    }

    if (conf.gamma_correct) {
        if (wayl.color_management.img_description != null) {
            std.debug.assert(wayl.color_management.manager != null);

            win.surface.color_management = wayland_shim_color_manager_get_surface(
                wayl.color_management.manager,
                win.surface.surf,
            );

            wayland_shim_color_management_set_image_description(
                win.surface.color_management,
                wayl.color_management.img_description,
                WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL,
            );
        } else {
            if (wayl.color_management.manager == null) {
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "gamma-corrected-blending: disabling; compositor does not implement the color-management protocol");
            } else {
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "gamma-corrected-blending: disabling; compositor does not implement all required color-management features");
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "use e.g. 'wayland-info' and verify the compositor implements:");
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "  - feature: parametric");
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "  - render intent: perceptual");
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "  - TF: ext_linear");
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "  - primaries: sRGB");
            }
        }
    }

    if (conf.csd.preferred == .prefer_none) {
        // User specifically do *not* want decorations
        win.csd_mode = .no;
        log_msg(LOG_CLASS_INFO, "wayland", "wayland.zig", @intCast(@src().line), "window decorations disabled by user");
    } else if (wayl.xdg_decoration_manager != null) {
        win.xdg_toplevel_decoration = wayland_shim_decoration_get(
            wayl.xdg_decoration_manager,
            win.xdg_toplevel,
        );

        log_msg(LOG_CLASS_INFO, "wayland", "wayland.zig", @intCast(@src().line), "requesting %s decorations", @as([*:0]const u8, if (conf.csd.preferred == .prefer_server) "SSD" else "CSD"));

        wayland_shim_decoration_set_mode(
            win.xdg_toplevel_decoration,
            if (conf.csd.preferred == .prefer_server)
                ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
            else
                ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE,
        );

        wayland_shim_add_decoration_listener(win.xdg_toplevel_decoration, win);
    } else {
        // No decoration manager - thus we *must* draw our own decorations
        win.configure.csd_mode = .yes;
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "no decoration manager available - using CSDs unconditionally");
    }

    wayland_shim_surface_commit(win.surface.surf);

    // Complete XDG startup notification
    wayl_activate(wayl, win, token);

    if (!wayl_win_subsurface_new(win, &win.overlay, false)) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to create overlay surface");
        return winInitFail(win);
    }

    switch (conf.tweak.render_timer) {
        .osd, .both => {
            if (!wayl_win_subsurface_new(win, &win.render_timer, false)) {
                log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to create render timer surface");
                return winInitFail(win);
            }
        },

        .none, .log => {},
    }

    return win;
}

fn winInitFail(win: *types.WlWindow) ?*types.WlWindow {
    wayl_win_destroy(win);
    return null;
}

fn waylandOf2(term: *types.Terminal) *types.Wayland {
    return @ptrCast(@alignCast(term.wl.?));
}

// ─────────────────────────────────────────────────────────────────────────
// Transparency region and XDG activation
// ─────────────────────────────────────────────────────────────────────────

extern fn wayland_shim_region_add(region: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) callconv(.c) void;
extern fn wayland_shim_surface_set_opaque_region(surf: ?*anyopaque, region: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_set_blur_region(effect: ?*anyopaque, region: ?*anyopaque) callconv(.c) void;
extern fn term_theme_get(term: *const types.Terminal) callconv(.c) *const types.ColorTheme;
extern fn wayland_shim_activation_get_token(activation: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_activation_token_set_serial(token: ?*anyopaque, serial: u32, seat: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_activation_token_set_surface(token: ?*anyopaque, surf: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_add_activation_token_listener(token: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_activation_token_commit(token: ?*anyopaque) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;

const INT32_MAX: i32 = 0x7fffffff;

export fn wayl_win_alpha_changed(win: *types.WlWindow) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    const wayl = waylandOf(win);

    // When fullscreened, transparency is disabled (see render.c).
    // Update the opaque region to match.
    const is_opaque = term.colors.alpha == 0xffff or win.is_fullscreen;

    if (is_opaque) {
        const region = wayland_shim_compositor_create_region(wayl.compositor);

        if (region != null) {
            wayland_shim_region_add(region, 0, 0, INT32_MAX, INT32_MAX);
            wayland_shim_surface_set_opaque_region(win.surface.surf, region);
            wayland_shim_region_destroy(region);
        }
    } else {
        wayland_shim_surface_set_opaque_region(win.surface.surf, null);
    }

    if (term_theme_get(term).blur) {
        if (wayl.have_background_blur) {
            std.debug.assert(win.surface.background_effect != null);

            if (is_opaque) {
                // No transparency, disable blur
                log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "disabling background blur");
                wayland_shim_set_blur_region(win.surface.background_effect, null);
            } else {
                // We have transparency, enable blur if user has enabled it
                const region = wayland_shim_compositor_create_region(wayl.compositor);
                if (region != null) {
                    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "enabling background blur");

                    wayland_shim_region_add(region, 0, 0, INT32_MAX, INT32_MAX);
                    wayland_shim_set_blur_region(win.surface.background_effect, region);
                    wayland_shim_region_destroy(region);
                }
            }
        } else {
            const S = struct {
                var have_warned: bool = false;
            };
            if (!S.have_warned) {
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "background blur requested, but compositor does not support it");
                S.have_warned = true;
            }
        }
    }
}

export fn activation_token_v1_done(data: ?*anyopaque, xdg_token: ?*anyopaque, token: [*c]const u8) callconv(.c) void {
    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "XDG activation token done: %s", token);

    const ctx: *types.XdgActivationTokenContext = @ptrCast(@alignCast(data.?));
    const win: *types.WlWindow = @ptrCast(@alignCast(ctx.win.?));

    ctx.cb(@ptrCast(token), ctx.cb_data);

    const TokenList = tll.Tll(?*types.XdgActivationTokenContext);
    const tokens: *TokenList = @ptrCast(&win.xdg_tokens);
    var it = (@constCast(tokens)).foreach();
    while (it.next()) |node| {
        if (node.item.?.xdg_token != xdg_token)
            continue;

        std.debug.assert(win == @as(*types.WlWindow, @ptrCast(@alignCast(node.item.?.win.?))));

        free(@as(?*anyopaque, @ptrCast(ctx)));
        wayland_shim_xdg_activation_token_destroy(xdg_token);
        tokens.removeNode(node);
        return;
    }

    bug(@src().file, @intCast(@src().line), "activation_token_v1_done", "activation token not found in list");
}

export fn wayl_get_activation_token(
    wayl: *types.Wayland,
    seat: ?*types.Seat,
    serial: u32,
    win: *types.WlWindow,
    cb: types.ActivationTokenCb,
    cb_data: ?*anyopaque,
) callconv(.c) bool {
    if (wayl.xdg_activation == null)
        return false;

    const token = wayland_shim_activation_get_token(wayl.xdg_activation);

    if (token == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to retrieve XDG activation token");
        return false;
    }

    const ctx: *types.XdgActivationTokenContext = @ptrCast(@alignCast(xmalloc(@sizeOf(types.XdgActivationTokenContext)) orelse unreachable));
    ctx.* = .{
        .win = win,
        .xdg_token = token,
        .cb = cb,
        .cb_data = cb_data,
    };

    {
        const TokenList = tll.Tll(?*types.XdgActivationTokenContext);
        const tokens: *TokenList = @ptrCast(&win.xdg_tokens);
        tokens.pushBack(ctx);
    }

    if (seat != null and serial != 0)
        wayland_shim_activation_token_set_serial(token, serial, seat.?.wl_seat);

    wayland_shim_activation_token_set_surface(token, win.surface.surf);
    wayland_shim_add_activation_token_listener(token, ctx);
    wayland_shim_activation_token_commit(token);
    return true;
}

export fn wayl_activate(wayl: *types.Wayland, win: *types.WlWindow, token: [*c]const u8) callconv(.c) void {
    if (wayl.xdg_activation == null)
        return;

    if (token == null)
        return;

    wayland_shim_xdg_activation_activate(wayl.xdg_activation, @ptrCast(token), win.surface.surf);
}

// ─────────────────────────────────────────────────────────────────────────
// Seat setup / teardown
// ─────────────────────────────────────────────────────────────────────────

extern fn wayland_shim_data_device_manager_get_device(m: ?*anyopaque, seat: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_primary_selection_device_manager_get_device(m: ?*anyopaque, seat: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_text_input_manager_get_text_input(m: ?*anyopaque, seat: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_add_data_device_listener(dev: ?*anyopaque, seat: *types.Seat) callconv(.c) void;
extern fn wayland_shim_add_primary_selection_device_listener(dev: ?*anyopaque, seat: *types.Seat) callconv(.c) void;
extern fn wayland_shim_add_text_input_listener(ti: ?*anyopaque, seat: *types.Seat) callconv(.c) void;
extern fn wayland_shim_data_source_destroy(src: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_data_offer_destroy(offer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_data_device_release(dev: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_source_destroy(src: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_offer_destroy(offer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_device_destroy(dev: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_cursor_shape_device_destroy(dev: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_keyboard_release(kbd: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_pointer_release(pointer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_touch_release(touch: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_text_input_destroy(ti: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_seat_release(seat: ?*anyopaque) callconv(.c) void;

extern fn key_binding_new_for_seat(manager: ?*anyopaque, seat: *types.Seat) callconv(.c) void;
extern fn key_binding_remove_seat(manager: ?*anyopaque, seat: *types.Seat) callconv(.c) void;
extern fn xkb_compose_state_unref(state: ?*anyopaque) callconv(.c) void;
extern fn xkb_compose_table_unref(table: ?*anyopaque) callconv(.c) void;
extern fn xkb_keymap_unref(keymap: ?*anyopaque) callconv(.c) void;
extern fn xkb_state_unref(state: ?*anyopaque) callconv(.c) void;
extern fn xkb_context_unref(context: ?*anyopaque) callconv(.c) void;
extern fn ime_reset_pending(seat: *types.Seat) callconv(.c) void;

fn seatWayl(seat: *types.Seat) *types.Wayland {
    return @ptrCast(@alignCast(seat.wayl.?));
}

export fn seat_add_data_device(seat: *types.Seat) callconv(.c) void {
    const wayl = seatWayl(seat);

    if (wayl.data_device_manager == null)
        return;

    if (seat.data_device != null) {
        // TODO: destroy old device + clipboard data?
        return;
    }

    const data_device = wayland_shim_data_device_manager_get_device(
        wayl.data_device_manager,
        seat.wl_seat,
    );

    if (data_device == null)
        return;

    seat.data_device = data_device;
    wayland_shim_add_data_device_listener(data_device, seat);
}

export fn seat_add_primary_selection(seat: *types.Seat) callconv(.c) void {
    const wayl = seatWayl(seat);

    if (wayl.primary_selection_device_manager == null)
        return;

    if (seat.primary_selection_device != null)
        return;

    const dev = wayland_shim_primary_selection_device_manager_get_device(
        wayl.primary_selection_device_manager,
        seat.wl_seat,
    );

    if (dev == null)
        return;

    seat.primary_selection_device = dev;
    wayland_shim_add_primary_selection_device_listener(dev, seat);
}

export fn seat_add_text_input(seat: *types.Seat) callconv(.c) void {
    const wayl = seatWayl(seat);

    if (wayl.text_input_manager == null)
        return;

    const text_input = wayland_shim_text_input_manager_get_text_input(
        wayl.text_input_manager,
        seat.wl_seat,
    );

    if (text_input == null)
        return;

    seat.wl_text_input = text_input;
    wayland_shim_add_text_input_listener(text_input, seat);
}

export fn seat_add_key_bindings(seat: *types.Seat) callconv(.c) void {
    key_binding_new_for_seat(seatWayl(seat).key_binding_manager, seat);
}

export fn seat_destroy(seat_in: ?*types.Seat) callconv(.c) void {
    const seat = seat_in orelse return;
    const wayl = seatWayl(seat);

    {
        const ButtonList = tll.Tll(types.ButtonTracker);
        const buttons: *ButtonList = @ptrCast(&seat.mouse.buttons);
        buttons.freeList();
    }
    key_binding_remove_seat(wayl.key_binding_manager, seat);

    if (seat.kbd.xkb_compose_state != null)
        xkb_compose_state_unref(seat.kbd.xkb_compose_state);
    if (seat.kbd.xkb_compose_table != null)
        xkb_compose_table_unref(seat.kbd.xkb_compose_table);
    if (seat.kbd.xkb_keymap != null)
        xkb_keymap_unref(seat.kbd.xkb_keymap);
    if (seat.kbd.xkb_state != null)
        xkb_state_unref(seat.kbd.xkb_state);
    if (seat.kbd.xkb != null)
        xkb_context_unref(seat.kbd.xkb);

    if (seat.kbd.repeat.fd >= 0)
        _ = fdm_del(wayl.fdm, seat.kbd.repeat.fd);

    if (seat.pointer.theme != null)
        wl_cursor_theme_destroy(seat.pointer.theme);
    if (seat.pointer.surface.surf != null)
        wayland_shim_surface_destroy(seat.pointer.surface.surf);
    if (seat.pointer.surface.viewport != null)
        wayland_shim_viewport_destroy(seat.pointer.surface.viewport);
    if (seat.pointer.xcursor_callback != null)
        wayland_shim_wl_callback_destroy(seat.pointer.xcursor_callback);

    if (seat.clipboard.data_source != null)
        wayland_shim_data_source_destroy(seat.clipboard.data_source);
    if (seat.clipboard.data_offer != null)
        wayland_shim_data_offer_destroy(seat.clipboard.data_offer);
    if (seat.primary.data_source != null)
        wayland_shim_primary_selection_source_destroy(seat.primary.data_source);
    if (seat.primary.data_offer != null)
        wayland_shim_primary_selection_offer_destroy(seat.primary.data_offer);
    if (seat.primary_selection_device != null)
        wayland_shim_primary_selection_device_destroy(seat.primary_selection_device);
    if (seat.data_device != null)
        wayland_shim_data_device_release(seat.data_device);
    if (seat.pointer.shape_device != null)
        wayland_shim_cursor_shape_device_destroy(seat.pointer.shape_device);
    if (seat.wl_keyboard != null)
        wayland_shim_keyboard_release(seat.wl_keyboard);
    if (seat.wl_pointer != null)
        wayland_shim_pointer_release(seat.wl_pointer);
    if (seat.wl_touch != null)
        wayland_shim_touch_release(seat.wl_touch);

    if (seat.wl_text_input != null)
        wayland_shim_text_input_destroy(seat.wl_text_input);

    if (seat.wl_seat != null)
        wayland_shim_seat_release(seat.wl_seat);

    ime_reset_pending(seat);
    free(@as(?*anyopaque, @ptrCast(seat.clipboard.text)));
    free(@as(?*anyopaque, @ptrCast(seat.primary.text)));
    free(@as(?*anyopaque, @ptrCast(seat.pointer.last_custom_xcursor)));
    free(@as(?*anyopaque, @ptrCast(seat.name)));
}

// ─────────────────────────────────────────────────────────────────────────
// xdg_toplevel / xdg_surface configure
// ─────────────────────────────────────────────────────────────────────────

/// wayland-util.h: `struct wl_array`
const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

extern fn term_visual_focus_in(term: *types.Terminal) callconv(.c) void;
extern fn term_visual_focus_out(term: *types.Terminal) callconv(.c) void;
extern fn term_send_visibility_report(term: *types.Terminal) callconv(.c) void;
extern fn term_window_configured(term: *types.Terminal) callconv(.c) void;
extern fn term_shutdown(term: *types.Terminal) callconv(.c) bool;
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
extern fn wayland_shim_ack_configure(xdg_surface: ?*anyopaque, serial: u32) callconv(.c) void;

// render.h: enum resize_options
const RESIZE_BY_CELLS: c_int = 0x2;

// xdg-shell.h: enum xdg_toplevel_state
const STATE_MAXIMIZED: u32 = 1;
const STATE_FULLSCREEN: u32 = 2;
const STATE_RESIZING: u32 = 3;
const STATE_ACTIVATED: u32 = 4;
const STATE_TILED_LEFT: u32 = 5;
const STATE_TILED_RIGHT: u32 = 6;
const STATE_TILED_TOP: u32 = 7;
const STATE_TILED_BOTTOM: u32 = 8;
const STATE_SUSPENDED: u32 = 9;
const STATE_CONSTRAINED_LEFT: u32 = 10;
const STATE_CONSTRAINED_RIGHT: u32 = 11;
const STATE_CONSTRAINED_TOP: u32 = 12;
const STATE_CONSTRAINED_BOTTOM: u32 = 13;

// xdg-shell.h: enum xdg_toplevel_wm_capabilities
const CAP_WINDOW_MENU: u32 = 1;
const CAP_MAXIMIZE: u32 = 2;
const CAP_FULLSCREEN: u32 = 3;
const CAP_MINIMIZE: u32 = 4;

fn arrayElems(array: *const WlArray) []const u32 {
    if (array.data == null or array.size == 0)
        return &[_]u32{};
    const ptr: [*]const u32 = @ptrCast(@alignCast(array.data.?));
    return ptr[0 .. array.size / @sizeOf(u32)];
}

export fn xdg_toplevel_configure(
    data: ?*anyopaque,
    xdg_toplevel: ?*anyopaque,
    width: i32,
    height: i32,
    states: ?*WlArray,
) callconv(.c) void {
    _ = xdg_toplevel;

    var is_activated = false;
    var is_fullscreen = false;
    var is_maximized = false;
    var is_resizing = false;
    var is_tiled_top = false;
    var is_tiled_bottom = false;
    var is_tiled_left = false;
    var is_tiled_right = false;
    var is_constrained_top = false;
    var is_constrained_bottom = false;
    var is_constrained_left = false;
    var is_constrained_right = false;
    var is_suspended = false;

    for (arrayElems(states.?)) |state| {
        switch (state) {
            STATE_MAXIMIZED => is_maximized = true,
            STATE_FULLSCREEN => is_fullscreen = true,
            STATE_RESIZING => is_resizing = true,
            STATE_ACTIVATED => is_activated = true,
            STATE_TILED_LEFT => is_tiled_left = true,
            STATE_TILED_RIGHT => is_tiled_right = true,
            STATE_TILED_TOP => is_tiled_top = true,
            STATE_TILED_BOTTOM => is_tiled_bottom = true,
            STATE_SUSPENDED => is_suspended = true,
            STATE_CONSTRAINED_LEFT => is_constrained_left = true,
            STATE_CONSTRAINED_RIGHT => is_constrained_right = true,
            STATE_CONSTRAINED_TOP => is_constrained_top = true,
            STATE_CONSTRAINED_BOTTOM => is_constrained_bottom = true,
            else => {},
        }
    }

    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "xdg-toplevel: configure: size=%dx%d", width, height);

    // Changes done here are ignored until the configure event has been
    // ack:ed in xdg_surface_configure(). So, just store the config data
    // and apply it later, in xdg_surface_configure() after we've ack:ed
    // the event.
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));

    win.configure.flags.is_activated = is_activated;
    win.configure.flags.is_suspended = is_suspended;
    win.configure.flags.is_fullscreen = is_fullscreen;
    win.configure.flags.is_maximized = is_maximized;
    win.configure.flags.is_resizing = is_resizing;
    win.configure.flags.is_tiled_top = is_tiled_top;
    win.configure.flags.is_tiled_bottom = is_tiled_bottom;
    win.configure.flags.is_tiled_left = is_tiled_left;
    win.configure.flags.is_tiled_right = is_tiled_right;
    win.configure.flags.is_constrained_top = is_constrained_top;
    win.configure.flags.is_constrained_bottom = is_constrained_bottom;
    win.configure.flags.is_constrained_left = is_constrained_left;
    win.configure.flags.is_constrained_right = is_constrained_right;
    win.configure.width = width;
    win.configure.height = height;
}

export fn xdg_toplevel_close(data: ?*anyopaque, xdg_toplevel: ?*anyopaque) callconv(.c) void {
    _ = xdg_toplevel;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "xdg-toplevel: close");
    _ = term_shutdown(term);
}

export fn xdg_toplevel_configure_bounds(
    data: ?*anyopaque,
    xdg_toplevel: ?*anyopaque,
    width: i32,
    height: i32,
) callconv(.c) void {
    // TODO: ensure we don't pick a bigger size
    _ = data;
    _ = xdg_toplevel;
    _ = width;
    _ = height;
}

export fn xdg_toplevel_wm_capabilities(
    data: ?*anyopaque,
    xdg_toplevel: ?*anyopaque,
    caps: ?*WlArray,
) callconv(.c) void {
    _ = xdg_toplevel;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));

    win.wm_capabilities.maximize = false;
    win.wm_capabilities.minimize = false;

    for (arrayElems(caps.?)) |cap| {
        switch (cap) {
            CAP_MAXIMIZE => win.wm_capabilities.maximize = true,
            CAP_MINIMIZE => win.wm_capabilities.minimize = true,
            CAP_WINDOW_MENU, CAP_FULLSCREEN => {},
            else => {},
        }
    }
}

export fn xdg_surface_configure(
    data: ?*anyopaque,
    xdg_surface: ?*anyopaque,
    serial: u32,
) callconv(.c) void {
    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "xdg-surface: configure");

    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    if (win.unmapped) {
        // https://codeberg.org/dnkl/foot/issues/1249
        // https://gitlab.freedesktop.org/wlroots/wlroots/-/issues/3487
        // https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/3719
        // https://gitlab.freedesktop.org/wayland/wayland-protocols/-/issues/108
        return;
    }

    const wasnt_configured = !win.is_configured;
    const was_resizing = win.is_resizing;
    const was_fullscreen = win.is_fullscreen;
    const was_suspended = win.is_suspended;
    const csd_was_enabled = win.csd_mode == .yes and !win.is_fullscreen;
    var new_width: c_int = win.configure.width;
    var new_height: c_int = win.configure.height;

    win.is_configured = true;
    win.is_maximized = win.configure.flags.is_maximized;
    win.is_fullscreen = win.configure.flags.is_fullscreen;
    win.is_resizing = win.configure.flags.is_resizing;
    win.is_suspended = win.configure.flags.is_suspended;

    win.is_tiled_top = win.configure.flags.is_tiled_top;
    win.is_tiled_bottom = win.configure.flags.is_tiled_bottom;
    win.is_tiled_left = win.configure.flags.is_tiled_left;
    win.is_tiled_right = win.configure.flags.is_tiled_right;

    win.is_constrained_top = win.configure.flags.is_constrained_top;
    win.is_constrained_bottom = win.configure.flags.is_constrained_bottom;
    win.is_constrained_left = win.configure.flags.is_constrained_left;
    win.is_constrained_right = win.configure.flags.is_constrained_right;

    win.is_tiled = win.is_tiled_top or
        win.is_tiled_bottom or
        win.is_tiled_left or
        win.is_tiled_right;

    win.csd_mode = win.configure.csd_mode;

    const enable_csd = win.csd_mode == .yes and !win.is_fullscreen;
    if (!csd_was_enabled and enable_csd) {
        csd_instantiate(win);
    } else if (csd_was_enabled and !enable_csd) {
        csd_destroy(win);
    }

    if (enable_csd and new_width > 0 and new_height > 0) {
        if (wayl_win_csd_titlebar_visible(win))
            new_height -= term.conf.?.csd.title_height;

        if (wayl_win_csd_borders_visible(win)) {
            new_height -= 2 * term.conf.?.csd.border_width_visible;
            new_width -= 2 * term.conf.?.csd.border_width_visible;
        }
    }

    wayland_shim_ack_configure(xdg_surface, serial);

    var opts: c_int = RESIZE_BY_CELLS;

    // TODO: decide if we should do the last "forced" call when ending an
    // interactive resize. Without it, the last TIOCSWINSZ sent to the
    // client will be a scheduled one, i.e. there will be a small delay
    // after the user has *stopped* resizing before the client gets the
    // final size.
    if (was_resizing and !win.is_resizing)
        opts |= RESIZE_FORCE;

    const resized = render_resize(term, new_width, new_height, opts);

    if (win.configure.flags.is_activated)
        term_visual_focus_in(term)
    else
        term_visual_focus_out(term);

    if (was_suspended != win.is_suspended and term.visibility_reports)
        term_send_visibility_report(term);

    // Update opaque region if fullscreen state changed, also need to
    // render, since we use different buffer types with and without alpha
    if (was_fullscreen != win.is_fullscreen) {
        wayl_win_alpha_changed(win);
        render_refresh(term);
    }

    const will_render_soon = resized or
        term.render.refresh.grid or
        term.render.pending.grid;

    if (!will_render_soon) {
        // If we didn't resize, and aren't refreshing for other reasons,
        // we won't be committing a new surface anytime soon. Some
        // compositors require a commit in combination with an ack - make
        // them happy.
        wayland_shim_surface_commit(win.surface.surf);
    }

    if (wasnt_configured)
        term_window_configured(term);
}

// ─────────────────────────────────────────────────────────────────────────
// wl_surface listener
// ─────────────────────────────────────────────────────────────────────────

const MonitorList = tll.Tll(types.Monitor);
const WindowOutputList = tll.Tll(?*const types.Monitor);

export fn verify_iface_version(iface: [*c]const u8, version: u32, wanted: u32) callconv(.c) bool {
    if (version >= wanted)
        return true;

    log_msg(
        LOG_CLASS_ERROR,
        "wayland",
        "wayland.zig",
        @intCast(@src().line),
        "%s: need interface version %u, but compositor only implements %u",
        iface,
        wanted,
        version,
    );
    return false;
}

export fn surface_enter(data: ?*anyopaque, wl_surface: ?*anyopaque, wl_output: ?*anyopaque) callconv(.c) void {
    _ = wl_surface;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));
    const wayl = waylandOf(win);

    const monitors: *MonitorList = @ptrCast(&wayl.monitors);
    var it = (@constCast(monitors)).foreach();
    while (it.next()) |node| {
        if (node.item.output == wl_output) {
            log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "mapped on %s", node.item.name);
            const outputs: *WindowOutputList = @ptrCast(&win.on_outputs);
            outputs.pushBack(&node.item);
            update_term_for_output_change(term);
            return;
        }
    }

    log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "mapped on unknown output");
}

export fn surface_leave(data: ?*anyopaque, wl_surface: ?*anyopaque, wl_output: ?*anyopaque) callconv(.c) void {
    _ = wl_surface;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    const outputs: *WindowOutputList = @ptrCast(&win.on_outputs);
    var it = outputs.foreach();
    while (it.next()) |node| {
        if (node.item.?.output != wl_output)
            continue;

        log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "unmapped from %s", node.item.?.name);
        outputs.removeNode(node);
        update_term_for_output_change(term);
        return;
    }

    log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "unmapped from unknown output");
}

export fn surface_preferred_buffer_scale(data: ?*anyopaque, surface: ?*anyopaque, scale: i32) callconv(.c) void {
    _ = surface;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));

    if (win.preferred_buffer_scale == scale)
        return;

    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "wl_surface preferred scale: %d -> %d", win.preferred_buffer_scale, scale);

    win.preferred_buffer_scale = scale;
    updateTermForOutputChange(@ptrCast(@alignCast(win.term.?)));
}

export fn surface_preferred_buffer_transform(data: ?*anyopaque, surface: ?*anyopaque, transform: u32) callconv(.c) void {
    // TODO
    _ = data;
    _ = surface;
    _ = transform;
}

// ─────────────────────────────────────────────────────────────────────────
// Small protocol listeners
// ─────────────────────────────────────────────────────────────────────────

// wayland-client: enum wl_shm_format
const WL_SHM_FORMAT_ARGB2101010: u32 = 0x30335241; // 'A''R''3''0'
const WL_SHM_FORMAT_ABGR2101010: u32 = 0x30334241; // 'A''B''3''0'
const WL_SHM_FORMAT_ABGR16161616: u32 = 0x38344241; // 'A''B''4''8'

export fn shm_format(data: ?*anyopaque, wl_shm: ?*anyopaque, format: u32) callconv(.c) void {
    _ = wl_shm;
    const wayl: *types.Wayland = @ptrCast(@alignCast(data.?));

    switch (format) {
        WL_SHM_FORMAT_ARGB2101010 => wayl._shm_format_bits.argb2101010 = true,
        WL_SHM_FORMAT_ABGR2101010 => wayl._shm_format_bits.abgr2101010 = true,
        WL_SHM_FORMAT_ABGR16161616 => wayl._shm_format_bits.abgr161616 = true,
        else => {},
    }
}

export fn seat_handle_name(data: ?*anyopaque, wl_seat: ?*anyopaque, name: [*c]const u8) callconv(.c) void {
    _ = wl_seat;
    const seat: *types.Seat = @ptrCast(@alignCast(data.?));
    free(@as(?*anyopaque, @ptrCast(seat.name)));
    seat.name = if (name == null) null else xstrdup(@ptrCast(name));
}

export fn xdg_toplevel_decoration_configure(
    data: ?*anyopaque,
    decoration: ?*anyopaque,
    mode: u32,
) callconv(.c) void {
    _ = decoration;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));
    const term: *types.Terminal = @ptrCast(@alignCast(win.term.?));

    std.debug.assert(term.conf.?.csd.preferred != .prefer_none);

    switch (mode) {
        ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE => {
            log_msg(LOG_CLASS_INFO, "wayland", "wayland.zig", @intCast(@src().line), "using CSD decorations");
            win.configure.csd_mode = .yes;
        },

        ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE => {
            log_msg(LOG_CLASS_INFO, "wayland", "wayland.zig", @intCast(@src().line), "using SSD decorations");
            win.configure.csd_mode = .no;
        },

        else => log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "unimplemented: unknown XDG toplevel decoration mode: %u", mode),
    }
}

export fn fractional_scale_preferred_scale(
    data: ?*anyopaque,
    fractional_scale: ?*anyopaque,
    scale: u32,
) callconv(.c) void {
    _ = fractional_scale;
    const win: *types.WlWindow = @ptrCast(@alignCast(data.?));

    const new_scale: f32 = @as(f32, @floatFromInt(scale)) / 120.0;

    if (win.scale == new_scale)
        return;

    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "fractional scale: %.2f -> %.2f", win.scale, new_scale);

    win.scale = new_scale;
    updateTermForOutputChange(@ptrCast(@alignCast(win.term.?)));
}

// ext-background-effect-v1.h
const EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR: u32 = 1;

export fn ext_background_capabilities(data: ?*anyopaque, manager: ?*anyopaque, flags: u32) callconv(.c) void {
    _ = manager;
    const wayl: *types.Wayland = @ptrCast(@alignCast(data.?));

    wayl.have_background_blur =
        (flags & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR) != 0;

    log_msg(LOG_CLASS_DEBUG, "wayland", "wayland.zig", @intCast(@src().line), "compositor supports background blur: %s", @as([*:0]const u8, if (wayl.have_background_blur) "yes" else "no"));
}

// ─────────────────────────────────────────────────────────────────────────
// wayl_init() / wayl_destroy()
// ─────────────────────────────────────────────────────────────────────────

extern fn wayland_shim_fcntl_getfl(fd: c_int) callconv(.c) c_int;
extern fn wayland_shim_fcntl_setfl(fd: c_int, flags: c_int) callconv(.c) c_int;
extern fn wayland_shim_text_input_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_toplevel_tag_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_background_effect_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_image_description_destroy(desc: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_color_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_system_bell_destroy(bell: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_toplevel_icon_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_single_pixel_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_fractional_scale_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_viewporter_destroy(viewporter: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_cursor_shape_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_activation_destroy(activation: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_output_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_wm_base_destroy(shell: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_decoration_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_presentation_destroy(presentation: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_data_device_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_device_manager_destroy(m: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_shm_destroy(shm: ?*anyopaque, use_release: bool) callconv(.c) void;
extern fn wayland_shim_subcompositor_destroy(sub_compositor: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_compositor_destroy(compositor: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_fixes_destroy(fixes: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_registry_destroy(registry: ?*anyopaque) callconv(.c) void;

extern fn wayland_shim_hook_add(fdm: ?*anyopaque, wayl: *types.Wayland) callconv(.c) bool;
extern fn wayland_shim_hook_del(fdm: ?*anyopaque) callconv(.c) bool;
extern fn wayland_shim_add_registry_listener(registry: ?*anyopaque, wayl: *types.Wayland) callconv(.c) void;

extern fn wl_display_connect(name: [*c]const u8) callconv(.c) ?*anyopaque;
extern fn wayland_shim_display_get_registry(display: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wl_display_get_fd(display: ?*anyopaque) callconv(.c) c_int;
extern fn wl_display_disconnect(display: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_fdm_add(fdm: ?*anyopaque, wayl: *types.Wayland) callconv(.c) bool;
extern fn fdm_del_no_close(fdm: ?*anyopaque, fd: c_int) callconv(.c) bool;
extern fn term_destroy(term: *types.Terminal) callconv(.c) c_int;

const O_NONBLOCK: c_int = 0o4000;

export fn wayl_init(
    fdm: ?*anyopaque,
    key_binding_manager: ?*anyopaque,
    presentation_timings: bool,
) callconv(.c) ?*types.Wayland {
    const wayl: *types.Wayland = @ptrCast(@alignCast(calloc(1, @sizeOf(types.Wayland)) orelse {
        log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "calloc() failed");
        return null;
    }));

    wayl.fdm = fdm;
    wayl.key_binding_manager = key_binding_manager;
    wayl.fd = -1;
    wayl.presentation_timings = presentation_timings;

    if (!wayland_shim_hook_add(fdm, wayl)) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to add FDM hook");
        return waylInitFail(wayl);
    }

    wayl.display = wl_display_connect(null);
    if (wayl.display == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to connect to wayland; no compositor running?");
        return waylInitFail(wayl);
    }

    wayl.registry = wayland_shim_display_get_registry(wayl.display);
    if (wayl.registry == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to get wayland registry");
        return waylInitFail(wayl);
    }

    wayland_shim_add_registry_listener(wayl.registry, wayl);
    _ = wl_display_roundtrip(wayl.display);

    if (wayl.compositor == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no compositor");
        return waylInitFail(wayl);
    }
    if (wayl.sub_compositor == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no sub compositor");
        return waylInitFail(wayl);
    }
    if (wayl.shm == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no shared memory buffers interface");
        return waylInitFail(wayl);
    }
    if (wayl.shell == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no XDG shell interface");
        return waylInitFail(wayl);
    }
    if (wayl.data_device_manager == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no clipboard available (wl_data_device_manager not implemented by server)");
        return waylInitFail(wayl);
    }
    if (tllLengthPtr(&wayl.seats) == 0) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no seats available (wl_seat interface too old?)");
        return waylInitFail(wayl);
    }
    if (tllLengthPtr(&wayl.monitors) == 0) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "no monitors available");
        return waylInitFail(wayl);
    }

    if (presentation_timings and wayl.presentation == null) {
        log_msg(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement the presentation time interface");
        return waylInitFail(wayl);
    }

    if (wayl.primary_selection_device_manager == null)
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement the primary selection interface");

    if (wayl.xdg_activation == null) {
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement XDG activation, bell.urgent will fall back to coloring the window margins red");
    }

    if (wayl.fractional_scale_manager == null or wayl.viewporter == null)
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement fractional scaling");

    if (wayl.cursor_shape_manager == null) {
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement server-side cursors, falling back to client-side cursors");
    }

    if (wayl.toplevel_icon_manager == null) {
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "compositor does not implement the xdg-toplevel-icon protocol");
    }

    if (wayl.text_input_manager == null) {
        log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "text input interface not implemented by compositor; IME will be disabled");
    }

    // Trigger listeners registered when handling globals
    _ = wl_display_roundtrip(wayl.display);

    {
        const monitors: *MonitorList = @ptrCast(&wayl.monitors);
        var it = (@constCast(monitors)).foreach();
        while (it.next()) |node| {
            const mon = &node.item;
            log_msg(
                LOG_CLASS_INFO,
                "wayland",
                "wayland.zig",
                @intCast(@src().line),
                "%s: %dx%d+%dx%d@%dHz %s %.2f\" scale=%d, DPI=%.2f/%.2f (physical/scaled)",
                mon.name,
                mon.dim.px_real.width,
                mon.dim.px_real.height,
                mon.x,
                mon.y,
                @as(c_int, @intFromFloat(@round(mon.refresh))),
                if (mon.model) |m| m else mon.description,
                mon.inch,
                mon.scale,
                mon.dpi.physical,
                mon.dpi.scaled,
            );
        }
    }

    wayl.fd = wl_display_get_fd(wayl.display);
    if (wayland_shim_fcntl_setfl(wayl.fd, wayland_shim_fcntl_getfl(wayl.fd) | O_NONBLOCK) < 0) {
        log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to make Wayland socket non-blocking");
        return waylInitFail(wayl);
    }

    if (!wayland_shim_fdm_add(fdm, wayl))
        return waylInitFail(wayl);

    if (wl_display_prepare_read(wayl.display) != 0) {
        log_errno(LOG_CLASS_ERROR, "wayland", "wayland.zig", @intCast(@src().line), "failed to prepare for reading wayland events");
        return waylInitFail(wayl);
    }

    return wayl;
}

fn waylInitFail(wayl: *types.Wayland) ?*types.Wayland {
    wayl_destroy(wayl);
    return null;
}

fn tllLengthPtr(list: *const anyopaque) usize {
    // tll's third word is the length
    const p: [*]const usize = @ptrCast(@alignCast(list));
    return p[2];
}

export fn wayl_destroy(wayl_in: ?*types.Wayland) callconv(.c) void {
    const wayl = wayl_in orelse return;

    {
        const TerminalList = tll.Tll(?*anyopaque);
        const terms: *TerminalList = @ptrCast(&wayl.terms);
        var it = (@constCast(terms)).foreach();
        while (it.next()) |node| {
            const S = struct {
                var have_warned: bool = false;
            };
            if (!S.have_warned) {
                S.have_warned = true;
                log_msg(LOG_CLASS_WARNING, "wayland", "wayland.zig", @intCast(@src().line), "there are terminals still running");
                _ = term_destroy(@ptrCast(@alignCast(node.item.?)));
            }
        }
        terms.freeList();
    }

    _ = wayland_shim_hook_del(wayl.fdm);

    {
        const monitors: *MonitorList = @ptrCast(&wayl.monitors);
        var it = monitors.foreach();
        while (it.next()) |node| {
            monitor_destroy(&node.item);
            monitors.removeNode(node);
        }
    }

    {
        const SeatList = tll.Tll(types.Seat);
        const seats: *SeatList = @ptrCast(&wayl.seats);
        var it = seats.foreach();
        while (it.next()) |node| {
            seat_destroy(&node.item);
            seats.removeNode(node);
        }
    }

    if (wayl.text_input_manager != null)
        wayland_shim_text_input_manager_destroy(wayl.text_input_manager);
    if (wayl.toplevel_tag_manager != null)
        wayland_shim_toplevel_tag_manager_destroy(wayl.toplevel_tag_manager);
    if (wayl.background_effect_manager != null)
        wayland_shim_background_effect_manager_destroy(wayl.background_effect_manager);

    if (wayl.color_management.img_description != null)
        wayland_shim_image_description_destroy(wayl.color_management.img_description);
    if (wayl.color_management.manager != null)
        wayland_shim_color_manager_destroy(wayl.color_management.manager);
    if (wayl.system_bell != null)
        wayland_shim_system_bell_destroy(wayl.system_bell);
    if (wayl.toplevel_icon_manager != null)
        wayland_shim_toplevel_icon_manager_destroy(wayl.toplevel_icon_manager);
    if (wayl.single_pixel_manager != null)
        wayland_shim_single_pixel_manager_destroy(wayl.single_pixel_manager);
    if (wayl.fractional_scale_manager != null)
        wayland_shim_fractional_scale_manager_destroy(wayl.fractional_scale_manager);
    if (wayl.viewporter != null)
        wayland_shim_viewporter_destroy(wayl.viewporter);
    if (wayl.cursor_shape_manager != null)
        wayland_shim_cursor_shape_manager_destroy(wayl.cursor_shape_manager);
    if (wayl.xdg_activation != null)
        wayland_shim_activation_destroy(wayl.xdg_activation);
    if (wayl.xdg_output_manager != null)
        wayland_shim_output_manager_destroy(wayl.xdg_output_manager);
    if (wayl.shell != null)
        wayland_shim_wm_base_destroy(wayl.shell);
    if (wayl.xdg_decoration_manager != null)
        wayland_shim_decoration_manager_destroy(wayl.xdg_decoration_manager);
    if (wayl.presentation != null)
        wayland_shim_presentation_destroy(wayl.presentation);
    if (wayl.data_device_manager != null)
        wayland_shim_data_device_manager_destroy(wayl.data_device_manager);
    if (wayl.primary_selection_device_manager != null)
        wayland_shim_primary_selection_device_manager_destroy(wayl.primary_selection_device_manager);
    if (wayl.shm != null)
        wayland_shim_shm_destroy(wayl.shm, wayl.use_shm_release);
    if (wayl.sub_compositor != null)
        wayland_shim_subcompositor_destroy(wayl.sub_compositor);
    if (wayl.compositor != null)
        wayland_shim_compositor_destroy(wayl.compositor);
    if (wayl.fixes != null)
        wayland_shim_fixes_destroy(wayl.fixes);
    if (wayl.registry != null)
        wayland_shim_registry_destroy(wayl.registry);
    if (wayl.fd != -1)
        _ = fdm_del_no_close(wayl.fdm, wayl.fd);
    if (wayl.display != null) {
        wayl_flush(wayl);
        wl_display_disconnect(wayl.display);
    }

    free(@as(?*anyopaque, @ptrCast(wayl)));
}
