const std = @import("std");

const Argv = extern struct { args: ?[*:null]?[*:0]u8 };
const ConfigSpawnTemplate = extern struct { argv: Argv };

extern fn xmalloc(size: usize) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;

const log_class_warning: c_int = 2; // LOG_CLASS_WARNING, see log.h
const log_module = "spawn";

fn append(buf: *?[*]u8, len: *usize, bytes: [*]const u8, n: usize) void {
    buf.* = @ptrCast(xrealloc(buf.*, len.* + n + 1).?);
    @memcpy(buf.*.?[len.*..][0..n], bytes[0..n]);
    len.* += n;
    buf.*.?[len.*] = 0;
}

export fn spawn_expand_template(
    template: *const ConfigSpawnTemplate,
    key_count: usize,
    key_names: ?[*]const ?[*:0]const u8,
    key_values: ?[*]const ?[*:0]const u8,
    argc: *usize,
    argv: *?[*:null]?[*:0]u8,
) bool {
    argc.* = 0;
    argv.* = null;

    const in_args = template.argv.args orelse unreachable;
    while (in_args[argc.*] != null) argc.* += 1;

    const out: [*:null]?[*:0]u8 = @ptrCast(@alignCast(xmalloc((argc.* + 1) * @sizeOf(?[*:0]u8)).?));
    argv.* = out;

    for (0..argc.*) |i| {
        const arg_z: [*:0]const u8 = in_args[i].?;
        const arg: [*]const u8 = arg_z;
        const arg_len = std.mem.len(arg_z);

        var len: usize = 0;
        var buf: ?[*]u8 = null;

        var last_end: usize = 0;
        var search_from: usize = 0;

        while (std.mem.indexOfPos(u8, arg[0..arg_len], search_from, "${")) |dollar| {
            append(&buf, &len, arg + last_end, dollar - last_end);

            const name_start = dollar + 2;
            if (std.mem.indexOfScalarPos(u8, arg[0..arg_len], name_start, '}')) |brace| {
                const name = arg[name_start..brace];

                var valid = false;
                var j: usize = 0;
                while (j < key_count) : (j += 1) {
                    const key: [*:0]const u8 = key_names.?[j].?;
                    if (std.mem.len(key) < name.len) continue;
                    if (!std.mem.eql(u8, key[0..name.len], name)) continue;

                    const val: [*:0]const u8 = key_values.?[j].?;
                    append(&buf, &len, val, std.mem.len(val));
                    valid = true;
                    break;
                }

                if (!valid) {
                    append(&buf, &len, arg + dollar, brace + 1 - dollar);
                    log_msg(log_class_warning, log_module, @src().file, @src().line, "notify: unrecognized template: %.*s", @as(c_int, @intCast(brace + 1 - dollar)), arg + dollar);
                }

                last_end = brace + 1;
                search_from = brace + 1;
            } else {
                log_msg(log_class_warning, log_module, @src().file, @src().line, "notify: unclosed template: %s", arg_z + dollar);
                last_end = dollar;
                break;
            }
        }

        append(&buf, &len, arg + last_end, arg_len - last_end);
        out[i] = @ptrCast(buf.?);
    }

    out[argc.*] = null;
    return true;
}
