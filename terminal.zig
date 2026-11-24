const std = @import("std");
const build_options = @import("build_options");
const types = @import("terminal_types.zig");
extern fn render_refresh_csd(term: *types.Terminal) void;

extern fn row(grid: *types.Grid, row_no: c_int) *types.Row;
extern fn rowInView(grid: *types.Grid, row_no: c_int) *types.Row;

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

// ── Chunk A: term_row_rel_to_abs + blink/flash timers ────────────

extern fn render_overlay(term: *types.Terminal) callconv(.c) void;
extern fn fdm_add(fdm: *anyopaque, fd: c_int, events: c_int, handler: *const fn (*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) bool, data: ?*anyopaque) callconv(.c) bool;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;
extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
extern fn timerfd_settime(fd: c_int, flags: c_int, new_value: *const types.Itimerspec, old_value: ?*types.Itimerspec) callconv(.c) c_int;
extern fn read(fd: c_int, buf: *anyopaque, count: usize) callconv(.c) isize;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn __errno_location() callconv(.c) *c_int;
extern fn terminal_shim_window_surface(term: *types.Terminal) callconv(.c) ?*anyopaque;
extern fn terminal_shim_window_is_configured(term: *types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_cursor_blink_rate_ms(term: *types.Terminal) callconv(.c) c_int;
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

    const surf = terminal_shim_window_surface(term);
    if (surf) |s| terminal_shim_wl_surface_commit(s);
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

    const alarm: types.Itimerspec = .{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 500 * 1_000_000 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 500 * 1_000_000 },
    };

    if (timerfd_settime(fd, 0, &alarm, null) < 0) {
        _ = fdm_del(term.fdm orelse return, fd);
    }

    term.blink.fd = fd;
}

