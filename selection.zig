const std = @import("std");
const types = @import("terminal_types.zig");

// The whole module is Zig: selection.c and selection-shim.c were deleted in
// D5d-b2; only the generated listener tables (wayland-shim.c) and the
// protocol request inlines (terminal-shim.c) are C.

// ── Chunk A: grid helpers + foreach_selected + selection_to_text ──
// Ports selection.c lines 33-345.

// Constants from terminal.h
const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

// isword: misc.zig (prototype in misc.h)
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

// extract: extract.zig (prototype in extract.h)
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

extern fn selection_grid_row_in_view(grid: *types.Grid, row_no: c_int) callconv(.c) ?*types.Row;

export fn selection_find_word_boundary_left(
    term: *const types.Terminal,
    pos: *types.Coord,
    spaces_only: bool,
) callconv(.c) void {
    const grid = term.grid.?;

    pos.row &= grid.num_rows - 1;

    const delims: ?[*]const u32 = @ptrCast(term.conf.?.word_delimiters);

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

    const delims: ?[*]const u32 = @ptrCast(term.conf.?.word_delimiters);

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

    // Compare rows in scrollback-relative space: absolute row numbers wrap
    // around the grid ring buffer, so comparing them directly misdetects the
    // selection direction when the view is scrolled (upstream fixes
    // "selection: fix row comparison in selection update").
    const rel_new_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, new_start.row);
    const rel_new_end_row = grid_row_abs_to_sb(term.grid.?, term.rows, new_end.row);

    if (!(rel_new_end_row == rel_new_start_row and new_end.col == new_start.col)) {
        var new_direction = term.selection.direction;

        const pivot_start = &term.selection.pivot.start;
        const pivot_end = &term.selection.pivot.end;
        const rel_pivot_start_row = grid_row_abs_to_sb(term.grid.?, term.rows, pivot_start.row);

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
            if (rel_new_end_row < rel_pivot_start_row or
                (rel_new_end_row == rel_pivot_start_row and new_end.col < pivot_start.col))
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

    // If an end point points into the pad area of a multi-cell character,
    // back off to the start of that character.
    while (row_start.cells.?[@intCast(new_start.col)].wc == CELL_SPACER) {
        new_start.col -= 1;
    }
    while (row_end.cells.?[@intCast(new_end.col)].wc == CELL_SPACER) {
        new_end.col -= 1;
    }

    // Whether the *start* is expanded depends on the selection direction,
    // not on a row/column ordering test (upstream fix for multi-cell chars).
    if (term.selection.direction != .left) {
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

extern fn search_selection_cancelled(term: *types.Terminal) callconv(.c) void;


// SelectionTarget enum values (from config.h: SELECTION_TARGET_NONE=0, PRIMARY=1, CLIPBOARD=2, BOTH=3)

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

    const target = @intFromEnum(term.conf.?.selection_target);
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
    const s: *const types.Seat = @ptrCast(@alignCast(seat orelse return false));
    return s.clipboard.data_offer != null;
}

export fn selection_primary_has_data(seat: ?*const anyopaque) callconv(.c) bool {
    const s: *const types.Seat = @ptrCast(@alignCast(seat orelse return false));
    return s.primary.data_offer != null;
}

// ── Chunk D: clipboard/primary send (manager fns) ────────────────
// The wire protocol is a set of generated static inlines; they live in
// terminal-shim.c as wayland_shim_* wrappers. All the logic is here.

const MIME_TYPES = [_][*:0]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "TEXT",
    "STRING",
    "UTF8_STRING",
};

fn textToClipboard(
    seat: *types.Seat,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) bool {
    if (text == null or text.?[0] == 0)
        return false;
    if (serial == 0)
        return false;

    const clipboard = &seat.clipboard;

    if (clipboard.data_source != null) {
        wayland_shim_data_device_set_selection(seat.data_device, null, clipboard.serial);
        wayland_shim_data_source_destroy(clipboard.data_source);
        freeSlice(clipboard.text);
        clipboard.data_source = null;
        clipboard.serial = 0;
        clipboard.text = null;
    }

    const wayl = term.wl orelse return false;
    // C dereferences data_device_manager unconditionally; guard instead.
    const manager = wayl.data_device_manager orelse return false;

    clipboard.data_source = wayland_shim_data_source_create(manager);
    if (clipboard.data_source == null) {
        log_msg(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to create clipboard data source",
        );
        return false;
    }

    clipboard.text = text;
    for (MIME_TYPES) |mime|
        wayland_shim_data_source_offer(clipboard.data_source, mime);

    wayland_shim_add_data_source_listener(clipboard.data_source, seat);
    wayland_shim_data_device_set_selection(seat.data_device, clipboard.data_source, serial);
    clipboard.serial = serial;
    return true;
}

fn textToPrimary(
    seat: *types.Seat,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) bool {
    if (text == null or text.?[0] == 0)
        return false;
    if (serial == 0)
        return false;

    const wayl = term.wl orelse return false;
    const manager = wayl.primary_selection_device_manager orelse return false;

    const primary = &seat.primary;

    if (primary.data_source != null) {
        wayland_shim_primary_device_set_selection(
            seat.primary_selection_device, null, primary.serial);
        wayland_shim_primary_selection_source_destroy(primary.data_source);
        freeSlice(primary.text);
        primary.data_source = null;
        primary.serial = 0;
        primary.text = null;
    }

    primary.data_source = wayland_shim_primary_source_create(manager);
    if (primary.data_source == null) {
        log_msg(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to create clipboard data source",
        );
        return false;
    }

    primary.text = text;
    for (MIME_TYPES) |mime|
        wayland_shim_primary_source_offer(primary.data_source, mime);

    wayland_shim_add_primary_source_listener(primary.data_source, seat);
    wayland_shim_primary_device_set_selection(
        seat.primary_selection_device, primary.data_source, serial);
    primary.serial = serial;
    return true;
}

export fn text_to_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) callconv(.c) bool {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return false));
    return textToClipboard(s, term, text, serial);
}

