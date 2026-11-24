const std = @import("std");
const types = @import("terminal_types.zig");

// Port of extract.c. Turns a row/cell range into text, honouring hard
// linebreaks, empty cells, tab stops and composed (grapheme-cluster) cells.
//
// The C API in extract.h is unchanged: extract_begin() returns an opaque
// context that must be passed to extract_one() any number of times and then
// to extract_finish()/extract_finish_wide(), which consume it.

const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fffffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

extern fn composed_lookup(root: ?*types.Composed, key: u32) callconv(.c) ?*types.Composed;
extern fn ac32tombs(src: [*c]const u32) callconv(.c) ?[*:0]u8;
extern fn vt_tab_stops_next_after(term: *types.Terminal, col: c_int) callconv(.c) c_int;

const Context = struct {
    buf: ?[*]u32 = null,
    size: usize = 0,
    idx: usize = 0,
    tab_spaces_left: usize = 0,
    empty_count: usize = 0,
    newline_count: usize = 0,
    strip_trailing_empty: bool = false,
    failed: bool = false,
    last_row: ?*const types.Row = null,
    last_cell: ?*const types.Cell = null,
    selection_kind: types.SelectionKind = .none,
};

fn ensureSize(ctx: *Context, additional_chars: usize) bool {
    while (ctx.size < ctx.idx + additional_chars) {
        const new_size = if (ctx.size == 0) 512 else ctx.size * 2;
        const new_buf = std.c.realloc(ctx.buf, new_size * @sizeOf(u32)) orelse
            return false;

        ctx.buf = @ptrCast(@alignCast(new_buf));
        ctx.size = new_size;
    }

    std.debug.assert(ctx.size >= ctx.idx + additional_chars);
    return true;
}

fn push(ctx: *Context, char: u32) void {
    ctx.buf.?[ctx.idx] = char;
    ctx.idx += 1;
}

fn pushSpaces(ctx: *Context, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1)
        push(ctx, ' ');
}

fn pushNewlines(ctx: *Context, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1)
        push(ctx, '\n');
}

export fn extract_begin(kind: types.SelectionKind, strip_trailing_empty: bool) ?*Context {
    const ctx_raw = std.c.malloc(@sizeOf(Context)) orelse return null;
    const ctx: *Context = @ptrCast(@alignCast(ctx_raw));
    ctx.* = .{
        .selection_kind = kind,
        .strip_trailing_empty = strip_trailing_empty,
    };
    return ctx;
}

/// Finishes the extraction into a wide (UCS-4) string. On success the
/// context is freed and the buffer ownership moves to `text`.
export fn extract_finish_wide(
    ctx: *Context,
    text: ?*?[*]u32,
    len: ?*usize,
) bool {
    const out = text orelse return false;

    out.* = null;
    if (len) |l| l.* = 0;

    if (!ctx.failed) {
        if (!ctx.strip_trailing_empty) {
            // Insert pending newlines, and replace empty cells with spaces
            if (!ensureSize(ctx, ctx.newline_count + ctx.empty_count))
                ctx.failed = true;
            if (!ctx.failed) {
                pushNewlines(ctx, ctx.newline_count);
                pushSpaces(ctx, ctx.empty_count);
            }
        }
    }

    if (!ctx.failed) {
        if (ctx.idx == 0) {
            // Selection of empty cells only
            if (!ensureSize(ctx, 1)) {
                ctx.failed = true;
            } else {
                push(ctx, 0);
            }
        } else {
            std.debug.assert(ctx.idx <= ctx.size);

            switch (ctx.selection_kind) {
                .line_wise => {
                    if (ctx.buf.?[ctx.idx - 1] != '\n') {
                        if (!ensureSize(ctx, 1)) {
                            ctx.failed = true;
                        } else {
                            push(ctx, '\n');
                        }
                    }
                },
                else => {
                    if (ctx.buf.?[ctx.idx - 1] == '\n')
                        ctx.buf.?[ctx.idx - 1] = 0;
                },
            }

            if (!ctx.failed and ctx.buf.?[ctx.idx - 1] != 0) {
                if (!ensureSize(ctx, 1)) {
                    ctx.failed = true;
                } else {
                    push(ctx, 0);
                }
            }
        }
    }

    if (ctx.failed) {
        if (ctx.buf) |buf| std.c.free(buf);
        std.c.free(ctx);
        return false;
    }

    out.* = ctx.buf;
    if (len) |l| l.* = ctx.idx - 1;
    std.c.free(ctx);
    return true;
}

