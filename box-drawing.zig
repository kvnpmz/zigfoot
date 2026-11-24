const std = @import("std");
const types = @import("terminal_types.zig");

//
// Chunk A1 — box-drawing scaffolding: the rendering buffer's primitives.
//
// `struct buf` moved to box-drawing.h so the ABI probe can pin it; this file
// mirrors it as types.BoxBuf. The 188 draw_*() functions still live in
// box-drawing.c and call straight into these exports through the macros in
// box-drawing.h, so the C and Zig halves share one buffer and one set of
// drawing primitives.
//

const PixmanBox32 = types.PixmanBox32;

/// pixman_color_t: four 16-bit channels.
const PixmanColor = extern struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,
};

const PIXMAN_OP_SRC: c_int = 0x01;

// PIXMAN_FORMAT(8, PIXMAN_TYPE_A, 8, 0, 0, 0) and
// PIXMAN_FORMAT(1, PIXMAN_TYPE_A, 1, 0, 0, 0).
const PIXMAN_a8: u32 = 0x08018000;
const PIXMAN_a1: u32 = 0x01011000;

const LIGHT: c_int = 0;
const HEAVY: c_int = 1;

extern fn pixman_image_fill_boxes(
    op: c_int,
    image: *anyopaque,
    color: *const PixmanColor,
    n_boxes: c_int,
    boxes: [*]const PixmanBox32,
) c_int;
extern fn pixman_image_create_bits_no_clear(
    format: c_int,
    width: c_int,
    height: c_int,
    bits: ?[*]u32,
    rowstride: c_int,
) callconv(.c) ?*anyopaque;
extern fn pixman_image_unref(image: *anyopaque) callconv(.c) void;
extern fn perror(s: [*:0]const u8) void;

const white = PixmanColor{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };

fn clamp(x: c_int, lower: c_int, upper: c_int) c_int {
    return @min(upper, @max(x, lower));
}

/// stride.h: stride_for_format_and_width() -- a static inline over
/// PIXMAN_FORMAT_BPP().
fn strideForFormatAndWidth(format: u32, width: c_int) c_int {
    const bpp = (format >> 24) & 0xff;
    return @intCast(((@as(u32, bpp) * @as(u32, @intCast(width)) + 7) / 8 + 4 - 1) & ~@as(u32, 3));
}

fn bppOf(format: u32) u32 {
    return (format >> 24) & 0xff;
}

export fn box_thickness(base_thickness: c_int, thick: c_int) callconv(.c) c_int {
    const multiplier = thick * 2 + 1;

    std.debug.assert(base_thickness >= 1);
    std.debug.assert((thick == LIGHT and multiplier == 1) or
        (thick == HEAVY and multiplier == 3));

    return base_thickness * multiplier;
}

export fn box_change_buffer_format(buf: *types.BoxBuf, new_format: u32) callconv(.c) void {
    _ = bppOf(new_format);

    const stride = strideForFormatAndWidth(new_format, buf.width);
    const new_data: [*]u8 = @ptrCast(@alignCast(
        std.c.calloc(@intCast(buf.height * stride), 1) orelse @panic("out of memory")));

    const new_pix = pixman_image_create_bits_no_clear(
        @intCast(new_format),
        buf.width,
        buf.height,
        @ptrCast(@alignCast(new_data)),
        stride,
    );

    if (new_pix == null) {
        std.c._errno().* = 12; // ENOMEM
        perror("change_buffer_format");
        std.c.abort();
    }

    _ = pixman_image_unref(buf.pix.?);
    std.c.free(@ptrCast(buf.data));

    buf.data = new_data;
    buf.pix = new_pix;
    buf.format = new_format;
    buf.stride = stride;
}

fn fillBox(buf: *types.BoxBuf, box: PixmanBox32) void {
    _ = pixman_image_fill_boxes(
        PIXMAN_OP_SRC,
        buf.pix.?,
        &white,
        1,
        @ptrCast(&box),
    );
}

export fn box_hline(
    buf: *types.BoxBuf,
    x1: c_int,
    x2: c_int,
    y: c_int,
    thick: c_int,
) callconv(.c) void {
    fillBox(buf, .{
        .x1 = clamp(x1, 0, buf.width),
        .x2 = clamp(x2, 0, buf.width),
        .y1 = clamp(y, 0, buf.height),
        .y2 = clamp(y + thick, 0, buf.height),
    });
}

export fn box_vline(
    buf: *types.BoxBuf,
    y1: c_int,
    y2: c_int,
    x: c_int,
    thick: c_int,
) callconv(.c) void {
    fillBox(buf, .{
        .x1 = clamp(x, 0, buf.width),
        .x2 = clamp(x + thick, 0, buf.width),
        .y1 = clamp(y1, 0, buf.height),
        .y2 = clamp(y2, 0, buf.height),
    });
}

export fn box_rect(
    buf: *types.BoxBuf,
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
) callconv(.c) void {
    fillBox(buf, .{
        .x1 = clamp(x1, 0, buf.width),
        .y1 = clamp(y1, 0, buf.height),
        .x2 = clamp(x2, 0, buf.width),
        .y2 = clamp(y2, 0, buf.height),
    });
}

export fn box_hline_middle(buf: *types.BoxBuf, thick: c_int) callconv(.c) void {
    const t = buf.thickness[@intCast(thick)];
    box_hline(buf, 0, buf.width, @divTrunc(buf.height - t, 2), t);
}

export fn box_hline_middle_left(
    buf: *types.BoxBuf,
    vthick: c_int,
    hthick: c_int,
) callconv(.c) void {
    const vt = buf.thickness[@intCast(vthick)];
    const ht = buf.thickness[@intCast(hthick)];
    box_hline(buf, 0, @divTrunc(buf.width + vt, 2), @divTrunc(buf.height - ht, 2), ht);
}

