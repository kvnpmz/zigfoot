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
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
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

// ── Chunk B: word/quote/line boundary finders ────────────────────
// Ports selection.c lines 74-395.

extern fn selection_conf_word_delimiters(term: *const types.Terminal) callconv(.c) ?[*]const u32;
extern fn selection_grid_row_in_view(grid: *types.Grid, row_no: c_int) callconv(.c) ?*types.Row;

export fn selection_find_word_boundary_left(
    term: *const types.Terminal,
    pos: *types.Coord,
    spaces_only: bool,
) callconv(.c) void {
    const grid = term.grid.?;

    pos.row &= grid.num_rows - 1;

    const delims = selection_conf_word_delimiters(term);

    const r = grid.rows.?[@intCast(pos.row)] orelse return;
    var c: u32 = r.cells.?[@intCast(pos.col)].wc;

    while (c >= CELL_SPACER) {
        if (pos.col == 0) return;
        pos.col -= 1;
        c = r.cells.?[@intCast(pos.col)].wc;
    }

    if (c >= CELL_COMB_CHARS_LO and c <= CELL_COMB_CHARS_HI) {
        const comp = composed_lookup(term.composed, c - CELL_COMB_CHARS_LO);
        if (comp) |cp| {
            c = cp.chars.?[0];
        }
    }

    const initial_is_space: bool = c == 0 or isc32space(c);
    const initial_is_delim: bool =
        !initial_is_space and !isword(c, spaces_only, delims);
    const initial_is_word: bool =
        c != 0 and isword(c, spaces_only, delims);

    while (true) {
        var next_col: c_int = pos.col - 1;
        var next_row: c_int = pos.row;

        var row = grid.rows.?[@intCast(next_row)] orelse return;

        // Linewrap
        if (next_col < 0) {
            next_col = term.cols - 1;
            next_row = (next_row - 1 + grid.num_rows) & (grid.num_rows - 1);

            if (grid_row_abs_to_sb(grid, term.rows, next_row) == term.grid.?.num_rows - 1 or
                grid.rows.?[@intCast(next_row)] == null)
            {
                break;
            }

            row = grid.rows.?[@intCast(next_row)] orelse return;

            if (row.linebreak) break;
        }

        c = row.cells.?[@intCast(next_col)].wc;
        while (c >= CELL_SPACER) {
            next_col -= 1;
            if (next_col < 0) return;
            c = row.cells.?[@intCast(next_col)].wc;
        }

        if (c >= CELL_COMB_CHARS_LO and c <= CELL_COMB_CHARS_HI) {
            const comp = composed_lookup(term.composed, c - CELL_COMB_CHARS_LO);
            if (comp) |cp| {
                c = cp.chars.?[0];
            }
        }

        const is_space: bool = c == 0 or isc32space(c);
        const is_delim: bool = !is_space and !isword(c, spaces_only, delims);
        const is_word: bool = c != 0 and isword(c, spaces_only, delims);

        if (initial_is_space and !is_space) break;
        if (initial_is_delim and !is_delim) break;
        if (initial_is_word and !is_word) break;

        pos.col = next_col;
        pos.row = next_row;
    }
}

export fn selection_find_word_boundary_right(
    term: *const types.Terminal,
    pos: *types.Coord,
    spaces_only: bool,
    stop_on_space_to_word_boundary: bool,
) callconv(.c) void {
    const grid = term.grid.?;

    pos.row &= grid.num_rows - 1;

    const delims = selection_conf_word_delimiters(term);

    const r = grid.rows.?[@intCast(pos.row)] orelse return;
    var c: u32 = r.cells.?[@intCast(pos.col)].wc;

    while (c >= CELL_SPACER) {
        if (pos.col == 0) return;
        pos.col -= 1;
        c = r.cells.?[@intCast(pos.col)].wc;
    }

    if (c >= CELL_COMB_CHARS_LO and c <= CELL_COMB_CHARS_HI) {
        const comp = composed_lookup(term.composed, c - CELL_COMB_CHARS_LO);
        if (comp) |cp| {
            c = cp.chars.?[0];
        }
    }

    const initial_is_space: bool = c == 0 or isc32space(c);
    const initial_is_delim: bool =
        !initial_is_space and !isword(c, spaces_only, delims);
    const initial_is_word: bool =
        c != 0 and isword(c, spaces_only, delims);
    var have_seen_word: bool = initial_is_word;

    while (true) {
        var next_col: c_int = pos.col;
        var next_row: c_int = pos.row;

        var row = term.grid.?.rows.?[@intCast(next_row)] orelse return;

        while (true) {
            next_col += 1;
            if (next_col >= term.cols) {
                if (row.linebreak) return;

                next_col = 0;
                next_row = (next_row + 1) & (grid.num_rows - 1);

                if (grid_row_abs_to_sb(grid, term.rows, next_row) == 0) {
                    return;
                }
                row = grid.rows.?[@intCast(next_row)] orelse return;
            }

            c = row.cells.?[@intCast(next_col)].wc;
            if (c < CELL_SPACER) break;
        }

        if (c >= CELL_COMB_CHARS_LO and c <= CELL_COMB_CHARS_HI) {
            const comp = composed_lookup(term.composed, c - CELL_COMB_CHARS_LO);
            if (comp) |cp| {
                c = cp.chars.?[0];
            }
        }

        const is_space: bool = c == 0 or isc32space(c);
        const is_delim: bool = !is_space and !isword(c, spaces_only, delims);
        const is_word: bool = c != 0 and isword(c, spaces_only, delims);

        if (stop_on_space_to_word_boundary) {
            if (initial_is_space and !is_space) break;
            if (initial_is_delim and !is_delim) break;
        } else {
            if (initial_is_space and ((have_seen_word and is_space) or is_delim)) break;
            if (initial_is_delim and ((have_seen_word and is_delim) or is_space)) break;
        }
        if (initial_is_word and !is_word) break;

        have_seen_word = is_word;

        pos.col = next_col;
        pos.row = next_row;
    }
}

