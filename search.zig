//! Zig port of search.c's matching core: the row/viewport helpers,
//! matches_cell(), find_next(), the match iterator and the query buffer.
//!
//! Not here yet (D1b/D1c): search_begin()/search_cancel(), the extend/word/line
//! selectors, execute_binding() and search_input().

const std = @import("std");
const types = @import("terminal_types.zig");

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_DEBUG: c_int = 4;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn bug(
    file: [*:0]const u8,
    line: c_int,
    func: [*:0]const u8,
    fmt: [*:0]const u8,
    ...
) callconv(.c) noreturn;

extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn composed_lookup(root: ?*types.Composed, key: u32) callconv(.c) ?*types.Composed;
extern fn mbsntoc32(dst: ?[*]u32, src: [*c]const u8, nms: usize, len: usize) callconv(.c) usize;

// char32.h helpers and grid.h inlines that Zig cannot call directly.
extern fn terminal_shim_c32ncmp(s1: [*c]const u32, s2: [*c]const u32, n: usize) callconv(.c) c_int;
extern fn terminal_shim_c32ncasecmp(s1: [*c]const u32, s2: [*c]const u32, n: usize) callconv(.c) c_int;
extern fn terminal_shim_isc32print(c32: u32) callconv(.c) bool;
extern fn terminal_shim_hasc32upper(s: [*c]const u32) callconv(.c) bool;
extern fn terminal_shim_grid_row_absolute_in_view(grid: *const types.Grid, row_no: c_int) callconv(.c) c_int;
extern fn terminal_shim_isc32space(c32: u32) callconv(.c) bool;

// Already Zig, in terminal.zig.
extern fn grid_row_abs_to_sb(grid: *const types.Grid, screen_rows: c_int, abs_row: c_int) callconv(.c) c_int;
extern fn grid_row_sb_to_abs(grid: *const types.Grid, screen_rows: c_int, sb_rel_row: c_int) callconv(.c) c_int;
extern fn term_damage_view(term: *types.Terminal) callconv(.c) void;

// Still C: selection.c and render.c.
extern fn selection_start(
    term: *types.Terminal,
    col: c_int,
    row: c_int,
    kind: types.SelectionKind,
    spaces_only: bool,
) callconv(.c) void;
extern fn selection_update(term: *types.Terminal, col: c_int, row: c_int) callconv(.c) void;
extern fn selection_cancel(term: *types.Terminal) callconv(.c) void;
extern fn selection_get_start(term: *const types.Terminal) callconv(.c) types.Coord;
extern fn selection_get_end(term: *const types.Terminal) callconv(.c) types.Coord;
extern fn selection_find_word_boundary_left(term: *const types.Terminal, pos: *types.Coord, spaces_only: bool) callconv(.c) void;
extern fn selection_find_word_boundary_right(term: *const types.Terminal, pos: *types.Coord, spaces_only: bool, stop_at_non_ws: bool) callconv(.c) void;

// wayland.c
extern fn wayl_win_subsurface_destroy(sub: *types.WaylSubSurface) callconv(.c) void;
extern fn wayl_win_subsurface_new(win: *types.WlWindow, sub: *types.WaylSubSurface, start_synchronized: bool) callconv(.c) bool;

// render.c
extern fn render_refresh(term: *types.Terminal) callconv(.c) void;
extern fn render_refresh_search(term: *types.Terminal) callconv(.c) void;

// terminal.zig
extern fn term_xcursor_update(term: *types.Terminal) callconv(.c) void;

// ime.c
extern fn term_ime_is_enabled(term: *const types.Terminal) callconv(.c) bool;
extern fn term_ime_enable(term: *types.Terminal) callconv(.c) void;
extern fn term_ime_disable(term: *types.Terminal) callconv(.c) void;

// extract.c (search.c wraps the extraction context opaquely).
const ExtractionContext = opaque {};
extern fn extract_begin(kind: types.SelectionKind, strip_trailing_empty: bool) callconv(.c) ?*ExtractionContext;
extern fn extract_one(
    term: *const types.Terminal,
    row: *const types.Row,
    cell: *const types.Cell,
    col: c_int,
    ctx: *ExtractionContext,
) callconv(.c) bool;
extern fn extract_finish_wide(
    ctx: *ExtractionContext,
    text: *?[*]u32,
    len: *usize,
) callconv(.c) bool;

extern fn free(ptr: ?*anyopaque) callconv(.c) void;

// terminal.h: CELL_COMB_CHARS_LO/HI and CELL_SPACER.
const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

/// search.h's `struct search_match_iterator` (returned by value from C).
pub const SearchMatchIterator = extern struct {
    term: *types.Terminal,
    start: types.Coord,
};

fn rowsPtr(grid: *const types.Grid) [*]?*types.Row {
    return grid.rows.?;
}

/// Ensures a "new" viewport doesn't contain any unallocated rows.
///
/// This is done by first checking if the *first* row is NULL. If so, we move
/// the viewport *forward* until the first row is non-NULL. At this point, the
/// entire viewport should be allocated rows only.
///
/// If the first row already was non-NULL, we instead check the *last* row, and
/// if it is NULL, we move the viewport *backward* until the last row is
/// non-NULL.
fn ensureViewIsAllocated(term: *types.Terminal, new_view_in: c_int) c_int {
    const grid = term.grid.?;
    const rows = rowsPtr(grid);
    var new_view = new_view_in;
    var view_end = (new_view + term.rows - 1) & (grid.num_rows - 1);

    if (rows[@intCast(new_view)] == null) {
        while (rows[@intCast(new_view)] == null)
            new_view = (new_view + 1) & (grid.num_rows - 1);
    } else if (rows[@intCast(view_end)] == null) {
        while (rows[@intCast(view_end)] == null) {
            new_view -= 1;
            if (new_view < 0)
                new_view += grid.num_rows;
            view_end = (new_view + term.rows - 1) & (grid.num_rows - 1);
        }
    }

    if (std.debug.runtime_safety) {
        var r: c_int = 0;
        while (r < term.rows) : (r += 1) {
            if (rows[@intCast((new_view + r) & (grid.num_rows - 1))] == null)
                bug(@src().file, @intCast(@src().line), "ensure_view_is_allocated", "assertion failed");
        }
    }

    return new_view;
}

fn searchEnsureSize(term: *types.Terminal, wanted_size: usize) bool {
    while (wanted_size >= term.search.sz) {
        const new_sz: usize = if (term.search.sz == 0) 64 else term.search.sz * 2;
        const new_buf: [*]u32 = @ptrCast(@alignCast(realloc(
            @as(?*anyopaque, @ptrCast(term.search.buf)),
            new_sz * @sizeOf(u32),
        ) orelse {
            log_errno(LOG_CLASS_ERROR, "search", "search.zig", @intCast(@src().line), "failed to resize search buffer");
            return false;
        }));

        term.search.buf = new_buf;
        term.search.sz = new_sz;
    }

    return true;
}

