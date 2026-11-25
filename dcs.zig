const std = @import("std");
const types = @import("terminal_types.zig");

// ── C-side symbols we call into ───────────────────────────────────
extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn memchr(s: ?*const anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque;
extern fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) callconv(.c) c_int;
extern fn strlen(s: [*:0]const u8) callconv(.c) usize;

extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

extern fn term_to_slave(term: *types.Terminal, buf: [*]const u8, len: usize) callconv(.c) void;
extern fn term_enable_app_sync_updates(term: *types.Terminal) callconv(.c) void;
extern fn term_disable_app_sync_updates(term: *types.Terminal) callconv(.c) void;

// sixel_init returns a function pointer with type `void (*)(struct terminal *, uint8_t)`.
// Declared as returning an opaque fn pointer; we @ptrCast at assignment.
extern fn sixel_init(term: *types.Terminal, p1: c_int, p2: c_int, p3: c_int) callconv(.c) ?*const fn (*types.Terminal, u8) callconv(.c) void;
extern fn sixel_unhook(term: *types.Terminal) callconv(.c) void;

// ── Accessors from dcs-shim.c ─────────────────────────────────────
extern fn dcs_terminfo_capabilities() callconv(.c) [*]const u8;
extern fn dcs_terminfo_capabilities_size() callconv(.c) usize;
// ── Inlined vt_param_get (was static inline in vt.h) ──────────────
fn vtParamGet(term: *const types.Terminal, idx: usize, default_value: c_int) c_int {
    const value_mask: c_uint = 0x7fff_ffff;
    if (@as(usize, term.vt.params.idx) > idx) {
        const value: c_uint = term.vt.params.v[idx].value & value_mask;
        return if (value != 0) @intCast(value) else default_value;
    }
    return default_value;
}

// ── hex2nibble (was static inline in util.h) ──────────────────────
const HEX_DIGIT_INVALID: u8 = 16;

fn hex2nibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => HEX_DIGIT_INVALID,
    };
}

// ── Logging (diagnostic only; falls back to std.debug) ────────────
fn logErrno(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dcs: " ++ fmt ++ " (errno)\n", args);
}
fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dcs: WARN: " ++ fmt ++ "\n", args);
}

// ── ensure_size ───────────────────────────────────────────────────
fn ensureSize(term: *types.Terminal, required_size: usize) bool {
    if (required_size <= term.vt.dcs.size)
        return true;

    const new_data: ?[*]u8 = @ptrCast(realloc(
        if (term.vt.dcs.data) |d| @ptrCast(d) else null,
        required_size,
    ));
    if (new_data == null) {
        logErrno("failed to increase size of DCS buffer", .{});
        return false;
    }

    term.vt.dcs.data = new_data;
    term.vt.dcs.size = required_size;
    return true;
}

// ── hex_decode ────────────────────────────────────────────────────
fn hexDecode(s_in: [*]const u8, len: usize) ?[*:0]u8 {
    if (len % 2 != 0)
        return null;

    const buf = xmalloc(len / 2 + 1) orelse return null;
    const hex: [*]u8 = @ptrCast(buf);
    var o: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const nib1 = hex2nibble(s_in[i]);
        const nib2 = hex2nibble(s_in[i + 1]);
        if (nib1 == HEX_DIGIT_INVALID or nib2 == HEX_DIGIT_INVALID) {
            free(buf);
            return null;
        }
        hex[o] = (nib1 << 4) | nib2;
        o += 1;
    }
    hex[o] = 0;
    return @ptrCast(hex);
}

// ── lookup_capability ─────────────────────────────────────────────
fn lookupCapability(name: [*:0]const u8, value_out: *?[*:0]const u8) bool {
    const base = dcs_terminfo_capabilities();
    const total = dcs_terminfo_capabilities_size();
    var p: usize = 0;
    var left: usize = total;

    while (left > 0) {
        const cap: [*:0]const u8 = @ptrCast(base + p);
        const cap_len = strlen(cap);
        const val: [*:0]const u8 = @ptrCast(base + p + cap_len + 1);
        const val_len = strlen(val);
        const size = cap_len + 1 + val_len + 1;
        std.debug.assert(size <= left);
        p += size;
        left -= size;

        const r = std.mem.orderZ(u8, cap, name);
        switch (r) {
            .eq => {
                value_out.* = val;
                return true;
            },
            .gt => break,
            .lt => {},
        }
    }

    value_out.* = null;
    return false;
}