// ── cursor_refresh ──────────────────────────────────────────────
export fn cursor_refresh(term: *types.Terminal) callconv(.c) void {
    if (!terminal_shim_window_is_configured(term)) return;
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

    const rate_ms = terminal_shim_conf_cursor_blink_rate_ms(term);
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

        // C: if (term->render.last_cursor.row == row) term->render.last_cursor.row = NULL;
        // render.last_cursor.row is opaque here; shim later if needed.
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
// Hot path. Depends on grid row access, URI/underline ranges,
// linewrap/insert helpers (all still C), and sixel_overwrite_* (Zig).


extern fn grid_row_uri_range_put(row: *types.Row, col: c_int, uri: [*:0]const u8, id: u64) callconv(.c) void;
extern fn grid_row_underline_range_put(row: *types.Row, col: c_int, range: types.UnderlineRangeData) callconv(.c) void;

extern fn sixel_overwrite_by_row(term: *types.Terminal, row: c_int, col: c_int, width: c_int) callconv(.c) void;
extern fn sixel_overwrite_by_rectangle(term: *types.Terminal, row: c_int, col: c_int, height: c_int, width: c_int) callconv(.c) void;
extern fn sixel_overwrite_at_cursor(term: *types.Terminal, width: c_int) callconv(.c) void;

extern fn terminal_shim_conf_url_osc8_underline(term: *types.Terminal) callconv(.c) c_int;

// OSC8_UNDERLINE_ALWAYS = 0, OSC8_UNDERLINE_URL_MODE = 1 (from config.h)
const OSC8_UNDERLINE_ALWAYS: c_int = 0;
const OSC8_UNDERLINE_URL_MODE: c_int = 1;

// UNDERLINE_SINGLE = 0, COLOR_DEFAULT = 0 (from terminal_types)
const UNDERLINE_SINGLE: c_int = 0;


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

    const osc8_underline = terminal_shim_conf_url_osc8_underline(term);

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

            if (osc8_underline == OSC8_UNDERLINE_ALWAYS) {
                cell.attrs.url = true;
            }
        }

        if (use_sgr_attrs and
            (term.vt.underline.style > UNDERLINE_SINGLE or
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

        if (term.vt.underline.style <= UNDERLINE_SINGLE and
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
        const osc8_underline = terminal_shim_conf_url_osc8_underline(term);
        var i: c_int = 0;
        while (i < width and (col + i) < term.cols) : (i += 1) {
            grid_row_uri_range_put(
                current_row,
                col + i,
                @ptrCast(term.vt.osc8.uri.?),
                term.vt.osc8.id,
            );
        }
        if (osc8_underline == OSC8_UNDERLINE_ALWAYS) {
            cell.attrs.url = true;
        }
    } else if (current_row.extra != null) {
        grid_row_uri_range_erase(current_row, col, col + width - 1);
    }

    if (term.vt.underline.style > UNDERLINE_SINGLE or
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
//   - fcft_precompose()                 (term->fonts is opaque here)
//   - conf->tweak.grapheme_width_method (struct config isn't mirrored)
//   - emoji_vs[] VS-15/VS-16 table      (generated at build time)

const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fff_ffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

const GRAPHEME_WIDTH_WCSWIDTH: c_int = 0;
const GRAPHEME_WIDTH_DOUBLE: c_int = 1;
const GRAPHEME_WIDTH_MAX: c_int = 2;

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
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;

extern fn terminal_shim_precompose(
    term: *types.Terminal,
    base: u32,
    wc: u32,
    base_from_primary: *bool,
    comb_from_primary: *bool,
    pre_from_primary: *bool,
) u32;
extern fn terminal_shim_conf_grapheme_width_method(term: *const types.Terminal) c_int;
extern fn terminal_shim_emoji_vs_width(cp: u32, wc: u32) c_int;

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
                ) != 0)
                {
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

            const precomposed = terminal_shim_precompose(
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

        switch (terminal_shim_conf_grapheme_width_method(term)) {
            GRAPHEME_WIDTH_MAX => new_cc.width = @intCast(@max(grapheme_width, width)),

            GRAPHEME_WIDTH_DOUBLE => {
                new_cc.width = @intCast(@min(grapheme_width + width, 2));

                // Handle VS-15 and VS-16 variation selectors
                if (comptime build_options.grapheme_clustering) {
                    if (grapheme_clustering and
                        (wc == 0xfe0e or wc == 0xfe0f) and
                        new_cc.count == 2)
                    {
                        const forced = terminal_shim_emoji_vs_width(chars[0], wc);
                        if (forced >= 0)
                            new_cc.width = @intCast(forced);
                    }
                }
            },

            GRAPHEME_WIDTH_WCSWIDTH => new_cc.width = @intCast(grapheme_width + width),

            else => unreachable,
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
extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

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

extern fn term_shutdown(term: *types.Terminal) callconv(.c) void;
extern fn vt_from_slave(term: *types.Terminal, data: [*]const u8, len: usize) callconv(.c) void;
extern fn del_utmp_record(
    conf: ?*const anyopaque,
    reaper: ?*anyopaque,
    ptmx: c_int,
) callconv(.c) bool;
extern fn terminal_shim_delayed_render_lower_fd(term: *types.Terminal) callconv(.c) c_int;
extern fn terminal_shim_delayed_render_upper_fd(term: *types.Terminal) callconv(.c) c_int;
extern fn terminal_shim_delayed_render_is_armed(term: *types.Terminal) callconv(.c) bool;
extern fn terminal_shim_delayed_render_set_armed(term: *types.Terminal, armed: bool) callconv(.c) void;
extern fn terminal_shim_conf_delayed_render_lower_ns(term: *types.Terminal) callconv(.c) u32;
extern fn terminal_shim_conf_delayed_render_upper_ns(term: *types.Terminal) callconv(.c) u32;
extern fn terminal_shim_conf_hold_at_exit(term: *types.Terminal) callconv(.c) bool;

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
        const lower_ns = terminal_shim_conf_delayed_render_lower_ns(term);
        const upper_ns = terminal_shim_conf_delayed_render_upper_ns(term);

        if (lower_ns > 0 and upper_ns > 0) {
            std.debug.assert(lower_ns < 1_000_000_000);
            std.debug.assert(upper_ns < 1_000_000_000);
            std.debug.assert(upper_ns > lower_ns);

            _ = timerfd_settime(
                terminal_shim_delayed_render_lower_fd(term),
                0,
                &types.Itimerspec{
                    .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(lower_ns) },
                    .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                },
                null,
            );

            // Second timeout - only reset when we render. Set to one
            // frame (assuming 60Hz)
            if (!terminal_shim_delayed_render_is_armed(term)) {
                _ = timerfd_settime(
                    terminal_shim_delayed_render_upper_fd(term),
                    0,
                    &types.Itimerspec{
                        .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(upper_ns) },
                        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                    },
                    null,
                );
                terminal_shim_delayed_render_set_armed(term, true);
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
        if (term.slave < 0 and !terminal_shim_conf_hold_at_exit(term))
            term_shutdown(term);
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
extern fn term_xcursor_update(term: *types.Terminal) callconv(.c) void;
extern fn terminal_shim_window_is_suspended(term: *types.Terminal) callconv(.c) bool;
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
    const report = if (terminal_shim_window_is_suspended(term))
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
    const alarm = types.Itimerspec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = @intCast(duration_ms * 1_000_000) },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };

    if (timerfd_settime(term.flash.fd, 0, &alarm, null) < 0) {
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
    _ = timerfd_settime(terminal_shim_delayed_render_lower_fd(term), 0, &zero_itimerspec, null);
    _ = timerfd_settime(terminal_shim_delayed_render_upper_fd(term), 0, &zero_itimerspec, null);
    terminal_shim_delayed_render_set_armed(term, false);
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
// colour-theme switches. The config is still C-owned; read-only access goes
// through terminal_shim_conf_*() accessors until phase 2 ports it.
//

extern fn wayl_win_alpha_changed(window: ?*anyopaque) callconv(.c) void;
extern fn term_font_subpixel_changed(term: *types.Terminal) callconv(.c) void;
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
extern fn terminal_shim_conf_colors_dark(term: *const types.Terminal) callconv(.c) *const types.ColorTheme;
extern fn terminal_shim_conf_colors_light(term: *const types.Terminal) callconv(.c) *const types.ColorTheme;
extern fn terminal_shim_conf_locked_title(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_app_id(term: *const types.Terminal) callconv(.c) ?[*:0]const u8;
extern fn terminal_shim_conf_conf_path(term: *const types.Terminal) callconv(.c) ?[*:0]const u8;

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

fn replaceStr(dst: *?[*:0]u8, value: [*:0]const u8) void {
    if (dst.*) |old|
        std.c.free(old);
    dst.* = xstrdup(value);
}

export fn term_set_window_title(term: *types.Terminal, title: [*:0]const u8) void {
    if (terminal_shim_conf_locked_title(term) and term.window_title_has_been_set)
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
    const app_id = if (term.app_id) |id| id else terminal_shim_conf_app_id(term).?;

    return if (streq(app_id, "footclient")) "foot" else app_id;
}

export fn term_spawn_new(term: *const types.Terminal) bool {
    var argv: [4]?[*:0]const u8 = .{ term.foot_exe, null, null, null };
    var argc: usize = 1;

    if (terminal_shim_conf_conf_path(term)) |conf_path| {
        argv[argc] = "--config";
        argc += 1;
        argv[argc] = conf_path;
        argc += 1;
    }
    argv[argc] = null;

    return spawn(
        term.reaper,
        @ptrCast(term.cwd),
        @ptrCast(&argv),
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
        .dark => terminal_shim_conf_colors_dark(term),
        else => terminal_shim_conf_colors_light(term),
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
        terminal_shim_conf_colors_dark(term)
    else
        terminal_shim_conf_colors_light(term);
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
extern fn terminal_shim_conf_bell_urgent(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_bell_system_bell(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_bell_notify(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_bell_flash(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_bell_command_focused(term: *const types.Terminal) callconv(.c) bool;
extern fn terminal_shim_conf_bell_command_argv(term: *const types.Terminal) callconv(.c) [*c]const [*c]u8;

const O_RDONLY: c_int = 0;

export fn term_bell(term: *types.Terminal) void {
    if (!term.bell_action_enabled)
        return;

    if (terminal_shim_conf_bell_urgent(term) and !term.kbd_focus) {
        if (!wayl_win_set_urgent(term.window)) {
            // Urgency (xdg-activation) is relatively new in Wayland. Fall
            // back to the old, "faked", urgency: red window margins.
            term.render.urgency = true;
            term_damage_margins(term);
        }
    }

    if (terminal_shim_conf_bell_system_bell(term))
        wayl_win_ring_bell(term.window);

    if (terminal_shim_conf_bell_notify(term)) {
        var notif = std.mem.zeroes(types.Notification);
        notif.title = xstrdup("Bell");
        notif.body = xstrdup("Bell in terminal");
        notif.expire_time = -1;
        notif.focus = true;
        _ = notify_notify(term, &notif);
    }

    if (terminal_shim_conf_bell_flash(term))
        term_flash(term, 100);

    if (terminal_shim_conf_bell_command_argv(term) != null and
        (!term.kbd_focus or terminal_shim_conf_bell_command_focused(term)))
    {
        const devnull = open("/dev/null", O_RDONLY);
        _ = spawn(term.reaper, null, terminal_shim_conf_bell_command_argv(term), devnull, -1, -1, null, null, null);

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