export fn selection_find_quote_left(
    term: *types.Terminal,
    pos: *types.Coord,
    quote_char: *u32,
) callconv(.c) bool {
    var row = selection_grid_row_in_view(term.grid.?, pos.row) orelse return false;
    var wc: u32 = row.cells.?[@intCast(pos.col)].wc;

    const is_quote = if (quote_char.* == 0)
        (wc == '"' or wc == '\'')
    else
        wc == quote_char.*;

    if (is_quote) return false;

    var next_row: c_int = pos.row;
    var next_col: c_int = pos.col;

    while (true) {
        next_col -= 1;
        if (next_col < 0) {
            next_col = term.cols - 1;
            next_row -= 1;
            if (next_row < 0) return false;

            row = selection_grid_row_in_view(term.grid.?, next_row) orelse return false;
            if (row.linebreak) return false;
        }

        wc = row.cells.?[@intCast(next_col)].wc;

        const matches = if (quote_char.* == 0)
            (wc == '"' or wc == '\'')
        else
            wc == quote_char.*;

        if (matches) {
            if (next_col + 1 == term.cols) {
                pos.row = next_row + 1;
                pos.col = 0;
            } else {
                pos.row = next_row;
                pos.col = next_col + 1;
            }
            quote_char.* = wc;
            return true;
        }
    }
}

export fn selection_find_quote_right(
    term: *types.Terminal,
    pos: *types.Coord,
    quote_char: u32,
) callconv(.c) bool {
    if (quote_char == 0) return false;

    var row = selection_grid_row_in_view(term.grid.?, pos.row) orelse return false;
    var wc: u32 = row.cells.?[@intCast(pos.col)].wc;
    if (wc == quote_char) return false;

    var next_row: c_int = pos.row;
    var next_col: c_int = pos.col;

    while (true) {
        next_col += 1;
        if (next_col >= term.cols) {
            next_col = 0;
            next_row += 1;
            if (next_row >= term.rows) return false;

            if (row.linebreak) return false;

            row = selection_grid_row_in_view(term.grid.?, next_row) orelse return false;
        }

        wc = row.cells.?[@intCast(next_col)].wc;
        if (wc == quote_char) {
            if (next_col == 0) {
                pos.row = next_row - 1;
                pos.col = term.cols - 1;
            } else {
                pos.row = next_row;
                pos.col = next_col - 1;
            }
            return true;
        }
    }
}

export fn selection_find_line_boundary_left(term: *types.Terminal, pos: *types.Coord) callconv(.c) void {
    var next_row: c_int = pos.row;
    pos.col = 0;

    while (true) {
        next_row -= 1;
        if (next_row < 0) return;

        const row = selection_grid_row_in_view(term.grid.?, next_row) orelse return;
        if (row.linebreak) return;

        pos.col = 0;
        pos.row = next_row;
    }
}

export fn selection_find_line_boundary_right(term: *types.Terminal, pos: *types.Coord) callconv(.c) void {
    var next_row: c_int = pos.row;
    pos.col = term.cols - 1;

    while (true) {
        const row = selection_grid_row_in_view(term.grid.?, next_row) orelse return;
        if (row.linebreak) return;

        next_row += 1;
        if (next_row >= term.rows) return;

        pos.col = term.cols - 1;
        pos.row = next_row;
    }
}

// ── Chunk C1: selection_start ────────────────────────────────────
// Ports selection.c lines 89-212.


