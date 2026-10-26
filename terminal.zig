const std = @import("std");
const types = @import("terminal_types.zig");
extern fn term_update_ascii_printer(term: *types.Terminal) void;
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

// ── Chunk A: term_row_rel_to_abs + blink/flash timers ────────────

extern fn render_overlay(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
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
