// The config parser (Phase 2, chunks C2a-C2g).
//
// This file owns the section tables, key/value tokenizing, include handling,
// the override loop and the option handlers that have been ported. config.c
// still owns the key-binding sections ([url], [regex], the four *-bindings)
// and the C binding tables, which the ported loop reaches through externs.
//
// The C versions were kept only as thin wrappers; `tests/test-config.c`
// (#include "../config.c") is the oracle for the behaviour below, so every
// libc call is kept deliberately — strtoul/strtof/strtok/sscanf semantics
// ("0x10", "  5x6", leading whitespace, truncation) are part of the contract
// and re-implementing them by hand would only introduce drift.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("terminal_types.zig");

const Context = types.ConfigContext;

// ── libc ───────────────────────────────────────────────────────────
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn strlen(s: [*:0]const u8) callconv(.c) usize;
extern fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int;
extern fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int;
extern fn strtoul(s: [*:0]const u8, end: ?*?[*:0]u8, base: c_int) callconv(.c) c_ulong;
extern fn strtol(s: [*:0]const u8, end: ?*?[*:0]u8, base: c_int) callconv(.c) c_long;
extern fn strtof(s: [*:0]const u8, end: ?*?[*:0]u8) callconv(.c) f32;
extern fn sscanf(s: [*:0]const u8, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn strtok(s: ?[*:0]u8, delim: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn __errno_location() callconv(.c) *c_int;
extern fn ambstoc32(s: [*:0]const u8) callconv(.c) ?[*]u32;

// config.c
extern fn tokenize_cmdline(cmdline: [*:0]const u8, argv: *?[*:null]?[*:0]u8) callconv(.c) bool;
extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn log_contextual(
    ctx: *Context,
    class: c_int,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;

// ── LOG_CONTEXTUAL_ERR() / _WARN() ────────────────────────────────
//
// The C macro is variadic; rather than pass varargs across the ABI, format
// here and hand log_contextual() a "%s".

fn logCtx(ctx: *Context, class: c_int, file: [*:0]const u8, line: u32, msg: [*:0]const u8) void {
    log_contextual(ctx, class, file, @intCast(line), "%s", msg);
}

// `src` is threaded through explicitly: the C original logs the line of the
// LOG_CONTEXTUAL_ERR() macro expansion, and `@src()` inside a helper would
// report the helper instead.
fn contextualErr(
    ctx: *Context,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [1024]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, fmt, args) catch "invalid value";
    logCtx(ctx, LOG_CLASS_ERROR, src.file, src.line, msg.ptr);
}

fn errValue(
    ctx: *Context,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) bool {
    contextualErr(ctx, src, fmt, args);
    return false;
}

// ── integers ──────────────────────────────────────────────────────

/// Also used by config.c (parse_color_theme() indexes the palette with it).
export fn str_to_ulong(s: ?[*:0]const u8, base: c_int, res: *c_ulong) callconv(.c) bool {
    const str = s orelse return false;

    __errno_location().* = 0;
    var end: ?[*:0]u8 = null;

    const v = strtoul(str, &end, base);
    if (!(__errno_location().* == 0 and end != null and end.?[0] == 0))
        return false;

    res.* = v;
    return true;
}

fn strToUint32(s: ?[*:0]const u8, base: c_int, res: *u32) bool {
    var v: c_ulong = 0;
    if (!str_to_ulong(s, base, &v))
        return false;
    if (v > std.math.maxInt(u32))
        return false;
    res.* = @intCast(v);
    return true;
}

fn strToUint16(s: ?[*:0]const u8, base: c_int, res: *u16) bool {
    var v: c_ulong = 0;
    if (!str_to_ulong(s, base, &v))
        return false;
    if (v > std.math.maxInt(u16))
        return false;
    res.* = @intCast(v);
    return true;
}

export fn value_to_uint16(ctx: *Context, base: c_int, res: *u16) callconv(.c) bool {
    if (!strToUint16(ctx.value, base, res))
        return errValue(ctx, @src(), "invalid integer value, or outside range 0-{d}", .{std.math.maxInt(u16)});
    return true;
}

export fn value_to_uint32(ctx: *Context, base: c_int, res: *u32) callconv(.c) bool {
    if (!strToUint32(ctx.value, base, res))
        return errValue(ctx, @src(), "invalid integer value, or outside range 0-{d}", .{std.math.maxInt(u32)});
    return true;
}

export fn value_to_bool(ctx: *Context, res: *bool) callconv(.c) bool {
    const yes = [_][*:0]const u8{ "on", "true", "yes", "1" };
    const no = [_][*:0]const u8{ "off", "false", "no", "0" };

    const value = ctx.value orelse return errValue(ctx, @src(), "invalid boolean value", .{});

    for (yes) |candidate| {
        if (strcasecmp(value, candidate) == 0) {
            res.* = true;
            return true;
        }
    }

    for (no) |candidate| {
        if (strcasecmp(value, candidate) == 0) {
            res.* = false;
            return true;
        }
    }

    return errValue(ctx, @src(), "invalid boolean value", .{});
}

export fn value_to_dimensions(ctx: *Context, x: *u32, y: *u32) callconv(.c) bool {
    const value = ctx.value orelse return errValue(ctx, @src(), "invalid dimensions (must be in the form AxB)", .{});

    // sscanf(), like the C version: " 5x6" is valid and trailing garbage is
    // ignored (only the two conversions matter).
    if (sscanf(value, "%ux%u", x, y) != 2)
        return errValue(ctx, @src(), "invalid dimensions (must be in the form AxB)", .{});

    return true;
}

export fn value_to_float(ctx: *Context, res: *f32) callconv(.c) bool {
    const s = ctx.value orelse return false;

    __errno_location().* = 0;
    var end: ?[*:0]u8 = null;

    const v = strtof(s, &end);
    if (!(__errno_location().* == 0 and end != null and end.?[0] == 0))
        return errValue(ctx, @src(), "invalid decimal value", .{});

    res.* = v;
    return true;
}

// ── strings ───────────────────────────────────────────────────────

export fn value_to_str(ctx: *Context, res: *?[*:0]u8) callconv(.c) bool {
    const copy = xstrdup(ctx.value orelse "") orelse return false;
    const len = std.mem.len(copy);

    // Un-quote. Only the *entire* value may be quoted, and only the current
    // quote character (or a backslash) may be escaped inside it.
    if (len > 0 and
        ((copy[0] == '"' and copy[len - 1] == '"') or
        (copy[0] == '\'' and copy[len - 1] == '\'')))
    {
        const quote = copy[0];

        copy[len - 1] = 0;
        // memmove(copy, copy + 1, len - 1): drop the opening quote, keeping
        // the NUL that now lives at len - 1.
        std.mem.copyForwards(u8, copy[0 .. len - 1], copy[1..len]);

        var i: usize = 0;
        while (copy[i] != 0) : (i += 1) {
            if (copy[i] == '\\' and (copy[i + 1] == '\\' or copy[i + 1] == quote)) {
                // memmove(p, p + 1, end - p)
                const rest = (len - 1) - i;
                std.mem.copyForwards(
                    u8,
                    copy[i .. i + rest],
                    copy[i + 1 .. i + 1 + rest],
                );
            }
        }
    }

    if (res.*) |old|
        free(@ptrCast(old));
    res.* = copy;
    return true;
}

export fn value_to_wchars(ctx: *Context, res: *?[*]u32) callconv(.c) bool {
    const value = ctx.value orelse return errValue(ctx, @src(), "not a valid string value", .{});

    const s = ambstoc32(value) orelse return errValue(ctx, @src(), "not a valid string value", .{});

    if (res.*) |old|
        free(@ptrCast(old));
    res.* = s;
    return true;
}

export fn value_to_enum(
    ctx: *Context,
    value_map: [*]const ?[*:0]const u8,
    res: *c_int,
) callconv(.c) bool {
    const value = ctx.value orelse return false;

    var str_len: usize = 0;
    var count: usize = 0;

    while (value_map[count]) |entry| : (count += 1) {
        if (strcasecmp(entry, value) == 0) {
            res.* = @intCast(count);
            return true;
        }
        str_len += std.mem.len(entry);
    }

    // Build the "'a', 'b'" list for the error message. The C version
    // xassert()s that it fits in 512 bytes; here an over-long list just gets
    // truncated (it's a diagnostic).
    var valid_values: [512]u8 = undefined;
    var idx: usize = 0;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const piece = std.fmt.bufPrint(
            valid_values[idx..],
            "'{s}', ",
            .{std.mem.span(value_map[i].?)},
        ) catch break;
        idx += piece.len;
    }

    if (count > 0 and idx >= 2)
        idx -= 2;
    valid_values[idx] = 0;

    contextualErr(ctx, @src(), "not one of {s}", .{valid_values[0..idx]});
    return false;
}

// ── colours ───────────────────────────────────────────────────────

export fn value_to_color(ctx: *Context, result: *u32, allow_alpha: bool) callconv(.c) bool {
    const value = ctx.value orelse return false;

    const len = std.mem.len(value);
    const component_count = len / 2;

    var color: u32 = undefined;
    if (!(len == 6 or (allow_alpha and len == 8)) or
        !strToUint32(value, 16, &color))
    {
        if (allow_alpha)
            return errValue(ctx, @src(), "color must be in either RGB or ARGB format", .{});
        return errValue(ctx, @src(), "color must be in RGB format", .{});
    }

    if (allow_alpha and component_count == 3) {
        // No alpha component given: assume non-transparency
        color |= 0xff000000;
    }

    result.* = color;
    return true;
}

export fn value_to_two_colors(
    ctx: *Context,
    first: *u32,
    second: *u32,
    allow_alpha: bool,
) callconv(.c) bool {
    const original_value = ctx.value;

    // TODO: do this without strdup()
    const value_copy = xstrdup(ctx.value orelse "") orelse return false;
    defer {
        free(@ptrCast(value_copy));
        ctx.value = original_value;
    }

    // strtok() splits on spaces, skipping runs of them; keeps C's exact
    // behaviour for "  a  b  ".
    const first_as_str = strtok(value_copy, " ");
    const second_as_str = strtok(null, " ");

    if (first_as_str == null or second_as_str == null)
        return errValue(ctx, @src(), "invalid double color value", .{});

    var a: u32 = undefined;
    ctx.value = first_as_str;
    if (!value_to_color(ctx, &a, allow_alpha))
        return false;

    var b: u32 = undefined;
    ctx.value = second_as_str;
    if (!value_to_color(ctx, &b, allow_alpha))
        return false;

    first.* = a;
    second.* = b;
    return true;
}

// ── pt/px ─────────────────────────────────────────────────────────

export fn value_to_pt_or_px(ctx: *Context, res: *types.PtOrPx) callconv(.c) bool {
    const s = ctx.value;
    const len = if (s) |v| std.mem.len(v) else 0;

    if (len >= 2 and s.?[len - 2] == 'p' and s.?[len - 1] == 'x') {
        __errno_location().* = 0;
        var end: ?[*:0]u8 = null;

        const value = strtol(s.?, &end, 10);
        if (!(len > 2 and __errno_location().* == 0 and end == s.? + len - 2))
            return errValue(ctx, @src(), "invalid px value (must be in the form 12px)", .{});

        res.pt = 0;
        res.px = @truncate(value);
    } else {
        var value: f32 = undefined;
        if (!value_to_float(ctx, &value))
            return false;
        res.pt = value;
        res.px = 0;
    }

    return true;
}

// ── command lines ─────────────────────────────────────────────────

export fn free_argv(argv: *types.Argv) callconv(.c) void {
    const args = argv.args orelse return;

    var i: usize = 0;
    while (args[i]) |arg| : (i += 1)
        free(@ptrCast(arg));
    free(@ptrCast(args));

    argv.args = null;
}

export fn clone_argv(dst: *types.Argv, src: *const types.Argv) callconv(.c) void {
    const src_args = src.args orelse {
        dst.args = null;
        return;
    };

    var count: usize = 0;
    while (src_args[count] != null) : (count += 1) {}

    const args: [*]?[*:0]u8 = @ptrCast(@alignCast(
        xmalloc((count + 1) * @sizeOf(?[*:0]u8)) orelse unreachable,
    ));

    var i: usize = 0;
    while (i < count) : (i += 1)
        args[i] = xstrdup(src_args[i].?);
    args[count] = null;

    dst.args = @ptrCast(args);
}

export fn spawn_template_free(template: *types.ConfigSpawnTemplate) callconv(.c) void {
    free_argv(&template.argv);
}

export fn spawn_template_clone(
    dst: *types.ConfigSpawnTemplate,
    src: *const types.ConfigSpawnTemplate,
) callconv(.c) void {
    clone_argv(&dst.argv, &src.argv);
}

export fn value_to_spawn_template(
    ctx: *Context,
    template: *types.ConfigSpawnTemplate,
) callconv(.c) bool {
    spawn_template_free(template);

    const value = ctx.value orelse return false;

    // The empty command: `command=""` clears a previously configured one.
    if (value[0] == '"' and value[1] == '"' and value[2] == 0) {
        template.argv.args = null;
        return true;
    }

    var argv: ?[*:null]?[*:0]u8 = null;
    if (!tokenize_cmdline(value, &argv))
        return errValue(ctx, @src(), "syntax error in command line", .{});

    template.argv.args = argv;
    return true;
}


// ── section parsers (C2b) ─────────────────────────────────────────
//
// Each `[section]` in foot.ini ends up here. The dispatch table that maps
// section names to these functions is still in config.c; the table just
// takes their addresses.

fn eq(a: ?[*:0]const u8, b: []const u8) bool {
    const s = a orelse return false;
    return std.mem.eql(u8, std.mem.span(s), b);
}

fn eqPtr(a: ?[*:0]const u8, b: ?[*:0]const u8) bool {
    const lhs = a orelse return false;
    const rhs = b orelse return false;
    return strcmp(lhs, rhs) == 0;
}

fn invalidOption(ctx: *Context, key: [*:0]const u8) bool {
    return errValue(ctx, @src(), "not a valid option: {s}", .{std.mem.span(key)});
}

/// NULL-terminated `const char *[]` for value_to_enum(), built at compile
/// time.
fn valueMap(comptime names: []const [:0]const u8) [*]const ?[*:0]const u8 {
    const Table = struct {
        const arr = blk: {
            var a: [names.len + 1]?[*:0]const u8 = undefined;
            for (names, 0..) |name, i|
                a[i] = name.ptr;
            a[names.len] = null;
            break :blk a;
        };
    };
    return &Table.arr;
}

export fn parse_section_security(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "osc52")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "disabled", "copy-enabled", "paste-enabled", "enabled" }),
            @ptrCast(&conf.security.osc52),
        );
    }

    return invalidOption(ctx, key);
}