export fn text_to_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
    text: ?[*:0]u8,
    serial: u32,
) callconv(.c) bool {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return false));
    return textToPrimary(s, term, text, serial);
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
// The other client writes into a pipe; we read it through the FDM (chunk
// S2) and paste it into the terminal.

const ClipboardCb = *const fn (data: [*]u8, size: usize, user: ?*anyopaque) callconv(.c) void;
const ClipboardDone = *const fn (user: ?*anyopaque) callconv(.c) void;

fn mimeTypeName(mime_type: types.DataOfferMimeType) ?[*:0]const u8 {
    const idx = @intFromEnum(mime_type);
    if (idx < 0 or idx >= mime_type_map.len)
        return null;
    return mime_type_map[@intCast(idx)];
}

/// Pipe the offer's data into `cb`, then `done`. Asynchronous: the callbacks
/// run later, off the FDM.
fn textFromClipboard(
    seat: *types.Seat,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) void {
    const clipboard = &seat.clipboard;

    if (clipboard.data_offer == null or clipboard.mime_type == .unset) {
        done(user);
        return;
    }

    // Prepare a pipe the other client can write its selection to us
    var fds: [2]c_int = undefined;
    if (pipe2(&fds, O_CLOEXEC) == -1) {
        log_errno(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to create pipe");
        done(user);
        return;
    }

    const read_fd = fds[0];
    const write_fd = fds[1];

    // Give the write-end of the pipe to the other client
    wayland_shim_data_offer_receive(
        clipboard.data_offer, mimeTypeName(clipboard.mime_type).?, write_fd);

    // Don't keep our copy of the write-end open (or we'll never get EOF)
    _ = close(write_fd);

    begin_receive_clipboard(
        term, no_strip, read_fd, @intFromEnum(clipboard.mime_type), cb, done, user);
}

fn textFromPrimary(
    seat: *types.Seat,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) void {
    const wayl = term.wl orelse {
        done(user);
        return;
    };
    if (wayl.primary_selection_device_manager == null) {
        done(user);
        return;
    }

    const primary = &seat.primary;
    if (primary.data_offer == null or primary.mime_type == .unset) {
        done(user);
        return;
    }

    var fds: [2]c_int = undefined;
    if (pipe2(&fds, O_CLOEXEC) == -1) {
        log_errno(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to create pipe");
        done(user);
        return;
    }

    const read_fd = fds[0];
    const write_fd = fds[1];

    wayland_shim_primary_offer_receive(
        primary.data_offer, mimeTypeName(primary.mime_type).?, write_fd);

    _ = close(write_fd);

    begin_receive_clipboard(
        term, no_strip, read_fd, @intFromEnum(primary.mime_type), cb, done, user);
}

fn receiveOffer(data: [*]u8, size: usize, user: ?*anyopaque) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(user orelse return));
    std.debug.assert(term.is_sending_paste_data);
    term_paste_data_to_slave(term, data, size);
}

fn receiveOfferDone(user: ?*anyopaque) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(user orelse return));

    if (term.bracketed_paste)
        term_paste_data_to_slave(term, "\x1b[201~", 6);

    term.is_sending_paste_data = false;

    // Make sure we send any queued up non-paste data
    if (term.ptmx_buffers.length > 0) {
        if (term.fdm) |fdm|
            _ = fdm_event_add(fdm, term.ptmx, EPOLLOUT);
    }
}

export fn text_from_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse {
        done(user);
        return;
    }));
    textFromClipboard(s, term, no_strip, cb, done, user);
}

export fn text_from_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
    no_strip: bool,
    cb: ClipboardCb,
    done: ClipboardDone,
    user: ?*anyopaque,
) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse {
        done(user);
        return;
    }));
    textFromPrimary(s, term, no_strip, cb, done, user);
}

export fn selection_from_clipboard(
    seat: ?*anyopaque,
    term: *types.Terminal,
    serial: u32,
) callconv(.c) void {
    _ = serial;
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return));

    if (term.is_sending_paste_data) {
        // We're already pasting...
        return;
    }

    const clipboard = &s.clipboard;
    if (clipboard.data_offer == null)
        return;

    term.is_sending_paste_data = true;

    if (term.bracketed_paste)
        term_paste_data_to_slave(term, "\x1b[200~", 6);

    textFromClipboard(s, term, false, &receiveOffer, &receiveOfferDone, term);
}

export fn selection_from_primary(
    seat: ?*anyopaque,
    term: *types.Terminal,
) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return));

    const wayl = term.wl orelse return;
    if (wayl.primary_selection_device_manager == null)
        return;

    if (term.is_sending_paste_data) {
        // We're already pasting...
        return;
    }

    const primary = &s.primary;
    if (primary.data_offer == null)
        return;

    term.is_sending_paste_data = true;
    if (term.bracketed_paste)
        term_paste_data_to_slave(term, "\x1b[200~", 6);

    textFromPrimary(s, term, false, &receiveOffer, &receiveOfferDone, term);
}

// ── Chunk F: unset + scroll timer ───────────────────────────────

export fn selection_clipboard_unset(seat: ?*anyopaque) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return));
    const clipboard = &s.clipboard;

    if (clipboard.data_source == null)
        return;

    wayland_shim_data_device_set_selection(s.data_device, null, clipboard.serial);
    wayland_shim_data_source_destroy(clipboard.data_source);

    clipboard.data_source = null;
    clipboard.serial = 0;

    freeSlice(clipboard.text);
    clipboard.text = null;
}

export fn selection_primary_unset(seat: ?*anyopaque) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return));
    const primary = &s.primary;

    if (primary.data_source == null)
        return;

    wayland_shim_primary_device_set_selection(
        s.primary_selection_device, null, primary.serial);
    wayland_shim_primary_selection_source_destroy(primary.data_source);

    primary.data_source = null;
    primary.serial = 0;

    freeSlice(primary.text);
    primary.text = null;
}

// fdm + timerfd externs
const Fdm = anyopaque;
const FdmHandler = *const fn (*Fdm, c_int, c_int, ?*anyopaque) callconv(.c) bool;

