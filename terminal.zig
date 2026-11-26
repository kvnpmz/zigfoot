const std = @import("std");
const build_options = @import("build_options");
const types = @import("terminal_types.zig");
extern fn render_refresh_csd(term: *types.Terminal) void;

extern fn row(grid: *types.Grid, row_no: c_int) *types.Row;
extern fn rowInView(grid: *types.Grid, row_no: c_int) *types.Row;

// Ported from terminal.c; the pure core lives next to PtOrPx so it can be
// unit-tested without dragging in terminal.zig's extern dependencies.
export fn term_pt_or_px_as_pixels(
    term: *const types.Terminal,
    pt_or_px: *const types.PtOrPx,
) callconv(.c) c_int {
    return types.ptOrPxAsPixels(term, pt_or_px);
}

//
// Chunk T9b-ii — custom glyph lifetime. C's free_custom_glyph() /
// free_custom_glyphs() are static helpers called from term_set_fonts() and
// term_destroy(); both call sites now call the single exported entry point
// below. The glyph array element type is still opaque, so the one field we
// need (fcft_glyph.pix) comes from a terminal-shim.c accessor.
//

const PixmanImage = anyopaque;

extern fn pixman_image_get_data(image: *PixmanImage) callconv(.c) ?[*]u32;
extern fn pixman_image_unref(image: *PixmanImage) callconv(.c) void;

// Mirrors terminal.h's GLYPH_*_COUNT macros.
const GLYPH_BOX_DRAWING_COUNT = GLYPH_BOX_DRAWING_LAST - GLYPH_BOX_DRAWING_FIRST + 1;
const GLYPH_BRAILLE_COUNT = GLYPH_BRAILLE_LAST - GLYPH_BRAILLE_FIRST + 1;
const GLYPH_OCTANTS_COUNT = GLYPH_OCTANTS_LAST - GLYPH_OCTANTS_FIRST + 1;
const GLYPH_LEGACY_COUNT = GLYPH_LEGACY_LAST - GLYPH_LEGACY_FIRST + 1;

const GLYPH_BOX_DRAWING_FIRST = 0x2500;
const GLYPH_BOX_DRAWING_LAST = 0x259F;
const GLYPH_BRAILLE_FIRST = 0x2800;
const GLYPH_BRAILLE_LAST = 0x28FF;
const GLYPH_OCTANTS_FIRST = 0x1CD00;
const GLYPH_OCTANTS_LAST = 0x1CDE5;
const GLYPH_LEGACY_FIRST = 0x1FB00;
const GLYPH_LEGACY_LAST = 0x1FB9B;

fn freeCustomGlyph(glyph: *?*anyopaque) void {
    const g = glyph.* orelse return;

    const fg: *types.FcftGlyph = @ptrCast(@alignCast(g));
    if (fg.pix) |pix_any| {
        const pix: *PixmanImage = @ptrCast(@alignCast(pix_any));
        if (pixman_image_get_data(pix)) |data|
            std.c.free(@ptrCast(data));
        pixman_image_unref(pix);
    }

    std.c.free(g);
    glyph.* = null;
}

fn freeCustomGlyphs(glyphs: *?*anyopaque, count: usize) void {
    const ptr = glyphs.* orelse return;

    const arr: [*]?*anyopaque = @ptrCast(@alignCast(ptr));
    var i: usize = 0;
    while (i < count) : (i += 1)
        freeCustomGlyph(&arr[i]);

    std.c.free(ptr);
    glyphs.* = null;
}

export fn term_free_custom_glyphs(term: *types.Terminal) callconv(.c) void {
    freeCustomGlyphs(&term.custom_glyphs.box_drawing, GLYPH_BOX_DRAWING_COUNT);
    freeCustomGlyphs(&term.custom_glyphs.braille, GLYPH_BRAILLE_COUNT);
    freeCustomGlyphs(&term.custom_glyphs.octants, GLYPH_OCTANTS_COUNT);
    freeCustomGlyphs(&term.custom_glyphs.legacy, GLYPH_LEGACY_COUNT);
}

//
// Chunk T9b-iii — font baseline. Reads only fcft's ascent/descent, which come
// through the metrics accessor above; the arithmetic lives in
// terminal_types.zig so it has a unit test.
//

const FontMetrics = extern struct {
    height: c_int,
    descent: c_int,
    ascent: c_int,
    max_advance_x: c_int,
};

extern fn terminal_shim_fcft_font_metrics(font: *anyopaque) callconv(.c) FontMetrics;

export fn term_font_baseline(term: *const types.Terminal) callconv(.c) c_int {
    const metrics = terminal_shim_fcft_font_metrics(term.fonts[0].?);
    return types.fontBaseline(term, metrics.ascent, metrics.descent);
}

// Ported from terminal.c; core in terminal_types.zig (unit-tested).
export fn term_line_height_update(term: *types.Terminal) callconv(.c) void {
    types.lineHeightUpdate(term);
}

//
// Chunk T9b-v — term_set_fonts(). This is the integration point: it swaps the
// four fcft fonts, drops the custom-glyph caches, and recomputes the cell
// metrics from font extents. Real resize work is left to render_resize(),
// which needs a window; callers that fire before the window exists pass
// resize_grid = false.
//

const RESIZE_FORCE: u8 = 1 << 0;
const RESIZE_KEEP_GRID: u8 = 1 << 2;

const LOG_CLASS_INFO: c_int = 3;

extern fn fcft_destroy(font: ?*anyopaque) callconv(.c) void;
extern fn fcft_rasterize_char_utf32(
    font: *anyopaque,
    cp: u32,
    subpixel: c_int,
) callconv(.c) ?*const anyopaque;
extern fn sixel_cell_size_changed(term: *types.Terminal) callconv(.c) void;
extern fn render_resize(
    term: *types.Terminal,
    width: c_int,
    height: c_int,
    opts: u8,
) callconv(.c) bool;

export fn term_set_fonts(
    term: *types.Terminal,
    fonts: [*]?*anyopaque,
    resize_grid: bool,
) callconv(.c) bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        std.debug.assert(fonts[i] != null);

        fcft_destroy(term.fonts[i]);
        term.fonts[i] = fonts[i];
    }

    term_free_custom_glyphs(term);

    const conf = term.conf.?;
    const primary = term.fonts[0].?;
    const metrics = terminal_shim_fcft_font_metrics(primary);

    // Measure 'M'; fall back to the font's widest glyph if it has no 'M'.
    const glyph_m = fcft_rasterize_char_utf32(primary, 'M', term.font_subpixel);
    const advance: c_int = if (glyph_m) |glyph|
        @as(*const types.FcftGlyph, @ptrCast(@alignCast(glyph))).advance.x
    else
        metrics.max_advance_x;

    term_line_height_update(term);

    term.cell_width = advance + types.ptOrPxAsPixels(term, &conf.letter_spacing);

    term.cell_height = if (term.font_line_height.px >= 0)
        types.ptOrPxAsPixels(term, &term.font_line_height)
    else
        @max(metrics.height, metrics.ascent + metrics.descent);

    if (term.cell_width <= 0)
        term.cell_width = 1;
    if (term.cell_height <= 0)
        term.cell_height = 1;

    term.font_x_ofs = @intCast(types.ptOrPxAsPixels(term, &conf.horizontal_letter_offset));
    term.font_y_ofs = @intCast(types.ptOrPxAsPixels(term, &conf.vertical_letter_offset));

    term.font_baseline = @intCast(term_font_baseline(term));

    log_msg(
        LOG_CLASS_INFO,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "cell width=%d, height=%d",
        term.cell_width,
        term.cell_height,
    );

    sixel_cell_size_changed(term);

    // Some code paths are forced to call render_resize() right after this.
    if (resize_grid) {
        var opts: u8 = RESIZE_FORCE;
        if (conf.resize_keep_grid)
            opts |= RESIZE_KEEP_GRID;

        _ = render_resize(
            term,
            @intFromFloat(@round(@as(f32, @floatFromInt(term.width)) / term.scale)),
            @intFromFloat(@round(@as(f32, @floatFromInt(term.height)) / term.scale)),
            opts,
        );
    }

    return true;
}

//
// Chunk T9c — reload_fonts() / load_fonts_from_conf().
//
// This is the runtime font path: every font-size shortcut, DPI or scale
// change ends up here. The four faces are loaded on separate threads, like
// the C version, and the actual swap is term_set_fonts().
//
// The font-option fields and the two environment predicates are owned here;
// the generated Wayland requests and libc/fcft entry points remain in C.
//

const FontLoadData = struct {
    count: usize,
    names: [*]const ?[*:0]const u8,
    attrs: [*:0]const u8,
    options: *const anyopaque,
    font: *?*anyopaque,
    ok: bool = false,
};

extern fn fcft_from_name2(
    count: usize,
    names: [*]const ?[*:0]const u8,
    attributes: [*:0]const u8,
    options: *const anyopaque,
) callconv(.c) ?*anyopaque;
extern fn fcft_font_options_create() callconv(.c) ?*anyopaque;
extern fn fcft_font_options_destroy(options: *anyopaque) callconv(.c) void;
extern fn shm_shim_format_constants() callconv(.c) *const types.ShmFormatConstants;

extern fn shm_chain_bit_depth(chain: *const types.ShmBufferChain) callconv(.c) c_int;

const SHM_BITS_10: c_int = 2;

// pixman.h's PIXMAN_rgba_float enum value. The 16-bit choice is the same
// Meson capability test that defines HAVE_PIXMAN_RGBA_16 for C.
const PIXMAN_rgba_float: u32 = 0x10cb4444;

fn configureFontOptions(
    options: *types.FcftFontOptions,
    scaling_filter: c_int,
    srgb_decode: bool,
    high_res_color: bool,
) void {
    options.scaling_filter = scaling_filter;
    options.color_glyphs.format = shm_shim_format_constants().*.pixman_a8r8g8b8;
    options.color_glyphs.srgb_decode = srgb_decode;

    if (high_res_color) {
        options.color_glyphs.format = if (build_options.pixman_rgba_16)
            shm_shim_format_constants().*.pixman_a16b16g16r16
        else
            PIXMAN_rgba_float;
    }
}

export fn terminal_shim_linear_blending(term: *const types.Terminal) callconv(.c) bool {
    const wl = term.wl orelse return false;
    return wayl_do_linear_blending(wl, term.conf.?);
}

export fn terminal_shim_grid_is_high_bit_depth(term: *const types.Terminal) callconv(.c) bool {
    const chain: *const types.ShmBufferChain = @ptrCast(@alignCast(
        term.render.chains.grid orelse return false,
    ));
    return shm_chain_bit_depth(chain) >= SHM_BITS_10;
}
extern fn snprintf(buf: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;
extern fn asprintf(strp: *?[*:0]u8, format: [*:0]const u8, ...) callconv(.c) c_int;

fn asConstNames(p: [*]?[*:0]u8) [*]const ?[*:0]const u8 {
    return @ptrCast(p);
}

fn fontLoaderThread(data: *FontLoadData) void {
    const font = fcft_from_name2(data.count, data.names, data.attrs, data.options);
    data.font.* = font;
    data.ok = font != null;
}

export fn reload_fonts(term: *types.Terminal, resize_grid: bool) callconv(.c) bool {
    const conf = term.conf.?;
    const alloc = std.heap.c_allocator;

    const counts: [4]usize = .{
        conf.fonts[0].count,
        conf.fonts[1].count,
        conf.fonts[2].count,
        conf.fonts[3].count,
    };

    var name_arrays: [4]?[]?[*:0]u8 = .{ null, null, null, null };

    for (0..4) |i| {
        const list = conf.fonts[i];
        const arr = alloc.alloc(?[*:0]u8, list.count) catch @panic("out of memory");
        name_arrays[i] = arr;

        const sizes: [*]types.ConfigFont = @ptrCast(term.font_sizes[i].?);
        const scale: f32 = if (term.font_is_sized_by_dpi) 1.0 else term.scale;

        for (0..list.count) |j| {
            const font = list.arr.?[j];
            var size_buf: [64]u8 = undefined;

            if (sizes[j].px_size > 0) {
                const px: c_int = @intFromFloat(
                    @round(@as(f32, @floatFromInt(sizes[j].px_size)) * scale),
                );
                _ = snprintf(&size_buf, size_buf.len, ":pixelsize=%d", px);
            } else {
                _ = snprintf(&size_buf, size_buf.len, ":size=%.2f", sizes[j].pt_size * scale);
            }

            const pattern: [*:0]const u8 = if (font.pattern) |p| p else "";
            var name: ?[*:0]u8 = null;
            _ = asprintf(&name, "%s%s", pattern, &size_buf);
            arr[j] = name;
        }
    }

    // Did the user configure custom bold/italic faces? Otherwise use the
    // regular face with weight/slant attributes.
    const custom_bold = counts[1] > 0;
    const custom_italic = counts[2] > 0;
    const custom_bold_italic = counts[3] > 0;

    const count_bold = if (custom_bold) counts[1] else counts[0];
    const count_italic = if (custom_italic) counts[2] else counts[0];
    const count_bold_italic = if (custom_bold_italic) counts[3] else counts[0];

    const names_bold = asConstNames(name_arrays[if (custom_bold) 1 else 0].?.ptr);
    const names_italic = asConstNames(name_arrays[if (custom_italic) 2 else 0].?.ptr);
    const names_bold_italic = asConstNames(name_arrays[if (custom_bold_italic) 3 else 0].?.ptr);

    const use_dpi = term.font_is_sized_by_dpi;
    const dpi_value: f32 = if (use_dpi) term.font_dpi else 96.0;
    var dpi_buf: [32]u8 = undefined;
    _ = snprintf(&dpi_buf, dpi_buf.len, "dpi=%.2f", dpi_value);

    const bold_suffix: [*:0]const u8 = if (!custom_bold) ":weight=bold" else "";
    const italic_suffix: [*:0]const u8 = if (!custom_italic) ":slant=italic" else "";
    const bi_suffix: [*:0]const u8 = if (!custom_bold_italic) ":weight=bold:slant=italic" else "";

    var attrs: [4]?[*:0]u8 = .{ null, null, null, null };
    _ = asprintf(&attrs[0], "%s", &dpi_buf);
    _ = asprintf(&attrs[1], "%s%s", &dpi_buf, bold_suffix);
    _ = asprintf(&attrs[2], "%s%s", &dpi_buf, italic_suffix);
    _ = asprintf(&attrs[3], "%s%s", &dpi_buf, bi_suffix);

    const options: *types.FcftFontOptions = @ptrCast(@alignCast(
        fcft_font_options_create() orelse
            @panic("fcft_font_options_create failed"),
    ));
    configureFontOptions(
        options,
        conf.tweak.fcft_filter,
        terminal_shim_linear_blending(term),
        terminal_shim_grid_is_high_bit_depth(term),
    );

    var fonts: [4]?*anyopaque = .{ null, null, null, null };
    var data: [4]FontLoadData = .{
        .{
            .count = counts[0],
            .names = asConstNames(name_arrays[0].?.ptr),
            .attrs = attrs[0].?,
            .options = options,
            .font = &fonts[0],
        },
        .{
            .count = count_bold,
            .names = names_bold,
            .attrs = attrs[1].?,
            .options = options,
            .font = &fonts[1],
        },
        .{
            .count = count_italic,
            .names = names_italic,
            .attrs = attrs[2].?,
            .options = options,
            .font = &fonts[2],
        },
        .{
            .count = count_bold_italic,
            .names = names_bold_italic,
            .attrs = attrs[3].?,
            .options = options,
            .font = &fonts[3],
        },
    };

    var threads: [4]?std.Thread = .{ null, null, null, null };
    for (0..4) |i| {
        threads[i] = std.Thread.spawn(.{}, fontLoaderThread, .{&data[i]}) catch null;
        if (threads[i] == null) {
            logErr("failed to create font loader thread");
            break;
        }
    }

    var success = true;
    for (0..4) |i| {
        if (threads[i]) |thread| {
            thread.join();
            success = success and data[i].ok;
        } else {
            // A face whose thread was never created cannot have loaded.
            success = false;
        }
    }

    fcft_font_options_destroy(options);

    for (0..4) |i| {
        if (name_arrays[i]) |arr| {
            for (arr) |maybe_name| {
                if (maybe_name) |name|
                    std.c.free(name);
            }
            alloc.free(arr);
        }
        if (attrs[i]) |attr|
            std.c.free(attr);
    }

    if (!success) {
        logErr("failed to load primary fonts");
        for (0..4) |i| {
            fcft_destroy(fonts[i]);
            fonts[i] = null;
        }
    }

    return if (success) term_set_fonts(term, &fonts, resize_grid) else success;
}

export fn load_fonts_from_conf(term: *types.Terminal) callconv(.c) bool {
    const conf = term.conf.?;

    for (0..4) |i| {
        const list = conf.fonts[i];
        const sizes: [*]types.ConfigFont = @ptrCast(term.font_sizes[i].?);

        for (0..list.count) |j| {
            const font = list.arr.?[j];
            sizes[j] = .{
                .pattern = null,
                .pt_size = font.pt_size,
                .px_size = font.px_size,
            };
        }
    }

    return reload_fonts(term, true);
}

//
// Chunk T9d — DPI and subpixel selection.
//
// The policy lives here; the Wayland data it needs now comes straight from
// the struct mirrors (Track B), so no terminal-shim.c accessors remain.
//

/// tll_back() of win->on_outputs: the last output the window is mapped on.
fn windowLastOutput(term: *const types.Terminal) ?*const types.Monitor {
    const win = term.window orelse return null;
    if (win.on_outputs.length == 0)
        return null;

    const node: *const types.TllNode(?*const types.Monitor) =
        @ptrCast(@alignCast(win.on_outputs.tail.?));
    return node.item;
}

/// tll_front() of wayl->monitors: the first available output.
fn firstMonitor(term: *const types.Terminal) ?*types.Monitor {
    const wayl = term.wl orelse return null;
    if (wayl.monitors.length == 0)
        return null;

    const node: *types.TllNode(types.Monitor) =
        @ptrCast(@alignCast(wayl.monitors.head.?));
    return &node.item;
}

fn hasFractionalScaleManager(term: *const types.Terminal) bool {
    const wayl = term.wl orelse return false;
    return wayl.fractional_scale_manager != null and wayl.viewporter != null;
}

fn windowScale(term: *const types.Terminal) f32 {
    const win = term.window orelse return 0.0;
    return win.scale;
}

fn windowPreferredBufferScale(term: *const types.Terminal) c_int {
    const win = term.window orelse return 0;
    return win.preferred_buffer_scale;
}

// fcft_subpixel and wl_output_subpixel have the same ordering, but map
// explicitly: a change in either enum must not silently change rendering.
const FCFT_SUBPIXEL_DEFAULT: c_int = 0;
const FCFT_SUBPIXEL_NONE: c_int = 1;
const FCFT_SUBPIXEL_HORIZONTAL_RGB: c_int = 2;
const FCFT_SUBPIXEL_HORIZONTAL_BGR: c_int = 3;
const FCFT_SUBPIXEL_VERTICAL_RGB: c_int = 4;
const FCFT_SUBPIXEL_VERTICAL_BGR: c_int = 5;

const WL_OUTPUT_SUBPIXEL_UNKNOWN: c_int = 0;
const WL_OUTPUT_SUBPIXEL_NONE: c_int = 1;
const WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB: c_int = 2;
const WL_OUTPUT_SUBPIXEL_HORIZONTAL_BGR: c_int = 3;
const WL_OUTPUT_SUBPIXEL_VERTICAL_RGB: c_int = 4;
const WL_OUTPUT_SUBPIXEL_VERTICAL_BGR: c_int = 5;

export fn term_fractional_scaling(term: *const types.Terminal) callconv(.c) bool {
    return hasFractionalScaleManager(term) and
        windowScale(term) > 0.0;
}

export fn term_preferred_buffer_scale(term: *const types.Terminal) callconv(.c) bool {
    return windowPreferredBufferScale(term) > 0;
}

fn getFontDpi(term: *const types.Terminal) f32 {
    var mon = windowLastOutput(term);

    if (mon == null) {
        // Prefer the last known good DPI; avoids flicker when a window is
        // unmapped/remapped on a mixed-DPI setup.
        if (term.font_dpi_before_unmap > 0.0)
            return term.font_dpi_before_unmap;

        mon = firstMonitor(term);
    }

    const monitor_dpi: f32 = if (mon) |m|
        if (term_fractional_scaling(term))
            m.dpi.physical
        else
            m.dpi.scaled
    else
        96.0;

    return if (monitor_dpi > 0.0) monitor_dpi else 96.0;
}

export fn get_font_dpi(term: *const types.Terminal) callconv(.c) f32 {
    return getFontDpi(term);
}

fn getFontSubpixel(term: *const types.Terminal) c_int {
    // Can't do subpixel rendering on a transparent background.
    if (term.colors.alpha != 0xffff)
        return FCFT_SUBPIXEL_NONE;

    var wl_subpixel: c_int = undefined;

    if (windowLastOutput(term)) |m|
        wl_subpixel = @intFromEnum(m.subpixel)
    else if (firstMonitor(term)) |m|
        wl_subpixel = @intFromEnum(m.subpixel)
    else
        wl_subpixel = WL_OUTPUT_SUBPIXEL_UNKNOWN;

    return switch (wl_subpixel) {
        WL_OUTPUT_SUBPIXEL_UNKNOWN => FCFT_SUBPIXEL_DEFAULT,
        WL_OUTPUT_SUBPIXEL_NONE => FCFT_SUBPIXEL_NONE,
        WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB => FCFT_SUBPIXEL_HORIZONTAL_RGB,
        WL_OUTPUT_SUBPIXEL_HORIZONTAL_BGR => FCFT_SUBPIXEL_HORIZONTAL_BGR,
        WL_OUTPUT_SUBPIXEL_VERTICAL_RGB => FCFT_SUBPIXEL_VERTICAL_RGB,
        WL_OUTPUT_SUBPIXEL_VERTICAL_BGR => FCFT_SUBPIXEL_VERTICAL_BGR,
        else => FCFT_SUBPIXEL_DEFAULT,
    };
}

export fn get_font_subpixel(term: *const types.Terminal) callconv(.c) c_int {
    return getFontSubpixel(term);
}

export fn term_update_scale(term: *types.Terminal) callconv(.c) bool {
    const new_scale: f32 = if (term_fractional_scaling(term))
        windowScale(term)
    else if (term_preferred_buffer_scale(term))
        @floatFromInt(windowPreferredBufferScale(term))
    else if (windowLastOutput(term)) |m|
        @floatFromInt(m.scale)
    else if (term.scale_before_unmap > 0.0)
        term.scale_before_unmap
    else if (firstMonitor(term)) |m|
        @floatFromInt(m.scale)
    else
        1.0;

    if (new_scale == term.scale)
        return false;

    term.scale_before_unmap = new_scale;
    term.scale = new_scale;
    return true;
}

export fn term_font_dpi_changed(term: *types.Terminal, old_scale: f32) callconv(.c) bool {
    const dpi = getFontDpi(term);
    std.debug.assert(term.scale > 0.0);

    const was_scaled_using_dpi = term.font_is_sized_by_dpi;
    const will_scale_using_dpi = term.conf.?.dpi_aware;

    const need_font_reload = was_scaled_using_dpi != will_scale_using_dpi or
        (if (will_scale_using_dpi)
            term.font_dpi != dpi
        else
            old_scale != term.scale);

    term.font_dpi = dpi;
    term.font_dpi_before_unmap = dpi;
    term.font_is_sized_by_dpi = will_scale_using_dpi;

    if (!need_font_reload)
        return false;

    return reload_fonts(term, false);
}

export fn term_font_subpixel_changed(term: *types.Terminal) callconv(.c) void {
    const subpixel = getFontSubpixel(term);

    if (term.font_subpixel == subpixel)
        return;

    term.font_subpixel = subpixel;
    term_damage_view(term);
    render_refresh(term);
}

//
// Chunk T10a — font-size adjustments (the fontSize shortcuts). These only
// mutate the runtime font sizes and reload; the configured fonts are left
// untouched so a reset can restore them.
//

fn fontSizeList(term: *types.Terminal, i: usize) [*]types.ConfigFont {
    return @ptrCast(term.font_sizes[i].?);
}

fn adjustFontSizeByPoints(term: *types.Terminal, amount: f32) bool {
    const conf = term.conf.?;
    const dpi: f32 = if (term.font_is_sized_by_dpi) term.font_dpi else 96.0;

    for (0..4) |i| {
        const list = conf.fonts[i];
        const sizes = fontSizeList(term, i);

        for (0..list.count) |j| {
            var old_pt_size = sizes[j].pt_size;

            if (sizes[j].px_size > 0)
                old_pt_size = @as(f32, @floatFromInt(sizes[j].px_size)) * 72.0 / dpi;

            sizes[j].pt_size = @max(old_pt_size + amount, 0.0);
            sizes[j].px_size = -1;
        }
    }

    return reload_fonts(term, true);
}

fn adjustFontSizeByPixels(term: *types.Terminal, amount: c_int) bool {
    const conf = term.conf.?;
    const dpi: f32 = if (term.font_is_sized_by_dpi) term.font_dpi else 96.0;

    for (0..4) |i| {
        const list = conf.fonts[i];
        const sizes = fontSizeList(term, i);

        for (0..list.count) |j| {
            var old_px_size = sizes[j].px_size;

            if (sizes[j].px_size <= 0)
                old_px_size = @intFromFloat(sizes[j].pt_size * dpi / 72.0);

            sizes[j].px_size = @max(old_px_size + amount, 1);
        }
    }

    return reload_fonts(term, true);
}

fn adjustFontSizeByPercent(term: *types.Terminal, increment: bool, percent: f32) bool {
    const conf = term.conf.?;
    const multiplier: f32 = if (increment) 1.0 + percent else 1.0 / (1.0 + percent);

    for (0..4) |i| {
        const list = conf.fonts[i];
        const sizes = fontSizeList(term, i);

        for (0..list.count) |j| {
            if (sizes[j].px_size > 0) {
                const scaled = @as(f32, @floatFromInt(sizes[j].px_size)) * multiplier;
                sizes[j].px_size = @intFromFloat(@max(scaled, 1.0));
            } else {
                sizes[j].pt_size = @max(sizes[j].pt_size * multiplier, 0.0);
            }
        }
    }

    return reload_fonts(term, true);
}

export fn term_font_size_increase(term: *types.Terminal) callconv(.c) bool {
    const inc_dec = term.conf.?.font_size_adjustment;

    if (inc_dec.percent > 0.0)
        return adjustFontSizeByPercent(term, true, inc_dec.percent)
    else if (inc_dec.pt_or_px.px > 0)
        return adjustFontSizeByPixels(term, inc_dec.pt_or_px.px)
    else
        return adjustFontSizeByPoints(term, inc_dec.pt_or_px.pt);
}

export fn term_font_size_decrease(term: *types.Terminal) callconv(.c) bool {
    const inc_dec = term.conf.?.font_size_adjustment;

    if (inc_dec.percent > 0.0)
        return adjustFontSizeByPercent(term, false, inc_dec.percent)
    else if (inc_dec.pt_or_px.px > 0)
        return adjustFontSizeByPixels(term, -inc_dec.pt_or_px.px)
    else
        return adjustFontSizeByPoints(term, -inc_dec.pt_or_px.pt);
}

export fn term_font_size_reset(term: *types.Terminal) callconv(.c) bool {
    return load_fonts_from_conf(term);
}

fn termResetGraphemeState(term: *types.Terminal) void {
    // Without utf8proc the fields don't exist in `struct vt` and C's
    // term_reset_grapheme_state() is a no-op; keep `term` "used" so the
    // helper still compiles in that configuration.
    if (comptime build_options.grapheme_clustering) {
        term.vt.grapheme_state = 0;
        term.vt.codepoint_merging_ok = false;
    } else {
        _ = @intFromPtr(term);
    }
}

export fn term_cursor_to(
    term: *types.Terminal,
    row_index: c_int,
    col: c_int,
) void {
    std.debug.assert(row_index < term.rows);
    std.debug.assert(col < term.cols);

    term.grid.?.cursor.lcf = false;
    term.grid.?.cursor.point.col = col;
    term.grid.?.cursor.point.row = row_index;

    termResetGraphemeState(term);

    term.grid.?.cur_row = row(term.grid.?, row_index);
}

export fn term_cursor_home(term: *types.Terminal) void {
    term_cursor_to(term, term_row_rel_to_abs(term, 0), 0);
}

export fn term_cursor_col(term: *types.Terminal, col: c_int) void {
    std.debug.assert(col < term.cols);

    term.grid.?.cursor.lcf = false;
    term.grid.?.cursor.point.col = col;
    termResetGraphemeState(term);
}

export fn term_cursor_left(term: *types.Terminal, count: c_int) void {
    const move_amount = @min(term.grid.?.cursor.point.col, count);
    term.grid.?.cursor.point.col -= move_amount;
    std.debug.assert(term.grid.?.cursor.point.col >= 0);
    term.grid.?.cursor.lcf = false;
    termResetGraphemeState(term);
}

export fn term_cursor_right(term: *types.Terminal, count: c_int) void {
    const move_amount = @min(
        term.cols - term.grid.?.cursor.point.col - 1,
        count,
    );
    term.grid.?.cursor.point.col += move_amount;
    std.debug.assert(term.grid.?.cursor.point.col < term.cols);
    term.grid.?.cursor.lcf = false;
    termResetGraphemeState(term);
}

export fn term_cursor_up(term: *types.Terminal, count: c_int) void {
    const top: c_int =
        if (term.origin == .absolute) 0 else term.scroll_region.start;

    // C xassert()s `cursor.row >= top` here. That state is reachable from
    // hostile input: set a scroll region on the normal screen, switch to the
    // alt screen (the region survives the switch, the cursor row does not),
    // then send ESC M. C's debug build aborts too, but its release build has
    // the assert compiled out, computes a negative move amount and carries on.
    // Drop the trap so Debug/ReleaseSafe match C release instead of crashing
    // (fuzz seed 58).

    const move_amount = @min(
        term.grid.?.cursor.point.row - top,
        count,
    );
    term_cursor_to(
        term,
        term.grid.?.cursor.point.row - move_amount,
        term.grid.?.cursor.point.col,
    );
}

export fn term_cursor_down(term: *types.Terminal, count: c_int) void {
    const bottom: c_int =
        if (term.origin == .absolute) term.rows else term.scroll_region.end;

    // Same trap, same reason, as term_cursor_up(): C only has this assert in
    // builds without NDEBUG, and the mirror state (region without its cursor)
    // is reachable from input.

    const move_amount = @min(
        bottom - term.grid.?.cursor.point.row - 1,
        count,
    );
    term_cursor_to(
        term,
        term.grid.?.cursor.point.row + move_amount,
        term.grid.?.cursor.point.col,
    );
}

fn damageRows(term: *types.Terminal, start: c_int, end: c_int) void {
    std.debug.assert(start <= end);

    var r = start;
    while (r <= end) : (r += 1) {
        const current_row = row(term.grid.?, r);
        current_row.dirty = true;

        var c: c_int = 0;
        while (c < term.grid.?.num_cols) : (c += 1) {
            current_row.cells.?[@intCast(c)].attrs.clean = false;
        }
    }
}

fn damageRowsInView(term: *types.Terminal, start: c_int, end: c_int) void {
    std.debug.assert(start <= end);

    var r = start;
    while (r <= end) : (r += 1) {
        const current_row = rowInView(term.grid.?, r);
        current_row.dirty = true;

        var c: c_int = 0;
        while (c < term.grid.?.num_cols) : (c += 1) {
            current_row.cells.?[@intCast(c)].attrs.clean = false;
        }
    }
}

export fn term_damage_rows(term: *types.Terminal, start: c_int, end: c_int) void {
    damageRows(term, start, end);
}

export fn term_damage_rows_in_view(
    term: *types.Terminal,
    start: c_int,
    end: c_int,
) void {
    damageRowsInView(term, start, end);
}

export fn term_damage_all(term: *types.Terminal) void {
    damageRows(term, 0, term.rows - 1);
}

export fn term_damage_view(term: *types.Terminal) void {
    damageRowsInView(term, 0, term.rows - 1);
}

export fn term_damage_cursor(term: *types.Terminal) void {
    const grid = term.grid.?;
    const current_row = grid.cur_row.?;
    const col: usize = @intCast(grid.cursor.point.col);

    current_row.cells.?[col].attrs.clean = false;
    current_row.dirty = true;
}

export fn term_damage_margins(term: *types.Terminal) void {
    term.render.margins = true;
}

fn damagePushBack(list: *types.DamageList, item: types.Damage) void {
    const node: *types.DamageNode = @ptrCast(@alignCast(std.c.malloc(@sizeOf(types.DamageNode)) orelse unreachable));
    node.* = .{ .item = item, .prev = list.tail, .next = null };
    if (list.tail) |tail| {
        tail.next = node;
    } else {
        list.head = node;
    }
    list.tail = node;
    list.length += 1;
}

export fn term_damage_color(
    term: *types.Terminal,
    src: types.ColorSource,
    idx: c_int,
) void {
    std.debug.assert(src == .default or src == .base256);

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const current_row = rowInView(term.grid.?, r);
        var c: c_int = 0;

        while (c < term.cols) : (c += 1) {
            const cell = &current_row.cells.?[@intCast(c)];
            var dirty = false;

            switch (cell.attrs.fg_src) {
                1, 2 => {
                    if (src == .base256 and
                        cell.attrs.fg == @as(u24, @intCast(idx)))
                    {
                        dirty = true;
                    }
                },
                0 => {
                    if (src == .default)
                        dirty = true;
                },
                3 => {},
            }

            switch (cell.attrs.bg_src) {
                1, 2 => {
                    if (src == .base256 and
                        cell.attrs.bg == @as(u24, @intCast(idx)))
                    {
                        dirty = true;
                    }
                },
                0 => {
                    if (src == .default)
                        dirty = true;
                },
                3 => {},
            }

            if (dirty) {
                cell.attrs.clean = false;
                current_row.dirty = true;
            }
        }

        if (current_row.extra) |extra| {
            const underlines = &extra.underline_ranges;
            var i: c_int = 0;

            while (i < underlines.count) : (i += 1) {
                const range = &underlines.v.?[@intCast(i)];

                std.debug.assert(
                    range.data.underline.color_src == .default or
                        range.data.underline.color_src == .base256 or
                        range.data.underline.color_src == .rgb,
                );

                if (range.data.underline.color_src == src) {
                    var c2: c_int = range.start;
                    while (c2 <= range.end) : (c2 += 1) {
                        current_row.cells.?[@intCast(c2)].attrs.clean = false;
                    }

                    current_row.dirty = true;
                }
            }
        }
    }
}

