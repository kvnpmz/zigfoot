const std = @import("std");
const types = @import("terminal_types.zig");

// TODO: port selection.c: selection_start, selection_update, selection_finalize, ...

// ── Chunk A: grid helpers + foreach_selected + selection_to_text ──
// Ports selection.c lines 33-345.

// Constants from terminal.h
const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

// isword: still in C (misc.h)
extern fn isword(wc: u32, spaces_only: bool, delimiters: ?[*]const u32) callconv(.c) bool;
// isc32space: static inline in char32.h -> port inline here
fn isc32space(c: u32) bool {
    // C: iswspace((wint_t)c32). For the ASCII/C-locale case we treat
    // the standard whitespace set; if foot relies on locale-specific
    // behavior we can shim this later.
    return c == 0x20 or c == 0x09 or c == 0x0a or c == 0x0b or
           c == 0x0c or c == 0x0d;
}

// composed_lookup: exported from composed.zig
extern fn composed_lookup(root: ?*types.Composed, key: u32) callconv(.c) ?*types.Composed;

// extract: still in C
const ExtractionContext = anyopaque;
extern fn extract_begin(kind: types.SelectionKind, strip_trailing_empty: bool) callconv(.c) ?*ExtractionContext;
extern fn extract_one(
    term: *const types.Terminal,
    row: *const types.Row,
    cell: *const types.Cell,
    col: c_int,
    context: ?*ExtractionContext,
) callconv(.c) bool;
extern fn extract_finish(
    context: ?*ExtractionContext,
    text: *?[*:0]u8,
    len: ?*usize,
) callconv(.c) bool;

// grid helper from grid.zig
extern fn grid_row_abs_to_sb(grid: *const types.Grid, screen_rows: c_int, abs_row: c_int) callconv(.c) c_int;
extern fn grid_row_abs_to_sb_precalc_sb_start(
    grid: *const types.Grid,
    sb_start: c_int,
    abs_row: c_int,
) callconv(.c) c_int;

// selection_cancel: ported later (chunk C), forward-declare
extern fn selection_cancel(term: *types.Terminal) callconv(.c) void;

// ── bounded ──────────────────────────────────────────────────────
fn bounded(grid: *const types.Grid, coord_in: types.Coord) types.Coord {
    var coord = coord_in;
    coord.row &= grid.num_rows - 1;
    return coord;
}

// ── selection_get_start / end ────────────────────────────────────
export fn selection_get_start(term: *const types.Terminal) callconv(.c) types.Coord {
    if (term.selection.coords.start.row < 0) return term.selection.coords.start;
    return bounded(term.grid.?, term.selection.coords.start);
}

export fn selection_get_end(term: *const types.Terminal) callconv(.c) types.Coord {
    if (term.selection.coords.end.row < 0) return term.selection.coords.end;
    return bounded(term.grid.?, term.selection.coords.end);
}

// ── selection_on_rows ────────────────────────────────────────────
export fn selection_on_rows(term: *const types.Terminal, row_start_in: c_int, row_end_in: c_int) callconv(.c) bool {
    var row_start = row_start_in;
    var row_end = row_end_in;

    row_start += term.grid.?.offset;
    row_end += term.grid.?.offset;

    const start = &term.selection.coords.start;
    const end = &term.selection.coords.end;

    const grid = term.grid.?;
    const sb_start: c_int = grid.offset + term.rows;

    const rel_row_start = grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, row_start);
    const rel_row_end = grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, row_end);
    var rel_sel_start = grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, start.row);
    var rel_sel_end = grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, end.row);

    if (rel_sel_start > rel_sel_end) {
        const tmp = rel_sel_start;
        rel_sel_start = rel_sel_end;
        rel_sel_end = tmp;
    }

    if ((rel_row_start <= rel_sel_start and rel_row_end >= rel_sel_start) or
        (rel_row_start <= rel_sel_end and rel_row_end >= rel_sel_end))
    {
        return true;
    }

    if (rel_row_start >= rel_sel_start and rel_row_end <= rel_sel_end) {
        return true;
    }

    return false;
}

// ── scroll / view ────────────────────────────────────────────────
export fn selection_scroll_up(term: *types.Terminal, rows: c_int) callconv(.c) void {
    const rel_row_start = grid_row_abs_to_sb(term.grid.?, term.rows, term.selection.coords.start.row);
    const rel_row_end = grid_row_abs_to_sb(term.grid.?, term.rows, term.selection.coords.end.row);
    const actual_start = @min(rel_row_start, rel_row_end);

    if (actual_start - rows < 0) {
        selection_cancel(term);
    }
}

export fn selection_scroll_down(term: *types.Terminal, rows: c_int) callconv(.c) void {
    const grid = term.grid.?;
    const sel = &term.selection.coords;

    const screen_end = grid_row_abs_to_sb(grid, term.rows, grid.offset + term.rows - 1);
    const rel_row_start = grid_row_abs_to_sb(grid, term.rows, sel.start.row);
    const rel_row_end = grid_row_abs_to_sb(grid, term.rows, sel.end.row);
    const actual_end = @max(rel_row_start, rel_row_end);

    if (actual_end > screen_end - rows) {
        selection_cancel(term);
    }
}

export fn selection_view_up(term: *types.Terminal, new_view: c_int) callconv(.c) void {
    if (term.selection.coords.start.row < 0) return;
    if (new_view < term.grid.?.view) return;

    term.selection.coords.start.row += term.grid.?.num_rows;
    if (term.selection.coords.end.row >= 0) {
        term.selection.coords.end.row += term.grid.?.num_rows;
    }
}