// ── xtgettcap_reply ───────────────────────────────────────────────
fn xtgettcapReply(term: *types.Terminal, hex_cap_name: [*]const u8, len: usize) void {
    const maybe_name = hexDecode(hex_cap_name, len);
    if (maybe_name == null) {
        logWarn("XTGETTCAP: invalid hex encoding, ignoring capability", .{});
        return;
    }
    const name: [*:0]u8 = maybe_name.?;

    var value_opt: ?[*:0]const u8 = null;
    const valid_capability = lookupCapability(name, &value_opt);

    std.debug.assert(!valid_capability or value_opt != null);

    if (!valid_capability) {
        // err: reply 0+r
        term_to_slave(term, "\x1bP0+r", 5);
        term_to_slave(term, hex_cap_name, len);
        term_to_slave(term, "\x1b\\", 2);
        free(name);
        return;
    }

    const value = value_opt.?;
    const value_len = strlen(value);

    if (value_len == 0) {
        // Boolean capability
        term_to_slave(term, "\x1bP1+r", 5);
        term_to_slave(term, hex_cap_name, len);
        term_to_slave(term, "\x1b\\", 2);
        free(name);
        return;
    }

    // Reply: DCS "1+r" <hex_cap_name> "=" <hex_value> ST
    const reply_size = 5 + len + 1 + value_len * 2 + 2 + 1;
    const reply_buf = xmalloc(reply_size) orelse {
        free(name);
        return;
    };
    const reply: [*]u8 = @ptrCast(reply_buf);
    var idx: usize = 0;

    // "\x1bP1+r"
    const prefix = "\x1bP1+r";
    @memcpy(reply[idx .. idx + prefix.len], prefix);
    idx += prefix.len;
    // hex_cap_name (already hex-encoded by caller)
    @memcpy(reply[idx .. idx + len], hex_cap_name[0..len]);
    idx += len;
    // "="
    reply[idx] = '=';
    idx += 1;
    // hex-encode value
    var i: usize = 0;
    while (i < value_len) : (i += 1) {
        const c: u8 = @bitCast(value[i]);
        const nib1: u8 = c >> 4;
        const nib2: u8 = c & 0xf;
        reply[idx] = if (nib1 >= 0xa) 'A' + nib1 - 0xa else '0' + nib1;
        idx += 1;
        reply[idx] = if (nib2 >= 0xa) 'A' + nib2 - 0xa else '0' + nib2;
        idx += 1;
    }
    // ST
    reply[idx] = 0x1b;
    idx += 1;
    reply[idx] = '\\';
    idx += 1;

    term_to_slave(term, reply, idx);
    free(reply_buf);
    free(name);
}

// ── xtgettcap_put / unhook ────────────────────────────────────────
fn xtgettcapPut(term: *types.Terminal, c: u8) void {
    if (term.vt.dcs.idx >= term.vt.dcs.size) {
        var new_size: usize = term.vt.dcs.size * 2;
        if (new_size == 0) new_size = 128;
        if (!ensureSize(term, new_size)) return;
    }
    term.vt.dcs.data.?[term.vt.dcs.idx] = c;
    term.vt.dcs.idx += 1;
}

fn xtgettcapUnhook(term: *types.Terminal) void {
    if (term.vt.dcs.data == null) {
        term_to_slave(term, "\x1bP0+r\x1b\\", 7);
        return;
    }

    const data: [*]u8 = term.vt.dcs.data.?;
    var left: usize = term.vt.dcs.idx;
    var p: [*]const u8 = data;

    while (true) {
        const sep: ?[*]u8 = if (memchr(p, ';', left)) |s| @ptrCast(s) else null;
        const cap_len: usize = if (sep) |s|
            @intCast(@intFromPtr(s) - @intFromPtr(p))
        else
            left;

        xtgettcapReply(term, p, cap_len);

        left -= cap_len + 1;
        p += cap_len + 1;

        if (sep == null) break;
    }
}

