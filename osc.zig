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

