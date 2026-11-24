const std = @import("std");

//
// debug.c ported to Zig: fatal_error() and the variadic bug() used by the
// xassert()/BUG() macros. The AddressSanitizer stack-trace hook stays in C
// (it is only compiled in when the sanitizer is enabled).
//

const LOG_CLASS_ERROR: c_int = 1;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;
extern fn vsnprintf(
    str: [*]u8,
    size: usize,
    format: [*:0]const u8,
    ap: *std.builtin.VaList,
) c_int;
extern fn strerror(errnum: c_int) [*:0]u8;
extern var stderr: *std.c.FILE;
extern fn fflush(stream: ?*std.c.FILE) c_int;

extern fn debug_shim_print_stack_trace() callconv(.c) void;

export fn fatal_error(
    file: [*:0]const u8,
    line: c_int,
    msg: [*:0]const u8,
    err: c_int,
) callconv(.c) noreturn {
    log_msg(LOG_CLASS_ERROR, "debug", file, line, "%s: %s", msg, strerror(err));
    debug_shim_print_stack_trace();
    _ = fflush(stderr);
    std.c.abort();
}

export fn bug(
    file: [*:0]const u8,
    line: c_int,
    func: [*:0]const u8,
    fmt: [*:0]const u8,
    ...
) callconv(.c) noreturn {
    var ap = @cVaStart();

    var buf: [4096]u8 = undefined;
    const n = vsnprintf(&buf, buf.len, fmt, &ap);
    @cVaEnd(&ap);

    const msg: [*:0]const u8 = if (n >= 0) @ptrCast(&buf) else "??";

    log_msg(LOG_CLASS_ERROR, "debug", file, line, "BUG in %s(): %s", func, msg);
    debug_shim_print_stack_trace();
    _ = fflush(stderr);
    std.c.abort();
}
