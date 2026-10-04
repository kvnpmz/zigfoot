const std = @import("std");

extern fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;

const CursorShape = enum(c_int) {
    none = 0,
    custom = 1,
    hidden = 2,
    left_ptr = 3,
    text = 4,
    top_left_corner = 5,
    top_right_corner = 6,
    bottom_left_corner = 7,
    bottom_right_corner = 8,
    left_side = 9,
    right_side = 10,
    top_side = 11,
    bottom_side = 12,
};

const ShapeNames = struct {
    names: [3][*c]const u8,
};

const shape_names = [_]ShapeNames{
    .{ .names = .{ null, null, null } },
    .{ .names = .{ null, null, null } },
    .{ .names = .{ "hidden", null, null } },
    .{ .names = .{ "default", "left_ptr", null } },
    .{ .names = .{ "text", "xterm", null } },
    .{ .names = .{ "nw-resize", "top_left_corner", null } },
    .{ .names = .{ "ne-resize", "top_right_corner", null } },
    .{ .names = .{ "sw-resize", "bottom_left_corner", null } },
    .{ .names = .{ "se-resize", "bottom_right_corner", null } },
    .{ .names = .{ "w-resize", "left_side", null } },
    .{ .names = .{ "e-resize", "right_side", null } },
    .{ .names = .{ "n-resize", "top_side", null } },
    .{ .names = .{ "s-resize", "bottom_side", null } },
};

export fn cursor_shape_to_string(shape: c_int) [*c]const [*c]const u8 {
    if (shape < 0 or shape >= shape_names.len)
        std.debug.panic("invalid cursor shape", .{});

    return &shape_names[@intCast(shape)].names;
}

export fn cursor_shape_to_server_shape(shape: c_int) c_int {
    return switch (shape) {
        3 => 1, // DEFAULT
        4 => 9, // TEXT
        5 => 21, // NW_RESIZE
        6 => 20, // NE_RESIZE
        7 => 24, // SW_RESIZE
        8 => 23, // SE_RESIZE
        9 => 25, // W_RESIZE
        10 => 18, // E_RESIZE
        11 => 19, // N_RESIZE
        12 => 22, // S_RESIZE
        else => std.debug.panic("invalid cursor shape", .{}),
    };
}

fn matches(xcursor: [*c]const u8, name: [*c]const u8) bool {
    return strcmp(xcursor, name) == 0;
}

export fn cursor_string_to_server_shape(xcursor: [*c]const u8, bound_version: c_int) c_int {
    if (xcursor == null)
        return 0;

    const names = [_]struct {
        shape: c_int,
        version: c_int,
        names: []const [*c]const u8,
    }{
        .{ .shape = 1, .version = 0, .names = &.{ "default", "left_ptr" } },
        .{ .shape = 2, .version = 0, .names = &.{"context-menu"} },
        .{ .shape = 3, .version = 0, .names = &.{ "help", "question_arrow" } },
        .{ .shape = 4, .version = 0, .names = &.{ "pointer", "hand" } },
        .{ .shape = 5, .version = 0, .names = &.{ "progress", "left_ptr_watch" } },
        .{ .shape = 6, .version = 0, .names = &.{ "wait", "watch" } },
        .{ .shape = 7, .version = 0, .names = &.{"cell"} },
        .{ .shape = 8, .version = 0, .names = &.{ "crosshair", "cross" } },
        .{ .shape = 9, .version = 0, .names = &.{ "text", "xterm" } },
        .{ .shape = 10, .version = 0, .names = &.{"vertical-text"} },
        .{ .shape = 11, .version = 0, .names = &.{ "alias", "dnd-link" } },
        .{ .shape = 12, .version = 0, .names = &.{ "copy", "dnd-copy" } },
        .{ .shape = 13, .version = 0, .names = &.{ "move", "dnd-move" } },
        .{ .shape = 14, .version = 0, .names = &.{ "no-drop", "dnd-no-drop" } },
        .{ .shape = 15, .version = 0, .names = &.{ "not-allowed", "crossed_circle" } },
        .{ .shape = 16, .version = 0, .names = &.{ "grab", "hand1" } },
        .{ .shape = 17, .version = 0, .names = &.{"grabbing"} },
        .{ .shape = 18, .version = 0, .names = &.{ "e-resize", "right_side" } },
        .{ .shape = 19, .version = 0, .names = &.{ "n-resize", "top_side" } },
        .{ .shape = 20, .version = 0, .names = &.{ "ne-resize", "top_right_corner" } },
        .{ .shape = 21, .version = 0, .names = &.{ "nw-resize", "top_left_corner" } },
        .{ .shape = 22, .version = 0, .names = &.{ "s-resize", "bottom_side" } },
        .{ .shape = 23, .version = 0, .names = &.{ "se-resize", "bottom_right_corner" } },
        .{ .shape = 24, .version = 0, .names = &.{ "sw-resize", "bottom_left_corner" } },
        .{ .shape = 25, .version = 0, .names = &.{ "w-resize", "left_side" } },
        .{ .shape = 26, .version = 0, .names = &.{ "ew-resize", "sb_h_double_arrow" } },
        .{ .shape = 27, .version = 0, .names = &.{ "ns-resize", "sb_v_double_arrow" } },
        .{ .shape = 28, .version = 0, .names = &.{ "nesw-resize", "fd_double_arrow" } },
        .{ .shape = 29, .version = 0, .names = &.{ "nwse-resize", "bd_double_arrow" } },
        .{ .shape = 30, .version = 0, .names = &.{ "col-resize", "sb_h_double_arrow" } },
        .{ .shape = 31, .version = 0, .names = &.{ "row-resize", "sb_v_double_arrow" } },
        .{ .shape = 32, .version = 0, .names = &.{ "all-scroll", "fleur" } },
        .{ .shape = 33, .version = 0, .names = &.{"zoom-in"} },
        .{ .shape = 34, .version = 0, .names = &.{"zoom-out"} },
        .{ .shape = 35, .version = 2, .names = &.{"dnd-ask"} },
        .{ .shape = 36, .version = 2, .names = &.{"all-resize"} },
    };

    for (names) |entry| {
        if (entry.version != 0 and bound_version < entry.version)
            continue;

        for (entry.names) |name| {
            if (matches(xcursor, name))
                return entry.shape;
        }
    }

    return 0;
}