extern fn fdm_add(fdm: *Fdm, fd: c_int, events: c_int, handler: FdmHandler, data: ?*anyopaque) callconv(.c) bool;
extern fn fdm_del(fdm: *Fdm, fd: c_int) callconv(.c) bool;
extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
extern fn timerfd_gettime(fd: c_int, curr: *types.Itimerspec) callconv(.c) c_int;
extern fn timerfd_settime(fd: c_int, flags: c_int, new_value: *const types.Itimerspec, old_value: ?*types.Itimerspec) callconv(.c) c_int;
extern fn read(fd: c_int, buf: *anyopaque, count: usize) callconv(.c) isize;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn __errno_location() callconv(.c) *c_int;

extern fn cmd_scrollback_up(term: *types.Terminal, rows: u64) callconv(.c) void;
extern fn cmd_scrollback_down(term: *types.Terminal, rows: u64) callconv(.c) void;

const EPOLLIN: c_int = 0x001;
const EPOLLHUP: c_int = 0x010;
const EAGAIN: c_int = 11;
const CLOCK_MONOTONIC: c_int = 1;
const TFD_CLOEXEC: c_int = 0x80000;
const TFD_NONBLOCK: c_int = 0x800;

// SELECTION_SCROLL_* values from terminal.h

fn fdm_scroll_timer(fdm_opaque: *Fdm, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm_opaque;
    if (events & EPOLLHUP != 0) return false;

    const term: *types.Terminal = @ptrCast(@alignCast(data orelse return false));

    var expiration_count: u64 = 0;
    const ret = read(fd, &expiration_count, @sizeOf(u64));
    if (ret < 0) {
        if (__errno_location().* == EAGAIN) return true;
        return false;
    }

    switch (term.selection.auto_scroll.direction) {
        .not => return true,
        .up => {
            cmd_scrollback_up(term, expiration_count);
            selection_update(term, term.selection.auto_scroll.col, 0);
        },
        .down => {
            cmd_scrollback_down(term, expiration_count);
            selection_update(term, term.selection.auto_scroll.col, term.rows - 1);
        },
    }
    return true;
}

export fn selection_start_scroll_timer(
    term: *types.Terminal,
    interval_ns: c_int,
    direction: c_int,
    col: c_int,
) callconv(.c) void {
    if (!term.selection.ongoing) return;

    if (term.selection.auto_scroll.fd < 0) {
        const fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        if (fd < 0) {
            selection_stop_scroll_timer(term);
            return;
        }

        if (!fdm_add(@ptrCast(@alignCast(term.fdm orelse return)), fd, EPOLLIN, &fdm_scroll_timer, term)) {
            _ = close(fd);
            return;
        }

        term.selection.auto_scroll.fd = fd;
    }

    var timer: types.Itimerspec = undefined;
    if (timerfd_gettime(term.selection.auto_scroll.fd, &timer) < 0) {
        selection_stop_scroll_timer(term);
        return;
    }

    if (timer.it_value.tv_sec == 0 and timer.it_value.tv_nsec == 0) {
        timer.it_value.tv_nsec = 1;
    }

    timer.it_interval.tv_sec = @divTrunc(interval_ns, 1_000_000_000);
    timer.it_interval.tv_nsec = @mod(interval_ns, 1_000_000_000);

    if (timerfd_settime(term.selection.auto_scroll.fd, 0, &timer, null) < 0) {
        selection_stop_scroll_timer(term);
        return;
    }

    term.selection.auto_scroll.direction = @enumFromInt(direction);
    term.selection.auto_scroll.col = col;
}

export fn selection_stop_scroll_timer(term: *types.Terminal) callconv(.c) void {
    if (term.selection.auto_scroll.fd < 0) return;

    _ = fdm_del(@ptrCast(@alignCast(term.fdm orelse return)), term.selection.auto_scroll.fd);
    term.selection.auto_scroll.fd = -1;
    term.selection.auto_scroll.direction = .not;
}

//
// Chunk S2 — clipboard/primary receive pipeline.
//
// Everything below the wayland layer: the other client writes into a pipe, we
// read it through the fdm, normalise/strip as configured, and hand chunks to a
// callback. begin_receive_clipboard() is still called from the C
// selection_*_from_clipboard/primary() functions, which need the seat.
//

extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn uri_parse(
    uri: [*c]const u8,
    len: usize,
    scheme: ?*[*c]u8,
    user: ?*[*c]u8,
    password: ?*[*c]u8,
    host: ?*[*c]u8,
    port: ?*u16,
    path: ?*[*c]u8,
    query: ?*[*c]u8,
    fragment: ?*[*c]u8,
) callconv(.c) bool;
extern fn hostname_is_localhost(hostname: [*c]const u8) callconv(.c) bool;

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x800;

const DATA_OFFER_MIME_URI_LIST: c_int = 3;

const ReceiveCb = *const fn (data: [*]u8, size: usize, user: ?*anyopaque) callconv(.c) void;
const ReceiveDone = *const fn (user: ?*anyopaque) callconv(.c) void;

const UriBuf = struct {
    data: ?[*]u8 = null,
    sz: usize = 0,
    idx: usize = 0,
};

const ClipboardReceive = struct {
    read_fd: c_int,
    timeout_fd: c_int,
    timeout: types.Itimerspec,
    bracketed: bool,
    no_strip: bool,
    quote_paths: bool,

    decoder: *const fn (*ClipboardReceive, [*]u8, usize) void,
    finish: *const fn (*ClipboardReceive) void,

    // URI state
    add_space: bool = false,
    buf: UriBuf = .{},

    // Callback data
    cb: ReceiveCb,
    done: ReceiveDone,
    user: ?*anyopaque,
};

fn receiveCb(ctx: *ClipboardReceive, data: [*]const u8, size: usize) void {
    ctx.cb(@constCast(data), size, ctx.user);
}

