const std = @import("std");
const types = @import("terminal_types.zig");

extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: ERROR: " ++ fmt ++ "\n", args);
}
fn logErrno(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: " ++ fmt ++ " (errno)\n", args);
}
fn logDbg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: " ++ fmt ++ "\n", args);
}

export fn osc_ensure_size(term: *types.Terminal, required_size: usize) callconv(.c) bool {
    if (required_size <= term.vt.osc.size)
        return true;

    const pow2_max: usize = ~(@as(usize, std.math.maxInt(usize)) >> 1);
    if (required_size > pow2_max) {
        logErr("required OSC buffer size ({d}) exceeds limit ({d})", .{ required_size, pow2_max });
        return false;
    }

    var new_size: usize = @max(term.vt.osc.size, 4096);
    while (new_size < required_size) {
        new_size <<= 1;
    }

    const new_data: ?[*]u8 = @ptrCast(realloc(
        if (term.vt.osc.data) |d| @ptrCast(d) else null,
        new_size,
    ));
    if (new_data == null) {
        logErrno("failed to increase size of OSC buffer", .{});
        return false;
    }

    logDbg("resized OSC buffer: {d}", .{new_size});
    term.vt.osc.data = new_data;
    term.vt.osc.size = new_size;
    return true;
}

// ─── Chunk B: osc_flash / osc_set_pwd / osc_uri ────────────────────

extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn strlen(s: [*:0]const u8) callconv(.c) usize;
extern fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]u8;
extern fn strtok_r(s: ?[*:0]u8, delim: [*:0]const u8, saveptr: *?[*:0]u8) callconv(.c) ?[*:0]u8;
extern fn rand() callconv(.c) c_int;

extern fn term_flash(term: *types.Terminal, duration_ms: c_int) callconv(.c) void;
extern fn term_osc8_open(term: *types.Terminal, id: u64, uri: [*:0]const u8) callconv(.c) void;
extern fn term_osc8_close(term: *types.Terminal) callconv(.c) void;
extern fn hostname_is_localhost(hostname: [*:0]const u8) callconv(.c) bool;
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

extern fn osc_term_cwd_ptr(term: *types.Terminal) callconv(.c) *?[*:0]u8;

fn sdbmHash(s: [*:0]const u8) u64 {
    var hash: u64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const c: u8 = @bitCast(s[i]);
        hash = @as(u64, c) +% (hash << 6) +% (hash << 16) -% hash;
    }
    return hash;
}

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

fn cStr(s: [*c]const u8) [*:0]const u8 {
    return @ptrCast(s);
}

fn cStrMut(s: [*c]u8) [*:0]u8 {
    return @ptrCast(s);
}

export fn osc_flash(term: *types.Terminal) callconv(.c) void {
    term_flash(term, 50);
}

export fn osc_set_pwd(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    var scheme: [*c]u8 = null;
    var host: [*c]u8 = null;
    var path: [*c]u8 = null;

    const len = strlen(string);
    if (!uri_parse(
        string,
        len,
        &scheme,
        null, null,
        &host,
        null,
        &path,
        null, null,
    )) {
        std.debug.print("osc: ERROR: OSC7: invalid URI: {s}\n", .{std.mem.span(string)});
        return;
    }

    if (scheme != null and host != null and path != null) {
        if (streq(cStr(scheme), "file") and hostname_is_localhost(cStr(host))) {
            const cwd_ptr = osc_term_cwd_ptr(term);
            if (cwd_ptr.*) |old| free(@ptrCast(old));
            cwd_ptr.* = @ptrCast(path);
        } else {
            free(@ptrCast(path));
        }
    }
    if (scheme != null) free(@ptrCast(scheme));
    if (host != null) free(@ptrCast(host));
}

export fn osc_uri(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    const params_end = strchr(string, ';');
    if (params_end == null) return;

    params_end.?[0] = 0;
    const uri: [*:0]const u8 = @ptrCast(params_end.? + 1);

    // C: (uint64_t)rand() << 32 | rand()
    const r1 = rand();
    const r2 = rand();
    var id: u64 = (@as(u64, @bitCast(@as(i64, r1))) << 32) | @as(u64, @as(u32, @bitCast(r2)));

    var ctx: ?[*:0]u8 = null;
    var key_value: ?[*:0]u8 = strtok_r(string, ":", &ctx);
    while (key_value) |kv| : (key_value = strtok_r(null, ":", &ctx)) {
        const op = strchr(kv, '=');
        if (op == null) continue;
        op.?[0] = 0;
        const value: [*:0]const u8 = @ptrCast(op.? + 1);
        if (streq(kv, "id")) id = sdbmHash(value);
    }

    if (uri[0] == 0) {
        term_osc8_close(term);
    } else {
        term_osc8_open(term, id, uri);
    }
}