export fn term_damage_scroll(
    term: *types.Terminal,
    damage_type: types.DamageType,
    region: types.ScrollRegion,
    lines: c_int,
) void {
    if (term.grid.?.scroll_damage.length > 0) {
        const dmg = &term.grid.?.scroll_damage.tail.?.item;

        if (dmg.type == damage_type and
            dmg.region.start == region.start and
            dmg.region.end == region.end)
        {
            const new_line_count = @as(c_int, @intCast(dmg.lines)) + lines;
            if (new_line_count <= std.math.maxInt(u16)) {
                dmg.lines = @intCast(new_line_count);
                return;
            }
        }
    }

    damagePushBack(&term.grid.?.scroll_damage, .{
        .type = damage_type,
        .region = region,
        .lines = @intCast(lines),
    });
}

export fn term_carriage_return(term: *types.Terminal) void {
    term_cursor_left(term, term.grid.?.cursor.point.col);
}

export fn term_reset_view(term: *types.Terminal) void {
    if (term.grid.?.view == term.grid.?.offset)
        return;

    term.grid.?.view = term.grid.?.offset;
    term_damage_view(term);
}

export fn term_save_cursor(term: *types.Terminal) void {
    term.grid.?.saved_cursor = term.grid.?.cursor;
    term.grid.?.saved_attrs = term.vt.attrs;
    term.saved_charsets = term.charsets;
}

export fn term_visual_focus_in(term: *types.Terminal) void {
    if (term.visual_focus)
        return;

    term.visual_focus = true;
    term_cursor_blink_update(term);
    render_refresh_csd(term);
}

export fn term_visual_focus_out(term: *types.Terminal) void {
    if (!term.visual_focus)
        return;

    term.visual_focus = false;
    term_cursor_blink_update(term);
    render_refresh_csd(term);
}

export fn term_restore_cursor(
    term: *types.Terminal,
    cursor: *const types.Cursor,
) void {
    const row_index = @min(cursor.point.row, term.rows - 1);
    const col = @min(cursor.point.col, term.cols - 1);

    term_cursor_to(term, row_index, col);
    term.grid.?.cursor.lcf = cursor.lcf;

    term.vt.attrs = term.grid.?.saved_attrs;
    term.charsets = term.saved_charsets;

    term.bits_affecting_ascii_printer.value =
        if (term.charsets.set[@intCast(@intFromEnum(term.charsets.selected))] != .ascii) 1 else 0;
    term_update_ascii_printer(term);
}

// ── Chunk A: term_row_rel_to_abs + blink/flash timers ────────────

extern fn render_overlay(term: *types.Terminal) callconv(.c) void;
extern fn fdm_add(fdm: *anyopaque, fd: c_int, events: c_int, handler: *const fn (*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) bool, data: ?*anyopaque) callconv(.c) bool;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;
extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
extern fn timerfd_settime(fd: c_int, flags: c_int, new_value: *const types.Itimerspec, old_value: ?*types.Itimerspec) callconv(.c) c_int;
extern fn read(fd: c_int, buf: *anyopaque, count: usize) callconv(.c) isize;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn __errno_location() callconv(.c) *c_int;
extern fn terminal_shim_grid_row_in_view(grid: *types.Grid, row: c_int) callconv(.c) ?*types.Row;
extern fn terminal_shim_wl_surface_commit(surf: ?*anyopaque) callconv(.c) void;

const EPOLLIN: c_int = 0x001;
const EPOLLHUP: c_int = 0x010;
const EAGAIN: c_int = 11;
const CLOCK_MONOTONIC: c_int = 1;
const TFD_CLOEXEC: c_int = 0x80000;
const TFD_NONBLOCK: c_int = 0x800;

// blink state: BLINK_ON=0, BLINK_OFF=1 in C
// cursor_blink state: CURSOR_BLINK_ON=0, CURSOR_BLINK_OFF=1
const CURSOR_BLINK_ON: c_int = 0;
const CURSOR_BLINK_OFF: c_int = 1;

// ── term_row_rel_to_abs ─────────────────────────────────────────
export fn term_row_rel_to_abs(term: *const types.Terminal, row_in: c_int) callconv(.c) c_int {
    return switch (term.origin) {
        .absolute => @min(row_in, term.rows - 1),
        .relative => @min(row_in + term.scroll_region.start, term.scroll_region.end - 1),
    };
}

// ── fdm_flash ───────────────────────────────────────────────────
export fn fdm_flash(fdm_opaque: *anyopaque, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm_opaque;
    _ = fd;
    if (events & EPOLLHUP != 0) return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    var expiration_count: u64 = 0;
    const ret = read(term.flash.fd, &expiration_count, @sizeOf(u64));
    if (ret < 0) {
        if (__errno_location().* == EAGAIN) return true;
        return false;
    }

    term.flash.active = false;
    render_overlay(term);

    if (term.window) |win|
        terminal_shim_wl_surface_commit(win.surface.surf);
    return true;
}

// ── fdm_blink ───────────────────────────────────────────────────
fn fdm_blink(fdm_opaque: *anyopaque, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm_opaque;
    _ = fd;
    if (events & EPOLLHUP != 0) return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    var expiration_count: u64 = 0;
    const ret = read(term.blink.fd, &expiration_count, @sizeOf(u64));
    if (ret < 0) {
        if (__errno_location().* == EAGAIN) return true;
        return false;
    }

    term.blink.state = if (term.blink.state == .on) .off else .on;

    var no_blinking_cells = true;
    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const current_row = terminal_shim_grid_row_in_view(term.grid.?, r) orelse continue;
        var col: c_int = 0;
        while (col < term.cols) : (col += 1) {
            const cell = &current_row.cells.?[@intCast(col)];
            if (cell.attrs.blink) {
                cell.attrs.clean = false;
                current_row.dirty = true;
                no_blinking_cells = false;
            }
        }
    }

    if (no_blinking_cells) {
        term.blink.state = .on;
        _ = fdm_del(term.fdm orelse return true, term.blink.fd);
        term.blink.fd = -1;
    } else {
        render_refresh(term);
    }
    return true;
}

// ── term_arm_blink_timer ────────────────────────────────────────
export fn term_arm_blink_timer(term: *types.Terminal) callconv(.c) void {
    if (term.blink.fd >= 0) return;

    const fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (fd < 0) return;

    if (!fdm_add(term.fdm orelse return, fd, EPOLLIN, &fdm_blink, term)) {
        _ = close(fd);
        return;
    }

    const timer: types.Itimerspec = .{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 500 * 1_000_000 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 500 * 1_000_000 },
    };

    if (timerfd_settime(fd, 0, &timer, null) < 0) {
        _ = fdm_del(term.fdm orelse return, fd);
    }

    term.blink.fd = fd;
}

// ── cursor_refresh ──────────────────────────────────────────────
export fn cursor_refresh(term: *types.Terminal) callconv(.c) void {
    const win = term.window orelse return;
    if (!win.is_configured) return;
    if (term.shutdown.in_progress) return;

    const grid = term.grid.?;
    const cur_row = grid.cur_row orelse return;
    const col: usize = @intCast(grid.cursor.point.col);
    cur_row.cells.?[col].attrs.clean = false;
    cur_row.dirty = true;
    render_refresh(term);
}

// ── fdm_cursor_blink ────────────────────────────────────────────
fn fdm_cursor_blink(fdm_opaque: *anyopaque, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm_opaque;
    _ = fd;
    if (events & EPOLLHUP != 0) return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    var expiration_count: u64 = 0;
    const ret = read(term.cursor_blink.fd, &expiration_count, @sizeOf(u64));
    if (ret < 0) {
        if (__errno_location().* == EAGAIN) return true;
        return false;
    }

    term.cursor_blink.state = if (term.cursor_blink.state == CURSOR_BLINK_ON)
        CURSOR_BLINK_OFF
    else
        CURSOR_BLINK_ON;

    cursor_refresh(term);
    return true;
}

// ── cursor_blink_rearm/disarm + term_cursor_blink_update ────────
export fn cursor_blink_rearm_timer(term: *types.Terminal) callconv(.c) bool {
    if (term.cursor_blink.fd < 0) {
        const fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        if (fd < 0) return false;

        if (!fdm_add(term.fdm orelse return false, fd, EPOLLIN, &fdm_cursor_blink, term)) {
            _ = close(fd);
            return false;
        }
        term.cursor_blink.fd = fd;
    }

    const rate_ms = term.conf.?.cursor.blink.rate_ms;
    const secs: i64 = @divTrunc(@as(i64, rate_ms), 1000);
    const nsecs: i64 = @mod(@as(i64, rate_ms), 1000) * 1_000_000;

    const timer: types.Itimerspec = .{
        .it_value = .{ .tv_sec = secs, .tv_nsec = nsecs },
        .it_interval = .{ .tv_sec = secs, .tv_nsec = nsecs },
    };

    if (timerfd_settime(term.cursor_blink.fd, 0, &timer, null) < 0) {
        _ = fdm_del(term.fdm orelse return false, term.cursor_blink.fd);
        term.cursor_blink.fd = -1;
        return false;
    }
    return true;
}

export fn cursor_blink_disarm_timer(term: *types.Terminal) callconv(.c) bool {
    _ = fdm_del(term.fdm orelse return true, term.cursor_blink.fd);
    term.cursor_blink.fd = -1;
    return true;
}

export fn term_cursor_blink_update(term: *types.Terminal) callconv(.c) void {
    const enable = term.cursor_blink.decset or term.cursor_blink.deccsusr;
    const activate = !term.shutdown.in_progress and enable and term.visual_focus;

    if (activate and term.cursor_blink.fd < 0) {
        term.cursor_blink.state = CURSOR_BLINK_ON;
        _ = cursor_blink_rearm_timer(term);
    } else if (!activate and term.cursor_blink.fd >= 0) {
        _ = cursor_blink_disarm_timer(term);
    }
}

// ── Chunk B: scroll family ──────────────────────────────────────
// term_scroll_partial / term_scroll / term_scroll_reverse_partial /
// term_scroll_reverse / term_linefeed / term_reverse_index.

extern fn selection_cancel(term: *types.Terminal) callconv(.c) void;
extern fn selection_get_start(term: *const types.Terminal) callconv(.c) types.Coord;
extern fn selection_get_end(term: *const types.Terminal) callconv(.c) types.Coord;
extern fn selection_on_rows(term: *const types.Terminal, start: c_int, end: c_int) callconv(.c) bool;
extern fn selection_scroll_up(term: *types.Terminal, rows: c_int) callconv(.c) void;
extern fn selection_scroll_down(term: *types.Terminal, rows: c_int) callconv(.c) void;
extern fn selection_view_up(term: *types.Terminal, new_view: c_int) callconv(.c) void;
extern fn selection_view_down(term: *types.Terminal, new_view: c_int) callconv(.c) void;

extern fn sixel_scroll_up(term: *types.Terminal, rows: c_int) callconv(.c) void;
extern fn sixel_scroll_down(term: *types.Terminal, rows: c_int) callconv(.c) void;

extern fn grid_row_abs_to_sb(grid: *const types.Grid, screen_rows: c_int, abs_row: c_int) callconv(.c) c_int;
extern fn grid_row_sb_to_abs(grid: *const types.Grid, screen_rows: c_int, sb_rel_row: c_int) callconv(.c) c_int;
extern fn grid_swap_row(grid: *types.Grid, row_a: c_int, row_b: c_int) callconv(.c) void;
extern fn grid_row_free(r: ?*types.Row) callconv(.c) void;
extern fn grid_row_uri_range_erase(row: *types.Row, start: c_int, end: c_int) callconv(.c) void;
extern fn grid_row_underline_range_erase(row: *types.Row, start: c_int, end: c_int) callconv(.c) void;