// ── append_sgr_attr_n ─────────────────────────────────────────────
fn appendSgrAttrN(reply: *?[*]u8, len: *usize, attr: []const u8) void {
    const new_len = len.* + attr.len + 1;
    const new_ptr = xrealloc(
        if (reply.*) |r| @ptrCast(r) else null,
        new_len,
    ) orelse return;
    const rp: [*]u8 = @ptrCast(new_ptr);
    @memcpy(rp[len.* .. len.* + attr.len], attr);
    rp[new_len - 1] = ';';
    reply.* = rp;
    len.* = new_len;
}

// ── decrqss_put / unhook ──────────────────────────────────────────
fn decrqssPut(term: *types.Terminal, c: u8) void {
    if (!ensureSize(term, 2)) return;
    if (term.vt.dcs.idx >= 2) return;
    term.vt.dcs.data.?[term.vt.dcs.idx] = c;
    term.vt.dcs.idx += 1;
}

fn decrqssUnhook(term: *types.Terminal) void {
    const data = term.vt.dcs.data;
    const n = term.vt.dcs.idx;

    // Helper to write `s` as ASCII bytes (compile-time string literal).
    const writeLit = struct {
        fn f(t: *types.Terminal, comptime s: []const u8) void {
            term_to_slave(t, s.ptr, s.len);
        }
    }.f;

    if (n == 1 and data.?[0] == 'r') {
        // DECSTBM
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{
            term.scroll_region.start + 1,
            term.scroll_region.end,
        }) catch return;
        term_to_slave(term, s.ptr, s.len);
    } else if (n == 1 and data.?[0] == 'm') {
        // SGR
        var reply: ?[*]u8 = null;
        var len: usize = 0;

        appendSgrAttrN(&reply, &len, "0");

        const a = &term.vt.attrs;
        if (a.bold)        appendSgrAttrN(&reply, &len, "1");
        if (a.dim)         appendSgrAttrN(&reply, &len, "2");
        if (a.italic)      appendSgrAttrN(&reply, &len, "3");
        if (a.underline) {
            if (term.vt.underline.style != .none and
                term.vt.underline.style != .single)
            {
                var value: [8]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "4:{d}", .{
                    @intFromEnum(term.vt.underline.style),
                }) catch return;
                appendSgrAttrN(&reply, &len, v);
            } else {
                appendSgrAttrN(&reply, &len, "4");
            }
        }
        if (a.blink)       appendSgrAttrN(&reply, &len, "5");
        if (a.reverse)     appendSgrAttrN(&reply, &len, "7");
        if (a.conceal)     appendSgrAttrN(&reply, &len, "8");
        if (a.strikethrough)      appendSgrAttrN(&reply, &len, "9");

        // fg
        switch (@as(types.ColorSource, @enumFromInt(a.fg_src))) {
            .default => {},
            .base16 => {
                var value: [8]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "{d}", .{
                    if (a.fg >= 8) a.fg - 8 + 90 else a.fg + 30,
                }) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
            .base256 => {
                var value: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "38:5:{d}", .{a.fg}) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
            .rgb => {
                const r: u8 = @intCast((a.fg >> 16) & 0xff);
                const g: u8 = @intCast((a.fg >> 8) & 0xff);
                const b: u8 = @intCast(a.fg & 0xff);
                var value: [32]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "38:2::{d}:{d}:{d}", .{ r, g, b }) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
        }

        // bg
        switch (@as(types.ColorSource, @enumFromInt(a.bg_src))) {
            .default => {},
            .base16 => {
                var value: [8]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "{d}", .{
                    if (a.bg >= 8) a.bg - 8 + 100 else a.bg + 40,
                }) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
            .base256 => {
                var value: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "48:5:{d}", .{a.bg}) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
            .rgb => {
                const r: u8 = @intCast((a.bg >> 16) & 0xff);
                const g: u8 = @intCast((a.bg >> 8) & 0xff);
                const b: u8 = @intCast(a.bg & 0xff);
                var value: [32]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "48:2::{d}:{d}:{d}", .{ r, g, b }) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
        }

        // underline color
        switch (term.vt.underline.color_src) {
            .default, .base16 => {},
            .base256 => {
                var value: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "58:5:{d}", .{term.vt.underline.color}) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
            .rgb => {
                const r: u8 = @intCast((term.vt.underline.color >> 16) & 0xff);
                const g: u8 = @intCast((term.vt.underline.color >> 8) & 0xff);
                const b: u8 = @intCast(term.vt.underline.color & 0xff);
                var value: [32]u8 = undefined;
                const v = std.fmt.bufPrint(&value, "58:2::{d}:{d}:{d}", .{ r, g, b }) catch return;
                appendSgrAttrN(&reply, &len, v);
            },
        }

        if (reply) |rp| {
            rp[len - 1] = 'm';
            writeLit(term, "\x1bP1$r");
            term_to_slave(term, rp, len);
            writeLit(term, "\x1b\\");
            free(@ptrCast(rp));
        }
    } else if (n == 2 and memcmp(data, " q", 2) == 0) {
        // DECSCUSR
        const mode: c_int = switch (term.cursor_style) {
            .hollow, .block => 2,
            .underline => 4,
            .beam => 6,
        };
        const adj = if (term.cursor_blink.deccsusr) mode - 1 else mode;
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{adj}) catch return;
        term_to_slave(term, s.ptr, s.len);
    } else {
        writeLit(term, "\x1bP0$r\x1b\\");
    }
}