export fn extract_finish(ctx: *Context, text: *?[*:0]u8, len: *usize) bool {
    len.* = 0;

    var wtext: ?[*]u32 = null;
    if (!extract_finish_wide(ctx, &wtext, null))
        return false;

    const wide = wtext orelse return false;
    const bytes = ac32tombs(wide) orelse {
        std.c.free(wide);
        return false;
    };

    text.* = bytes;
    len.* = std.mem.len(bytes);
    std.c.free(wide);
    return true;
}

export fn extract_one(
    term: *const types.Terminal,
    row: *const types.Row,
    cell: *const types.Cell,
    col: c_int,
    context: ?*anyopaque,
) bool {
    const ctx: *Context = @ptrCast(@alignCast(context orelse return false));

    if (cell.wc >= CELL_SPACER)
        return true;

    if (ctx.last_row != null and row != ctx.last_row.?) {
        // New row - determine if we should insert a newline or not
        if (ctx.selection_kind != .block) {
            if (ctx.last_row.?.linebreak or
                ctx.empty_count > 0 or
                cell.wc == 0)
            {
                // Row has a hard linebreak, or either last cell or current
                // cell is empty. Don't emit the newline just yet - only if
                // there are non-empty cells following it.
                ctx.newline_count += 1;

                if (!ctx.strip_trailing_empty) {
                    if (!ensureSize(ctx, ctx.empty_count))
                        return fail(ctx);
                    pushSpaces(ctx, ctx.empty_count);
                }
                ctx.empty_count = 0;
            }
        } else {
            // Always insert a linebreak
            if (!ensureSize(ctx, 1))
                return fail(ctx);

            push(ctx, '\n');

            if (!ctx.strip_trailing_empty) {
                if (!ensureSize(ctx, ctx.empty_count))
                    return fail(ctx);
                pushSpaces(ctx, ctx.empty_count);
            }
            ctx.empty_count = 0;
        }

        ctx.tab_spaces_left = 0;
    }

    if (cell.wc == ' ' and ctx.tab_spaces_left > 0) {
        ctx.tab_spaces_left -= 1;
        return true;
    }

    ctx.tab_spaces_left = 0;

    if (cell.wc == 0) {
        ctx.empty_count += 1;
        ctx.last_row = row;
        ctx.last_cell = cell;
        return true;
    }

    // Insert pending newlines, and replace empty cells with spaces
    if (!ensureSize(ctx, ctx.newline_count + ctx.empty_count))
        return fail(ctx);

    pushNewlines(ctx, ctx.newline_count);
    pushSpaces(ctx, ctx.empty_count);

    ctx.newline_count = 0;
    ctx.empty_count = 0;

    if (cell.wc >= CELL_COMB_CHARS_LO and cell.wc <= CELL_COMB_CHARS_HI) {
        const composed = composed_lookup(term.composed, cell.wc - CELL_COMB_CHARS_LO) orelse
            return fail(ctx);

        if (!ensureSize(ctx, composed.count))
            return fail(ctx);

        const chars = composed.chars.?;
        var i: usize = 0;
        while (i < composed.count) : (i += 1)
            push(ctx, chars[i]);
    } else {
        if (!ensureSize(ctx, 1))
            return fail(ctx);
        push(ctx, cell.wc);

        if (cell.wc == '\t') {
            const found = vt_tab_stops_next_after(@constCast(term), col);
            const next_tab_stop: c_int = if (found >= 0) found else term.cols - 1;

            if (next_tab_stop > col)
                ctx.tab_spaces_left = @intCast(next_tab_stop - col - 1);
        }
    }

    ctx.last_row = row;
    ctx.last_cell = cell;
    return true;
}

fn fail(ctx: *Context) bool {
    ctx.failed = true;
    return false;
}