extern fn terminal_shim_grid_row_and_alloc(grid: *types.Grid, row_no: c_int) callconv(.c) ?*types.Row;
extern fn terminal_shim_grid_row_absolute(grid: *types.Grid, row_no: c_int) callconv(.c) c_int;
extern fn terminal_shim_erase_line(term: *types.Terminal, row: *types.Row) callconv(.c) void;
extern fn terminal_shim_grid_row(grid: *types.Grid, row_no: c_int) callconv(.c) ?*types.Row;
extern fn terminal_shim_term_reset_grapheme_state(term: *types.Terminal) callconv(.c) void;

extern fn cmd_scrollback_down(term: *types.Terminal, rows: u64) callconv(.c) void;

fn selection_on_top_region(term: *const types.Terminal, region: types.ScrollRegion) bool {
    return region.start > 0 and selection_on_rows(term, 0, region.start - 1);
}

fn selection_on_bottom_region(term: *const types.Terminal, region: types.ScrollRegion) bool {
    return region.end < term.rows and selection_on_rows(term, region.end, term.rows - 1);
}

// DAMAGE_SCROLL / DAMAGE_SCROLL_REVERSE enum values from terminal.h
const DAMAGE_SCROLL: types.DamageType = .scroll;
const DAMAGE_SCROLL_REVERSE: types.DamageType = .scroll_reverse;

export fn term_scroll_partial(
    term: *types.Terminal,
    region: types.ScrollRegion,
    rows: c_int,
) callconv(.c) void {
    if (term.selection.coords.end.row >= 0) {
        if (selection_on_top_region(term, region) or
            selection_on_bottom_region(term, region))
        {
            selection_cancel(term);
        } else {
            selection_scroll_up(term, rows);
        }
    }

    sixel_scroll_up(term, rows);

    const view_sb_start_distance = grid_row_abs_to_sb(term.grid.?, term.rows, term.grid.?.view);

    const view_follows = term.grid.?.view == term.grid.?.offset;
    term.grid.?.offset += rows;
    term.grid.?.offset &= term.grid.?.num_rows - 1;

    if (view_follows) {
        term_damage_scroll(term, DAMAGE_SCROLL, region, rows);
        selection_view_down(term, term.grid.?.offset);
        term.grid.?.view = term.grid.?.offset;
    } else if (rows > view_sb_start_distance) {
        const new_view = grid_row_sb_to_abs(term.grid.?, term.rows, 0);
        selection_view_down(term, new_view);
        cmd_scrollback_down(term, @intCast(rows - view_sb_start_distance));
    }

    var i: c_int = region.start - 1;
    while (i >= 0) : (i -= 1) {
        grid_swap_row(term.grid.?, i - rows, i);
    }

    i = term.rows - 1;
    while (i >= region.end) : (i -= 1) {
        grid_swap_row(term.grid.?, i - rows, i);
    }

    var r: c_int = region.end - rows;
    while (r < region.end) : (r += 1) {
        const current_row = terminal_shim_grid_row_and_alloc(term.grid.?, r) orelse continue;
        terminal_shim_erase_line(term, current_row);
    }

    term.grid.?.cur_row = terminal_shim_grid_row(term.grid.?, term.grid.?.cursor.point.row);
}

export fn term_scroll(term: *types.Terminal, rows: c_int) callconv(.c) void {
    term_scroll_partial(term, term.scroll_region, rows);
}

export fn term_scroll_reverse_partial(
    term: *types.Terminal,
    region: types.ScrollRegion,
    rows: c_int,
) callconv(.c) void {
    if (term.selection.coords.end.row >= 0) {
        if (selection_on_top_region(term, region) or
            selection_on_bottom_region(term, region))
        {
            selection_cancel(term);
        } else {
            selection_scroll_down(term, rows);
        }
    }

    var r: c_int = region.end - rows;
    while (r < region.end) : (r += 1) {
        const abs_r = terminal_shim_grid_row_absolute(term.grid.?, r);
        const current_row = term.grid.?.rows.?[@intCast(abs_r)];

        grid_row_free(current_row);
        term.grid.?.rows.?[@intCast(abs_r)] = null;

        // The rendered cursor may still point at the row we just freed;
        // render.zig dereferences this in the next frame.
        if (term.render.last_cursor.row == current_row)
            term.render.last_cursor.row = null;
    }

    sixel_scroll_down(term, rows);

    const view_follows = term.grid.?.view == term.grid.?.offset;
    term.grid.?.offset -= rows;
    term.grid.?.offset += term.grid.?.num_rows;
    term.grid.?.offset &= term.grid.?.num_rows - 1;

    const view_sb_start_distance = grid_row_abs_to_sb(term.grid.?, term.rows, term.grid.?.view);
    const offset_sb_start_distance = grid_row_abs_to_sb(term.grid.?, term.rows, term.grid.?.offset);

    if (view_follows) {
        term_damage_scroll(term, DAMAGE_SCROLL_REVERSE, region, rows);
        selection_view_up(term, term.grid.?.offset);
        term.grid.?.view = term.grid.?.offset;
    } else if (view_sb_start_distance > offset_sb_start_distance) {
        const new_view = term.grid.?.offset;
        selection_view_up(term, new_view);
        term.grid.?.view = new_view;
    }

    var i: c_int = region.end + rows;
    while (i < term.rows + rows) : (i += 1) {
        grid_swap_row(term.grid.?, i, i - rows);
    }

    i = 0 + rows;
    while (i < region.start + rows) : (i += 1) {
        grid_swap_row(term.grid.?, i, i - rows);
    }

    r = region.start;
    while (r < region.start + rows) : (r += 1) {
        const current_row = terminal_shim_grid_row_and_alloc(term.grid.?, r) orelse continue;
        terminal_shim_erase_line(term, current_row);
    }

    if (view_sb_start_distance > offset_sb_start_distance) {
        term_damage_view(term);
    }

    term.grid.?.cur_row = terminal_shim_grid_row(term.grid.?, term.grid.?.cursor.point.row);
}

export fn term_scroll_reverse(term: *types.Terminal, rows: c_int) callconv(.c) void {
    term_scroll_reverse_partial(term, term.scroll_region, rows);
}

export fn term_linefeed(term: *types.Terminal) callconv(.c) void {
    term.grid.?.cursor.lcf = false;

    if (term.grid.?.cursor.point.row == term.scroll_region.end - 1) {
        term_scroll(term, 1);
    } else {
        term_cursor_down(term, 1);
    }

    terminal_shim_term_reset_grapheme_state(term);
}

export fn term_reverse_index(term: *types.Terminal) callconv(.c) void {
    if (term.grid.?.cursor.point.row == term.scroll_region.start) {
        term_scroll_reverse(term, 1);
    } else {
        term_cursor_up(term, 1);
    }
}

// ── Chunk C1: term_erase / term_fill / term_print / print_spacer ─
// Hot path. Depends on grid row access, URI/underline ranges, the
// print_linewrap/print_insert helpers below, and sixel_overwrite_* (sixel.zig).

extern fn grid_row_uri_range_put(row: *types.Row, col: c_int, uri: [*:0]const u8, id: u64) callconv(.c) void;
extern fn grid_row_underline_range_put(row: *types.Row, col: c_int, range: types.UnderlineRangeData) callconv(.c) void;

extern fn sixel_overwrite_by_row(term: *types.Terminal, row: c_int, col: c_int, width: c_int) callconv(.c) void;
extern fn sixel_overwrite_by_rectangle(term: *types.Terminal, row: c_int, col: c_int, height: c_int, width: c_int) callconv(.c) void;
extern fn sixel_overwrite_at_cursor(term: *types.Terminal, width: c_int) callconv(.c) void;

export fn term_erase(
    term: *types.Terminal,
    start_row: c_int,
    start_col: c_int,
    end_row: c_int,
    end_col: c_int,
) callconv(.c) void {
    if (start_row == end_row) {
        const current_row = terminal_shim_grid_row(term.grid.?, start_row) orelse return;
        erase_cell_range(term, current_row, start_col, end_col);
        sixel_overwrite_by_row(term, start_row, start_col, end_col - start_col + 1);
        return;
    }

    const row0 = terminal_shim_grid_row(term.grid.?, start_row) orelse return;
    erase_cell_range(term, row0, start_col, term.cols - 1);
    sixel_overwrite_by_row(term, start_row, start_col, term.cols - start_col);

    var r: c_int = start_row + 1;
    while (r < end_row) : (r += 1) {
        const current_row = terminal_shim_grid_row(term.grid.?, r) orelse continue;
        terminal_shim_erase_line(term, current_row);
    }
    sixel_overwrite_by_rectangle(term, start_row + 1, 0, end_row - start_row, term.cols);

    const row_end = terminal_shim_grid_row(term.grid.?, end_row) orelse return;
    erase_cell_range(term, row_end, 0, end_col);
    sixel_overwrite_by_row(term, end_row, 0, end_col + 1);
}

export fn print_spacer(term: *types.Terminal, col: c_int, remaining: c_int) callconv(.c) void {
    const current_row = term.grid.?.cur_row orelse return;
    const cell = &current_row.cells.?[@intCast(col)];
    cell.wc = CELL_SPACER_CONST + @as(u32, @intCast(remaining));
    cell.attrs = std.mem.zeroes(types.Attributes);
}

const CELL_SPACER_CONST: u32 = 0x00200000 + 0x3fffffff + 1;

export fn term_fill(
    term: *types.Terminal,
    r: c_int,
    c: c_int,
    data: u8,
    count: usize,
    use_sgr_attrs: bool,
) callconv(.c) void {
    const current_row = terminal_shim_grid_row(term.grid.?, r) orelse return;
    current_row.dirty = true;

    const attrs = if (use_sgr_attrs) term.vt.attrs else std.mem.zeroes(types.Attributes);

    const osc8_underline = term.conf.?.url.osc8_underline;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const cell = &current_row.cells.?[@intCast(c + @as(c_int, @intCast(i)))];

        cell.wc = data;
        cell.attrs = attrs;

        if (use_sgr_attrs and term.vt.osc8.uri != null) {
            grid_row_uri_range_put(
                current_row,
                c,
                @ptrCast(term.vt.osc8.uri.?),
                term.vt.osc8.id,
            );

            if (osc8_underline == .always) {
                cell.attrs.url = true;
            }
        }

        if (use_sgr_attrs and
            (term.vt.underline.style != .none and term.vt.underline.style != .single or
                term.vt.underline.color_src != .default))
        {
            grid_row_underline_range_put(current_row, c, term.vt.underline);
        }
    }

    if (current_row.extra != null) {
        if (term.vt.osc8.uri != null) {
            grid_row_uri_range_erase(
                current_row,
                c,
                c + @as(c_int, @intCast(count)) - 1,
            );
        }

        if ((term.vt.underline.style == .none or term.vt.underline.style == .single) and
            term.vt.underline.color_src == .default)
        {
            grid_row_underline_range_erase(
                current_row,
                c,
                c + @as(c_int, @intCast(count)) - 1,
            );
        }
    }
}

export fn term_print(
    term: *types.Terminal,
    wc_in: u32,
    width: c_int,
    insert_mode_disable: bool,
) callconv(.c) void {
    var wc = wc_in;

    const grid = term.grid.?;

    if (term.charsets.set[@intCast(@intFromEnum(term.charsets.selected))] == .graphic and
        wc >= 0x60 and wc <= 0x7e)
    {
        const vt100_0 = [31]u32{
            0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1,
            0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA,
            0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C,
            0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
        };
        wc = vt100_0[wc - 0x60];
    }

    print_linewrap(term);
    if (!insert_mode_disable) print_insert(term, width);

    var col = grid.cursor.point.col;

    if (width > 1 and term.auto_margin and col + width > term.cols) {
        var i: c_int = col;
        while (i < term.cols) : (i += 1) {
            print_spacer(term, i, 0);
        }
        grid.cursor.lcf = true;
        print_linewrap(term);
        col = 0;
    }

    sixel_overwrite_at_cursor(term, width);

    const current_row = grid.cur_row orelse return;
    current_row.dirty = true;
    current_row.linebreak = true;

    const cell = &current_row.cells.?[@intCast(col)];
    cell.wc = wc;
    term.vt.last_printed = wc;
    cell.attrs = term.vt.attrs;

    if (term.vt.osc8.uri != null) {
        const osc8_underline = term.conf.?.url.osc8_underline;
        var i: c_int = 0;
        while (i < width and (col + i) < term.cols) : (i += 1) {
            grid_row_uri_range_put(
                current_row,
                col + i,
                @ptrCast(term.vt.osc8.uri.?),
                term.vt.osc8.id,
            );
        }
        if (osc8_underline == .always) {
            cell.attrs.url = true;
        }
    } else if (current_row.extra != null) {
        grid_row_uri_range_erase(current_row, col, col + width - 1);
    }

    if ((term.vt.underline.style != .none and term.vt.underline.style != .single) or
        term.vt.underline.color_src != .default)
    {
        grid_row_underline_range_put(current_row, col, term.vt.underline);
    } else if (current_row.extra != null) {
        grid_row_underline_range_erase(current_row, col, col + width - 1);
    }

    var i: c_int = 1;
    while (i < width and (col + 1) < term.cols) : (i += 1) {
        col += 1;
        print_spacer(term, col, width - i);
    }

    col += 1;
    if (col >= term.cols) {
        grid.cursor.lcf = true;
        col -= 1;
    }

    grid.cursor.point.col = col;
    if (comptime build_options.grapheme_clustering)
        term.vt.codepoint_merging_ok = true;
}

// ── Chunk C2a: ascii printers + term_update_ascii_printer + term_single_shift

const AsciiPrinter = *const fn (*types.Terminal, u32) callconv(.c) void;

fn ascii_printer_generic(term: *types.Terminal, wc: u32) callconv(.c) void {
    term_print(term, wc, 1, false);
}

fn ascii_printer_fast(term: *types.Terminal, wc: u32) callconv(.c) void {
    const grid = term.grid.?;

    print_linewrap(term);

    var col: c_int = grid.cursor.point.col;
    const uri_start = col;

    const current_row = grid.cur_row orelse return;
    current_row.dirty = true;
    current_row.linebreak = true;

    const cell = &current_row.cells.?[@intCast(col)];
    cell.wc = wc;
    term.vt.last_printed = wc;
    cell.attrs = term.vt.attrs;

    col += 1;
    if (col >= term.cols) {
        grid.cursor.lcf = true;
        col -= 1;
    }

    grid.cursor.point.col = col;
    if (comptime build_options.grapheme_clustering)
        term.vt.codepoint_merging_ok = true;

    if (current_row.extra != null) {
        grid_row_uri_range_erase(current_row, uri_start, uri_start);
        grid_row_underline_range_erase(current_row, uri_start, uri_start);
    }
}

fn ascii_printer_single_shift(term: *types.Terminal, wc: u32) callconv(.c) void {
    ascii_printer_generic(term, wc);
    term.charsets.selected = term.charsets.saved;

    term.bits_affecting_ascii_printer._.charset =
        term.charsets.set[@intCast(@intFromEnum(term.charsets.selected))] != .ascii;
    term_update_ascii_printer(term);
}

export fn term_update_ascii_printer(term: *types.Terminal) callconv(.c) void {
    const new_printer: AsciiPrinter = if (term.bits_affecting_ascii_printer.value != 0)
        &ascii_printer_generic
    else
        &ascii_printer_fast;

    term.ascii_printer = @ptrCast(new_printer);
}

export fn term_single_shift(
    term: *types.Terminal,
    idx: types.CharsetDesignator,
) callconv(.c) void {
    term.charsets.saved = term.charsets.selected;
    term.charsets.selected = idx;
    term.ascii_printer = @ptrCast(&ascii_printer_single_shift);
}

// ── Non-ASCII printing ────────────────────────────────────────────
//
// Ported from terminal.c: term_process_and_print_non_ascii().
//
// C machinery still required, and thus shimmed:
//   - conf->tweak.grapheme_width_method (struct config isn't mirrored)
// The generated emoji variation table stays in C; its lookup is here.

const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fff_ffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

const LOG_CLASS_WARNING: c_int = 2;

extern fn c32width(c: u32) c_int;
extern fn utf8proc_grapheme_break_stateful(state1: i32, state2: i32, state: *i32) c_int;

extern fn composed_lookup(root: ?*types.Composed, key: u32) ?*types.Composed;
extern fn composed_key_from_key(prev_key: u32, next_char: u32) u32;
extern fn composed_lookup_without_collision(
    root: ?*types.Composed,
    key: *u32,
    prefix_text: [*c]const u32,
    prefix_len: usize,
    wc: u32,
    forced_width: c_int,
) ?*types.Composed;
extern fn composed_insert(root: *?*types.Composed, node: ?*types.Composed) void;

extern fn xmalloc(size: usize) ?*anyopaque;
extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;

extern fn fcft_precompose(
    font: *const anyopaque,
    base: u32,
    wc: u32,
    base_from_primary: *bool,
    comb_from_primary: *bool,
    pre_from_primary: *bool,
) callconv(.c) u32;
extern fn terminal_shim_emoji_vs_count() callconv(.c) usize;
extern fn terminal_shim_emoji_vs_get(
    index: usize,
    start: *u32,
    end: *u32,
    vs15: *bool,
    vs16: *bool,
) callconv(.c) void;

fn precompose(
    term: *types.Terminal,
    base: u32,
    wc: u32,
    base_from_primary: *bool,
    comb_from_primary: *bool,
    pre_from_primary: *bool,
) u32 {
    const font = term.fonts[0] orelse {
        base_from_primary.* = false;
        comb_from_primary.* = false;
        pre_from_primary.* = false;
        return 0xffff_ffff;
    };

    return fcft_precompose(
        font,
        base,
        wc,
        base_from_primary,
        comb_from_primary,
        pre_from_primary,
    );
}

fn emojiVsWidth(cp: u32, wc: u32) c_int {
    if (comptime !build_options.grapheme_clustering)
        return -1;

    const count = terminal_shim_emoji_vs_count();

    // This is C bsearch() with emoji_vs_compare(): compare against start
    // first, then end, and accept any code point in the inclusive range.
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        var start: u32 = undefined;
        var end: u32 = undefined;
        var vs15: bool = undefined;
        var vs16: bool = undefined;
        terminal_shim_emoji_vs_get(mid, &start, &end, &vs15, &vs16);

        if (cp < start) {
            hi = mid;
        } else if (cp > end) {
            lo = mid + 1;
        } else {
            if (wc == 0xfe0e and vs15)
                return 1;
            if (wc == 0xfe0f and vs16)
                return 2;
            return -1;
        }
    }

    return -1;
}

export fn term_process_and_print_non_ascii(
    term: *types.Terminal,
    wc_in: u32,
) callconv(.c) void {
    var wc = wc_in;
    var width: c_int = c32width(wc);
    var insert_mode_disable = false;

    // Mirrors the FOOT_GRAPHEME_CLUSTERING guards in terminal.c: when
    // clustering is compiled out, the predicate is a constant false and
    // the utf8proc call below is dropped (it isn't linked in that config).
    const grapheme_clustering = if (comptime build_options.grapheme_clustering)
        term.grapheme_shaping and term.vt.codepoint_merging_ok
    else
        false;

    out: {
        const grid = term.grid.?;

        if (!(grid.cursor.point.col > 0 and
            (grapheme_clustering or (width == 0 and wc >= 0x300))))
        {
            termResetGraphemeState(term);
            break :out;
        }

        var col: c_int = grid.cursor.point.col;
        if (!grid.cursor.lcf)
            col -= 1;

        // Skip past spacers
        const current_row = grid.cur_row.?;
        const cells = current_row.cells.?;
        while (cells[@intCast(col)].wc >= CELL_SPACER and col > 0)
            col -= 1;

        std.debug.assert(col >= 0 and col < term.cols);

        var base: u32 = cells[@intCast(col)].wc;
        var last: u32 = base;

        // Is base cell already a cluster?
        const composed: ?*types.Composed = if (base >= CELL_COMB_CHARS_LO and
            base <= CELL_COMB_CHARS_HI)
            composed_lookup(term.composed, base - CELL_COMB_CHARS_LO)
        else
            null;

        var key: u32 = undefined;
        if (composed) |cc| {
            base = cc.chars.?[0];
            last = cc.chars.?[cc.count - 1];
            key = composed_key_from_key(cc.key, wc);
        } else {
            key = composed_key_from_key(base, wc);
        }

        if (comptime build_options.grapheme_clustering) {
            if (grapheme_clustering) {
                // Check if we're on a grapheme cluster break
                if (utf8proc_grapheme_break_stateful(
                    @bitCast(last),
                    @bitCast(wc),
                    &term.vt.grapheme_state,
                ) != 0) {
                    termResetGraphemeState(term);
                    break :out;
                }
            }
        }

        const base_width = c32width(base);
        if (base_width <= 0)
            break :out;

        grid.cursor.point.col = col;
        grid.cursor.lcf = false;
        insert_mode_disable = true;

        if (composed == null) {
            var base_from_primary: bool = undefined;
            var comb_from_primary: bool = undefined;
            var pre_from_primary: bool = undefined;

            const precomposed = precompose(
                term,
                base,
                wc,
                &base_from_primary,
                &comb_from_primary,
                &pre_from_primary,
            );

            const precomposed_width = c32width(precomposed);

            // Only use the pre-composed character if:
            //
            //  1. we *have* a pre-composed character
            //  2. the width matches the base characters width
            //  3. it's in the primary font, OR one of the base or
            //     combining characters are *not* from the primary font
            if (precomposed != 0xffff_ffff and
                precomposed_width == base_width and
                (pre_from_primary or !base_from_primary or !comb_from_primary))
            {
                wc = precomposed;
                width = precomposed_width;
                termResetGraphemeState(term);
                break :out;
            }
        }

        var wanted_count: usize = if (composed) |cc| @as(usize, cc.count) + 1 else 2;
        if (wanted_count > 255) {
            std.debug.assert(composed != null);
            // This is going to break anyway...
            wanted_count -= 1;
        }

        std.debug.assert(wanted_count <= 255);

        // Check if we already have a match for the entire compose chain
        const cc = composed_lookup_without_collision(
            term.composed,
            &key,
            if (composed) |c| c.chars.? else @as([*c]const u32, @ptrCast(&base)),
            if (composed) |c| @as(usize, c.count) else 1,
            wc,
            0,
        );

        if (cc) |match| {
            // We *do* have a match!
            wc = CELL_COMB_CHARS_LO + match.key;
            width = match.width;
            break :out;
        }

        if (term.composed_count >= @as(usize, CELL_COMB_CHARS_HI - CELL_COMB_CHARS_LO)) {
            // We reached our maximum number of allowed composed
            // character chains. Fall through here and print the
            // current zero-width character to the current cell.
            log_msg(
                LOG_CLASS_WARNING,
                "terminal",
                "terminal.zig",
                0,
                "maximum number of composed characters reached",
            );
            termResetGraphemeState(term);
            break :out;
        }

        // Allocate new chain
        const new_cc: *types.Composed = @ptrCast(@alignCast(xmalloc(@sizeOf(types.Composed)) orelse unreachable));
        const chars: [*]u32 = @ptrCast(@alignCast(xmalloc(wanted_count * @sizeOf(u32)) orelse unreachable));

        new_cc.chars = chars;
        new_cc.key = key;
        new_cc.count = @intCast(wanted_count);
        chars[0] = base;
        chars[wanted_count - 1] = wc;
        new_cc.forced_width = if (composed) |c| c.forced_width else 0;

        if (composed) |c| {
            const src: [*]const u32 = c.chars.?;
            @memcpy(chars[1 .. wanted_count - 1], src[1 .. wanted_count - 1]);
        }

        const grapheme_width: c_int = if (composed) |c| c.width else base_width;

        switch (term.conf.?.tweak.grapheme_width_method) {
            .max => new_cc.width = @intCast(@max(grapheme_width, width)),

            .double => {
                new_cc.width = @intCast(@min(grapheme_width + width, 2));

                // Handle VS-15 and VS-16 variation selectors
                if (comptime build_options.grapheme_clustering) {
                    if (grapheme_clustering and
                        (wc == 0xfe0e or wc == 0xfe0f) and
                        new_cc.count == 2)
                    {
                        const forced = emojiVsWidth(chars[0], wc);
                        if (forced >= 0)
                            new_cc.width = @intCast(forced);
                    }
                }
            },

            .wcswidth => new_cc.width = @intCast(grapheme_width + width),
        }

        term.composed_count += 1;
        composed_insert(&term.composed, new_cc);

        wc = CELL_COMB_CHARS_LO + new_cc.key;
        width = if (new_cc.forced_width > 0) new_cc.forced_width else new_cc.width;

        std.debug.assert(wc >= CELL_COMB_CHARS_LO);
        std.debug.assert(wc <= CELL_COMB_CHARS_HI);
    }

    if (width > 0)
        term_print(term, wc, width, insert_mode_disable);
}