export fn box_hline_middle_right(
    buf: *types.BoxBuf,
    vthick: c_int,
    hthick: c_int,
) callconv(.c) void {
    const vt = buf.thickness[@intCast(vthick)];
    const ht = buf.thickness[@intCast(hthick)];
    box_hline(buf, @divTrunc(buf.width - vt, 2), buf.width, @divTrunc(buf.height - ht, 2), ht);
}

export fn box_vline_middle(buf: *types.BoxBuf, thick: c_int) callconv(.c) void {
    const t = buf.thickness[@intCast(thick)];
    box_vline(buf, 0, buf.height, @divTrunc(buf.width - t, 2), t);
}

export fn box_vline_middle_up(
    buf: *types.BoxBuf,
    vthick: c_int,
    hthick: c_int,
) callconv(.c) void {
    const vt = buf.thickness[@intCast(vthick)];
    const ht = buf.thickness[@intCast(hthick)];
    box_vline(buf, 0, @divTrunc(buf.height + ht, 2), @divTrunc(buf.width - vt, 2), vt);
}

export fn box_vline_middle_down(
    buf: *types.BoxBuf,
    vthick: c_int,
    hthick: c_int,
) callconv(.c) void {
    const vt = buf.thickness[@intCast(vthick)];
    const ht = buf.thickness[@intCast(hthick)];
    box_vline(buf, @divTrunc(buf.height - ht, 2), buf.height, @divTrunc(buf.width - vt, 2), vt);
}

//
// Chunk A2 — the single-line and rounded-corner family (U+2500..U+254B).
//
// These are straight transcriptions of box-drawing.c's draw_*() functions;
// the C originals are gone and box-drawing.c declares them extern.
//

fn hline(buf: *types.BoxBuf, x1: c_int, x2: c_int, y: c_int, thick: c_int) void {
    box_hline(buf, x1, x2, y, thick);
}

fn vline(buf: *types.BoxBuf, y1: c_int, y2: c_int, x: c_int, thick: c_int) void {
    box_vline(buf, y1, y2, x, thick);
}

fn rect(buf: *types.BoxBuf, x1: c_int, y1: c_int, x2: c_int, y2: c_int) void {
    box_rect(buf, x1, y1, x2, y2);
}

fn hlineMiddle(buf: *types.BoxBuf, thick: c_int) void {
    box_hline_middle(buf, thick);
}

fn hlineMiddleLeft(buf: *types.BoxBuf, thick: c_int) void {
    box_hline_middle_left(buf, thick, thick);
}

fn hlineMiddleRight(buf: *types.BoxBuf, thick: c_int) void {
    box_hline_middle_right(buf, thick, thick);
}

fn vlineMiddle(buf: *types.BoxBuf, thick: c_int) void {
    box_vline_middle(buf, thick);
}

fn vlineMiddleUp(buf: *types.BoxBuf, thick: c_int) void {
    box_vline_middle_up(buf, thick, thick);
}

fn vlineMiddleDown(buf: *types.BoxBuf, thick: c_int) void {
    box_vline_middle_down(buf, thick, thick);
}

// The C macros pass the same thickness twice.
fn hlineMiddleLeftMixed(buf: *types.BoxBuf, vthick: c_int, hthick: c_int) void {
    box_hline_middle_left(buf, vthick, hthick);
}

fn hlineMiddleRightMixed(buf: *types.BoxBuf, vthick: c_int, hthick: c_int) void {
    box_hline_middle_right(buf, vthick, hthick);
}

fn vlineMiddleUpMixed(buf: *types.BoxBuf, vthick: c_int, hthick: c_int) void {
    box_vline_middle_up(buf, vthick, hthick);
}

fn vlineMiddleDownMixed(buf: *types.BoxBuf, vthick: c_int, hthick: c_int) void {
    box_vline_middle_down(buf, vthick, hthick);
}


/// C: draw_box_drawings_dash_horizontal()
export fn draw_box_drawings_dash_horizontal(
    buf: *types.BoxBuf,
    count: c_int,
    thick: c_int,
    gap_in: c_int,
) callconv(.c) void {
    var gap = gap_in;
    const width = buf.width;
    const height = buf.height;

    std.debug.assert(count >= 2 and count <= 4);
    const gap_count = count - 1;

    var dash_width = @divTrunc(width - gap_count * gap, count);
    while (dash_width <= 0 and gap > 1) {
        gap -= 1;
        dash_width = @divTrunc(width - gap_count * gap, count);
    }

    if (dash_width <= 0) {
        hlineMiddle(buf, LIGHT);
        return;
    }

    std.debug.assert(count * dash_width + gap_count * gap <= width);

    const remaining = width - count * dash_width - gap_count * gap;

    var x = [4]c_int{ 0, 0, 0, 0 };
    var w = [4]c_int{ dash_width, dash_width, dash_width, dash_width };

    x[0] = 0;

    x[1] = x[0] + w[0] + gap;
    if (count == 2)
        w[1] = width - x[1]
    else if (count == 3)
        w[1] += remaining
    else
        w[1] += @divTrunc(remaining, 2);

    if (count >= 3) {
        x[2] = x[1] + w[1] + gap;
        if (count == 3)
            w[2] = width - x[2]
        else
            w[2] += remaining - @divTrunc(remaining, 2);
    }

    if (count >= 4) {
        x[3] = x[2] + w[2] + gap;
        w[3] = width - x[3];
    }

    hline(buf, x[0], x[0] + w[0], @divTrunc(height - thick, 2), thick);
    hline(buf, x[1], x[1] + w[1], @divTrunc(height - thick, 2), thick);
    if (count >= 3)
        hline(buf, x[2], x[2] + w[2], @divTrunc(height - thick, 2), thick);
    if (count >= 4)
        hline(buf, x[3], x[3] + w[3], @divTrunc(height - thick, 2), thick);
}