fn clipboardReceiveDone(fdm: *Fdm, ctx: *ClipboardReceive) void {
    _ = fdm_del(fdm, ctx.timeout_fd);
    _ = fdm_del(fdm, ctx.read_fd);
    ctx.done(ctx.user);
    if (ctx.buf.data) |data|
        free(data);
    free(ctx);
}

fn fdmReceiveTimeout(fdm_opaque: *Fdm, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *ClipboardReceive = @ptrCast(@alignCast(data orelse return false));
    if (events & EPOLLHUP != 0)
        return false;

    std.debug.assert(events & EPOLLIN != 0);

    var expire_count: u64 = 0;
    const ret = read(fd, &expire_count, @sizeOf(u64));
    if (ret < 0) {
        if (__errno_location().* == EAGAIN)
            return true;
        return false;
    }

    log_msg(
        LOG_CLASS_WARNING, "selection", "selection.zig", @intCast(@src().line),
        "no data received from clipboard in %llu seconds, aborting",
        @as(c_ulonglong, @intCast(ctx.timeout.it_value.tv_sec)),
    );

    clipboardReceiveDone(fdm_opaque, ctx);
    return true;
}

fn fdmReceiveDecoderPlain(ctx: *ClipboardReceive, data: [*]u8, size: usize) void {
    ctx.cb(data, size, ctx.user);
}

fn fdmReceiveFinishPlain(ctx: *ClipboardReceive) void {
    _ = ctx;
}

fn decodeOneUri(ctx: *ClipboardReceive, uri: [*]u8, len: usize) bool {
    if (len == 0)
        return false;

    var scheme: [*c]u8 = null;
    var host: [*c]u8 = null;
    var path: [*c]u8 = null;

    if (!uri_parse(uri, len, &scheme, null, null, &host, null, &path, null, null)) {
        log_msg(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "drag-and-drop: invalid URI: %.*s",
            @as(c_int, @intCast(len)), uri,
        );
        return false;
    }

    if (ctx.add_space)
        receiveCb(ctx, " ", 1);
    ctx.add_space = true;

    const is_file = scheme != null and host != null and path != null and
        std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(scheme))), "file") and
        hostname_is_localhost(host);

    if (is_file) {
        const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));

        if (ctx.quote_paths)
            receiveCb(ctx, "'", 1);

        var remaining = path_slice;
        while (std.mem.indexOfScalar(u8, remaining, '\'')) |quote_idx| {
            receiveCb(ctx, remaining.ptr, quote_idx);
            receiveCb(ctx, "\\'", 2);
            remaining = remaining[quote_idx + 1 ..];
        }
        receiveCb(ctx, remaining.ptr, remaining.len);

        if (ctx.quote_paths)
            receiveCb(ctx, "'", 1);
    } else {
        ctx.cb(uri, len, ctx.user);
    }

    if (scheme != null)
        free(scheme);
    if (host != null)
        free(host);
    if (path != null)
        free(path);
    return true;
}

fn fdmReceiveDecoderUri(ctx: *ClipboardReceive, data: [*]u8, size: usize) void {
    while (ctx.buf.idx + size > ctx.buf.sz) {
        const new_sz = if (ctx.buf.sz == 0) size else 2 * ctx.buf.sz;
        const new_data = std.c.realloc(ctx.buf.data, new_sz) orelse return;
        ctx.buf.data = @ptrCast(new_data);
        ctx.buf.sz = new_sz;
    }

    // C did `memcpy(&ctx->buf.data[idx], data, size)` even when nothing was
    // buffered yet; with size == 0 that is a no-op on a NULL pointer. In Zig
    // it would be an unwrap of null, so a zero-length chunk on an empty
    // buffer returns early: there is nothing to copy and nothing to scan.
    if (ctx.buf.data == null) {
        std.debug.assert(size == 0 and ctx.buf.idx == 0);
        return;
    }

    const buf = ctx.buf.data.?;
    @memcpy(buf[ctx.buf.idx .. ctx.buf.idx + size], data[0..size]);
    ctx.buf.idx += size;

    var start: usize = 0;
    var end: usize = 0;

    while (true) {
        end = start;
        while (end < ctx.buf.idx and buf[end] != '\r' and buf[end] != '\n')
            end += 1;

        if (end >= ctx.buf.idx)
            break;

        _ = decodeOneUri(ctx, buf + start, end - start);
        start = end + 1;
    }

    const left = ctx.buf.idx - start;
    if (left > 0)
        _ = memmove(buf, buf + start, left);
    ctx.buf.idx = left;
}

fn fdmReceiveFinishUri(ctx: *ClipboardReceive) void {
    if (ctx.buf.data) |buf|
        _ = decodeOneUri(ctx, buf, ctx.buf.idx);
}

/// Decode and filter one buffer's worth of clipboard data. The C0-stripping
/// and CRLF-normalisation state machine is a transcription of the C version;
/// "skip_one" restarts the scan on the remaining data.
fn receiveChunk(ctx: *ClipboardReceive, p_in: [*]u8, left_in: usize) [*]u8 {
    var p = p_in;
    var left = left_in;

    while (true) {
        var skipped = false;
        var i: usize = 0;

        while (i < left) : (i += 1) {
            switch (p[i]) {
                '\n' => {
                    if (!ctx.no_strip and !ctx.bracketed)
                        p[i] = '\r';
                },

                '\r' => {
                    // Convert \r\n -> \r
                    if (!ctx.no_strip and !ctx.bracketed and i + 1 < left and p[i + 1] == '\n') {
                        i += 1;
                        ctx.decoder(ctx, p, i);
                        std.debug.assert(i + 1 <= left);
                        p += i + 1;
                        left -= i + 1;
                        skipped = true;
                    }
                },

                // C0 non-formatting control characters (\b \t \n \r excluded)
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13,
                0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
                => {
                    if (!ctx.no_strip) {
                        ctx.decoder(ctx, p, i);
                        std.debug.assert(i + 1 <= left);
                        p += i + 1;
                        left -= i + 1;
                        skipped = true;
                    }
                },

                // XTerm strips these in non-bracketed mode, but keeps them in
                // bracketed paste mode.
                '\x08', '\x7f', 0x00 => {
                    if (!ctx.no_strip and !ctx.bracketed) {
                        ctx.decoder(ctx, p, i);
                        std.debug.assert(i + 1 <= left);
                        p += i + 1;
                        left -= i + 1;
                        skipped = true;
                    }
                },

                else => {},
            }

            if (skipped)
                break;
        }

        if (!skipped) {
            ctx.decoder(ctx, p, left);
            return p + left;
        }
    }
}