// ── ptmx: chunk P1 — slave write buffers, term_to_slave, ptmx pause/resume

const tll = @import("tll.zig");

const PtmxBuffer = extern struct {
    data: ?*anyopaque,
    len: usize,
    idx: usize,
};

const PtmxBufferList = tll.Tll(PtmxBuffer);

const AsyncWriteStatus = enum(c_int) {
    done = 0,
    remain = 1,
    err = 2,
};

const LOG_CLASS_ERROR: c_int = 1;
const EPOLLOUT: c_int = 0x004;

extern fn async_write(fd: c_int, data: ?*const anyopaque, len: usize, idx: *usize) callconv(.c) AsyncWriteStatus;
extern fn fdm_event_add(fdm: *anyopaque, fd: c_int, events: c_int) callconv(.c) bool;
extern fn fdm_event_del(fdm: *anyopaque, fd: c_int, events: c_int) callconv(.c) bool;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

inline fn ptmxBuffers(term: *types.Terminal) *PtmxBufferList {
    return @ptrCast(&term.ptmx_buffers);
}

inline fn ptmxPasteBuffers(term: *types.Terminal) *PtmxBufferList {
    return @ptrCast(&term.ptmx_paste_buffers);
}

fn enqueueDataForSlave(
    data: ?*const anyopaque,
    len: usize,
    offset: usize,
    buffer_list: *PtmxBufferList,
) void {
    // C: xmemdup() + tll_push_back()
    const copy = xmalloc(len) orelse unreachable;
    if (len > 0) {
        @memcpy(
            @as([*]u8, @ptrCast(copy))[0..len],
            @as([*]const u8, @ptrCast(data.?))[0..len],
        );
    }

    buffer_list.pushBack(.{ .data = copy, .len = len, .idx = offset });
}

fn dataToSlave(
    term: *types.Terminal,
    data: ?*const anyopaque,
    len: usize,
    buffer_list: *PtmxBufferList,
) bool {
    // Try a synchronous write first. If we fail to write everything,
    // switch to asynchronous.
    var async_idx: usize = 0;

    switch (async_write(term.ptmx, data, len, &async_idx)) {
        .remain => {
            // Switch to asynchronous mode; let FDM write the remaining data
            if (!fdm_event_add(term.fdm orelse return false, term.ptmx, EPOLLOUT))
                return false;
            enqueueDataForSlave(data, len, async_idx, buffer_list);
            return true;
        },

        .done => return true,

        .err => {
            log_errno(
                LOG_CLASS_ERROR,
                "terminal",
                "terminal.zig",
                @as(c_int, @intCast(@src().line)),
                "failed to synchronously write %zu bytes to slave",
                len,
            );
            return false;
        },
    }
}

export fn term_paste_data_to_slave(
    term: *types.Terminal,
    data: ?*const anyopaque,
    len: usize,
) callconv(.c) bool {
    std.debug.assert(term.is_sending_paste_data);

    if (term.ptmx < 0) {
        // We're probably in "hold"
        return false;
    }

    const paste_buffers = ptmxPasteBuffers(term);
    if (paste_buffers.len() > 0) {
        // Don't even try to send data *now* if there's queued up data,
        // since that would result in events arriving out of order.
        enqueueDataForSlave(data, len, 0, paste_buffers);
        return true;
    }

    return dataToSlave(term, data, len, paste_buffers);
}

export fn term_to_slave(
    term: *types.Terminal,
    data: ?*const anyopaque,
    len: usize,
) callconv(.c) bool {
    if (term.ptmx < 0) {
        // We're probably in "hold"
        return false;
    }

    const buffers = ptmxBuffers(term);
    const paste_buffers = ptmxPasteBuffers(term);

    if (buffers.len() > 0 or
        term.is_sending_paste_data or
        paste_buffers.len() > 0)
    {
        // Don't even try to send data *now* if there's queued up data,
        // since that would result in events arriving out of order.
        //
        // Furthermore, if we're currently sending paste data to the
        // client, do *not* mix that stream with other events
        // (https://codeberg.org/dnkl/foot/issues/101).
        enqueueDataForSlave(data, len, 0, buffers);
        return true;
    }

    return dataToSlave(term, data, len, buffers);
}

const FlushResult = enum { flushed, remain, err };

// C macro `write_one_buffer` in fdm_ptmx_out()
fn flushOneBuffer(
    term: *types.Terminal,
    buffer_list: *PtmxBufferList,
    node: *PtmxBufferList.Node,
) FlushResult {
    switch (async_write(term.ptmx, node.item.data, node.item.len, &node.item.idx)) {
        .done => {
            free(node.item.data);
            buffer_list.removeNode(node);
            return .flushed;
        },

        .remain => {
            // to_slave() updated node.item.idx
            return .remain;
        },

        .err => {
            log_errno(
                LOG_CLASS_ERROR,
                "terminal",
                "terminal.zig",
                @as(c_int, @intCast(@src().line)),
                "failed to asynchronously write %zu bytes to slave",
                node.item.len - node.item.idx,
            );
            return .err;
        },
    }
}

export fn fdm_ptmx_out(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fdm;
    _ = fd;
    _ = events;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    const buffers = ptmxBuffers(term);
    const paste_buffers = ptmxPasteBuffers(term);

    // If there is no queued data, then we shouldn't be in asynchronous mode
    std.debug.assert(buffers.len() > 0 or paste_buffers.len() > 0);

    var it = paste_buffers.foreach();
    while (it.next()) |node| {
        switch (flushOneBuffer(term, paste_buffers, node)) {
            .flushed => {},
            .remain => return true,
            .err => return false,
        }
    }

    // If we get here, *all* paste data buffers were successfully flushed

    if (!term.is_sending_paste_data) {
        var it_normal = buffers.foreach();
        while (it_normal.next()) |node| {
            switch (flushOneBuffer(term, buffers, node)) {
                .flushed => {},
                .remain => return true,
                .err => return false,
            }
        }
    }

    // If we get here, *all* buffers were successfully flushed. Or, we're
    // still sending paste data, in which case we do *not* want to send the
    // "normal" queued up data. In both cases, we want to *disable* the FDM
    // callback since otherwise we'd just be called right away again, with
    // nothing to write.
    if (term.fdm) |f|
        _ = fdm_event_del(f, term.ptmx, EPOLLOUT);
    return true;
}

export fn term_ptmx_pause(term: *types.Terminal) callconv(.c) bool {
    if (term.ptmx < 0)
        return false;
    return fdm_event_del(term.fdm orelse return false, term.ptmx, EPOLLIN);
}

export fn term_ptmx_resume(term: *types.Terminal) callconv(.c) bool {
    if (term.ptmx < 0)
        return false;
    return fdm_event_add(term.fdm orelse return false, term.ptmx, EPOLLIN);
}

// ── ptmx: chunk P2 — fdm_ptmx

const EIO: c_int = 5;
const PTMX_READ_BUFFER_SIZE: usize = 24 * 1024;

extern fn vt_from_slave(term: *types.Terminal, data: [*]const u8, len: usize) callconv(.c) void;

// PTMX_TIMING is 0 in terminal.c; the timing instrumentation is omitted
// until that build-time option exists in build_options.
export fn fdm_ptmx(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    const pollin = (events & EPOLLIN) != 0;
    const pollout = (events & EPOLLOUT) != 0;
    const hup = (events & EPOLLHUP) != 0;

    if (pollout) {
        if (!fdm_ptmx_out(fdm, fd, events, data))
            return false;
    }

    // Prevent blinking while typing
    if (term.cursor_blink.fd >= 0) {
        term.cursor_blink.state = CURSOR_BLINK_ON;
        _ = cursor_blink_rearm_timer(term);
    }

    if (term.interactive_resizing.grid != null) {
        // Don't consume PTMX while we're doing an interactive resize,
        // since the 'normal' grid we're currently using is a temporary
        // one - all changes done to it will be lost when the interactive
        // resize ends.
        return true;
    }

    var buf: [PTMX_READ_BUFFER_SIZE]u8 = undefined;
    const max_iterations: usize = if (!hup) 10 else std.math.maxInt(usize);

    var i: usize = 0;
    while (i < max_iterations and pollin) : (i += 1) {
        const count = read(term.ptmx, &buf, buf.len);

        if (count < 0) {
            const errnum = __errno_location().*;
            if (errnum == EAGAIN or errnum == EIO) {
                // EAGAIN: no more to read - FDM will trigger us again
                // EIO: assume PTY was closed - we already have, or will
                // get, a EPOLLHUP
                break;
            }

            log_errno(
                LOG_CLASS_ERROR,
                "terminal",
                "terminal.zig",
                @as(c_int, @intCast(@src().line)),
                "failed to read from pseudo terminal",
            );
            return false;
        } else if (count == 0) {
            // Reached end-of-file
            break;
        }

        std.debug.assert(term.interactive_resizing.grid == null);
        vt_from_slave(term, &buf, @intCast(count));
    }

    if (!term.render.app_sync_updates.enabled) {
        // See the C version for why we delay: batching client updates
        // avoids rendering "intermediate" frames. The lower timeout is
        // re-armed on every read; the upper one only when we render.
        const lower_ns = term.conf.?.tweak.delayed_render_lower_ns;
        const upper_ns = term.conf.?.tweak.delayed_render_upper_ns;

        if (lower_ns > 0 and upper_ns > 0) {
            std.debug.assert(lower_ns < 1_000_000_000);
            std.debug.assert(upper_ns < 1_000_000_000);
            std.debug.assert(upper_ns > lower_ns);

            _ = timerfd_settime(
                term.delayed_render_timer.lower_fd,
                0,
                &types.Itimerspec{
                    .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(lower_ns) },
                    .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                },
                null,
            );

            // Second timeout - only reset when we render. Set to one
            // frame (assuming 60Hz)
            if (!term.delayed_render_timer.is_armed) {
                _ = timerfd_settime(
                    term.delayed_render_timer.upper_fd,
                    0,
                    &types.Itimerspec{
                        .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(upper_ns) },
                        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                    },
                    null,
                );
                term.delayed_render_timer.is_armed = true;
            }
        } else {
            render_refresh(term);
        }
    }

    if (hup) {
        _ = del_utmp_record(term.conf, term.reaper, term.ptmx);
        if (fdm) |f|
            _ = fdm_del(f, fd);
        term.ptmx = -1;

        // Normally, we do *not* want to shutdown when the PTY is closed.
        // Instead, we want to wait for the client application to exit.
        //
        // However, when we're using a pre-existing PTY (the --pty
        // option), there _is_ no client application. That is, foot does
        // *not* fork+exec anything, and thus the only way to shutdown is
        // to wait for the PTY to be closed.
        if (term.slave < 0 and !term.conf.?.hold_at_exit)
            _ = term_shutdown(term);
    }

    return true;
}

//
// Chunk T1 — term_erase_scrollback
//

extern fn sixel_destroy(sixel: *types.Sixel) callconv(.c) void;

// grid.h: grid_row_absolute() and grid_row_absolute_in_view() are static
// inline in C, so they cannot be called from here; mirror them instead.
fn gridRowAbsolute(grid: *const types.Grid, row_no: c_int) c_int {
    return (grid.offset + row_no) & (grid.num_rows - 1);
}

fn gridRowAbsoluteInView(grid: *const types.Grid, row_no: c_int) c_int {
    return (grid.view + row_no) & (grid.num_rows - 1);
}

/// Range check a (rel_start, rel_end) span against the scrollback span
/// (rel_sb_start, rel_sb_end). Rows are relative to the scrollback start, so a
/// higher number means further *down* in the scrollback.
fn spanTouchesScrollback(
    rel_start: c_int,
    rel_end: c_int,
    rel_sb_start: c_int,
    rel_sb_end: c_int,
) bool {
    if (rel_start < 0 or rel_end < 0)
        return false;

    return (rel_start <= rel_sb_start and rel_end >= rel_sb_start) or
        (rel_start <= rel_sb_end and rel_end >= rel_sb_end) or
        (rel_start >= rel_sb_start and rel_end <= rel_sb_end);
}

/// tll_remove(): unlink *and* free the node (this matches tllist.h).
fn sixelListRemove(list: *types.SixelList, node: *types.SixelNode) void {
    std.debug.assert(list.length > 0);

    if (node.prev) |prev| prev.next = node.next else list.head = node.next;
    if (node.next) |next| next.prev = node.prev else list.tail = node.prev;
    list.length -= 1;

    std.c.free(node);
}

export fn term_erase_scrollback(term: *types.Terminal) void {
    const grid = term.grid.?;
    const num_rows = grid.num_rows;
    const mask = num_rows - 1;

    const scrollback_history_size = num_rows - term.rows;
    if (scrollback_history_size == 0)
        return;

    const start = (grid.offset + term.rows) & mask;
    const end = (grid.offset - 1) & mask;

    const rel_start = grid_row_abs_to_sb(grid, term.rows, start);
    const rel_end = grid_row_abs_to_sb(grid, term.rows, end);

    const sel_start = selection_get_start(term).row;
    const sel_end = selection_get_end(term).row;

    if (sel_end >= 0) {
        // Cancel the selection if it touches any of the rows in the
        // scrollback, since we can't have it reference soon-to-be-deleted
        // rows.
        const rel_sel_start = grid_row_abs_to_sb(grid, term.rows, sel_start);
        const rel_sel_end = grid_row_abs_to_sb(grid, term.rows, sel_end);

        if (spanTouchesScrollback(rel_sel_start, rel_sel_end, rel_start, rel_end))
            selection_cancel(term);
    }

    var it = grid.sixel_images.head;
    while (it) |node| {
        // Cache the next node: removing `node` frees it.
        const next = node.next;
        const six = &node.item;

        const six_start = grid_row_abs_to_sb(grid, term.rows, six.pos.row);
        const six_end = grid_row_abs_to_sb(
            grid,
            term.rows,
            six.pos.row + six.rows - 1,
        );

        if (spanTouchesScrollback(six_start, six_end, rel_start, rel_end)) {
            sixel_destroy(six);
            sixelListRemove(&grid.sixel_images, node);
        }

        it = next;
    }

    var i = start;
    while (true) : (i = (i + 1) & mask) {
        if (grid.rows.?[@intCast(i)]) |r| {
            if (term.render.last_cursor.row == r)
                term.render.last_cursor.row = null;

            grid_row_free(r);
            grid.rows.?[@intCast(i)] = null;
        }

        if (i == end)
            break;
    }

    grid.view = grid.offset;

    if (comptime @import("builtin").mode == .Debug) {
        // Every row in view must still exist (C guarded this with _DEBUG).
        var r: c_int = 0;
        while (r < term.rows) : (r += 1) {
            const in_view = gridRowAbsoluteInView(grid, r);
            std.debug.assert(grid.rows.?[@intCast(in_view)] != null);
        }
    }

    term_damage_view(term);
}

//
// Chunk T2 — text extraction
//

const SELECTION_NONE: c_int = 0;

extern fn extract_begin(kind: c_int, strip_trailing_empty: bool) callconv(.c) ?*anyopaque;
extern fn extract_one(
    term: *const types.Terminal,
    row: *const types.Row,
    cell: *const types.Cell,
    col: c_int,
    context: *anyopaque,
) callconv(.c) bool;
extern fn extract_finish(context: *anyopaque, text: *?[*:0]u8, len: *usize) callconv(.c) bool;

fn rowsToText(
    term: *const types.Terminal,
    start: c_int,
    end: c_int,
    col_start_initial: c_int,
    col_end: c_int,
    text: *?[*:0]u8,
    len: *usize,
) bool {
    const ctx = extract_begin(SELECTION_NONE, true) orelse return false;

    const grid = term.grid.?;
    const grid_rows = grid.num_rows;
    const rows = grid.rows.?;

    var r = start;
    var col_start = col_start_initial;

    while (true) {
        const r_row = rows[@intCast(r)] orelse {
            std.debug.assert(false); // xassert(row != NULL)
            return extract_finish(ctx, text, len);
        };

        const c_end = if (r == end) col_end else term.cols;

        var c = col_start;
        while (c < c_end) : (c += 1) {
            const cell = &r_row.cells.?[@intCast(c)];
            if (!extract_one(term, r_row, cell, c, ctx))
                return extract_finish(ctx, text, len);
        }

        if (r == end)
            break;

        r = (r + 1) & (grid_rows - 1);
        col_start = 0;
    }

    return extract_finish(ctx, text, len);
}

export fn term_scrollback_to_text(
    term: *const types.Terminal,
    text: *?[*:0]u8,
    len: *usize,
) bool {
    const grid = term.grid.?;
    const grid_rows = grid.num_rows;

    var start = (grid.offset + term.rows) & (grid_rows - 1);
    var end = (grid.offset + term.rows - 1) & (grid_rows - 1);

    std.debug.assert(start >= 0 and start < grid_rows);
    std.debug.assert(end >= 0 and end < grid_rows);

    // If the scrollback isn't full yet, this may be NULL, so scan forward
    // until we find the first non-NULL row.
    const rows = grid.rows.?;
    while (rows[@intCast(start)] == null) {
        start += 1;
        start &= grid_rows - 1;
    }

    while (rows[@intCast(end)] == null) {
        end -= 1;
        if (end < 0)
            end += grid.num_rows;
    }

    return rowsToText(term, start, end, 0, term.cols, text, len);
}

export fn term_view_to_text(
    term: *const types.Terminal,
    text: *?[*:0]u8,
    len: *usize,
) bool {
    const start = gridRowAbsoluteInView(term.grid.?, 0);
    const end = gridRowAbsoluteInView(term.grid.?, term.rows - 1);
    return rowsToText(term, start, end, 0, term.cols, text, len);
}

export fn term_command_output_to_text(
    term: *const types.Terminal,
    text: *?[*:0]u8,
    len: *usize,
) bool {
    var start_row: c_int = -1;
    var end_row: c_int = -1;
    var start_col: c_int = -1;
    var end_col: c_int = -1;

    const grid = term.grid.?;
    const rows = grid.rows.?;
    const sb_end = gridRowAbsolute(grid, term.rows - 1);
    const sb_start = (sb_end + 1) & (grid.num_rows - 1);
    var r = sb_end;

    while (start_row < 0) {
        const cmd_row = rows[@intCast(r)] orelse break;

        if (cmd_row.shell_integration.cmd_end >= 0) {
            end_row = r;
            end_col = cmd_row.shell_integration.cmd_end;
        }

        if (end_row >= 0 and cmd_row.shell_integration.cmd_start >= 0) {
            start_row = r;
            start_col = cmd_row.shell_integration.cmd_start;
        }

        if (r == sb_start)
            break;

        r = (r - 1 + grid.num_rows) & (grid.num_rows - 1);
    }

    if (start_row < 0)
        return false;

    const ret = rowsToText(term, start_row, end_row, start_col, end_col, text, len);
    if (!ret)
        return false;

    // If the FTCS_COMMAND_FINISHED marker was emitted at the *first* column,
    // then the *entire* previous line is part of the command output,
    // including the newline. rowsToText() doesn't extract the column the
    // marker was emitted at, so the extracted text won't end with a newline;
    // compensate for that here. If end_col != 0 the output only covers a
    // partial row, and we must *not* append a newline.
    if (end_col > 0)
        return true;

    const next_to_last_row = (end_row - 1 + grid.num_rows) & (grid.num_rows - 1);
    const prev_row = rows[@intCast(next_to_last_row)] orelse return true;

    // Add newline if the last row has a hard linebreak
    if (prev_row.linebreak) {
        const new_text = std.c.realloc(@ptrCast(text.*), len.* + 2) orelse return true;
        text.* = @ptrCast(new_text);
        len.* += 1;
        text.*.?[len.* - 1] = '\n';
        text.*.?[len.*] = 0;
    }

    return true;
}

//
// Chunk T3 — small accessors: osc8, user mouse cursor, size notifications,
// visibility report, flash, app-sync updates, render throttle timers.
//

fn logErr(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "%s", msg);
}

fn logErrno(msg: [*:0]const u8) void {
    log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "%s", msg);
}

extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh_title(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh_icon(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh_app_id(term: *types.Terminal) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;

export fn term_osc8_open(term: *types.Terminal, id: u64, uri: [*:0]const u8) void {
    term_osc8_close(term);
    std.debug.assert(term.vt.osc8.uri == null);

    term.vt.osc8.id = id;
    term.vt.osc8.uri = xstrdup(uri);

    term.bits_affecting_ascii_printer._.osc8 = true;
    term_update_ascii_printer(term);
}

export fn term_osc8_close(term: *types.Terminal) void {
    if (term.vt.osc8.uri) |uri|
        std.c.free(uri);
    term.vt.osc8.uri = null;
    term.vt.osc8.id = 0;

    term.bits_affecting_ascii_printer._.osc8 = false;
    term_update_ascii_printer(term);
}

export fn term_set_user_mouse_cursor(term: *types.Terminal, cursor: ?[*:0]const u8) void {
    if (term.mouse_user_cursor) |old|
        std.c.free(old);

    if (cursor) |c| {
        term.mouse_user_cursor = if (c[0] != 0) xstrdup(c) else null;
    } else {
        term.mouse_user_cursor = null;
    }

    term_xcursor_update(term);
}

export fn term_send_visibility_report(term: *types.Terminal) void {
    // Both reports are 9 bytes; see also term_to_slave()'s length cast.
    const report = if (term.window != null and term.window.?.is_suspended)
        "\x1b[?999;2n"
    else
        "\x1b[?999;1n";

    _ = term_to_slave(term, @ptrCast(report.ptr), report.len);
}

export fn term_enable_size_notifications(term: *types.Terminal) void {
    // Note: always send the current size upon activation, regardless of
    // the previous state.
    term.size_notifications = true;
    term_send_size_notification(term);
}

export fn term_disable_size_notifications(term: *types.Terminal) void {
    if (!term.size_notifications)
        return;

    term.size_notifications = false;
}

export fn term_send_size_notification(term: *types.Terminal) void {
    if (!term.size_notifications)
        return;

    const height = term.height - term.margins.top - term.margins.bottom;
    const width = term.width - term.margins.left - term.margins.right;

    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(
        &buf,
        "\x1b[48;{d};{d};{d};{d}t",
        .{ term.rows, term.cols, height, width },
    ) catch return;

    _ = term_to_slave(term, @ptrCast(s.ptr), s.len);
}

const zero_itimerspec = types.Itimerspec{
    .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
    .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
};

export fn term_flash(term: *types.Terminal, duration_ms: c_uint) void {
    const timer = types.Itimerspec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(duration_ms * 1_000_000) },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };

    if (timerfd_settime(term.flash.fd, 0, &timer, null) < 0) {
        logErrno("failed to arm flash timer");
    } else {
        term.flash.active = true;
    }
}

