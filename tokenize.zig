extern fn log_msg(log_class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn xstrndup(str: [*c]const u8, n: usize) callconv(.c) [*c]u8;
extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn strlen(s: [*c]const u8) callconv(.c) usize;
extern fn strchr(s: [*c]const u8, c: c_int) [*c]u8;
extern fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;

const LOG_CLASS_ERROR: c_int = 1;

fn push_argv(argv: *[*c][*c]u8, size: *usize, arg: [*c]const u8, len: usize, argc: *usize) bool {
    if (arg != null and arg[0] == '%')
        return true;

    if (argc.* >= size.*) {
        const new_size: usize = if (size.* > 0) 2 * size.* else 10;
        const raw = realloc(@ptrCast(argv.*), new_size * @sizeOf([*c]u8));
        if (raw == null)
            return false;

        argv.* = @ptrCast(@alignCast(raw.?));
        size.* = new_size;
    }

    argv.*[argc.*] = if (arg != null) xstrndup(arg, len) else null;
    argc.* += 1;
    return true;
}

fn fail(argv: *[*c][*c]u8, idx: usize) bool {
    var i: usize = 0;
    while (i < idx) : (i += 1)
        free(argv.*[i]);
    free(@ptrCast(argv.*));
    argv.* = null;
    return false;
}

export fn tokenize_cmdline(cmdline: [*c]const u8, argv: *[*c][*c]u8) bool {
    argv.* = null;
    var argv_size: usize = 0;

    const final_end: [*c]const u8 = cmdline + strlen(cmdline) + 1;

    const first_token_is_quoted = cmdline[0] == '"' or cmdline[0] == '\'';
    var delim: u8 = if (first_token_is_quoted) cmdline[0] else ' ';

    var p: [*c]const u8 = if (first_token_is_quoted) cmdline + 1 else cmdline;
    var search_start: [*c]const u8 = p;

    var idx: usize = 0;
    while (p[0] != 0) {
        const end: [*c]u8 = strchr(search_start, @as(c_int, delim));
        if (end == null) {
            if (delim != ' ') {
                const which: [*:0]const u8 = if (delim == '"') "double" else "single";
                log_msg(LOG_CLASS_ERROR, "tokenize", "tokenize.zig", @as(c_int, @intCast(@src().line)), "unterminated %s quote", which);
                return fail(argv, idx);
            }

            if (!push_argv(argv, &argv_size, p, @intFromPtr(final_end) - @intFromPtr(p), &idx) or
                !push_argv(argv, &argv_size, null, 0, &idx))
            {
                return fail(argv, idx);
            }
            return true;
        }

        if (@intFromPtr(end) > @intFromPtr(p) and (end - 1)[0] == '\\') {
            // Escaped quote: remove one level of escaping and keep
            // searching for our closing quote.
            _ = memmove(end - 1, end, strlen(end));
            end[strlen(end) - 1] = 0;
            search_start = end;
            continue;
        }

        if (!push_argv(argv, &argv_size, p, @intFromPtr(end) - @intFromPtr(p), &idx))
            return fail(argv, idx);

        p = end + 1;
        while (p[0] == delim)
            p += 1;

        while (p[0] == ' ')
            p += 1;

        if (p[0] == '"' or p[0] == '\'') {
            delim = p[0];
            p += 1;
        } else {
            delim = ' ';
        }
        search_start = p;
    }

    if (!push_argv(argv, &argv_size, null, 0, &idx))
        return fail(argv, idx);

    return true;
}
