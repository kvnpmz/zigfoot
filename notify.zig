const std = @import("std");
const types = @import("terminal_types.zig");

extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn unlink(path: [*:0]const u8) callconv(.c) c_int;
extern fn mkostemp(template: [*:0]u8, flags: c_int) callconv(.c) c_int;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn notify_xstrjoin(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) ?[*:0]u8;

const O_CLOEXEC: c_int = 0x80000;

fn freePtr(p: anytype) void {
    if (p) |v| free(@ptrCast(@constCast(v)));
}

export fn notify_free(term: ?*types.Terminal, notif: *types.Notification) callconv(.c) void {
    _ = term;
    // TODO(chunk B): fdm_del(term->fdm, notif->stdout_fd) when pid > 0
    freePtr(notif.id);
    freePtr(notif.title);
    freePtr(notif.body);
    freePtr(notif.category);
    freePtr(notif.app_id);
    freePtr(notif.icon_cache_id);
    freePtr(notif.icon_symbolic_name);
    if (notif.icon_data) |d| free(@ptrCast(d));
    freePtr(notif.sound_name);
    freePtr(notif.xdg_token);
    if (notif.stdout_data) |d| free(@ptrCast(d));
    // TODO(chunk B): tll_free_and_free(notif->actions, free)

    if (notif.icon_path) |path| {
        _ = unlink(path);
        free(@ptrCast(path));
        if (notif.icon_fd >= 0) _ = close(notif.icon_fd);
    }

    const bytes: [*]u8 = @ptrCast(notif);
    @memset(bytes[0..@sizeOf(types.Notification)], 0);
}

export fn write_icon_file(
    data: *const anyopaque,
    data_sz: usize,
    fd: *c_int,
    filename: *?[*:0]u8,
    symbolic_name: *?[*:0]u8,
) callconv(.c) bool {
    var name: [64:0]u8 = undefined;
    const template = "/tmp/foot-notification-icon-XXXXXX";
    @memcpy(name[0..template.len], template);
    name[template.len] = 0;

    filename.* = null;
    symbolic_name.* = null;
    fd.* = mkostemp(&name, O_CLOEXEC);
    if (fd.* < 0) return false;

    const written = std.c.write(fd.*, @as([*]const u8, @ptrCast(data)), data_sz);
    if (written != @as(isize, @intCast(data_sz))) {
        _ = close(fd.*);
        fd.* = -1;
        return false;
    }

    filename.* = xstrdup(&name);
    if (filename.*) |f| {
        symbolic_name.* = notify_xstrjoin("file://", f);
    }
    return true;
}

export fn to_integer(line: [*]const u8, len: usize, res: *u32) callconv(.c) bool {
    var is_id = true;
    var maybe_id: u32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const digit = line[i];
        if (digit < '0' or digit > '9') {
            is_id = false;
            break;
        }
        maybe_id = maybe_id *% 10 +% @as(u32, digit - '0');
    }
    res.* = maybe_id;
    return is_id;
}

export fn notify_icon_free(icon: *types.NotificationIcon) callconv(.c) void {
    if (icon.tmp_file_name) |name| {
        _ = unlink(name);
        if (icon.tmp_file_fd >= 0) _ = close(icon.tmp_file_fd);
    }
    freePtr(icon.id);
    freePtr(icon.symbolic_name);
    freePtr(icon.tmp_file_name);
    icon.id = null;
    icon.symbolic_name = null;
    icon.tmp_file_name = null;
    icon.tmp_file_fd = -1;
}