/// Drain a timerfd and disarm it again. Returns false if reading failed for a
/// reason other than "would block".
fn drainTimer(fd: c_int) bool {
    var unused: u64 = undefined;
    _ = std.posix.read(fd, std.mem.asBytes(&unused)) catch |err| switch (err) {
        error.WouldBlock => return true,
        else => return false,
    };

    _ = timerfd_settime(fd, 0, &zero_itimerspec, null);
    return true;
}

export fn fdm_app_sync_updates_timeout(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) bool {
    _ = fdm;
    _ = fd;

    if (events & EPOLLHUP != 0)
        return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data.?));

    var unused: u64 = undefined;
    _ = std.posix.read(term.render.app_sync_updates.timer_fd, std.mem.asBytes(&unused)) catch |err| switch (err) {
        error.WouldBlock => return true,
        else => {
            logErrno("failed to read application synchronized updates timeout timer");
            return false;
        },
    };

    term_disable_app_sync_updates(term);
    return true;
}

const ThrottleKind = enum { title, icon, app_id };

fn fdmRenderThrottleTimeout(events: c_int, data: ?*anyopaque, kind: ThrottleKind) bool {
    if (events & EPOLLHUP != 0)
        return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data.?));

    const fd = switch (kind) {
        .title => term.render.title.timer_fd,
        .icon => term.render.icon.timer_fd,
        .app_id => term.render.app_id.timer_fd,
    };

    if (!drainTimer(fd)) {
        logErrno("failed to read update throttle timer");
        return false;
    }

    switch (kind) {
        .title => render_refresh_title(term),
        .icon => render_refresh_icon(term),
        .app_id => render_refresh_app_id(term),
    }

    return true;
}

export fn fdm_title_update_timeout(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) bool {
    _ = fdm;
    _ = fd;
    return fdmRenderThrottleTimeout(events, data, .title);
}

export fn fdm_icon_update_timeout(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) bool {
    _ = fdm;
    _ = fd;
    return fdmRenderThrottleTimeout(events, data, .icon);
}

export fn fdm_app_id_update_timeout(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) bool {
    _ = fdm;
    _ = fd;
    return fdmRenderThrottleTimeout(events, data, .app_id);
}

export fn term_enable_app_sync_updates(term: *types.Terminal) void {
    term.render.app_sync_updates.enabled = true;

    if (timerfd_settime(
        term.render.app_sync_updates.timer_fd,
        0,
        &types.Itimerspec{
            .it_value = .{ .tv_sec = 1, .tv_nsec = 0 },
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        },
        null,
    ) < 0) {
        logErr("failed to arm timer for application synchronized updates");
    }

    // Disable pending refresh *iff* the grid is the *only* thing scheduled
    // to be re-rendered.
    if (!term.render.refresh.csd and !term.render.refresh.search and
        !term.render.pending.csd and !term.render.pending.search)
    {
        term.render.refresh.grid = false;
        term.render.pending.grid = false;
    }

    // Disarm delayed rendering timers
    _ = timerfd_settime(term.delayed_render_timer.lower_fd, 0, &zero_itimerspec, null);
    _ = timerfd_settime(term.delayed_render_timer.upper_fd, 0, &zero_itimerspec, null);
    term.delayed_render_timer.is_armed = false;
}

export fn term_disable_app_sync_updates(term: *types.Terminal) void {
    if (!term.render.app_sync_updates.enabled)
        return;

    term.render.app_sync_updates.enabled = false;
    render_refresh(term);

    // Reset timers
    _ = timerfd_settime(term.render.app_sync_updates.timer_fd, 0, &zero_itimerspec, null);
}

//
// Chunk T6 (part 1) — window title / app-id / icon / respawn, and the
// colour-theme switches. The config is still parsed by C, but its layout is
// mirrored in terminal_types.zig, so these read `term.conf` directly.
//

extern fn wayl_win_alpha_changed(window: ?*anyopaque) callconv(.c) void;
extern fn is_valid_utf8_and_printable(value: [*:0]const u8) callconv(.c) bool;
extern fn spawn(
    reaper: ?*anyopaque,
    cwd: [*c]const u8,
    argv: [*c]const [*c]u8,
    stdin_fd: c_int,
    stdout_fd: c_int,
    stderr_fd: c_int,
    cb: ?*const anyopaque,
    cb_data: ?*anyopaque,
    xdg_activation_token: [*c]const u8,
) callconv(.c) c_int;

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

fn replaceStr(dst: *?[*:0]u8, value: [*:0]const u8) void {
    if (dst.*) |old|
        std.c.free(old);
    dst.* = xstrdup(value);
}

export fn term_set_window_title(term: *types.Terminal, title: [*:0]const u8) void {
    if (term.conf.?.locked_title and term.window_title_has_been_set)
        return;

    if (term.window_title) |current| {
        if (streq(current, title))
            return;
    }

    if (!is_valid_utf8_and_printable(title)) {
        // It's an xdg_toplevel::set_title() protocol violation to set a
        // title with an invalid UTF-8 sequence.
        log_msg(LOG_CLASS_WARNING, "terminal", "terminal.zig", @intCast(@src().line), "%s: title is not valid UTF-8, ignoring", title);
        return;
    }

    replaceStr(&term.window_title, title);
    render_refresh_title(term);
    term.window_title_has_been_set = true;
}

export fn term_set_app_id(term: *types.Terminal, app_id_in: ?[*:0]const u8) void {
    var app_id = app_id_in;
    if (app_id) |id| {
        if (id[0] == 0)
            app_id = null;
    }

    if (term.app_id == null and app_id == null)
        return;

    if (term.app_id != null and app_id != null and streq(term.app_id.?, app_id.?))
        return;

    if (app_id) |id| {
        if (!is_valid_utf8_and_printable(id)) {
            log_msg(LOG_CLASS_WARNING, "terminal", "terminal.zig", @intCast(@src().line), "%s: app-id is not valid UTF-8, ignoring", id);
            return;
        }
    }

    if (term.app_id) |old|
        std.c.free(old);

    if (app_id) |id| {
        term.app_id = xstrdup(id);
    } else {
        term.app_id = null;
    }

    const length = if (app_id) |id| std.mem.len(id) else 0;
    if (length > 2048) {
        // Too long app-ids make at least river and sway peg the CPU at 100%
        // and stop sending frame callbacks.
        term.app_id.?[2048] = 0;
    }

    render_refresh_app_id(term);
    render_refresh_icon(term);
}

export fn term_icon(term: *const types.Terminal) [*:0]const u8 {
    const app_id = if (term.app_id) |id| id else term.conf.?.app_id.?;

    return if (streq(app_id, "footclient")) "foot" else app_id;
}

export fn term_spawn_new(term: *const types.Terminal) bool {
    // C: xassert(term->argc > 0). Keep the same contract, but fail the
    // spawn instead of trapping when there is no command line to reuse.
    if (term.argc <= 0) return false;

    const argc: usize = @intCast(term.argc);
    const argv: [*]?[*:0]u8 = @ptrCast(@alignCast(
        xmalloc((argc + 1) * @sizeOf(?[*:0]u8)) orelse return false,
    ));
    defer std.c.free(@ptrCast(argv));

    // Reuse the original foot command line, but with argv[0] pointing at
    // this process's executable.
    argv[0] = term.foot_exe;
    var i: usize = 1;
    while (i < argc) : (i += 1)
        argv[i] = term.argv.?[i];
    argv[argc] = null;

    return spawn(
        term.reaper,
        @ptrCast(term.cwd),
        @ptrCast(argv),
        -1,
        -1,
        -1,
        null,
        null,
        null,
    ) >= 0;
}

export fn term_theme_apply(term: *types.Terminal, theme: *const types.ColorTheme) void {
    term.colors.fg = theme.fg;
    term.colors.bg = theme.bg;
    term.colors.alpha = theme.alpha;
    term.colors.cursor_fg = (if (theme.use_custom.cursor) @as(u32, 0x8000_0000) else 0) | theme.cursor.text;
    term.colors.cursor_bg = (if (theme.use_custom.cursor) @as(u32, 0x8000_0000) else 0) | theme.cursor.cursor;
    term.colors.selection_fg = theme.selection_fg;
    term.colors.selection_bg = theme.selection_bg;
    @memcpy(&term.colors.table, &theme.table);
}

fn themeSwitch(term: *types.Terminal, theme: types.WhichColorTheme, report: []const u8) void {
    const colors = switch (theme) {
        .dark => &term.conf.?.colors_dark,
        else => &term.conf.?.colors_light,
    };

    term_theme_apply(term, colors);
    term.colors.active_theme = theme;

    wayl_win_alpha_changed(term.window);
    term_font_subpixel_changed(term);

    if (term.report_theme_changes)
        _ = term_to_slave(term, @ptrCast(report.ptr), report.len);

    term_damage_view(term);
    term_damage_margins(term);
    render_refresh(term);
}

export fn term_theme_switch_to_dark(term: *types.Terminal) void {
    if (term.colors.active_theme == .dark)
        return;

    themeSwitch(term, .dark, "\x1b[?997;1n");
}

export fn term_theme_switch_to_light(term: *types.Terminal) void {
    if (term.colors.active_theme == .light)
        return;

    themeSwitch(term, .light, "\x1b[?997;2n");
}

export fn term_theme_toggle(term: *types.Terminal) void {
    if (term.colors.active_theme == .dark)
        themeSwitch(term, .light, "\x1b[?997;2n")
    else
        themeSwitch(term, .dark, "\x1b[?997;1n");
}

export fn term_theme_get(term: *const types.Terminal) *const types.ColorTheme {
    return if (term.colors.active_theme == .dark)
        &term.conf.?.colors_dark
    else
        &term.conf.?.colors_light;
}

//
// Chunk T7 (part 1) — mouse reporting. term_mouse_grabbed() and the
// xcursor functions stay in C: they need the seat and the key-binding
// manager (phase 3).
//

const BTN_LEFT: c_int = 0x110;
const BTN_RIGHT: c_int = 0x111;
const BTN_MIDDLE: c_int = 0x112;
const BTN_SIDE: c_int = 0x113;
const BTN_EXTRA: c_int = 0x114;
const BTN_FORWARD: c_int = 0x115;
const BTN_BACK: c_int = 0x116;
const BTN_TASK: c_int = 0x117;

// Foot custom defines (input.h), not Linux input event codes.
const BTN_WHEEL_BACK: c_int = 0x11c;
const BTN_WHEEL_FORWARD: c_int = 0x11d;
const BTN_WHEEL_LEFT: c_int = 0x11e;
const BTN_WHEEL_RIGHT: c_int = 0x11f;

fn linuxMouseButtonToX(button: c_int) c_int {
    // On X11, scroll events were reported as buttons. Not so on Wayland, so
    // map scroll events to custom "button" defines (BTN_WHEEL_*).
    return switch (button) {
        BTN_LEFT => 1,
        BTN_MIDDLE => 2,
        BTN_RIGHT => 3,
        BTN_WHEEL_BACK => 4,
        BTN_WHEEL_FORWARD => 5,
        BTN_WHEEL_LEFT => 6,
        BTN_WHEEL_RIGHT => 7,
        BTN_SIDE => 8,
        BTN_EXTRA => 9,
        BTN_FORWARD => 10,
        BTN_BACK => 11,
        BTN_TASK => 12,
        else => -1,
    };
}

fn encodeXbutton(xbutton: c_int) c_int {
    return switch (xbutton) {
        1, 2, 3 => xbutton - 1,

        // Like button 1 and 2, but with 64 added
        4, 5, 6, 7 => xbutton - 4 + 64,

        // Similar to 4 and 5, but adding 128 instead of 64
        8, 9, 10, 11 => xbutton - 8 + 128,

        else => -1,
    };
}

fn reportMouseClick(
    term: *types.Terminal,
    encoded_button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    release: bool,
) void {
    var response: [128]u8 = undefined;

    const out: []const u8 = switch (term.mouse_reporting) {
        .normal => blk: {
            const encoded_col = 32 + col + 1;
            const encoded_row = 32 + row_idx + 1;
            if (encoded_col > 255 or encoded_row > 255)
                return;

            response[0] = 0x1b;
            response[1] = '[';
            response[2] = 'M';
            response[3] = @intCast(32 + (if (release) 3 else encoded_button));
            response[4] = @intCast(encoded_col);
            response[5] = @intCast(encoded_row);
            break :blk response[0..6];
        },

        .sgr => std.fmt.bufPrint(
            &response,
            "\x1b[<{d};{d};{d}{c}",
            .{ encoded_button, col + 1, row_idx + 1, if (release) @as(u8, 'm') else 'M' },
        ) catch return,

        .sgr_pixels => std.fmt.bufPrint(
            &response,
            "\x1b[<{d};{d};{d}{c}",
            .{
                encoded_button,
                @max(col_pixels, 0) + 1,
                @max(row_pixels, 0) + 1,
                if (release) @as(u8, 'm') else 'M',
            },
        ) catch return,

        .urxvt => std.fmt.bufPrint(
            &response,
            "\x1b[{d};{d};{d}M",
            .{ 32 + (if (release) 3 else encoded_button), col + 1, row_idx + 1 },
        ) catch return,

        // Unimplemented
        .utf8 => return,
    };

    _ = term_to_slave(term, @ptrCast(out.ptr), out.len);
}

fn reportMouseMotion(
    term: *types.Terminal,
    encoded_button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
) void {
    reportMouseClick(term, encoded_button, row_idx, col, row_pixels, col_pixels, false);
}

fn encodeWithModifiers(term: *types.Terminal, encoded: c_int, shift: bool, alt: bool, ctrl: bool) c_int {
    _ = term;
    return encoded +
        (if (shift) @as(c_int, 4) else 0) +
        (if (alt) @as(c_int, 8) else 0) +
        (if (ctrl) @as(c_int, 16) else 0);
}

export fn term_mouse_down(
    term: *types.Terminal,
    button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    shift_in: bool,
    alt_in: bool,
    ctrl_in: bool,
) void {
    // Map libinput button event code to X button number
    const xbutton = linuxMouseButtonToX(button);
    if (xbutton == -1)
        return;

    var encoded = encodeXbutton(xbutton);
    if (encoded == -1)
        return;

    const has_focus = term.kbd_focus;
    const shift = has_focus and shift_in;
    const alt = has_focus and alt_in;
    const ctrl = has_focus and ctrl_in;

    encoded = encodeWithModifiers(term, encoded, shift, alt, ctrl);

    switch (term.mouse_tracking) {
        .none => {},
        .click, .drag, .motion => reportMouseClick(
            term,
            encoded,
            row_idx,
            col,
            row_pixels,
            col_pixels,
            false,
        ),
        .x10 => unreachable, // Never enabled
    }
}

export fn term_mouse_up(
    term: *types.Terminal,
    button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    shift_in: bool,
    alt_in: bool,
    ctrl_in: bool,
) void {
    const xbutton = linuxMouseButtonToX(button);
    if (xbutton == -1)
        return;

    if (xbutton == 4 or xbutton == 5) {
        // No release events for vertical scroll wheel buttons
        return;
    }

    var encoded = encodeXbutton(xbutton);
    if (encoded == -1)
        return;

    const has_focus = term.kbd_focus;
    const shift = has_focus and shift_in;
    const alt = has_focus and alt_in;
    const ctrl = has_focus and ctrl_in;

    encoded = encodeWithModifiers(term, encoded, shift, alt, ctrl);

    switch (term.mouse_tracking) {
        .none => {},
        .click, .drag, .motion => reportMouseClick(
            term,
            encoded,
            row_idx,
            col,
            row_pixels,
            col_pixels,
            true,
        ),
        .x10 => unreachable, // Never enabled
    }
}

export fn term_mouse_motion(
    term: *types.Terminal,
    button: c_int,
    row_idx: c_int,
    col: c_int,
    row_pixels: c_int,
    col_pixels: c_int,
    shift_in: bool,
    alt_in: bool,
    ctrl_in: bool,
) void {
    var encoded: c_int = 0;

    if (button != 0) {
        const xbutton = linuxMouseButtonToX(button);
        if (xbutton == -1)
            return;

        encoded = encodeXbutton(xbutton);
        if (encoded == -1)
            return;
    } else {
        encoded = 3; // "released"
    }

    const has_focus = term.kbd_focus;
    const shift = has_focus and shift_in;
    const alt = has_focus and alt_in;
    const ctrl = has_focus and ctrl_in;

    encoded += 32; // Motion event
    encoded = encodeWithModifiers(term, encoded, shift, alt, ctrl);

    switch (term.mouse_tracking) {
        .none, .click => return,

        .drag => {
            if (button == 0)
                return;
            reportMouseMotion(term, encoded, row_idx, col, row_pixels, col_pixels);
        },

        .motion => reportMouseMotion(term, encoded, row_idx, col, row_pixels, col_pixels),
        .x10 => unreachable, // Never enabled
    }
}

//
// print_linewrap / print_insert — helpers used by term_print().
//

export fn print_linewrap(term: *types.Terminal) void {
    const grid = term.grid.?;

    if (!grid.cursor.lcf)
        return; // Not at the end of the line

    if (!term.auto_margin)
        return; // Auto-wrap disabled

    grid.cur_row.?.linebreak = false;
    grid.cursor.lcf = false;

    const cursor_row = grid.cursor.point.row;

    if (cursor_row == term.scroll_region.end - 1) {
        term_scroll(term, 1);
    } else {
        const new_row = @min(cursor_row + 1, term.rows - 1);
        grid.cursor.point.row = new_row;
        grid.cur_row = terminal_shim_grid_row(grid, new_row);
    }

    grid.cursor.point.col = 0;
}

export fn print_insert(term: *types.Terminal, width: c_int) void {
    if (!term.insert_mode)
        return;

    std.debug.assert(width > 0);

    const grid = term.grid.?;
    const cur_row = grid.cur_row.?;
    const cells = cur_row.cells.?;
    const col: usize = @intCast(grid.cursor.point.col);
    const width_u: usize = @intCast(width);
    const cols: usize = @intCast(term.cols);

    const move_count: usize = if (cols > col + width_u) cols - col - width_u else 0;

    std.mem.copyBackwards(
        types.Cell,
        cells[col + width_u .. col + width_u + move_count],
        cells[col .. col + move_count],
    );

    // Mark moved cells as dirty
    var i: usize = col + width_u;
    while (i < cols) : (i += 1)
        cells[i].attrs.clean = false;
}

//
// Chunk T6 (part 2) — bell + keyboard focus-in. term_kbd_focus_out() needs
// term->wl->seats and stays in C until the wayland port.
//

extern fn wayl_win_set_urgent(window: ?*anyopaque) callconv(.c) bool;
extern fn wayl_win_ring_bell(window: ?*anyopaque) void;
extern fn notify_notify(term: *types.Terminal, notif: *types.Notification) callconv(.c) bool;
extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;

const O_RDONLY: c_int = 0;

export fn term_bell(term: *types.Terminal) void {
    if (!term.bell_action_enabled)
        return;

    if (term.conf.?.bell.urgent and !term.kbd_focus) {
        if (!wayl_win_set_urgent(term.window)) {
            // Urgency (xdg-activation) is relatively new in Wayland. Fall
            // back to the old, "faked", urgency: red window margins.
            term.render.urgency = true;
            term_damage_margins(term);
        }
    }

    if (term.conf.?.bell.system_bell)
        wayl_win_ring_bell(term.window);

    if (term.conf.?.bell.notify) {
        var notif = std.mem.zeroes(types.Notification);
        notif.title = xstrdup("Bell");
        notif.body = xstrdup("Bell in terminal");
        notif.expire_time = -1;
        notif.focus = true;
        _ = notify_notify(term, &notif);
    }

    if (term.conf.?.bell.flash)
        term_flash(term, 100);

    const bell_command = term.conf.?.bell.command.argv.args;
    if (bell_command != null and
        (!term.kbd_focus or term.conf.?.bell.command_focused))
    {
        const argv: [*c]const [*c]u8 = @ptrCast(bell_command.?);
        const devnull = open("/dev/null", O_RDONLY);
        _ = spawn(term.reaper, null, argv, devnull, -1, -1, null, null, null);

        if (devnull >= 0)
            _ = close(devnull);
    }
}

export fn term_kbd_focus_in(term: *types.Terminal) void {
    if (term.kbd_focus)
        return;

    term.kbd_focus = true;

    if (term.render.urgency) {
        term.render.urgency = false;
        term_damage_margins(term);
    }

    cursor_refresh(term);

    if (term.focus_events)
        _ = term_to_slave(term, "\x1b[I", 3);
}

//
// erase_cell_range / erase_line — grid helpers, called from term_erase()
// (already Zig) through terminal_shim_erase_line() and by C for now.
//

const COLOR_SRC_DEFAULT: u2 = 0;

export fn erase_cell_range(term: *types.Terminal, r: *types.Row, start: c_int, end: c_int) void {
    std.debug.assert(start < term.cols);
    std.debug.assert(end < term.cols);

    r.dirty = true;

    const cells = r.cells.?;
    const bg_src = term.vt.attrs.bg_src;

    if (bg_src != COLOR_SRC_DEFAULT) {
        var col = start;
        while (col <= end) : (col += 1) {
            const c = &cells[@intCast(col)];
            c.wc = 0;
            c.attrs = std.mem.zeroes(types.Attributes);
            c.attrs.bg_src = bg_src;
            c.attrs.bg = term.vt.attrs.bg;
        }
    } else {
        const first: usize = @intCast(start);
        const count: usize = @intCast(end - start + 1);
        @memset(cells[first .. first + count], std.mem.zeroes(types.Cell));
    }

    if (r.extra != null) {
        grid_row_uri_range_erase(r, start, end);
        grid_row_underline_range_erase(r, start, end);
    }
}

export fn erase_line(term: *types.Terminal, r: *types.Row) void {
    erase_cell_range(term, r, 0, term.cols - 1);
    r.linebreak = true;
    r.shell_integration.prompt_marker = false;
    r.shell_integration.cmd_start = -1;
    r.shell_integration.cmd_end = -1;
}