export fn selection_start(
    term: *types.Terminal,
    col: c_int,
    row: c_int,
    kind: types.SelectionKind,
    spaces_only: bool,
) callconv(.c) void {
    selection_cancel(term);

    term.selection.kind = kind;
    term.selection.ongoing = true;
    term.selection.spaces_only = spaces_only;

    switch (kind) {
        .char_wise, .block => {
            term.selection.coords.start = .{ .col = col, .row = term.grid.?.view + row };
            term.selection.coords.end = .{ .col = -1, .row = -1 };

            term.selection.pivot.start = term.selection.coords.start;
            term.selection.pivot.end = term.selection.coords.end;
        },
        .word_wise => {
            var start: types.Coord = .{ .col = col, .row = term.grid.?.view + row };
            var end: types.Coord = .{ .col = col, .row = term.grid.?.view + row };
            selection_find_word_boundary_left(term, &start, spaces_only);
            selection_find_word_boundary_right(term, &end, spaces_only, true);

            term.selection.coords.start = start;
            term.selection.pivot.start = term.selection.coords.start;
            term.selection.pivot.end = end;

            selection_update(term, end.col, end.row - term.grid.?.view);
        },
        .quote_wise => {
            var start: types.Coord = .{ .col = col, .row = row };
            var end: types.Coord = .{ .col = col, .row = row };

            var quote_char: u32 = 0;
            var found_left = selection_find_quote_left(term, &start, &quote_char);
            var found_right = selection_find_quote_right(term, &end, quote_char);

            if (found_left and !found_right) {
                if (quote_char == '\'') {
                    quote_char = '"';
                } else if (quote_char == '"') {
                    quote_char = '\'';
                }

                found_left = selection_find_quote_left(term, &start, &quote_char);
                found_right = selection_find_quote_right(term, &end, quote_char);
            }

            if (found_left and found_right) {
                term.selection.coords.start = .{
                    .col = start.col,
                    .row = term.grid.?.view + start.row,
                };
                term.selection.pivot.start = term.selection.coords.start;
                term.selection.pivot.end = .{
                    .col = end.col,
                    .row = term.grid.?.view + end.row,
                };
                term.selection.kind = .word_wise;
                selection_update(term, end.col, end.row);
                return;
            }
            // Fallthrough to line_wise
            term.selection.kind = .line_wise;
            chunkC1_line_wise(term, row);
        },
        .line_wise => {
            chunkC1_line_wise(term, row);
        },
        .none => {},
    }
}

fn chunkC1_line_wise(term: *types.Terminal, row: c_int) void {
    var start: types.Coord = .{ .col = 0, .row = row };
    var end: types.Coord = .{ .col = term.cols - 1, .row = row };
    selection_find_line_boundary_left(term, &start);
    selection_find_line_boundary_right(term, &end);

    term.selection.coords.start = .{
        .col = start.col,
        .row = term.grid.?.view + start.row,
    };
    term.selection.pivot.start = term.selection.coords.start;
    term.selection.pivot.end = .{
        .col = end.col,
        .row = term.grid.?.view + end.row,
    };

    selection_update(term, end.col, end.row);
}

// ── Chunk C2: pixman_region_for_coords_* + mark_selected_region ──
// Ports selection.c lines 214-433.

const PixmanBox32 = extern struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
};
const PixmanRegion32 = extern struct {
    extents: PixmanBox32,
    data: ?*anyopaque,
};

extern fn pixman_region32_init(region: *PixmanRegion32) callconv(.c) void;
extern fn pixman_region32_union_rect(
    new_reg: *PixmanRegion32,
    reg: *const PixmanRegion32,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
) callconv(.c) c_int;
extern fn grid_row_sb_to_abs(grid: *const types.Grid, screen_rows: c_int, sb_rel_row: c_int) callconv(.c) c_int;

fn pixman_region_for_coords_normal(
    term: *const types.Terminal,
    start: *const types.Coord,
    end: *const types.Coord,
) PixmanRegion32 {
    var region: PixmanRegion32 = undefined;
    pixman_region32_init(&region);

    const rel_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, start.row);
    const rel_end_row = grid_row_abs_to_sb(term.grid.?, term.rows, end.row);

    if (rel_start_row < rel_end_row) {
        if (term.cols > start.col) {
            _ = pixman_region32_union_rect(
                &region,
                &region,
                start.col,
                rel_start_row,
                @intCast(term.cols - start.col),
                1,
            );
        }
        if (rel_start_row + 1 < rel_end_row) {
            _ = pixman_region32_union_rect(
                &region,
                &region,
                0,
                rel_start_row + 1,
                @intCast(term.cols),
                @intCast(rel_end_row - rel_start_row - 1),
            );
        }
        _ = pixman_region32_union_rect(
            &region,
            &region,
            0,
            rel_end_row,
            @intCast(end.col + 1),
            1,
        );
    } else if (rel_start_row > rel_end_row) {
        if (term.cols > end.col) {
            _ = pixman_region32_union_rect(
                &region,
                &region,
                end.col,
                rel_end_row,
                @intCast(term.cols - end.col),
                1,
            );
        }
        if (rel_end_row + 1 < rel_start_row) {
            _ = pixman_region32_union_rect(
                &region,
                &region,
                0,
                rel_end_row + 1,
                @intCast(term.cols),
                @intCast(rel_start_row - rel_end_row - 1),
            );
        }
        _ = pixman_region32_union_rect(
            &region,
            &region,
            0,
            rel_start_row,
            @intCast(start.col + 1),
            1,
        );
    } else {
        const start_col = @min(start.col, end.col);
        const end_col = @max(start.col, end.col);
        _ = pixman_region32_union_rect(
            &region,
            &region,
            start_col,
            rel_start_row,
            @intCast(end_col + 1 - start_col),
            1,
        );
    }

    return region;
}

