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

extern fn selection_update(term: *types.Terminal, col: c_int, row: c_int) callconv(.c) void;

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
