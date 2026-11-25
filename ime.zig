//! Zig port of ime.c (D5b): the text-input-v3 side of IME support.
//!
//! The compositor's IME talks to us through zwp_text_input_v3: preedit and
//! commit strings arrive as *pending* state and are only applied in `done()`,
//! in the order the protocol prescribes. The preedit is turned into a row of
//! cells here (with the cursor mapped from byte offsets to cell indices) and
//! painted by render.zig; the listener table stays C-side in wayland.c.
//!
//! This build requires `-Dime=true` (meson refuses `ime=false`, since the
//! wayland.h mirrors assume it), so the `#else` stubs ime.c had are not
//! reproduced.

const std = @import("std");
const types = @import("terminal_types.zig");

const Terminal = types.Terminal;
const Seat = types.Seat;

const ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE: u32 = 0;
const ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_TERMINAL: u32 = 13;

const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;
const CELL_SPACER: u32 = CELL_COMB_CHARS_LO + 0x3fff_ffff + 1;

extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn ambstoc32(src: [*c]const u8) callconv(.c) ?[*]u32;
extern fn c32width(c: u32) callconv(.c) c_int;
extern fn mblen(s: [*:0]const u8, n: usize) callconv(.c) c_int;

extern fn term_ime_set_cursor_rect(
    term: *Terminal, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void;
extern fn term_to_slave(term: *Terminal, data: ?*const anyopaque, len: usize) callconv(.c) bool;
extern fn term_reset_view(term: *Terminal) callconv(.c) void;
extern fn selection_cancel(term: *Terminal) callconv(.c) void;
extern fn render_refresh(term: *Terminal) callconv(.c) void;
extern fn render_refresh_search(term: *Terminal) callconv(.c) void;
extern fn search_add_chars(term: *Terminal, src: [*c]const u8, count: usize) callconv(.c) void;
extern fn search_find_next(term: *Terminal, direction: types.SearchDirection) callconv(.c) void;
extern fn wayland_shim_surface_get_user_data(surf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

const LOG_CLASS_WARNING: c_int = 2;

// text-input-v3 requests are generated static inlines.
extern fn terminal_shim_text_input_enable(ti: ?*anyopaque) callconv(.c) void;
extern fn terminal_shim_text_input_disable(ti: ?*anyopaque) callconv(.c) void;
extern fn terminal_shim_text_input_commit(ti: ?*anyopaque) callconv(.c) void;
extern fn terminal_shim_text_input_set_content_type(
    ti: ?*anyopaque, hint: u32, purpose: u32) callconv(.c) void;
extern fn terminal_shim_text_input_set_cursor_rectangle(
    ti: ?*anyopaque, x: i32, y: i32, width: i32, height: i32) callconv(.c) void;

/// C's `x / term->scale` (float divide, truncate to int).
fn scaleInt(v: c_int, scale: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(v)) / scale);
}

fn c32len(s: [*]const u32) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn resetPendingPreedit(seat: *Seat) void {
    free(seat.ime.preedit.pending.text);
    seat.ime.preedit.pending.text = null;
}

fn resetPendingCommit(seat: *Seat) void {
    free(seat.ime.commit.pending.text);
    seat.ime.commit.pending.text = null;
}

export fn ime_reset_pending(seat: *Seat) callconv(.c) void {
    resetPendingPreedit(seat);
    resetPendingCommit(seat);
}

export fn ime_reset_preedit(seat: *Seat) callconv(.c) void {
    if (seat.ime.preedit.cells == null)
        return;

    free(seat.ime.preedit.text);
    free(seat.ime.preedit.cells);
    seat.ime.preedit.text = null;
    seat.ime.preedit.cells = null;
    seat.ime.preedit.count = 0;
}

// ─────────────────────────────────────────────────────────────────────────
// zwp_text_input_v3 listeners
// ─────────────────────────────────────────────────────────────────────────