export fn selection_view_down(term: *types.Terminal, new_view: c_int) callconv(.c) void {
    if (term.selection.coords.start.row < 0) return;
    if (new_view > term.grid.?.view) return;

    term.selection.coords.start.row &= term.grid.?.num_rows - 1;
    if (term.selection.coords.end.row >= 0) {
        term.selection.coords.end.row &= term.grid.?.num_rows - 1;
    }
}

// ── foreach_selected_* ───────────────────────────────────────────
const SelectedCb = *const fn (
    *types.Terminal,
    *types.Row,
    *types.Cell,
    c_int,
    c_int,
    ?*anyopaque,
) callconv(.c) bool;

fn foreach_selected_normal(
    term: *types.Terminal,
    start_coord: types.Coord,
    end_coord: types.Coord,
    cb: SelectedCb,
    data: ?*anyopaque,
) void {
    const grid = term.grid.?;
    const grid_rows: c_int = grid.num_rows;

    const rel_start_row = grid_row_abs_to_sb(grid, term.rows, start_coord.row);
    const rel_end_row = grid_row_abs_to_sb(grid, term.rows, end_coord.row);

    var start_row: c_int = undefined;
    var end_row: c_int = undefined;
    var start_col: c_int = undefined;
    var end_col: c_int = undefined;

    if (rel_start_row < rel_end_row) {
        start_row = start_coord.row;
        start_col = start_coord.col;
        end_row = end_coord.row;
        end_col = end_coord.col;
    } else if (rel_start_row > rel_end_row) {
        start_row = end_coord.row;
        start_col = end_coord.col;
        end_row = start_coord.row;
        end_col = start_coord.col;
    } else {
        start_row = start_coord.row;
        end_row = start_coord.row;
        start_col = @min(start_coord.col, end_coord.col);
        end_col = @max(start_coord.col, end_coord.col);
    }

    start_row &= (grid_rows - 1);
    end_row &= (grid_rows - 1);

    var r: c_int = start_row;
    while (r != end_row) : (r = (r + 1) & (grid_rows - 1)) {
        const row = grid.rows.?[@intCast(r)] orelse continue;

        var c: c_int = start_col;
        while (c <= term.cols - 1) : (c += 1) {
            if (!cb(term, row, &row.cells.?[@intCast(c)], r, c, data)) return;
        }
        start_col = 0;
    }

    const last_row = grid.rows.?[@intCast(end_row)] orelse return;
    var c: c_int = start_col;
    while (c <= end_col) : (c += 1) {
        if (!cb(term, last_row, &last_row.cells.?[@intCast(c)], end_row, c, data)) return;
    }
}

fn foreach_selected_block(
    term: *types.Terminal,
    start_coord: types.Coord,
    end_coord: types.Coord,
    cb: SelectedCb,
    data: ?*anyopaque,
) void {
    const grid = term.grid.?;
    const grid_rows: c_int = grid.num_rows;

    const rel_start_row = grid_row_abs_to_sb(grid, term.rows, start_coord.row);
    const rel_end_row = grid_row_abs_to_sb(grid, term.rows, end_coord.row);

    const top_left: types.Coord = .{
        .row = (if (rel_start_row < rel_end_row) start_coord.row else end_coord.row) & (grid_rows - 1),
        .col = @min(start_coord.col, end_coord.col),
    };
    const bottom_right: types.Coord = .{
        .row = (if (rel_start_row > rel_end_row) start_coord.row else end_coord.row) & (grid_rows - 1),
        .col = @max(start_coord.col, end_coord.col),
    };

    var r: c_int = top_left.row;
    while (true) {
        const row = grid.rows.?[@intCast(r)] orelse return;

        var c: c_int = top_left.col;
        while (c <= bottom_right.col) : (c += 1) {
            if (!cb(term, row, &row.cells.?[@intCast(c)], r, c, data)) return;
        }

        if (r == bottom_right.row) break;

        r += 1;
        r &= grid_rows - 1;
    }
}

export fn foreach_selected(
    term: *types.Terminal,
    start_coord: types.Coord,
    end_coord: types.Coord,
    cb: SelectedCb,
    data: ?*anyopaque,
) callconv(.c) void {
    switch (term.selection.kind) {
        .char_wise, .word_wise, .quote_wise, .line_wise => {
            foreach_selected_normal(term, start_coord, end_coord, cb, data);
        },
        .block => {
            foreach_selected_block(term, start_coord, end_coord, cb, data);
        },
        .none => {},
    }
}

// ── extract_one_const_wrapper ────────────────────────────────────
export fn extract_one_const_wrapper(
    term: *types.Terminal,
    row: *types.Row,
    cell: *types.Cell,
    row_no: c_int,
    col: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = row_no;
    return extract_one(
        term,
        row,
        cell,
        col,
        @ptrCast(@alignCast(data)),
    );
}

// ── selection_to_text ────────────────────────────────────────────
export fn selection_to_text(term: *const types.Terminal) callconv(.c) ?[*:0]u8 {
    if (term.selection.coords.end.row == -1) return null;

    const ctx = extract_begin(term.selection.kind, true) orelse return null;

    const mutable_term: *types.Terminal = @ptrCast(@constCast(term));
    foreach_selected(
        mutable_term,
        term.selection.coords.start,
        term.selection.coords.end,
        &extract_one_const_wrapper,
        @ptrCast(@alignCast(ctx)),
    );

    var text: ?[*:0]u8 = null;
    const ok = extract_finish(ctx, &text, null);
    return if (ok) text else null;
}