fn fdmReceive(fdm_opaque: *Fdm, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *ClipboardReceive = @ptrCast(@alignCast(data orelse return false));
    const no_strip = ctx.no_strip;
    const bracketed = ctx.bracketed;

    if ((events & EPOLLHUP != 0) and (events & EPOLLIN == 0))
        return receiveDone(fdm_opaque, fd, ctx);

    // Reset timeout timer
    if (timerfd_settime(ctx.timeout_fd, 0, &ctx.timeout, null) < 0)
        return false;

    while (true) {
        var text: [256]u8 = undefined;
        const count = read(fd, &text, text.len);

        if (count == -1) {
            const err = __errno_location().*;
            if (err == EAGAIN or err == 11) // EAGAIN || EWOULDBLOCK
                return true;
            break;
        }

        if (count == 0)
            break;

        // The chunk filter mutates the buffer in place (\n -> \r), hence the
        // constCast; `count` is a positive read() result, so it fits.
        _ = receiveChunk(ctx, @constCast(text[0..@intCast(count)].ptr), @intCast(count));
        _ = no_strip;
        _ = bracketed;
    }

    return receiveDone(fdm_opaque, fd, ctx);
}

fn receiveDone(fdm_opaque: *Fdm, fd: c_int, ctx: *ClipboardReceive) bool {
    _ = fd;
    ctx.finish(ctx);
    clipboardReceiveDone(fdm_opaque, ctx);
    return true;
}

fn setupReceive(
    term: *types.Terminal,
    no_strip: bool,
    read_fd: c_int,
    mime_type: c_int,
    cb: ReceiveCb,
    done: ReceiveDone,
    user: ?*anyopaque,
    timeout_fd_out: *c_int,
) ?*ClipboardReceive {
    const flags = fcntl(read_fd, F_GETFL);
    if (flags < 0 or fcntl(read_fd, F_SETFL, flags | O_NONBLOCK) < 0)
        return null;

    const timeout_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (timeout_fd < 0)
        return null;
    timeout_fd_out.* = timeout_fd;

    const timeout = types.Itimerspec{
        .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };
    if (timerfd_settime(timeout_fd, 0, &timeout, null) < 0)
        return null;

    const ctx_raw = malloc(@sizeOf(ClipboardReceive)) orelse return null;
    const ctx: *ClipboardReceive = @ptrCast(@alignCast(ctx_raw));
    ctx.* = .{
        .read_fd = read_fd,
        .timeout_fd = timeout_fd,
        .timeout = timeout,
        .bracketed = term.bracketed_paste,
        .no_strip = no_strip,
        .quote_paths = term.grid == &term.normal,
        .decoder = if (mime_type == DATA_OFFER_MIME_URI_LIST)
            &fdmReceiveDecoderUri
        else
            &fdmReceiveDecoderPlain,
        .finish = if (mime_type == DATA_OFFER_MIME_URI_LIST)
            &fdmReceiveFinishUri
        else
            &fdmReceiveFinishPlain,
        .cb = cb,
        .done = done,
        .user = user,
    };
    return ctx;
}

export fn begin_receive_clipboard(
    term: *types.Terminal,
    no_strip: bool,
    read_fd: c_int,
    mime_type: c_int,
    cb: ReceiveCb,
    done: ReceiveDone,
    user: ?*anyopaque,
) callconv(.c) void {
    var timeout_fd: c_int = -1;
    const maybe_ctx = setupReceive(term, no_strip, read_fd, mime_type, cb, done, user, &timeout_fd);

    if (maybe_ctx) |ctx| {
        if (term.fdm) |fdm_opaque| {
            const fdm: *Fdm = @ptrCast(@alignCast(fdm_opaque));
            if (fdm_add(fdm, read_fd, EPOLLIN, &fdmReceive, ctx) and
                fdm_add(fdm, timeout_fd, EPOLLIN, &fdmReceiveTimeout, ctx))
            {
                return;
            }
        }
        free(ctx);
    }

    if (term.fdm) |fdm_opaque| {
        const fdm: *Fdm = @ptrCast(@alignCast(fdm_opaque));
        _ = fdm_del(fdm, timeout_fd);
        _ = fdm_del(fdm, read_fd);
    }
    done(user);
}

// ─────────────────────────────────────────────────────────────────────────
// Data-source send path (D5d-a)
//
// When another client pastes, the compositor asks us for the data through
// the wl_data_source / zwp_primary_selection_source_v1 "send" event. The
// initial write is synchronous; if the pipe is full the remainder is queued
// on the FDM (EPOLLOUT) and written chunk by chunk.
//
// The two listener tables stay in selection.c; they reference these exports.
// ─────────────────────────────────────────────────────────────────────────

const EPOLLOUT: c_int = 0x004;

const AsyncWriteStatus = enum(c_int) { done = 0, remain = 1, err = 2 };