fn pixman_region_for_coords_block(
    term: *const types.Terminal,
    start: *const types.Coord,
    end: *const types.Coord,
) PixmanRegion32 {
    var region: PixmanRegion32 = undefined;
    pixman_region32_init(&region);

    const rel_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, start.row);
    const rel_end_row = grid_row_abs_to_sb(term.grid.?, term.rows, end.row);

    _ = pixman_region32_union_rect(
        &region,
        &region,
        @min(start.col, end.col),
        @min(rel_start_row, rel_end_row),
        @intCast(@abs(start.col - end.col) + 1),
        @intCast(@abs(rel_start_row - rel_end_row) + 1),
    );

    return region;
}

export fn pixman_region_for_coords(
    term: *const types.Terminal,
    start: *const types.Coord,
    end: *const types.Coord,
) callconv(.c) PixmanRegion32 {
    return switch (term.selection.kind) {
        .block => pixman_region_for_coords_block(term, start, end),
        else => pixman_region_for_coords_normal(term, start, end),
    };
}

const MarkSelectionVariant = enum(c_int) {
    mark_and_dirty = 0,
    unmark_and_dirty = 1,
    mark_for_render = 2,
};

export fn mark_selected_region(
    term: *types.Terminal,
    boxes: [*]PixmanBox32,
    count: usize,
    mark_variant: MarkSelectionVariant,
) callconv(.c) void {
    const selected = mark_variant == .mark_and_dirty or mark_variant == .mark_for_render;
    const dirty_cells = mark_variant == .mark_and_dirty or mark_variant == .unmark_and_dirty;
    const highlight_empty =
        mark_variant != .mark_for_render or term.selection.kind == .block;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const box = &boxes[i];
        const grid = term.grid.?;

        const abs_row_start = grid_row_sb_to_abs(grid, term.rows, box.y1);

        var r: c_int = abs_row_start;
        var rel_r: c_int = box.y1;
        while (rel_r < box.y2) : ({
            r = (r + 1) & (grid.num_rows - 1);
            rel_r += 1;
        }) {
            const row = grid.rows.?[@intCast(r)] orelse continue;

            if (dirty_cells) row.dirty = true;

            var c: c_int = box.x1;
            var empty_count: c_int = 0;
            while (c < box.x2) : (c += 1) {
                const cell = &row.cells.?[@intCast(c)];

                if ((cell.wc == 0 or cell.wc == CELL_SPACER) and !highlight_empty) {
                    empty_count += 1;
                    cell.attrs.clean = false;
                    cell.attrs.selected = false;
                    row.dirty = true;
                    continue;
                }

                var j: c_int = 0;
                while (j < empty_count + 1) : (j += 1) {
                    const ecell = &row.cells.?[@intCast(c - j)];
                    if (dirty_cells) {
                        ecell.attrs.clean = false;
                        row.dirty = true;
                    }
                    ecell.attrs.selected = selected;
                }
                empty_count = 0;
            }
        }
    }
}

// ── Chunk C3: selection_modify + set_pivot + selection_update ────
// Ports selection.c lines 435-734.

extern fn pixman_region32_subtract(
    reg_d: *PixmanRegion32,
    reg_m: *const PixmanRegion32,
    reg_s: *const PixmanRegion32,
) callconv(.c) c_int;
extern fn pixman_region32_intersect(
    new_reg: *PixmanRegion32,
    reg1: *const PixmanRegion32,
    reg2: *const PixmanRegion32,
) callconv(.c) c_int;
extern fn pixman_region32_fini(region: *PixmanRegion32) callconv(.c) void;
extern fn pixman_region32_rectangles(
    region: *const PixmanRegion32,
    n_rects: *c_int,
) callconv(.c) [*]PixmanBox32;
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;

export fn selection_modify(
    term: *types.Terminal,
    start: types.Coord,
    end: types.Coord,
) callconv(.c) void {
    var previous_selection: PixmanRegion32 = undefined;
    if (term.selection.coords.end.row >= 0) {
        previous_selection = pixman_region_for_coords(
            term,
            &term.selection.coords.start,
            &term.selection.coords.end,
        );
    } else {
        pixman_region32_init(&previous_selection);
    }

    var current_selection = pixman_region_for_coords(term, &start, &end);

    var no_longer_selected: PixmanRegion32 = undefined;
    pixman_region32_init(&no_longer_selected);
    _ = pixman_region32_subtract(&no_longer_selected, &previous_selection, &current_selection);

    var newly_selected: PixmanRegion32 = undefined;
    pixman_region32_init(&newly_selected);
    _ = pixman_region32_subtract(&newly_selected, &current_selection, &previous_selection);

    var n_rects: c_int = -1;
    var boxes = pixman_region32_rectangles(&no_longer_selected, &n_rects);
    mark_selected_region(term, boxes, @intCast(n_rects), .unmark_and_dirty);

    boxes = pixman_region32_rectangles(&newly_selected, &n_rects);
    mark_selected_region(term, boxes, @intCast(n_rects), .mark_and_dirty);

    pixman_region32_fini(&newly_selected);
    pixman_region32_fini(&no_longer_selected);
    pixman_region32_fini(&current_selection);
    pixman_region32_fini(&previous_selection);

    term.selection.coords.start = start;
    term.selection.coords.end = end;
    render_refresh(term);
}

