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

//
// Chunk A5b -- the pixman diagonals and the wedge triangles.
//

const PIXMAN_OP_OVER: c_int = 0x03;
const PIXMAN_OP_OUT: c_int = 0x07;

/// pixman_fixed_t: 16.16 fixed point.
const pixman_fixed_t = i32;

const PixmanPointFixed = extern struct {
    x: pixman_fixed_t,
    y: pixman_fixed_t,
};

const PixmanLineFixed = extern struct {
    p1: PixmanPointFixed,
    p2: PixmanPointFixed,
};

const PixmanTrapezoid = extern struct {
    top: pixman_fixed_t,
    bottom: pixman_fixed_t,
    left: PixmanLineFixed,
    right: PixmanLineFixed,
};

const PixmanTriangle = extern struct {
    p1: PixmanPointFixed,
    p2: PixmanPointFixed,
    p3: PixmanPointFixed,
};

extern fn pixman_rasterize_trapezoid(
    image: *anyopaque,
    trap: *const PixmanTrapezoid,
    x_off: c_int,
    y_off: c_int,
) void;

extern fn pixman_composite_triangles(
    op: c_int,
    src: ?*anyopaque,
    dst: *anyopaque,
    mask_format: c_int,
    x_src: c_int,
    y_src: c_int,
    x_dst: c_int,
    y_dst: c_int,
    n_tris: c_int,
    tris: [*]const PixmanTriangle,
) void;

extern fn pixman_image_create_solid_fill(color: *const PixmanColor) ?*anyopaque;

extern fn pixman_image_composite(
    op: c_int,
    src: ?*anyopaque,
    mask: ?*anyopaque,
    dst: *anyopaque,
    src_x: c_int,
    src_y: c_int,
    mask_x: c_int,
    mask_y: c_int,
    dst_x: c_int,
    dst_y: c_int,
    width: c_int,
    height: c_int,
) void;

/// pixman_int_to_fixed(): the C macro shifts through uint32_t.
fn pixmanIntToFixed(i: c_int) pixman_fixed_t {
    return @bitCast(@as(u32, @bitCast(i)) << 16);
}

/// pixman_double_to_fixed(): truncating conversion.
fn pixmanDoubleToFixed(d: f64) pixman_fixed_t {
    return @intFromFloat(d * 65536.0);
}

