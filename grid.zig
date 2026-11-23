const types = @import("terminal_types.zig");
const std = @import("std");

pub const Grid = types.Grid;

export fn rowAbsToSb(grid: *const Grid, screen_rows: c_int, abs_row: c_int) c_int {
    const scrollback_start = grid.offset + screen_rows;
    var rebased_row = abs_row - scrollback_start + grid.num_rows;

    rebased_row &= grid.num_rows - 1;
    return rebased_row;
}

export fn rowSbToAbs(grid: *const Grid, screen_rows: c_int, sb_rel_row: c_int) c_int {
    const scrollback_start = grid.offset + screen_rows;
    var abs_row = sb_rel_row + scrollback_start;

    abs_row &= grid.num_rows - 1;
    return abs_row;
}

export fn sbStartIgnoreUninitialized(grid: *const Grid, screen_rows: c_int) c_int {
    var scrollback_start = grid.offset + screen_rows;
    scrollback_start &= grid.num_rows - 1;

    while (grid.rows.?[@intCast(scrollback_start)] == null) {
        scrollback_start += 1;
        scrollback_start &= grid.num_rows - 1;
    }

    return scrollback_start;
}

export fn rowAbsToSbPrecalcSbStart(
    grid: *const Grid,
    sb_start: c_int,
    abs_row: c_int,
) c_int {
    var rebased_row = abs_row - sb_start + grid.num_rows;
    rebased_row &= grid.num_rows - 1;
    return rebased_row;
}

export fn rowSbToAbsPrecalcSbStart(
    grid: *const Grid,
    sb_start: c_int,
    sb_rel_row: c_int,
) c_int {
    var abs_row = sb_rel_row + sb_start;
    abs_row &= grid.num_rows - 1;
    return abs_row;
}

test "grid coordinate conversions" {
    var grid: Grid = undefined;
    grid.num_rows = 8;
    grid.offset = 6;
    grid.view = 0;

    try @import("std").testing.expectEqual(@as(c_int, 3), rowAbsToSb(&grid, 2, 3));
    try @import("std").testing.expectEqual(@as(c_int, 3), rowSbToAbs(&grid, 2, 3));

    try @import("std").testing.expectEqual(@as(c_int, 7), rowAbsToSbPrecalcSbStart(&grid, 4, 3));
    try @import("std").testing.expectEqual(@as(c_int, 7), rowSbToAbsPrecalcSbStart(&grid, 4, 3));
}

export fn rowAbsolute(grid: *const Grid, row_no: c_int) c_int {
    return (grid.offset + row_no) & (grid.num_rows - 1);
}

export fn rowAbsoluteInView(grid: *const Grid, row_no: c_int) c_int {
    return (grid.view + row_no) & (grid.num_rows - 1);
}

export fn rowAlloc(cols: c_int, initialize: bool) *types.Row {
    const allocator = std.heap.c_allocator;
    const r = allocator.create(types.Row) catch @panic("out of memory");

    r.* = .{
        .cells = null,
        .extra = null,
        .dirty = false,
        .linebreak = true,
        .shell_integration = .{
            .prompt_marker = false,
            .cmd_start = -1,
            .cmd_end = -1,
        },
    };

    if (initialize) {
        r.cells = (allocator.alloc(types.Cell, @intCast(cols)) catch @panic("out of memory")).ptr;
        for (r.cells.?[0..@intCast(cols)]) |*cell| {
            cell.* = .{
                .wc = 0,
                .attrs = @bitCast(@as(u64, 0)),
            };
            cell.attrs.clean = true;
        }
    } else {
        r.cells = (allocator.alloc(types.Cell, @intCast(cols)) catch @panic("out of memory")).ptr;
    }

    return r;
}

export fn rowFree(maybe_row: ?*types.Row) void {
    const r = maybe_row orelse return;
    const allocator = std.heap.c_allocator;

    rowResetExtra(r);

    if (r.cells) |cells|
        std.c.free(cells);

    allocator.destroy(r);
}

pub export fn row(grid: *types.Grid, row_no: c_int) *types.Row {
    const real_row = rowAbsolute(grid, row_no);
    return grid.rows.?[@intCast(real_row)].?;
}

export fn rowAndAlloc(grid: *types.Grid, row_no: c_int) *types.Row {
    const real_row = rowAbsolute(grid, row_no);

    if (grid.rows.?[@intCast(real_row)] == null)
        grid.rows.?[@intCast(real_row)] = rowAlloc(grid.num_cols, false);

    return grid.rows.?[@intCast(real_row)].?;
}

pub export fn rowInView(grid: *types.Grid, row_no: c_int) *types.Row {
    const real_row = rowAbsoluteInView(grid, row_no);
    return grid.rows.?[@intCast(real_row)].?;
}

test "row allocation" {
    const r = rowAlloc(4, true);
    defer rowFree(r);

    try @import("std").testing.expectEqual(@as(c_int, -1), r.shell_integration.cmd_start);
    try @import("std").testing.expectEqual(@as(c_int, -1), r.shell_integration.cmd_end);
    try @import("std").testing.expect(r.linebreak);
    try @import("std").testing.expect(!r.dirty);

    for (r.cells.?[0..4]) |cell|
        try @import("std").testing.expect(cell.attrs.clean);
}

fn rangeEnsureSize(ranges: *types.RowRanges, count_to_add: c_int) void {
    if (ranges.count + count_to_add > ranges.size) {
        const old_size: usize = @intCast(ranges.size);
        ranges.size = ranges.count + count_to_add;
        const new_size: usize = @intCast(ranges.size);

        const allocator = std.heap.c_allocator;
        const new_mem = if (ranges.v) |p|
            allocator.realloc(p[0..old_size], new_size) catch @panic("out of memory")
        else
            allocator.alloc(types.RowRange, new_size) catch @panic("out of memory");

        ranges.v = new_mem.ptr;
    }
}

fn rangeInsert(
    ranges: *types.RowRanges,
    idx: usize,
    start: c_int,
    end: c_int,
    range_type: types.RowRangeType,
    data: *const types.RowRangeData,
) void {
    rangeEnsureSize(ranges, 1);

    const count = @as(usize, @intCast(ranges.count));
    std.debug.assert(idx <= count);

    if (idx < count) {
        const ptr = ranges.v.?;
        std.mem.copyBackwards(
            types.RowRange,
            ptr[idx + 1 .. count + 1],
            ptr[idx..count],
        );
    }

    ranges.count += 1;

    const r = &ranges.v.?[idx];
    r.start = start;
    r.end = end;

    switch (range_type) {
        .uri => {
            r.data.uri.id = data.uri.id;
            r.data.uri.uri = if (data.uri.uri) |uri|
                strdup(uri)
            else
                null;
        },
        .underline => {
            r.data.underline = data.underline;
        },
    }
}

fn rangeAppendByRef(
    ranges: *types.RowRanges,
    start: c_int,
    end: c_int,
    range_type: types.RowRangeType,
    data: *const types.RowRangeData,
) void {
    rangeEnsureSize(ranges, 1);

    const idx: usize = @intCast(ranges.count);
    ranges.count += 1;

    const r = &ranges.v.?[idx];
    r.start = start;
    r.end = end;

    switch (range_type) {
        .uri => {
            r.data.uri.id = data.uri.id;
            r.data.uri.uri = data.uri.uri;
        },
        .underline => {
            r.data.underline = data.underline;
        },
    }
}

fn rangeAppend(
    ranges: *types.RowRanges,
    start: c_int,
    end: c_int,
    range_type: types.RowRangeType,
    data: *const types.RowRangeData,
) void {
    switch (range_type) {
        .uri => {
            var copied: types.RowRangeData = undefined;
            copied.uri.id = data.uri.id;
            copied.uri.uri = if (data.uri.uri) |uri|
                strdup(uri)
            else
                null;
            rangeAppendByRef(ranges, start, end, range_type, &copied);
        },
        .underline => {
            rangeAppendByRef(ranges, start, end, range_type, data);
        },
    }
}

fn rangeDelete(
    ranges: *types.RowRanges,
    range_type: types.RowRangeType,
    idx: usize,
) void {
    std.debug.assert(idx < @as(usize, @intCast(ranges.count)));

    const r = &ranges.v.?[idx];

    if (range_type == .uri) {
        if (r.data.uri.uri) |uri|
            std.c.free(uri);
    }

    const count: usize = @intCast(ranges.count);
    if (idx + 1 < count) {
        std.mem.copyForwards(
            types.RowRange,
            ranges.v.?[idx .. count - 1],
            ranges.v.?[idx + 1 .. count],
        );
    }

    ranges.count -= 1;
}

