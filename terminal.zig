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

// ── Chunk C1: term_erase / term_fill / term_print / print_spacer ─
// Hot path. Depends on grid row access, URI/underline ranges,
// linewrap/insert helpers (all still C), and sixel_overwrite_* (Zig).

extern fn erase_cell_range(term: *types.Terminal, row: *types.Row, start: c_int, end: c_int) callconv(.c) void;
extern fn print_linewrap(term: *types.Terminal) callconv(.c) void;
extern fn print_insert(term: *types.Terminal, width: c_int) callconv(.c) void;

extern fn grid_row_uri_range_put(row: *types.Row, col: c_int, uri: [*:0]const u8, id: u64) callconv(.c) void;
extern fn grid_row_uri_range_erase(row: *types.Row, start: c_int, end: c_int) callconv(.c) void;
extern fn grid_row_underline_range_put(row: *types.Row, col: c_int, range: types.UnderlineRangeData) callconv(.c) void;
extern fn grid_row_underline_range_erase(row: *types.Row, start: c_int, end: c_int) callconv(.c) void;

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