extern fn async_write(
    fd: c_int, data: ?*const anyopaque, len: usize, idx: *usize) callconv(.c) AsyncWriteStatus;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn wayland_shim_data_source_destroy(source: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_source_destroy(source: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_data_device_set_selection(
    dev: ?*anyopaque, source: ?*anyopaque, serial: u32,
) callconv(.c) void;
extern fn wayland_shim_data_source_create(manager: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_data_source_offer(
    source: ?*anyopaque, mime_type: [*:0]const u8,
) callconv(.c) void;
extern fn wayland_shim_primary_source_create(manager: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn wayland_shim_primary_source_offer(
    source: ?*anyopaque, mime_type: [*:0]const u8,
) callconv(.c) void;
extern fn wayland_shim_primary_device_set_selection(
    dev: ?*anyopaque, source: ?*anyopaque, serial: u32,
) callconv(.c) void;
extern fn wayland_shim_add_data_source_listener(
    source: ?*anyopaque, seat: ?*anyopaque,
) callconv(.c) void;
extern fn wayland_shim_add_primary_source_listener(
    source: ?*anyopaque, seat: ?*anyopaque,
) callconv(.c) void;
extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;

fn freeSlice(p: anytype) void {
    if (p) |q| free(@ptrCast(q));
}

const ClipboardSend = extern struct {
    data: ?[*:0]u8,
    len: usize,
    idx: usize,
};

fn fdmSend(fdm_opaque: *Fdm, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *ClipboardSend = @ptrCast(@alignCast(data orelse return true));

    if (events & EPOLLHUP == 0) {
        const buf: ?*const anyopaque = if (ctx.data) |d| @ptrCast(d) else null;
        switch (async_write(fd, buf, ctx.len, &ctx.idx)) {
            .remain => return true,
            .done => {},
            .err => log_errno(
                LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
                "failed to asynchronously write %zu of selection data to FD=%d",
                ctx.len - ctx.idx, fd),
        }
    }

    _ = fdm_del(fdm_opaque, fd);
    freeSlice(ctx.data);
    free(ctx);
    return true;
}

fn sendClipboardOrPrimary(
    seat: *types.Seat,
    fd: c_int,
    selection_text: ?[*:0]const u8,
    source_name: [*:0]const u8,
) void {
    // Make it NONBLOCK:ing right away - we don't want to block if the initial
    // attempt to send the data synchronously fails
    const flags = fcntl(fd, F_GETFL);
    if (flags < 0 or fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        log_errno(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to set O_NONBLOCK");
        return;
    }

    const len: usize = if (selection_text) |s| std.mem.len(s) else 0;
    var async_idx: usize = 0;

    const buf: ?*const anyopaque = if (selection_text) |s| @ptrCast(s) else null;

    switch (async_write(fd, buf, len, &async_idx)) {
        .remain => {
            const raw = xmalloc(@sizeOf(ClipboardSend)) orelse unreachable;
            const ctx: *ClipboardSend = @ptrCast(@alignCast(raw));
            ctx.* = .{
                .data = xstrdup(@ptrCast(selection_text.? + async_idx)),
                .len = len - async_idx,
                .idx = 0,
            };

            const fdm: *Fdm = @ptrCast(@alignCast(seat.wayl.?.fdm.?));
            if (fdm_add(fdm, fd, EPOLLOUT, &fdmSend, ctx))
                return;

            freeSlice(ctx.data);
            free(ctx);
        },

        .done => {},

        .err => log_errno(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed write %zu bytes of %s selection data to FD=%d",
            len, source_name, fd),
    }

    _ = close(fd);
}

export fn selection_send_clipboard_or_primary(
    seat: ?*anyopaque,
    fd: c_int,
    selection_text: ?[*:0]const u8,
    source_name: [*:0]const u8,
) callconv(.c) void {
    const s: *types.Seat = @ptrCast(@alignCast(seat orelse return));
    sendClipboardOrPrimary(s, fd, selection_text, source_name);
}

export fn selection_data_source_target(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    _ = data;
    _ = wl_data_source;
    _ = mime_type;
}

export fn selection_data_source_send(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
    mime_type: ?[*:0]const u8,
    fd: c_int,
) callconv(.c) void {
    _ = wl_data_source;
    _ = mime_type;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    sendClipboardOrPrimary(seat, fd, seat.clipboard.text, "clipboard");
}

export fn selection_data_source_cancelled(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
) callconv(.c) void {
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));
    const clipboard = &seat.clipboard;

    std.debug.assert(clipboard.data_source == wl_data_source);

    wayland_shim_data_source_destroy(clipboard.data_source);
    clipboard.data_source = null;
    clipboard.serial = 0;

    freeSlice(clipboard.text);
    clipboard.text = null;
}

// We don't support dragging *from*
export fn selection_data_source_dnd_drop_performed(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = wl_data_source;
}

export fn selection_data_source_dnd_finished(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = wl_data_source;
}

export fn selection_data_source_action(
    data: ?*anyopaque,
    wl_data_source: ?*anyopaque,
    dnd_action: u32,
) callconv(.c) void {
    _ = data;
    _ = wl_data_source;
    _ = dnd_action;
}

export fn selection_primary_source_send(
    data: ?*anyopaque,
    zwp_primary_selection_source_v1: ?*anyopaque,
    mime_type: ?[*:0]const u8,
    fd: c_int,
) callconv(.c) void {
    _ = zwp_primary_selection_source_v1;
    _ = mime_type;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    sendClipboardOrPrimary(seat, fd, seat.primary.text, "primary");
}

export fn selection_primary_source_cancelled(
    data: ?*anyopaque,
    zwp_primary_selection_source_v1: ?*anyopaque,
) callconv(.c) void {
    _ = zwp_primary_selection_source_v1;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));
    const primary = &seat.primary;

    wayland_shim_primary_selection_source_destroy(primary.data_source);
    primary.data_source = null;
    primary.serial = 0;

    freeSlice(primary.text);
    primary.text = null;
}

// ─────────────────────────────────────────────────────────────────────────
// Data offers: mime-type ranking and offer bookkeeping (D5d-b1)
//
// Both clipboard and primary selection expose the same preference order:
// text/uri-list always wins, utf8 flavours beat plain text, and the
// X11-style names are the last resort. The offer reset helpers destroy the
// protocol object (C-side inline) and clear the tracking state.
// ─────────────────────────────────────────────────────────────────────────

const mime_type_map = [_]?[*:0]const u8{
    null, // DATA_OFFER_MIME_UNSET
    "text/plain", // DATA_OFFER_MIME_TEXT_PLAIN
    "text/plain;charset=utf-8", // DATA_OFFER_MIME_TEXT_UTF8
    "text/uri-list", // DATA_OFFER_MIME_URI_LIST
    "TEXT", // DATA_OFFER_MIME_TEXT_TEXT
    "STRING", // DATA_OFFER_MIME_TEXT_STRING
    "UTF8_STRING", // DATA_OFFER_MIME_TEXT_UTF8_STRING
};

extern fn wayland_shim_data_offer_destroy(offer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_primary_selection_offer_destroy(offer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_add_data_offer_listener(
    offer: ?*anyopaque, seat: ?*anyopaque,
) callconv(.c) void;
extern fn wayland_shim_add_primary_offer_listener(
    offer: ?*anyopaque, seat: ?*anyopaque,
) callconv(.c) void;

export fn selection_select_mime_type_for_offer(
    mime_type_in: [*:0]const u8,
    mime_type_out: *types.DataOfferMimeType,
) callconv(.c) void {
    const mime_type: types.DataOfferMimeType = blk: {
        for (mime_type_map, 0..) |candidate, i| {
            const candidate_z = candidate orelse continue;
            if (std.mem.eql(u8, std.mem.span(mime_type_in), std.mem.span(candidate_z)))
                break :blk @enumFromInt(i);
        }
        break :blk .unset;
    };

    // Mime-type transition; if the new mime-type is "better" than previously
    // offered types, use the new type
    switch (mime_type) {
        .text_plain, .text_text, .text_string => {
            // text/plain is our least preferred type. Only use if current type
            // is unset.
            switch (mime_type_out.*) {
                .unset => mime_type_out.* = mime_type,
                else => {},
            }
        },

        .text_utf8, .text_utf8_string => {
            // text/plain;charset=utf-8 is preferred over text/plain
            switch (mime_type_out.*) {
                .unset, .text_plain, .text_text, .text_string => mime_type_out.* = mime_type,
                else => {},
            }
        },

        .uri_list => {
            // text/uri-list is always used when offered
            mime_type_out.* = mime_type;
        },

        .unset => {},
    }
}

export fn selection_data_offer_reset(clipboard: ?*types.WlClipboard) callconv(.c) void {
    const c = clipboard orelse return;

    if (c.data_offer != null) {
        wayland_shim_data_offer_destroy(c.data_offer);
        c.data_offer = null;
    }

    c.window = null;
    c.mime_type = .unset;
}

export fn selection_primary_offer_reset(primary: ?*types.WlPrimary) callconv(.c) void {
    const p = primary orelse return;

    if (p.data_offer != null) {
        wayland_shim_primary_selection_offer_destroy(p.data_offer);
        p.data_offer = null;
    }

    p.mime_type = .unset;
}

export fn selection_offer(
    data: ?*anyopaque,
    wl_data_offer: ?*anyopaque,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    _ = wl_data_offer;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    selection_select_mime_type_for_offer(mime_type orelse return, &seat.clipboard.mime_type);
}

// Debug-only in C (LOG_DBG), so empty here.
export fn selection_offer_source_actions(
    data: ?*anyopaque,
    wl_data_offer: ?*anyopaque,
    source_actions: u32,
) callconv(.c) void {
    _ = data;
    _ = wl_data_offer;
    _ = source_actions;
}

export fn selection_offer_action(
    data: ?*anyopaque,
    wl_data_offer: ?*anyopaque,
    dnd_action: u32,
) callconv(.c) void {
    _ = data;
    _ = wl_data_offer;
    _ = dnd_action;
}

export fn selection_primary_offer(
    data: ?*anyopaque,
    zwp_primary_selection_offer: ?*anyopaque,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    _ = zwp_primary_selection_offer;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    selection_select_mime_type_for_offer(mime_type orelse return, &seat.primary.mime_type);
}

// ─────────────────────────────────────────────────────────────────────────
// Data-device / DND listeners (D5d-b2)
//
// The compositor tells us about incoming offers and drag-and-drop through the
// wl_data_device interface. The listener table is C (wayland-shim.c), the
// callbacks are here: they track which terminal the offer targets and, on
// drop, hand the offer's pipe to the receive pipeline (chunk E).
// ─────────────────────────────────────────────────────────────────────────

const EPOLLOUT_REPEAT: c_int = 0x004; // EPOLLOUT, shared with the send path

const O_CLOEXEC: c_int = 0x80000;

const DND_ACTION_NONE: u32 = 0;
const DND_ACTION_COPY: u32 = 1;

extern fn pipe2(fds: *[2]c_int, flags: c_int) callconv(.c) c_int;
extern fn fdm_event_add(fdm: *anyopaque, fd: c_int, events: c_int) callconv(.c) bool;
extern fn term_paste_data_to_slave(
    term: *types.Terminal, buf: [*]const u8, len: usize,
) callconv(.c) void;
extern fn term_surface_kind(
    term: *const types.Terminal, surface: ?*const anyopaque,
) callconv(.c) types.TermSurface;
extern fn wayland_shim_data_offer_accept(
    offer: ?*anyopaque, serial: u32, mime_type: ?[*:0]const u8,
) callconv(.c) void;
extern fn wayland_shim_data_offer_set_actions(
    offer: ?*anyopaque, actions: u32, preferred_action: u32,
) callconv(.c) void;
extern fn wayland_shim_data_offer_finish(offer: ?*anyopaque) callconv(.c) void;
extern fn wayland_shim_data_offer_receive(
    offer: ?*anyopaque, mime_type: [*:0]const u8, fd: c_int,
) callconv(.c) void;
extern fn wayland_shim_primary_offer_receive(
    offer: ?*anyopaque, mime_type: [*:0]const u8, fd: c_int,
) callconv(.c) void;

/// tll_foreach(seat->wayl->terms, it)
const TermsIter = struct {
    node: ?*anyopaque,

    fn next(self: *TermsIter) ?*types.Terminal {
        while (self.node) |raw| {
            const node: *types.TllNode(?*anyopaque) = @ptrCast(@alignCast(raw));
            self.node = node.next;
            if (node.item) |item|
                return @ptrCast(@alignCast(item));
        }
        return null;
    }
};

fn terms(wayl: *types.Wayland) TermsIter {
    return .{ .node = wayl.terms.head };
}

export fn selection_data_device_data_offer(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
    offer: ?*anyopaque,
) callconv(.c) void {
    _ = wl_data_device;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    selection_data_offer_reset(&seat.clipboard);
    seat.clipboard.data_offer = offer;
    wayland_shim_add_data_offer_listener(offer, seat);
}

export fn selection_data_device_enter(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
    serial: u32,
    surface: ?*anyopaque,
    x: c_int,
    y: c_int,
    offer: ?*anyopaque,
) callconv(.c) void {
    _ = wl_data_device;
    _ = x;
    _ = y;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));
    const wayl = seat.wayl orelse return;

    std.debug.assert(offer == seat.clipboard.data_offer);

    if (seat.clipboard.mime_type != .unset) {
        var it = terms(wayl);
        while (it.next()) |term| {
            // Remember _which_ terminal the current DnD offer is targeting
            if (term_surface_kind(term, surface) == .grid and
                !term.is_sending_paste_data)
            {
                wayland_shim_data_offer_accept(
                    offer, serial, mimeTypeName(seat.clipboard.mime_type).?);
                wayland_shim_data_offer_set_actions(
                    offer, DND_ACTION_COPY, DND_ACTION_COPY);

                std.debug.assert(seat.clipboard.window == null);
                seat.clipboard.window = @ptrCast(term.window);
                return;
            }
        }
    }

    // Either terminal is already busy sending paste data, or mouse
    // pointer isn't over the grid
    seat.clipboard.window = null;
    wayland_shim_data_offer_accept(offer, serial, null);
    wayland_shim_data_offer_set_actions(offer, DND_ACTION_NONE, DND_ACTION_NONE);
}

export fn selection_data_device_leave(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
) callconv(.c) void {
    _ = wl_data_device;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));
    seat.clipboard.window = null;
}