export fn set_pivot_point_for_block_and_char_wise(
    term: *types.Terminal,
    start: types.Coord,
    new_direction: types.SelectionDirection,
) callconv(.c) void {
    const pivot_start = &term.selection.pivot.start;
    const pivot_end = &term.selection.pivot.end;

    pivot_start.* = start;

    while (true) {
        const grid = term.grid.?;
        const r = grid.rows.?[@intCast(pivot_start.row & (grid.num_rows - 1))] orelse break;
        const c = r.cells.?[@intCast(pivot_start.col)];

        if (c.wc < CELL_SPACER) break;

        if (pivot_start.col == 0) break;
        pivot_start.col -= 1;
    }

    pivot_end.* = pivot_start.*;

    if (new_direction == .right) {
        var keep_going = true;
        while (keep_going) {
            const grid = term.grid.?;
            const r = grid.rows.?[@intCast(pivot_end.row & (grid.num_rows - 1))] orelse break;
            const wc: u32 = r.cells.?[@intCast(pivot_end.col)].wc;

            keep_going = wc >= CELL_SPACER;

            if (pivot_end.col == 0) {
                if (pivot_end.row - term.grid.?.view <= 0) break;
                pivot_end.col = term.cols - 1;
                pivot_end.row -= 1;
            } else {
                pivot_end.col -= 1;
            }
        }
    } else {
        var keep_going = true;
        while (keep_going) {
            const grid = term.grid.?;
            const r = grid.rows.?[@intCast(pivot_start.row & (grid.num_rows - 1))] orelse break;
            const wc: u32 = if (pivot_start.col < term.cols - 1)
                r.cells.?[@intCast(pivot_start.col + 1)].wc
            else
                0;

            keep_going = wc >= CELL_SPACER;

            if (pivot_start.col >= term.cols - 1) {
                if (pivot_start.row - term.grid.?.view >= term.rows - 1) break;
                pivot_start.col = 0;
                pivot_start.row += 1;
            } else {
                pivot_start.col += 1;
            }
        }
    }
}

export fn selection_update(
    term: *types.Terminal,
    col: c_int,
    row: c_int,
) callconv(.c) void {
    if (term.selection.coords.start.row < 0) return;
    if (!term.selection.ongoing) return;

    var new_start = term.selection.coords.start;
    var new_end: types.Coord = .{ .col = col, .row = term.grid.?.view + row };

    if (!(new_end.row == new_start.row and new_end.col == new_start.col)) {
        var new_direction = term.selection.direction;

        const pivot_start = &term.selection.pivot.start;
        const pivot_end = &term.selection.pivot.end;

        if (term.selection.kind == .block) {
            if (new_end.col >= pivot_start.col) {
                new_direction = .right;
            } else {
                new_direction = .left;
            }

            if (term.selection.direction == .undir) {
                set_pivot_point_for_block_and_char_wise(term, pivot_start.*, new_direction);
            }

            if (new_direction == .left) {
                new_start = pivot_end.*;
            } else {
                new_start = pivot_start.*;
            }
            term.selection.direction = new_direction;
        } else {
            if (new_end.row < pivot_start.row or
                (new_end.row == pivot_start.row and new_end.col < pivot_start.col))
            {
                new_direction = .left;
            } else {
                new_direction = .right;
            }

            if (term.selection.direction != new_direction) {
                if (term.selection.direction == .undir and pivot_end.row < 0) {
                    set_pivot_point_for_block_and_char_wise(term, pivot_start.*, new_direction);
                }

                if (new_direction == .left) {
                    new_start = pivot_end.*;
                } else {
                    new_start = pivot_start.*;
                }
                term.selection.direction = new_direction;
            }
        }
    }

    switch (term.selection.kind) {
        .char_wise, .block => {},
        .word_wise => {
            switch (term.selection.direction) {
                .left => {
                    new_end = .{ .col = col, .row = term.grid.?.view + row };
                    selection_find_word_boundary_left(term, &new_end, term.selection.spaces_only);
                },
                .right => {
                    new_end = .{ .col = col, .row = term.grid.?.view + row };
                    selection_find_word_boundary_right(term, &new_end, term.selection.spaces_only, true);
                },
                .undir => {},
            }
        },
        .quote_wise => {},
        .line_wise => {
            switch (term.selection.direction) {
                .left => {
                    var end: types.Coord = .{ .col = 0, .row = row };
                    selection_find_line_boundary_left(term, &end);
                    new_end = .{ .col = end.col, .row = term.grid.?.view + end.row };
                },
                .right => {
                    var end: types.Coord = .{ .col = col, .row = row };
                    selection_find_line_boundary_right(term, &end);
                    new_end = .{ .col = end.col, .row = term.grid.?.view + end.row };
                },
                .undir => {},
            }
        },
        .none => {},
    }

    const grid = term.grid.?;
    const start_row_idx: usize = @intCast(new_start.row & (grid.num_rows - 1));
    const end_row_idx: usize = @intCast(new_end.row & (grid.num_rows - 1));

    const row_start = grid.rows.?[start_row_idx] orelse return;
    const row_end = grid.rows.?[end_row_idx] orelse return;

    // Pull CELL_SPACER start/end back into the multi-cell char
    while (row_start.cells.?[@intCast(new_start.col)].wc == CELL_SPACER) {
        new_start.col -= 1;
    }
    while (row_end.cells.?[@intCast(new_end.col)].wc == CELL_SPACER) {
        new_end.col -= 1;
    }

    if (new_start.row < new_end.row or
        (new_start.row == new_end.row and new_start.col <= new_end.col))
    {
        while (new_start.col >= 1 and
            row_start.cells.?[@intCast(new_start.col)].wc >= CELL_SPACER)
        {
            new_start.col -= 1;
        }
        while (new_end.col < term.cols - 1 and
            row_end.cells.?[@intCast(new_end.col + 1)].wc > CELL_SPACER)
        {
            new_end.col += 1;
        }
    } else {
        while (new_end.col >= 1 and
            row_end.cells.?[@intCast(new_end.col)].wc >= CELL_SPACER)
        {
            new_end.col -= 1;
        }
        while (new_start.col < term.cols - 1 and
            row_start.cells.?[@intCast(new_start.col + 1)].wc > CELL_SPACER)
        {
            new_start.col += 1;
        }
    }

    selection_modify(term, new_start, new_end);
}

