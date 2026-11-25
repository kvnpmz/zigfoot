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
            const cwd_ptr = &term.cwd;
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
extern fn osc_ptmx_buffers_len(term: *types.Terminal) callconv(.c) usize;
extern fn osc_fdm_epollout_ptmx(term: *types.Terminal) callconv(.c) void;

// ── Helpers ───────────────────────────────────────────────────────
fn osc52CopyAllowed(term: *types.Terminal) bool {
    const p = term.conf.?.security.osc52;
    return p == .enabled or p == .copy_enabled;
}

fn osc52PasteAllowed(term: *types.Terminal) bool {
    const p = term.conf.?.security.osc52;
    return p == .enabled or p == .paste_enabled;
}

fn termSeatSerial(seat: *anyopaque) u32 {
    const s: *const types.Seat = @ptrCast(@alignCast(seat));
    return s.kbd.serial;
}

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

    if (!osc52CopyAllowed(term)) {
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

    if (!osc52PasteAllowed(term)) {
        std.debug.print("osc: ignoring paste request: disabled in configuration\n", .{});
        return;
    }

    // Use the clipboard if no source was given. Walk the source list and
    // use the last source that has data; if none does, reply with an empty
    // payload for that source instead of dropping the request (upstream
    // "osc-52: send response even if no source has data").
    var src: u8 = 'c';
    {
        var i: usize = 0;
        while (source[i] != 0) : (i += 1) {
            src = source[i];
            if (src == 'c') {
                if (selection_clipboard_has_data(seat.?)) break;
            } else if (src == 'p' or src == 's') {
                if (selection_primary_has_data(seat.?)) break;
            } else {
                std.debug.print("osc: WARN: unimplemented clipboard source '{c}'\n", .{src});
            }
        }
    }

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

    if (src == 'c') {
        text_from_clipboard(seat.?, term, true, &fromClipboardCb, &fromClipboardDone, ctx);
    } else if (src == 'p' or src == 's') {
        text_from_primary(seat.?, term, true, &fromClipboardCb, &fromClipboardDone, ctx);
    } else {
        // Unsupported source: reply with an empty payload.
        fromClipboardDone(ctx);
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



extern fn osc_theme_fg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_bg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_alpha(term: *types.Terminal) callconv(.c) u16;
extern fn osc_theme_cursor_text(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_cursor_cursor(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_selection_bg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_selection_fg(term: *types.Terminal) callconv(.c) u32;
extern fn osc_theme_table_copy(term: *types.Terminal, out: *[256]u32) callconv(.c) void;

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
            osc_notify_impl(term, string);
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
        66 => kitty_text_size_impl(term, string),
        99 => kitty_notification_impl(term, string),
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
            if (term.conf.?.colors_dark.use_custom.cursor) {
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
                osc_notify_impl(term, @ptrCast(param_brk.? + 1));
            } else {
                unhandled(term);
            }
        },
        else => unhandled(term),
    }
}


// ── chunk E-1: osc_notify ─────────────────────────────────────────
extern fn osc_notify_utf8_valid(s: [*]const u8, len: usize) callconv(.c) bool;

export fn osc_notify_impl(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    var ctx: ?[*:0]u8 = null;
    const title = strtok_r(string, ";", &ctx);
    if (title == null) return;
    const t = title.?;
    const msg = strtok_r(null, "\x00", &ctx);

    if (!osc_notify_utf8_valid(t, strlen(t))) return;
    if (msg) |m| {
        if (!osc_notify_utf8_valid(m, strlen(m))) return;
    }

    const msgdup: ?[*:0]u8 = if (msg) |m| xstrdup(m) else null;

    var notif: types.Notification = std.mem.zeroes(types.Notification);
    notif.title = xstrdup(t);
    notif.body = msgdup;
    notif.expire_time = -1;
    notif.focus = true;

    _ = notify_notify(term, &notif);
}
extern fn notify_notify(term: *types.Terminal, notif: *types.Notification) callconv(.c) bool;

// ── chunk E-2: kitty_notification ─────────────────────────────────
extern fn osc_xstrjoin(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn osc_xstrjoin3(a: [*:0]const u8, b: [*:0]const u8, c: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn osc_kitty_actions_push_back(notif: *types.Notification, s: [*:0]u8) callconv(.c) void;
extern fn notify_free(term: *types.Terminal, notif: *types.Notification) callconv(.c) void;
extern fn notify_close(term: *types.Terminal, id: [*:0]const u8) callconv(.c) void;
extern fn notify_icon_add(term: *types.Terminal, id: [*:0]const u8, symbolic_name: ?[*:0]const u8, data: ?[*]const u8, data_sz: usize) callconv(.c) void;
extern fn notify_icon_del(term: *types.Terminal, id: [*:0]const u8) callconv(.c) void;
extern fn xasprintf(fmt: [*:0]const u8, ...) callconv(.c) ?[*:0]u8;
extern fn strtol(s: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) callconv(.c) c_long;

const INT32_MAX_C: c_long = 2147483647;
const PAYLOAD_TITLE: c_int = 0;
const PAYLOAD_BODY: c_int = 1;
const PAYLOAD_CLOSE: c_int = 2;
const PAYLOAD_ALIVE: c_int = 3;
const PAYLOAD_ICON: c_int = 4;
const PAYLOAD_BUTTON: c_int = 5;

fn streqz(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

fn verify_kitty_id_is_valid(id: [*:0]const u8) bool {
    var i: usize = 0;
    while (id[i] != 0) : (i += 1) {
        const c = id[i];
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                   (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '+' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn translateSoundName(s: [*:0]const u8) ?[*:0]const u8 {
    const span = std.mem.span(s);
    if (std.mem.eql(u8, span, "error")) return "dialog-error";
    if (std.mem.eql(u8, span, "warn")) return "dialog-warning";
    if (std.mem.eql(u8, span, "warning")) return "dialog-warning";
    if (std.mem.eql(u8, span, "info")) return "dialog-information";
    if (std.mem.eql(u8, span, "question")) return "dialog-question";
    return null;
}

fn translateIconName(s: [*:0]const u8) ?[*:0]const u8 {
    const span = std.mem.span(s);
    if (std.mem.eql(u8, span, "error")) return "dialog-error";
    if (std.mem.eql(u8, span, "warn")) return "dialog-warning";
    if (std.mem.eql(u8, span, "warning")) return "dialog-warning";
    if (std.mem.eql(u8, span, "info")) return "dialog-information";
    if (std.mem.eql(u8, span, "question")) return "dialog-question";
    if (std.mem.eql(u8, span, "help")) return "system-help";
    if (std.mem.eql(u8, span, "file-manager")) return "system-file-manager";
    if (std.mem.eql(u8, span, "system-monitor")) return "utilities-system-monitor";
    if (std.mem.eql(u8, span, "text-editor")) return "text-editor";
    return null;
}

export fn kitty_notification_impl(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    const payload_raw_ptr = strchr(string, ';') orelse return;
    payload_raw_ptr[0] = 0;
    const payload_raw: [*:0]u8 = payload_raw_ptr + 1;

    var id: ?[*:0]u8 = null;
    var app_id: ?[*:0]u8 = null;
    var icon_cache_id: ?[*:0]u8 = null;
    var symbolic_icon: ?[*:0]u8 = null;
    var category: ?[*:0]u8 = null;
    var sound_name: ?[*:0]u8 = null;
    var payload: ?[*:0]u8 = null;

    var focus = true;
    var report_activated = false;
    var report_closed = false;
    var done = true;
    var use_b64 = false;

    var expire_time: i32 = -1;
    var payload_size: usize = 0;
    var payload_type: c_int = PAYLOAD_TITLE;

    var when: types.NotifyWhen = .always;
    var urgency: types.NotifyUrgency = .normal;

    var have_a = false;
    var have_c = false;
    var have_o = false;
    var have_u = false;
    var have_w = false;

    var ctx: ?[*:0]u8 = null;
    var param = strtok_r(string, ":", &ctx);
    while (param) |p| : (param = strtok_r(null, ":", &ctx)) {
        if (p[0] == 0 or p[1] != '=') continue;
        const value: [*:0]u8 = @ptrCast(p + 2);

        switch (p[0]) {
            'a' => {
                have_a = true;
                var a_ctx: ?[*:0]u8 = null;
                var v = strtok_r(value, ",", &a_ctx);
                while (v) |vv| : (v = strtok_r(null, ",", &a_ctx)) {
                    var s = vv;
                    const reverse = s[0] == '-';
                    if (reverse) s += 1;
                    if (streqz(s, "focus")) { focus = !reverse; }
                    else if (streqz(s, "report")) { report_activated = !reverse; }
                }
            },
            'c' => {
                if (value[0] == '1' and value[1] == 0) { report_closed = true; }
                else if (value[0] == '0' and value[1] == 0) { report_closed = false; }
                have_c = true;
            },
            'd' => {
                if (value[0] == '0' and value[1] == 0) { done = false; }
                else if (value[0] == '1' and value[1] == 0) { done = true; }
            },
            'e' => {
                if (value[0] == '0' and value[1] == 0) { use_b64 = false; }
                else if (value[0] == '1' and value[1] == 0) { use_b64 = true; }
            },
            'i' => {
                if (verify_kitty_id_is_valid(value)) {
                    if (id) |o| free(@ptrCast(o));
                    id = xstrdup(value);
                }
            },
            'p' => {
                if (streqz(value, "title")) { payload_type = PAYLOAD_TITLE; }
                else if (streqz(value, "body")) { payload_type = PAYLOAD_BODY; }
                else if (streqz(value, "close")) { payload_type = PAYLOAD_CLOSE; }
                else if (streqz(value, "alive")) { payload_type = PAYLOAD_ALIVE; }
                else if (streqz(value, "icon")) { payload_type = PAYLOAD_ICON; }
                else if (streqz(value, "buttons")) { payload_type = PAYLOAD_BUTTON; }
                else if (streqz(value, "?")) {
                    const reply_id: [*:0]const u8 = if (id) |i| i else "0";
                    const term_caps: [*:0]const u8 = if (term.vt.osc.bel) "\x07" else "\x1b\\";
                    var when_caps: [64]u8 = undefined;
                    const base = "unfocused";
                    @memcpy(when_caps[0..base.len], base);
                    var wlen: usize = base.len;
                    if (!term.conf.?.desktop_notifications.inhibit_when_focused) {
                        const extra = ",always";
                        @memcpy(when_caps[wlen..wlen + extra.len], extra);
                        wlen += extra.len;
                    }
                    when_caps[wlen] = 0;
                    var reply: [512]u8 = undefined;
                    const n = xsnprintf(&reply, reply.len,
                        "\x1b]99;i=%s:p=?;p=%s:a=%s:o=%s:u=%s:c=1:w=1:s=system,silent,error,warn,warning,info,question%s",
                        reply_id,
                        @as([*:0]const u8, "title,body,?,close,alive,icon,buttons"),
                        @as([*:0]const u8, "focus,report"),
                        @as([*:0]const u8, @ptrCast(&when_caps)),
                        @as([*:0]const u8, "0,1,2"),
                        term_caps);
                    _ = term_to_slave(term, &reply, @intCast(n));
                    if (id) |o| free(@ptrCast(o));
                    if (app_id) |o| free(@ptrCast(o));
                    if (icon_cache_id) |o| free(@ptrCast(o));
                    if (symbolic_icon) |o| free(@ptrCast(o));
                    if (payload) |o| free(@ptrCast(o));
                    if (category) |o| free(@ptrCast(o));
                    if (sound_name) |o| free(@ptrCast(o));
                    return;
                }
            },
            'o' => {
                have_o = true;
                if (streqz(value, "always")) { when = .always; }
                else if (streqz(value, "unfocused")) { when = .unfocused; }
                else if (streqz(value, "invisible")) { when = .invisible; }
            },
            'u' => {
                have_u = true;
                if (value[0] == '0' and value[1] == 0) { urgency = .low; }
                else if (value[0] == '1' and value[1] == 0) { urgency = .normal; }
                else if (value[0] == '2' and value[1] == 0) { urgency = .critical; }
            },
            'w' => {
                __errno_location().* = 0;
                var end: [*:0]u8 = undefined;
                const timeout = strtol(value, &end, 10);
                if (__errno_location().* == 0 and end[0] == 0 and timeout <= INT32_MAX_C) {
                    expire_time = @intCast(timeout);
                    have_w = true;
                }
            },
            'f' => {
                if (base64_decode(value, null)) |decoded| {
                    if (app_id) |o| free(@ptrCast(o));
                    app_id = @ptrCast(decoded);
                }
            },
            't' => {
                if (base64_decode(value, null)) |decoded| {
                    const d: [*:0]u8 = @ptrCast(decoded);
                    if (category) |old| {
                        category = osc_xstrjoin3(old, ",", d);
                        free(@ptrCast(d));
                        free(@ptrCast(old));
                    } else {
                        category = d;
                    }
                }
            },
            's' => {
                if (base64_decode(value, null)) |decoded| {
                    const d: [*:0]u8 = @ptrCast(decoded);
                    if (sound_name) |o| free(@ptrCast(o));
                    sound_name = d;
                    if (translateSoundName(d)) |tn| {
                        free(@ptrCast(d));
                        sound_name = xstrdup(tn);
                    }
                }
            },
            'g' => {
                if (icon_cache_id) |o| free(@ptrCast(o));
                icon_cache_id = xstrdup(value);
            },
            'n' => {
                if (base64_decode(value, null)) |decoded| {
                    const d: [*:0]u8 = @ptrCast(decoded);
                    const need_replace = symbolic_icon == null or strlen(d) < strlen(symbolic_icon.?);
                    if (need_replace) {
                        if (symbolic_icon) |o| free(@ptrCast(o));
                        symbolic_icon = d;
                        if (translateIconName(d)) |tn| {
                            free(@ptrCast(d));
                            symbolic_icon = xstrdup(tn);
                        }
                    } else {
                        free(@ptrCast(d));
                    }
                }
            },
            else => {},
        }
    }

    if (use_b64) {
        const raw: [*:0]const u8 = payload_raw;
        if (base64_decode(raw, &payload_size)) |decoded| {
            payload = @ptrCast(decoded);
        } else {
            if (id) |o| free(@ptrCast(o));
            if (app_id) |o| free(@ptrCast(o));
            if (icon_cache_id) |o| free(@ptrCast(o));
            if (symbolic_icon) |o| free(@ptrCast(o));
            if (payload) |o| free(@ptrCast(o));
            if (category) |o| free(@ptrCast(o));
            if (sound_name) |o| free(@ptrCast(o));
            return;
        }
    } else {
        payload = xstrdup(payload_raw);
        if (payload) |p| payload_size = strlen(p);
    }

    const notif = &term.kitty_notification;

    const same = (id == null and notif.id == null) or
                 (id != null and notif.id != null and streqz(id.?, notif.id.?));
    if (!same or !notif.may_be_programatically_closed) {
        notify_free(term, notif);
        notif.id = id;
        notif.when = when;
        notif.urgency = urgency;
        notif.expire_time = expire_time;
        notif.focus = focus;
        notif.may_be_programatically_closed = true;
        notif.report_activated = report_activated;
        notif.report_closed = report_closed;
        id = null;
    }

    if (have_a) { notif.focus = focus; notif.report_activated = report_activated; }
    if (have_c) { notif.report_closed = report_closed; }
    if (have_o) { notif.when = when; }
    if (have_u) { notif.urgency = urgency; }
    if (have_w) { notif.expire_time = expire_time; }

    if (icon_cache_id) |ici| {
        if (notif.icon_cache_id) |o| free(@ptrCast(o));
        notif.icon_cache_id = ici;
        icon_cache_id = null;
    }
    if (symbolic_icon) |si| {
        if (notif.icon_symbolic_name) |o| free(@ptrCast(o));
        notif.icon_symbolic_name = si;
        symbolic_icon = null;
    }
    if (app_id) |ai| {
        if (notif.app_id) |o| free(@ptrCast(o));
        notif.app_id = ai;
        app_id = null;
    }
    if (category) |cat| {
        if (notif.category) |old| {
            const new_cat = osc_xstrjoin3(old, ",", cat);
            free(@ptrCast(old));
            notif.category = new_cat;
        } else {
            notif.category = cat;
            category = null;
        }
    }
    if (sound_name) |sn| {
        notif.muted = streqz(sn, "silent");
        if (notif.muted or streqz(sn, "system")) {
            if (notif.sound_name) |o| free(@ptrCast(o));
            notif.sound_name = null;
        } else {
            if (notif.sound_name) |o| free(@ptrCast(o));
            notif.sound_name = sn;
            sound_name = null;
        }
    }

    switch (payload_type) {
        PAYLOAD_TITLE, PAYLOAD_BODY => {
            const ptr: *?[*:0]u8 = if (payload_type == PAYLOAD_TITLE) &notif.title else &notif.body;
            if (ptr.* == null) {
                ptr.* = payload;
                payload = null;
            } else {
                const old = ptr.*.?;
                ptr.* = osc_xstrjoin(old, payload.?);
                free(@ptrCast(old));
            }
        },
        PAYLOAD_CLOSE, PAYLOAD_ALIVE => {},
        PAYLOAD_ICON => {
            if (notif.icon_data == null) {
                notif.icon_data = @ptrCast(payload);
                notif.icon_data_sz = payload_size;
                payload = null;
            } else {
                const new_ptr: [*]u8 = @ptrCast(xrealloc(@ptrCast(notif.icon_data), notif.icon_data_sz + payload_size) orelse return);
                @memcpy(new_ptr[notif.icon_data_sz..notif.icon_data_sz + payload_size], @as([*]const u8, @ptrCast(payload.?))[0..payload_size]);
                notif.icon_data = new_ptr;
                notif.icon_data_sz += payload_size;
            }
        },
        PAYLOAD_BUTTON => {
            var b_ctx: ?[*:0]u8 = null;
            var button = strtok_r(payload.?, "\u{2028}", &b_ctx);
            while (button) |b| : (button = strtok_r(null, "\u{2028}", &b_ctx)) {
                if (b[0] != 0) osc_kitty_actions_push_back(notif, xstrdup(b).?);
            }
        },
        else => {},
    }

    if (done) {
        if (notif.icon_cache_id) |cache_id| {
            if (notif.icon_symbolic_name != null or notif.icon_data != null) {
                notify_icon_del(term, cache_id);
                notify_icon_add(term, cache_id, notif.icon_symbolic_name, notif.icon_data, notif.icon_data_sz);
                if (notif.icon_symbolic_name) |o| free(@ptrCast(o));
                if (notif.icon_data) |o| free(@ptrCast(o));
                notif.icon_symbolic_name = null;
                notif.icon_data = null;
                notif.icon_data_sz = 0;
            }
        }

        if (payload_type == PAYLOAD_CLOSE) {
            if (notif.id) |nid| notify_close(term, nid);
        } else if (payload_type == PAYLOAD_ALIVE) {
            var alive_ids: ?[*:0]u8 = null;
            var ait = notify_active_first(term);
            while (ait) |active| : (ait = notify_active_next(term, active)) {
                const item_id: [*:0]const u8 = if (active.id) |x| x else "0";
                if (alive_ids == null) {
                    alive_ids = xstrdup(item_id);
                } else {
                    const nw = osc_xstrjoin3(alive_ids.?, ",", item_id);
                    free(@ptrCast(alive_ids.?));
                    alive_ids = nw;
                }
            }
            const reply = xasprintf("\x1b]99;i=%s:p=alive;%s\x1b\\",
                if (notif.id) |x| x else "0",
                if (alive_ids) |x| x else "");
            if (reply) |r| {
                _ = term_to_slave(term, r, strlen(r));
                free(@ptrCast(r));
            }
            if (alive_ids) |o| free(@ptrCast(o));
        } else {
            if (notif.title != null or notif.body != null) {
                _ = notify_notify(term, notif);
            }
        }
        notify_free(term, notif);
    }

    if (id) |o| free(@ptrCast(o));
    if (app_id) |o| free(@ptrCast(o));
    if (icon_cache_id) |o| free(@ptrCast(o));
    if (symbolic_icon) |o| free(@ptrCast(o));
    if (payload) |o| free(@ptrCast(o));
    if (category) |o| free(@ptrCast(o));
    if (sound_name) |o| free(@ptrCast(o));
}
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn notify_active_first(term: *types.Terminal) callconv(.c) ?*types.Notification;
extern fn notify_active_next(term: *types.Terminal, prev: *types.Notification) callconv(.c) ?*types.Notification;

// ── chunk E-3: kitty_text_size (OSC-66) ──────────────────────────
extern fn ambstoc32(s: [*:0]const u8) callconv(.c) ?[*]u32;
extern fn osc_c32len(s: [*]const u32) callconv(.c) usize;
extern fn composed_key_from_chars(chars: [*]const u32, count: usize) callconv(.c) u32;
extern fn composed_lookup_without_collision(root: ?*types.Composed, key: *u32, chars: [*]const u32, count: usize, last: u32, forced_width: c_int) callconv(.c) ?*types.Composed;
extern fn composed_insert(root: *?*types.Composed, node: ?*types.Composed) callconv(.c) void;
extern fn term_print(term: *types.Terminal, wc: u32, width: c_int, is_wide: bool) callconv(.c) void;

const CELL_COMB_CHARS_LO: u32 = 0x00200000;
const GRAPHEME_WIDTH_WCSWIDTH: c_int = 0;
const GRAPHEME_WIDTH_MAX: c_int = 1;
const GRAPHEME_WIDTH_DOUBLE: c_int = 2;

export fn kitty_text_size_impl(term: *types.Terminal, string: [*:0]u8) callconv(.c) void {
    const text_ptr = strchr(string, ';') orelse return;
    text_ptr[0] = 0;
    const text: [*:0]u8 = text_ptr + 1;

    if (text[0] == 0) return;

    const wchars = ambstoc32(text) orelse return;

    var forced_width: c_int = 0;

    var ctx: ?[*:0]u8 = null;
    var param = strtok_r(string, ":", &ctx);
    while (param) |p| : (param = strtok_r(null, ":", &ctx)) {
        if (p[0] == 0 or p[1] != '=') continue;
        const value: [*:0]u8 = @ptrCast(p + 2);

        switch (p[0]) {
            'w' => {
                __errno_location().* = 0;
                var end: [*:0]u8 = undefined;
                const w = strtoul(value, &end, 10);
                if (end[0] == 0 and __errno_location().* == 0 and w <= 7) {
                    forced_width = @intCast(w);
                }
            },
            else => {},
        }
    }

    const len = osc_c32len(wchars);

    if (forced_width == 0) {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            term_process_and_print_non_ascii(term, wchars[i]);
        }
        free(@ptrCast(wchars));
        return;
    }

    var max_cp_width: usize = 0;
    var all_cp_width: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const cp_width: usize = @intCast(csi_c32width(wchars[i]));
        all_cp_width += cp_width;
        if (cp_width > max_cp_width) max_cp_width = cp_width;
    }

    var calculated_width: usize = 0;
    const method = @intFromEnum(term.conf.?.tweak.grapheme_width_method);
    if (method == GRAPHEME_WIDTH_WCSWIDTH) calculated_width = all_cp_width
    else if (method == GRAPHEME_WIDTH_MAX) calculated_width = max_cp_width
    else if (method == GRAPHEME_WIDTH_DOUBLE) calculated_width = @min(max_cp_width, 2);

    const width: usize = if (forced_width == 0) calculated_width else @intCast(forced_width);

    var key = composed_key_from_chars(wchars, len);
    const composed = composed_lookup_without_collision(
        term.composed, &key, wchars, len - 1, wchars[len - 1], forced_width);

    if (composed == null) {
        const new_cc: *types.Composed = @ptrCast(@alignCast(xmalloc(@sizeOf(types.Composed)) orelse {
            free(@ptrCast(wchars));
            return;
        }));
        new_cc.chars = wchars;
        new_cc.count = @intCast(len);
        new_cc.key = key;
        new_cc.width = @intCast(width);
        new_cc.forced_width = @intCast(forced_width);

        term.composed_count += 1;
        composed_insert(&term.composed, new_cc);
    } else if (composed.?.width == width) {
        free(@ptrCast(wchars));
    }

    const final_composed = composed orelse blk: {
        // should be filled by composed_insert re-read; fallback
        break :blk term.composed.?;
    };
    _ = final_composed;

    // Re-lookup since composed_insert may have rebalanced the tree
    const found = composed_lookup_without_collision(
        term.composed, &key, wchars, len - 1, wchars[len - 1], forced_width) orelse return;

    const print_width: c_int = if (found.forced_width > 0) @intCast(found.forced_width) else @intCast(found.width);
    term_print(term, CELL_COMB_CHARS_LO + found.key, print_width, false);
}
extern fn csi_c32width(c: u32) callconv(.c) c_int;
extern fn term_process_and_print_non_ascii(term: *types.Terminal, wc: u32) callconv(.c) void;