fn hasWrappedAroundLeft(term: *const types.Terminal, abs_row_no: c_int) bool {
    const grid = term.grid.?;
    const rebased_row = grid_row_abs_to_sb(grid, term.rows, abs_row_no);
    return rebased_row == grid.num_rows - 1 or rowsPtr(grid)[@intCast(abs_row_no)] == null;
}

fn hasWrappedAroundRight(term: *const types.Terminal, abs_row_no: c_int) bool {
    const rebased_row = grid_row_abs_to_sb(term.grid.?, term.rows, abs_row_no);
    return rebased_row == 0;
}

fn matchesCell(term: *const types.Terminal, cell: *const types.Cell, search_ofs: usize) isize {
    std.debug.assert(search_ofs < term.search.len);

    const search_buf = term.search.buf.?;

    var base = cell.wc;
    var composed: ?*const types.Composed = null;

    if (base >= CELL_COMB_CHARS_LO and base <= CELL_COMB_CHARS_HI) {
        composed = composed_lookup(term.composed, base - CELL_COMB_CHARS_LO);
        base = composed.?.chars.?[0];
    }

    if (composed == null and base == 0 and search_buf[search_ofs] == ' ')
        return 1;

    if (terminal_shim_hasc32upper(search_buf)) {
        if (terminal_shim_c32ncmp(&base, &search_buf[search_ofs], 1) != 0)
            return -1;
    } else {
        if (terminal_shim_c32ncasecmp(&base, &search_buf[search_ofs], 1) != 0)
            return -1;
    }

    if (composed) |c| {
        if (search_ofs + c.count > term.search.len)
            return -1;

        var j: usize = 1;
        while (j < c.count) : (j += 1) {
            if (c.chars.?[j] != search_buf[search_ofs + j])
                return -1;
        }
    }

    return if (composed) |c| @intCast(c.count) else 1;
}

fn findNext(
    term: *types.Terminal,
    direction: types.SearchDirection,
    abs_start: types.Coord,
    abs_end: types.Coord,
    match: *types.Range,
) bool {
    const grid = term.grid.?;
    const rows = rowsPtr(grid);
    const backward = direction != .forward;
    const mask = grid.num_rows - 1;

    log_msg(
        LOG_CLASS_DEBUG,
        "search",
        "search.zig",
        @intCast(@src().line),
        "%s: start: %dx%d, end: %dx%d",
        @as([*:0]const u8, if (backward) "backward" else "forward"),
        abs_start.row,
        abs_start.col,
        abs_end.row,
        abs_end.col,
    );

    std.debug.assert(abs_start.row >= 0 and abs_start.row < grid.num_rows);
    std.debug.assert(abs_start.col >= 0 and abs_start.col < term.cols);
    std.debug.assert(abs_end.row >= 0 and abs_end.row < grid.num_rows);
    std.debug.assert(abs_end.col >= 0 and abs_end.col < term.cols);

    var match_start_row = abs_start.row;
    var match_start_col = abs_start.col;

    while (true) {
        const row = rows[@intCast(match_start_row)];
        if (row == null) {
            if (match_start_row == abs_end.row)
                break;
            match_start_row = if (backward)
                (match_start_row - 1 + grid.num_rows) & mask
            else
                (match_start_row + 1) & mask;
            continue;
        }
        const cells = row.?.cells.?;

        inner: while (if (backward) match_start_col >= 0 else match_start_col < term.cols) {
            if (matchesCell(term, &cells[@intCast(match_start_col)], 0) < 0) {
                if (match_start_row == abs_end.row and match_start_col == abs_end.col)
                    break :inner;
                match_start_col += if (backward) -1 else 1;
                continue;
            }

            // Got a match on the first letter. Now see if the rest of the
            // search buffer matches.
            log_msg(
                LOG_CLASS_DEBUG,
                "search",
                "search.zig",
                @intCast(@src().line),
                "search: initial match at row=%d, col=%d",
                match_start_row,
                match_start_col,
            );

            var match_end_row = match_start_row;
            var match_end_col = match_start_col;
            var match_row: ?*types.Row = row;
            var match_len: usize = 0;

            var i: usize = 0;
            while (i < term.search.len) {
                if (match_end_col >= term.cols) {
                    match_end_row = (match_end_row + 1) & mask;
                    match_end_col = 0;

                    match_row = rows[@intCast(match_end_row)] orelse break;
                }

                const cells_now = match_row.?.cells.?;
                if (cells_now[@intCast(match_end_col)].wc >= CELL_SPACER) {
                    match_end_col += 1;
                    continue;
                }

                const additional_chars = matchesCell(term, &cells_now[@intCast(match_end_col)], i);
                if (additional_chars < 0)
                    break;

                const additional: usize = @intCast(additional_chars);
                i += additional;
                match_len += additional;
                match_end_col += 1;

                while (match_end_col < term.cols and
                    cells_now[@intCast(match_end_col)].wc > CELL_SPACER)
                {
                    match_end_col += 1;
                }
            }

            if (match_len != term.search.len) {
                // Didn't match (completely)
                if (match_start_row == abs_end.row and match_start_col == abs_end.col)
                    break :inner;
                match_start_col += if (backward) -1 else 1;
                continue;
            }

            match.* = .{
                .start = .{ .col = match_start_col, .row = match_start_row },
                .end = .{ .col = match_end_col - 1, .row = match_end_row },
            };
            return true;
        }

        if (match_start_row == abs_end.row and match_start_col == abs_end.col)
            break;

        match_start_col = if (backward) term.cols - 1 else 0;
        match_start_row = if (backward)
            (match_start_row - 1 + grid.num_rows) & mask
        else
            (match_start_row + 1) & mask;
    }

    return false;
}