export fn parse_section_bell(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "urgent"))
        return value_to_bool(ctx, &conf.bell.urgent);
    if (eq(key, "notify"))
        return value_to_bool(ctx, &conf.bell.notify);
    if (eq(key, "system"))
        return value_to_bool(ctx, &conf.bell.system_bell);
    if (eq(key, "visual"))
        return value_to_bool(ctx, &conf.bell.flash);
    if (eq(key, "command"))
        return value_to_spawn_template(ctx, &conf.bell.command);
    if (eq(key, "command-focused"))
        return value_to_bool(ctx, &conf.bell.command_focused);

    return invalidOption(ctx, key);
}

export fn parse_section_desktop_notifications(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "command"))
        return value_to_spawn_template(ctx, &conf.desktop_notifications.command);
    if (eq(key, "command-action-argument"))
        return value_to_spawn_template(ctx, &conf.desktop_notifications.command_action_arg);
    if (eq(key, "close"))
        return value_to_spawn_template(ctx, &conf.desktop_notifications.close);
    if (eq(key, "inhibit-when-focused"))
        return value_to_bool(ctx, &conf.desktop_notifications.inhibit_when_focused);

    return invalidOption(ctx, key);
}

export fn parse_section_scrollback(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "lines"))
        return value_to_uint32(ctx, 10, &conf.scrollback.lines);

    if (eq(key, "indicator-position")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "none", "fixed", "relative" }),
            @ptrCast(&conf.scrollback.indicator.position),
        );
    }

    if (eq(key, "indicator-format")) {
        if (eq(ctx.value, "percentage")) {
            conf.scrollback.indicator.format = .percentage;
            return true;
        }
        if (eq(ctx.value, "line")) {
            conf.scrollback.indicator.format = .lineno;
            return true;
        }
        return value_to_wchars(ctx, &conf.scrollback.indicator.text);
    }

    if (eq(key, "multiplier"))
        return value_to_float(ctx, &conf.scrollback.multiplier);

    return invalidOption(ctx, key);
}

