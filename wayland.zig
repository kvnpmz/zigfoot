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