// ─── Chunk C: parse_legacy_color / parse_rgb ──────────────────────

extern fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int;
extern fn strtoul(s: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) callconv(.c) c_ulong;

fn isxdigit(c: u8) bool {
    return (c >= '0' and c <= '9') or
           (c >= 'a' and c <= 'f') or
           (c >= 'A' and c <= 'F');
}

fn hexNibble(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

export fn parse_legacy_color(
    string_in: [*:0]const u8,
    color: *u32,
    have_alpha_out: ?*bool,
    alpha_out: ?*u16,
) callconv(.c) bool {
    var have_alpha: bool = false;
    var alpha: u16 = 0xffff;
    var string: [*:0]const u8 = string_in;

    if (string[0] == '[') {
        // e.g. \E]11;[50]#00ff00
        const start: [*:0]const u8 = @ptrCast(string + 1);

        var end: [*:0]u8 = undefined;
        const percent = strtoul(start, &end, 10);
        if (end[0] != ']') return false;

        have_alpha = true;
        const pct_capped: c_ulong = @min(percent, 100);
        alpha = @intCast((@as(c_ulong, 0xffff) * pct_capped + 50) / 100);

        string = @ptrCast(end + 1);
    }

    if (string[0] != '#') return false;

    string = @ptrCast(string + 1);
    const len = strlen(string);
    if (len % 3 != 0) return false;

    const digits: usize = len / 3;
    var rgb: [3]i32 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        rgb[i] = 0;
        var j: usize = 0;
        while (j < digits) : (j += 1) {
            const idx = i * digits + j;
            const c: u8 = @bitCast(string[idx]);
            rgb[i] <<= 4;
            if (isxdigit(c)) rgb[i] |= hexNibble(c);
            // else rgb[i] |= 0 (no-op)
        }
        rgb[i] <<= @intCast(16 - 4 * digits);
    }

    const r: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[0])) / 65536.0));
    const g: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[1])) / 65536.0));
    const b: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[2])) / 65536.0));

    color.* = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);

    if (have_alpha_out) |h| h.* = have_alpha;
    if (alpha_out) |a| a.* = alpha;
    return true;
}

export fn parse_rgb(
    string_in: [*:0]const u8,
    color: *u32,
    have_alpha_out: ?*bool,
    alpha_out: ?*u16,
) callconv(.c) bool {
    var string: [*:0]const u8 = string_in;
    var len = strlen(string);
    const have_alpha: bool = (len >= 4 and strncmp(string, "rgba", 4) == 0);

    if (have_alpha) {
        if (len < "rgba:x/x/x/x".len) return false;
        if (strncmp(string, "rgba:", 5) != 0) return false;
        string = @ptrCast(string + 5);
        len -= 5;
    } else {
        if (len < "rgb:x/x/x".len) return false;
        if (strncmp(string, "rgb:", 4) != 0) return false;
        string = @ptrCast(string + 4);
        len -= 4;
    }

    var rgb: [4]i32 = .{ 0, 0, 0, 0 };
    var digits: [4]i32 = .{ 0, 0, 0, 0 };

    const n_components: usize = if (have_alpha) 4 else 3;
    var i: usize = 0;
    while (i < n_components) : (i += 1) {
        rgb[i] = 0;
        digits[i] = 0;
        while (len > 0 and string[0] != '/') : ({
            len -= 1;
            string = @ptrCast(string + 1);
            digits[i] += 1;
        }) {
            const c: u8 = @bitCast(string[0]);
            rgb[i] <<= 4;
            if (isxdigit(c)) rgb[i] |= hexNibble(c);
        }

        const last_i: usize = if (have_alpha) 3 else 2;
        if (i >= last_i) break;

        if (len == 0 or string[0] != '/') return false;
        string = @ptrCast(string + 1);
        len -= 1;
    }

    const r: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[0])) / @as(f64, @floatFromInt(@as(i32, 1) << @intCast(4 * @as(u5, @intCast(digits[0])))))));
    const g: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[1])) / @as(f64, @floatFromInt(@as(i32, 1) << @intCast(4 * @as(u5, @intCast(digits[1])))))));
    const b: u8 = @intFromFloat(256.0 * (@as(f64, @floatFromInt(rgb[2])) / @as(f64, @floatFromInt(@as(i32, 1) << @intCast(4 * @as(u5, @intCast(digits[2])))))));

    var alpha: u16 = 0xffff;
    if (have_alpha) {
        alpha = @intFromFloat(65536.0 * (@as(f64, @floatFromInt(rgb[3])) / @as(f64, @floatFromInt(@as(i32, 1) << @intCast(4 * @as(u5, @intCast(digits[3])))))));
    }

    if (have_alpha_out) |h| h.* = have_alpha;
    if (alpha_out) |a| a.* = alpha;

    color.* = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    return true;
}