export fn parse_section_cursor(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "style")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "block", "underline", "beam", "hollow" }),
            @ptrCast(&conf.cursor.style),
        );
    }

    if (eq(key, "unfocused-style")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "unchanged", "hollow", "none" }),
            @ptrCast(&conf.cursor.unfocused_style),
        );
    }

    if (eq(key, "blink"))
        return value_to_bool(ctx, &conf.cursor.blink.enabled);
    if (eq(key, "blink-rate"))
        return value_to_uint32(ctx, 10, &conf.cursor.blink.rate_ms);
    if (eq(key, "beam-thickness"))
        return value_to_pt_or_px(ctx, &conf.cursor.beam_thickness);
    if (eq(key, "underline-thickness"))
        return value_to_pt_or_px(ctx, &conf.cursor.underline_thickness);

    return invalidOption(ctx, key);
}

export fn parse_section_mouse(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "hide-when-typing"))
        return value_to_bool(ctx, &conf.mouse.hide_when_typing);
    if (eq(key, "alternate-scroll-mode"))
        return value_to_bool(ctx, &conf.mouse.alternate_scroll_mode);

    return invalidOption(ctx, key);
}

export fn parse_section_touch(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "long-press-delay"))
        return value_to_uint32(ctx, 10, &conf.touch.long_press_delay);

    return invalidOption(ctx, key);
}

export fn parse_section_environment(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    // Pre-existing variable: overwrite its value in place.
    var it = conf.env_vars.head;
    while (it) |node| : (it = node.next) {
        if (eqPtr(node.item.name, key))
            return value_to_str(ctx, &node.item.value);
    }

    var value: ?[*:0]u8 = null;
    if (!value_to_str(ctx, &value))
        return false;

    // tll_push_back(conf->env_vars, ((struct env_var){xstrdup(key), value}))
    const node: *types.EnvVarNode = @ptrCast(@alignCast(
        xmalloc(@sizeOf(types.EnvVarNode)) orelse unreachable,
    ));
    node.item = .{ .name = xstrdup(key), .value = value };
    node.prev = conf.env_vars.tail;
    node.next = null;

    if (conf.env_vars.tail) |tail|
        tail.next = node
    else
        conf.env_vars.head = node;
    conf.env_vars.tail = node;
    conf.env_vars.length += 1;

    return true;
}

// ── [url] and [regex] (C2h) ───────────────────────────────────────

// regex_t is libc-private (glibc and musl disagree on its layout), so the
// Zig side keeps it opaque and lets config.c compile/validate it.
extern fn regfree(preg: *anyopaque) callconv(.c) void;
extern fn config_regex_compile(
    regex: [*:0]const u8,
    preg: *anyopaque,
    err_buf: [*]u8,
    err_buf_len: usize,
) callconv(.c) c_int;

/// Mirrors regcomp() + the re_nsub check + regerror() in the C original.
/// Returns false (and logs the same message) on failure.
fn compileRegex(
    ctx: *Context,
    src: std.builtin.SourceLocation,
    regex: [*:0]const u8,
    preg: *anyopaque,
) bool {
    var err_buf: [128]u8 = undefined;

    switch (config_regex_compile(regex, preg, &err_buf, err_buf.len)) {
        0 => return true,
        -2 => return errValue(ctx, src, "invalid regex: no marked subexpression(s)", .{}),
        else => return errValue(
            ctx,
            src,
            "invalid regex: {s}",
            .{std.mem.sliceTo(&err_buf, 0)},
        ),
    }
}

fn findCustomRegex(conf: *types.Config, name: [*:0]const u8) ?*types.CustomRegex {
    var it = conf.custom_regexes.head;
    while (it) |node| : (it = node.next) {
        if (eqPtr(node.item.name, name))
            return &node.item;
    }
    return null;
}

/// tll_push_back(conf->custom_regexes, (struct custom_regex){.name = ...})
fn pushCustomRegex(conf: *types.Config, name: [*:0]const u8) *types.CustomRegex {
    const node: *types.CustomRegexNode = @ptrCast(@alignCast(
        xmalloc(@sizeOf(types.CustomRegexNode)) orelse unreachable,
    ));
    node.item = .{
        .name = xstrdup(name),
        .regex = null,
        .preg = std.mem.zeroes(types.RegexT),
        .launch = .{ .argv = .{ .args = null } },
    };
    node.prev = conf.custom_regexes.tail;
    node.next = null;

    if (conf.custom_regexes.tail) |tail|
        tail.next = node
    else
        conf.custom_regexes.head = node;
    conf.custom_regexes.tail = node;
    conf.custom_regexes.length += 1;

    return &node.item;
}

export fn parse_section_url(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "launch"))
        return value_to_spawn_template(ctx, &conf.url.launch)
    else if (eq(key, "label-letters"))
        return value_to_wchars(ctx, &conf.url.label_letters)
    else if (eq(key, "style"))
        return value_to_enum(
            ctx,
            valueMap(&.{ "none", "single", "double", "curly", "dotted", "dashed" }),
            @ptrCast(&conf.url.style),
        )
    else if (eq(key, "osc8-underline"))
        return value_to_enum(
            ctx,
            valueMap(&.{ "url-mode", "always" }),
            @ptrCast(&conf.url.osc8_underline),
        )
    else if (eq(key, "regex")) {
        const regex = ctx.value orelse return false;

        // Compile into a local first: a failed regex must leave the
        // currently active one untouched.
        var new_preg: types.RegexT align(16) = undefined;
        if (!compileRegex(ctx, @src(), regex, @ptrCast(&new_preg)))
            return false;

        regfree(@ptrCast(&conf.url.preg));
        free(conf.url.regex);
        conf.url.regex = xstrdup(regex);
        conf.url.preg = new_preg;
        return true;
    }

    return invalidOption(ctx, key);
}