export fn ime_enter(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    surface: ?*anyopaque,
) callconv(.c) void {
    _ = zwp_text_input_v3;

    if (surface == null) {
        // Seen on Hyprland
        log_msg(
            LOG_CLASS_WARNING, "ime", "ime.zig", @intCast(@src().line),
            "compositor sent ime_enter event with a NULL surface");
        return;
    }

    const seat: *Seat = @ptrCast(@alignCast(data orelse return));
    const win: *types.WlWindow = @ptrCast(@alignCast(
        wayland_shim_surface_get_user_data(surface) orelse return));
    const term: *Terminal = @ptrCast(@alignCast(win.term.?));

    if (seat.kbd_focus != term) {
        log_msg(
            LOG_CLASS_WARNING, "ime", "ime.zig", @intCast(@src().line),
            "compositor sent ime::enter() event before the " ++
                "corresponding keyboard_enter() event");
    }

    // The main grid is the *only* input-receiving surface we have
    seat.ime_focus = term;

    const grid = term.grid orelse return;
    const cursor = &grid.cursor.point;

    term_ime_set_cursor_rect(
        term,
        term.margins.left + cursor.col * term.cell_width,
        term.margins.top + cursor.row * term.cell_height,
        term.cell_width,
        term.cell_height);

    ime_enable(seat);
}

export fn ime_leave(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    surface: ?*anyopaque,
) callconv(.c) void {
    _ = zwp_text_input_v3;
    _ = surface;
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    ime_disable(seat);
    seat.ime_focus = null;
}

export fn ime_preedit_string(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    text: ?[*:0]const u8,
    cursor_begin: i32,
    cursor_end: i32,
) callconv(.c) void {
    _ = zwp_text_input_v3;
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    resetPendingPreedit(seat);

    if (text) |t| {
        seat.ime.preedit.pending.text = xstrdup(t);
        seat.ime.preedit.pending.cursor_begin = cursor_begin;
        seat.ime.preedit.pending.cursor_end = cursor_end;
    }
}

export fn ime_commit_string(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    text: ?[*:0]const u8,
) callconv(.c) void {
    _ = zwp_text_input_v3;
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    resetPendingCommit(seat);

    if (text) |t|
        seat.ime.commit.pending.text = xstrdup(t);
}

export fn ime_delete_surrounding_text(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    before_length: u32,
    after_length: u32,
) callconv(.c) void {
    _ = zwp_text_input_v3;
    const seat: *Seat = @ptrCast(@alignCast(data orelse return));

    seat.ime.surrounding.pending.before_length = before_length;
    seat.ime.surrounding.pending.after_length = after_length;
}

var done_have_warned: bool = false;