/// C: draw_box_drawings_dash_vertical()
export fn draw_box_drawings_dash_vertical(
    buf: *types.BoxBuf,
    count: c_int,
    thick: c_int,
    gap_in: c_int,
) callconv(.c) void {
    var gap = gap_in;
    const width = buf.width;
    const height = buf.height;

    std.debug.assert(count >= 2 and count <= 4);
    const gap_count = count - 1;

    var dash_height = @divTrunc(height - gap_count * gap, count);
    while (dash_height <= 0 and gap > 1) {
        gap -= 1;
        dash_height = @divTrunc(height - gap_count * gap, count);
    }

    if (dash_height <= 0) {
        vlineMiddle(buf, LIGHT);
        return;
    }

    std.debug.assert(count * dash_height + gap_count * gap <= height);

    const remaining = height - count * dash_height - gap_count * gap;

    var y = [4]c_int{ 0, 0, 0, 0 };
    var h = [4]c_int{ dash_height, dash_height, dash_height, dash_height };

    y[0] = 0;

    y[1] = y[0] + h[0] + gap;
    if (count == 2)
        h[1] = height - y[1]
    else if (count == 3)
        h[1] += remaining
    else
        h[1] += @divTrunc(remaining, 2);

    if (count >= 3) {
        y[2] = y[1] + h[1] + gap;
        if (count == 3)
            h[2] = height - y[2]
        else
            h[2] += remaining - @divTrunc(remaining, 2);
    }

    if (count >= 4) {
        y[3] = y[2] + h[2] + gap;
        h[3] = height - y[3];
    }

    vline(buf, y[0], y[0] + h[0], @divTrunc(width - thick, 2), thick);
    vline(buf, y[1], y[1] + h[1], @divTrunc(width - thick, 2), thick);
    if (count >= 3)
        vline(buf, y[2], y[2] + h[2], @divTrunc(width - thick, 2), thick);
    if (count >= 4)
        vline(buf, y[3], y[3] + h[3], @divTrunc(width - thick, 2), thick);
}

export fn draw_box_drawings_light_triple_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 3, buf.thickness[LIGHT], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_heavy_triple_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 3, buf.thickness[HEAVY], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_light_triple_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 3, buf.thickness[LIGHT], buf.thickness[HEAVY]);
}

export fn draw_box_drawings_heavy_triple_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 3, buf.thickness[HEAVY], buf.thickness[HEAVY]);
}

export fn draw_box_drawings_light_quadruple_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 4, buf.thickness[LIGHT], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_heavy_quadruple_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 4, buf.thickness[HEAVY], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_light_quadruple_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 4, buf.thickness[LIGHT], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_heavy_quadruple_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 4, buf.thickness[HEAVY], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_light_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_heavy_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_light_vertical(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_heavy_vertical(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_light_down_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_light_and_right_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_right_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_heavy_down_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_light_down_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_light_and_left_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_left_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_heavy_down_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_light_up_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_right_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_right_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_heavy_up_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_light_up_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_left_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_left_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_heavy_up_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_light_vertical_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_vertical_light_and_right_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_right_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_right_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_vertical_heavy_and_right_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_down_light_and_right_up_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_right_down_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_heavy_vertical_and_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_light_vertical_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_vertical_light_and_left_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_left_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_left_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_vertical_heavy_and_left_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_down_light_and_left_up_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_left_down_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_heavy_vertical_and_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_light_down_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_left_heavy_and_right_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_right_heavy_and_left_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_light_and_horizontal_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_horizontal_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_right_light_and_left_down_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_left_light_and_right_down_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_heavy_down_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_light_up_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_left_heavy_and_right_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_right_heavy_and_left_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_horizontal_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_horizontal_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_right_light_and_left_up_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_left_light_and_right_up_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_heavy_up_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_light_vertical_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_left_heavy_and_right_vertical_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeftMixed(buf, LIGHT, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_right_heavy_and_left_vertical_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRightMixed(buf, LIGHT, HEAVY);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_vertical_light_and_horizontal_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddle(buf, LIGHT);
}

export fn draw_box_drawings_up_heavy_and_down_horizontal_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleUpMixed(buf, HEAVY, LIGHT);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_down_heavy_and_up_horizontal_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDownMixed(buf, HEAVY, LIGHT);
}

export fn draw_box_drawings_vertical_heavy_and_horizontal_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, LIGHT);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_left_up_heavy_and_right_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_right_up_heavy_and_left_down_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_left_down_heavy_and_right_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_right_down_heavy_and_left_up_light(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_down_light_and_up_horizontal_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_up_light_and_down_horizontal_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_right_light_and_left_vertical_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_left_light_and_right_vertical_heavy(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
    vlineMiddle(buf, HEAVY);
}

export fn draw_box_drawings_heavy_vertical_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddle(buf, HEAVY);
    vlineMiddle(buf, HEAVY);
}

//
// Chunk A3 — the double-line family (U+254C..U+257F).
//
// Same shape as A2: a couple of local thicknesses, then rect/line calls.
//

export fn draw_box_drawings_light_double_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 2, buf.thickness[LIGHT], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_heavy_double_dash_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_horizontal(buf, 2, buf.thickness[HEAVY], buf.thickness[LIGHT]);
}

export fn draw_box_drawings_light_double_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 2, buf.thickness[LIGHT], buf.thickness[HEAVY]);
}

export fn draw_box_drawings_heavy_double_dash_vertical(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_dash_vertical(buf, 2, buf.thickness[HEAVY], buf.thickness[HEAVY]);
}

export fn draw_box_drawings_double_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const mid: c_int = @divTrunc(buf.height - thick * 3, 2);
    hline(buf, 0, buf.width, mid, thick);
    hline(buf, 0, buf.width, mid + 2 * thick, thick);
}

export fn draw_box_drawings_double_vertical(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const mid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, buf.height, mid, thick);
    vline(buf, 0, buf.height, mid + 2 * thick, thick);
}