export fn parse_section_regex(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;
    const regex_name: [*:0]const u8 = ctx.section_suffix orelse "";

    var regex = findCustomRegex(conf, regex_name);

    if (eq(key, "regex")) {
        const regex_string = ctx.value orelse return false;

        var new_preg: types.RegexT align(16) = undefined;
        if (!compileRegex(ctx, @src(), regex_string, @ptrCast(&new_preg)))
            return false;

        if (regex == null)
            regex = pushCustomRegex(conf, regex_name);

        const r = regex.?;
        regfree(@ptrCast(&r.preg));
        free(r.regex);
        r.regex = xstrdup(regex_string);
        r.preg = new_preg;
        return true;
    } else if (eq(key, "launch")) {
        var launch: types.ConfigSpawnTemplate = .{ .argv = .{ .args = null } };
        if (!value_to_spawn_template(ctx, &launch))
            return false;

        if (regex == null)
            regex = pushCustomRegex(conf, regex_name);

        const r = regex.?;
        spawn_template_free(&r.launch);
        r.launch = launch;
        return true;
    }

    return invalidOption(ctx, key);
}

// ── [colors] and [csd] (C2c) ──────────────────────────────────────

extern fn value_to_fonts(ctx: *Context) callconv(.c) types.ConfigFontList;
extern fn config_font_list_destroy(list: *types.ConfigFontList) callconv(.c) void;
extern fn log_and_notify_errno(
    conf: *types.Config,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn getline(
    lineptr: *?[*]u8,
    n: *usize,
    stream: *anyopaque,
) callconv(.c) isize;
extern fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]u8;
extern fn log_contextual_errno(
    ctx: *Context,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void;
extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn fclose(f: *anyopaque) callconv(.c) c_int;


export fn parse_color_theme(ctx: *Context, theme: *types.ColorTheme) callconv(.c) bool {
    const key = ctx.key orelse return true;
    const k = std.mem.span(key);
    const key_len = k.len;

    if (key_len == 0)
        return invalidOption(ctx, key);

    const last_byte = k[key_len - 1];
    const last_digit: u8 = if (std.ascii.isDigit(last_byte)) last_byte - '0' else 0xff;

    var color: ?*u32 = null;

    if (std.ascii.isDigit(k[0])) {
        var index: c_ulong = 0;
        if (!str_to_ulong(key, 0, &index) or index >= theme.table.len) {
            contextualErr(
                ctx,
                @src(),
                "invalid color palette index: {s} (not in range 0-{d})",
                .{ k, theme.table.len },
            );
            return false;
        }
        color = &theme.table[@intCast(index)];
    } else if (key_len == 8 and std.mem.startsWith(u8, k, "regular") and last_digit < 8) {
        color = &theme.table[last_digit];
    } else if (key_len == 7 and std.mem.startsWith(u8, k, "bright") and last_digit < 8) {
        color = &theme.table[8 + last_digit];
    } else if (key_len == 4 and std.mem.startsWith(u8, k, "dim") and last_digit < 8) {
        if (!value_to_color(ctx, &theme.dim[last_digit], false))
            return false;

        theme.use_custom.dim |= @as(u8, 1) << @intCast(last_digit);
        return true;
    } else if (std.mem.startsWith(u8, k, "sixel") and
        ((key_len == 6 and last_digit < 10) or
        (key_len == 7 and k[5] == '1' and last_digit < 6)))
    {
        const idx: usize = if (key_len == 6) last_digit else 10 + last_digit;
        return value_to_color(ctx, &theme.sixel[idx], false);
    } else if (eq(key, "flash")) {
        color = &theme.flash;
    } else if (eq(key, "foreground")) {
        color = &theme.fg;
    } else if (eq(key, "background")) {
        color = &theme.bg;
    } else if (eq(key, "selection-foreground")) {
        color = &theme.selection_fg;
    } else if (eq(key, "selection-background")) {
        color = &theme.selection_bg;
    } else if (eq(key, "jump-labels")) {
        if (!value_to_two_colors(ctx, &theme.jump_label.fg, &theme.jump_label.bg, false))
            return false;

        theme.use_custom.jump_label = true;
        return true;
    } else if (eq(key, "scrollback-indicator")) {
        if (!value_to_two_colors(
            ctx,
            &theme.scrollback_indicator.fg,
            &theme.scrollback_indicator.bg,
            false,
        )) return false;

        theme.use_custom.scrollback_indicator = true;
        return true;
    } else if (eq(key, "search-box-no-match")) {
        if (!value_to_two_colors(
            ctx,
            &theme.search_box.no_match.fg,
            &theme.search_box.no_match.bg,
            false,
        )) return false;

        theme.use_custom.search_box_no_match = true;
        return true;
    } else if (eq(key, "search-box-match")) {
        if (!value_to_two_colors(
            ctx,
            &theme.search_box.match.fg,
            &theme.search_box.match.bg,
            false,
        )) return false;

        theme.use_custom.search_box_match = true;
        return true;
    } else if (eq(key, "cursor")) {
        if (!value_to_two_colors(ctx, &theme.cursor.text, &theme.cursor.cursor, false))
            return false;

        theme.use_custom.cursor = true;
        return true;
    } else if (eq(key, "urls")) {
        if (!value_to_color(ctx, &theme.url, false))
            return false;

        theme.use_custom.url = true;
        return true;
    } else if (eq(key, "alpha")) {
        var alpha: f32 = undefined;
        if (!value_to_float(ctx, &alpha))
            return false;

        if (alpha < 0.0 or alpha > 1.0)
            return errValue(ctx, @src(), "not in range 0.0-1.0", .{});

        theme.alpha = @intFromFloat(alpha * 65535.0);
        return true;
    } else if (eq(key, "flash-alpha")) {
        var alpha: f32 = undefined;
        if (!value_to_float(ctx, &alpha))
            return false;

        if (alpha < 0.0 or alpha > 1.0)
            return errValue(ctx, @src(), "not in range 0.0-1.0", .{});

        theme.flash_alpha = @intFromFloat(alpha * 65535.0);
        return true;
    } else if (eq(key, "alpha-mode")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "default", "matching", "all" }),
            @ptrCast(&theme.alpha_mode),
        );
    } else if (eq(key, "dim-blend-towards")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "black", "white" }),
            @ptrCast(&theme.dim_blend_towards),
        );
    } else if (eq(key, "blur")) {
        return value_to_bool(ctx, &theme.blur);
    } else {
        return invalidOption(ctx, key);
    }

    var color_value: u32 = undefined;
    if (!value_to_color(ctx, &color_value, false))
        return false;

    (color orelse unreachable).* = color_value;
    return true;
}

export fn parse_section_colors_dark(ctx: *Context) callconv(.c) bool {
    return parse_color_theme(ctx, &ctx.conf.?.colors_dark);
}

export fn parse_section_colors_light(ctx: *Context) callconv(.c) bool {
    return parse_color_theme(ctx, &ctx.conf.?.colors_light);
}