// ── Chunk C4: dirty_cells + extend_* + extend + finalize + cancel + has_data ──
// Ports selection.c lines 736-1070.

extern fn selection_stop_scroll_timer(term: *types.Terminal) callconv(.c) void;
extern fn search_selection_cancelled(term: *types.Terminal) callconv(.c) void;

extern fn selection_seat_clipboard_data_offer(seat: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn selection_seat_primary_data_offer(seat: ?*const anyopaque) callconv(.c) ?*anyopaque;

// SelectionTarget enum values (from config.h: SELECTION_TARGET_NONE=0, PRIMARY=1, CLIPBOARD=2, BOTH=3)
extern fn selection_conf_selection_target(term: *const types.Terminal) callconv(.c) c_int;

export fn selection_dirty_cells(term: *types.Terminal) callconv(.c) void {
    if (term.selection.coords.start.row < 0 or term.selection.coords.end.row < 0) return;

    var selection_region = pixman_region_for_coords(
        term,
        &term.selection.coords.start,
        &term.selection.coords.end,
    );

    var view_start: types.Coord = .{ .col = 0, .row = term.grid.?.view };
    var view_end: types.Coord = .{ .col = term.cols - 1, .row = term.grid.?.view + term.rows - 1 };
    var view_region = pixman_region_for_coords(term, &view_start, &view_end);

    var visible_and_selected: PixmanRegion32 = undefined;
    pixman_region32_init(&visible_and_selected);
    _ = pixman_region32_intersect(&visible_and_selected, &selection_region, &view_region);

    var n_rects: c_int = -1;
    const boxes = pixman_region32_rectangles(&visible_and_selected, &n_rects);
    mark_selected_region(term, boxes, @intCast(n_rects), .mark_for_render);

    pixman_region32_fini(&visible_and_selected);
    pixman_region32_fini(&view_region);
    pixman_region32_fini(&selection_region);
}

fn selection_extend_normal(
    term: *types.Terminal,
    col: c_int,
    row: c_int,
    new_kind: types.SelectionKind,
) void {
    var start: *types.Coord = &term.selection.coords.start;
    var end: *types.Coord = &term.selection.coords.end;

    const rel_row = grid_row_abs_to_sb(term.grid.?, term.rows, row);
    var rel_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, start.row);
    var rel_end_row = grid_row_abs_to_sb(term.grid.?, term.rows, end.row);

    if (rel_start_row > rel_end_row or
        (rel_start_row == rel_end_row and start.col > end.col))
    {
        const tmp = start;
        start = end;
        end = tmp;

        const tmp_row = rel_start_row;
        rel_start_row = rel_end_row;
        rel_end_row = tmp_row;
    }

    var new_start: types.Coord = undefined;
    var new_end: types.Coord = undefined;
    var direction: types.SelectionDirection = undefined;

    if (rel_row < rel_start_row or
        (rel_row == rel_start_row and col < start.col))
    {
        new_start = end.*;
        new_end = .{ .col = col, .row = row };
        direction = .left;
    } else if (rel_row > rel_end_row or
        (rel_row == rel_end_row and col > end.col))
    {
        new_start = start.*;
        new_end = .{ .col = col, .row = row };
        direction = .right;
    } else {
        const linear = rel_row * term.cols + col;
        if (@abs(linear - (rel_start_row * term.cols + start.col)) <
            @abs(linear - (rel_end_row * term.cols + end.col)))
        {
            new_start = end.*;
            new_end = .{ .col = col, .row = row };
            direction = .left;
        } else {
            new_start = start.*;
            new_end = .{ .col = col, .row = row };
            direction = .right;
        }
    }

    const spaces_only = term.selection.spaces_only;

    switch (term.selection.kind) {
        .char_wise => {
            set_pivot_point_for_block_and_char_wise(term, new_start, direction);
        },
        .word_wise => {
            var pivot_start: types.Coord = .{ .col = new_start.col, .row = new_start.row };
            var pivot_end: types.Coord = pivot_start;
            selection_find_word_boundary_left(term, &pivot_start, spaces_only);
            selection_find_word_boundary_right(term, &pivot_end, spaces_only, true);
            term.selection.pivot.start = pivot_start;
            term.selection.pivot.end = pivot_end;
        },
        .quote_wise => {},
        .line_wise => {
            var pivot_start: types.Coord = .{ .col = new_start.col, .row = new_start.row - term.grid.?.view };
            var pivot_end: types.Coord = pivot_start;
            selection_find_line_boundary_left(term, &pivot_start);
            selection_find_line_boundary_right(term, &pivot_end);
            term.selection.pivot.start = .{ .col = pivot_start.col, .row = term.grid.?.view + pivot_start.row };
            term.selection.pivot.end = .{ .col = pivot_end.col, .row = term.grid.?.view + pivot_end.row };
        },
        .block, .none => {},
    }

    term.selection.kind = new_kind;
    term.selection.direction = direction;
    selection_modify(term, new_start, new_end);
}

