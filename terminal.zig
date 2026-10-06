const std = @import("std");
const types = @import("terminal_types.zig");
extern fn term_row_rel_to_abs(term: *const types.Terminal, row: c_int) c_int;
extern fn term_update_ascii_printer(term: *types.Terminal) void;
extern fn term_cursor_blink_update(term: *types.Terminal) void;
extern fn render_refresh_csd(term: *types.Terminal) void;

extern fn row(grid: *types.Grid, row_no: c_int) *types.Row;
extern fn rowInView(grid: *types.Grid, row_no: c_int) *types.Row;

fn termResetGraphemeState(term: *types.Terminal) void {
    term.vt.grapheme_state = 0;
    term.vt.codepoint_merging_ok = false;
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
    std.debug.assert(term.grid.?.cursor.point.row >= top);

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
    std.debug.assert(bottom >= term.grid.?.cursor.point.row);

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
            current_row.cells.?[ @intCast(c) ].attrs.clean = false;
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
            current_row.cells.?[ @intCast(c) ].attrs.clean = false;
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