export fn parse_section_csd(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "preferred")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "none", "server", "client" }),
            @ptrCast(&conf.csd.preferred),
        );
    }

    if (eq(key, "font")) {
        const new_list = value_to_fonts(ctx);
        if (new_list.arr == null)
            return false;

        config_font_list_destroy(&conf.csd.font);
        conf.csd.font = new_list;
        return true;
    }

    if (eq(key, "color")) {
        var color: u32 = undefined;
        if (!value_to_color(ctx, &color, true))
            return false;

        conf.csd.color._flags.title_set = true;
        conf.csd.color.title = color;
        return true;
    }

    if (eq(key, "size"))
        return value_to_uint16(ctx, 10, &conf.csd.title_height);
    if (eq(key, "button-width"))
        return value_to_uint16(ctx, 10, &conf.csd.button_width);

    if (eq(key, "button-color")) {
        if (!value_to_color(ctx, &conf.csd.color.buttons, true))
            return false;
        conf.csd.color._flags.buttons_set = true;
        return true;
    }

    if (eq(key, "button-minimize-color")) {
        if (!value_to_color(ctx, &conf.csd.color.minimize, true))
            return false;
        conf.csd.color._flags.minimize_set = true;
        return true;
    }

    if (eq(key, "button-maximize-color")) {
        if (!value_to_color(ctx, &conf.csd.color.maximize, true))
            return false;
        conf.csd.color._flags.maximize_set = true;
        return true;
    }

    if (eq(key, "button-close-color")) {
        if (!value_to_color(ctx, &conf.csd.color.quit, true))
            return false;
        conf.csd.color._flags.close_set = true;
        return true;
    }

    if (eq(key, "border-color")) {
        if (!value_to_color(ctx, &conf.csd.color.border, true))
            return false;
        conf.csd.color._flags.border_set = true;
        return true;
    }

    if (eq(key, "border-width"))
        return value_to_uint16(ctx, 10, &conf.csd.border_width_visible);
    if (eq(key, "hide-when-maximized"))
        return value_to_bool(ctx, &conf.csd.hide_when_maximized);
    if (eq(key, "double-click-to-maximize"))
        return value_to_bool(ctx, &conf.csd.double_click_to_maximize);

    return errValue(ctx, @src(), "not a valid action: {s}", .{std.mem.span(key)});
}

// ── [tweak] (C2d) ─────────────────────────────────────────────────

fn logWarn(src: std.builtin.SourceLocation, msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_WARNING, "config", src.file, @intCast(src.line), "%s", msg);
}

export fn parse_section_tweak(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;

    if (eq(key, "scaling-filter")) {
        // Index order matters: value_to_enum() stores the index, and the C
        // table is designated-initialised by `enum fcft_scaling_filter`
        // (NONE, NEAREST, BILINEAR, CUBIC, LANCZOS3, IMPULSE, BOX, LINEAR,
        // GAUSSIAN, LANCZOS2, LANCZOS3_STRETCHED) — not the textual order
        // in which config.c happens to write the entries.
        return value_to_enum(
            ctx,
            valueMap(&.{
                "none",     "nearest",  "bilinear", "cubic",
                "lanczos3", "impulse",  "box",      "linear",
                "gaussian", "lanczos2", "lanczos3-stretched",
            }),
            @ptrCast(&conf.tweak.fcft_filter),
        );
    }

    if (eq(key, "overflowing-glyphs"))
        return value_to_bool(ctx, &conf.tweak.overflowing_glyphs);
    if (eq(key, "damage-whole-window"))
        return value_to_bool(ctx, &conf.tweak.damage_whole_window);

    if (eq(key, "grapheme-shaping")) {
        if (!value_to_bool(ctx, &conf.tweak.grapheme_shaping))
            return false;

        if (comptime !build_options.grapheme_clustering) {
            if (conf.tweak.grapheme_shaping) {
                logWarn(@src(), "foot was not compiled with support for grapheme shaping");
                conf.tweak.grapheme_shaping = false;
            }
        }

        if (conf.tweak.grapheme_shaping and !conf.can_shape_grapheme) {
            // Keep it enabled: it still makes us do grapheme clustering.
            logWarn(@src(), "fcft was not compiled with support for grapheme shaping");
        }

        return true;
    }

    if (eq(key, "grapheme-width-method")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "wcswidth", "double-width", "max" }),
            @ptrCast(&conf.tweak.grapheme_width_method),
        );
    }

    if (eq(key, "render-timer")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "none", "osd", "log", "both" }),
            @ptrCast(&conf.tweak.render_timer),
        );
    }

    if (eq(key, "delayed-render-lower") or eq(key, "delayed-render-upper")) {
        var ns: u32 = undefined;
        if (!value_to_uint32(ctx, 10, &ns))
            return false;

        if (ns > 16666666)
            return errValue(ctx, @src(), "timeout must not exceed 16ms", .{});

        if (eq(key, "delayed-render-lower"))
            conf.tweak.delayed_render_lower_ns = ns
        else
            conf.tweak.delayed_render_upper_ns = ns;
        return true;
    }

    if (eq(key, "max-shm-pool-size-mb")) {
        var mb: u32 = undefined;
        if (!value_to_uint32(ctx, 10, &mb))
            return false;

        // C: min((int32_t)mb * 1024 * 1024, INT32_MAX) — the multiply wraps
        // in `int`, then widens to off_t.
        const bytes = @as(i32, @bitCast(mb)) *% 1024 *% 1024;
        conf.tweak.max_shm_pool_size = @as(i64, @min(bytes, std.math.maxInt(i32)));
        return true;
    }

    if (eq(key, "box-drawing-base-thickness"))
        return value_to_float(ctx, &conf.tweak.box_drawing_base_thickness);
    if (eq(key, "box-drawing-solid-shades"))
        return value_to_bool(ctx, &conf.tweak.box_drawing_solid_shades);
    if (eq(key, "font-monospace-warn"))
        return value_to_bool(ctx, &conf.tweak.font_monospace_warn);
    if (eq(key, "sixel"))
        return value_to_bool(ctx, &conf.tweak.sixel);
    if (eq(key, "dim-amount"))
        return value_to_float(ctx, &conf.dim.amount);
    if (eq(key, "bold-text-in-bright-amount"))
        return value_to_float(ctx, &conf.bold_in_bright.amount);

    if (eq(key, "surface-bit-depth")) {
        if (comptime build_options.pixman_rgba_16) {
            return value_to_enum(
                ctx,
                valueMap(&.{ "auto", "8-bit", "10-bit", "16-bit" }),
                @ptrCast(&conf.tweak.surface_bit_depth),
            );
        } else {
            return value_to_enum(
                ctx,
                valueMap(&.{ "auto", "8-bit", "10-bit" }),
                @ptrCast(&conf.tweak.surface_bit_depth),
            );
        }
    }

    if (eq(key, "min-stride-alignment"))
        return value_to_uint32(ctx, 10, &conf.tweak.min_stride_alignment);
    if (eq(key, "pre-apply-damage"))
        return value_to_bool(ctx, &conf.tweak.preapply_damage);

    return invalidOption(ctx, key);
}

// ── [main] (C2e) ──────────────────────────────────────────────────

fn logInfo(src: std.builtin.SourceLocation, msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_INFO, "config", src.file, @intCast(src.line), "%s", msg);
}

fn logInfoFmt(src: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    logInfo(src, msg.ptr);
}

/// LOG_CONTEXTUAL_ERRNO(): like contextualErr(), plus strerror(errno).
fn errValueErrno(
    ctx: *Context,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) bool {
    var buf: [1024]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, fmt, args) catch "invalid value";
    log_contextual_errno(ctx, src.file, @intCast(src.line), "%s", msg.ptr);
    return false;
}