export fn selection_data_device_motion(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
    time: u32,
    x: c_int,
    y: c_int,
) callconv(.c) void {
    _ = data;
    _ = wl_data_device;
    _ = time;
    _ = x;
    _ = y;
}

const DndContext = extern struct {
    term: *types.Terminal,
    data_offer: ?*anyopaque,
};

fn receiveDnd(data: [*]u8, size: usize, user: ?*anyopaque) callconv(.c) void {
    const ctx: *DndContext = @ptrCast(@alignCast(user orelse return));
    receiveOffer(data, size, ctx.term);
}

fn receiveDndDone(user: ?*anyopaque) callconv(.c) void {
    const ctx: *DndContext = @ptrCast(@alignCast(user orelse return));

    wayland_shim_data_offer_finish(ctx.data_offer);
    wayland_shim_data_offer_destroy(ctx.data_offer);
    receiveOfferDone(ctx.term);
    free(ctx);
}

export fn selection_data_device_drop(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
) callconv(.c) void {
    _ = wl_data_device;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));
    const clipboard = &seat.clipboard;

    if (clipboard.mime_type == .unset) {
        log_msg(
            LOG_CLASS_WARNING, "selection", "selection.zig", @intCast(@src().line),
            "compositor called data_device::drop() even though we rejected the drag-and-drop",
        );
        return;
    }

    const window = clipboard.window orelse return;
    const w: *types.WlWindow = @ptrCast(@alignCast(window));
    const term: *types.Terminal = @ptrCast(@alignCast(w.term orelse return));

    const raw = xmalloc(@sizeOf(DndContext)) orelse return;
    const ctx: *DndContext = @ptrCast(@alignCast(raw));
    ctx.* = .{
        .term = term,
        .data_offer = clipboard.data_offer,
    };

    // Prepare a pipe the other client can write its selection to us
    var fds: [2]c_int = undefined;
    if (pipe2(&fds, O_CLOEXEC) == -1) {
        log_errno(
            LOG_CLASS_ERROR, "selection", "selection.zig", @intCast(@src().line),
            "failed to create pipe");
        free(ctx);
        return;
    }

    const read_fd = fds[0];
    const write_fd = fds[1];

    // Give the write-end of the pipe to the other client
    wayland_shim_data_offer_receive(
        clipboard.data_offer, mimeTypeName(clipboard.mime_type).?, write_fd);

    // Don't keep our copy of the write-end open (or we'll never get EOF)
    _ = close(write_fd);

    term.is_sending_paste_data = true;

    if (term.bracketed_paste)
        term_paste_data_to_slave(term, "\x1b[200~", 6);

    begin_receive_clipboard(
        term, false, read_fd, @intFromEnum(clipboard.mime_type),
        &receiveDnd, &receiveDndDone, ctx);

    // data offer is now "owned" by the receive context
    clipboard.data_offer = null;
    clipboard.mime_type = .unset;
}