fn rangesMatch(
    r1: *const types.RowRange,
    r2: *const types.RowRange,
    range_type: types.RowRangeType,
) bool {
    switch (range_type) {
        .uri => return r1.data.uri.id == r2.data.uri.id,
        .underline => return r1.data.underline.style == r2.data.underline.style and
            r1.data.underline.color_src == r2.data.underline.color_src and
            r1.data.underline.color == r2.data.underline.color,
    }
}

fn rangeMatchData(
    r: *const types.RowRange,
    data: *const types.RowRangeData,
    range_type: types.RowRangeType,
) bool {
    switch (range_type) {
        .uri => return r.data.uri.id == data.uri.id,
        .underline => return r.data.underline.style == data.underline.style and
            r.data.underline.color_src == data.underline.color_src and
            r.data.underline.color == data.underline.color,
    }
}

fn gridRowRangePut(
    ranges: *types.RowRanges,
    col: c_int,
    data: *const types.RowRangeData,
    range_type: types.RowRangeType,
) void {
    var insert_idx: usize = 0;
    var replace = false;
    var run_merge_pass = false;

    var i: c_int = ranges.count - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        const r = &ranges.v.?[idx];
        const matching = rangeMatchData(r, data, range_type);

        if (matching and r.end + 1 == col) {
            r.end += 1;
            return;
        } else if (r.end < col) {
            insert_idx = idx + 1;
            break;
        } else if (r.start > col) {
            continue;
        } else {
            std.debug.assert(r.start <= col);
            std.debug.assert(r.end >= col);

            if (matching) {
                return;
            }

            if (r.start == r.end) {
                replace = true;
                run_merge_pass = true;
                insert_idx = idx;
            } else if (r.start == col) {
                run_merge_pass = true;
                r.start += 1;
                insert_idx = idx;
            } else if (r.end == col) {
                run_merge_pass = true;
                r.end -= 1;
                insert_idx = idx + 1;
            } else {
                std.debug.assert(r.start < col);
                std.debug.assert(r.end > col);

                var insert_data: types.RowRangeData = undefined;
                switch (range_type) {
                    .uri => insert_data.uri = r.data.uri,
                    .underline => insert_data.underline = r.data.underline,
                }

                rangeInsert(
                    ranges,
                    idx + 1,
                    col + 1,
                    r.end,
                    range_type,
                    &insert_data,
                );

                const old = &ranges.v.?[idx];
                old.end = col - 1;
                std.debug.assert(old.start <= old.end);

                insert_idx = idx + 1;
            }

            break;
        }
    }

    std.debug.assert(insert_idx <= @as(usize, @intCast(ranges.count)));

    if (replace) {
        rangeDelete(ranges, range_type, insert_idx);

        var new_range: types.RowRange = undefined;
        new_range.start = col;
        new_range.end = col;

        switch (range_type) {
            .uri => {
                new_range.data.uri.id = data.uri.id;
                new_range.data.uri.uri = if (data.uri.uri) |uri|
                    strdup(uri)
                else
                    null;
            },
            .underline => {
                new_range.data.underline = data.underline;
            },
        }

        rangeEnsureSize(ranges, 1);
        const count: usize = @intCast(ranges.count);

        if (insert_idx < count) {
            std.mem.copyBackwards(
                types.RowRange,
                ranges.v.?[insert_idx + 1 .. count + 1],
                ranges.v.?[insert_idx..count],
            );
        }

        ranges.v.?[insert_idx] = new_range;
        ranges.count += 1;
    } else {
        rangeInsert(ranges, insert_idx, col, col, range_type, data);
    }

    if (run_merge_pass) {
        var merge_idx: usize = 1;
        while (merge_idx < @as(usize, @intCast(ranges.count))) {
            const r1 = &ranges.v.?[merge_idx - 1];
            const r2 = &ranges.v.?[merge_idx];

            if (rangesMatch(r1, r2, range_type) and r1.end + 1 == r2.start) {
                r1.end = r2.end;
                rangeDelete(ranges, range_type, merge_idx);
                continue;
            }

            merge_idx += 1;
        }
    }
}

fn ensureRowHasExtraData(r: *types.Row) void {
    if (r.extra == null) {
        const allocator = std.heap.c_allocator;
        const extra = allocator.create(types.RowData) catch @panic("out of memory");
        extra.* = .{
            .uri_ranges = .{
                .v = null,
                .size = 0,
                .count = 0,
            },
            .underline_ranges = .{
                .v = null,
                .size = 0,
                .count = 0,
            },
        };
        r.extra = extra;
    }
}

export fn rowUriRangePut(
    r: *types.Row,
    col: c_int,
    uri: ?[*:0]const u8,
    id: u64,
) void {
    ensureRowHasExtraData(r);

    var data: types.RowRangeData = undefined;
    data.uri = .{
        .id = id,
        .uri = @constCast(uri),
    };

    gridRowRangePut(
        &r.extra.?.uri_ranges,
        col,
        &data,
        .uri,
    );
}

export fn rowUnderlineRangePut(
    r: *types.Row,
    col: c_int,
    data: types.UnderlineRangeData,
) void {
    ensureRowHasExtraData(r);

    var range_data: types.RowRangeData = undefined;
    range_data.underline = data;

    gridRowRangePut(
        &r.extra.?.underline_ranges,
        col,
        &range_data,
        .underline,
    );
}

fn gridRowRangeErase(
    ranges: *types.RowRanges,
    range_type: types.RowRangeType,
    start: c_int,
    end: c_int,
) void {
    std.debug.assert(start <= end);

    var i: c_int = ranges.count - 1;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        const old = &ranges.v.?[idx];

        if (old.end < start)
            return;

        if (old.start > end)
            continue;

        if (start <= old.start and end >= old.end) {
            rangeDelete(ranges, range_type, idx);
        } else if (start > old.start and end < old.end) {
            var data: types.RowRangeData = undefined;
            switch (range_type) {
                .uri => data.uri = old.data.uri,
                .underline => data.underline = old.data.underline,
            }

            rangeInsert(
                ranges,
                idx + 1,
                end + 1,
                old.end,
                range_type,
                &data,
            );

            const current = &ranges.v.?[idx];
            current.end = start - 1;
            return;
        } else if (start <= old.start and end >= old.start) {
            std.debug.assert(start <= old.start);
            old.start = end + 1;
        } else if (start <= old.end and end >= old.end) {
            std.debug.assert(end >= old.end);
            old.end = start - 1;
            return;
        }
    }
}

export fn rowUriRangeErase(
    r: *types.Row,
    start: c_int,
    end: c_int,
) void {
    std.debug.assert(r.extra != null);
    gridRowRangeErase(
        &r.extra.?.uri_ranges,
        .uri,
        start,
        end,
    );
}

export fn rowUnderlineRangeErase(
    r: *types.Row,
    start: c_int,
    end: c_int,
) void {
    std.debug.assert(r.extra != null);
    gridRowRangeErase(
        &r.extra.?.underline_ranges,
        .underline,
        start,
        end,
    );
}

fn rowRangeDestroy(
    range: *types.RowRange,
    range_type: types.RowRangeType,
) void {
    switch (range_type) {
        .uri => {
            if (range.data.uri.uri) |uri|
                std.c.free(uri);
        },
        .underline => {},
    }
}

fn rowRangesDestroy(
    ranges: *types.RowRanges,
    range_type: types.RowRangeType,
) void {
    var i: c_int = 0;
    while (i < ranges.count) : (i += 1) {
        rowRangeDestroy(&ranges.v.?[@intCast(i)], range_type);
    }
}

fn rowResetExtra(r: *types.Row) void {
    const extra = r.extra orelse return;

    rowRangesDestroy(&extra.uri_ranges, .uri);
    rowRangesDestroy(&extra.underline_ranges, .underline);

    if (extra.uri_ranges.v) |v|
        std.c.free(v);
    if (extra.underline_ranges.v) |v|
        std.c.free(v);

    std.heap.c_allocator.destroy(extra);
    r.extra = null;
}

extern fn strdup(s: [*:0]const u8) ?[*:0]u8;
extern fn sixel_destroy(sixel: *types.Sixel) void;

fn tllFreeNodes(list: anytype) void {
    var it = list.head;
    while (it) |node| {
        const next = node.next;
        std.c.free(node);
        it = next;
    }
    list.head = null;
    list.tail = null;
    list.length = 0;
}

export fn gridFree(maybe_grid: ?*types.Grid) void {
    const grid = maybe_grid orelse return;

    if (grid.rows) |rows| {
        var r: usize = 0;
        while (r < @as(usize, @intCast(grid.num_rows))) : (r += 1)
            rowFree(rows[r]);
    }

    var it = grid.sixel_images.head;
    while (it) |node| {
        sixel_destroy(&node.item);
        it = node.next;
    }
    tllFreeNodes(&grid.sixel_images);

    if (grid.rows) |rows|
        std.c.free(@ptrCast(rows));

    tllFreeNodes(&grid.scroll_damage);
}