//
// Chunk C1 — IME enable/disable/reset.
//
// The terminal-level wrappers around ime.c: they fan out to every seat that
// currently has keyboard focus on this terminal. `struct seat`/`struct
// wayland` are mirrored (Track B), so the walk is direct.
//
// The C original wrapped everything in `#if FOOT_IME_ENABLED`; meson now
// refuses to configure the Zig wayland mirrors without IME support, so there
// is no off case left to compile.
//

const LOG_CLASS_DEBUG: c_int = 4;

extern fn ime_enable(seat: *types.Seat) callconv(.c) void;
extern fn ime_disable(seat: *types.Seat) callconv(.c) void;
extern fn ime_reset_preedit(seat: *types.Seat) callconv(.c) void;

/// tll_foreach(term->wl->seats, it)
const SeatIter = struct {
    node: ?*anyopaque,

    fn next(self: *SeatIter) ?*types.Seat {
        const raw = self.node orelse return null;
        const node: *types.TllNode(types.Seat) = @ptrCast(@alignCast(raw));
        self.node = node.next;
        return &node.item;
    }
};

fn seats(term: *const types.Terminal) SeatIter {
    const wayl = term.wl orelse return .{ .node = null };
    return .{ .node = wayl.seats.head };
}

/// The seats whose keyboard focus is `term`.
fn focusedOn(seat: *types.Seat, term: *const types.Terminal) bool {
    const focus = seat.kbd_focus orelse return false;
    return focus == term;
}

export fn term_ime_is_enabled(term: *const types.Terminal) callconv(.c) bool {
    return term.ime_enabled;
}

export fn term_ime_enable(term: *types.Terminal) callconv(.c) void {
    if (term.ime_enabled)
        return;

    log_msg(
        LOG_CLASS_DEBUG,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "IME enabled",
    );

    term.ime_enabled = true;

    // IME is per seat - enable on all seats currently focusing us
    var it = seats(term);
    while (it.next()) |seat| {
        if (focusedOn(seat, term))
            ime_enable(seat);
    }
}

export fn term_ime_disable(term: *types.Terminal) callconv(.c) void {
    if (!term.ime_enabled)
        return;

    log_msg(
        LOG_CLASS_DEBUG,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "IME disabled",
    );

    term.ime_enabled = false;

    // IME is per seat - disable on all seats currently focusing us
    var it = seats(term);
    while (it.next()) |seat| {
        if (focusedOn(seat, term))
            ime_disable(seat);
    }
}

export fn term_ime_reset(term: *types.Terminal) callconv(.c) bool {
    var at_least_one_seat_was_reset = false;

    var it = seats(term);
    while (it.next()) |seat| {
        if (!focusedOn(seat, term))
            continue;

        ime_reset_preedit(seat);
        at_least_one_seat_was_reset = true;
    }

    return at_least_one_seat_was_reset;
}

export fn term_ime_set_cursor_rect(
    term: *types.Terminal,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    var it = seats(term);
    while (it.next()) |seat| {
        if (focusedOn(seat, term)) {
            seat.ime.cursor_rect.pending.x = x;
            seat.ime.cursor_rect.pending.y = y;
            seat.ime.cursor_rect.pending.width = width;
            seat.ime.cursor_rect.pending.height = height;
        }
    }
}

//
// Chunk C2 — mouse grab state and cursor shape selection.
//
// term_mouse_grabbed() and the term_xcursor_update() pair lived in terminal.c;
// the CSD border corner helpers (is_top_left() and friends) and
// xcursor_for_csd_border() lived in input.c. All of them are pure decisions
// over the terminal/seat/window mirrors, so they are ported here. The
// remaining dependencies are the modifier/key-binding lookups
// (input.zig/key-binding.zig), the xcursor loader (render.zig) and the
// cursor-shape name mapping (cursor-shape.zig).
//

extern fn get_current_modifiers(
    seat: *const types.Seat,
    effective: ?*u32, // xkb_mod_mask_t *
    consumed: ?*u32,
    key: u32,
    filter_locked: bool,
) callconv(.c) void;

/// key-binding.h's `struct key_binding_set` now lives in terminal_types.zig.
const KeyBindingSet = types.KeyBindingSet;

extern fn key_binding_for(
    mgr: ?*anyopaque,
    conf: ?*const types.Config,
    seat: *const types.Seat,
) callconv(.c) ?*KeyBindingSet;
extern fn render_xcursor_is_valid(seat: *const types.Seat, xcursor: [*c]const u8) callconv(.c) bool;
extern fn render_xcursor_set(seat: *types.Seat, term: *types.Terminal, shape: types.CursorShape) callconv(.c) bool;
extern fn cursor_string_to_server_shape(xcursor: [*c]const u8, bound_version: c_int) callconv(.c) c_int;
extern fn bug(file: [*:0]const u8, line: c_int, func: [*:0]const u8, fmt: [*:0]const u8, ...) callconv(.c) noreturn;

/// A missing wayland instance can't produce override modifiers, and C never
/// dereferences it in a valid program: the `orelse` paths below degrade to
/// the same "no override modifiers pressed" answer the C expression gives.
export fn term_mouse_grabbed(term: *const types.Terminal, seat: *const types.Seat) callconv(.c) bool {
    var mods: u32 = 0;
    get_current_modifiers(seat, &mods, null, 0, true);

    const wayl = term.wl orelse return term.mouse_tracking == .none;
    const bindings = key_binding_for(wayl.key_binding_manager, term.conf, seat) orelse
        return term.mouse_tracking == .none;

    const override_modmask = bindings.selection_overrides;
    const has_focus = if (seat.kbd_focus) |focus| focus == term else false;
    const override_mods_pressed = seat.kbd.xkb_keymap != null and
        mods != 0 and (mods & override_modmask) == override_modmask;

    return term.mouse_tracking == .none or
        (has_focus and override_mods_pressed);
}

//
// CSD border hit testing. C compares an integer coordinate against a float
// expression, i.e. single precision (int -> float); mirrored the same way.
//

fn csdTitleSize(term: *const types.Terminal) f32 {
    const conf = term.conf orelse return 0;
    return @floatFromInt(conf.csd.title_height);
}

fn csdBorderSize(term: *const types.Terminal) f32 {
    const conf = term.conf orelse return 0;
    return @floatFromInt(conf.csd.border_width);
}

fn isTopLeft(term: *const types.Terminal, x: c_int, y: c_int) bool {
    const win = term.window orelse return false;
    const scale = term.scale;
    return !win.is_constrained_top and !win.is_constrained_left and
        ((term.active_surface == .border_left and
            @as(f32, @floatFromInt(y)) < 10.0 * scale) or
            (term.active_surface == .border_top and
                @as(f32, @floatFromInt(x)) < (10.0 + csdBorderSize(term)) * scale));
}

fn isTopRight(term: *const types.Terminal, x: c_int, y: c_int) bool {
    const win = term.window orelse return false;
    const scale = term.scale;
    return !win.is_constrained_top and !win.is_constrained_right and
        ((term.active_surface == .border_right and
            @as(f32, @floatFromInt(y)) < 10.0 * scale) or
            (term.active_surface == .border_top and
                @as(f32, @floatFromInt(x)) > @as(f32, @floatFromInt(term.width)) +
                    csdBorderSize(term) * scale - 10.0 * scale));
}

fn isBottomLeft(term: *const types.Terminal, x: c_int, y: c_int) bool {
    const win = term.window orelse return false;
    const scale = term.scale;
    return !win.is_constrained_bottom and !win.is_constrained_left and
        ((term.active_surface == .border_left and
            @as(f32, @floatFromInt(y)) > csdTitleSize(term) * scale +
                @as(f32, @floatFromInt(term.height))) or
            (term.active_surface == .border_bottom and
                @as(f32, @floatFromInt(x)) < (10.0 + csdBorderSize(term)) * scale));
}

fn isBottomRight(term: *const types.Terminal, x: c_int, y: c_int) bool {
    const win = term.window orelse return false;
    const scale = term.scale;
    return !win.is_constrained_bottom and !win.is_constrained_right and
        ((term.active_surface == .border_right and
            @as(f32, @floatFromInt(y)) > csdTitleSize(term) * scale +
                @as(f32, @floatFromInt(term.height))) or
            (term.active_surface == .border_bottom and
                @as(f32, @floatFromInt(x)) > @as(f32, @floatFromInt(term.width)) +
                    csdBorderSize(term) * scale - 10.0 * scale));
}

// Exported because input.c's border-drag code still calls these helpers
// (it is ported in track D4).

export fn is_top_left(term: *const types.Terminal, x: c_int, y: c_int) callconv(.c) bool {
    return isTopLeft(term, x, y);
}

export fn is_top_right(term: *const types.Terminal, x: c_int, y: c_int) callconv(.c) bool {
    return isTopRight(term, x, y);
}

export fn is_bottom_left(term: *const types.Terminal, x: c_int, y: c_int) callconv(.c) bool {
    return isBottomLeft(term, x, y);
}

export fn is_bottom_right(term: *const types.Terminal, x: c_int, y: c_int) callconv(.c) bool {
    return isBottomRight(term, x, y);
}

export fn xcursor_for_csd_border(term: *types.Terminal, x: c_int, y: c_int) callconv(.c) types.CursorShape {
    const win = term.window orelse {
        bug(@src().file, @intCast(@src().line), "xcursor_for_csd_border", "no window");
    };

    if (isTopLeft(term, x, y))
        return .top_left_corner
    else if (isTopRight(term, x, y))
        return .top_right_corner
    else if (isBottomLeft(term, x, y))
        return .bottom_left_corner
    else if (isBottomRight(term, x, y))
        return .bottom_right_corner
    else if (term.active_surface == .border_left)
        return if (!win.is_constrained_left) .left_side else .left_ptr
    else if (term.active_surface == .border_right)
        return if (!win.is_constrained_right) .right_side else .left_ptr
    else if (term.active_surface == .border_top)
        return if (!win.is_constrained_top) .top_side else .left_ptr
    else if (term.active_surface == .border_bottom)
        return if (!win.is_constrained_bottom) .bottom_side else .left_ptr
    else {
        bug(@src().file, @intCast(@src().line), "xcursor_for_csd_border", "Unreachable");
    }
}

export fn term_xcursor_update_for_seat(term: *types.Terminal, seat: *types.Seat) callconv(.c) void {
    const shape: types.CursorShape = switch (term.active_surface) {
        .grid => blk: {
            if (seat.pointer.hidden)
                break :blk .hidden;

            // C dereferences term->wl here; a missing wayland instance is
            // invalid, so treat it as "no server-side cursor support".
            const shape_manager_version: c_int = if (term.wl) |wayl|
                wayl.shape_manager_version
            else
                0;

            if (cursor_string_to_server_shape(term.mouse_user_cursor, shape_manager_version) != 0 or
                render_xcursor_is_valid(seat, term.mouse_user_cursor))
            {
                break :blk .custom;
            }

            if (term_mouse_grabbed(term, seat))
                break :blk .text;

            break :blk .left_ptr;
        },

        .title, .button_minimize, .button_maximize, .button_close => .left_ptr,

        .border_left, .border_right, .border_top, .border_bottom => xcursor_for_csd_border(
            term,
            seat.mouse.x,
            seat.mouse.y,
        ),

        .none => return,
    };

    if (shape == .none)
        bug(@src().file, @intCast(@src().line), "term_xcursor_update_for_seat", "xcursor not set");

    _ = render_xcursor_set(seat, term, shape);
}

export fn term_xcursor_update(term: *types.Terminal) callconv(.c) void {
    var it = seats(term);
    while (it.next()) |seat|
        term_xcursor_update_for_seat(term, seat);
}
//
// Chunk C3a — the delayed-render timer, window-configured and the render
// worker pool. All three were static in terminal.c. The deadline arithmetic is
// already Zig; what remains here is the fdm/timer plumbing and C11 thread
// setup, which are thin libc calls.
//

extern fn wayl_do_linear_blending(wayl: ?*const types.Wayland, conf: ?*const types.Config) callconv(.c) bool;

fn fdmPtmxAdapter(fdm_opaque: *anyopaque, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    return fdm_ptmx(fdm_opaque, fd, events, data);
}

export fn term_window_configured(term: *types.Terminal) callconv(.c) void {
    // Enable the ptmx FDM callback
    if (!term.shutdown.in_progress) {
        const win = term.window orelse
            bug(@src().file, @intCast(@src().line), "term_window_configured", "no window");
        if (!win.is_configured)
            bug(@src().file, @intCast(@src().line), "term_window_configured", "assertion failed: 'term->window->is_configured'");

        _ = fdm_add(term.fdm orelse return, term.ptmx, EPOLLIN, &fdmPtmxAdapter, term);

        const gamma_correct = wayl_do_linear_blending(term.wl, term.conf);
        log_msg(
            LOG_CLASS_INFO,
            "terminal",
            "terminal.zig",
            @intCast(@src().line),
            "gamma-correct blending: %s",
            @as([*:0]const u8, if (gamma_correct) "enabled" else "disabled"),
        );
    }
}

export fn fdm_delayed_render(
    fdm_opaque: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fdm_opaque;
    if (events & EPOLLHUP != 0) return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    var unused: u64 = 0;
    var ret1: isize = 0;
    var ret2: isize = 0;

    if (fd == term.delayed_render_timer.lower_fd)
        ret1 = read(term.delayed_render_timer.lower_fd, &unused, @sizeOf(u64));
    if (fd == term.delayed_render_timer.upper_fd)
        ret2 = read(term.delayed_render_timer.upper_fd, &unused, @sizeOf(u64));

    if (ret1 < 0 or ret2 < 0) {
        if (__errno_location().* == EAGAIN) return true;

        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to read timeout timer");
        return false;
    }

    if (ret1 > 0)
        log_msg(LOG_CLASS_DEBUG, "terminal", "terminal.zig", @intCast(@src().line), "lower delay timer expired")
    else if (ret2 > 0)
        log_msg(LOG_CLASS_DEBUG, "terminal", "terminal.zig", @intCast(@src().line), "upper delay timer expired");

    if (ret1 == 0 and ret2 == 0) return true;

    // Reset the timers
    const reset: types.Itimerspec = std.mem.zeroes(types.Itimerspec);
    _ = timerfd_settime(term.delayed_render_timer.lower_fd, 0, &reset, null);
    _ = timerfd_settime(term.delayed_render_timer.upper_fd, 0, &reset, null);
    term.delayed_render_timer.is_armed = false;

    render_refresh(term);
    return true;
}

//
// Render workers. The semaphores/mutex/condition variable are byte blobs in
// the mirror (their pthread layout is opaque to Zig, but the size is pinned by
// the ABI probe), so they are passed through by address.
//

extern fn sem_init(sem: *anyopaque, pshared: c_int, value: c_uint) callconv(.c) c_int;
extern fn sem_destroy(sem: *anyopaque) callconv(.c) c_int;
extern fn mtx_init(mtx: *anyopaque, mtx_type: c_int) callconv(.c) c_int;
extern fn cnd_init(cond: *anyopaque) callconv(.c) c_int;
// C11 thrd_create()/thrd_join() are broken when called from a Zig object in
// this environment (thrd_create returns thrd_success, then thrd_join fails
// with thrd_error and the thread is never reaped - reproduced in a 20-line
// standalone program, while the same calls from C work). glibc's thrd_* are
// thin wrappers around pthread_* and thrd_t IS pthread_t, so the pthread
// entry points are used directly; only the error codes differ (errno instead
// of thrd_*), which shows up in a log message on a failure path only.
extern fn pthread_create(
    thr: *anyopaque,
    attr: ?*const anyopaque,
    func: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) c_int;
const RENDER_WORKER_STACK_SIZE: usize = 16 * 1024 * 1024;

extern fn pthread_attr_init(attr: *anyopaque) callconv(.c) c_int;
extern fn pthread_attr_setstacksize(attr: *anyopaque, size: usize) callconv(.c) c_int;
extern fn terminal_shim_thrd_err_as_string(err: c_int) callconv(.c) [*:0]const u8;
extern fn render_worker_thread(ctx: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn xcalloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque;

const THRD_SUCCESS: c_int = 0;
const MTX_PLAIN: c_int = 0;

/// render.h's `struct render_worker_context` (my_id comes first).
const RenderWorkerContext = extern struct {
    my_id: c_int,
    _pad: [4]u8 = undefined,
    term: *types.Terminal,
};

export fn initialize_render_workers(term: *types.Terminal) callconv(.c) bool {
    log_msg(
        LOG_CLASS_INFO,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "using %hu rendering threads",
        @as(c_uint, term.render.workers.count),
    );

    const start: *anyopaque = @ptrCast(@alignCast(&term.render.workers.start));
    const done: *anyopaque = @ptrCast(@alignCast(&term.render.workers.done));
    const lock: *anyopaque = @ptrCast(@alignCast(&term.render.workers.lock));

    if (sem_init(start, 0, 0) < 0 or sem_init(done, 0, 0) < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to instantiate render worker semaphores");
        return false;
    }

    const err = mtx_init(lock, MTX_PLAIN);
    if (err != THRD_SUCCESS) {
        log_msg(
            LOG_CLASS_ERROR,
            "terminal",
            "terminal.zig",
            @intCast(@src().line),
            "failed to instantiate render worker mutex: %s (%d)",
            @as([*:0]const u8, terminal_shim_thrd_err_as_string(err)),
            err,
        );
        _ = sem_destroy(start);
        _ = sem_destroy(done);
        return false;
    }

    _ = mtx_init(@ptrCast(@alignCast(&term.render.workers.preapplied_damage.lock)), MTX_PLAIN);
    _ = cnd_init(@ptrCast(@alignCast(&term.render.workers.preapplied_damage.cond)));

    const count = @as(usize, term.render.workers.count);
    term.render.workers.threads = xcalloc(count, @sizeOf(u64));
    const threads: [*]u64 = @ptrCast(@alignCast(term.render.workers.threads.?));

    // Render workers get an explicit stack size. A Debug (-O Debug) build
    // peaks above the 8 MiB pthread default while rendering a row for a wide
    // grid: 8 MiB crashes deterministically (SIGSEGV inside whatever library
    // call runs at the boundary), 12 MiB and 16 MiB are clean. ReleaseSafe
    // needs well under 8 MiB. 16 MiB is lazy-committed, so the cost is address
    // space only. Shrinking the Debug frames is tracked as a follow-up.
    var attr: [64]u8 align(16) = undefined;
    _ = pthread_attr_init(&attr);
    _ = pthread_attr_setstacksize(&attr, RENDER_WORKER_STACK_SIZE);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ctx: *RenderWorkerContext = @ptrCast(@alignCast(xmalloc(@sizeOf(RenderWorkerContext)).?));
        ctx.* = .{ .my_id = @intCast(1 + i), .term = term };

        const ret = pthread_create(@ptrCast(&threads[i]), &attr, &render_worker_thread, ctx);
        if (ret != THRD_SUCCESS) {
            log_msg(
                LOG_CLASS_ERROR,
                "terminal",
                "terminal.zig",
                @intCast(@src().line),
                "failed to create render worker thread: %s (%d)",
                @as([*:0]const u8, terminal_shim_thrd_err_as_string(ret)),
                ret,
            );
            threads[i] = 0;
            return false;
        }
    }

    return true;
}
//
// Chunk C3b — the utmp helper records. Both were static in terminal.c and are
// only compiled in when meson found a utmp backend (UTMP_ADD/UTMP_DEL); that
// is mirrored as build options, so the "no backend" build still returns true
// without spawning anything, exactly like the old #else arm.
//

extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8;

fn utmpHelperPath(conf: ?*const types.Config) ?[*:0]const u8 {
    if (comptime !build_options.utmp_enabled) return null;
    const c = conf orelse return null;
    return c.utmp_helper_path;
}

export fn add_utmp_record(conf: ?*const types.Config, reaper: ?*anyopaque, ptmx: c_int) callconv(.c) bool {
    if (comptime !build_options.utmp_enabled)
        return true;

    if (ptmx < 0)
        return true;

    const helper = utmpHelperPath(conf) orelse return true;

    // NOTE: a NULL wayland display terminates argv early, which is what C's
    // {helper, UTMP_ADD, getenv(...), NULL} does as well.
    const argv = [_:null]?[*:0]const u8{
        helper,
        build_options.utmp_add,
        getenv("WAYLAND_DISPLAY"),
    };

    return spawn(reaper, null, @ptrCast(&argv), ptmx, -1, -1, null, null, null) >= 0;
}

export fn del_utmp_record(conf: ?*const types.Config, reaper: ?*anyopaque, ptmx: c_int) callconv(.c) bool {
    if (comptime !build_options.utmp_enabled)
        return true;

    if (ptmx < 0)
        return true;

    const helper = utmpHelperPath(conf) orelse return true;

    const del_argument: ?[*:0]u8 = if (comptime build_options.utmp_del_have_argument)
        getenv("WAYLAND_DISPLAY")
    else
        null;

    const argv = [_:null]?[*:0]const u8{
        helper,
        build_options.utmp_del,
        del_argument,
    };

    return spawn(reaper, null, @ptrCast(&argv), ptmx, -1, -1, null, null, null) >= 0;
}
//
// Chunk C4a — the two small leftovers: keyboard focus-out and the surface
// kind lookup. Both were the last functions in terminal.c that only read the
// mirrors.
//

/// meson refuses to configure a Zig build with -Dime=false (the wayland.h
/// mirrors assume IME), so the C's `#if FOOT_IME_ENABLED` guard is a constant.
export fn term_kbd_focus_out(term: *types.Terminal) callconv(.c) void {
    if (!term.kbd_focus)
        return;

    var it = seats(term);
    while (it.next()) |seat| {
        if (focusedOn(seat, term))
            return;
    }

    if (term_ime_reset(term))
        render_refresh(term);

    term.kbd_focus = false;
    cursor_refresh(term);

    if (term.focus_events)
        _ = term_to_slave(term, "\x1b[O", 3);
}

export fn term_surface_kind(
    term: *const types.Terminal,
    surface: ?*const anyopaque,
) callconv(.c) types.TermSurface {
    const win = term.window orelse return .none;

    if (surface == win.surface.surf)
        return .grid;

    const csd = &win.csd.surface;
    if (surface == csd[@intFromEnum(types.CsdSurface.title)].surface.surf)
        return .title;
    if (surface == csd[@intFromEnum(types.CsdSurface.left)].surface.surf)
        return .border_left;
    if (surface == csd[@intFromEnum(types.CsdSurface.right)].surface.surf)
        return .border_right;
    if (surface == csd[@intFromEnum(types.CsdSurface.top)].surface.surf)
        return .border_top;
    if (surface == csd[@intFromEnum(types.CsdSurface.bottom)].surface.surf)
        return .border_bottom;
    if (surface == csd[@intFromEnum(types.CsdSurface.minimize)].surface.surf)
        return .button_minimize;
    if (surface == csd[@intFromEnum(types.CsdSurface.maximize)].surface.surf)
        return .button_maximize;
    if (surface == csd[@intFromEnum(types.CsdSurface.close)].surface.surf)
        return .button_close;

    return .none;
}
//
// Chunk C4b — the shutdown sequence. shutdown_maybe_done(),
// fdm_client_terminated(), fdm_shutdown(), fdm_terminate_timeout() and
// term_shutdown() were static/global in terminal.c. term_destroy() was ported
// in C5 and is exported from this file; everything else reads the mirrors.
//