fn strJoin3(a: [*:0]const u8, b: [*:0]const u8, c: [*:0]const u8) ?[*:0]u8 {
    const s1 = std.mem.span(a);
    const s2 = std.mem.span(b);
    const s3 = std.mem.span(c);

    const len = s1.len + s2.len + s3.len;
    const buf: [*]u8 = @ptrCast(@alignCast(xmalloc(len + 1) orelse return null));

    @memcpy(buf[0..s1.len], s1);
    @memcpy(buf[s1.len .. s1.len + s2.len], s2);
    @memcpy(buf[s1.len + s2.len .. len], s3);
    buf[len] = 0;

    return @ptrCast(buf);
}

fn centerFromMode(mode: [*:0]const u8) types.CenterWhen {
    if (strcasecmp(mode, "center") == 0)
        return .always;
    if (strcasecmp(mode, "center-when-fullscreen") == 0)
        return .fullscreen;
    if (strcasecmp(mode, "center-when-maximized-and-fullscreen") == 0)
        return .maximized_and_fullscreen;
    return .invalid;
}

export fn parse_section_main(ctx: *Context) callconv(.c) bool {
    const conf = ctx.conf.?;
    const key = ctx.key orelse return true;
    const value = ctx.value;

    if (eq(key, "include")) {
        const val = value orelse return false;

        var include_path: ?[*:0]const u8 = null;
        var expanded: ?[*:0]u8 = null;

        if (val[0] == '~' and val[1] == '/') {
            const home_dir = getenv("HOME") orelse
                return errValueErrno(ctx, @src(), "failed to expand '~'", .{});

            // xstrjoin3() is `static inline` in xmalloc.h, so join here.
            expanded = strJoin3(home_dir, "/", val + 2);
            include_path = expanded;
        } else {
            include_path = val;
        }

        const path = include_path.?;

        if (path[0] != '/') {
            const ret = errValue(ctx, @src(), "not an absolute path", .{});
            if (expanded) |p| free(@ptrCast(p));
            return ret;
        }

        const file = fopen(path, "r") orelse {
            const ret = errValueErrno(ctx, @src(), "failed to open", .{});
            if (expanded) |p| free(@ptrCast(p));
            return ret;
        };

        const ret = parse_config_file(file, conf, path, ctx.errors_are_fatal);
        _ = fclose(file);

        logInfoFmt(@src(), "imported sub-configuration from {s}", .{std.mem.span(path)});
        if (expanded) |p| free(@ptrCast(p));
        return ret;
    }

    if (eq(key, "term"))
        return value_to_str(ctx, &conf.term);
    if (eq(key, "shell"))
        return value_to_str(ctx, &conf.shell);
    if (eq(key, "login-shell"))
        return value_to_bool(ctx, &conf.login_shell);
    if (eq(key, "title"))
        return value_to_str(ctx, &conf.title);
    if (eq(key, "locked-title"))
        return value_to_bool(ctx, &conf.locked_title);
    if (eq(key, "app-id"))
        return value_to_str(ctx, &conf.app_id);
    if (eq(key, "toplevel-tag"))
        return value_to_str(ctx, &conf.toplevel_tag);

    if (eq(key, "initial-window-size-pixels")) {
        if (!value_to_dimensions(ctx, &conf.size.width, &conf.size.height))
            return false;

        conf.size.type = .px;
        return true;
    }

    if (eq(key, "initial-window-size-chars")) {
        if (!value_to_dimensions(ctx, &conf.size.width, &conf.size.height))
            return false;

        conf.size.type = .cells;
        return true;
    }

    if (eq(key, "pad")) {
        const val = value orelse return false;

        var x: c_uint = 0;
        var y: c_uint = 0;
        var left: c_uint = 0;
        var top: c_uint = 0;
        var right: c_uint = 0;
        var bottom: c_uint = 0;
        var mode: [64]u8 = [_]u8{0} ** 64;

        var ret = sscanf(val, "%ux%ux%ux%u %63s", &left, &top, &right, &bottom, &mode);
        var center: types.CenterWhen = .never;

        if (ret == 5) {
            center = centerFromMode(@ptrCast(&mode));
        } else if (ret < 4) {
            ret = sscanf(val, "%ux%u %63s", &x, &y, &mode);
            if (ret >= 2) {
                left = x;
                right = x;
                top = y;
                bottom = y;
                if (ret == 3)
                    center = centerFromMode(@ptrCast(&mode));
            }
        }

        if (ret < 2 or ret > 5 or center == .invalid) {
            return errValue(
                ctx,
                @src(),
                "invalid padding (must be in the form RIGHTxTOPxLEFTxBOTTOM or XxY " ++
                    "[center|center-when-fullscreen|center-when-maximized-and-fullscreen])",
                .{},
            );
        }

        conf.pad_left = left;
        conf.pad_top = top;
        conf.pad_right = right;
        conf.pad_bottom = bottom;
        conf.center_when = if (ret == 4 or ret == 2) .never else center;
        return true;
    }

    if (eq(key, "resize-delay-ms"))
        return value_to_uint16(ctx, 10, &conf.resize_delay_ms);
    if (eq(key, "resize-by-cells"))
        return value_to_bool(ctx, &conf.resize_by_cells);
    if (eq(key, "resize-keep-grid"))
        return value_to_bool(ctx, &conf.resize_keep_grid);

    if (eq(key, "bold-text-in-bright")) {
        if (eq(value, "palette-based")) {
            conf.bold_in_bright.enabled = true;
            conf.bold_in_bright.palette_based = true;
        } else {
            if (!value_to_bool(ctx, &conf.bold_in_bright.enabled))
                return false;
            conf.bold_in_bright.palette_based = false;
        }
        return true;
    }

    if (eq(key, "initial-window-mode")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "windowed", "maximized", "fullscreen" }),
            @ptrCast(&conf.startup_mode),
        );
    }

    if (eq(key, "font") or
        eq(key, "font-bold") or
        eq(key, "font-italic") or
        eq(key, "font-bold-italic"))
    {
        const idx: usize =
            if (eq(key, "font")) 0
            else if (eq(key, "font-bold")) 1
            else if (eq(key, "font-italic")) 2
            else 3;

        const new_list = value_to_fonts(ctx);
        if (new_list.arr == null)
            return false;

        config_font_list_destroy(&conf.fonts[idx]);
        conf.fonts[idx] = new_list;
        return true;
    }

    if (eq(key, "font-size-adjustment")) {
        const val = value orelse return false;
        const len = std.mem.len(val);

        if (len >= 1 and val[len - 1] == '%') {
            __errno_location().* = 0;
            var end: ?[*:0]u8 = null;

            const percent = strtof(val, &end);
            if (!(len > 1 and __errno_location().* == 0 and end == val + len - 1))
                return errValue(ctx, @src(), "invalid percent value (must be in the form 10.5%)", .{});

            conf.font_size_adjustment.percent = percent / 100.0;
            conf.font_size_adjustment.pt_or_px.pt = 0;
            conf.font_size_adjustment.pt_or_px.px = 0;
            return true;
        }

        const ok = value_to_pt_or_px(ctx, &conf.font_size_adjustment.pt_or_px);
        if (ok)
            conf.font_size_adjustment.percent = 0.0;
        return ok;
    }

    if (eq(key, "line-height"))
        return value_to_pt_or_px(ctx, &conf.line_height);
    if (eq(key, "letter-spacing"))
        return value_to_pt_or_px(ctx, &conf.letter_spacing);
    if (eq(key, "horizontal-letter-offset"))
        return value_to_pt_or_px(ctx, &conf.horizontal_letter_offset);
    if (eq(key, "vertical-letter-offset"))
        return value_to_pt_or_px(ctx, &conf.vertical_letter_offset);

    if (eq(key, "underline-offset")) {
        if (!value_to_pt_or_px(ctx, &conf.underline_offset))
            return false;
        conf.use_custom_underline_offset = true;
        return true;
    }

    if (eq(key, "underline-thickness"))
        return value_to_pt_or_px(ctx, &conf.underline_thickness);
    if (eq(key, "strikeout-thickness"))
        return value_to_pt_or_px(ctx, &conf.strikeout_thickness);

    if (eq(key, "dpi-aware"))
        return value_to_bool(ctx, &conf.dpi_aware);
    if (eq(key, "workers"))
        return value_to_uint16(ctx, 10, &conf.render_worker_count);
    if (eq(key, "word-delimiters"))
        return value_to_wchars(ctx, &conf.word_delimiters);

    if (eq(key, "selection-target")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "none", "primary", "clipboard", "both" }),
            @ptrCast(&conf.selection_target),
        );
    }

    if (eq(key, "box-drawings-uses-font-glyphs"))
        return value_to_bool(ctx, &conf.box_drawings_uses_font_glyphs);

    if (eq(key, "utmp-helper")) {
        if (!value_to_str(ctx, &conf.utmp_helper_path))
            return false;

        if (eq(conf.utmp_helper_path, "none")) {
            if (conf.utmp_helper_path) |p|
                free(@ptrCast(p));
            conf.utmp_helper_path = null;
        }

        return true;
    }

    if (eq(key, "gamma-correct-blending"))
        return value_to_bool(ctx, &conf.gamma_correct);

    if (eq(key, "initial-color-theme")) {
        return value_to_enum(
            ctx,
            valueMap(&.{ "dark", "light" }),
            @ptrCast(&conf.initial_color_theme),
        );
    }

    if (eq(key, "uppercase-regex-insert"))
        return value_to_bool(ctx, &conf.uppercase_regex_insert);

    return invalidOption(ctx, key);
}