fn searchUpdateSelection(term: *types.Terminal, match: *const types.Range) void {
    const grid = term.grid.?;

    const start_row = match.start.row;
    const start_col = match.start.col;
    const end_row = match.end.row;

    std.debug.assert(start_row >= 0);
    std.debug.assert(start_row < grid.num_rows);

    var move_viewport = true;

    const view_end = (grid.view + term.rows - 1) & (grid.num_rows - 1);
    if (view_end >= grid.view) {
        // Viewport does *not* wrap around
        if (start_row >= grid.view and end_row <= view_end)
            move_viewport = false;
    } else {
        // Viewport wraps
        if (start_row >= grid.view or end_row <= view_end)
            move_viewport = false;
    }

    if (move_viewport) {
        var rebased_new_view = grid_row_abs_to_sb(grid, term.rows, start_row);

        rebased_new_view -= @divTrunc(term.rows, 2);
        rebased_new_view = @min(@max(rebased_new_view, 0), grid.num_rows - term.rows);

        const old_view = grid.view;
        var new_view = grid_row_sb_to_abs(grid, term.rows, rebased_new_view);

        // Scrollback may not be completely filled yet
        {
            const rows = rowsPtr(grid);
            const mask = grid.num_rows - 1;
            while (rows[@intCast(new_view)] == null)
                new_view = (new_view + 1) & mask;
        }

        // Update view
        grid.view = new_view;
        if (new_view != old_view)
            term_damage_view(term);
    }

    if (start_row != term.search.match.row or
        start_col != term.search.match.col or
        // Pointer leave events trigger selection_finalize() :/
        !term.selection.ongoing)
    {
        var selection_row = start_row - grid.view + grid.num_rows;
        selection_row &= grid.num_rows - 1;

        selection_start(term, start_col, selection_row, .char_wise, false);

        term.search.match.row = start_row;
        term.search.match.col = start_col;
    }

    // Update selection endpoint
    {
        var selection_row = end_row - grid.view + grid.num_rows;
        selection_row &= grid.num_rows - 1;
        selection_update(term, match.end.col, selection_row);
    }
}

export fn search_find_next(term: *types.Terminal, direction: types.SearchDirection) callconv(.c) void {
    const grid = term.grid.?;

    if (term.search.len == 0) {
        term.search.match = .{ .col = -1, .row = -1 };
        term.search.match_len = 0;
        selection_cancel(term);
        return;
    }

    var start = term.search.match;
    const len = term.search.match_len;

    if (!((len == 0 and start.row == -1 and start.col == -1) or
        (len > 0 and start.row >= 0 and start.col >= 0)))
    {
        bug(@src().file, @intCast(@src().line), "search_find_next", "invalid previous match");
    }

    if (len == 0) {
        // No previous match, start from the top, or bottom, of the scrollback
        switch (direction) {
            .forward => {
                start.row = terminal_shim_grid_row_absolute_in_view(grid, 0);
                start.col = 0;
            },
            .backward, .backward_same_position => {
                start.row = terminal_shim_grid_row_absolute_in_view(grid, term.rows - 1);
                start.col = term.cols - 1;
            },
        }
    } else {
        // Continue from the last match
        switch (direction) {
            .backward_same_position => {},

            .backward => {
                start.col -= 1;
                if (start.col < 0) {
                    start.col = term.cols - 1;
                    start.row += grid.num_rows - 1;
                    start.row &= grid.num_rows - 1;
                }
            },

            .forward => {
                start.col += 1;
                if (start.col >= term.cols) {
                    start.col = 0;
                    start.row += 1;
                    start.row &= grid.num_rows - 1;
                }
            },
        }

        std.debug.assert(start.row >= 0 and start.row < grid.num_rows);
        std.debug.assert(start.col >= 0 and start.col < term.cols);
    }

    log_msg(
        LOG_CLASS_DEBUG,
        "search",
        "search.zig",
        @intCast(@src().line),
        "update: %s: starting at row=%d col=%d (offset = %d, view = %d)",
        @as([*:0]const u8, if (direction != .forward) "backward" else "forward"),
        start.row,
        start.col,
        grid.offset,
        grid.view,
    );

    var end = start;
    switch (direction) {
        .forward => {
            // Search forward, until we reach the cell *before* current start
            end.col -= 1;
            if (end.col < 0) {
                end.col = term.cols - 1;
                end.row += grid.num_rows - 1;
                end.row &= grid.num_rows - 1;
            }
        },

        .backward, .backward_same_position => {
            // Search backwards, until we reach the cell *after* current start
            end.col += 1;
            if (end.col >= term.cols) {
                end.col = 0;
                end.row += 1;
                end.row &= grid.num_rows - 1;
            }
        },
    }

    var match: types.Range = undefined;
    const found = findNext(term, direction, start, end, &match);

    if (found) {
        log_msg(
            LOG_CLASS_DEBUG,
            "search",
            "search.zig",
            @intCast(@src().line),
            "primary match found at %dx%d",
            match.start.row,
            match.start.col,
        );
        searchUpdateSelection(term, &match);
        term.search.match = match.start;
        term.search.match_len = term.search.len;
    } else {
        log_msg(LOG_CLASS_DEBUG, "search", "search.zig", @intCast(@src().line), "no match");
        term.search.match = .{ .col = -1, .row = -1 };
        term.search.match_len = 0;
        selection_cancel(term);
    }
}

export fn search_matches_new_iter(term: *types.Terminal) callconv(.c) SearchMatchIterator {
    return .{
        .term = term,
        .start = .{ .col = 0, .row = 0 },
    };
}

export fn search_matches_next(iter: *SearchMatchIterator) callconv(.c) types.Range {
    const term = iter.term;
    const grid = term.grid.?;

    if (term.search.match_len == 0 or iter.start.row >= term.rows)
        return noMatch(iter);

    std.debug.assert(iter.start.row >= 0 and iter.start.row < term.rows);
    std.debug.assert(iter.start.col >= 0 and iter.start.col < term.cols);

    var abs_start = iter.start;
    abs_start.row = terminal_shim_grid_row_absolute_in_view(grid, abs_start.row);

    const abs_end = types.Coord{
        .col = term.cols - 1,
        .row = terminal_shim_grid_row_absolute_in_view(grid, term.rows - 1),
    };

    // BUG: matches that *start* outside the view, but *end* inside, aren't
    // matched (same as C).
    var match: types.Range = undefined;
    if (!findNext(term, .forward, abs_start, abs_end, &match))
        return noMatch(iter);

    // Convert absolute row numbers back to view relative
    match.start.row = match.start.row - grid.view + grid.num_rows;
    match.start.row &= grid.num_rows - 1;
    match.end.row = match.end.row - grid.view + grid.num_rows;
    match.end.row &= grid.num_rows - 1;

    // Assert match end comes *after* the match start
    std.debug.assert(match.end.row > match.start.row or
        (match.end.row == match.start.row and match.end.col >= match.start.col));

    // Assert the match starts at, or after, the iterator position
    std.debug.assert(match.start.row > iter.start.row or
        (match.start.row == iter.start.row and match.start.col >= iter.start.col));

    // Continue at next column, next time
    iter.start.row = match.start.row;
    iter.start.col = match.start.col + 1;

    if (iter.start.col >= term.cols) {
        iter.start.col = 0;
        iter.start.row += 1; // Overflow is caught in next iteration
    }

    std.debug.assert(iter.start.row >= 0 and iter.start.row <= term.rows);
    std.debug.assert(iter.start.col >= 0 and iter.start.col < term.cols);
    return match;
}