// ─── Chunk D: osc_to_clipboard / osc_from_clipboard / osc_selection ─

extern fn base64_decode(s: [*c]const u8, size: ?*usize) callconv(.c) [*c]u8;
extern fn base64_encode(data: [*c]const u8, size: usize) callconv(.c) [*c]u8;
extern fn base64_encode_final(data: [*c]const u8, size: usize, result: [*c]u8) callconv(.c) void;

extern fn selection_clipboard_unset(seat: *anyopaque) callconv(.c) void;
extern fn selection_primary_unset(seat: *anyopaque) callconv(.c) void;
extern fn selection_clipboard_has_data(seat: *const anyopaque) callconv(.c) bool;
extern fn selection_primary_has_data(seat: *const anyopaque) callconv(.c) bool;

extern fn text_to_clipboard(seat: *anyopaque, term: *types.Terminal, text: [*:0]u8, serial: u32) callconv(.c) bool;
extern fn text_to_primary(seat: *anyopaque, term: *types.Terminal, text: [*:0]u8, serial: u32) callconv(.c) bool;

extern fn text_from_clipboard(
    seat: *anyopaque,
    term: *types.Terminal,
    confirm: bool,
    cb: ?*const fn ([*]u8, usize, ?*anyopaque) callconv(.c) void,
    done_cb: ?*const fn (?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
) callconv(.c) void;
extern fn text_from_primary(
    seat: *anyopaque,
    term: *types.Terminal,
    confirm: bool,
    cb: ?*const fn ([*]u8, usize, ?*anyopaque) callconv(.c) void,
    done_cb: ?*const fn (?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
) callconv(.c) void;

extern fn term_paste_data_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;
extern fn term_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;

extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;

extern fn osc_seat_with_focus(term: *types.Terminal) callconv(.c) ?*anyopaque;
extern fn osc_osc52_copy_allowed(term: *types.Terminal) callconv(.c) bool;
extern fn osc_osc52_paste_allowed(term: *types.Terminal) callconv(.c) bool;
extern fn osc_ptmx_buffers_len(term: *types.Terminal) callconv(.c) usize;
extern fn osc_fdm_epollout_ptmx(term: *types.Terminal) callconv(.c) void;

// ── Helpers ───────────────────────────────────────────────────────
extern fn osc_seat_serial(seat: *anyopaque) callconv(.c) u32;
fn termSeatSerial(seat: *anyopaque) u32 { return osc_seat_serial(seat); }

// ── osc_to_clipboard ──────────────────────────────────────────────
export fn osc_to_clipboard(
    term: *types.Terminal,
    target: [*:0]const u8,
    base64_data: [*:0]const u8,
) callconv(.c) void {
    var to_clipboard = false;
    var to_primary = false;

    if (target[0] == 0) to_clipboard = true;

    var t: usize = 0;
    while (target[t] != 0) : (t += 1) {
        switch (target[t]) {
            'c' => to_clipboard = true,
            's', 'p' => to_primary = true,
            else => std.debug.print("osc: WARN: unimplemented clipboard target '{c}'\n", .{target[t]}),
        }
    }

    const seat = osc_seat_with_focus(term);
    if (seat == null) {
        std.debug.print("osc: WARN: OSC52: client tried to write to clipboard while window unfocused\n", .{});
        return;
    }

    if (!osc_osc52_copy_allowed(term)) {
        std.debug.print("osc: ignoring copy request: disabled in configuration\n", .{});
        return;
    }

    const decoded: [*c]u8 = base64_decode(base64_data, null);
    if (decoded == null or decoded[0] == 0) {
        if (decoded == null) {
            std.debug.print("osc: WARN: invalid clipboard data\n", .{});
        }
        if (to_clipboard) selection_clipboard_unset(seat.?);
        if (to_primary) selection_primary_unset(seat.?);
        if (decoded != null) free(@ptrCast(decoded));
        return;
    }

    if (to_clipboard) {
        const copy = xstrdup(@ptrCast(decoded));
        if (copy != null) {
            const serial = termSeatSerial(seat.?);
            if (!text_to_clipboard(seat.?, term, copy.?, serial)) free(@ptrCast(copy));
        }
    }
    if (to_primary) {
        const copy = xstrdup(@ptrCast(decoded));
        if (copy != null) {
            const serial = termSeatSerial(seat.?);
            if (!text_to_primary(seat.?, term, copy.?, serial)) free(@ptrCast(copy));
        }
    }
    free(@ptrCast(decoded));
}

// ── clip_context ──────────────────────────────────────────────────
const ClipContext = extern struct {
    seat: *anyopaque,
    term: *types.Terminal,
    buf: [3]u8,
    idx: c_int,
};

fn fromClipboardCb(text: [*]u8, size: usize, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ClipContext = @ptrCast(@alignCast(user.?));
    const term = ctx.term;

    var tp: [*]u8 = text;
    var left: usize = size;

    if (ctx.idx > 0) {
        var i: c_int = ctx.idx;
        while (i < 3 and left > 0) : ({
            i += 1;
            tp += 1;
            left -= 1;
        }) {
            ctx.buf[@intCast(ctx.idx)] = tp[0];
            ctx.idx += 1;
        }

        if (ctx.idx == 3) {
            const chunk = base64_encode(&ctx.buf, 3);
            term_paste_data_to_slave(term, chunk, 4);
            free(@ptrCast(chunk));
            ctx.idx = 0;
        }
    }

    if (left == 0) return;

    const remaining: usize = left % 3;
    var i: usize = remaining;
    while (i > 0) : (i -= 1) {
        ctx.buf[@intCast(ctx.idx)] = text[size - i];
        ctx.idx += 1;
    }

    const chunk = base64_encode(tp, (left / 3) * 3);
    term_paste_data_to_slave(term, chunk, strlen(@ptrCast(chunk)));
    free(@ptrCast(chunk));
}

fn fromClipboardDone(user: ?*anyopaque) callconv(.c) void {
    const ctx: *ClipContext = @ptrCast(@alignCast(user.?));
    const term = ctx.term;

    if (ctx.idx > 0) {
        var res: [4]u8 = undefined;
        base64_encode_final(&ctx.buf, @intCast(ctx.idx), &res);
        term_paste_data_to_slave(term, @as([*]const u8, @ptrCast(&res)), 4);
    }

    if (term.vt.osc.bel) {
        term_paste_data_to_slave(term, "\x07", 1);
    } else {
        term_paste_data_to_slave(term, "\x1b\\", 2);
    }

    term.is_sending_paste_data = false;

    if (osc_ptmx_buffers_len(term) > 0) {
        osc_fdm_epollout_ptmx(term);
    }

    free(user);
}

// ── osc_from_clipboard ────────────────────────────────────────────
export fn osc_from_clipboard(term: *types.Terminal, source: [*:0]const u8) callconv(.c) void {
    const seat = osc_seat_with_focus(term);
    if (seat == null) {
        std.debug.print("osc: WARN: OSC52: client tried to read clipboard while window unfocused\n", .{});
        return;
    }

    if (!osc_osc52_paste_allowed(term)) {
        std.debug.print("osc: ignoring paste request: disabled in configuration\n", .{});
        return;
    }

    var src: u8 = if (source[0] == 0) 'c' else 0;
    var from_clipboard = src == 'c';
    var from_primary = false;

    var i: usize = 0;
    while (source[i] != 0 and !from_clipboard and !from_primary) : (i += 1) {
        const c = source[i];
        if (c == 'c' or c == 'p' or c == 's') {
            src = c;
            switch (c) {
                'c' => from_clipboard = selection_clipboard_has_data(seat.?),
                's', 'p' => from_primary = selection_primary_has_data(seat.?),
                else => unreachable,
            }
        } else {
            std.debug.print("osc: WARN: unimplemented clipboard source '{c}'\n", .{c});
        }
    }

    if (!from_clipboard and !from_primary) return;

    if (term.is_sending_paste_data) {
        term_to_slave(term, "\x1b]52;", 5);
        term_to_slave(term, @as([*]const u8, @ptrCast(&src)), 1);
        term_to_slave(term, ";", 1);
        if (term.vt.osc.bel) {
            term_to_slave(term, "\x07", 1);
        } else {
            term_to_slave(term, "\x1b\\", 2);
        }
        return;
    }

    term.is_sending_paste_data = true;

    term_paste_data_to_slave(term, "\x1b]52;", 5);
    term_paste_data_to_slave(term, @as([*]const u8, @ptrCast(&src)), 1);
    term_paste_data_to_slave(term, ";", 1);

    const ctx_ptr = xmalloc(@sizeOf(ClipContext)) orelse return;
    const ctx: *ClipContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.* = .{ .seat = seat.?, .term = term, .buf = undefined, .idx = 0 };

    if (from_clipboard) {
        text_from_clipboard(seat.?, term, true, &fromClipboardCb, &fromClipboardDone, ctx);
    }
    if (from_primary) {
        text_from_primary(seat.?, term, true, &fromClipboardCb, &fromClipboardDone, ctx);
    }
}

// ── osc_selection ─────────────────────────────────────────────────
export fn osc_selection(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    var p: [*:0]u8 = string;
    var clipboard_done = false;

    while (p[0] != 0 and !clipboard_done) {
        switch (p[0]) {
            ';' => {
                clipboard_done = true;
                p[0] = 0;
            },
            else => {},
        }
        p += 1;
    }

    // osc_selection ends here in osc.c — the last lines of the function
    // dispatch to osc_to_clipboard / osc_from_clipboard based on whether
    // the data part is empty. Original C continues; see continuation.
    const data: [*:0]const u8 = p;
    if (data[0] == 0) {
        osc_from_clipboard(term, string);
    } else {
        osc_to_clipboard(term, string, data);
    }
}

// ─── Chunk F: osc_dispatch ─────────────────────────────────────────

extern fn isdigit(c: c_int) callconv(.c) c_int;
extern fn strtok(s: ?[*:0]u8, delim: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn __errno_location() callconv(.c) *c_int;

extern fn xsnprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) callconv(.c) usize;
extern fn term_set_window_title(term: *types.Terminal, title: [*:0]const u8) callconv(.c) void;
extern fn term_set_app_id(term: *types.Terminal, app_id: [*:0]const u8) callconv(.c) void;
extern fn term_set_user_mouse_cursor(term: *types.Terminal, cursor: [*:0]const u8) callconv(.c) void;
extern fn term_damage_color(term: *types.Terminal, src: types.ColorSource, idx: u32) callconv(.c) void;
extern fn term_damage_cursor(term: *types.Terminal) callconv(.c) void;
extern fn term_damage_margins(term: *types.Terminal) callconv(.c) void;
extern fn term_damage_view(term: *types.Terminal) callconv(.c) void;
extern fn term_font_subpixel_changed(term: *types.Terminal) callconv(.c) void;

extern fn wayl_win_alpha_changed(win: ?*anyopaque) callconv(.c) void;

extern fn osc_notify(term: *types.Terminal, string: [*:0]u8) callconv(.c) void;
extern fn kitty_notification(term: *types.Terminal, string: [*:0]u8) callconv(.c) void;
extern fn kitty_text_size(term: *types.Terminal, string: [*:0]u8) callconv(.c) void;

extern fn osc_theme_fg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_bg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_alpha(term: *types.Terminal) callconv(.c) u16;
extern fn osc_theme_cursor_text(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_cursor_cursor(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_selection_bg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_selection_fg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_table_copy(term: *types.Terminal, out: *[256]u32) callconv(.c) void;
extern fn osc_conf_colors_dark_use_custom_cursor(term: *types.Terminal) callconv(.c) bool;

fn unhandled(term: *types.Terminal) void {
    std.debug.print("osc: unhandled: OSC: {s}\n", .{term.vt.osc.data.?[0..term.vt.osc.idx]});
}

// Parse a leading integer from a C string (advancing through decimal digits).
fn parseIdx(s_in: [*:0]const u8) struct { idx: u32, rest: [*:0]const u8 } {
    var idx: u32 = 0;
    var p: usize = 0;
    while (s_in[p] != 0) : (p += 1) {
        const c = s_in[p];
        if (c < '0' or c > '9') break;
        idx = idx * 10 + @as(u32, c - '0');
    }
    return .{ .idx = idx, .rest = @ptrCast(s_in + p) };
}

export fn osc_dispatch(term: *types.Terminal) callconv(.c) void {
    var param: c_uint = 0;
    var data_ofs: usize = 0;
    const data = term.vt.osc.data.?;

    var i: usize = 0;
    while (i < term.vt.osc.idx) : ({
        i += 1;
        data_ofs += 1;
    }) {
        const c = data[i];
        if (c == ';') {
            data_ofs += 1;
            break;
        }
        if (isdigit(@intCast(c)) == 0) {
            unhandled(term);
            return;
        }
        param = param *% 10 +% @as(c_uint, c - '0');
    }

    const string: [*:0]u8 = @ptrCast(data + data_ofs);

    switch (param) {
        0, 2 => term_set_window_title(term, string),
        1 => {},
        4 => {
            // Set color<idx>
            const prev = string - 1;
            if (prev[0] != ';') return;

            var s_idx_opt: ?[*:0]u8 = strtok(string, ";");
            var s_color_opt: ?[*:0]u8 = strtok(null, ";");
            while (s_idx_opt != null and s_color_opt != null) : ({
                s_idx_opt = strtok(null, ";");
                s_color_opt = strtok(null, ";");
            }) {
                const s_idx = s_idx_opt.?;
                const s_color = s_color_opt.?;

                const parsed = parseIdx(s_idx);
                const idx = parsed.idx;
                if (idx >= 256) {
                    std.debug.print("osc: WARN: invalid OSC 4 color index: {d}\n", .{idx});
                    break;
                }

                if (s_color[0] == '?' and s_color[1] == 0) {
                    const color = term.colors.table[idx];
                    const r: u8 = @intCast((color >> 16) & 0xff);
                    const g: u8 = @intCast((color >> 8) & 0xff);
                    const b: u8 = @intCast(color & 0xff);
                    const terminator = if (term.vt.osc.bel) "\x07" else "\x1b\\";

                    var reply: [32]u8 = undefined;
                    const n = xsnprintf(&reply, reply.len, "\x1b]4;%u;rgb:%02x%02x/%02x%02x/%02x%02x%s", idx, r, r, g, g, b, b, terminator.ptr);
                    term_to_slave(term, &reply, n);
                } else {
                    var color: u32 = 0;
                    const color_is_valid = if (s_color[0] == '#' or s_color[0] == '[')
                        parse_legacy_color(s_color, &color, null, null)
                    else
                        parse_rgb(s_color, &color, null, null);

                    if (!color_is_valid) continue;

                    term.colors.table[idx] = color;
                    term_damage_color(term, .base256, idx);
                }
            }
        },
        7 => osc_set_pwd(term, string),
        8 => osc_uri(term, string),
        9 => {
            const sep = strchr(string, ';');
            if (sep != null) {
                const e = __errno_location();
                e.* = 0;
                var end: [*:0]u8 = undefined;
                _ = strtoul(string, &end, 10);
                if (end == sep.? and e.* == 0) {
                    return;
                }
            }
            osc_notify(term, string);
        },
        10, 11, 12, 17, 19 => {
            if (string[0] == '?' and string[1] == 0) {
                const color: u32 = switch (param) {
                    10 => term.colors.fg,
                    11 => term.colors.bg,
                    12 => term.colors.cursor_bg,
                    17 => term.colors.selection_bg,
                    else => term.colors.selection_fg,
                };
                const r: u8 = @intCast((color >> 16) & 0xff);
                const g: u8 = @intCast((color >> 8) & 0xff);
                const b: u8 = @intCast(color & 0xff);
                const terminator = if (term.vt.osc.bel) "\x07" else "\x1b\\";

                var reply: [32]u8 = undefined;
                const n = xsnprintf(&reply, reply.len, "\x1b]%u;rgb:%02x%02x/%02x%02x/%02x%02x%s", param, r, r, g, g, b, b, terminator.ptr);
                term_to_slave(term, &reply, n);
                return;
            }

            var color: u32 = 0;
            var have_alpha: bool = false;
            var alpha: u16 = 0xffff;

            const parsed_ok = if (string[0] == '#' or string[0] == '[')
                parse_legacy_color(string, &color, &have_alpha, &alpha)
            else
                parse_rgb(string, &color, &have_alpha, &alpha);
            if (!parsed_ok) return;

            switch (param) {
                10 => {
                    term.colors.fg = color;
                    term_damage_color(term, .default, 0);
                },
                11 => {
                    term.colors.bg = color;
                    if (!have_alpha) alpha = osc_theme_alpha(term);
                    const changed = term.colors.alpha != alpha;
                    term.colors.alpha = alpha;
                    if (changed) {
                        wayl_win_alpha_changed(term.window);
                        term_font_subpixel_changed(term);
                    }
                    term_damage_color(term, .default, 0);
                    term_damage_margins(term);
                },
                12 => {
                    term.colors.cursor_bg = (1 << 31) | color;
                    term_damage_cursor(term);
                },
                17 => term.colors.selection_bg = color,
                19 => term.colors.selection_fg = color,
                else => unreachable,
            }
        },
        22 => term_set_user_mouse_cursor(term, string),
        30 => {},
        52 => osc_selection(term, string),
        66 => kitty_text_size(term, string),
        99 => kitty_notification(term, string),
        104 => {
            if (string[0] == 0) {
                osc_theme_table_copy(term, &term.colors.table);
                term_damage_view(term);
            } else {
                var s_idx_opt: ?[*:0]u8 = strtok(string, ";");
                while (s_idx_opt) |s_idx| : (s_idx_opt = strtok(null, ";")) {
                    const parsed = parseIdx(s_idx);
                    const idx = parsed.idx;
                    if (idx >= 256) {
                        std.debug.print("osc: WARN: invalid OSC 104 color index: {d}\n", .{idx});
                        continue;
                    }
                    var tbl: [256]u32 = undefined;
                    osc_theme_table_copy(term, &tbl);
                    term.colors.table[idx] = tbl[idx];
                    term_damage_color(term, .base256, idx);
                }
            }
        },
        105 => {},
        110 => {
            term.colors.fg = osc_theme_fg(term);
            term_damage_color(term, .default, 0);
        },
        111 => {
            const alpha_changed = term.colors.alpha != osc_theme_alpha(term);
            term.colors.bg = osc_theme_bg(term);
            term.colors.alpha = osc_theme_alpha(term);
            if (alpha_changed) {
                wayl_win_alpha_changed(term.window);
                term_font_subpixel_changed(term);
            }
            term_damage_color(term, .default, 0);
            term_damage_margins(term);
        },
        112 => {
            term.colors.cursor_fg = osc_theme_cursor_text(term);
            term.colors.cursor_bg = osc_theme_cursor_cursor(term);
            if (osc_conf_colors_dark_use_custom_cursor(term)) {
                term.colors.cursor_fg |= 1 << 31;
                term.colors.cursor_bg |= 1 << 31;
            }
            term_damage_cursor(term);
        },
        117 => term.colors.selection_bg = osc_theme_selection_bg(term),
        119 => term.colors.selection_fg = osc_theme_selection_fg(term),
        133 => {
            const grid = term.grid orelse return;
            const cur_row = grid.cur_row orelse return;
            switch (string[0]) {
                'A' => cur_row.shell_integration.prompt_marker = true,
                'B' => {},
                'C' => cur_row.shell_integration.cmd_start = grid.cursor.point.col,
                'D' => cur_row.shell_integration.cmd_end = grid.cursor.point.col,
                else => {},
            }
        },
        176 => {
            if (string[0] == '?' and string[1] == 0) {
                std.debug.print("osc: WARN: OSC-176 app-id query ignored\n", .{});
                return;
            }
            term_set_app_id(term, string);
        },
        555 => osc_flash(term),
        777 => {
            const param_brk = strchr(string, ';');
            if (param_brk == null) {
                unhandled(term);
                return;
            }
            const prefix_len = @intFromPtr(param_brk.?) - @intFromPtr(string);
            if (std.mem.eql(u8, string[0..prefix_len], "notify")) {
                osc_notify(term, @ptrCast(param_brk.? + 1));
            } else {
                unhandled(term);
            }
        },
        else => unhandled(term),
    }
}