// ── the config file loop (C2f) ────────────────────────────────────
//
// This is the last non-binding piece of the parser: split lines into
// key/value pairs, track the current section, dispatch to the section
// parser. The key-binding sections and [url]/[regex] are still C, and are
// reachable through the table below like any other parser.

const ParserFun = *const fn (*Context) callconv(.c) bool;

const SectionInfo = struct {
    fun: ParserFun,
    name: [:0]const u8,
    allow_colon_suffix: bool = false,
};

extern fn parse_section_key_bindings(ctx: *Context) callconv(.c) bool;
extern fn parse_section_search_bindings(ctx: *Context) callconv(.c) bool;
extern fn parse_section_url_bindings(ctx: *Context) callconv(.c) bool;
extern fn parse_section_mouse_bindings(ctx: *Context) callconv(.c) bool;
extern fn parse_section_text_bindings(ctx: *Context) callconv(.c) bool;

const SECTION_MAIN = 0;
const SECTION_COUNT = 20;

const section_info = [SECTION_COUNT]SectionInfo{
    .{ .fun = &parse_section_main, .name = "main" },
    .{ .fun = &parse_section_security, .name = "security" },
    .{ .fun = &parse_section_bell, .name = "bell" },
    .{ .fun = &parse_section_desktop_notifications, .name = "desktop-notifications" },
    .{ .fun = &parse_section_scrollback, .name = "scrollback" },
    .{ .fun = &parse_section_url, .name = "url" },
    .{ .fun = &parse_section_regex, .name = "regex", .allow_colon_suffix = true },
    .{ .fun = &parse_section_colors_dark, .name = "colors-dark" },
    .{ .fun = &parse_section_colors_light, .name = "colors-light" },
    .{ .fun = &parse_section_cursor, .name = "cursor" },
    .{ .fun = &parse_section_mouse, .name = "mouse" },
    .{ .fun = &parse_section_csd, .name = "csd" },
    .{ .fun = &parse_section_key_bindings, .name = "key-bindings" },
    .{ .fun = &parse_section_search_bindings, .name = "search-bindings" },
    .{ .fun = &parse_section_url_bindings, .name = "url-bindings" },
    .{ .fun = &parse_section_mouse_bindings, .name = "mouse-bindings" },
    .{ .fun = &parse_section_text_bindings, .name = "text-bindings" },
    .{ .fun = &parse_section_environment, .name = "environment" },
    .{ .fun = &parse_section_tweak, .name = "tweak" },
    .{ .fun = &parse_section_touch, .name = "touch" },
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn strToSection(str: [*:0]u8, suffix: *?[*:0]u8) usize {
    suffix.* = null;

    const s = std.mem.span(str);

    for (section_info, 0..) |info, i| {
        if (std.mem.eql(u8, s, info.name))
            return i;

        if (info.allow_colon_suffix) {
            // At least "section:" chars?
            if (s.len > info.name.len + 1 and
                std.mem.startsWith(u8, s, info.name) and
                s[info.name.len] == ':')
            {
                str[info.name.len] = 0;
                suffix.* = @ptrCast(str + info.name.len + 1);
                return i;
            }
        }
    }

    return SECTION_COUNT;
}

/// Splits "key=value" (optionally "section.key=value"). Only the plain form
/// is used by the file loop; the section form is kept because
/// --override=section.key=value goes through it.
fn parseKeyValue(
    kv_in: [*:0]u8,
    section_out: ?*?[*:0]const u8,
    key: *?[*:0]const u8,
    value: *?[*:0]const u8,
) bool {
    var kv: [*]u8 = kv_in;
    var section_is_needed = section_out != null;

    // Strip leading whitespace
    while (isSpace(kv[0]))
        kv += 1;

    if (section_out) |out|
        out.* = "main";

    if (kv[0] == '=')
        return false;

    key.* = @ptrCast(kv);
    value.* = null;

    var kvlen = std.mem.len(@as([*:0]const u8, @ptrCast(kv)));
    if (kvlen == 0)
        return false;

    // Strip trailing whitespace
    while (isSpace(kv[kvlen - 1]))
        kvlen -= 1;
    kv[kvlen] = 0;

    var i: usize = 0;
    while (i < kvlen) : (i += 1) {
        if (kv[i] == '.' and section_is_needed) {
            section_is_needed = false;
            if (section_out) |out|
                out.* = @ptrCast(kv);
            kv[i] = 0;
            if (i == kvlen - 1 or kv[i + 1] == '=') {
                key.* = null;
                return false;
            }
            key.* = @ptrCast(kv + i + 1);
        } else if (kv[i] == '=') {
            kv[i] = 0;
            if (i != kvlen - 1)
                value.* = @ptrCast(kv + i + 1);
            break;
        }
    }

    if (value.* == null)
        return false;

    // Strip trailing whitespace from key (leading stripped earlier)
    {
        const k = key.*.?;
        var end: [*]const u8 = k + std.mem.len(k) - 1;
        while (isSpace(end[0]))
            end -= 1;
        @constCast(end)[1] = 0;
    }

    // Strip leading whitespace from value (trailing stripped earlier)
    while (isSpace(value.*.?[0]))
        value.* = value.*.? + 1;

    return true;
}

export fn parse_config_file(
    f: *anyopaque,
    conf: *types.Config,
    path: [*:0]const u8,
    errors_are_fatal: bool,
) callconv(.c) bool {
    var section: usize = SECTION_MAIN;

    var line_buf: ?[*]u8 = null;
    var count: usize = 0;
    var ret = true;

    var section_name: ?[*:0]u8 = xstrdup("main");
    var section_suffix: ?[*:0]u8 = null;

    var context = types.ConfigContext{
        .conf = conf,
        .section = section_name,
        .section_suffix = section_suffix,
        .key = null,
        .value = null,
        .path = path,
        .lineno = 0,
        .errors_are_fatal = errors_are_fatal,
    };
    const ctx = &context;

    __errno_location().* = 0;

    parse: {
        while (true) {
            const got = getline(&line_buf, &count, f);
            if (got == -1)
                break;

            ctx.key = null;
            ctx.value = null;
            ctx.lineno += 1;

            var line: [*]u8 = line_buf.?;
            var line_len: usize = @intCast(got);

            // Strip leading whitespace
            while (isSpace(line[0])) {
                line += 1;
                line_len -= 1;
            }

            // Empty line, or comment
            if (line[0] == 0 or line[0] == '#')
                continue;

            // Strip the trailing newline - may be absent on the last line
            if (line[line_len - 1] == '\n') {
                line_len -= 1;
                line[line_len] = 0;
            }

            // Split into key/value pair + trailing comment separated by blank
            const key_value: [*]u8 = line;
            var kv_trailing: [*]u8 = line + line_len - 1;
            var comment: [*]u8 = line + 1;
            while (comment[1] != 0) : (comment += 1) {
                if (isBlank(comment[0]) and comment[1] == '#') {
                    comment[1] = 0; // Terminate the key/value pair
                    kv_trailing = comment;
                    break;
                }
            }

            // Strip trailing whitespace
            while (isSpace(kv_trailing[0]))
                kv_trailing -= 1;
            kv_trailing[1] = 0;

            // New section?
            if (key_value[0] == '[') {
                const name: [*]u8 = key_value + 1;

                if (name[0] == ']') {
                    contextualErr(ctx, @src(), "empty section name", .{});
                    section = SECTION_COUNT;
                    if (errors_are_fatal) {
                        ret = false;
                        break :parse;
                    }
                    continue;
                }

                const end = strchr(@ptrCast(name), ']') orelse {
                    ctx.section = @ptrCast(name);
                    contextualErr(ctx, @src(), "syntax error: no closing ']'", .{});
                    ctx.section = section_name;
                    section = SECTION_COUNT;
                    if (errors_are_fatal) {
                        ret = false;
                        break :parse;
                    }
                    continue;
                };

                end[0] = 0;

                if (end[1] != 0) {
                    ctx.section = @ptrCast(name);
                    contextualErr(ctx, @src(), "section declaration contains trailing characters", .{});
                    ctx.section = section_name;
                    section = SECTION_COUNT;
                    if (errors_are_fatal) {
                        ret = false;
                        break :parse;
                    }
                    continue;
                }

                var maybe_suffix: ?[*:0]u8 = null;
                section = strToSection(@ptrCast(name), &maybe_suffix);

                if (section == SECTION_COUNT) {
                    ctx.section = @ptrCast(name);
                    contextualErr(ctx, @src(), "invalid section name: {s}", .{std.mem.span(@as([*:0]u8, @ptrCast(name)))});
                    ctx.section = section_name;
                    if (errors_are_fatal) {
                        ret = false;
                        break :parse;
                    }
                    continue;
                }

                if (section_name) |old|
                    free(@ptrCast(old));
                if (section_suffix) |old|
                    free(@ptrCast(old));
                section_name = xstrdup(@ptrCast(name));
                section_suffix = if (maybe_suffix) |s| xstrdup(s) else null;
                ctx.section = section_name;
                ctx.section_suffix = section_suffix;

                // Process next line
                continue;
            }

            if (section >= SECTION_COUNT) {
                // Last section name was invalid; ignore all keys in it
                continue;
            }

            if (!parseKeyValue(@ptrCast(key_value), null, &ctx.key, &ctx.value)) {
                contextualErr(
                    ctx,
                    @src(),
                    "syntax error: key/value pair has no {s}",
                    .{if (ctx.key == null) "key" else "value"},
                );
                if (errors_are_fatal) {
                    ret = false;
                    break :parse;
                }
                continue;
            }

            if (!section_info[section].fun(ctx)) {
                if (errors_are_fatal) {
                    ret = false;
                    break :parse;
                }
                continue;
            }

            // For next iteration of getline()
            __errno_location().* = 0;
        }

        if (__errno_location().* != 0) {
            log_and_notify_errno(conf, @src().file, @intCast(@src().line), "%s", "failed to read from configuration");
            if (errors_are_fatal)
                ret = false;
        }
    }

    if (section_name) |old|
        free(@ptrCast(old));
    if (section_suffix) |old|
        free(@ptrCast(old));
    if (line_buf) |old|
        free(@ptrCast(old));

    return ret;
}

// ── override loop (C2g) ───────────────────────────────────────────
//
// config_override_apply() was the last C piece of the parser proper. It is
// the same key/value split as the file loop above, but without comments,
// sections or include handling: each tll item is "section.key=value".
// Collision resolution needs the C binding tables, so that stays in C.

const tll = @import("tll.zig");
const Overrides = tll.Tll(?[*:0]u8);

extern fn config_bindings_finalize(conf: *types.Config) callconv(.c) bool;

const SECTION_KEY_BINDINGS = 12;
const SECTION_SEARCH_BINDINGS = 13;
const SECTION_URL_BINDINGS = 14;
const SECTION_MOUSE_BINDINGS = 15;

/// C: `conf->csd.border_width = max(min_csd_border_width, visible)`
const min_csd_border_width: u16 = 5;

export fn config_override_apply(
    conf: *types.Config,
    overrides: *Overrides,
    errors_are_fatal: bool,
) callconv(.c) bool {
    var section_name: ?[*:0]const u8 = null;

    var context = types.ConfigContext{
        .conf = conf,
        .section = null,
        .section_suffix = null,
        .key = null,
        .value = null,
        .path = "override",
        .lineno = 0,
        .errors_are_fatal = errors_are_fatal,
    };
    const ctx = &context;

    var it = overrides.foreach();
    while (it.next()) |node| {
        ctx.lineno += 1;

        if (!parseKeyValue(node.item.?, &section_name, &ctx.key, &ctx.value)) {
            contextualErr(
                ctx,
                @src(),
                "syntax error: key/value pair has no {s}",
                .{if (ctx.key == null) "key" else "value"},
            );
            if (errors_are_fatal)
                return false;
            continue;
        }

        if (section_name.?[0] == 0) {
            contextualErr(ctx, @src(), "empty section name", .{});
            if (errors_are_fatal)
                return false;
            continue;
        }

        var maybe_section_suffix: ?[*:0]u8 = null;
        const section = strToSection(@constCast(section_name.?), &maybe_section_suffix);

        ctx.section = section_name;
        ctx.section_suffix = maybe_section_suffix;

        if (section == SECTION_COUNT) {
            contextualErr(
                ctx,
                @src(),
                "invalid section name: {s}",
                .{std.mem.span(section_name.?)},
            );
            if (errors_are_fatal)
                return false;
            continue;
        }

        if (!section_info[section].fun(ctx)) {
            if (errors_are_fatal)
                return false;
            continue;
        }
    }

    conf.csd.border_width = @max(min_csd_border_width, conf.csd.border_width_visible);

    return config_bindings_finalize(conf);
}