fn noMatch(iter: *SearchMatchIterator) types.Range {
    iter.start.row = -1;
    iter.start.col = -1;
    return .{ .start = .{ .col = -1, .row = -1 }, .end = .{ .col = -1, .row = -1 } };
}

fn addWchars(term: *types.Terminal, src: []u32, count_in: usize) void {
    var count = count_in;

    // Strip non-printable characters
    var i: usize = 0;
    var j: usize = 0;
    while (i < count_in) : (i += 1) {
        if (terminal_shim_isc32print(src[i])) {
            src[j] = src[i];
            j += 1;
        } else {
            count -= 1;
        }
    }

    if (!searchEnsureSize(term, term.search.len + count))
        return;

    const buf = term.search.buf.?;
    if (term.search.len + count >= term.search.sz)
        bug(@src().file, @intCast(@src().line), "add_wchars", "search buffer size assertion");

    const cursor = term.search.cursor;
    const tail = term.search.len - cursor;

    // Make room for the new characters at the cursor
    std.mem.copyBackwards(u32, buf[cursor + count .. cursor + count + tail], buf[cursor .. cursor + tail]);
    // Cut the buffer tail (C stores the NUL one past len)
    @memcpy(buf[cursor .. cursor + count], src[0..count]);

    term.search.len += count;
    term.search.cursor += count;
    buf[term.search.len] = 0;
}

export fn search_add_chars(term: *types.Terminal, src: [*c]const u8, count: usize) callconv(.c) void {
    const chars = mbsntoc32(null, src, count, 0);
    if (chars == std.math.maxInt(usize)) {
        log_errno(
            LOG_CLASS_ERROR,
            "search",
            "search.zig",
            @intCast(@src().line),
            "failed to convert %.*s to Unicode",
            @as(c_int, @intCast(count)),
            src,
        );
        return;
    }

    // C uses a VLA here; a heap buffer is the same amount of work and keeps
    // this frame small.
    const buf: [*]u32 = @ptrCast(@alignCast(xmalloc(chars * @sizeOf(u32)).?));

    _ = mbsntoc32(buf, src, count, chars);
    addWchars(term, buf[0..chars], chars);

    std.c.free(@as(?*anyopaque, @ptrCast(buf)));
}

// ─────────────────────────────────────────────────────────────────────────
// Search lifecycle
// ─────────────────────────────────────────────────────────────────────────

extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;

fn resetIme(term: *types.Terminal) void {
    if (term_ime_is_enabled(term)) {
        term_ime_disable(term);
        term_ime_enable(term);
    }
}

fn searchCancelKeepSelection(term: *types.Terminal) void {
    const win = term.window.?;
    wayl_win_subsurface_destroy(&win.search);

    if (term.search.len > 0) {
        free(@as(?*anyopaque, @ptrCast(term.search.last.buf)));
        term.search.last.buf = term.search.buf;
        term.search.last.len = term.search.len;
    } else {
        free(@as(?*anyopaque, @ptrCast(term.search.buf)));
    }

    term.search.buf = null;
    term.search.len = 0;
    term.search.sz = 0;

    term.search.cursor = 0;
    term.search.match = .{ .col = -1, .row = -1 };
    term.search.match_len = 0;
    term.is_searching = false;
    term.render.search_glyph_offset = 0;

    resetIme(term);

    term_xcursor_update(term);
    render_refresh(term);
}

export fn search_begin(term: *types.Terminal) callconv(.c) void {
    log_msg(LOG_CLASS_DEBUG, "search", "search.zig", @intCast(@src().line), "search: begin");

    searchCancelKeepSelection(term);
    selection_cancel(term);
    resetIme(term);

    // On-demand instantiate the wayland surface
    const win = term.window.?;
    const ret = wayl_win_subsurface_new(win, &win.search, false);
    if (!ret) bug(@src().file, @intCast(@src().line), "search_begin", "assertion failed");

    const grid = term.grid.?;
    term.search.original_view = grid.view;
    term.search.view_followed_offset = grid.view == grid.offset;
    term.is_searching = true;

    term.search.len = 0;
    term.search.sz = 64;
    term.search.buf = @ptrCast(@alignCast(xmalloc(term.search.sz * @sizeOf(u32)) orelse unreachable));
    term.search.buf.?[0] = 0;

    term_xcursor_update(term);
    render_refresh_search(term);
}

export fn search_cancel(term: *types.Terminal) callconv(.c) void {
    if (!term.is_searching)
        return;

    searchCancelKeepSelection(term);
    selection_cancel(term);
}

export fn search_selection_cancelled(term: *types.Terminal) callconv(.c) void {
    term.search.match = .{ .col = -1, .row = -1 };
    term.search.match_len = 0;
    render_refresh_search(term);
}

// ─────────────────────────────────────────────────────────────────────────
// Coordinate helpers and the extend/word/line selectors
// ─────────────────────────────────────────────────────────────────────────

fn coordAdvanceLeft(term: *const types.Terminal, pos: *types.Coord, row: ?*?*const types.Row) bool {
    const grid = term.grid.?;
    var new_pos = pos.*;

    new_pos.col -= 1;
    if (new_pos.col < 0) {
        new_pos.row = (new_pos.row - 1 + grid.num_rows) & (grid.num_rows - 1);
        new_pos.col = term.cols - 1;

        if (hasWrappedAroundLeft(term, new_pos.row))
            return false;

        if (row) |r|
            r.* = grid.rows.?[@intCast(new_pos.row)];
    }

    pos.* = new_pos;
    return true;
}

fn coordAdvanceRight(term: *const types.Terminal, pos: *types.Coord, row: ?*?*const types.Row) bool {
    const grid = term.grid.?;
    var new_pos = pos.*;

    new_pos.col += 1;
    if (new_pos.col >= term.cols) {
        new_pos.row = (new_pos.row + 1) & (grid.num_rows - 1);
        new_pos.col = 0;

        if (hasWrappedAroundRight(term, new_pos.row))
            return false;

        if (row) |r|
            r.* = grid.rows.?[@intCast(new_pos.row)];
    }

    pos.* = new_pos;
    return true;
}