export fn selection_data_device_selection(
    data: ?*anyopaque,
    wl_data_device: ?*anyopaque,
    offer: ?*anyopaque,
) callconv(.c) void {
    _ = wl_data_device;
    // Selection offer from another client
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    if (offer == null) {
        selection_data_offer_reset(&seat.clipboard);
    } else {
        std.debug.assert(offer == seat.clipboard.data_offer);
    }
}

export fn selection_primary_device_data_offer(
    data: ?*anyopaque,
    zwp_primary_selection_device: ?*anyopaque,
    offer: ?*anyopaque,
) callconv(.c) void {
    _ = zwp_primary_selection_device;
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    selection_primary_offer_reset(&seat.primary);
    seat.primary.data_offer = offer;
    wayland_shim_add_primary_offer_listener(offer, seat);
}

export fn selection_primary_device_selection(
    data: ?*anyopaque,
    zwp_primary_selection_device: ?*anyopaque,
    offer: ?*anyopaque,
) callconv(.c) void {
    _ = zwp_primary_selection_device;
    // Selection offer from another client, for primary
    const seat: *types.Seat = @ptrCast(@alignCast(data orelse return));

    if (offer == null) {
        selection_primary_offer_reset(&seat.primary);
    } else {
        std.debug.assert(seat.primary.data_offer == offer);
    }
}