export fn draw_box_drawings_down_single_and_right_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick, 2);
    vlineMiddleDown(buf, LIGHT);
    hline(buf, vmid, buf.width, hmid, thick);
    hline(buf, vmid, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_down_double_and_right_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddleRight(buf, LIGHT);
    vline(buf, hmid, buf.height, vmid, thick);
    vline(buf, hmid, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_down_and_right(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, hmid, buf.height, vmid, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid + 2 * thick, thick);
    hline(buf, vmid, buf.width, hmid, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_down_single_and_left_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width + thick, 2);
    vlineMiddleDown(buf, LIGHT);
    hline(buf, 0, vmid, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_down_double_and_left_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddleLeft(buf, LIGHT);
    vline(buf, hmid, buf.height, vmid, thick);
    vline(buf, hmid, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_down_and_left(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, hmid + 2 * thick, buf.height, vmid, thick);
    vline(buf, hmid, buf.height, vmid + 2 * thick, thick);
    hline(buf, 0, vmid + 2 * thick, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_single_and_right_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick, 2);
    vlineMiddleUp(buf, LIGHT);
    hline(buf, vmid, buf.width, hmid, thick);
    hline(buf, vmid, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_double_and_right_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height + thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddleRight(buf, LIGHT);
    vline(buf, 0, hmid, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_up_and_right(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, hmid + 2 * thick, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid, thick);
    hline(buf, vmid, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_single_and_left_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width + thick, 2);
    vlineMiddleUp(buf, LIGHT);
    hline(buf, 0, vmid, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_double_and_left_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height + thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddleLeft(buf, LIGHT);
    vline(buf, 0, hmid, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_up_and_left(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, hmid + 0 * thick + thick, vmid, thick);
    vline(buf, 0, hmid + 2 * thick + thick, vmid + 2 * thick, thick);
    hline(buf, 0, vmid, hmid, thick);
    hline(buf, 0, vmid + 2 * thick, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_single_and_right_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick, 2);
    vlineMiddle(buf, LIGHT);
    hline(buf, vmid, buf.width, hmid, thick);
    hline(buf, vmid, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_double_and_right_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hline(buf, vmid + 2 * thick, buf.width, @divTrunc(buf.height - thick, 2), thick);
    vline(buf, 0, buf.height, vmid, thick);
    vline(buf, 0, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_vertical_and_right(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, buf.height, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid + 2 * thick, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_single_and_left_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width + thick, 2);
    vlineMiddle(buf, LIGHT);
    hline(buf, 0, vmid, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_double_and_left_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hline(buf, 0, vmid, @divTrunc(buf.height - thick, 2), thick);
    vline(buf, 0, buf.height, vmid, thick);
    vline(buf, 0, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_vertical_and_left(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, buf.height, vmid + 2 * thick, thick);
    vline(buf, 0, hmid, vmid, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid, thick);
    hline(buf, 0, vmid + thick, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_down_single_and_horizontal_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    vline(buf, hmid + 2 * thick, buf.height, @divTrunc(buf.width - thick, 2), thick);
    hline(buf, 0, buf.width, hmid, thick);
    hline(buf, 0, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_down_double_and_horizontal_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddle(buf, LIGHT);
    vline(buf, hmid, buf.height, vmid, thick);
    vline(buf, hmid, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_down_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hline(buf, 0, buf.width, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid + 2 * thick, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_single_and_horizontal_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick, 2);
    vline(buf, 0, hmid, vmid, thick);
    hline(buf, 0, buf.width, hmid, thick);
    hline(buf, 0, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_up_double_and_horizontal_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddle(buf, LIGHT);
    vline(buf, 0, hmid, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_up_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    vline(buf, 0, hmid, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
    hline(buf, 0, vmid + thick, hmid, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid, thick);
    hline(buf, 0, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_single_and_horizontal_double(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    vlineMiddle(buf, LIGHT);
    hline(buf, 0, buf.width, hmid, thick);
    hline(buf, 0, buf.width, hmid + 2 * thick, thick);
}

export fn draw_box_drawings_vertical_double_and_horizontal_single(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hlineMiddle(buf, LIGHT);
    vline(buf, 0, buf.height, vmid, thick);
    vline(buf, 0, buf.height, vmid + 2 * thick, thick);
}

export fn draw_box_drawings_double_vertical_and_horizontal(buf: *types.BoxBuf) callconv(.c) void {
    const thick: c_int = buf.thickness[LIGHT];
    const hmid: c_int = @divTrunc(buf.height - thick * 3, 2);
    const vmid: c_int = @divTrunc(buf.width - thick * 3, 2);
    hline(buf, 0, vmid, hmid, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid, thick);
    hline(buf, 0, vmid, hmid + 2 * thick, thick);
    hline(buf, vmid + 2 * thick, buf.width, hmid + 2 * thick, thick);
    vline(buf, 0, hmid + thick, vmid, thick);
    vline(buf, 0, hmid, vmid + 2 * thick, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid, thick);
    vline(buf, hmid + 2 * thick, buf.height, vmid + 2 * thick, thick);
}

//
// Chunk A4 — blocks, shade patterns, quadrants and the line ends
// (U+2580..U+259F plus U+1FB70..U+1FB8B and the quadratic-eighth blocks).
//

/// `round()` + implicit double->int conversion, as the C code does.
fn roundi(v: f64) c_int {
    return @intFromFloat(@round(v));
}

fn ceili(v: f64) c_int {
    return @intFromFloat(@ceil(v));
}

fn floori(v: f64) c_int {
    return @intFromFloat(@floor(v));
}

fn f(v: c_int) f64 {
    return @floatFromInt(v);
}

export fn draw_upper_half_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(f(buf.height) / 2.0));
}

export fn draw_lower_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(f(buf.height) / 8.0), buf.width, buf.height);
}

export fn draw_lower_one_quarter_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(f(buf.height) / 4.0), buf.width, buf.height);
}

export fn draw_lower_three_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(3.0 * f(buf.height) / 8.0), buf.width, buf.height);
}

export fn draw_lower_half_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(f(buf.height) / 2.0), buf.width, buf.height);
}

export fn draw_lower_five_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(5.0 * f(buf.height) / 8.0), buf.width, buf.height);
}

export fn draw_lower_three_quarters_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(3.0 * f(buf.height) / 4.0), buf.width, buf.height);
}

export fn draw_lower_seven_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, buf.height - roundi(7.0 * f(buf.height) / 8.0), buf.width, buf.height);
}

export fn draw_upper_one_quarter_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(f(buf.height) / 4.0));
}

export fn draw_upper_three_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(3.0 * f(buf.height) / 8.0));
}