export fn swapRow(grid: *types.Grid, row_a: c_int, row_b: c_int) void {
    std.debug.assert(grid.offset >= 0);
    std.debug.assert(row_a != row_b);

    const mask = grid.num_rows - 1;
    const real_a: usize = @intCast((grid.offset + row_a) & mask);
    const real_b: usize = @intCast((grid.offset + row_b) & mask);

    const rows = grid.rows.?;
    const tmp = rows[real_a];
    rows[real_a] = rows[real_b];
    rows[real_b] = tmp;
}

extern fn pixman_image_get_format(image: ?*anyopaque) c_uint;
extern fn pixman_image_create_bits_no_clear(
    format: c_uint,
    width: c_int,
    height: c_int,
    bits: ?*anyopaque,
    rowstride_bytes: c_int,
) ?*anyopaque;

fn xmalloc(size: usize) *anyopaque {
    return std.c.malloc(size) orelse @panic("out of memory");
}

fn xcalloc(n: usize, size: usize) *anyopaque {
    return std.c.calloc(@max(n, 1), size) orelse @panic("out of memory");
}

fn xmemdup(src: *const anyopaque, size: usize) *anyopaque {
    const dst = xmalloc(size);
    const d: [*]u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    @memcpy(d[0..size], s[0..size]);
    return dst;
}

/// Mirrors stride.h: verify against the real header.
fn strideForFormatAndWidth(format: c_uint, width: c_int) c_int {
    const bpp: c_int = @intCast((format >> 24) & 0xff);
    return 4 * @divTrunc(width * bpp + 31, 32);
}

fn tllPushBack(comptime Node: type, list: anytype, item: anytype) void {
    const node: *Node = @ptrCast(@alignCast(xmalloc(@sizeOf(Node))));
    node.* = .{ .item = item, .prev = list.tail, .next = null };
    if (list.tail) |t| t.next = node else list.head = node;
    list.tail = node;
    list.length += 1;
}

export fn gridSnapshot(grid: *const types.Grid) *types.Grid {
    const clone: *types.Grid = @ptrCast(@alignCast(xmalloc(@sizeOf(types.Grid))));
    clone.* = grid.*;

    const num_rows: usize = @intCast(grid.num_rows);
    const num_cols: usize = @intCast(grid.num_cols);

    const new_rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(num_rows, @sizeOf(?*types.Row))));
    clone.rows = new_rows;
    clone.cur_row = null;
    clone.scroll_damage = .{ .head = null, .tail = null, .length = 0 };
    clone.sixel_images = .{ .head = null, .tail = null, .length = 0 };

    var dmg = grid.scroll_damage.head;
    while (dmg) |n| : (dmg = n.next)
        tllPushBack(types.DamageNode, &clone.scroll_damage, n.item);

    if (grid.rows) |src_rows| {
        var r: usize = 0;
        while (r < num_rows) : (r += 1) {
            const src = src_rows[r] orelse continue;
            const cr: *types.Row = @ptrCast(@alignCast(xmalloc(@sizeOf(types.Row))));
            new_rows[r] = cr;

            cr.* = src.*;
            const cells: [*]types.Cell = @ptrCast(@alignCast(xmalloc(num_cols * @sizeOf(types.Cell))));
            @memcpy(cells[0..num_cols], src.cells.?[0..num_cols]);
            cr.cells = cells;
            cr.extra = null;

            const extra = src.extra orelse continue;
            const ce: *types.RowData = @ptrCast(@alignCast(xcalloc(1, @sizeOf(types.RowData))));
            cr.extra = ce;

            rangeEnsureSize(&ce.uri_ranges, extra.uri_ranges.count);
            rangeEnsureSize(&ce.underline_ranges, extra.underline_ranges.count);

            var i: usize = 0;
            while (i < @as(usize, @intCast(extra.uri_ranges.count))) : (i += 1) {
                const range = &extra.uri_ranges.v.?[i];
                rangeAppend(&ce.uri_ranges, range.start, range.end, .uri, &range.data);
            }
            i = 0;
            while (i < @as(usize, @intCast(extra.underline_ranges.count))) : (i += 1) {
                const range = &extra.underline_ranges.v.?[i];
                rangeAppendByRef(&ce.underline_ranges, range.start, range.end, .underline, &range.data);
            }
        }
    }

    var sn = grid.sixel_images.head;
    while (sn) |n| : (sn = n.next) {
        const item = &n.item;

        const ow = item.original.width;
        const oh = item.original.height;
        const ofmt = pixman_image_get_format(item.original.pix);
        const ostride = strideForFormatAndWidth(ofmt, ow);
        const osize: usize = @intCast(ostride * oh);
        const new_odata = xmemdup(item.original.data.?, osize);
        const new_opix = pixman_image_create_bits_no_clear(ofmt, ow, oh, new_odata, ostride);

        var new_sdata: ?*anyopaque = null;
        var new_spix: ?*anyopaque = null;
        var sw: c_int = -1;
        var sh: c_int = -1;
        if (item.scaled.data) |sdata| {
            sw = item.scaled.width;
            sh = item.scaled.height;
            const sfmt = pixman_image_get_format(item.scaled.pix);
            const sstride = strideForFormatAndWidth(sfmt, sw);
            const ssize: usize = @intCast(sstride * sh);
            new_sdata = xmemdup(sdata, ssize);
            new_spix = pixman_image_create_bits_no_clear(sfmt, sw, sh, new_sdata, sstride);
        }

        const six: types.Sixel = .{
            .pix = if (item.pix == item.original.pix)
                new_opix
            else if (item.pix == item.scaled.pix)
                new_spix
            else
                null,
            .width = item.width,
            .height = item.height,
            .rows = item.rows,
            .cols = item.cols,
            .pos = item.pos,
            .@"opaque" = item.@"opaque",
            .cell_width = item.cell_width,
            .cell_height = item.cell_height,
            .original = .{ .data = new_odata, .pix = new_opix, .width = ow, .height = oh },
            .scaled = .{ .data = new_sdata, .pix = new_spix, .width = sw, .height = sh },
        };
        tllPushBack(types.SixelNode, &clone.sixel_images, six);
    }

    return clone;
}

test "swapRow swaps pointers" {
    var g = std.mem.zeroes(types.Grid);
    var slots = [_]?*types.Row{ @ptrFromInt(0x10), @ptrFromInt(0x20), @ptrFromInt(0x30), @ptrFromInt(0x40) };
    g.num_rows = 4;
    g.offset = 1;
    g.rows = &slots;
    swapRow(&g, 0, 2);
    try std.testing.expectEqual(@as(usize, 0x10), @intFromPtr(slots[0]));
    try std.testing.expectEqual(@as(usize, 0x40), @intFromPtr(slots[1]));
    try std.testing.expectEqual(@as(usize, 0x30), @intFromPtr(slots[2]));
    try std.testing.expectEqual(@as(usize, 0x20), @intFromPtr(slots[3]));
}

test "snapshot of grid with null rows" {
    var g = std.mem.zeroes(types.Grid);
    var slots = [_]?*types.Row{ null, null };
    g.num_rows = 2;
    g.num_cols = 3;
    g.offset = 1;
    g.view = 1;
    g.rows = &slots;

    const c = gridSnapshot(&g);
    defer {
        std.c.free(@ptrCast(c.rows.?));
        std.c.free(c);
    }
    try std.testing.expectEqual(@as(c_int, 2), c.num_rows);
    try std.testing.expectEqual(@as(c_int, 1), c.offset);
    try std.testing.expect(c.rows.? != g.rows.?);
    try std.testing.expect(c.rows.?[0] == null and c.rows.?[1] == null);
    try std.testing.expect(c.sixel_images.head == null);
}

test "snapshot of grid with a row and a uri range" {
    var g = std.mem.zeroes(types.Grid);
    var slots = [_]?*types.Row{ rowAlloc(4, true), null };
    defer rowFree(slots[0]);
    g.num_rows = 2;
    g.num_cols = 4;
    g.rows = &slots;

    const put_uri = strdup("file:///tmp/x").?;
    defer std.c.free(put_uri);
    rowUriRangePut(slots[0].?, 1, put_uri, 42);

    const c = gridSnapshot(&g);
    defer {
        rowFree(c.rows.?[0]);
        std.c.free(@ptrCast(c.rows.?));
        std.c.free(c);
    }

    const src = slots[0].?;
    const dst = c.rows.?[0].?;

    try std.testing.expect(dst != src);
    try std.testing.expect(dst.cells.? != src.cells.?);
    try std.testing.expect(c.rows.?[1] == null);

    const src_extra = src.extra.?;
    const dst_extra = dst.extra.?;
    try std.testing.expect(dst_extra != src_extra);
    try std.testing.expectEqual(src_extra.uri_ranges.count, dst_extra.uri_ranges.count);
    try std.testing.expectEqual(@as(c_int, 1), dst_extra.uri_ranges.count);

    const sr = src_extra.uri_ranges.v.?[0];
    const dr = dst_extra.uri_ranges.v.?[0];
    try std.testing.expectEqual(sr.start, dr.start);
    try std.testing.expectEqual(sr.end, dr.end);
    try std.testing.expectEqual(sr.data.uri.id, dr.data.uri.id);
    try std.testing.expect(dr.data.uri.uri.? != sr.data.uri.uri.?);
    try std.testing.expectEqualStrings(
        std.mem.span(sr.data.uri.uri.?),
        std.mem.span(dr.data.uri.uri.?),
    );
}

