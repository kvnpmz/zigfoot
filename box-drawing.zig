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

const LIGHT: u2 = 0;
const HEAVY: u2 = 1;

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
    const multiplier = @as(c_int, @intCast(thick)) * 2 + 1;

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
