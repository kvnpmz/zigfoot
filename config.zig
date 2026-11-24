// Value-parsing helpers for the config parser (Phase 2, chunk C2a).
//
// config.c still owns the parser itself (sections, key/value tokenizing,
// include handling, the option tables). This file owns the leaf conversions
// every option handler goes through: strings, booleans, integers, colours,
// pt/px values, command-line templates and the tll-backed argv clone/free
// pair.
//
// The C versions were kept only as thin wrappers; `tests/test-config.c`
// (#include "../config.c") is the oracle for the behaviour below, so every
// libc call is kept deliberately — strtoul/strtof/strtok/sscanf semantics
// ("0x10", "  5x6", leading whitespace, truncation) are part of the contract
// and re-implementing them by hand would only introduce drift.

const std = @import("std");
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