const builtin = @import("builtin");

const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

fn sixelDestroyStub(sixel: *types.Sixel) callconv(.c) void {
    _ = sixel;
}

comptime {
    if (builtin.is_test)
        @export(&sixelDestroyStub, .{ .name = "sixel_destroy" });
}

fn tllUnlink(list: anytype, node: anytype) void {
    if (node.prev) |p| p.next = node.next else list.head = node.next;
    if (node.next) |n| n.prev = node.prev else list.tail = node.prev;
    node.prev = null;
    node.next = null;
    list.length -= 1;
}

fn tllAppendNode(list: anytype, node: anytype) void {
    node.prev = list.tail;
    node.next = null;
    if (list.tail) |t| t.next = node else list.head = node;
    list.tail = node;
    list.length += 1;
}

export fn gridResizeWithoutReflow(
    grid: *types.Grid,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
) void {
    const old_grid_opt = grid.rows;
    const old_rows = grid.num_rows;
    const old_cols = grid.num_cols;
    const new_rows_u: usize = @intCast(new_rows);
    const new_cols_u: usize = @intCast(new_cols);

    const new_grid: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(new_rows_u, @sizeOf(?*types.Row))));

    // Move all sixels to a temporary list; they are moved back (or destroyed) below.
    var untranslated = grid.sixel_images;
    grid.sixel_images = .{ .head = null, .tail = null, .length = 0 };

    const new_offset: c_int = 0;
    const common_rows = @min(old_screen_rows, new_screen_rows);

    var r: c_int = 0;
    while (r < common_rows) : (r += 1) {
        const old_row_idx: usize = @intCast((grid.offset + r) & (old_rows - 1));
        const new_row_idx: usize = @intCast((new_offset + r) & (new_rows - 1));

        const old_row = old_grid_opt.?[old_row_idx].?;
        const new_row = rowAlloc(new_cols, false);
        new_grid[new_row_idx] = new_row;

        const copy_cols: usize = @intCast(@min(old_cols, new_cols));
        @memcpy(new_row.cells.?[0..copy_cols], old_row.cells.?[0..copy_cols]);

        new_row.dirty = old_row.dirty;
        new_row.shell_integration.prompt_marker = old_row.shell_integration.prompt_marker;
        new_row.shell_integration.cmd_start = @min(old_row.shell_integration.cmd_start, new_cols - 1);
        new_row.shell_integration.cmd_end = @min(old_row.shell_integration.cmd_end, new_cols - 1);

        if (new_cols > old_cols) {
            const from: usize = @intCast(old_cols);
            @memset(new_row.cells.?[from..new_cols_u], std.mem.zeroes(types.Cell));
            new_row.dirty = true;
        } else if (old_cols > new_cols) {
            // Don't leave half of a wide character at the new right edge.
            var i: usize = new_cols_u;
            while (i > 0 and old_row.cells.?[i].wc > CELL_SPACER) : (i -= 1)
                new_row.cells.?[i - 1].wc = 0;
        }

        var sn = untranslated.head;
        while (sn) |node| {
            sn = node.next;
            if (node.item.pos.row != @as(c_int, @intCast(old_row_idx)))
                continue;

            tllUnlink(&untranslated, node);
            node.item.pos.row = @intCast(new_row_idx);
            if (node.item.pos.col < new_cols) {
                tllAppendNode(&grid.sixel_images, node);
            } else {
                sixel_destroy(&node.item);
                std.c.free(node);
            }
        }

        const old_extra = old_row.extra orelse continue;
        ensureRowHasExtraData(new_row);
        const new_extra = new_row.extra.?;

        rangeEnsureSize(&new_extra.uri_ranges, old_extra.uri_ranges.count);
        rangeEnsureSize(&new_extra.underline_ranges, old_extra.underline_ranges.count);

        var i: usize = 0;
        while (i < @as(usize, @intCast(old_extra.uri_ranges.count))) : (i += 1) {
            const range = &old_extra.uri_ranges.v.?[i];
            if (range.start >= new_cols) continue;
            rangeAppend(&new_extra.uri_ranges, range.start, @min(range.end, new_cols - 1), .uri, &range.data);
        }
        i = 0;
        while (i < @as(usize, @intCast(old_extra.underline_ranges.count))) : (i += 1) {
            const range = &old_extra.underline_ranges.v.?[i];
            if (range.start >= new_cols) continue;
            rangeAppendByRef(&new_extra.underline_ranges, range.start, @min(range.end, new_cols - 1), .underline, &range.data);
        }
    }

    r = common_rows;
    while (r < new_screen_rows) : (r += 1) {
        const new_row = rowAlloc(new_cols, false);
        const idx: usize = @intCast((new_offset + r) & (new_rows - 1));
        new_grid[idx] = new_row;
        @memset(new_row.cells.?[0..new_cols_u], std.mem.zeroes(types.Cell));
        new_row.dirty = true;
    }

    var fr: usize = 0;
    while (fr < @as(usize, @intCast(grid.num_rows))) : (fr += 1)
        rowFree(old_grid_opt.?[fr]);
    std.c.free(@ptrCast(old_grid_opt));

    grid.rows = new_grid;
    grid.num_rows = new_rows;
    grid.num_cols = new_cols;
    grid.offset = new_offset;
    grid.view = new_offset;

    var cursor = grid.cursor.point;
    if (cursor.row == old_screen_rows - 1) cursor.row = new_screen_rows - 1;
    cursor.row = @min(cursor.row, new_screen_rows - 1);
    cursor.col = @min(cursor.col, new_cols - 1);
    grid.cursor.point = cursor;

    var saved = grid.saved_cursor.point;
    if (saved.row == old_screen_rows - 1) saved.row = new_screen_rows - 1;
    saved.row = @min(saved.row, new_screen_rows - 1);
    saved.col = @min(saved.col, new_cols - 1);
    grid.saved_cursor.point = saved;

    const cur_idx: usize = @intCast((grid.offset + cursor.row) & (new_rows - 1));
    grid.cur_row = new_grid[cur_idx];
    std.debug.assert(grid.cur_row != null);

    grid.cursor.lcf = false;
    grid.saved_cursor.lcf = false;

    // Sixels that were on rows beyond the new screen are dropped.
    var rest = untranslated.head;
    while (rest) |node| {
        const next = node.next;
        sixel_destroy(&node.item);
        std.c.free(node);
        rest = next;
    }
}

test "resize without reflow shrinks then grows columns" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rows[i] = rw;
    }
    rows[0].?.cells.?[0].wc = 0x41;
    rows[0].?.cells.?[1].wc = 0x42;

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 3, .row = 1 };
    g.cur_row = rows[1];

    gridResizeWithoutReflow(&g, 8, 2, 2, 3);
    try std.testing.expectEqual(@as(c_int, 8), g.num_rows);
    try std.testing.expectEqual(@as(c_int, 2), g.num_cols);
    try std.testing.expectEqual(@as(c_int, 1), g.cursor.point.col);
    try std.testing.expectEqual(@as(c_int, 2), g.cursor.point.row);
    try std.testing.expect(g.cur_row != null);
    try std.testing.expect(g.rows.?[0] != null and g.rows.?[1] != null and g.rows.?[2] != null);
    try std.testing.expect(g.rows.?[3] == null);
    try std.testing.expectEqual(@as(u32, 0x41), g.rows.?[0].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 0x42), g.rows.?[0].?.cells.?[1].wc);

    gridResizeWithoutReflow(&g, 8, 6, 3, 3);
    try std.testing.expectEqual(@as(c_int, 6), g.num_cols);
    try std.testing.expectEqual(@as(u32, 0x41), g.rows.?[0].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 0), g.rows.?[0].?.cells.?[5].wc);
    try std.testing.expect(g.rows.?[0].?.dirty);

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(g.rows.?[k]);
    std.c.free(@ptrCast(g.rows.?));
}

