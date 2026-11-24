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

const PIXMAN_a8: u32 = 0x00000008;
const PIXMAN_a1: u32 = 0x00000001;

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