export fn draw_upper_five_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(5.0 * f(buf.height) / 8.0));
}

export fn draw_upper_three_quarters_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(3.0 * f(buf.height) / 4.0));
}

export fn draw_upper_seven_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, roundi(7.0 * f(buf.height) / 8.0));
}

export fn draw_full_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, buf.width, buf.height);
}

export fn draw_left_seven_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(7.0 * f(buf.width) / 8.0), buf.height);
}

export fn draw_left_three_quarters_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(3.0 * f(buf.width) / 4.0), buf.height);
}

export fn draw_left_five_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(5.0 * f(buf.width) / 8.0), buf.height);
}

export fn draw_left_half_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(f(buf.width) / 2.0), buf.height);
}

export fn draw_left_three_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(3.0 * f(buf.width) / 8.0), buf.height);
}

export fn draw_left_one_quarter_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, 0, 0, roundi(f(buf.width) / 4.0), buf.height);
}

export fn draw_vertical_one_eighth_block_n(buf: *types.BoxBuf, n: c_int) callconv(.c) void {
    const x: c_int = roundi(@as(f64, @floatFromInt(n)) * f(buf.width) / 8.0);
    const w: c_int = roundi(f(buf.width) / 8.0);
    rect(buf, x, 0, x + w, buf.height);
}

export fn draw_left_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 0);
}

export fn draw_vertical_one_eighth_block_2(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 1);
}

export fn draw_vertical_one_eighth_block_3(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 2);
}

export fn draw_vertical_one_eighth_block_4(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 3);
}

export fn draw_vertical_one_eighth_block_5(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 4);
}

export fn draw_vertical_one_eighth_block_6(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 5);
}

export fn draw_vertical_one_eighth_block_7(buf: *types.BoxBuf) callconv(.c) void {
    draw_vertical_one_eighth_block_n(buf, 6);
}

export fn draw_right_half_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, roundi(f(buf.width) / 2.0), 0, buf.width, buf.height);
}

export fn draw_horizontal_one_eighth_block_n(buf: *types.BoxBuf, n: c_int) callconv(.c) void {
    const y: c_int = roundi(@as(f64, @floatFromInt(n)) * f(buf.height) / 8.0);
    const h: c_int = roundi(f(buf.height) / 8.0);
    rect(buf, 0, y, buf.width, y + h);
}

export fn draw_upper_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 0);
}

export fn draw_horizontal_one_eighth_block_2(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 1);
}

export fn draw_horizontal_one_eighth_block_3(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 2);
}

export fn draw_horizontal_one_eighth_block_4(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 3);
}

export fn draw_horizontal_one_eighth_block_5(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 4);
}

export fn draw_horizontal_one_eighth_block_6(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 5);
}

export fn draw_horizontal_one_eighth_block_7(buf: *types.BoxBuf) callconv(.c) void {
    draw_horizontal_one_eighth_block_n(buf, 6);
}

export fn draw_right_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(f(buf.width) / 8.0), 0, buf.width, buf.height);
}

export fn draw_left_and_lower_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_left_one_eighth_block(buf);
    draw_lower_one_eighth_block(buf);
}

export fn draw_left_and_upper_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_left_one_eighth_block(buf);
    draw_upper_one_eighth_block(buf);
}

export fn draw_right_and_upper_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_right_one_eighth_block(buf);
    draw_upper_one_eighth_block(buf);
}

export fn draw_right_and_lower_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_right_one_eighth_block(buf);
    draw_lower_one_eighth_block(buf);
}

export fn draw_upper_and_lower_one_eighth_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_upper_one_eighth_block(buf);
    draw_lower_one_eighth_block(buf);
}

export fn draw_horizontal_one_eighth_1358_block(buf: *types.BoxBuf) callconv(.c) void {
    draw_upper_one_eighth_block(buf);
    draw_horizontal_one_eighth_block_3(buf);
    draw_horizontal_one_eighth_block_5(buf);
    draw_lower_one_eighth_block(buf);
}

export fn draw_right_one_quarter_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(f(buf.width) / 4.0), 0, buf.width, buf.height);
}

export fn draw_right_three_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(3.0 * f(buf.width) / 8.0), 0, buf.width, buf.height);
}

export fn draw_right_five_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(5.0 * f(buf.width) / 8.0), 0, buf.width, buf.height);
}

export fn draw_right_three_quarters_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(3.0 * f(buf.width) / 4.0), 0, buf.width, buf.height);
}

export fn draw_right_seven_eighths_block(buf: *types.BoxBuf) callconv(.c) void {
    rect(buf, buf.width - roundi(7.0 * f(buf.width) / 8.0), 0, buf.width, buf.height);
}

export fn draw_box_drawings_light_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
}

export fn draw_box_drawings_light_up(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleUp(buf, LIGHT);
}

export fn draw_box_drawings_light_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, LIGHT);
}

export fn draw_box_drawings_light_down(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleDown(buf, LIGHT);
}

export fn draw_box_drawings_heavy_left(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
}

export fn draw_box_drawings_heavy_up(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleUp(buf, HEAVY);
}

