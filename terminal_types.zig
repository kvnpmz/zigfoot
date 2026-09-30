const std = @import("std");

pub const ColorSource = enum(c_int) {
    default,
    base16,
    base256,
    rgb,
};

pub const Coord = extern struct {
    col: c_int,
    row: c_int,
};

pub const Range = extern struct {
    start: Coord,
    end: Coord,
};

pub const Cursor = extern struct {
    point: Coord,
    lcf: bool,
};

pub const ScrollRegion = extern struct {
    start: c_int,
    end: c_int,
};

pub const DamageType = enum(c_int) {
    scroll,
    scroll_reverse,
    scroll_in_view,
    scroll_reverse_in_view,
};

pub const Damage = extern struct {
    type: DamageType,
    region: ScrollRegion,
    lines: u16,
};

pub const Attributes = packed struct(u64) {
    bold: bool,
    dim: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
    blink: bool,
    conceal: bool,
    reverse: bool,
    fg: u24,

    clean: bool,
    fg_src: u2,
    bg_src: u2,
    confined: bool,
    selected: bool,
    url: bool,
    bg: u24,
};

pub const Cell = extern struct {
    wc: u32,
    attrs: Attributes align(4),
};

pub const UriRangeData = extern struct {
    id: u64,
    uri: ?[*:0]u8,
};
test "terminal types layout" {
    try @import("std").testing.expectEqual(@as(usize, 8), @sizeOf(Coord));
    try @import("std").testing.expectEqual(@as(usize, 16), @sizeOf(Range));
    try @import("std").testing.expectEqual(@as(usize, 12), @sizeOf(Cursor));
    try @import("std").testing.expectEqual(@as(usize, 8), @sizeOf(ScrollRegion));
}

pub const UnderlineStyle = c_int;

pub const UnderlineRangeData = extern struct {
    style: UnderlineStyle,
    color_src: ColorSource,
    color: u32,
};

pub const RowRangeData = extern union {
    uri: UriRangeData,
    underline: UnderlineRangeData,
};

pub const RowRange = extern struct {
    start: c_int,
    end: c_int,
    data: RowRangeData,
};

pub const RowRangeType = enum(c_int) {
    uri,
    underline,
};

pub const RowRanges = extern struct {
    v: ?[*]RowRange,
    size: c_int,
    count: c_int,
};

test "range types layout" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(UnderlineRangeData));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RowRangeData));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(RowRange));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RowRanges));
}

pub const RowData = extern struct {
    uri_ranges: RowRanges,
    underline_ranges: RowRanges,
};

pub const Row = extern struct {
    cells: ?[*]Cell,
    extra: ?*RowData,
    dirty: bool,
    linebreak: bool,
    shell_integration: extern struct {
        prompt_marker: bool,
        cmd_start: c_int,
        cmd_end: c_int,
    },
};

test "row layout" {
    try @import("std").testing.expectEqual(@as(usize, 32), @sizeOf(Row));
}

pub const KittyKbdFlags = enum(c_int) {
    disambiguate = 0x01,
    report_event = 0x02,
    report_alternate = 0x04,
    report_all = 0x08,
    report_associated = 0x10,
    supported = 0x1f,
};

pub const Grid = extern struct {
    num_rows: c_int,
    num_cols: c_int,
    offset: c_int,
    view: c_int,
    cursor: Cursor,
    saved_cursor: Cursor,
    saved_attrs: Attributes,
    rows: ?[*]?*Row,
    cur_row: ?*Row,
    scroll_damage: DamageList,
    sixel_images: SixelList,
    kitty_kbd_flags: [8]KittyKbdFlags,
    kitty_kbd_idx: u8,
};

test "grid basic layout" {
    try @import("std").testing.expectEqual(@as(usize, 4), @sizeOf(KittyKbdFlags));
}

test "cell and attributes layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Attributes));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RowData));
}

pub const DamageNode = extern struct {
    item: Damage,
    prev: ?*DamageNode,
    next: ?*DamageNode,
};

pub const DamageList = extern struct {
    head: ?*DamageNode,
    tail: ?*DamageNode,
    length: usize,
};

pub const Sixel = extern struct {
    pix: ?*anyopaque,
    width: c_int,
    height: c_int,
    rows: c_int,
    cols: c_int,
    pos: Coord,
    @"opaque": bool,
    cell_width: c_int,
    cell_height: c_int,
    original: extern struct {
        data: ?*anyopaque,
        pix: ?*anyopaque,
        width: c_int,
        height: c_int,
    },
    scaled: extern struct {
        data: ?*anyopaque,
        pix: ?*anyopaque,
        width: c_int,
        height: c_int,
    },
};

pub const SixelNode = extern struct {
    item: Sixel,
    prev: ?*SixelNode,
    next: ?*SixelNode,
};

pub const SixelList = extern struct {
    head: ?*SixelNode,
    tail: ?*SixelNode,
    length: usize,
};

test "layout matches C probe (probe_layout.c)" {
    const t = std.testing;

    try t.expectEqual(@as(usize, 152), @sizeOf(Grid));
    try t.expectEqual(@as(usize, 40), @offsetOf(Grid, "saved_attrs"));
    try t.expectEqual(@as(usize, 48), @offsetOf(Grid, "rows"));
    try t.expectEqual(@as(usize, 64), @offsetOf(Grid, "scroll_damage"));
    try t.expectEqual(@as(usize, 88), @offsetOf(Grid, "sixel_images"));
    try t.expectEqual(@as(usize, 112), @offsetOf(Grid, "kitty_kbd_flags"));

    try t.expectEqual(@as(usize, 32), @sizeOf(Row));
    try t.expectEqual(@as(usize, 8), @offsetOf(Row, "extra"));
    try t.expectEqual(@as(usize, 20), @offsetOf(Row, "shell_integration"));

    try t.expectEqual(@as(usize, 12), @sizeOf(Cell));

    try t.expectEqual(@as(usize, 96), @sizeOf(Sixel));
    try t.expectEqual(@as(usize, 32), @offsetOf(Sixel, "opaque"));
    try t.expectEqual(@as(usize, 48), @offsetOf(Sixel, "original"));
    try t.expectEqual(@as(usize, 72), @offsetOf(Sixel, "scaled"));

    try t.expectEqual(@as(usize, 24), @sizeOf(RowRange));
    try t.expectEqual(@as(usize, 8), @offsetOf(RowRange, "data"));

    try t.expectEqual(@as(usize, 16), @sizeOf(Damage));
    try t.expectEqual(@as(usize, 32), @sizeOf(DamageNode));
}