fn reflowRangeStart(
    range: *types.RowRange,
    range_type: types.RowRangeType,
    new_row: *types.Row,
    new_col_idx: c_int,
) void {
    ensureRowHasExtraData(new_row);
    const extra = new_row.extra.?;
    const new_ranges = switch (range_type) {
        .uri => &extra.uri_ranges,
        .underline => &extra.underline_ranges,
    };

    rangeAppendByRef(new_ranges, new_col_idx, -1, range_type, &range.data);

    switch (range_type) {
        .uri => range.data.uri.uri = null, // Owned by new_ranges
        .underline => {},
    }
}

fn reflowRangeEnd(
    range: *const types.RowRange,
    range_type: types.RowRangeType,
    new_row: *types.Row,
    new_col_idx: c_int,
) void {
    const extra = new_row.extra.?;
    const ranges = switch (range_type) {
        .uri => &extra.uri_ranges,
        .underline => &extra.underline_ranges,
    };

    std.debug.assert(ranges.count > 0);
    const new_range = &ranges.v.?[@intCast(ranges.count - 1)];
    std.debug.assert(new_range.end < 0);

    switch (range_type) {
        .uri => std.debug.assert(new_range.data.uri.id == range.data.uri.id),
        .underline => {
            std.debug.assert(new_range.data.underline.style == range.data.underline.style);
            std.debug.assert(new_range.data.underline.color_src == range.data.underline.color_src);
            std.debug.assert(new_range.data.underline.color == range.data.underline.color);
        },
    }

    new_range.end = new_col_idx;
}

fn lineWrap(
    old_grid: *types.Grid,
    new_grid: [*]?*types.Row,
    prev_row: *types.Row,
    row_idx: *c_int,
    col_idx: *c_int,
    row_count: c_int,
    col_count: c_int,
) *types.Row {
    col_idx.* = 0;
    row_idx.* = (row_idx.* + 1) & (row_count - 1);

    const idx: usize = @intCast(row_idx.*);
    var new_row: *types.Row = undefined;

    if (new_grid[idx]) |existing| {
        new_row = existing;
        rowResetExtra(new_row);
        new_row.shell_integration.prompt_marker = false;
        new_row.shell_integration.cmd_start = -1;
        new_row.shell_integration.cmd_end = -1;

        var sn = old_grid.sixel_images.head;
        while (sn) |node| {
            sn = node.next;
            if (node.item.pos.row == row_idx.*) {
                sixel_destroy(&node.item);
                tllUnlink(&old_grid.sixel_images, node);
                std.c.free(node);
            }
        }
    } else {
        new_row = rowAlloc(col_count, false);
        new_grid[idx] = new_row;
    }

    const extra = prev_row.extra orelse return new_row;

    if (extra.uri_ranges.count > 0) {
        const range = &extra.uri_ranges.v.?[@intCast(extra.uri_ranges.count - 1)];
        if (range.end < 0) {
            range.end = col_count - 1;
            ensureRowHasExtraData(new_row);
            rangeAppend(&new_row.extra.?.uri_ranges, 0, -1, .uri, &range.data);
        }
    }

    if (extra.underline_ranges.count > 0) {
        const range = &extra.underline_ranges.v.?[@intCast(extra.underline_ranges.count - 1)];
        if (range.end < 0) {
            range.end = col_count - 1;
            ensureRowHasExtraData(new_row);
            rangeAppend(&new_row.extra.?.underline_ranges, 0, -1, .underline, &range.data);
        }
    }

    return new_row;
}

var tp_cmp_ctx: struct {
    scrollback_start: c_int,
    rows: c_int,
} = .{ .scrollback_start = 0, .rows = 0 };

fn tpCmp(a_: ?*const anyopaque, b_: ?*const anyopaque) callconv(.c) c_int {
    const a = @as(*const *const types.Coord, @ptrCast(@alignCast(a_.?))).*;
    const b = @as(*const *const types.Coord, @ptrCast(@alignCast(b_.?))).*;

    const sb = tp_cmp_ctx.scrollback_start;
    const n = tp_cmp_ctx.rows;

    const a_row = (a.row - sb + n) & (n - 1);
    const b_row = (b.row - sb + n) & (n - 1);
    std.debug.assert(a_row >= 0 and (a_row < n or n == 0));
    std.debug.assert(b_row >= 0 and (b_row < n or n == 0));

    if (a_row < b_row) return -1;
    if (a_row > b_row) return 1;
    if (a.col < b.col) return -1;
    if (a.col > b.col) return 1;
    return 0;
}

extern fn qsort(
    base: ?*anyopaque,
    nmemb: usize,
    size: usize,
    compar: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int,
) void;

test "reflow range start and end" {
    const new_row = rowAlloc(4, true);
    defer rowFree(new_row);

    var range: types.RowRange = .{ .start = 0, .end = 3, .data = std.mem.zeroes(types.RowRangeData) };
    range.data.uri = .{ .id = 9, .uri = strdup("x") };

    reflowRangeStart(&range, .uri, new_row, 1);
    try std.testing.expect(range.data.uri.uri == null);

    const ranges = &new_row.extra.?.uri_ranges;
    try std.testing.expectEqual(@as(c_int, 1), ranges.count);
    try std.testing.expectEqual(@as(c_int, 1), ranges.v.?[0].start);
    try std.testing.expectEqual(@as(c_int, -1), ranges.v.?[0].end);

    reflowRangeEnd(&range, .uri, new_row, 2);
    try std.testing.expectEqual(@as(c_int, 2), ranges.v.?[0].end);
}

test "lineWrap continues an open uri range on the new row" {
    var g = std.mem.zeroes(types.Grid);
    var slots = [_]?*types.Row{ null, null };

    const old_row = rowAlloc(4, true);
    defer rowFree(old_row);

    ensureRowHasExtraData(old_row);
    var data = std.mem.zeroes(types.RowRangeData);
    data.uri = .{ .id = 7, .uri = strdup("file:///a") };
    rangeAppendByRef(&old_row.extra.?.uri_ranges, 1, -1, .uri, &data);

    var row_idx: c_int = 0;
    var col_idx: c_int = 5;
    const new_row = lineWrap(&g, &slots, old_row, &row_idx, &col_idx, 2, 4);
    defer rowFree(new_row);

    try std.testing.expect(slots[1] == new_row);
    try std.testing.expectEqual(@as(c_int, 1), row_idx);
    try std.testing.expectEqual(@as(c_int, 0), col_idx);
    try std.testing.expectEqual(@as(c_int, 3), old_row.extra.?.uri_ranges.v.?[0].end);

    const nr = &new_row.extra.?.uri_ranges;
    try std.testing.expectEqual(@as(c_int, 1), nr.count);
    try std.testing.expectEqual(@as(c_int, 0), nr.v.?[0].start);
    try std.testing.expectEqual(@as(c_int, -1), nr.v.?[0].end);
    try std.testing.expectEqual(@as(u64, 7), nr.v.?[0].data.uri.id);
}

test "tpCmp orders by position relative to scrollback start" {
    const a = types.Coord{ .col = 0, .row = 0 };
    const b = types.Coord{ .col = 0, .row = 7 };
    const c = types.Coord{ .col = 2, .row = 7 };
    var arr = [_]*const types.Coord{ &a, &c, &b };

    tp_cmp_ctx = .{ .scrollback_start = 6, .rows = 8 };
    qsort(&arr, arr.len, @sizeOf(*const types.Coord), &tpCmp);

    try std.testing.expect(arr[0] == &b);
    try std.testing.expect(arr[1] == &c);
    try std.testing.expect(arr[2] == &a);
}

const Composed = @import("composed.zig").Composed;
const composed_ext = struct {
    extern fn composed_lookup(root: ?*Composed, key: u32) ?*Composed;
};
const composed_lookup = if (builtin.is_test)
    @import("composed.zig").composed_lookup
else
    composed_ext.composed_lookup;

fn zeroCells(r: *types.Row, from: c_int, to: c_int) void {
    if (to <= from) return;
    @memset(r.cells.?[@intCast(from)..@intCast(to)], std.mem.zeroes(types.Cell));
}