export fn ime_done(
    data: ?*anyopaque,
    zwp_text_input_v3: ?*anyopaque,
    serial: u32,
) callconv(.c) void {
    _ = zwp_text_input_v3;

    // From text-input-unstable-v3.h:
    //
    // The application must proceed by evaluating the changes in the following
    // order:
    //
    // 1. Replace existing preedit string with the cursor.
    // 2. Delete requested surrounding text.
    // 3. Insert commit string with the cursor at its end.
    // 4. Calculate surrounding text to send.
    // 5. Insert new preedit text in cursor position.
    // 6. Place cursor inside preedit text.

    const seat: *Seat = @ptrCast(@alignCast(data orelse return));
    const term = seat.ime_focus;

    if (seat.ime.serial != serial)
        return;

    if (term == null and !done_have_warned) {
        log_msg(
            LOG_CLASS_WARNING, "ime", "ime.zig", @intCast(@src().line),
            "%s: text-input::done() received on seat that isn't " ++
                "focusing a terminal window", seat.name.?);
        done_have_warned = true;
    }

    // 1. Delete existing pre-edit text
    if (seat.ime.preedit.cells != null) {
        ime_reset_preedit(seat);

        if (term) |t| {
            if (t.is_searching)
                render_refresh_search(t)
            else {
                term_reset_view(t);
                selection_cancel(t);
                render_refresh(t);
            }
        }
    }

    // 2. Delete requested surrounding text
    //
    // We don't support deleting surrounding text. But, we also never call
    // set_surrounding_text() so hopefully we should never receive any
    // requests to delete surrounding text.

    // 3. Insert commit string
    if (seat.ime.commit.pending.text) |text| {
        const len = std.mem.len(text);

        if (term) |t| {
            if (t.is_searching) {
                search_add_chars(t, text, len);
                search_find_next(t, .backward_same_position);
                render_refresh_search(t);
            } else {
                _ = term_to_slave(t, @ptrCast(text), len);
                term_reset_view(t);
                selection_cancel(t);
                render_refresh(t);
            }
        }
        resetPendingCommit(seat);
    }

    // 4. Calculate surrounding text to send - not supported

    // 5. Insert new pre-edit text
    const pending_text = seat.ime.preedit.pending.text;
    if (pending_text == null or pending_text.?[0] == 0) {
        resetPendingPreedit(seat);
        return;
    }

    const allocated_preedit_text = ambstoc32(pending_text) orelse {
        resetPendingPreedit(seat);
        return;
    };

    seat.ime.preedit.text = allocated_preedit_text;

    const text = allocated_preedit_text;
    const wchars = c32len(text);

    // Next, count number of cells needed
    var cell_count: usize = 0;
    const widths = xmalloc(wchars * @sizeOf(usize)) orelse unreachable;
    defer free(widths);
    const width_slice: [*]usize = @ptrCast(@alignCast(widths));

    var i: usize = 0;
    while (i < wchars) : (i += 1) {
        const width: usize = @intCast(@max(c32width(text[i]), 1));
        width_slice[i] = width;
        cell_count += width;
    }

    // Allocate cells
    const raw_cells = xmalloc(cell_count * @sizeOf(types.Cell)) orelse unreachable;
    const cells: [*]types.Cell = @ptrCast(@alignCast(raw_cells));
    seat.ime.preedit.cells = raw_cells;
    seat.ime.preedit.count = @intCast(cell_count);

    // Populate cells
    i = 0;
    var cell_idx: usize = 0;
    while (i < wchars) : (i += 1) {
        const width = width_slice[i];

        cells[cell_idx].wc = text[i];
        cells[cell_idx].attrs = std.mem.zeroes(types.Attributes);

        var j: usize = 1;
        while (j < width) : (j += 1) {
            cells[cell_idx + j].wc = CELL_SPACER + @as(u32, @intCast(width - j));
            cells[cell_idx + j].attrs = std.mem.zeroes(types.Attributes);
            cells[cell_idx + j].attrs.clean = true;
        }

        cell_idx += width;
    }

    const byte_len: i32 = @intCast(std.mem.len(pending_text.?));

    const pending_begin = seat.ime.preedit.pending.cursor_begin;
    const pending_end = seat.ime.preedit.pending.cursor_end;

    if (pending_begin == -1 or pending_end == -1) {
        // Note: docs says *both* begin and end should be -1, but what else
        // can we do if only one is -1?
        seat.ime.preedit.cursor.hidden = true;
        seat.ime.preedit.cursor.start = -1;
        seat.ime.preedit.cursor.end = -1;
    } else if (pending_begin == byte_len and pending_end == byte_len) {
        // Cursor is *after* the entire pre-edit string
        seat.ime.preedit.cursor.hidden = false;
        seat.ime.preedit.cursor.start = @intCast(cell_count);
        seat.ime.preedit.cursor.end = @intCast(cell_count);
    } else {
        // Translate cursor position to cell indices.
        //
        // cursor_begin/end are counted in *bytes*; map them to *cell*
        // indices by stepping through the utf-8 pre-edit string with
        // mblen(), advancing a unicode index and a cell index (c32width())
        // as we go.
        var cell_begin: c_int = -1;
        var cell_end: c_int = -1;

        var byte_idx: i32 = 0;
        var wc_idx: usize = 0;
        var c_idx: usize = 0;
        while (byte_idx < byte_len and
            wc_idx < wchars and
            c_idx < cell_count and
            (cell_begin < 0 or cell_end < 0))
        {
            if (pending_begin == byte_idx)
                cell_begin = @intCast(c_idx);
            if (pending_end == byte_idx)
                cell_end = @intCast(c_idx);

            // Number of bytes of *next* utf-8 character
            const left: usize = @intCast(byte_len - byte_idx);
            const wc_bytes = mblen(pending_text.? + @as(usize, @intCast(byte_idx)), left);
            if (wc_bytes <= 0)
                break;

            byte_idx += wc_bytes;
            wc_idx += 1;
            c_idx += width_slice[wc_idx - 1];
        }

        if (pending_end >= byte_len)
            cell_end = @intCast(cell_count);

        // Bounded by number of screen columns
        cell_begin = @min(@max(cell_begin, 0), @as(c_int, @intCast(cell_count)) - 1);
        cell_end = @min(@max(cell_end, 0), @as(c_int, @intCast(cell_count)));

        if (cell_end < cell_begin)
            cell_end = cell_begin;

        // Expand cursor end to end of glyph
        while (cell_end > cell_begin and cell_end < @as(c_int, @intCast(cell_count)) and
            cells[@intCast(cell_end)].wc >= CELL_SPACER)
        {
            cell_end += 1;
        }

        std.debug.assert(cell_begin >= 0);
        std.debug.assert(cell_begin < cell_count);
        std.debug.assert(cell_begin <= cell_end);
        std.debug.assert(cell_end >= 0);
        std.debug.assert(cell_end <= cell_count);

        seat.ime.preedit.cursor.hidden = false;
        seat.ime.preedit.cursor.start = cell_begin;
        seat.ime.preedit.cursor.end = cell_end;
    }

    // Underline pre-edit string that is *not* covered by the cursor
    const hidden = seat.ime.preedit.cursor.hidden;
    const start = seat.ime.preedit.cursor.start;
    const end = seat.ime.preedit.cursor.end;

    i = 0;
    cell_idx = 0;
    while (i < wchars) : ({
        cell_idx += width_slice[i];
        i += 1;
    }) {
        if (hidden or start == end or cell_idx < start or cell_idx >= end)
            cells[cell_idx].attrs.underline = true;
    }

    resetPendingPreedit(seat);

    if (term) |t| {
        if (t.is_searching)
            render_refresh_search(t)
        else
            render_refresh(t);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Requesting the IME
// ─────────────────────────────────────────────────────────────────────────

fn imeSendCursorRect(seat: *Seat) void {
    const wayl = seat.wayl orelse return;
    if (wayl.text_input_manager == null)
        return;

    const term = seat.ime_focus orelse return;
    if (!term.ime_enabled)
        return;

    const pending = seat.ime.cursor_rect.pending;
    const sent = seat.ime.cursor_rect.sent;
    if (pending.x == sent.x and
        pending.y == sent.y and
        pending.width == sent.width and
        pending.height == sent.height)
    {
        return;
    }

    terminal_shim_text_input_set_cursor_rectangle(
        seat.wl_text_input,
        scaleInt(pending.x, term.scale),
        scaleInt(pending.y, term.scale),
        scaleInt(pending.width, term.scale),
        scaleInt(pending.height, term.scale));

    terminal_shim_text_input_commit(seat.wl_text_input);
    seat.ime.serial += 1;

    seat.ime.cursor_rect.sent = pending;
}

export fn ime_enable(seat: *Seat) callconv(.c) void {
    const wayl = seat.wayl orelse return;
    if (wayl.text_input_manager == null)
        return;

    const term = seat.ime_focus orelse return;
    if (!term.ime_enabled)
        return;

    ime_reset_pending(seat);
    ime_reset_preedit(seat);

    terminal_shim_text_input_enable(seat.wl_text_input);
    terminal_shim_text_input_set_content_type(
        seat.wl_text_input,
        ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE,
        ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_TERMINAL);

    const pending = seat.ime.cursor_rect.pending;
    terminal_shim_text_input_set_cursor_rectangle(
        seat.wl_text_input,
        scaleInt(pending.x, term.scale),
        scaleInt(pending.y, term.scale),
        scaleInt(pending.width, term.scale),
        scaleInt(pending.height, term.scale));

    seat.ime.cursor_rect.sent = pending;

    terminal_shim_text_input_commit(seat.wl_text_input);
    seat.ime.serial += 1;
}

export fn ime_disable(seat: *Seat) callconv(.c) void {
    const wayl = seat.wayl orelse return;
    if (wayl.text_input_manager == null)
        return;

    if (seat.ime_focus == null)
        return;

    ime_reset_pending(seat);
    ime_reset_preedit(seat);

    terminal_shim_text_input_disable(seat.wl_text_input);
    terminal_shim_text_input_commit(seat.wl_text_input);
    seat.ime.serial += 1;
}

export fn ime_update_cursor_rect(seat: *Seat) callconv(.c) void {
    const term = seat.ime_focus orelse return;

    // Set in render_ime_preedit()
    if (seat.ime.preedit.cells != null) {
        imeSendCursorRect(seat);
        return;
    }

    // Set in render_search_box()
    if (term.is_searching) {
        imeSendCursorRect(seat);
        return;
    }

    const grid = term.grid.?;
    const col = grid.cursor.point.col;
    var row = grid.cursor.point.row;
    row += grid.offset;
    row -= grid.view;
    row &= grid.num_rows - 1;

    const x = term.margins.left + col * term.cell_width;
    const y = term.margins.top + row * term.cell_height;

    const width: c_int = if (term.cursor_style == .beam) 1 else term.cell_width;
    const height = term.cell_height;

    seat.ime.cursor_rect.pending.x = x;
    seat.ime.cursor_rect.pending.y = y;
    seat.ime.cursor_rect.pending.width = width;
    seat.ime.cursor_rect.pending.height = height;

    imeSendCursorRect(seat);
}