fn selection_extend_block(term: *types.Terminal, col: c_int, row: c_int) void {
    const start = &term.selection.coords.start;
    const end = &term.selection.coords.end;

    const rel_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, start.row);
    const rel_end_row = grid_row_abs_to_sb(term.grid.?, term.rows, end.row);

    const top_left: types.Coord = .{
        .row = if (rel_start_row < rel_end_row) start.row else end.row,
        .col = @min(start.col, end.col),
    };
    const top_right: types.Coord = .{
        .row = top_left.row,
        .col = @max(start.col, end.col),
    };
    const bottom_left: types.Coord = .{
        .row = if (rel_start_row > rel_end_row) start.row else end.row,
        .col = @min(start.col, end.col),
    };
    const bottom_right: types.Coord = .{
        .row = bottom_left.row,
        .col = @max(start.col, end.col),
    };

    const rel_row = grid_row_abs_to_sb(term.grid.?, term.rows, row);
    const rel_top_row = grid_row_abs_to_sb(term.grid.?, term.rows, top_left.row);
    const rel_bottom_row = grid_row_abs_to_sb(term.grid.?, term.rows, bottom_left.row);

    var new_start: types.Coord = undefined;
    var new_end: types.Coord = undefined;

    if (rel_row <= rel_top_row or
        @abs(rel_row - rel_top_row) < @abs(rel_row - rel_bottom_row))
    {
        if (@abs(col - top_left.col) < @abs(col - top_right.col)) {
            new_start = bottom_right;
            new_end = .{ .col = col, .row = row };
        } else {
            new_start = bottom_left;
            new_end = .{ .col = col, .row = row };
        }
    } else {
        if (@abs(col - bottom_left.col) < @abs(col - bottom_right.col)) {
            new_start = top_right;
            new_end = .{ .col = col, .row = row };
        } else {
            new_start = top_left;
            new_end = .{ .col = col, .row = row };
        }
    }

    const direction: types.SelectionDirection = if (col > new_start.col) .right else .left;
    set_pivot_point_for_block_and_char_wise(term, new_start, direction);
    term.selection.direction = direction;
    selection_modify(term, new_start, new_end);
}

export fn selection_extend(
    seat: ?*anyopaque,
    term: *types.Terminal,
    col: c_int,
    row_in: c_int,
    new_kind: types.SelectionKind,
) callconv(.c) void {
    _ = seat;
    var row: c_int = row_in;

    if (term.selection.coords.start.row < 0 or term.selection.coords.end.row < 0) return;
    if (term.selection.kind == .block and new_kind != .block) return;

    term.selection.ongoing = true;
    row += term.grid.?.view;

    if ((row == term.selection.coords.start.row and col == term.selection.coords.start.col) or
        (row == term.selection.coords.end.row and col == term.selection.coords.end.col))
    {
        return;
    }

    switch (term.selection.kind) {
        .none => {},
        .char_wise, .word_wise, .quote_wise, .line_wise => {
            selection_extend_normal(term, col, row, new_kind);
        },
        .block => {
            selection_extend_block(term, col, row);
        },
    }
}

export fn selection_finalize(seat: ?*anyopaque, term: *types.Terminal, serial: u32) callconv(.c) void {
    if (!term.selection.ongoing) return;

    selection_stop_scroll_timer(term);
    term.selection.ongoing = false;

    if (term.selection.coords.start.row < 0 or term.selection.coords.end.row < 0) return;

    term.selection.coords.start.row &= term.grid.?.num_rows - 1;
    term.selection.coords.end.row &= term.grid.?.num_rows - 1;

    const target = selection_conf_selection_target(term);
    switch (target) {
        0 => {}, // SELECTION_TARGET_NONE
        1 => selection_to_primary(seat, term, serial),
        2 => selection_to_clipboard(seat, term, serial),
        3 => {
            selection_to_primary(seat, term, serial);
            selection_to_clipboard(seat, term, serial);
        },
        else => {},
    }
}