export fn gridResizeAndReflow(
    grid: *types.Grid,
    composed_root: ?*Composed,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
    tracking_points_count: usize,
    tracking_points_in: ?[*]const *types.Coord,
) void {
    const allocator = std.heap.c_allocator;

    const old_grid_opt = grid.rows;
    const old_rows = grid.num_rows;
    const old_cols = grid.num_cols;
    const view_follows = grid.view == grid.offset;

    var new_col_idx: c_int = 0;
    var new_row_idx: c_int = 0;

    const new_grid: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(@intCast(new_rows), @sizeOf(?*types.Row))));
    var new_row = rowAlloc(new_cols, false);
    new_grid[0] = new_row;

    const offset = grid.offset + old_screen_rows;

    var untranslated = grid.sixel_images;
    grid.sixel_images = .{ .head = null, .tail = null, .length = 0 };

    var cursor = grid.cursor.point;
    cursor.row += grid.offset;
    cursor.row &= old_rows - 1;

    var saved_cursor = grid.saved_cursor.point;
    saved_cursor.row += grid.offset;
    saved_cursor.row &= old_rows - 1;

    const tp_count = tracking_points_count + 2 + @as(usize, @intFromBool(!view_follows)) + 1;
    const tps = allocator.alloc(*types.Coord, tp_count) catch @panic("out of memory");
    defer allocator.free(tps);

    if (tracking_points_count > 0)
        @memcpy(tps[0..tracking_points_count], tracking_points_in.?[0..tracking_points_count]);
    tps[tracking_points_count] = &cursor;
    tps[tracking_points_count + 1] = &saved_cursor;

    var viewport: types.Coord = .{ .col = 0, .row = grid.view };
    if (!view_follows)
        tps[tracking_points_count + 2] = &viewport;

    tp_cmp_ctx.scrollback_start = offset;
    tp_cmp_ctx.rows = old_rows;
    qsort(@ptrCast(tps.ptr), tp_count - 1, @sizeOf(*types.Coord), &tpCmp);

    var terminator: types.Coord = .{ .col = -1, .row = -1 };
    tps[tp_count - 1] = &terminator;
    var next_tp: usize = 0;

    var coalesced_linebreaks: usize = 0;

    var r: c_int = 0;
    while (r < old_rows) : (r += 1) {
        const old_row_idx_i: c_int = (offset + r) & (old_rows - 1);
        const old_row_idx: usize = @intCast(old_row_idx_i);
        const old_row = old_grid_opt.?[old_row_idx] orelse continue;

        var sn = untranslated.head;
        while (sn) |node| {
            sn = node.next;
            if (node.item.pos.row != old_row_idx_i) continue;
            tllUnlink(&untranslated, node);
            node.item.pos.row = new_row_idx;
            tllAppendNode(&grid.sixel_images, node);
        }

        var col_count: c_int = 0;
        var scan: c_int = old_cols - 1;
        while (scan >= 0) : (scan -= 1) {
            const cell = &old_row.cells.?[@intCast(scan)];
            if (!(cell.wc == 0 or cell.wc == CELL_SPACER) or cell.attrs.bg_src != 0) {
                col_count = scan + 1;
                break;
            }
        }

        if (!old_row.linebreak and col_count > 0) {
            while (col_count < old_cols and old_row.cells.?[@intCast(col_count)].wc == 0)
                col_count += 1;
        }
        std.debug.assert(col_count >= 0 and col_count <= old_cols);

        var tp: ?*types.Coord = null;
        if (tps[next_tp].row == old_row_idx_i) {
            tp = tps[next_tp];
            var last_on_row = tps[next_tp];
            var it = next_tp;
            while (tps[it].row == old_row_idx_i) : (it += 1)
                last_on_row = tps[it];
            col_count = @max(col_count, last_on_row.col + 1);
        }

        var uri_idx: usize = 0;
        var uri_count: usize = 0;
        var ul_idx: usize = 0;
        var ul_count: usize = 0;
        if (old_row.extra) |e| {
            if (e.uri_ranges.count > 0) {
                uri_count = @intCast(e.uri_ranges.count);
                col_count = @max(col_count, e.uri_ranges.v.?[uri_count - 1].end + 1);
            }
            if (e.underline_ranges.count > 0) {
                ul_count = @intCast(e.underline_ranges.count);
                col_count = @max(col_count, e.underline_ranges.v.?[ul_count - 1].end + 1);
            }
        }

        if (col_count > 0 and coalesced_linebreaks > 0) {
            var ln: usize = 0;
            while (ln < coalesced_linebreaks) : (ln += 1) {
                zeroCells(new_row, new_col_idx, new_cols);
                new_row.linebreak = true;
                new_row = lineWrap(grid, new_grid, new_row, &new_row_idx, &new_col_idx, new_rows, new_cols);
            }
            coalesced_linebreaks = 0;
        }

        var c: c_int = 0;
        while (c < col_count) {
            const cells = old_row.cells.?;
            std.debug.assert(new_col_idx <= new_cols);
            if (new_col_idx >= new_cols)
                new_row = lineWrap(grid, new_grid, new_row, &new_row_idx, &new_col_idx, new_rows, new_cols);

            const wc = cells[@intCast(c)].wc;
            var width: c_int = 1;
            if (wc >= CELL_COMB_CHARS_LO and wc <= CELL_COMB_CHARS_HI) {
                const composed = composed_lookup(composed_root, wc - CELL_COMB_CHARS_LO).?;
                width = if (composed.forced_width > 0)
                    @as(c_int, composed.forced_width)
                else
                    @as(c_int, composed.width);
            } else if (c + 1 < col_count and cells[@intCast(c + 1)].wc >= CELL_SPACER + 1) {
                width = @intCast(cells[@intCast(c + 1)].wc - CELL_SPACER + 1);
            }

            // Wide character doesn't fit on this row: pad and move it to the next one.
            if (new_col_idx + width > new_cols and width <= new_cols) {
                while (new_col_idx < new_cols) : (new_col_idx += 1) {
                    const dst = &new_row.cells.?[@intCast(new_col_idx)];
                    dst.wc = CELL_SPACER;
                    dst.attrs = std.mem.zeroes(types.Attributes);
                }
                new_row = lineWrap(grid, new_grid, new_row, &new_row_idx, &new_col_idx, new_rows, new_cols);
            }

            new_row.shell_integration.prompt_marker = old_row.shell_integration.prompt_marker;

            var i: c_int = 0;
            while (i < width) : (i += 1) {
                if (uri_idx < uri_count) {
                    const range = &old_row.extra.?.uri_ranges.v.?[uri_idx];
                    if (range.start == c)
                        reflowRangeStart(range, .uri, new_row, new_col_idx);
                    if (range.end == c) {
                        reflowRangeEnd(range, .uri, new_row, new_col_idx);
                        rowRangeDestroy(range, .uri);
                        uri_idx += 1;
                    }
                }
                if (ul_idx < ul_count) {
                    const range = &old_row.extra.?.underline_ranges.v.?[ul_idx];
                    if (range.start == c)
                        reflowRangeStart(range, .underline, new_row, new_col_idx);
                    if (range.end == c) {
                        reflowRangeEnd(range, .underline, new_row, new_col_idx);
                        rowRangeDestroy(range, .underline);
                        ul_idx += 1;
                    }
                }

                if (tp) |t0| {
                    if (t0.col == c) {
                        var t = t0;
                        while (true) {
                            std.debug.assert(t.row == old_row_idx_i);
                            t.row = new_row_idx;
                            t.col = new_col_idx;
                            next_tp += 1;
                            t = tps[next_tp];
                            if (!(t.row == old_row_idx_i and t.col == c)) break;
                        }
                        tp = if (t.row != old_row_idx_i) null else t;
                    }
                }

                if (old_row.shell_integration.cmd_start == c)
                    new_row.shell_integration.cmd_start = new_col_idx;
                if (old_row.shell_integration.cmd_end == c)
                    new_row.shell_integration.cmd_end = new_col_idx;

                const cur = cells[@intCast(c)];
                if (width > new_cols) {
                    if (i == 0) {
                        new_row.cells.?[@intCast(new_col_idx)] = cur;
                        new_row.cells.?[@intCast(new_col_idx)].wc = 0;
                    }
                    if (i == width - 1)
                        new_col_idx += 1;
                } else {
                    new_row.cells.?[@intCast(new_col_idx)] = cur;
                    new_col_idx += 1;
                }

                new_row.linebreak = false;
                c += 1;
            }
        }

        if (old_row.linebreak) {
            if (col_count > 0) {
                zeroCells(new_row, new_col_idx, new_cols);
                new_row.linebreak = true;

                if (r + 1 < old_rows) {
                    new_row = lineWrap(grid, new_grid, new_row, &new_row_idx, &new_col_idx, new_rows, new_cols);
                } else if (new_row.extra) |ne| {
                    if (ne.uri_ranges.count > 0)
                        std.debug.assert(ne.uri_ranges.v.?[@intCast(ne.uri_ranges.count - 1)].end >= 0);
                    if (ne.underline_ranges.count > 0)
                        std.debug.assert(ne.underline_ranges.v.?[@intCast(ne.underline_ranges.count - 1)].end >= 0);
                }
            } else {
                coalesced_linebreaks += 1;
            }
        }

        rowFree(old_grid_opt.?[old_row_idx]);
        old_grid_opt.?[old_row_idx] = null;
    }

    zeroCells(new_row, new_col_idx, new_cols);
    std.debug.assert(old_rows == 0 or tps[next_tp] == &terminator);

    grid.offset = new_row_idx - new_screen_rows + 1;
    while (grid.offset < 0)
        grid.offset += new_rows;
    while (new_grid[@intCast(grid.offset)] == null)
        grid.offset = (grid.offset + 1) & (new_rows - 1);

    var fr: c_int = 0;
    while (fr < new_screen_rows) : (fr += 1) {
        const idx: usize = @intCast((grid.offset + fr) & (new_rows - 1));
        if (new_grid[idx] == null)
            new_grid[idx] = rowAlloc(new_cols, true);
    }

    std.c.free(@ptrCast(old_grid_opt));
    grid.rows = new_grid;
    grid.num_rows = new_rows;
    grid.num_cols = new_cols;

    const sb_view = rowAbsToSb(grid, new_screen_rows, if (view_follows) grid.offset else viewport.row);
    grid.view = rowSbToAbs(grid, new_screen_rows, @min(sb_view, new_rows - new_screen_rows));

    cursor.row -= grid.offset;
    while (cursor.row < 0) cursor.row += grid.num_rows;
    cursor.row = @min(cursor.row, new_screen_rows - 1);
    cursor.col = @min(cursor.col, new_cols - 1);

    saved_cursor.row -= grid.offset;
    while (saved_cursor.row < 0) saved_cursor.row += grid.num_rows;
    saved_cursor.row = @min(saved_cursor.row, new_screen_rows - 1);
    saved_cursor.col = @min(saved_cursor.col, new_cols - 1);

    if (grid.cursor.lcf and cursor.col + 1 < new_cols) {
        cursor.col += 1;
        grid.cursor.lcf = false;
    }
    if (grid.saved_cursor.lcf and saved_cursor.col + 1 < new_cols) {
        saved_cursor.col += 1;
        grid.saved_cursor.lcf = false;
    }

    const cur_idx: usize = @intCast((grid.offset + cursor.row) & (new_rows - 1));
    grid.cur_row = new_grid[cur_idx];
    std.debug.assert(grid.cur_row != null);
    grid.cursor.point = cursor;
    grid.saved_cursor.point = saved_cursor;

    var rest = untranslated.head;
    while (rest) |node| {
        const next = node.next;
        sixel_destroy(&node.item);
        std.c.free(node);
        rest = next;
    }
}

