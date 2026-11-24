const std = @import("std");
const types = @import("terminal_types.zig");

// Port of commands.c: the scrollback-up/down commands bound to keys and
// scroll events.

extern fn terminal_shim_urls_mode_active(term: *const types.Terminal) callconv(.c) bool;
extern fn render_refresh_urls(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
extern fn grid_sb_start_ignore_uninitialized(grid: *const types.Grid, screen_rows: c_int) callconv(.c) c_int;
extern fn grid_row_abs_to_sb_precalc_sb_start(
    grid: *const types.Grid,
    sb_start: c_int,
    abs_row: c_int,
) callconv(.c) c_int;
extern fn term_damage_scroll(
    term: *types.Terminal,
    damage_type: types.DamageType,
    region: types.ScrollRegion,
    lines: c_int,
) callconv(.c) void;
extern fn term_damage_rows_in_view(term: *types.Terminal, start: c_int, end: c_int) callconv(.c) void;
extern fn term_damage_view(term: *types.Terminal) callconv(.c) void;
extern fn selection_view_up(term: *types.Terminal, new_view: c_int) callconv(.c) void;
extern fn selection_view_down(term: *types.Terminal, new_view: c_int) callconv(.c) void;

export fn cmd_scrollback_up(term: *types.Terminal, rows_in: c_int) void {
    if (term.grid == &term.alt)
        return;
    if (terminal_shim_urls_mode_active(term))
        return;

    const grid = term.grid.?;
    const view = grid.view;
    const grid_rows = grid.num_rows;

    // The view row number in scrollback relative coordinates. This is the
    // maximum number of rows we're allowed to scroll.
    const sb_start = grid_sb_start_ignore_uninitialized(grid, term.rows);
    const view_sb_rel = grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, view);

    const rows = @min(rows_in, view_sb_rel);
    if (rows == 0)
        return;

    const new_view = ((view + grid_rows) - rows) & (grid_rows - 1);

    std.debug.assert(new_view != view);
    std.debug.assert(grid.rows.?[@intCast(new_view)] != null);

    if (comptime @import("builtin").mode == .Debug) {
        var r: c_int = 0;
        while (r < term.rows) : (r += 1) {
            const row_idx = (new_view + r) & (grid.num_rows - 1);
            std.debug.assert(grid.rows.?[@intCast(row_idx)] != null);
        }
    }

    selection_view_up(term, new_view);
    grid.view = new_view;

    if (rows < term.rows) {
        term_damage_scroll(
            term,
            .scroll_reverse_in_view,
            .{ .start = 0, .end = term.rows },
            rows,
        );
        term_damage_rows_in_view(term, 0, rows - 1);
    } else {
        term_damage_view(term);
    }

    render_refresh_urls(term);
    render_refresh(term);

}

export fn cmd_scrollback_down(term: *types.Terminal, rows_in: c_int) void {
    if (term.grid == &term.alt)
        return;
    if (terminal_shim_urls_mode_active(term))
        return;

    const grid = term.grid.?;
    const offset = grid.offset;
    const view = grid.view;
    const grid_rows = grid.num_rows;
    const screen_rows = term.rows;

    const scrollback_end = offset;

    // Number of rows to scroll, without going past the scrollback end
    const max_rows: c_int = if (view <= scrollback_end)
        scrollback_end - view
    else
        offset + (grid_rows - view);

    const rows = @min(rows_in, max_rows);
    if (rows == 0)
        return;

    const new_view = (view + rows) & (grid_rows - 1);

    std.debug.assert(new_view != view);
    std.debug.assert(grid.rows.?[@intCast(new_view)] != null);

    if (comptime @import("builtin").mode == .Debug) {
        var r: c_int = 0;
        while (r < term.rows) : (r += 1) {
            const row_idx = (new_view + r) & (grid_rows - 1);
            std.debug.assert(grid.rows.?[@intCast(row_idx)] != null);
        }
    }

    selection_view_down(term, new_view);
    grid.view = new_view;

    if (rows < term.rows) {
        term_damage_scroll(
            term,
            .scroll_in_view,
            .{ .start = 0, .end = term.rows },
            rows,
        );
        term_damage_rows_in_view(term, term.rows - rows, screen_rows - 1);
    } else {
        term_damage_view(term);
    }

    render_refresh_urls(term);
    render_refresh(term);

}