fn searchExtendFindChar(
    term: *const types.Terminal,
    target: *types.Coord,
    direction: types.ExtendDirection,
) bool {
    if (term.search.match_len == 0)
        return false;

    var pos = switch (direction) {
        .left => selection_get_start(term),
        .right => selection_get_end(term),
    };
    std.debug.assert(pos.row >= 0);
    std.debug.assert(pos.row < term.grid.?.num_rows);

    target.* = pos;

    var row: ?*const types.Row = term.grid.?.rows.?[@intCast(pos.row)];

    while (true) {
        switch (direction) {
            .left => if (!coordAdvanceLeft(term, &pos, &row)) return false,
            .right => if (!coordAdvanceRight(term, &pos, &row)) return false,
        }

        const wc = row.?.cells.?[@intCast(pos.col)].wc;

        if (wc >= CELL_SPACER or wc == 0)
            continue;

        target.* = pos;
        return true;
    }
}

fn searchExtendFindCharLeft(term: *const types.Terminal, target: *types.Coord) bool {
    return searchExtendFindChar(term, target, .left);
}

fn searchExtendFindCharRight(term: *const types.Terminal, target: *types.Coord) bool {
    return searchExtendFindChar(term, target, .right);
}

fn searchExtendFindWord(
    term: *const types.Terminal,
    spaces_only: bool,
    target: *types.Coord,
    direction: types.ExtendDirection,
) bool {
    if (term.search.match_len == 0)
        return false;

    const grid = term.grid.?;
    var pos = switch (direction) {
        .left => selection_get_start(term),
        .right => selection_get_end(term),
    };

    std.debug.assert(pos.row >= 0);
    std.debug.assert(pos.row < grid.num_rows);

    target.* = pos;

    // First character to consider is the *next* character
    switch (direction) {
        .left => if (!coordAdvanceLeft(term, &pos, null)) return false,
        .right => if (!coordAdvanceRight(term, &pos, null)) return false,
    }

    std.debug.assert(pos.row >= 0);
    std.debug.assert(pos.row < grid.num_rows);
    std.debug.assert(grid.rows.?[@intCast(pos.row)] != null);

    // Find next word boundary
    switch (direction) {
        .left => selection_find_word_boundary_left(term, &pos, spaces_only),
        .right => selection_find_word_boundary_right(term, &pos, spaces_only, false),
    }

    target.* = pos;
    return true;
}

fn searchExtendFindWordLeft(term: *const types.Terminal, spaces_only: bool, target: *types.Coord) bool {
    return searchExtendFindWord(term, spaces_only, target, .left);
}

fn searchExtendFindWordRight(term: *const types.Terminal, spaces_only: bool, target: *types.Coord) bool {
    return searchExtendFindWord(term, spaces_only, target, .right);
}

fn searchExtendFindLine(
    term: *const types.Terminal,
    target: *types.Coord,
    direction: types.ExtendDirection,
) bool {
    if (term.search.match_len == 0)
        return false;

    var pos = switch (direction) {
        .left => selection_get_start(term),
        .right => selection_get_end(term),
    };

    std.debug.assert(pos.row >= 0);
    std.debug.assert(pos.row < term.grid.?.num_rows);

    target.* = pos;

    const grid = term.grid.?;

    switch (direction) {
        .left => {
            pos.row = (pos.row - 1 + grid.num_rows) & (grid.num_rows - 1);
            if (hasWrappedAroundLeft(term, pos.row))
                return false;
        },
        .right => {
            pos.row = (pos.row + 1) & (grid.num_rows - 1);
            if (hasWrappedAroundRight(term, pos.row))
                return false;
        },
    }

    target.* = pos;
    return true;
}

fn searchExtendFindLineUp(term: *const types.Terminal, target: *types.Coord) bool {
    return searchExtendFindLine(term, target, .left);
}

fn searchExtendFindLineDown(term: *const types.Terminal, target: *types.Coord) bool {
    return searchExtendFindLine(term, target, .right);
}

fn searchExtendLeft(term: *types.Terminal, target: *const types.Coord) void {
    if (term.search.match_len == 0)
        return;

    const last_coord = selection_get_start(term);
    var pos = target.*;
    var row: ?*const types.Row = term.grid.?.rows.?[@intCast(pos.row)];

    const move_cursor = term.search.cursor != 0;

    const ctx = extract_begin(.none, false) orelse return;

    while (pos.col != last_coord.col or pos.row != last_coord.row) {
        if (!extract_one(term, row.?, &row.?.cells.?[@intCast(pos.col)], pos.col, ctx))
            break;
        if (!coordAdvanceRight(term, &pos, &row))
            break;
    }

    var new_text: ?[*]u32 = null;
    var new_len: usize = 0;

    if (!extract_finish_wide(ctx, &new_text, &new_len))
        return;

    if (!searchEnsureSize(term, term.search.len + new_len))
        return;

    const buf = term.search.buf.?;
    _ = memmove(
        @ptrCast(&buf[new_len]),
        @ptrCast(&buf[0]),
        term.search.len * @sizeOf(u32),
    );

    var actually_copied: usize = 0;
    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        if (new_text.?[i] == '\n') {
            // extract() adds newlines, which we never match against
            continue;
        }

        buf[actually_copied] = new_text.?[i];
        actually_copied += 1;
        term.search.len += 1;
    }

    std.debug.assert(actually_copied <= new_len);
    if (actually_copied < new_len) {
        _ = memmove(
            @ptrCast(&buf[actually_copied]),
            @ptrCast(&buf[new_len]),
            (term.search.len - actually_copied) * @sizeOf(u32),
        );
    }

    buf[term.search.len] = 0;
    free(@as(?*anyopaque, @ptrCast(new_text)));

    if (move_cursor)
        term.search.cursor += actually_copied;

    const match: types.Range = .{ .start = target.*, .end = selection_get_end(term) };
    searchUpdateSelection(term, &match);

    term.search.match_len = term.search.len;
}

fn searchExtendRight(term: *types.Terminal, target: *const types.Coord) void {
    if (term.search.match_len == 0)
        return;

    var pos = selection_get_end(term);
    var row: ?*const types.Row = term.grid.?.rows.?[@intCast(pos.row)];

    const move_cursor = term.search.cursor == term.search.len;

    const ctx = extract_begin(.none, false) orelse return;

    while (true) {
        if (!coordAdvanceRight(term, &pos, &row))
            break;
        if (!extract_one(term, row.?, &row.?.cells.?[@intCast(pos.col)], pos.col, ctx))
            break;
        if (pos.col == target.col and pos.row == target.row)
            break;
    }

    var new_text: ?[*]u32 = null;
    var new_len: usize = 0;

    if (!extract_finish_wide(ctx, &new_text, &new_len))
        return;

    if (!searchEnsureSize(term, term.search.len + new_len))
        return;

    const buf = term.search.buf.?;
    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        if (new_text.?[i] == '\n') {
            // extract() adds newlines, which we never match against
            continue;
        }

        buf[term.search.len] = new_text.?[i];
        term.search.len += 1;
    }

    buf[term.search.len] = 0;
    free(@as(?*anyopaque, @ptrCast(new_text)));

    if (move_cursor)
        term.search.cursor = term.search.len;

    const match: types.Range = .{ .start = term.search.match, .end = target.* };
    searchUpdateSelection(term, &match);
    term.search.match_len = term.search.len;
}