test "reflow narrows columns, wrapping a line and keeping the cursor on its cell" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rw.linebreak = true;
        rows[i] = rw;
    }
    // "ABCD" wraps into the next row, which holds "EF" and ends with a real linebreak.
    const abcd = "ABCD";
    for (abcd, 0..) |ch, k| rows[0].?.cells.?[k].wc = ch;
    rows[0].?.linebreak = false;
    rows[1].?.cells.?[0].wc = 'E';
    rows[1].?.cells.?[1].wc = 'F';

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 1, .row = 1 };
    g.cur_row = rows[1];

    gridResizeAndReflow(&g, null, 8, 2, 4, 4, 0, null);

    try std.testing.expectEqual(@as(c_int, 8), g.num_rows);
    try std.testing.expectEqual(@as(c_int, 2), g.num_cols);
    try std.testing.expectEqual(@as(c_int, 0), g.offset);

    const out = g.rows.?;
    try std.testing.expectEqual(@as(u32, 'A'), out[0].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 'B'), out[0].?.cells.?[1].wc);
    try std.testing.expect(!out[0].?.linebreak);
    try std.testing.expectEqual(@as(u32, 'C'), out[1].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 'D'), out[1].?.cells.?[1].wc);
    try std.testing.expectEqual(@as(u32, 'E'), out[2].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 'F'), out[2].?.cells.?[1].wc);
    try std.testing.expect(out[2].?.linebreak);

    // The cursor was on 'F' (old row 1, col 1) and must still be on it.
    try std.testing.expectEqual(@as(c_int, 1), g.cursor.point.col);
    try std.testing.expectEqual(@as(c_int, 2), g.cursor.point.row);
    try std.testing.expect(g.cur_row == out[2]);

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(out[k]);
    std.c.free(@ptrCast(out));
}

test "uri range put twice on the same column replaces without leaking" {
    const r = rowAlloc(4, true);
    defer rowFree(r);

    const a = strdup("file:///a").?;
    defer std.c.free(a);
    const b = strdup("file:///b").?;
    defer std.c.free(b);

    rowUriRangePut(r, 1, a, 1);
    rowUriRangePut(r, 1, b, 2);

    const ranges = &r.extra.?.uri_ranges;
    try std.testing.expectEqual(@as(c_int, 1), ranges.count);
    try std.testing.expectEqual(@as(u64, 2), ranges.v.?[0].data.uri.id);
    try std.testing.expectEqualStrings("file:///b", std.mem.span(ranges.v.?[0].data.uri.uri.?));
}

test "reflow pads a wide character that does not fit and moves it to the next row" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rw.linebreak = true;
        rows[i] = rw;
    }
    // "AB" then a double-width X (wc, then CELL_SPACER + 1) in a 4-column row.
    const r0 = rows[0].?;
    r0.cells.?[0].wc = 'A';
    r0.cells.?[1].wc = 'B';
    r0.cells.?[2].wc = 'X';
    r0.cells.?[3].wc = CELL_SPACER + 1;

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 0, .row = 3 };
    g.cur_row = rows[3];

    // Narrow to 3 columns: 'X' needs 2 cells but only 1 is left after "AB".
    gridResizeAndReflow(&g, null, 8, 3, 4, 4, 0, null);

    const out = g.rows.?;
    try std.testing.expectEqual(@as(u32, 'A'), out[0].?.cells.?[0].wc);
    try std.testing.expectEqual(@as(u32, 'B'), out[0].?.cells.?[1].wc);
    try std.testing.expectEqual(CELL_SPACER, out[0].?.cells.?[2].wc);
    try std.testing.expectEqual(@as(u32, 'X'), out[1].?.cells.?[0].wc);
    try std.testing.expectEqual(CELL_SPACER + 1, out[1].?.cells.?[1].wc);

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(out[k]);
    std.c.free(@ptrCast(out));
}

test "reflow splits a uri range across a wrap without leaking or double freeing" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rw.linebreak = true;
        rows[i] = rw;
    }

    const r0 = rows[0].?;
    const abcd = "ABCD";
    for (abcd, 0..) |ch, k| r0.cells.?[k].wc = ch;

    // URI range over columns 1..3 ("BCD"); the row takes ownership of the string.
    ensureRowHasExtraData(r0);
    var data = std.mem.zeroes(types.RowRangeData);
    data.uri = .{ .id = 5, .uri = strdup("file:///r") };
    rangeAppendByRef(&r0.extra.?.uri_ranges, 1, 3, .uri, &data);

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 0, .row = 3 };
    g.cur_row = rows[3];

    gridResizeAndReflow(&g, null, 8, 2, 4, 4, 0, null);

    const out = g.rows.?;

    // Row 0 is "AB": the range starts at col 1 and is closed at the row edge.
    const a = &out[0].?.extra.?.uri_ranges;
    try std.testing.expectEqual(@as(c_int, 1), a.count);
    try std.testing.expectEqual(@as(c_int, 1), a.v.?[0].start);
    try std.testing.expectEqual(@as(c_int, 1), a.v.?[0].end);
    try std.testing.expectEqual(@as(u64, 5), a.v.?[0].data.uri.id);

    // Row 1 is "CD": the range continues from col 0 to col 1.
    const b = &out[1].?.extra.?.uri_ranges;
    try std.testing.expectEqual(@as(c_int, 1), b.count);
    try std.testing.expectEqual(@as(c_int, 0), b.v.?[0].start);
    try std.testing.expectEqual(@as(c_int, 1), b.v.?[0].end);
    try std.testing.expectEqual(@as(u64, 5), b.v.?[0].data.uri.id);

    // Each row owns its own copy of the string.
    try std.testing.expect(a.v.?[0].data.uri.uri.? != b.v.?[0].data.uri.uri.?);
    try std.testing.expectEqualStrings("file:///r", std.mem.span(a.v.?[0].data.uri.uri.?));
    try std.testing.expectEqualStrings("file:///r", std.mem.span(b.v.?[0].data.uri.uri.?));

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(out[k]);
    std.c.free(@ptrCast(out));
}