extern fn wayl_win_destroy(win: ?*types.WlWindow) callconv(.c) void;
extern fn kill(pid: c_int, sig: c_int) callconv(.c) c_int;
extern fn eventfd(initval: c_uint, flags: c_int) callconv(.c) c_int;
extern fn write(fd: c_int, buf: *const anyopaque, count: usize) callconv(.c) isize;

// Linux signal numbers and eventfd(2) flags, like the EPOLL* constants above.
const SIGHUP: c_int = 1;
const SIGKILL: c_int = 9;
const SIGTERM: c_int = 15;
const EFD_CLOEXEC: c_int = 0x80000;
const EFD_NONBLOCK: c_int = 0x800;

fn shutdown_maybe_done(term: *types.Terminal) void {
    const shutdown_done =
        term.window == null and term.shutdown.client_has_terminated;

    const win_ptr: ?*anyopaque = if (term.window) |w| @ptrCast(w) else null;
    log_msg(
        LOG_CLASS_DEBUG,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "window=%p, slave-has-been-reaped=%d --> %s",
        win_ptr,
        @as(c_int, @intFromBool(term.shutdown.client_has_terminated)),
        @as([*:0]const u8, if (shutdown_done)
            "shutdown done, calling term_destroy()"
        else
            "no action"),
    );

    if (!shutdown_done)
        return;

    const cb = term.shutdown.cb;
    const cb_data = term.shutdown.cb_data;

    const exit_code = term_destroy(term);
    if (cb) |raw| {
        const f: *const fn (?*anyopaque, c_int) callconv(.c) void =
            @ptrCast(@alignCast(raw));
        f(cb_data, exit_code);
    }
}

export fn fdm_client_terminated(
    reaper: ?*anyopaque,
    pid: c_int,
    status: c_int,
    data: ?*anyopaque,
) callconv(.c) void {
    _ = reaper;
    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return));

    log_msg(
        LOG_CLASS_DEBUG,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "slave (PID=%u) died",
        pid,
    );

    term.shutdown.client_has_terminated = true;
    term.shutdown.exit_status = status;

    if (term.shutdown.terminate_timeout_fd >= 0) {
        if (term.fdm) |fdm_ptr| _ = fdm_del(fdm_ptr, term.shutdown.terminate_timeout_fd);
        term.shutdown.terminate_timeout_fd = -1;
    }

    if (term.shutdown.in_progress)
        shutdown_maybe_done(term)
    else if (term.conf) |conf| {
        if (!conf.hold_at_exit)
            _ = term_shutdown(term);
    }
}

fn fdm_shutdown(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = events;
    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    // Kill the event FD
    if (term.fdm) |fdm_ptr| _ = fdm_del(fdm_ptr, fd);
    _ = fdm;

    wayl_win_destroy(term.window);
    term.window = null;

    // Normally we'd get unmapped when we destroy the wayland window above.
    // However, under certain conditions those events are deferred (for
    // example, when a screen locker is active), so we may get here without
    // having been unmapped.
    var it = seats(term);
    while (it.next()) |seat| {
        if (seat.kbd_focus == term) seat.kbd_focus = null;
        if (seat.mouse_focus == term) seat.mouse_focus = null;
    }

    shutdown_maybe_done(term);
    return true;
}

fn fdm_terminate_timeout(
    fdm: ?*anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fdm;
    _ = events;

    var unused: u64 = 0;
    const bytes = read(fd, &unused, @sizeOf(u64));
    if (bytes < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to read from slave terminate timeout FD");
        return false;
    }

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));
    if (term.shutdown.client_has_terminated)
        bug(@src().file, @intCast(@src().line), "fdm_terminate_timeout", "assertion failed: '!term->shutdown.client_has_terminated'");

    log_msg(
        LOG_CLASS_DEBUG,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "slave (PID=%u) has not terminated, sending %s (%d)",
        term.slave,
        @as([*:0]const u8, if (term.shutdown.next_signal == SIGTERM)
            "SIGTERM"
        else if (term.shutdown.next_signal == SIGKILL)
            "SIGKILL"
        else
            "<unknown>"),
        term.shutdown.next_signal,
    );

    _ = kill(-term.slave, term.shutdown.next_signal);

    switch (term.shutdown.next_signal) {
        SIGTERM => term.shutdown.next_signal = SIGKILL,

        SIGKILL => {
            // Disarm. Shouldn't be necessary, as we should be able to shut
            // down completely after sending SIGKILL, before the next timeout
            // occurs. But let's play it safe...
            if (term.shutdown.terminate_timeout_fd >= 0) {
                const zero: types.Itimerspec = std.mem.zeroes(types.Itimerspec);
                _ = timerfd_settime(term.shutdown.terminate_timeout_fd, 0, &zero, null);
            }
        },

        else => {
            bug(@src().file, @intCast(@src().line), "fdm_terminate_timeout", "can only handle SIGTERM and SIGKILL");
        },
    }

    return true;
}

export fn term_shutdown(term: *types.Terminal) callconv(.c) bool {
    if (term.shutdown.in_progress)
        return true;

    term.shutdown.in_progress = true;

    // Close FDs, then postpone self-destruction to the next poll iteration by
    // creating an event FD that we trigger immediately.
    term_cursor_blink_update(term);
    if (term.cursor_blink.fd >= 0)
        bug(@src().file, @intCast(@src().line), "term_shutdown", "assertion failed: 'term->cursor_blink.fd < 0'");

    if (term.fdm) |fdm_ptr| {
        _ = fdm_del(fdm_ptr, term.selection.auto_scroll.fd);
        _ = fdm_del(fdm_ptr, term.render.app_sync_updates.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.app_id.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.icon.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.title.timer_fd);
        _ = fdm_del(fdm_ptr, term.delayed_render_timer.lower_fd);
        _ = fdm_del(fdm_ptr, term.delayed_render_timer.upper_fd);
        _ = fdm_del(fdm_ptr, term.blink.fd);
        _ = fdm_del(fdm_ptr, term.flash.fd);
    }

    _ = del_utmp_record(term.conf, term.reaper, term.ptmx);

    if (term.window != null and term.window.?.is_configured) {
        if (term.fdm) |fdm_ptr| _ = fdm_del(fdm_ptr, term.ptmx);
    } else {
        _ = close(term.ptmx);
    }

    if (!term.shutdown.client_has_terminated) {
        if (term.slave <= 0) {
            term.shutdown.client_has_terminated = true;
        } else {
            log_msg(
                LOG_CLASS_DEBUG,
                "terminal",
                "terminal.zig",
                @intCast(@src().line),
                "initiating asynchronous terminate of slave; sending SIGHUP to PID=%u",
                term.slave,
            );

            _ = kill(-term.slave, SIGHUP);

            // Set up a timer with an interval: on the first timeout we send
            // SIGTERM. If the client still isn't terminating, we wait another
            // interval and then send SIGKILL.
            const timeout: types.Itimerspec = .{
                .it_value = .{ .tv_sec = 30, .tv_nsec = 0 },
                .it_interval = .{ .tv_sec = 30, .tv_nsec = 0 },
            };

            const timeout_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
            if (timeout_fd < 0 or
                timerfd_settime(timeout_fd, 0, &timeout, null) < 0 or
                term.fdm == null or
                !fdm_add(term.fdm.?, timeout_fd, EPOLLIN, &fdm_terminate_timeout, term))
            {
                if (timeout_fd >= 0) _ = close(timeout_fd);
                log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create slave terminate timeout FD");
                return false;
            }

            if (term.shutdown.terminate_timeout_fd >= 0)
                bug(@src().file, @intCast(@src().line), "term_shutdown", "assertion failed: 'term->shutdown.terminate_timeout_fd < 0'");
            term.shutdown.terminate_timeout_fd = timeout_fd;
            term.shutdown.next_signal = SIGTERM;
        }
    }

    term.selection.auto_scroll.fd = -1;
    term.render.app_sync_updates.timer_fd = -1;
    term.render.app_id.timer_fd = -1;
    term.render.icon.timer_fd = -1;
    term.render.title.timer_fd = -1;
    term.delayed_render_timer.lower_fd = -1;
    term.delayed_render_timer.upper_fd = -1;
    term.blink.fd = -1;
    term.flash.fd = -1;
    term.ptmx = -1;

    const event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (event_fd == -1) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create terminal shutdown event FD");
        return false;
    }

    if (term.fdm == null or !fdm_add(term.fdm.?, event_fd, EPOLLIN, &fdm_shutdown, term)) {
        _ = close(event_fd);
        return false;
    }

    var one: u64 = 1;
    if (write(event_fd, &one, @sizeOf(u64)) != @sizeOf(u64)) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to send terminal shutdown event");
        if (term.fdm) |fdm_ptr| _ = fdm_del(fdm_ptr, event_fd);
        return false;
    }

    return true;
}
//
// Chunk C5 — term_destroy(). The teardown order is load-bearing (workers are
// woken and joined before their queues and locks go away, the slave is reaped
// last), so this is a straight transcription of the C, with the two C-only
// pieces kept in C: the waitpid status macros (terminal-shim.c) and struct
// sigaction (the KSigaction/SigSet pattern fdm.zig already uses).
//

extern fn urls_reset(term: *types.Terminal) callconv(.c) void;
extern fn composed_free(node: ?*types.Composed) callconv(.c) void;
extern fn shm_unref(buf: ?*anyopaque) callconv(.c) void;
extern fn shm_chain_free(chain: ?*anyopaque) callconv(.c) void;
extern fn pixman_region32_fini(region: *anyopaque) callconv(.c) void;
extern fn notify_free(term: *types.Terminal, notification: *types.Notification) callconv(.c) void;
extern fn notify_icon_free(icon: *types.NotificationIcon) callconv(.c) void;
extern fn sixel_fini(term: *types.Terminal) callconv(.c) void;
extern fn grid_free(grid: *types.Grid) callconv(.c) void;
extern fn reaper_del(reaper: ?*anyopaque, pid: c_int) callconv(.c) void;
extern fn key_binding_unref(mgr: ?*anyopaque, conf: ?*const types.Config) callconv(.c) void;
extern fn pthread_join(thr: u64, res: ?*?*anyopaque) callconv(.c) c_int;
extern fn mtx_destroy(mtx: *anyopaque) callconv(.c) void;
extern fn cnd_destroy(cond: *anyopaque) callconv(.c) void;
extern fn sem_post(sem: *anyopaque) callconv(.c) c_int;
extern fn mtx_lock(mtx: *anyopaque) callconv(.c) c_int;
extern fn mtx_unlock(mtx: *anyopaque) callconv(.c) c_int;
extern fn malloc_trim(pad: usize) callconv(.c) c_int;
extern fn strsignal(sig: c_int) callconv(.c) [*:0]u8;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) callconv(.c) c_int;
extern fn alarm(seconds: c_uint) callconv(.c) c_uint;

// sys/wait.h's status macros are C-only; the shim keeps the platform's exact
// encoding instead of hard-coding the Linux one.
extern fn terminal_shim_wifexited(status: c_int) callconv(.c) c_int;
extern fn terminal_shim_wexitstatus(status: c_int) callconv(.c) c_int;
extern fn terminal_shim_wifsignaled(status: c_int) callconv(.c) c_int;
extern fn terminal_shim_wtermsig(status: c_int) callconv(.c) c_int;

// libc sigaction layout, selected by the target.
const SigSet = std.c.sigset_t;
const KSigaction = std.c.Sigaction;
extern fn sigemptyset(set: *SigSet) callconv(.c) c_int;
extern fn sigaction(sig: c_int, act: ?*const KSigaction, old: ?*KSigaction) callconv(.c) c_int;

const SIGALRM: c_int = @intFromEnum(std.posix.SIG.ALRM);
const SIG_DFL_HANDLER: ?KSigaction.handler_fn = std.posix.SIG.DFL;
const EINTR: c_int = @intFromEnum(std.c.E.INTR);

var alarm_raised: c_int = 0;

fn sigAlarm(signo: c_int) callconv(.c) void {
    _ = signo;
    log_msg(LOG_CLASS_DEBUG, "terminal", "terminal.zig", @intCast(@src().line), "SIGALRM");
    alarm_raised = 1;
}

fn zeroSigSet() SigSet {
    return std.mem.zeroes(SigSet);
}

fn installAlarmHandler(handler: ?KSigaction.handler_fn) void {
    var action = KSigaction{
        .handler = .{ .handler = handler },
        .mask = zeroSigSet(),
        .flags = 0,
    };
    _ = sigemptyset(&action.mask);
    _ = sigaction(SIGALRM, &action, null);
}

/// tll_remove() from the middle of wayland'sterms list (tll(struct terminal *)).
fn removeTerm(wayl: *types.Wayland, term: *types.Terminal) void {
    const list: *tll.Tll(?*anyopaque) = @ptrCast(@alignCast(&wayl.terms));
    var node_ptr = list.head;
    while (node_ptr) |node| {
        if (node.item) |item| {
            if (item == @as(?*anyopaque, @ptrCast(term))) {
                list.removeNode(node);
                return;
            }
        }
        node_ptr = node.next;
    }
}

fn freeString(item: ?[*:0]u8) callconv(.c) void {
    std.c.free(item);
}

fn freePtmxBuffer(buf: types.PtmxBuffer) callconv(.c) void {
    std.c.free(buf.data);
}

export fn term_destroy(term_arg: ?*types.Terminal) callconv(.c) c_int {
    const term = term_arg orelse return 0;

    if (term.wl) |wayl|
        removeTerm(wayl, term);

    _ = del_utmp_record(term.conf, term.reaper, term.ptmx);

    if (term.fdm) |fdm_ptr| {
        _ = fdm_del(fdm_ptr, term.selection.auto_scroll.fd);
        _ = fdm_del(fdm_ptr, term.render.app_sync_updates.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.app_id.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.icon.timer_fd);
        _ = fdm_del(fdm_ptr, term.render.title.timer_fd);
        _ = fdm_del(fdm_ptr, term.delayed_render_timer.lower_fd);
        _ = fdm_del(fdm_ptr, term.delayed_render_timer.upper_fd);
        _ = fdm_del(fdm_ptr, term.cursor_blink.fd);
        _ = fdm_del(fdm_ptr, term.blink.fd);
        _ = fdm_del(fdm_ptr, term.flash.fd);
        _ = fdm_del(fdm_ptr, term.ptmx);
        if (term.shutdown.terminate_timeout_fd >= 0)
            _ = fdm_del(fdm_ptr, term.shutdown.terminate_timeout_fd);
    }

    if (term.window != null) {
        wayl_win_destroy(term.window);
        term.window = null;
    }

    const workers_lock: *anyopaque = @ptrCast(@alignCast(&term.render.workers.lock));
    _ = mtx_lock(workers_lock);
    if (term.render.workers.queue.length != 0)
        bug(@src().file, @intCast(@src().line), "term_destroy", "assertion failed: 'tll_length(term->render.workers.queue) == 0'");

    // Count living threads - we may get here when only some of the threads
    // have been successfully started
    var worker_count: usize = 0;
    const worker_threads: ?[*]u64 = if (term.render.workers.threads) |raw|
        @ptrCast(@alignCast(raw))
    else
        null;

    if (worker_threads) |threads| {
        var i: usize = 0;
        while (i < term.render.workers.count) : (i += 1) {
            if (threads[i] == 0)
                break;
            worker_count += 1;
        }

        const queue: *tll.Tll(c_int) = @ptrCast(@alignCast(&term.render.workers.queue));
        const start: *anyopaque = @ptrCast(@alignCast(&term.render.workers.start));
        var j: usize = 0;
        while (j < worker_count) : (j += 1) {
            _ = sem_post(start);
            queue.pushBack(-2);
        }
    }
    _ = mtx_unlock(workers_lock);

    if (term.wl) |wayl|
        key_binding_unref(wayl.key_binding_manager, term.conf);

    urls_reset(term);

    std.c.free(term.vt.osc.data);
    std.c.free(term.vt.osc8.uri);

    composed_free(term.composed);

    std.c.free(term.app_id);
    std.c.free(term.window_title);
    {
        const stack: *tll.Tll(?[*:0]u8) = @ptrCast(@alignCast(&term.window_title_stack));
        stack.freeListAndFree(&freeString);
    }

    for (term.fonts) |font|
        fcft_destroy(font);
    for (term.font_sizes) |size|
        std.c.free(size);

    term_free_custom_glyphs(term);

    std.c.free(term.search.buf);
    std.c.free(term.search.last.buf);

    if (worker_threads) |threads| {
        var i: usize = 0;
        while (i < term.render.workers.count) : (i += 1) {
            if (threads[i] != 0)
                _ = pthread_join(threads[i], null);
        }
    }
    std.c.free(term.render.workers.threads);
    _ = mtx_destroy(@ptrCast(@alignCast(&term.render.workers.preapplied_damage.lock)));
    _ = cnd_destroy(@ptrCast(@alignCast(&term.render.workers.preapplied_damage.cond)));
    _ = mtx_destroy(workers_lock);
    _ = sem_destroy(@ptrCast(@alignCast(&term.render.workers.start)));
    _ = sem_destroy(@ptrCast(@alignCast(&term.render.workers.done)));

    {
        const queue: *tll.Tll(c_int) = @ptrCast(@alignCast(&term.render.workers.queue));
        if (queue.length != 0)
            bug(@src().file, @intCast(@src().line), "term_destroy", "assertion failed: 'tll_length(term->render.workers.queue) == 0'");
        queue.freeList();
    }

    shm_unref(term.render.last_buf);
    shm_chain_free(term.render.chains.grid);
    shm_chain_free(term.render.chains.search);
    shm_chain_free(term.render.chains.scrollback_indicator);
    shm_chain_free(term.render.chains.render_timer);
    shm_chain_free(term.render.chains.url);
    shm_chain_free(term.render.chains.csd);
    shm_chain_free(term.render.chains.overlay);
    pixman_region32_fini(@ptrCast(&term.render.last_overlay_clip));

    {
        const tab_stops: *tll.Tll(c_int) = @ptrCast(@alignCast(&term.tab_stops));
        tab_stops.freeList();
    }

    {
        const buffers: *tll.Tll(types.PtmxBuffer) = @ptrCast(@alignCast(&term.ptmx_buffers));
        buffers.freeListAndFree(&freePtmxBuffer);
    }
    {
        const buffers: *tll.Tll(types.PtmxBuffer) = @ptrCast(@alignCast(&term.ptmx_paste_buffers));
        buffers.freeListAndFree(&freePtmxBuffer);
    }

    notify_free(term, &term.kitty_notification);
    {
        const notifications: *tll.Tll(types.Notification) = @ptrCast(@alignCast(&term.active_notifications));
        var it = notifications.foreach();
        while (it.next()) |node| {
            notify_free(term, &node.item);
            notifications.removeNode(node);
        }
    }

    for (&term.notification_icons) |*icon|
        notify_icon_free(icon);

    sixel_fini(term);

    _ = term_ime_reset(term);

    grid_free(&term.normal);
    grid_free(&term.alt);
    if (term.interactive_resizing.grid) |grid| {
        grid_free(grid);
        std.c.free(grid);
    }

    std.c.free(term.foot_exe);
    std.c.free(term.cwd);
    std.c.free(term.mouse_user_cursor);
    std.c.free(term.color_stack.stack);

    if (term.argv) |argv| {
        var i: usize = 0;
        while (i < term.argc) : (i += 1)
            std.c.free(argv[i]);
        std.c.free(@as(?*anyopaque, @ptrCast(argv)));
    }

    var ret: c_int = 0; // EXIT_SUCCESS

    if (term.slave > 0) {
        // We'll deal with this explicitly
        reaper_del(term.reaper, term.slave);

        var exit_status: c_int = 0;

        if (term.shutdown.client_has_terminated) {
            exit_status = term.shutdown.exit_status;
        } else {
            log_msg(
                LOG_CLASS_DEBUG,
                "terminal",
                "terminal.zig",
                @intCast(@src().line),
                "initiating blocking terminate of slave; sending SIGHUP to PID=%u",
                term.slave,
            );

            _ = kill(-term.slave, SIGHUP);

            // We've closed the ptmx and sent SIGTERM to the client. It
            // *should* exit... but it is possible to write clients that ignore
            // this, so register a SIGALRM handler and configure a 30 second
            // alarm: if the slave hasn't died after this time, send SIGKILL.
            //
            // This is *not* asynchronous; other events are ignored during this
            // time. That only applies to a 'foot --server' instance, where
            // there may be other terminals running.
            installAlarmHandler(@ptrCast(&sigAlarm));

            var next_signal: c_int = SIGTERM;

            alarm_raised = 0;
            _ = alarm(30);

            while (true) {
                const r = waitpid(term.slave, &exit_status, 0);

                if (r == term.slave)
                    break;

                if (r == -1) {
                    if (__errno_location().* != EINTR)
                        bug(@src().file, @intCast(@src().line), "term_destroy", "assertion failed: 'errno == EINTR'");

                    if (alarm_raised != 0) {
                        log_msg(
                            LOG_CLASS_DEBUG,
                            "terminal",
                            "terminal.zig",
                            @intCast(@src().line),
                            "slave (PID=%u) has not terminated yet, sending: %s (%d)",
                            term.slave,
                            @as([*:0]const u8, if (next_signal == SIGTERM) "SIGTERM" else "SIGKILL"),
                            next_signal,
                        );

                        _ = kill(-term.slave, next_signal);
                        next_signal = SIGKILL;

                        alarm_raised = 0;
                        _ = alarm(30);
                    }
                }
            }

            // Cancel the alarm
            _ = alarm(0);
            installAlarmHandler(SIG_DFL_HANDLER);
        }

        ret = 1; // EXIT_FAILURE
        if (terminal_shim_wifexited(exit_status) != 0) {
            ret = terminal_shim_wexitstatus(exit_status);
            log_msg(LOG_CLASS_DEBUG, "terminal", "terminal.zig", @intCast(@src().line), "slave exited with code %d", ret);
        } else if (terminal_shim_wifsignaled(exit_status) != 0) {
            ret = terminal_shim_wtermsig(exit_status);
            log_msg(
                LOG_CLASS_WARNING,
                "terminal",
                "terminal.zig",
                @intCast(@src().line),
                "slave exited with signal %d (%s)",
                ret,
                strsignal(ret),
            );
        } else {
            log_msg(
                LOG_CLASS_WARNING,
                "terminal",
                "terminal.zig",
                @intCast(@src().line),
                "slave exited for unknown reason (status = 0x%08x)",
                exit_status,
            );
        }
    }

    std.c.free(term);

    if (malloc_trim(0) == 0)
        log_msg(LOG_CLASS_WARNING, "terminal", "terminal.zig", @intCast(@src().line), "failed to trim memory");

    return ret;
}
//
// Chunk C6 — term_reset(). A straight transcription: every field it touches is
// in the mirror, and the helpers it calls (term_set_window_title, erase_line,
// grid_row_and_alloc, term_damage_all, ...) are already Zig or C externs.
//

const SIXEL_MAX_COLORS: c_uint = 1024;
const SIXEL_MAX_WIDTH: c_uint = 10000;
const SIXEL_MAX_HEIGHT: c_uint = 10000;

