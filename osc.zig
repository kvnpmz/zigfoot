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