test "reflow into a full ring reuses rows and frees their extra data" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        // No linebreaks: all four rows join into one 16-character logical line.
        rw.linebreak = false;
        const letters = "ABCD";
        for (letters, 0..) |ch, k| rw.cells.?[k].wc = ch;
        rows[i] = rw;
    }

    // An open-ended URI range on the first row, carried across every wrap.
    const r0 = rows[0].?;
    ensureRowHasExtraData(r0);
    var data = std.mem.zeroes(types.RowRangeData);
    data.uri = .{ .id = 3, .uri = strdup("file:///ring") };
    rangeAppendByRef(&r0.extra.?.uri_ranges, 0, 3, .uri, &data);

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 0, .row = 3 };
    g.cur_row = rows[3];

    // 16 cells into 2 columns needs 8 rows, but the ring only has 4.
    gridResizeAndReflow(&g, null, 4, 2, 4, 4, 0, null);

    const out = g.rows.?;
    try std.testing.expectEqual(@as(c_int, 4), g.num_rows);
    try std.testing.expectEqual(@as(c_int, 2), g.num_cols);

    var r: c_int = 0;
    var saw_d = false;
    while (r < 4) : (r += 1) {
        const idx: usize = @intCast((g.offset + r) & 3);
        const rw = out[idx] orelse return error.TestUnexpectedNull;
        if (rw.cells.?[1].wc == 'D') saw_d = true;
    }
    try std.testing.expect(saw_d);
    try std.testing.expect(g.cur_row != null);

    var k: usize = 0;
    while (k < 4) : (k += 1) rowFree(out[k]);
    std.c.free(@ptrCast(out));
}

test "reflow keeps a scrolled-back viewport on the same content" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(8, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rw.linebreak = true;
        rw.cells.?[0].wc = 'a' + @as(u32, @intCast(i));
        rows[i] = rw;
    }

    // 8 rows in the ring, screen is 4 rows, scrolled back by two rows.
    g.rows = rows;
    g.num_rows = 8;
    g.num_cols = 4;
    g.offset = 4;
    g.view = 2;
    g.cursor.point = .{ .col = 0, .row = 3 };
    g.cur_row = rows[7];

    gridResizeAndReflow(&g, null, 8, 6, 4, 4, 0, null);

    try std.testing.expect(g.view != g.offset);
    const view_row = g.rows.?[@intCast(g.view)] orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 'c'), view_row.cells.?[0].wc);

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(g.rows.?[k]);
    std.c.free(@ptrCast(g.rows.?));
}

test "reflow collapses a character wider than the row into one blank cell" {
    var g = std.mem.zeroes(types.Grid);
    const rows: [*]?*types.Row = @ptrCast(@alignCast(xcalloc(4, @sizeOf(?*types.Row))));
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const rw = rowAlloc(4, true);
        @memset(rw.cells.?[0..4], std.mem.zeroes(types.Cell));
        rw.linebreak = true;
        rows[i] = rw;
    }
    // Width-3 character "X" (wc, then CELL_SPACER + 2, then a spacer), followed by 'Z'.
    const r0 = rows[0].?;
    r0.cells.?[0].wc = 'X';
    r0.cells.?[1].wc = CELL_SPACER + 2;
    r0.cells.?[2].wc = CELL_SPACER;
    r0.cells.?[3].wc = 'Z';

    g.rows = rows;
    g.num_rows = 4;
    g.num_cols = 4;
    g.cursor.point = .{ .col = 0, .row = 3 };
    g.cur_row = rows[3];

    gridResizeAndReflow(&g, null, 8, 2, 4, 4, 0, null);

    const out = g.rows.?;
    var saw_x = false;
    var saw_z = false;
    var r: usize = 0;
    while (r < 8) : (r += 1) {
        const rw = out[r] orelse continue;
        var c: usize = 0;
        while (c < 2) : (c += 1) {
            const wc = rw.cells.?[c].wc;
            if (wc == 'X') saw_x = true;
            if (wc == 'Z') saw_z = true;
        }
    }
    try std.testing.expect(!saw_x);
    try std.testing.expect(saw_z);
    try std.testing.expectEqual(@as(u32, 0), out[0].?.cells.?[0].wc);

    var k: usize = 0;
    while (k < 8) : (k += 1) rowFree(out[k]);
    std.c.free(@ptrCast(out));
}

test "resize tolerates an uninitialized grid (NULL rows)" {
    // term_init() zeroes term->normal/alt: rows is NULL and num_rows is 0
    // until the first wl_surface configure. C tolerates that (the pointer is
    // never dereferenced and free(NULL) is fine); the port must too.
    var normal = std.mem.zeroes(types.Grid);
    normal.sixel_images = .{ .head = null, .tail = null, .length = 0 };
    normal.scroll_damage = .{ .head = null, .tail = null, .length = 0 };

    gridResizeAndReflow(&normal, null, 24, 80, 0, 24, 0, null);

    try std.testing.expect(normal.rows != null);
    try std.testing.expectEqual(@as(c_int, 24), normal.num_rows);
    try std.testing.expectEqual(@as(c_int, 80), normal.num_cols);

    var alt = std.mem.zeroes(types.Grid);
    alt.sixel_images = .{ .head = null, .tail = null, .length = 0 };
    alt.scroll_damage = .{ .head = null, .tail = null, .length = 0 };

    gridResizeWithoutReflow(&alt, 24, 80, 0, 24);

    try std.testing.expect(alt.rows != null);
    try std.testing.expectEqual(@as(c_int, 24), alt.num_rows);
}

// ---------------------------------------------------------------------------
// C ABI exports (replace grid.c)
// ---------------------------------------------------------------------------

export fn grid_row_abs_to_sb(grid: *const types.Grid, screen_rows: c_int, abs_row: c_int) callconv(.c) c_int {
    return rowAbsToSb(grid, screen_rows, abs_row);
}

export fn grid_row_sb_to_abs(grid: *const types.Grid, screen_rows: c_int, sb_rel_row: c_int) callconv(.c) c_int {
    return rowSbToAbs(grid, screen_rows, sb_rel_row);
}

export fn grid_sb_start_ignore_uninitialized(grid: *const types.Grid, screen_rows: c_int) callconv(.c) c_int {
    return sbStartIgnoreUninitialized(grid, screen_rows);
}

export fn grid_row_abs_to_sb_precalc_sb_start(grid: *const types.Grid, sb_start: c_int, abs_row: c_int) callconv(.c) c_int {
    return rowAbsToSbPrecalcSbStart(grid, sb_start, abs_row);
}

export fn grid_row_sb_to_abs_precalc_sb_start(grid: *const types.Grid, sb_start: c_int, sb_rel_row: c_int) callconv(.c) c_int {
    return rowSbToAbsPrecalcSbStart(grid, sb_start, sb_rel_row);
}

export fn grid_snapshot(grid: *const types.Grid) callconv(.c) *types.Grid {
    return gridSnapshot(grid);
}

export fn grid_free(grid: ?*types.Grid) callconv(.c) void {
    gridFree(grid);
}

export fn grid_swap_row(grid: *types.Grid, row_a: c_int, row_b: c_int) callconv(.c) void {
    swapRow(grid, row_a, row_b);
}

export fn grid_row_alloc(cols: c_int, initialize: bool) callconv(.c) *types.Row {
    return rowAlloc(cols, initialize);
}

export fn grid_row_free(r: ?*types.Row) callconv(.c) void {
    rowFree(r);
}

export fn grid_resize_without_reflow(
    grid: *types.Grid,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
) callconv(.c) void {
    gridResizeWithoutReflow(grid, new_rows, new_cols, old_screen_rows, new_screen_rows);
}

// Called from grid-shim.c, which supplies term->composed.
export fn grid_resize_and_reflow(
    grid: *types.Grid,
    composed_root: ?*Composed,
    new_rows: c_int,
    new_cols: c_int,
    old_screen_rows: c_int,
    new_screen_rows: c_int,
    tracking_points_count: usize,
    tracking_points: ?[*]const *types.Coord,
) callconv(.c) void {
    gridResizeAndReflow(grid, composed_root, new_rows, new_cols, old_screen_rows, new_screen_rows, tracking_points_count, tracking_points);
}

export fn grid_row_range_put(
    ranges: *types.RowRanges,
    col: c_int,
    data: *const types.RowRangeData,
    range_type: types.RowRangeType,
) callconv(.c) void {
    gridRowRangePut(ranges, col, data, range_type);
}

export fn grid_row_uri_range_put(r: *types.Row, col: c_int, uri: ?[*:0]const u8, id: u64) callconv(.c) void {
    rowUriRangePut(r, col, uri, id);
}

export fn grid_row_underline_range_put(r: *types.Row, col: c_int, data: types.UnderlineRangeData) callconv(.c) void {
    rowUnderlineRangePut(r, col, data);
}

export fn grid_row_range_erase(
    ranges: *types.RowRanges,
    range_type: types.RowRangeType,
    start: c_int,
    end: c_int,
) callconv(.c) void {
    gridRowRangeErase(ranges, range_type, start, end);
}

export fn grid_row_uri_range_erase(r: *types.Row, start: c_int, end: c_int) callconv(.c) void {
    rowUriRangeErase(r, start, end);
}

export fn grid_row_underline_range_erase(r: *types.Row, start: c_int, end: c_int) callconv(.c) void {
    rowUnderlineRangeErase(r, start, end);
}