export fn draw_box_drawings_heavy_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleRight(buf, HEAVY);
}

export fn draw_box_drawings_heavy_down(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_light_left_and_heavy_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, LIGHT);
    hlineMiddleRight(buf, HEAVY);
}

export fn draw_box_drawings_light_up_and_heavy_down(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleUp(buf, LIGHT);
    vlineMiddleDown(buf, HEAVY);
}

export fn draw_box_drawings_heavy_left_and_light_right(buf: *types.BoxBuf) callconv(.c) void {
    hlineMiddleLeft(buf, HEAVY);
    hlineMiddleRight(buf, LIGHT);
}

export fn draw_box_drawings_heavy_up_and_light_down(buf: *types.BoxBuf) callconv(.c) void {
    vlineMiddleUp(buf, HEAVY);
    vlineMiddleDown(buf, LIGHT);
}
//
// Chunk A5a -- shades, quadrants, braille, sextants and octants.
//
// The matrices keep the C bit names verbatim; each is a function-local
// constant pair so the flag names cannot collide between draw_* bodies.
//

const builtin = @import("builtin");

/// log.h: LOG_CLASS_DEBUG
const LOG_CLASS_DEBUG: c_int = 4;

/// pixman_rectangle16_t
const PixmanRectangle16 = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

extern fn pixman_image_fill_rectangles(
    op: c_int,
    image: *anyopaque,
    color: *const PixmanColor,
    n_rects: c_int,
    rects: [*]const PixmanRectangle16,
) c_int;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;

fn setA1Bit(data: [*]u8, ofs: usize, bit_no: usize) void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        data[ofs] |= @as(u8, 1) << @intCast(bit_no);
    } else {
        data[ofs] |= @as(u8, 1) << @intCast(7 - bit_no);
    }
}

fn drawPixmanShade(buf: *types.BoxBuf, v: u16) void {
    const shade = PixmanColor{ .red = 0, .green = 0, .blue = 0, .alpha = v };
    var rects = [_]PixmanRectangle16{.{
        .x = 0,
        .y = 0,
        .width = @intCast(buf.width),
        .height = @intCast(buf.height),
    }};

    _ = pixman_image_fill_rectangles(PIXMAN_OP_SRC, buf.pix.?, &shade, 1, &rects);
}

/// Solid shades need an a8 buffer, the dithered ones an a1 buffer.
fn shadeSelectFormat(buf: *types.BoxBuf) void {
    const fmt = buf.format;

    if (buf.solid_shades and fmt == PIXMAN_a1)
        box_change_buffer_format(buf, PIXMAN_a8)
    else if (!buf.solid_shades and fmt == PIXMAN_a8)
        box_change_buffer_format(buf, PIXMAN_a1);
}

export fn draw_light_shade(buf: *types.BoxBuf) callconv(.c) void {
    shadeSelectFormat(buf);

    if (buf.solid_shades) {
        drawPixmanShade(buf, 0x4000);
    } else {
        const width: usize = @intCast(buf.width);
        const height: usize = @intCast(buf.height);
        const stride: usize = @intCast(buf.stride);

        var row: usize = 0;
        while (row < height) : (row += 2) {
            var col: usize = 0;
            while (col < width) : (col += 2) {
                const idx = col / 8;
                const bit_no = col % 8;
                setA1Bit(buf.data.?, row * stride + idx, bit_no);
            }
        }
    }
}

export fn draw_medium_shade(buf: *types.BoxBuf) callconv(.c) void {
    shadeSelectFormat(buf);

    if (buf.solid_shades) {
        drawPixmanShade(buf, 0x8000);
    } else {
        const width: usize = @intCast(buf.width);
        const height: usize = @intCast(buf.height);
        const stride: usize = @intCast(buf.stride);

        var row: usize = 0;
        while (row < height) : (row += 1) {
            var col: usize = row % 2;
            while (col < width) : (col += 2) {
                const idx = col / 8;
                const bit_no = col % 8;
                setA1Bit(buf.data.?, row * stride + idx, bit_no);
            }
        }
    }
}

export fn draw_dark_shade(buf: *types.BoxBuf) callconv(.c) void {
    shadeSelectFormat(buf);

    if (buf.solid_shades) {
        drawPixmanShade(buf, 0xc000);
    } else {
        const width: usize = @intCast(buf.width);
        const height: usize = @intCast(buf.height);
        const stride: usize = @intCast(buf.stride);

        var row: usize = 0;
        while (row < height) : (row += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1 + row % 2) {
                const idx = col / 8;
                const bit_no = col % 8;
                setA1Bit(buf.data.?, row * stride + idx, bit_no);
            }
        }
    }
}

fn quadUpperLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, 0, ceili(f(buf.width) / 2.0), ceili(f(buf.height) / 2.0));
}

fn quadUpperRight(buf: *types.BoxBuf) void {
    rect(buf, floori(f(buf.width) / 2.0), 0, buf.width, ceili(f(buf.height) / 2.0));
}

fn quadLowerLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, floori(f(buf.height) / 2.0), ceili(f(buf.width) / 2.0), buf.height);
}

fn quadLowerRight(buf: *types.BoxBuf) void {
    rect(buf, floori(f(buf.width) / 2.0), floori(f(buf.height) / 2.0), buf.width, buf.height);
}

export fn draw_quadrant(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    const UPPER_LEFT: u8 = 1 << 0;
    const UPPER_RIGHT: u8 = 1 << 1;
    const LOWER_LEFT: u8 = 1 << 2;
    const LOWER_RIGHT: u8 = 1 << 3;

    const matrix = [_]u8{
        LOWER_LEFT,
        LOWER_RIGHT,
        UPPER_LEFT,
        UPPER_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT,
        UPPER_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
    };

    std.debug.assert(wc >= 0x2596 and wc <= 0x259f);
    const idx: usize = @intCast(wc - 0x2596);

    std.debug.assert(idx < matrix.len);
    const encoded = matrix[idx];

    if (encoded & UPPER_LEFT != 0)
        quadUpperLeft(buf);

    if (encoded & UPPER_RIGHT != 0)
        quadUpperRight(buf);

    if (encoded & LOWER_LEFT != 0)
        quadLowerLeft(buf);

    if (encoded & LOWER_RIGHT != 0)
        quadLowerRight(buf);
}