// ── C→Zig entry points ────────────────────────────────────────────
export fn dcs_hook(term: *types.Terminal, final: u8) callconv(.c) void {
    std.debug.assert(term.vt.dcs.data == null);
    std.debug.assert(term.vt.dcs.size == 0);
    std.debug.assert(term.vt.dcs.put_handler == null);
    std.debug.assert(term.vt.dcs.unhook_handler == null);

    switch (term.vt.private) {
        0 => switch (final) {
            'q' => {
                if (!term.conf.?.tweak.sixel) return;
                const p1 = vtParamGet(term, 0, 0);
                const p2 = vtParamGet(term, 1, 0);
                const p3 = vtParamGet(term, 2, 0);
                const put_fn = sixel_init(term, p1, p2, p3);
                if (put_fn) |f| {
                    term.vt.dcs.put_handler = @ptrCast(f);
                }
                term.vt.dcs.unhook_handler = @ptrCast(&sixel_unhook);
            },
            else => {},
        },
        '$' => switch (final) {
            'q' => {
                term.vt.dcs.put_handler = @ptrCast(&decrqssPut);
                term.vt.dcs.unhook_handler = @ptrCast(&decrqssUnhook);
            },
            else => {},
        },
        '=' => switch (final) {
            's' => switch (vtParamGet(term, 0, 0)) {
                1 => {
                    term.vt.dcs.unhook_handler = @ptrCast(&term_enable_app_sync_updates);
                    return;
                },
                2 => {
                    term.vt.dcs.unhook_handler = @ptrCast(&term_disable_app_sync_updates);
                    return;
                },
                else => {},
            },
            else => {},
        },
        '+' => switch (final) {
            'q' => {
                term.vt.dcs.put_handler = @ptrCast(&xtgettcapPut);
                term.vt.dcs.unhook_handler = @ptrCast(&xtgettcapUnhook);
            },
            else => {},
        },
        else => {},
    }
}

export fn dcs_put(term: *types.Terminal, c: u8) callconv(.c) void {
    if (term.vt.dcs.put_handler) |f| f(@ptrCast(term), c);
}

export fn dcs_unhook(term: *types.Terminal) callconv(.c) void {
    if (term.vt.dcs.unhook_handler) |f| f(@ptrCast(term));

    term.vt.dcs.unhook_handler = null;
    term.vt.dcs.put_handler = null;

    free(if (term.vt.dcs.data) |d| @ptrCast(d) else null);
    term.vt.dcs.data = null;
    term.vt.dcs.size = 0;
    term.vt.dcs.idx = 0;
}
