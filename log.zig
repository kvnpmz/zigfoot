const std = @import("std");
const build_options = @import("build_options");

//
// log.c ported to Zig: the five C-variadic entry points, the stderr and syslog
// sinks, and the level parsing/help text.
//
// The variadic C ABI is handled with @cVaStart/@cVaCopy/@cVaEnd and passed
// straight to vfprintf()/vsnprintf(), so formatted output is byte-identical to
// the C version and no format string has to be parsed twice.
//

const LOG_CLASS_NONE: c_int = 0;
const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;
const LOG_CLASS_DEBUG: c_int = 4;
const LOG_CLASS_COUNT: c_int = 5;

const LOG_COLORIZE_NEVER: c_int = 0;
const LOG_COLORIZE_ALWAYS: c_int = 1;
const LOG_COLORIZE_AUTO: c_int = 2;

const LOG_FACILITY_USER: c_int = 0;
const LOG_FACILITY_DAEMON: c_int = 1;

// <syslog.h>
const LOG_USER: c_int = 1 << 3;
const LOG_DAEMON: c_int = 3 << 3;
const LOG_ERR: c_int = 3;
const LOG_WARNING: c_int = 4;
const LOG_INFO: c_int = 6;
const LOG_DEBUG: c_int = 7;

const STDERR_FILENO: c_int = 2;

extern var stderr: *std.c.FILE;
extern fn vfprintf(stream: *std.c.FILE, format: [*:0]const u8, ap: *std.builtin.VaList) c_int;
extern fn vsnprintf(str: [*]u8, size: usize, format: [*:0]const u8, ap: *std.builtin.VaList) c_int;
extern fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
extern fn fprintf(stream: *std.c.FILE, format: [*:0]const u8, ...) c_int;
extern fn fputc(c: c_int, stream: *std.c.FILE) c_int;
extern fn fputs(s: [*:0]const u8, stream: *std.c.FILE) c_int;
extern fn strerror(errnum: c_int) [*:0]u8;
extern fn isatty(fd: c_int) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

extern fn openlog(ident: ?[*:0]const u8, option: c_int, facility: c_int) void;
extern fn closelog() void;
extern fn setlogmask(mask: c_int) c_int;
extern fn syslog(priority: c_int, format: [*:0]const u8, ...) void;

const LogLevelEntry = struct {
    name: [:0]const u8,
    log_prefix: [:0]const u8,
    color: u8,
    syslog_equivalent: c_int,
};

const log_level_map = [_]LogLevelEntry{
    .{ .name = "none", .log_prefix = "none", .color = 5, .syslog_equivalent = -1 },
    .{ .name = "error", .log_prefix = " err", .color = 31, .syslog_equivalent = LOG_ERR },
    .{ .name = "warning", .log_prefix = "warn", .color = 33, .syslog_equivalent = LOG_WARNING },
    .{ .name = "info", .log_prefix = "info", .color = 97, .syslog_equivalent = LOG_INFO },
    .{ .name = "debug", .log_prefix = " dbg", .color = 36, .syslog_equivalent = LOG_DEBUG },
};

var colorize: bool = false;
var do_syslog: bool = false;
var log_level: c_int = LOG_CLASS_NONE;

fn logUpTo(pri: c_int) c_int {
    return (@as(c_int, 1) << @intCast(pri & 0x07)) - 1;
}

export fn log_init(
    _colorize: c_int,
    _do_syslog: bool,
    syslog_facility: c_int,
    _log_level: c_int,
) callconv(.c) void {
    std.debug.assert(_log_level >= 0 and _log_level < log_level_map.len);

    // Don't use colors if NO_COLOR is defined and not empty
    const no_color_str = getenv("NO_COLOR");
    const no_color = if (no_color_str) |s| s[0] != 0 else false;

    colorize = _colorize == LOG_COLORIZE_ALWAYS or
        (_colorize == LOG_COLORIZE_AUTO and
            !no_color and isatty(STDERR_FILENO) != 0);
    do_syslog = _do_syslog;
    log_level = _log_level;

    const slvl = log_level_map[@intCast(_log_level)].syslog_equivalent;
    if (slvl < 0)
        do_syslog = false;

    if (do_syslog) {
        const facility: c_int = switch (syslog_facility) {
            LOG_FACILITY_USER => LOG_USER,
            LOG_FACILITY_DAEMON => LOG_DAEMON,
            else => unreachable,
        };

        openlog(null, 0, facility);
        std.debug.assert(slvl >= 0);
        _ = setlogmask(logUpTo(slvl));
    }
}

export fn log_deinit() callconv(.c) void {
    if (do_syslog)
        closelog();
}