export fn draw_braille(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    var w: c_int = @min(@divTrunc(buf.width, 4), @divTrunc(buf.height, 8));
    var x_spacing: c_int = @divTrunc(buf.width, 4);
    var y_spacing: c_int = @divTrunc(buf.height, 8);
    var x_margin: c_int = @divTrunc(x_spacing, 2);
    var y_margin: c_int = @divTrunc(y_spacing, 2);

    var x_px_left: c_int = buf.width - 2 * x_margin - x_spacing - 2 * w;
    var y_px_left: c_int = buf.height - 2 * y_margin - 3 * y_spacing - 4 * w;

    log_msg(
        LOG_CLASS_DEBUG,
        "box-drawing",
        "box-drawing.zig",
        @intCast(@src().line),
        "braille: before adjusting: " ++
            "cell: %dx%d, margin=%dx%d, spacing=%dx%d, width=%d, left=%dx%d",
        buf.width,
        buf.height,
        x_margin,
        y_margin,
        x_spacing,
        y_spacing,
        w,
        x_px_left,
        y_px_left,
    );

        // First, try hard to ensure the DOT width is non-zero
    if (x_px_left >= 2 and y_px_left >= 4 and w == 0) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

        // Second, prefer a non-zero margin
    if (x_px_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_px_left -= 2;
    }

        // Third, increase spacing
    if (x_px_left >= 1) {
        x_spacing += 1;
        x_px_left -= 1;
    }
    if (y_px_left >= 3) {
        y_spacing += 1;
        y_px_left -= 3;
    }

        // Fourth, margins ("spacing", but on the sides)
    if (x_px_left >= 2) {
        x_margin += 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2) {
        y_margin += 1;
        y_px_left -= 2;
    }

        // Last - increase dot width
    if (x_px_left >= 2 and y_px_left >= 4) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    log_msg(
        LOG_CLASS_DEBUG,
        "box-drawing",
        "box-drawing.zig",
        @intCast(@src().line),
        "braille: after adjusting: " ++
            "cell: %dx%d, margin=%dx%d, spacing=%dx%d, width=%d, left=%dx%d",
        buf.width,
        buf.height,
        x_margin,
        y_margin,
        x_spacing,
        y_spacing,
        w,
        x_px_left,
        y_px_left,
    );

    std.debug.assert(x_px_left <= 1 or y_px_left <= 1);
    std.debug.assert(2 * x_margin + 2 * w + x_spacing <= buf.width);
    std.debug.assert(2 * y_margin + 4 * w + 3 * y_spacing <= buf.height);

    var x: [2]c_int = undefined;
    var y: [4]c_int = undefined;
    x[0] = x_margin;
    x[1] = x_margin + w + x_spacing;
    y[0] = y_margin;
    y[1] = y[0] + w + y_spacing;
    y[2] = y[1] + w + y_spacing;
    y[3] = y[2] + w + y_spacing;

    std.debug.assert(wc >= 0x2800);
    std.debug.assert(wc <= 0x28ff);
    const sym: u8 = @intCast(wc - 0x2800);

        // Left side
    if (sym & 1 != 0)
        rect(buf, x[0], y[0], x[0] + w, y[0] + w);
    if (sym & 2 != 0)
        rect(buf, x[0], y[1], x[0] + w, y[1] + w);
    if (sym & 4 != 0)
        rect(buf, x[0], y[2], x[0] + w, y[2] + w);

        // Right side
    if (sym & 8 != 0)
        rect(buf, x[1], y[0], x[1] + w, y[0] + w);
    if (sym & 16 != 0)
        rect(buf, x[1], y[1], x[1] + w, y[1] + w);
    if (sym & 32 != 0)
        rect(buf, x[1], y[2], x[1] + w, y[2] + w);

        // 8-dot patterns
    if (sym & 64 != 0)
        rect(buf, x[0], y[3], x[0] + w, y[3] + w);
    if (sym & 128 != 0)
        rect(buf, x[1], y[3], x[1] + w, y[3] + w);
}

fn sextantUpperLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, 0, buf.x_halfs[0], buf.y_thirds[0]);
}

fn sextantMiddleLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, buf.y_thirds[0], buf.x_halfs[0], buf.y_thirds[1]);
}

fn sextantLowerLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, buf.y_thirds[1], buf.x_halfs[0], buf.height);
}

fn sextantUpperRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], 0, buf.width, buf.y_thirds[0]);
}

fn sextantMiddleRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], buf.y_thirds[0], buf.width, buf.y_thirds[1]);
}

fn sextantLowerRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], buf.y_thirds[1], buf.width, buf.height);
}