fn unmark_selected(
    term: *types.Terminal,
    row: *types.Row,
    cell: *types.Cell,
    row_no: c_int,
    col: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = term;
    _ = row_no;
    _ = col;
    _ = data;
    if (!cell.attrs.selected) return true;

    row.dirty = true;
    cell.attrs.selected = false;
    cell.attrs.clean = false;
    return true;
}

export fn selection_cancel(term: *types.Terminal) callconv(.c) void {
    selection_stop_scroll_timer(term);

    if (term.selection.coords.start.row >= 0 and term.selection.coords.end.row >= 0) {
        foreach_selected(
            term,
            term.selection.coords.start,
            term.selection.coords.end,
            &unmark_selected,
            null,
        );
        render_refresh(term);
    }

    term.selection.kind = .none;
    term.selection.coords.start = .{ .col = -1, .row = -1 };
    term.selection.coords.end = .{ .col = -1, .row = -1 };
    term.selection.pivot.start = .{ .col = -1, .row = -1 };
    term.selection.pivot.end = .{ .col = -1, .row = -1 };
    term.selection.direction = .undir;
    term.selection.ongoing = false;

    search_selection_cancelled(term);
}

export fn selection_clipboard_has_data(seat: ?*const anyopaque) callconv(.c) bool {
    return selection_seat_clipboard_data_offer(seat) != null;
}

export fn selection_primary_has_data(seat: ?*const anyopaque) callconv(.c) bool {
    return selection_seat_primary_data_offer(seat) != null;
}

// ── Chunk D: clipboard/primary send (manager fns) ────────────────
// The wayland wire protocol is delegated to selection-shim.c.
// Receive-side (text_from_*, selection_from_*) is chunk E and not
// ported yet — those stay C.

extern fn selection_shim_text_to_clipboard(
    seat: ?*anyopaque, term: *types.Terminal, text: ?[*:0]u8, serial: u32,
) callconv(.c) bool;
extern fn selection_shim_text_to_primary(
    seat: ?*anyopaque, term: *types.Terminal, text: ?[*:0]u8, serial: u32,
) callconv(.c) bool;

export fn text_to_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) callconv(.c) bool {
    return selection_shim_text_to_clipboard(seat, term, text, serial);
}

export fn text_to_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) callconv(.c) bool {
    return selection_shim_text_to_primary(seat, term, text, serial);
}

export fn selection_to_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    serial: u32,
) callconv(.c) void {
    if (term.selection.coords.start.row < 0 or term.selection.coords.end.row < 0) return;

    const text = selection_to_text(term);
    if (!text_to_clipboard(seat, term, text, serial)) {
        if (text) |t| free(@ptrCast(t));
    }
}

export fn selection_to_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
    serial: u32,
) callconv(.c) void {
    // C checks wl->primary_selection_device_manager == NULL; the shim also
    // does that check, so we defer the guard to it.
    const text = selection_to_text(term);
    if (!text_to_primary(seat, term, text, serial)) {
        if (text) |t| free(@ptrCast(t));
    }
}

// ── Chunk E: clipboard/primary receive (manager fns) ─────────────
// Wire + fdm machinery remains C (selection-shim.c / selection.c _c impls).

const ClipboardCb = *const fn (data: ?[*]u8, size: usize, user: ?*anyopaque) callconv(.c) void;
const ClipboardDone = *const fn (user: ?*anyopaque) callconv(.c) void;

extern fn selection_shim_text_from_clipboard(
    seat: ?*anyopaque, term: *types.Terminal, no_strip: bool,
    cb: ClipboardCb, done: ClipboardDone, user: ?*anyopaque,
) callconv(.c) void;
extern fn selection_shim_text_from_primary(
    seat: ?*anyopaque, term: *types.Terminal, no_strip: bool,
    cb: ClipboardCb, done: ClipboardDone, user: ?*anyopaque,
) callconv(.c) void;
extern fn selection_shim_selection_from_clipboard(
    seat: ?*anyopaque, term: *types.Terminal, serial: u32,
) callconv(.c) void;
extern fn selection_shim_selection_from_primary(
    seat: ?*anyopaque, term: *types.Terminal,
) callconv(.c) void;

export fn text_from_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) callconv(.c) void {
    selection_shim_text_from_clipboard(seat, term, no_strip, cb, done, user);
}

export fn text_from_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) callconv(.c) void {
    selection_shim_text_from_primary(seat, term, no_strip, cb, done, user);
}

export fn selection_from_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    serial: u32,
) callconv(.c) void {
    selection_shim_selection_from_clipboard(seat, term, serial);
}

export fn selection_from_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
) callconv(.c) void {
    selection_shim_selection_from_primary(seat, term);
}