/// terminal.h: `bool scrolling:1; bool use_private_palette:1;
/// bool cursor_right_of_graphics:1;` (LSB first, as everywhere in foot).
const SixelFlags = packed struct(u8) {
    scrolling: bool = false,
    use_private_palette: bool = false,
    cursor_right_of_graphics: bool = false,
    _unused: u5 = 0,
};

fn freeStringTll(list: *types.TllInt) void {
    const l: *tll.Tll(?[*:0]u8) = @ptrCast(@alignCast(list));
    l.freeListAndFree(&freeString);
}

fn freeTllNodes(list: *types.TllInt) void {
    const l: *tll.Tll(c_int) = @ptrCast(@alignCast(list));
    l.freeList();
}

fn freeDamageList(list: *types.DamageList) void {
    const l: *tll.Tll(types.Damage) = @ptrCast(@alignCast(list));
    l.freeList();
}

export fn term_reset(term: *types.Terminal, hard: bool) callconv(.c) void {
    log_msg(
        LOG_CLASS_INFO,
        "terminal",
        "terminal.zig",
        @intCast(@src().line),
        "%s resetting the terminal",
        @as([*:0]const u8, if (hard) "hard" else "soft"),
    );

    term.cursor_keys_mode = .normal;
    term.keypad_keys_mode = .numerical;
    term.reverse = false;
    term.hide_cursor = false;
    term.reverse_wrap = true;
    term.auto_margin = true;
    term.insert_mode = false;
    term.bracketed_paste = false;
    term.focus_events = false;
    term.visibility_reports = false;
    term.num_lock_modifier = true;
    term.bell_action_enabled = true;
    term.mouse_tracking = .none;
    term.mouse_reporting = .normal;
    term.charsets.selected = .g0;
    term.charsets.set = .{ .ascii, .ascii, .ascii, .ascii };
    term.saved_charsets = term.charsets;
    freeStringTll(&term.window_title_stack);
    if (term.conf) |conf| {
        if (conf.title) |title|
            term_set_window_title(term, title);
    }
    term_set_app_id(term, null);

    term_set_user_mouse_cursor(term, null);

    term.modify_other_keys_2 = false;
    @memset(std.mem.asBytes(&term.normal.kitty_kbd.flags), 0);
    @memset(std.mem.asBytes(&term.alt.kitty_kbd.flags), 0);
    term.normal.kitty_kbd.idx = 0;
    term.alt.kitty_kbd.idx = 0;

    term.scroll_region.start = 0;
    term.scroll_region.end = term.rows;

    std.c.free(term.vt.osc8.uri);
    std.c.free(term.vt.osc.data);

    term.vt = std.mem.zeroes(types.Vt); // .state = 0 == STATE_GROUND

    if (term.grid == &term.alt) {
        term.grid = &term.normal;
        selection_cancel(term);
    }

    term.meta.esc_prefix = true;
    term.meta.eight_bit = true;

    {
        const images: *tll.Tll(types.Sixel) = @ptrCast(@alignCast(&term.normal.sixel_images));
        var it = images.foreach();
        while (it.next()) |node| {
            sixel_destroy(&node.item);
            images.removeNode(node);
        }
    }
    {
        const images: *tll.Tll(types.Sixel) = @ptrCast(@alignCast(&term.alt.sixel_images));
        var it = images.foreach();
        while (it.next()) |node| {
            sixel_destroy(&node.item);
            images.removeNode(node);
        }
    }

    notify_free(term, &term.kitty_notification);
    {
        const notifications: *tll.Tll(types.Notification) = @ptrCast(@alignCast(&term.active_notifications));
        var it = notifications.foreach();
        while (it.next()) |node| {
            notify_free(term, &node.item);
            notifications.removeNode(node);
        }
    }

    for (&term.notification_icons) |*icon|
        notify_icon_free(icon);

    if (term.conf) |conf|
        term.grapheme_shaping = conf.tweak.grapheme_shaping;

    // meson refuses a Zig build with -Dime=false (see term_kbd_focus_out()).
    term_ime_enable(term);

    term.bits_affecting_ascii_printer.value = 0;
    term_update_ascii_printer(term);

    if (!hard)
        return;

    const conf = term.conf orelse return;

    var theme: ?*const types.ColorTheme = null;
    switch (conf.initial_color_theme) {
        .dark => theme = &conf.colors_dark,
        .light => theme = &conf.colors_light,
        .color_theme_1, .color_theme_2 => {
            bug(@src().file, @intCast(@src().line), "term_reset", "COLOR_THEME_1/2 should not be used");
        },
    }

    term.flash.active = false;
    term.blink.state = .on;
    if (term.fdm) |fdm_ptr| _ = fdm_del(fdm_ptr, term.blink.fd);
    term.blink.fd = -1;
    if (theme) |t|
        term_theme_apply(term, t);
    term.colors.active_theme = conf.initial_color_theme;
    std.c.free(term.color_stack.stack);
    term.color_stack.stack = null;
    term.color_stack.size = 0;
    term.color_stack.idx = 0;
    term.origin = .absolute;
    term.normal.cursor.lcf = false;
    term.alt.cursor.lcf = false;
    // C: (struct cursor){.point = {0, 0}}, i.e. lcf is cleared too.
    term.normal.cursor = .{ .point = .{ .col = 0, .row = 0 }, .lcf = false };
    term.normal.saved_cursor = .{ .point = .{ .col = 0, .row = 0 }, .lcf = false };
    term.alt.cursor = .{ .point = .{ .col = 0, .row = 0 }, .lcf = false };
    term.alt.saved_cursor = .{ .point = .{ .col = 0, .row = 0 }, .lcf = false };
    term.cursor_style = conf.cursor.style;
    term.cursor_blink.decset = false;
    term.cursor_blink.deccsusr = conf.cursor.blink.enabled;
    term_cursor_blink_update(term);
    selection_cancel(term);
    term.normal.offset = 0;
    term.normal.view = 0;
    term.alt.offset = 0;
    term.alt.view = 0;

    var i: c_int = 0;
    while (i < term.rows) : (i += 1) {
        const r = terminal_shim_grid_row_and_alloc(&term.normal, i).?;
        erase_line(term, r);
    }
    i = 0;
    while (i < term.rows) : (i += 1) {
        const r = terminal_shim_grid_row_and_alloc(&term.alt, i).?;
        erase_line(term, r);
    }
    i = term.rows;
    while (i < term.normal.num_rows) : (i += 1) {
        const rows = term.normal.rows.?;
        grid_row_free(rows[@intCast(i)]);
        rows[@intCast(i)] = null;
    }
    i = term.rows;
    while (i < term.alt.num_rows) : (i += 1) {
        const rows = term.alt.rows.?;
        grid_row_free(rows[@intCast(i)]);
        rows[@intCast(i)] = null;
    }
    term.normal.cur_row = term.normal.rows.?[0];
    term.alt.cur_row = term.alt.rows.?[0];
    freeDamageList(&term.normal.scroll_damage);
    freeDamageList(&term.alt.scroll_damage);
    term.render.last_cursor.row = null;
    term_damage_all(term);

    var flags: SixelFlags = @bitCast(term.sixel._sixel_flags);
    flags.scrolling = true;
    flags.cursor_right_of_graphics = false;
    flags.use_private_palette = true;
    term.sixel._sixel_flags = @bitCast(flags);
    term.sixel.max_width = SIXEL_MAX_WIDTH;
    term.sixel.max_height = SIXEL_MAX_HEIGHT;
    term.sixel.palette_size = SIXEL_MAX_COLORS;
    std.c.free(term.sixel.private_palette);
    std.c.free(term.sixel.shared_palette);
    term.sixel.private_palette = null;
    term.sixel.shared_palette = null;
}
//
// Chunk C7 — term_init(). The last function in terminal.c: open the pty and
// the timer FDs, register the FDM callbacks, build the terminal from the
// config, spawn the slave, create the window, load fonts and start the render
// workers. Everything it calls is either already Zig or a plain C extern.
//

extern fn ioctl(fd: c_int, request: c_ulong, ...) callconv(.c) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
extern fn posix_openpt(flags: c_int) callconv(.c) c_int;
extern fn key_binding_new_for_conf(mgr: ?*anyopaque, wayl: ?*types.Wayland, conf: ?*const types.Config) callconv(.c) void;
extern fn shm_chain_new(
    wayl: ?*types.Wayland,
    scrollable: bool,
    pix_instances: usize,
    desired_bit_depth: c_int,
    release_cb: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    cb_data: ?*anyopaque,
) callconv(.c) ?*anyopaque;
extern fn render_buffer_release_callback(buf: ?*anyopaque, data: ?*anyopaque) callconv(.c) void;
extern fn pixman_region32_init(region: *anyopaque) callconv(.c) void;
extern fn slave_spawn(
    ptmx: c_int,
    argc: c_int,
    cwd: ?[*:0]const u8,
    argv: ?[*]?[*:0]u8,
    envp: ?[*]?[*:0]const u8,
    extra_env_vars: ?*const types.EnvVarList,
    term_env: ?[*:0]const u8,
    conf_shell: ?[*:0]const u8,
    login_shell: bool,
    notifications: ?*const types.UserNotifications,
) callconv(.c) c_int;
extern fn reaper_add(reaper: ?*anyopaque, pid: c_int, cb: *const fn (?*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) void, cb_data: ?*anyopaque) callconv(.c) void;
extern fn wayl_win_init(term: *types.Terminal, token: ?[*:0]const u8) callconv(.c) ?*types.WlWindow;
extern fn terminal_shim_xdg_toplevel_set_maximized(toplevel: ?*anyopaque) callconv(.c) void;
extern fn terminal_shim_xdg_toplevel_set_fullscreen(toplevel: ?*anyopaque, output: ?*anyopaque) callconv(.c) void;

// terminal.c's PTY_OPEN_FLAGS and the fcntl/ioctl constants, spelled out the
// way the EPOLL* constants above already are (same values on Linux).
const O_RDWR: c_int = 0o2;
const O_NOCTTY: c_int = 0o400;
const O_NONBLOCK: c_int = 0o4000;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const TIOCSWINSZ: c_ulong = 0x5414;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

fn closeFds(
    fdm: ?*anyopaque,
    term: *types.Terminal,
    ptmx: c_int,
    flash_fd: c_int,
    delay_lower_fd: c_int,
    delay_upper_fd: c_int,
    app_sync_updates_fd: c_int,
    title_update_fd: c_int,
    icon_update_fd: c_int,
    app_id_update_fd: c_int,
) ?*types.Terminal {
    _ = close(ptmx);
    if (fdm) |fdm_ptr| {
        _ = fdm_del(fdm_ptr, flash_fd);
        _ = fdm_del(fdm_ptr, delay_lower_fd);
        _ = fdm_del(fdm_ptr, delay_upper_fd);
        _ = fdm_del(fdm_ptr, app_sync_updates_fd);
        _ = fdm_del(fdm_ptr, title_update_fd);
        _ = fdm_del(fdm_ptr, icon_update_fd);
        _ = fdm_del(fdm_ptr, app_id_update_fd);
    }
    std.c.free(term);
    return null;
}

fn termInitFail(term: *types.Terminal) ?*types.Terminal {
    term.shutdown.in_progress = true;
    _ = term_destroy(term);
    return null;
}

export fn term_init(
    conf: *const types.Config,
    fdm: ?*anyopaque,
    reaper: ?*anyopaque,
    wayl: *types.Wayland,
    foot_exe: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    token: ?[*:0]const u8,
    pty_path: ?[*:0]const u8,
    slave_argc: c_int,
    slave_argv: ?[*]?[*:0]u8,
    slave_envp: ?[*]?[*:0]const u8,
    foot_argc: c_int,
    foot_argv: ?[*]?[*:0]const u8,
    shutdown_cb: ?*const fn (?*anyopaque, c_int) callconv(.c) void,
    shutdown_data: ?*anyopaque,
) callconv(.c) ?*types.Terminal {
    var flash_fd: c_int = -1;
    var delay_lower_fd: c_int = -1;
    var delay_upper_fd: c_int = -1;
    var app_sync_updates_fd: c_int = -1;
    var title_update_fd: c_int = -1;
    var icon_update_fd: c_int = -1;
    var app_id_update_fd: c_int = -1;

    const term: *types.Terminal = @ptrCast(@alignCast(std.c.malloc(@sizeOf(types.Terminal)) orelse {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "malloc() failed");
        return null;
    }));

    const ptmx = if (pty_path) |path|
        open(path, O_RDWR | O_NOCTTY)
    else
        posix_openpt(O_RDWR | O_NOCTTY);
    if (ptmx < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to open PTY");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }
    flash_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (flash_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create flash timer FD");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }
    delay_lower_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    delay_upper_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (delay_lower_fd < 0 or delay_upper_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create delayed rendering timer FDs");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    app_sync_updates_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (app_sync_updates_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create application synchronized updates timer FD");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    title_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (title_update_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create title update throttle timer FD");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    icon_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (icon_update_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create icon update throttle timer FD");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    app_id_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (app_id_update_fd < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to create app ID update throttle timer FD");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    var winsize = Winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (ioctl(ptmx, TIOCSWINSZ, &winsize) < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to set initial TIOCSWINSZ");
        return closeFds(fdm, term, ptmx, flash_fd, delay_lower_fd, delay_upper_fd, app_sync_updates_fd, title_update_fd, icon_update_fd, app_id_update_fd);
    }

    // Need to register *very* early (before the first failure return), so that
    // term_destroy() doesn't unref a key-binding we haven't ref'd yet.
    key_binding_new_for_conf(wayl.key_binding_manager, wayl, conf);

    const ptmx_flags = fcntl(ptmx, F_GETFL);
    if (ptmx_flags < 0 or fcntl(ptmx, F_SETFL, ptmx_flags | O_NONBLOCK) < 0) {
        log_errno(LOG_CLASS_ERROR, "terminal", "terminal.zig", @intCast(@src().line), "failed to configure ptmx as non-blocking");
        return termInitFail(term);
    }

    // Enable all FDM callbacks *except* ptmx - we can't do that until the
    // window has been 'configured', since we don't have a size (and thus no
    // grid) before then.
    if (!fdm_add(fdm orelse unreachable, flash_fd, EPOLLIN, &fdm_flash, term) or
        !fdm_add(fdm.?, delay_lower_fd, EPOLLIN, &fdm_delayed_render, term) or
        !fdm_add(fdm.?, delay_upper_fd, EPOLLIN, &fdm_delayed_render, term) or
        !fdm_add(fdm.?, app_sync_updates_fd, EPOLLIN, &fdm_app_sync_updates_timeout, term) or
        !fdm_add(fdm.?, title_update_fd, EPOLLIN, &fdm_title_update_timeout, term) or
        !fdm_add(fdm.?, icon_update_fd, EPOLLIN, &fdm_icon_update_timeout, term) or
        !fdm_add(fdm.?, app_id_update_fd, EPOLLIN, &fdm_app_id_update_timeout, term))
    {
        return termInitFail(term);
    }

    const desired_bit_depth: types.ShmBitDepth = if (conf.tweak.surface_bit_depth == .auto)
        (if (wayl_do_linear_blending(wayl, conf)) .depth16 else .depth8)
    else
        conf.tweak.surface_bit_depth;

    const theme: *const types.ColorTheme = switch (conf.initial_color_theme) {
        .dark => &conf.colors_dark,
        .light => &conf.colors_light,
        .color_theme_1, .color_theme_2 => {
            bug(@src().file, @intCast(@src().line), "term_init", "COLOR_THEME_1/2 should not be used");
        },
    };

    // Initialize configure-based terminal attributes. C uses a compound
    // literal (which zeroes everything not designated); malloc + @memset followed
    // by the same assignments is identical.
    @memset(std.mem.asBytes(term), 0);

    term.fdm = fdm;
    term.reaper = reaper;
    term.conf = conf;
    term.slave = -1;
    term.ptmx = ptmx;
    term.font_sizes = .{
        @ptrCast(@alignCast(xmalloc(@sizeOf(types.ConfigFont) * conf.fonts[0].count).?)),
        @ptrCast(@alignCast(xmalloc(@sizeOf(types.ConfigFont) * conf.fonts[1].count).?)),
        @ptrCast(@alignCast(xmalloc(@sizeOf(types.ConfigFont) * conf.fonts[2].count).?)),
        @ptrCast(@alignCast(xmalloc(@sizeOf(types.ConfigFont) * conf.fonts[3].count).?)),
    };
    term.font_dpi = 0.0;
    term.font_dpi_before_unmap = -1.0;
    // Can't do subpixel rendering on a transparent background
    term.font_subpixel = if (theme.alpha == 0xffff) FCFT_SUBPIXEL_DEFAULT else FCFT_SUBPIXEL_NONE;
    term.cursor_keys_mode = .normal;
    term.keypad_keys_mode = .numerical;
    term.reverse_wrap = true;
    term.auto_margin = true;
    term.scale = 1.0;
    term.scale_before_unmap = -1.0;
    term.flash.fd = flash_fd;
    term.blink.fd = -1;

    term.colors.fg = theme.fg;
    term.colors.bg = theme.bg;
    term.colors.alpha = theme.alpha;
    term.colors.cursor_fg = (if (theme.use_custom.cursor) @as(u32, 1 << 31) else 0) | theme.cursor.text;
    term.colors.cursor_bg = (if (theme.use_custom.cursor) @as(u32, 1 << 31) else 0) | theme.cursor.cursor;
    term.colors.selection_fg = theme.selection_fg;
    term.colors.selection_bg = theme.selection_bg;
    term.colors.active_theme = conf.initial_color_theme;

    term.origin = .absolute;
    term.cursor_style = conf.cursor.style;
    term.cursor_blink.decset = false;
    term.cursor_blink.deccsusr = conf.cursor.blink.enabled;
    term.cursor_blink.state = CURSOR_BLINK_ON;
    term.cursor_blink.fd = -1;

    term.selection.coords.start = .{ .col = -1, .row = -1 };
    term.selection.coords.end = .{ .col = -1, .row = -1 };
    term.selection.pivot.start = .{ .col = -1, .row = -1 };
    term.selection.pivot.end = .{ .col = -1, .row = -1 };
    term.selection.auto_scroll.fd = -1;

    term.grid = &term.normal;
    term.alt_scrolling = conf.mouse.alternate_scroll_mode;
    term.meta.esc_prefix = true;
    term.meta.eight_bit = true;
    term.num_lock_modifier = true;
    term.bell_action_enabled = true;
    term.wl = wayl;

    term.render.chains.grid = shm_chain_new(wayl, true, 1 + conf.render_worker_count, @intFromEnum(desired_bit_depth), &render_buffer_release_callback, term);
    term.render.chains.search = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);
    term.render.chains.scrollback_indicator = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);
    term.render.chains.render_timer = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);
    term.render.chains.url = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);
    term.render.chains.csd = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);
    term.render.chains.overlay = shm_chain_new(wayl, false, 1, @intFromEnum(desired_bit_depth), null, null);

    term.render.scrollback_lines = conf.scrollback.lines;
    term.render.app_sync_updates.timer_fd = app_sync_updates_fd;
    term.render.title.timer_fd = title_update_fd;
    term.render.icon.timer_fd = icon_update_fd;
    term.render.app_id.timer_fd = app_id_update_fd;
    term.render.workers.count = conf.render_worker_count;

    term.delayed_render_timer.is_armed = false;
    term.delayed_render_timer.lower_fd = delay_lower_fd;
    term.delayed_render_timer.upper_fd = delay_upper_fd;

    var sixel_flags: SixelFlags = @bitCast(term.sixel._sixel_flags);
    sixel_flags.scrolling = true;
    sixel_flags.use_private_palette = true;
    term.sixel._sixel_flags = @bitCast(sixel_flags);
    term.sixel.palette_size = SIXEL_MAX_COLORS;
    term.sixel.max_width = SIXEL_MAX_WIDTH;
    term.sixel.max_height = SIXEL_MAX_HEIGHT;

    term.shutdown.terminate_timeout_fd = -1;
    term.shutdown.cb = @ptrCast(shutdown_cb);
    term.shutdown.cb_data = shutdown_data;

    term.foot_exe = if (foot_exe) |exe| xstrdup(exe) else null;
    term.cwd = if (cwd) |c| xstrdup(c) else null;
    term.grapheme_shaping = conf.tweak.grapheme_shaping;
    term.ime_enabled = true; // meson enforces -Dime=true for Zig builds
    term.argc = foot_argc;
    term.argv = @ptrCast(@alignCast(xcalloc(@intCast(foot_argc), @sizeOf(?[*:0]u8)).?));

    if (foot_argv) |argv| {
        var i: usize = 0;
        while (i < @as(usize, @intCast(foot_argc))) : (i += 1) {
            if (argv[i]) |arg|
                term.argv.?[i] = xstrdup(arg);
        }
    }

    pixman_region32_init(@ptrCast(&term.render.last_overlay_clip));

    term_update_ascii_printer(term);
    @memcpy(&term.colors.table, &theme.table);

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const font_list = conf.fonts[i];
        const sizes: [*]types.ConfigFont = @ptrCast(term.font_sizes[i].?);
        const list_arr = font_list.arr orelse continue;
        var j: usize = 0;
        while (j < font_list.count) : (j += 1) {
            sizes[j] = .{ .pattern = null, .pt_size = list_arr[j].pt_size, .px_size = list_arr[j].px_size };
        }
    }

    for (&term.notification_icons) |*icon|
        icon.tmp_file_fd = -1;

    _ = add_utmp_record(conf, reaper, ptmx);

    if (pty_path == null) {
        // Start the slave/client
        term.slave = slave_spawn(
            term.ptmx,
            slave_argc,
            term.cwd,
            slave_argv,
            slave_envp,
            &conf.env_vars,
            conf.term,
            conf.shell,
            conf.login_shell,
            &conf.notifications,
        );
        if (term.slave == -1)
            return termInitFail(term);

        reaper_add(term.reaper, term.slave, &fdm_client_terminated, term);
    }

    // Guess scale; we're not mapped yet, so we don't know on which output
    // we'll be. Use the scaling factor from the first monitor.
    if (wayl.monitors.length > 0) {
        const node: *const types.TllNode(types.Monitor) = @ptrCast(@alignCast(wayl.monitors.head.?));
        term.scale = @floatFromInt(node.item.scale);
    }

    // Initialize the wayland window backend
    term.window = wayl_win_init(term, token);
    if (term.window == null)
        return termInitFail(term);

    // Load fonts
    if (!term_font_dpi_changed(term, 0.0))
        return termInitFail(term);

    term.font_subpixel = get_font_subpixel(term);

    if (conf.title) |title|
        term_set_window_title(term, title);

    // Let the wayland backend know we exist
    {
        const terms: *tll.Tll(?*anyopaque) = @ptrCast(@alignCast(&wayl.terms));
        terms.pushBack(@ptrCast(term));
    }

    switch (conf.startup_mode) {
        .windowed => {},
        .maximized => terminal_shim_xdg_toplevel_set_maximized(term.window.?.xdg_toplevel),
        .fullscreen => terminal_shim_xdg_toplevel_set_fullscreen(term.window.?.xdg_toplevel, null),
    }

    if (!initialize_render_workers(term))
        return termInitFail(term);

    return term;
}