fn distanceNextWord(term: *const types.Terminal) usize {
    var cursor = term.search.cursor;
    const buf = term.search.buf.?;

    // First eat non-whitespace. This is the word we're skipping past
    while (cursor < term.search.len) {
        const c = buf[cursor];
        cursor += 1;
        if (terminal_shim_isc32space(c))
            break;
    }

    std.debug.assert(cursor == term.search.len or terminal_shim_isc32space(buf[cursor - 1]));

    // Now skip past whitespace, so that we end up at the beginning of
    // the next word
    while (cursor < term.search.len) {
        const c = buf[cursor];
        cursor += 1;
        if (!terminal_shim_isc32space(c))
            break;
    }

    std.debug.assert(cursor == term.search.len or !terminal_shim_isc32space(buf[cursor - 1]));

    if (cursor < term.search.len and !terminal_shim_isc32space(buf[cursor]))
        cursor -= 1;

    return cursor - term.search.cursor;
}

fn distancePrevWord(term: *const types.Terminal) usize {
    var cursor: usize = term.search.cursor;
    const buf = term.search.buf.?;

    // First, eat whitespace prefix
    while (cursor > 0) {
        cursor -= 1;
        if (!terminal_shim_isc32space(buf[cursor]))
            break;
    }

    std.debug.assert(cursor == 0 or !terminal_shim_isc32space(buf[cursor]));

    // Now eat non-whitespace. This is the word we're skipping past
    while (cursor > 0) {
        cursor -= 1;
        if (terminal_shim_isc32space(buf[cursor]))
            break;
    }

    std.debug.assert(cursor == 0 or terminal_shim_isc32space(buf[cursor]));
    if (cursor > 0 and terminal_shim_isc32space(buf[cursor]))
        cursor += 1;

    return term.search.cursor - cursor;
}

// ─────────────────────────────────────────────────────────────────────────
// Search-mode key handling
// ─────────────────────────────────────────────────────────────────────────

const tll = @import("tll.zig");

// key-binding.h's `struct key_binding` is terminal_types.KeyBinding (D5);
// the anonymous union is reachable as `_u`.
const KeyBinding = types.KeyBinding;
pub const KeyBindingList = tll.Tll(KeyBinding);

// key-binding.h's `struct key_binding_set` now lives in terminal_types.zig.
pub const KeyBindingSet = @import("terminal_types.zig").KeyBindingSet;

// bind_action_search
const SEARCH_NONE: c_int = 0;
const SEARCH_SCROLLBACK_UP_PAGE: c_int = 1;
const SEARCH_SCROLLBACK_UP_HALF_PAGE: c_int = 2;
const SEARCH_SCROLLBACK_UP_LINE: c_int = 3;
const SEARCH_SCROLLBACK_DOWN_PAGE: c_int = 4;
const SEARCH_SCROLLBACK_DOWN_HALF_PAGE: c_int = 5;
const SEARCH_SCROLLBACK_DOWN_LINE: c_int = 6;
const SEARCH_SCROLLBACK_HOME: c_int = 7;
const SEARCH_SCROLLBACK_END: c_int = 8;
const SEARCH_CANCEL: c_int = 9;
const SEARCH_COMMIT: c_int = 10;
const SEARCH_FIND_PREV: c_int = 11;
const SEARCH_FIND_NEXT: c_int = 12;
const SEARCH_EDIT_LEFT: c_int = 13;
const SEARCH_EDIT_LEFT_WORD: c_int = 14;
const SEARCH_EDIT_RIGHT: c_int = 15;
const SEARCH_EDIT_RIGHT_WORD: c_int = 16;
const SEARCH_EDIT_HOME: c_int = 17;
const SEARCH_EDIT_END: c_int = 18;
const SEARCH_DELETE_PREV: c_int = 19;
const SEARCH_DELETE_PREV_WORD: c_int = 20;
const SEARCH_DELETE_NEXT: c_int = 21;
const SEARCH_DELETE_NEXT_WORD: c_int = 22;
const SEARCH_DELETE_TO_START: c_int = 23;
const SEARCH_DELETE_TO_END: c_int = 24;
const SEARCH_EXTEND_CHAR: c_int = 25;
const SEARCH_EXTEND_WORD: c_int = 26;
const SEARCH_EXTEND_WORD_WS: c_int = 27;
const SEARCH_EXTEND_LINE_DOWN: c_int = 28;
const SEARCH_EXTEND_BACKWARD_CHAR: c_int = 29;
const SEARCH_EXTEND_BACKWARD_WORD: c_int = 30;
const SEARCH_EXTEND_BACKWARD_WORD_WS: c_int = 31;
const SEARCH_EXTEND_LINE_UP: c_int = 32;
const SEARCH_CLIPBOARD_PASTE: c_int = 33;
const SEARCH_PRIMARY_PASTE: c_int = 34;
const SEARCH_UNICODE_INPUT: c_int = 35;