export fn draw_box_drawings_light_diagonal_upper_right_to_lower_left(buf: *types.BoxBuf) callconv(.c) void {
    const trap = PixmanTrapezoid{
        .top = pixmanIntToFixed(0),
        .bottom = pixmanIntToFixed(buf.height),
        .left = .{
            .p1 = .{
                .x = pixmanDoubleToFixed(f(buf.width) - f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(0),
            },
            .p2 = .{
                .x = pixmanDoubleToFixed(0.0 - f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(buf.height),
            },
        },
        .right = .{
            .p1 = .{
                .x = pixmanDoubleToFixed(f(buf.width) + f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(0),
            },
            .p2 = .{
                .x = pixmanDoubleToFixed(0.0 + f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(buf.height),
            },
        },
    };

    pixman_rasterize_trapezoid(buf.pix.?, &trap, 0, 0);
}

export fn draw_box_drawings_light_diagonal_upper_left_to_lower_right(buf: *types.BoxBuf) callconv(.c) void {
    const trap = PixmanTrapezoid{
        .top = pixmanIntToFixed(0),
        .bottom = pixmanIntToFixed(buf.height),
        .left = .{
            .p1 = .{
                .x = pixmanDoubleToFixed(0.0 - f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(0),
            },
            .p2 = .{
                .x = pixmanDoubleToFixed(f(buf.width) - f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(buf.height),
            },
        },
        .right = .{
            .p1 = .{
                .x = pixmanDoubleToFixed(0.0 + f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(0),
            },
            .p2 = .{
                .x = pixmanDoubleToFixed(f(buf.width) + f(buf.thickness[LIGHT]) / 2.0),
                .y = pixmanIntToFixed(buf.height),
            },
        },
    };

    pixman_rasterize_trapezoid(buf.pix.?, &trap, 0, 0);
}

export fn draw_box_drawings_light_diagonal_cross(buf: *types.BoxBuf) callconv(.c) void {
    draw_box_drawings_light_diagonal_upper_right_to_lower_left(buf);
    draw_box_drawings_light_diagonal_upper_left_to_lower_right(buf);
}

export fn draw_wedge_triangle(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    const width = buf.width;
    const height = buf.height;

    const halfs0 = buf.x_halfs[0];
    const halfs1 = buf.x_halfs[1];
    const thirds0 = buf.y_thirds[0];
    const thirds1 = buf.y_thirds[1];

    var p1_x: c_int = undefined;
    var p1_y: c_int = undefined;
    var p2_x: c_int = undefined;
    var p2_y: c_int = undefined;
    var p3_x: c_int = undefined;
    var p3_y: c_int = undefined;

    switch (wc) {
        0x1fb3c => { // 🬼
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb52 => { // 🭒
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3d => { // 🬽
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb53 => { // 🭓
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3e => { // 🬾
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb54 => { // 🭔
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3f => { // 🬿
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb55 => { // 🭕
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb40, 0x1fb56 => { // 🭀 🭖
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb47 => { // 🭇
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5d => { // 🭝
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb48 => { // 🭈
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5e => { // 🭞
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb49 => { // 🭉
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5f => { // 🭟
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4a => { // 🭊
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb60 => { // 🭠
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4b, 0x1fb61 => { // 🭋 🭡
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb57 => { // 🭗
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb41 => { // 🭁
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb58 => { // 🭘
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb42 => { // 🭂
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb59 => { // 🭙
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb43 => { // 🭃
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb5a => { // 🭚
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb44 => { // 🭄
            p1_x = 0;
            p2_x = 0;
            p3_x = width;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb5b, 0x1fb45 => { // 🭛 🭅
            p1_x = 0;
            p2_x = 0;
            p3_x = halfs0;
            p1_y = 0;
            p3_y = 0;
            p2_y = height;
        },

        0x1fb62 => { // 🭢
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb4c => { // 🭌
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb63 => { // 🭣
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb4d => { // 🭍
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds0;
        },

        0x1fb64 => { // 🭤
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb4e => { // 🭎
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb65 => { // 🭥
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb4f => { // 🭏
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = 0;
            p3_y = 0;
            p2_y = thirds1;
        },

        0x1fb66, 0x1fb50 => { // 🭦 ⭐
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p3_y = 0;
            p2_y = height;
        },

        0x1fb46 => { // 🭆
            p1_x = 0;
            p1_y = thirds1;
            p2_x = width;
            p2_y = thirds0;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb51 => { // 🭑
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p2_y;
        },

        0x1fb5c => { // 🭜
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb67 => { // 🭧
            p1_x = 0;
            p1_y = thirds0;
            p2_x = width;
            p2_y = p1_y;
            p3_x = width;
            p3_y = thirds1;
        },

        0x1fb6c, 0x1fb68 => { // 🭬 🭨
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs0;
            p2_y = @divTrunc(height, 2);
            p3_x = 0;
            p3_y = height;
        },

        0x1fb6d, 0x1fb69 => { // 🭭 🭩
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = @divTrunc(height, 2);
            p3_x = width;
            p3_y = 0;
        },

        0x1fb6e, 0x1fb6a => { // 🭮 🭪
            p1_x = width;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = @divTrunc(height, 2);
            p3_x = width;
            p3_y = height;
        },

        0x1fb6f, 0x1fb6b => { // 🭯 🭫
            p1_x = 0;
            p1_y = height;
            p2_x = halfs1;
            p2_y = @divTrunc(height, 2);
            p3_x = width;
            p3_y = height;
        },

        else => @panic("unimplemented Unicode codepoint"),
    }

    const tri = PixmanTriangle{
        .p1 = .{ .x = pixmanIntToFixed(p1_x), .y = pixmanIntToFixed(p1_y) },
        .p2 = .{ .x = pixmanIntToFixed(p2_x), .y = pixmanIntToFixed(p2_y) },
        .p3 = .{ .x = pixmanIntToFixed(p3_x), .y = pixmanIntToFixed(p3_y) },
    };

    const src = pixman_image_create_solid_fill(&white);
    pixman_composite_triangles(
        PIXMAN_OP_OVER,
        src,
        buf.pix.?,
        @intCast(buf.format),
        0,
        0,
        0,
        0,
        1,
        @ptrCast(&tri),
    );
    pixman_image_unref(src.?);
}

export fn draw_wedge_triangle_inverted(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    draw_wedge_triangle(buf, wc);

    const src = pixman_image_create_solid_fill(&white);
    pixman_image_composite(
        PIXMAN_OP_OUT,
        src,
        null,
        buf.pix.?,
        0,
        0,
        0,
        0,
        0,
        0,
        buf.width,
        buf.height,
    );
    pixman_image_unref(src.?);
}

export fn draw_wedge_triangle_and_box(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    draw_wedge_triangle(buf, wc);

    const width = buf.width;
    const height = buf.height;

    var box: PixmanBox32 = undefined;

    switch (wc) {
        0x1fb46, 0x1fb51 => box = .{
            .x1 = 0,
            .y1 = buf.y_thirds[1],
            .x2 = width,
            .y2 = height,
        },

        0x1fb5c, 0x1fb67 => box = .{
            .x1 = 0,
            .y1 = 0,
            .x2 = width,
            .y2 = buf.y_thirds[0],
        },

        else => {},
    }

    fillBox(buf, box);
}

//
// Chunk A5c -- the light arcs, the glyph dispatch and box_drawing() itself.
// With this chunk box-drawing.c is gone: box-drawing.zig owns the whole
// module (struct buf is still declared in box-drawing.h so the ABI probe can
// pin it against types.BoxBuf).
//

extern fn terminal_shim_fcft_font_antialias(font: *const anyopaque) callconv(.c) bool;

export fn draw_box_drawings_light_arc(buf: *types.BoxBuf, wc: u32) callconv(.c) void {
    const fmt = buf.format;
    const supersample: c_int = if (fmt == PIXMAN_a8) 4 else 1;
    const height: c_int = buf.height * supersample;
    const width: c_int = buf.width * supersample;
    const stride: c_int = if (fmt == PIXMAN_a8)
        strideForFormatAndWidth(PIXMAN_a8, width)
    else
        buf.stride;
    const data: [*]u8 = if (supersample > 1)
        @ptrCast(@alignCast(std.c.calloc(@intCast(height * stride), 1) orelse
            @panic("out of memory")))
    else
        buf.data.?;

    const thick: c_int = buf.thickness[LIGHT] * supersample;

    const height_pixels = buf.height;
    const width_pixels = buf.width;
    const thick_pixels = buf.thickness[LIGHT];

    // The general idea here is to connect the two incoming lines using a
    // circle, which is extended to the box-edges with vertical/horizontal
    // lines. See the C original for the full rationale behind the radius
    // choice; only the mechanics are reproduced here.
    const circle_inner_edge = @divTrunc(@min(width_pixels, height_pixels) - thick_pixels, 2);

    // We want to draw the quartercircle by filling small circles (with
    // r = thickness/2.) whose centers are on its edge, so add the exact half
    // thickness to the radius of the inner circle.
    var c_r: f64 = f(circle_inner_edge) + f(thick_pixels) / 2.0;

    var vert_to: c_int = 0;
    var hor_to: c_int = 0;

    // Coordinates of the circle-center.
    var c_x: c_int = 0;
    var c_y: c_int = 0;

    // For a given y there are up to two solutions for the circle-equation.
    // -1 for the left, and 1 for the right hemisphere.
    var circle_hemisphere: c_int = 0;

    // The quarter circle only has to be evaluated for a small range of
    // y-values.
    var y_min: c_int = 0;
    var y_max: c_int = 0;

    switch (wc) {
        0x256d => { // ╭
            // Don't use supersampled coordinates yet, we want to align actual
            // pixels: pixel-coordinates of the lower edge of the right line
            // and the right edge of the bottom line.
            const right_bottom_edge = @divTrunc(height_pixels + thick_pixels, 2);
            const bottom_right_edge = @divTrunc(width_pixels + thick_pixels, 2);

            c_y = right_bottom_edge + circle_inner_edge;
            c_x = bottom_right_edge + circle_inner_edge;

            // We want to render the left, not the right hemisphere.
            circle_hemisphere = -1;

            // Don't evaluate beyond c_y, the vertical line is drawn there.
            y_min = 0;
            y_max = c_y;

            // The vertical line extends to the bottom of the box, the
            // horizontal one to the right.
            vert_to = height_pixels;
            hor_to = width_pixels;
        },

        0x256e => { // ╮
            const left_bottom_edge = @divTrunc(height_pixels + thick_pixels, 2);
            const bottom_left_edge = @divTrunc(width_pixels - thick_pixels, 2);

            c_y = left_bottom_edge + circle_inner_edge;
            c_x = bottom_left_edge - circle_inner_edge;

            circle_hemisphere = 1;

            y_min = 0;
            y_max = c_y;

            vert_to = height_pixels;
            hor_to = 0;
        },

        0x2570 => { // ╰
            const right_top_edge = @divTrunc(height_pixels - thick_pixels, 2);
            const top_right_edge = @divTrunc(width_pixels + thick_pixels, 2);

            c_y = right_top_edge - circle_inner_edge;
            c_x = top_right_edge + circle_inner_edge;

            circle_hemisphere = -1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = width_pixels;
        },

        0x256f => { // ╯
            const left_top_edge = @divTrunc(height_pixels - thick_pixels, 2);
            const top_left_edge = @divTrunc(width_pixels - thick_pixels, 2);

            c_y = left_top_edge - circle_inner_edge;
            c_x = top_left_edge - circle_inner_edge;

            circle_hemisphere = 1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = 0;
        },

        else => {},
    }

    // Store for horizontal+vertical line.
    const c_x_pixels = c_x;
    const c_y_pixels = c_y;

    // Bring coordinates from pixel-grid to supersampled grid.
    c_r *= f(supersample);
    c_x *= supersample;
    c_y *= supersample;
    y_min *= supersample;
    y_max *= supersample;

    const c_r2 = c_r * c_r;

    // To prevent gaps in the circle, each pixel is sampled multiple times.
    // As the quartercircle ends (vertically) in the middle of a pixel, an
    // uneven number helps hit that exactly.
    var i: f64 = f(y_min * 16);
    while (i <= f(y_max * 16)) : (i += 1.0) {
        const y = i / 16.0;
        const dy = y - f(c_y);
        const radicand = c_r2 - dy * dy;

        // The C code sets errno and checks it after sqrt(); the only error
        // sqrt() can raise for this input is EDOM on a negative argument.
        if (radicand < 0.0)
            continue;

        const x = f(circle_hemisphere) * @sqrt(radicand) + f(c_x);

        const row = roundi(y);
        const col = roundi(x);

        if (col < 0)
            continue;

        // Rectangle big enough to fit entire circle with radius thick/2.
        const row1 = row - (@divTrunc(thick, 2) + 1);
        const row2 = row + (@divTrunc(thick, 2) + 1);
        const col1 = col - (@divTrunc(thick, 2) + 1);
        const col2 = col + (@divTrunc(thick, 2) + 1);

        const row_start = @min(row1, row2);
        const row_end = @max(row1, row2);
        const col_start = @min(col1, col2);
        const col_end = @max(col1, col2);

        std.debug.assert(row_end > row_start);
        std.debug.assert(col_end > col_start);

        // Draw a circle with radius thick/2 around x,y: reject pixels whose
        // center is further than thick/2 from x,y.
        var r: c_int = @max(row_start, 0);
        const r_end = @max(@min(row_end, height), 0);
        while (r < r_end) : (r += 1) {
            const r_midpoint = f(r) + 0.5;

            var c: c_int = @max(col_start, 0);
            const c_end = @max(@min(col_end, width), 0);
            while (c < c_end) : (c += 1) {
                const c_midpoint = f(c) + 0.5;

                // Vector from point on quartercircle to midpoint of the
                // current pixel.
                const center_midpoint_x = c_midpoint - x;
                const center_midpoint_y = r_midpoint - y;

                // Distance from current point to circle-center; skip if the
                // midpoint of the pixel is outside the circle.
                const dist = @sqrt(center_midpoint_x * center_midpoint_x +
                    center_midpoint_y * center_midpoint_y);
                if (dist > f(thick) / 2.0)
                    continue;

                if (fmt == PIXMAN_a1) {
                    const idx: usize = @intCast(@divTrunc(c, 8));
                    const bit_no: usize = @intCast(@mod(c, 8));
                    setA1Bit(data, @as(usize, @intCast(r * stride)) + idx, bit_no);
                } else {
                    data[@intCast(r * stride + c)] = 0xff;
                }
            }
        }
    }

    if (fmt == PIXMAN_a8) {
        std.debug.assert(data != buf.data.?);

        // Downsample
        const ss: usize = @intCast(supersample);
        const ss_stride: usize = @intCast(stride);

        var r: usize = 0;
        while (r < @as(usize, @intCast(buf.height))) : (r += 1) {
            var c: usize = 0;
            while (c < @as(usize, @intCast(buf.width))) : (c += 1) {
                var total: u32 = 0;
                var ii: usize = 0;
                while (ii < ss) : (ii += 1) {
                    var jj: usize = 0;
                    while (jj < ss) : (jj += 1) {
                        total += data[(r * ss + ii) * ss_stride + c * ss + jj];
                    }
                }

                const average: u8 = @intCast(@min(total / @as(u32, @intCast(supersample * supersample)), 0xff));
                buf.data.?[r * @as(usize, @intCast(buf.stride)) + c] = average;
            }
        }

        std.c.free(@ptrCast(data));
    }

    // Draw vertical/horizontal lines from quartercircle-edge to box-edge.
    box_vline(
        buf,
        @min(c_y_pixels, vert_to),
        @max(c_y_pixels, vert_to),
        @divTrunc(width_pixels - thick_pixels, 2),
        thick_pixels,
    );
    box_hline(
        buf,
        @min(c_x_pixels, hor_to),
        @max(c_x_pixels, hor_to),
        @divTrunc(height_pixels - thick_pixels, 2),
        thick_pixels,
    );
}

fn drawGlyph(buf: *types.BoxBuf, wc: u32) void {
    switch (wc) {
        0x2500 => draw_box_drawings_light_horizontal(buf),
        0x2501 => draw_box_drawings_heavy_horizontal(buf),
        0x2502 => draw_box_drawings_light_vertical(buf),
        0x2503 => draw_box_drawings_heavy_vertical(buf),
        0x2504 => draw_box_drawings_light_triple_dash_horizontal(buf),
        0x2505 => draw_box_drawings_heavy_triple_dash_horizontal(buf),
        0x2506 => draw_box_drawings_light_triple_dash_vertical(buf),
        0x2507 => draw_box_drawings_heavy_triple_dash_vertical(buf),
        0x2508 => draw_box_drawings_light_quadruple_dash_horizontal(buf),
        0x2509 => draw_box_drawings_heavy_quadruple_dash_horizontal(buf),
        0x250a => draw_box_drawings_light_quadruple_dash_vertical(buf),
        0x250b => draw_box_drawings_heavy_quadruple_dash_vertical(buf),
        0x250c => draw_box_drawings_light_down_and_right(buf),
        0x250d => draw_box_drawings_down_light_and_right_heavy(buf),
        0x250e => draw_box_drawings_down_heavy_and_right_light(buf),
        0x250f => draw_box_drawings_heavy_down_and_right(buf),
        0x2510 => draw_box_drawings_light_down_and_left(buf),
        0x2511 => draw_box_drawings_down_light_and_left_heavy(buf),
        0x2512 => draw_box_drawings_down_heavy_and_left_light(buf),
        0x2513 => draw_box_drawings_heavy_down_and_left(buf),
        0x2514 => draw_box_drawings_light_up_and_right(buf),
        0x2515 => draw_box_drawings_up_light_and_right_heavy(buf),
        0x2516 => draw_box_drawings_up_heavy_and_right_light(buf),
        0x2517 => draw_box_drawings_heavy_up_and_right(buf),
        0x2518 => draw_box_drawings_light_up_and_left(buf),
        0x2519 => draw_box_drawings_up_light_and_left_heavy(buf),
        0x251a => draw_box_drawings_up_heavy_and_left_light(buf),
        0x251b => draw_box_drawings_heavy_up_and_left(buf),
        0x251c => draw_box_drawings_light_vertical_and_right(buf),
        0x251d => draw_box_drawings_vertical_light_and_right_heavy(buf),
        0x251e => draw_box_drawings_up_heavy_and_right_down_light(buf),
        0x251f => draw_box_drawings_down_heavy_and_right_up_light(buf),
        0x2520 => draw_box_drawings_vertical_heavy_and_right_light(buf),
        0x2521 => draw_box_drawings_down_light_and_right_up_heavy(buf),
        0x2522 => draw_box_drawings_up_light_and_right_down_heavy(buf),
        0x2523 => draw_box_drawings_heavy_vertical_and_right(buf),
        0x2524 => draw_box_drawings_light_vertical_and_left(buf),
        0x2525 => draw_box_drawings_vertical_light_and_left_heavy(buf),
        0x2526 => draw_box_drawings_up_heavy_and_left_down_light(buf),
        0x2527 => draw_box_drawings_down_heavy_and_left_up_light(buf),
        0x2528 => draw_box_drawings_vertical_heavy_and_left_light(buf),
        0x2529 => draw_box_drawings_down_light_and_left_up_heavy(buf),
        0x252a => draw_box_drawings_up_light_and_left_down_heavy(buf),
        0x252b => draw_box_drawings_heavy_vertical_and_left(buf),
        0x252c => draw_box_drawings_light_down_and_horizontal(buf),
        0x252d => draw_box_drawings_left_heavy_and_right_down_light(buf),
        0x252e => draw_box_drawings_right_heavy_and_left_down_light(buf),
        0x252f => draw_box_drawings_down_light_and_horizontal_heavy(buf),
        0x2530 => draw_box_drawings_down_heavy_and_horizontal_light(buf),
        0x2531 => draw_box_drawings_right_light_and_left_down_heavy(buf),
        0x2532 => draw_box_drawings_left_light_and_right_down_heavy(buf),
        0x2533 => draw_box_drawings_heavy_down_and_horizontal(buf),
        0x2534 => draw_box_drawings_light_up_and_horizontal(buf),
        0x2535 => draw_box_drawings_left_heavy_and_right_up_light(buf),
        0x2536 => draw_box_drawings_right_heavy_and_left_up_light(buf),
        0x2537 => draw_box_drawings_up_light_and_horizontal_heavy(buf),
        0x2538 => draw_box_drawings_up_heavy_and_horizontal_light(buf),
        0x2539 => draw_box_drawings_right_light_and_left_up_heavy(buf),
        0x253a => draw_box_drawings_left_light_and_right_up_heavy(buf),
        0x253b => draw_box_drawings_heavy_up_and_horizontal(buf),
        0x253c => draw_box_drawings_light_vertical_and_horizontal(buf),
        0x253d => draw_box_drawings_left_heavy_and_right_vertical_light(buf),
        0x253e => draw_box_drawings_right_heavy_and_left_vertical_light(buf),
        0x253f => draw_box_drawings_vertical_light_and_horizontal_heavy(buf),
        0x2540 => draw_box_drawings_up_heavy_and_down_horizontal_light(buf),
        0x2541 => draw_box_drawings_down_heavy_and_up_horizontal_light(buf),
        0x2542 => draw_box_drawings_vertical_heavy_and_horizontal_light(buf),
        0x2543 => draw_box_drawings_left_up_heavy_and_right_down_light(buf),
        0x2544 => draw_box_drawings_right_up_heavy_and_left_down_light(buf),
        0x2545 => draw_box_drawings_left_down_heavy_and_right_up_light(buf),
        0x2546 => draw_box_drawings_right_down_heavy_and_left_up_light(buf),
        0x2547 => draw_box_drawings_down_light_and_up_horizontal_heavy(buf),
        0x2548 => draw_box_drawings_up_light_and_down_horizontal_heavy(buf),
        0x2549 => draw_box_drawings_right_light_and_left_vertical_heavy(buf),
        0x254a => draw_box_drawings_left_light_and_right_vertical_heavy(buf),
        0x254b => draw_box_drawings_heavy_vertical_and_horizontal(buf),
        0x254c => draw_box_drawings_light_double_dash_horizontal(buf),
        0x254d => draw_box_drawings_heavy_double_dash_horizontal(buf),
        0x254e => draw_box_drawings_light_double_dash_vertical(buf),
        0x254f => draw_box_drawings_heavy_double_dash_vertical(buf),
        0x2550 => draw_box_drawings_double_horizontal(buf),
        0x2551 => draw_box_drawings_double_vertical(buf),
        0x2552 => draw_box_drawings_down_single_and_right_double(buf),
        0x2553 => draw_box_drawings_down_double_and_right_single(buf),
        0x2554 => draw_box_drawings_double_down_and_right(buf),
        0x2555 => draw_box_drawings_down_single_and_left_double(buf),
        0x2556 => draw_box_drawings_down_double_and_left_single(buf),
        0x2557 => draw_box_drawings_double_down_and_left(buf),
        0x2558 => draw_box_drawings_up_single_and_right_double(buf),
        0x2559 => draw_box_drawings_up_double_and_right_single(buf),
        0x255a => draw_box_drawings_double_up_and_right(buf),
        0x255b => draw_box_drawings_up_single_and_left_double(buf),
        0x255c => draw_box_drawings_up_double_and_left_single(buf),
        0x255d => draw_box_drawings_double_up_and_left(buf),
        0x255e => draw_box_drawings_vertical_single_and_right_double(buf),
        0x255f => draw_box_drawings_vertical_double_and_right_single(buf),
        0x2560 => draw_box_drawings_double_vertical_and_right(buf),
        0x2561 => draw_box_drawings_vertical_single_and_left_double(buf),
        0x2562 => draw_box_drawings_vertical_double_and_left_single(buf),
        0x2563 => draw_box_drawings_double_vertical_and_left(buf),
        0x2564 => draw_box_drawings_down_single_and_horizontal_double(buf),
        0x2565 => draw_box_drawings_down_double_and_horizontal_single(buf),
        0x2566 => draw_box_drawings_double_down_and_horizontal(buf),
        0x2567 => draw_box_drawings_up_single_and_horizontal_double(buf),
        0x2568 => draw_box_drawings_up_double_and_horizontal_single(buf),
        0x2569 => draw_box_drawings_double_up_and_horizontal(buf),
        0x256a => draw_box_drawings_vertical_single_and_horizontal_double(buf),
        0x256b => draw_box_drawings_vertical_double_and_horizontal_single(buf),
        0x256c => draw_box_drawings_double_vertical_and_horizontal(buf),
        0x256d...0x2570 => draw_box_drawings_light_arc(buf, wc),
        0x2571 => draw_box_drawings_light_diagonal_upper_right_to_lower_left(buf),
        0x2572 => draw_box_drawings_light_diagonal_upper_left_to_lower_right(buf),
        0x2573 => draw_box_drawings_light_diagonal_cross(buf),
        0x2574 => draw_box_drawings_light_left(buf),
        0x2575 => draw_box_drawings_light_up(buf),
        0x2576 => draw_box_drawings_light_right(buf),
        0x2577 => draw_box_drawings_light_down(buf),
        0x2578 => draw_box_drawings_heavy_left(buf),
        0x2579 => draw_box_drawings_heavy_up(buf),
        0x257a => draw_box_drawings_heavy_right(buf),
        0x257b => draw_box_drawings_heavy_down(buf),
        0x257c => draw_box_drawings_light_left_and_heavy_right(buf),
        0x257d => draw_box_drawings_light_up_and_heavy_down(buf),
        0x257e => draw_box_drawings_heavy_left_and_light_right(buf),
        0x257f => draw_box_drawings_heavy_up_and_light_down(buf),
        0x2580 => draw_upper_half_block(buf),
        0x2581 => draw_lower_one_eighth_block(buf),
        0x2582 => draw_lower_one_quarter_block(buf),
        0x2583 => draw_lower_three_eighths_block(buf),
        0x2584 => draw_lower_half_block(buf),
        0x2585 => draw_lower_five_eighths_block(buf),
        0x2586 => draw_lower_three_quarters_block(buf),
        0x2587 => draw_lower_seven_eighths_block(buf),
        0x2588 => draw_full_block(buf),
        0x2589 => draw_left_seven_eighths_block(buf),
        0x258a => draw_left_three_quarters_block(buf),
        0x258b => draw_left_five_eighths_block(buf),
        0x258c => draw_left_half_block(buf),
        0x258d => draw_left_three_eighths_block(buf),
        0x258e => draw_left_one_quarter_block(buf),
        0x258f => draw_left_one_eighth_block(buf),
        0x2590 => draw_right_half_block(buf),
        0x2591 => draw_light_shade(buf),
        0x2592 => draw_medium_shade(buf),
        0x2593 => draw_dark_shade(buf),
        0x2594 => draw_upper_one_eighth_block(buf),
        0x2595 => draw_right_one_eighth_block(buf),
        0x2596...0x259f => draw_quadrant(buf, wc),
        0x2800...0x28ff => draw_braille(buf, wc),
        0x1cd00...0x1cde5 => draw_octant(buf, wc),
        0x1fb00...0x1fb3b => draw_sextant(buf, wc),
        0x1fb3c...0x1fb40, 0x1fb47...0x1fb4b, 0x1fb57...0x1fb5b, 0x1fb62...0x1fb66, 0x1fb6c...0x1fb6f => draw_wedge_triangle(buf, wc),
        0x1fb41...0x1fb45, 0x1fb4c...0x1fb50, 0x1fb52...0x1fb56, 0x1fb5d...0x1fb61, 0x1fb68...0x1fb6b => draw_wedge_triangle_inverted(buf, wc),
        0x1fb46, 0x1fb51, 0x1fb5c, 0x1fb67 => draw_wedge_triangle_and_box(buf, wc),
        0x1fb9a => {
            draw_wedge_triangle(buf, 0x1fb6d);
            draw_wedge_triangle(buf, 0x1fb6f);
        },
        0x1fb9b => {
            draw_wedge_triangle(buf, 0x1fb6c);
            draw_wedge_triangle(buf, 0x1fb6e);
        },
        0x1fb70 => draw_vertical_one_eighth_block_2(buf),
        0x1fb71 => draw_vertical_one_eighth_block_3(buf),
        0x1fb72 => draw_vertical_one_eighth_block_4(buf),
        0x1fb73 => draw_vertical_one_eighth_block_5(buf),
        0x1fb74 => draw_vertical_one_eighth_block_6(buf),
        0x1fb75 => draw_vertical_one_eighth_block_7(buf),
        0x1fb76 => draw_horizontal_one_eighth_block_2(buf),
        0x1fb77 => draw_horizontal_one_eighth_block_3(buf),
        0x1fb78 => draw_horizontal_one_eighth_block_4(buf),
        0x1fb79 => draw_horizontal_one_eighth_block_5(buf),
        0x1fb7a => draw_horizontal_one_eighth_block_6(buf),
        0x1fb7b => draw_horizontal_one_eighth_block_7(buf),
        0x1fb82 => draw_upper_one_quarter_block(buf),
        0x1fb83 => draw_upper_three_eighths_block(buf),
        0x1fb84 => draw_upper_five_eighths_block(buf),
        0x1fb85 => draw_upper_three_quarters_block(buf),
        0x1fb86 => draw_upper_seven_eighths_block(buf),
        0x1fb7c => draw_left_and_lower_one_eighth_block(buf),
        0x1fb7d => draw_left_and_upper_one_eighth_block(buf),
        0x1fb7e => draw_right_and_upper_one_eighth_block(buf),
        0x1fb7f => draw_right_and_lower_one_eighth_block(buf),
        0x1fb80 => draw_upper_and_lower_one_eighth_block(buf),
        0x1fb81 => draw_horizontal_one_eighth_1358_block(buf),
        0x1fb87 => draw_right_one_quarter_block(buf),
        0x1fb88 => draw_right_three_eighths_block(buf),
        0x1fb89 => draw_right_five_eighths_block(buf),
        0x1fb8a => draw_right_three_quarters_block(buf),
        0x1fb8b => draw_right_seven_eighths_block(buf),
        else => {},
    }
}

export fn box_drawing(term: *const types.Terminal, wc: u32) callconv(.c) *types.FcftGlyph {
    const width = term.cell_width;
    const height = term.cell_height;

    const font = term.fonts[0] orelse @panic("box_drawing: no font");
    const fmt: u32 = if (terminal_shim_fcft_font_antialias(@ptrCast(font))) PIXMAN_a8 else PIXMAN_a1;

    const stride = strideForFormatAndWidth(fmt, width);
    const data: [*]u8 = @ptrCast(@alignCast(
        std.c.calloc(@intCast(height * stride), 1) orelse @panic("out of memory")));

    const pix = pixman_image_create_bits_no_clear(
        @intCast(fmt),
        width,
        height,
        @ptrCast(@alignCast(data)),
        stride,
    );

    if (pix == null) {
        std.c._errno().* = 12; // ENOMEM
        perror("box_drawing");
        std.c.abort();
    }

    const conf = term.conf orelse @panic("box_drawing: no config");

    const dpi: f64 = if (term.font_is_sized_by_dpi) @floatCast(term.font_dpi) else 96.0;
    const scale: f64 = if (term.font_is_sized_by_dpi) 1.0 else @floatCast(term.scale);
    const cell_w: f64 = @floatFromInt(term.cell_width);
    const cell_h: f64 = @floatFromInt(term.cell_height);
    const cell_size = @sqrt(cell_w * cell_w + cell_h * cell_h);

    var base_thickness: c_int = @intFromFloat(
        @as(f64, @floatCast(conf.tweak.box_drawing_base_thickness)) * scale * cell_size * dpi / 72.0,
    );
    base_thickness = @max(base_thickness, 1);

    var y_third_0: c_int = 0;
    var y_third_1: c_int = 0;
    switch (@mod(height, 3)) {
        0 => {
            y_third_0 = @divTrunc(height, 3);
            y_third_1 = @divTrunc(2 * height, 3);
        },

        1 => {
            y_third_0 = @divTrunc(height, 3);
            y_third_1 = @divTrunc(2 * height, 3) + 1;
        },

        2 => {
            y_third_0 = @divTrunc(height, 3) + 1;
            y_third_1 = y_third_0 + @divTrunc(height, 3);
        },

        else => unreachable,
    }

    // All four height % 4 cases yield the same thirds of the cell height.
    const y_quad_0 = @divTrunc(height, 4);
    const y_quad_1 = @divTrunc(height, 2);
    const y_quad_2 = @divTrunc(3 * height, 4);

    var buf = types.BoxBuf{
        .data = data,
        .pix = pix,
        .format = fmt,
        .width = width,
        .height = height,
        .stride = stride,
        .solid_shades = conf.tweak.box_drawing_solid_shades,

        .thickness = .{
            box_thickness(base_thickness, LIGHT),
            box_thickness(base_thickness, HEAVY),
        },

        // Overlap when width is odd
        .x_halfs = .{
            roundi(@as(f64, @floatFromInt(width)) / 2.0), // Endpoint first half
            @divTrunc(width, 2), // Startpoint second half
        },

        .y_thirds = .{
            y_third_0, // Endpoint first third, start point second third
            y_third_1, // Endpoint second third, start point last third
        },

        .y_quads = .{
            y_quad_0,
            y_quad_1,
            y_quad_2,
        },
    };

    log_msg(
        LOG_CLASS_DEBUG,
        "box-drawing",
        "box-drawing.zig",
        @intCast(@src().line),
        "LIGHT=%d, HEAVY=%d",
        buf.thickness[LIGHT],
        buf.thickness[HEAVY],
    );

    drawGlyph(&buf, wc);

    const glyph: *types.FcftGlyph = @ptrCast(@alignCast(
        std.c.malloc(@sizeOf(types.FcftGlyph)) orelse @panic("out of memory")));
    glyph.* = .{
        .cp = wc,
        .cols = 1,
        .font_name = null,
        .pix = buf.pix,
        .x = -@as(c_int, term.font_x_ofs),
        .y = @as(c_int, term.font_baseline),
        .width = width,
        .height = height,
        .advance = .{
            .x = width,
            .y = height,
        },
        .is_color_glyph = false,
    };

    return glyph;
}