export fn draw_sextant(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    // Each byte encodes one sextant:
    //
    // Bit     sextant
    //   0      upper left
    //   1      middle left
    //   2      lower left
    //   3      upper right
    //   4      middle right
    //   5      lower right
    const UPPER_LEFT: u8 = 1 << 0;
    const MIDDLE_LEFT: u8 = 1 << 1;
    const LOWER_LEFT: u8 = 1 << 2;
    const UPPER_RIGHT: u8 = 1 << 3;
    const MIDDLE_RIGHT: u8 = 1 << 4;
    const LOWER_RIGHT: u8 = 1 << 5;

    const matrix = [_]u8{
        // U+1fb00 - U+1fb0f
        UPPER_LEFT,
        UPPER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT,
        MIDDLE_LEFT,
        UPPER_LEFT | MIDDLE_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT,
        MIDDLE_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT,
        UPPER_RIGHT | MIDDLE_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT,
        LOWER_LEFT,
        // U+1fb10 - U+1fb1f
        UPPER_LEFT | LOWER_LEFT,
        UPPER_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT,
        MIDDLE_LEFT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT,
        MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        LOWER_RIGHT,
        UPPER_LEFT | LOWER_RIGHT,
        // U+1fb20 - U+1fb2f
        UPPER_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_RIGHT,
        MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_RIGHT,
        MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        // U+1fb30 - U+1fb3b
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
    };

    std.debug.assert(wc >= 0x1fb00 and wc <= 0x1fb3b);
    const idx: usize = @intCast(wc - 0x1fb00);

    std.debug.assert(idx < matrix.len);
    const encoded = matrix[idx];

    if (encoded & UPPER_LEFT != 0)
        sextantUpperLeft(buf);

    if (encoded & MIDDLE_LEFT != 0)
        sextantMiddleLeft(buf);

    if (encoded & LOWER_LEFT != 0)
        sextantLowerLeft(buf);

    if (encoded & UPPER_RIGHT != 0)
        sextantUpperRight(buf);

    if (encoded & MIDDLE_RIGHT != 0)
        sextantMiddleRight(buf);

    if (encoded & LOWER_RIGHT != 0)
        sextantLowerRight(buf);
}

fn octantUpperLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, 0, buf.x_halfs[0], buf.y_quads[0]);
}

fn octantMiddleUpLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, buf.y_quads[0], buf.x_halfs[0], buf.y_quads[1]);
}

fn octantMiddleDownLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, buf.y_quads[1], buf.x_halfs[0], buf.y_quads[2]);
}

fn octantLowerLeft(buf: *types.BoxBuf) void {
    rect(buf, 0, buf.y_quads[2], buf.x_halfs[0], buf.height);
}

fn octantUpperRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], 0, buf.width, buf.y_quads[0]);
}

fn octantMiddleUpRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], buf.y_quads[0], buf.width, buf.y_quads[1]);
}

fn octantMiddleDownRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], buf.y_quads[1], buf.width, buf.y_quads[2]);
}

fn octantLowerRight(buf: *types.BoxBuf) void {
    rect(buf, buf.x_halfs[1], buf.y_quads[2], buf.width, buf.height);
}

export fn draw_octant(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    // Each byte encodes one octant:
    //
    // Bit      octant part
    //   0      upper left
    //   1      middle, upper left
    //   2      middle, lower left
    //   3      lower, left
    //   4      upper right
    //   5      middle, upper right
    //   6      middle, lower right
    //   7      lower right
    const UPPER_LEFT: u8 = 1 << 0;
    const MIDDLE_UP_LEFT: u8 = 1 << 1;
    const MIDDLE_DOWN_LEFT: u8 = 1 << 2;
    const LOWER_LEFT: u8 = 1 << 3;
    const UPPER_RIGHT: u8 = 1 << 4;
    const MIDDLE_UP_RIGHT: u8 = 1 << 5;
    const MIDDLE_DOWN_RIGHT: u8 = 1 << 6;
    const LOWER_RIGHT: u8 = 1 << 7;

    const matrix = [_]u8{
        // U+1CD00 - U+1CD0F
        MIDDLE_UP_LEFT,
        MIDDLE_UP_LEFT | UPPER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | UPPER_RIGHT,
        MIDDLE_UP_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT,
        MIDDLE_DOWN_LEFT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT,
        // U+1CD10 - U+1CD1F
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT,
        MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT,
        // U+1CD20 - U+1CD2F
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT,
        MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        // U+1CD30 - U+1CD3F
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT,
        UPPER_LEFT | LOWER_LEFT,
        UPPER_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_LEFT,
        MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        // U+1CD40 - U+1CD4F
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        // U+1CD50 - U+1CD5F
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT,
        MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        // U+1CD60 - U+1CD6F
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        // U+1CD70 - U+1CD7F
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT,
        UPPER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_RIGHT,
        // U+1CD80 - U+1CD8F
        MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_RIGHT,
        // U+1CD90 - U+1CD9F
        UPPER_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        // U+1CDA0 - U+1CDAF
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | LOWER_LEFT | LOWER_RIGHT,
        // U+1CDB0 - U+1CDBF
        UPPER_LEFT | MIDDLE_UP_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        // U+1CDC0 - U+1CDCF
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        // U+1CDD0 - U+1CDDF
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        // U+1CDE0 - U+1CDE5
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_UP_LEFT | MIDDLE_UP_RIGHT | MIDDLE_DOWN_LEFT | MIDDLE_DOWN_RIGHT | LOWER_LEFT | LOWER_RIGHT,
    };

    // The C original has a _DEBUG-only assertion sweep over the matrix
    // checking that no two codepoints encode the same octant; the table is
    // carried over verbatim, so it is checked in review rather than at
    // runtime.

    std.debug.assert(wc >= 0x1cd00 and wc <= 0x1cde5);
    const idx: usize = @intCast(wc - 0x1cd00);

    std.debug.assert(idx < matrix.len);
    const encoded = matrix[idx];

    if (encoded & UPPER_LEFT != 0)
        octantUpperLeft(buf);

    if (encoded & MIDDLE_UP_LEFT != 0)
        octantMiddleUpLeft(buf);

    if (encoded & MIDDLE_DOWN_LEFT != 0)
        octantMiddleDownLeft(buf);

    if (encoded & LOWER_LEFT != 0)
        octantLowerLeft(buf);

    if (encoded & UPPER_RIGHT != 0)
        octantUpperRight(buf);

    if (encoded & MIDDLE_UP_RIGHT != 0)
        octantMiddleUpRight(buf);

    if (encoded & MIDDLE_DOWN_RIGHT != 0)
        octantMiddleDownRight(buf);

    if (encoded & LOWER_RIGHT != 0)
        octantLowerRight(buf);
}