extern fn cmd_scrollback_up(term: *types.Terminal, rows: c_int) callconv(.c) void;
extern fn cmd_scrollback_down(term: *types.Terminal, rows: c_int) callconv(.c) void;
extern fn selection_finalize(seat: *types.Seat, term: *types.Terminal, serial: u32) callconv(.c) void;
extern fn text_from_clipboard(
    seat: *types.Seat,
    term: *types.Terminal,
    no_strip: bool,
    cb: *const fn ([*c]u8, usize, ?*anyopaque) callconv(.c) void,
    done: *const fn (?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
) callconv(.c) void;
extern fn text_from_primary(
    seat: *types.Seat,
    term: *types.Terminal,
    no_strip: bool,
    cb: *const fn ([*c]u8, usize, ?*anyopaque) callconv(.c) void,
    done: *const fn (?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
) callconv(.c) void;
extern fn unicode_mode_activate(term: *types.Terminal) callconv(.c) void;

// libxkbcommon
const XKB_COMPOSE_NOTHING: c_int = 0;
const XKB_COMPOSE_COMPOSING: c_int = 1;
const XKB_COMPOSE_COMPOSED: c_int = 2;
const XKB_COMPOSE_CANCELLED: c_int = 3;

extern fn xkb_compose_state_get_status(state: ?*anyopaque) callconv(.c) c_int;
extern fn xkb_compose_state_get_utf8(state: ?*anyopaque, buf: [*c]u8, size: usize) callconv(.c) c_int;
extern fn xkb_compose_state_reset(state: ?*anyopaque) callconv(.c) void;
extern fn xkb_state_key_get_utf8(state: ?*anyopaque, key: u32, buf: [*c]u8, size: usize) callconv(.c) c_int;

fn fromClipboardCb(text: [*c]u8, size: usize, user: ?*anyopaque) callconv(.c) void {
    search_add_chars(@ptrCast(@alignCast(user.?)), text, size);
}

fn fromClipboardDone(user: ?*anyopaque) callconv(.c) void {
    const term: *types.Terminal = @ptrCast(@alignCast(user.?));
    log_msg(LOG_CLASS_DEBUG, "search", "search.zig", @intCast(@src().line), "search: buffer: %ls", @as([*c]const u32, @ptrCast(term.search.buf.?)));
    search_find_next(term, .backward_same_position);
    render_refresh_search(term);
}

fn executeBinding(
    seat: *types.Seat,
    term: *types.Terminal,
    binding: *const KeyBinding,
    serial: u32,
    update_search_result: *bool,
    direction: *types.SearchDirection,
    redraw: *bool,
) bool {
    update_search_result.* = false;
    redraw.* = false;
    const action = binding.action;

    const grid = term.grid.?;

    switch (action) {
        SEARCH_NONE => return false,

        SEARCH_SCROLLBACK_UP_PAGE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_up(term, term.rows);
                return true;
            }
            return false;
        },

        SEARCH_SCROLLBACK_UP_HALF_PAGE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_up(term, @max(@divTrunc(term.rows, 2), 1));
                return true;
            }
        },

        SEARCH_SCROLLBACK_UP_LINE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_up(term, 1);
                return true;
            }
        },

        SEARCH_SCROLLBACK_DOWN_PAGE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_down(term, term.rows);
                return true;
            }
            return false;
        },

        SEARCH_SCROLLBACK_DOWN_HALF_PAGE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_down(term, @max(@divTrunc(term.rows, 2), 1));
                return true;
            }
        },

        SEARCH_SCROLLBACK_DOWN_LINE => {
            if (term.grid == &term.normal) {
                cmd_scrollback_down(term, 1);
                return true;
            }
        },

        SEARCH_SCROLLBACK_HOME => {
            if (term.grid == &term.normal) {
                cmd_scrollback_up(term, term.grid.?.num_rows);
                return true;
            }
        },

        SEARCH_SCROLLBACK_END => {
            if (term.grid == &term.normal) {
                cmd_scrollback_down(term, term.grid.?.num_rows);
                return true;
            }
        },

        SEARCH_CANCEL => {
            if (term.search.view_followed_offset) {
                grid.view = grid.offset;
            } else {
                grid.view = ensureViewIsAllocated(term, term.search.original_view);
            }
            term_damage_view(term);
            search_cancel(term);
            return true;
        },

        SEARCH_COMMIT => {
            selection_finalize(seat, term, serial);
            searchCancelKeepSelection(term);
            return true;
        },

        SEARCH_FIND_PREV, SEARCH_FIND_NEXT => {
            if (term.search.last.buf != null and term.search.len == 0) {
                addWchars(term, term.search.last.buf.?[0..term.search.last.len], term.search.last.len);

                free(@as(?*anyopaque, @ptrCast(term.search.last.buf)));
                term.search.last.buf = null;
                term.search.last.len = 0;
            }

            direction.* = if (action == SEARCH_FIND_PREV) .backward else .forward;
            update_search_result.* = true;
            redraw.* = true;
            return true;
        },

        SEARCH_EDIT_LEFT => {
            if (term.search.cursor > 0) {
                term.search.cursor -= 1;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EDIT_LEFT_WORD => {
            const diff = distancePrevWord(term);
            term.search.cursor -= diff;
            std.debug.assert(term.search.cursor <= term.search.len);

            if (diff > 0)
                redraw.* = true;
            return true;
        },

        SEARCH_EDIT_RIGHT => {
            if (term.search.cursor < term.search.len) {
                term.search.cursor += 1;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EDIT_RIGHT_WORD => {
            const diff = distanceNextWord(term);
            term.search.cursor += diff;
            std.debug.assert(term.search.cursor <= term.search.len);

            if (diff > 0)
                redraw.* = true;
            return true;
        },

        SEARCH_EDIT_HOME => {
            if (term.search.cursor != 0) {
                term.search.cursor = 0;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EDIT_END => {
            if (term.search.cursor != term.search.len) {
                term.search.cursor = term.search.len;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_PREV => {
            if (term.search.cursor > 0) {
                const buf = term.search.buf.?;
                _ = memmove(
                    @ptrCast(&buf[term.search.cursor - 1]),
                    @ptrCast(&buf[term.search.cursor]),
                    (term.search.len - term.search.cursor) * @sizeOf(u32),
                );
                term.search.cursor -= 1;
                term.search.len -= 1;
                buf[term.search.len] = 0;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_PREV_WORD => {
            const diff = distancePrevWord(term);
            const old_cursor = term.search.cursor;
            const new_cursor = old_cursor - diff;

            if (diff > 0) {
                const buf = term.search.buf.?;
                _ = memmove(
                    @ptrCast(&buf[new_cursor]),
                    @ptrCast(&buf[old_cursor]),
                    (term.search.len - old_cursor) * @sizeOf(u32),
                );

                term.search.len -= diff;
                term.search.cursor = new_cursor;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_NEXT => {
            if (term.search.cursor < term.search.len) {
                const buf = term.search.buf.?;
                _ = memmove(
                    @ptrCast(&buf[term.search.cursor]),
                    @ptrCast(&buf[term.search.cursor + 1]),
                    (term.search.len - term.search.cursor - 1) * @sizeOf(u32),
                );
                term.search.len -= 1;
                buf[term.search.len] = 0;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_NEXT_WORD => {
            const diff = distanceNextWord(term);
            const cursor = term.search.cursor;

            if (diff > 0) {
                const buf = term.search.buf.?;
                _ = memmove(
                    @ptrCast(&buf[cursor]),
                    @ptrCast(&buf[cursor + diff]),
                    (term.search.len - (cursor + diff)) * @sizeOf(u32),
                );

                term.search.len -= diff;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_TO_START => {
            if (term.search.cursor > 0) {
                const buf = term.search.buf.?;
                _ = memmove(
                    @ptrCast(&buf[0]),
                    @ptrCast(&buf[term.search.cursor]),
                    (term.search.len - term.search.cursor) * @sizeOf(u32),
                );

                term.search.len -= term.search.cursor;
                term.search.cursor = 0;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_DELETE_TO_END => {
            if (term.search.cursor < term.search.len) {
                term.search.buf.?[term.search.cursor] = 0;
                term.search.len = term.search.cursor;
                update_search_result.* = true;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_CHAR => {
            var target: types.Coord = undefined;
            if (searchExtendFindCharRight(term, &target)) {
                searchExtendRight(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_WORD, SEARCH_EXTEND_WORD_WS => {
            var target: types.Coord = undefined;
            if (searchExtendFindWordRight(term, action == SEARCH_EXTEND_WORD_WS, &target)) {
                searchExtendRight(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_LINE_DOWN => {
            var target: types.Coord = undefined;
            if (searchExtendFindLineDown(term, &target)) {
                searchExtendRight(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_BACKWARD_CHAR => {
            var target: types.Coord = undefined;
            if (searchExtendFindCharLeft(term, &target)) {
                searchExtendLeft(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_BACKWARD_WORD, SEARCH_EXTEND_BACKWARD_WORD_WS => {
            var target: types.Coord = undefined;
            if (searchExtendFindWordLeft(term, action == SEARCH_EXTEND_BACKWARD_WORD_WS, &target)) {
                searchExtendLeft(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_EXTEND_LINE_UP => {
            var target: types.Coord = undefined;
            if (searchExtendFindLineUp(term, &target)) {
                searchExtendLeft(term, &target);
                update_search_result.* = false;
                redraw.* = true;
            }
            return true;
        },

        SEARCH_CLIPBOARD_PASTE => {
            text_from_clipboard(seat, term, false, &fromClipboardCb, &fromClipboardDone, term);
            update_search_result.* = true;
            redraw.* = true;
            return true;
        },

        SEARCH_PRIMARY_PASTE => {
            text_from_primary(seat, term, false, &fromClipboardCb, &fromClipboardDone, term);
            update_search_result.* = true;
            redraw.* = true;
            return true;
        },

        SEARCH_UNICODE_INPUT => {
            unicode_mode_activate(term);
            return true;
        },

        else => {
            if (action == 36) // BIND_ACTION_SEARCH_COUNT
                bug(@src().file, @intCast(@src().line), "execute_binding", "Invalid action type");
            bug(@src().file, @intCast(@src().line), "execute_binding", "Unhandled action type");
        },
    }

    bug(@src().file, @intCast(@src().line), "execute_binding", "Unhandled action type");
}

export fn search_input(
    seat: *types.Seat,
    term: *types.Terminal,
    bindings: *const KeyBindingSet,
    key: u32,
    sym: u32,
    mods: u32,
    consumed: u32,
    raw_syms: [*c]const u32,
    raw_count: usize,
    serial: u32,
) callconv(.c) void {
    log_msg(
        LOG_CLASS_DEBUG,
        "search",
        "search.zig",
        @intCast(@src().line),
        "search: input: sym=%d/0x%x, mods=0x%08x, consumed=0x%08x",
        sym,
        sym,
        mods,
        consumed,
    );

    const compose_status: c_int = if (seat.kbd.xkb_compose_state != null)
        xkb_compose_state_get_status(seat.kbd.xkb_compose_state)
    else
        XKB_COMPOSE_NOTHING;

    var search_direction: types.SearchDirection = .backward_same_position;
    var update_search_result = false;
    var redraw = false;

    // Key bindings

    // Match untranslated symbols
    const search_list: *tll.Tll(KeyBinding) = @ptrCast(@constCast(&bindings.search));
    var it = search_list.foreach();
    while (it.next()) |node| {
        const bind = &node.item;

        if (bind.mods != mods or bind.mods == 0)
            continue;

        var i: usize = 0;
        while (i < raw_count) : (i += 1) {
            if (bind._u.k.sym == raw_syms[i]) {
                if (executeBinding(seat, term, bind, serial, &update_search_result, &search_direction, &redraw)) {
                    seat.kbd.last_shortcut_sym = sym;
                    return searchUpdate(term, update_search_result, redraw, search_direction);
                }
                return;
            }
        }
    }

    // Match translated symbol
    it = search_list.foreach();
    while (it.next()) |node| {
        const bind = &node.item;

        if (bind._u.k.sym == sym and bind.mods == (mods & ~consumed)) {
            if (executeBinding(seat, term, bind, serial, &update_search_result, &search_direction, &redraw)) {
                seat.kbd.last_shortcut_sym = sym;
                return searchUpdate(term, update_search_result, redraw, search_direction);
            }
            return;
        }
    }

    // Match raw key code
    it = search_list.foreach();
    while (it.next()) |node| {
        const bind = &node.item;

        if (bind.mods != mods or bind.mods == 0)
            continue;

        const key_codes: *tll.Tll(u32) = @ptrCast(@constCast(&bind._u.k.key_codes));
        var code_it = key_codes.foreach();
        while (code_it.next()) |code| {
            if (code.item == key) {
                if (executeBinding(seat, term, bind, serial, &update_search_result, &search_direction, &redraw)) {
                    seat.kbd.last_shortcut_sym = sym;
                    return searchUpdate(term, update_search_result, redraw, search_direction);
                }
                return;
            }
        }
    }

    var buf: [64]u8 = @splat(0);
    var count: c_int = 0;

    if (compose_status == XKB_COMPOSE_COMPOSED) {
        count = xkb_compose_state_get_utf8(seat.kbd.xkb_compose_state, &buf, buf.len);
        xkb_compose_state_reset(seat.kbd.xkb_compose_state);
    } else if (compose_status == XKB_COMPOSE_CANCELLED or compose_status == XKB_COMPOSE_COMPOSING) {
        count = 0;
    } else {
        count = xkb_state_key_get_utf8(seat.kbd.xkb_state, key, &buf, buf.len);
    }

    update_search_result = count > 0;
    redraw = count > 0;
    search_direction = .backward_same_position;

    if (count == 0)
        return;

    search_add_chars(term, &buf, @intCast(count));

    searchUpdate(term, update_search_result, redraw, search_direction);
}

/// The `update_search:` label at the end of C's search_input().
fn searchUpdate(
    term: *types.Terminal,
    update_search_result: bool,
    redraw: bool,
    direction: types.SearchDirection,
) void {
    log_msg(LOG_CLASS_DEBUG, "search", "search.zig", @intCast(@src().line), "search: buffer: %ls", @as([*c]const u32, @ptrCast(term.search.buf.?)));
    if (update_search_result)
        search_find_next(term, direction);
    if (redraw)
        render_refresh_search(term);
}