fn log(
    class: c_int,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    sys_errno: c_int,
    va: *std.builtin.VaList,
) void {
    std.debug.assert(class > LOG_CLASS_NONE);
    std.debug.assert(class < log_level_map.len);

    if (class > log_level)
        return;

    const entry = log_level_map[@intCast(class)];

    var clr: [16]u8 = undefined;
    _ = snprintf(&clr, clr.len, "\x1b[%um", @as(c_uint, entry.color));

    _ = fprintf(
        stderr,
        "%s%s%s: ",
        if (colorize) @as([*:0]const u8, @ptrCast(&clr)) else "",
        entry.log_prefix.ptr,
        if (colorize) @as([*:0]const u8, "\x1b[0m") else "",
    );

    if (colorize)
        _ = fputs("\x1b[2m", stderr);
    _ = fprintf(stderr, "%s:%d: ", file, lineno);
    if (colorize)
        _ = fputs("\x1b[0m", stderr);

    _ = vfprintf(stderr, fmt, va);

    if (sys_errno != 0)
        _ = fprintf(stderr, ": %s", strerror(sys_errno));

    _ = fputc('\n', stderr);
}

fn sysLog(
    class: c_int,
    module: [*:0]const u8,
    fmt: [*:0]const u8,
    sys_errno: c_int,
    va: *std.builtin.VaList,
) void {
    std.debug.assert(class > LOG_CLASS_NONE);
    std.debug.assert(class < log_level_map.len);

    if (!do_syslog)
        return;

    if (class > log_level)
        return;

    // Map our log level to syslog's level
    const level = log_level_map[@intCast(class)].syslog_equivalent;

    var msg: [4096]u8 = undefined;
    const n = vsnprintf(&msg, msg.len, fmt, va);
    std.debug.assert(n >= 0);

    const n_ok: usize = @intCast(n);
    if (sys_errno != 0 and n_ok < msg.len)
        _ = snprintf(
            msg[n_ok..].ptr,
            msg.len - n_ok,
            ": %s",
            strerror(sys_errno),
        );

    syslog(level, "%s: %s", module, @as([*:0]const u8, @ptrCast(&msg)));
}

export fn log_msg_va(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    va: *std.builtin.VaList,
) callconv(.c) void {
    var va2 = @cVaCopy(va);

    log(class, file, lineno, fmt, 0, va);
    sysLog(class, module, fmt, 0, &va2);

    @cVaEnd(&va2);
}

export fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void {
    var va = @cVaStart();
    defer @cVaEnd(&va);
    log_msg_va(class, module, file, lineno, fmt, &va);
}

export fn log_errno_va(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    va: *std.builtin.VaList,
) callconv(.c) void {
    log_errno_provided_va(class, module, file, lineno, std.c._errno().*, fmt, va);
}

export fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void {
    var va = @cVaStart();
    defer @cVaEnd(&va);
    log_errno_va(class, module, file, lineno, fmt, &va);
}

export fn log_errno_provided_va(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    errno_copy: c_int,
    fmt: [*:0]const u8,
    va: *std.builtin.VaList,
) callconv(.c) void {
    var va2 = @cVaCopy(va);

    log(class, file, lineno, fmt, errno_copy, va);
    sysLog(class, module, fmt, errno_copy, &va2);

    @cVaEnd(&va2);
}

export fn log_errno_provided(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, errno_copy: c_int, fmt: [*:0]const u8, ...) callconv(.c) void {
    var va = @cVaStart();
    defer @cVaEnd(&va);
    log_errno_provided_va(class, module, file, lineno, errno_copy, fmt, &va);
}

fn mapLen() usize {
    // Exclude the "debug" entry for non-debug builds
    return if (build_options.debug_build) log_level_map.len else log_level_map.len - 1;
}

export fn log_level_from_string(str: [*:0]const u8) callconv(.c) c_int {
    if (str[0] == 0)
        return -1;

    var i: usize = 0;
    const n = mapLen();
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(str), log_level_map[i].name))
            return @intCast(i);
    }

    return -1;
}

var hint_buf: [64]u8 = @splat(0);

export fn log_level_string_hint() callconv(.c) [*:0]const u8 {
    if (hint_buf[0] != 0)
        return @ptrCast(&hint_buf);

    var pos: usize = 0;
    const n = mapLen();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = log_level_map[i].name;
        const delim: [*:0]const u8 = if (i + 1 < n) ", " else "";
        pos += @intCast(snprintf(
            hint_buf[pos..].ptr,
            hint_buf.len - pos,
            "'%s'%s",
            entry.ptr,
            delim,
        ));
    }

    return @ptrCast(&hint_buf);
}
