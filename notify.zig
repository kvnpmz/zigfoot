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
    notify_tll_free_and_free_actions(notif);

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

// ── notify-shim.c additions ───────────────────────────────────────
extern fn notify_icon_at(term: *types.Terminal, idx: usize) callconv(.c) *types.NotificationIcon;
extern fn notify_icon_count() callconv(.c) usize;
extern fn notify_tll_free_and_free_actions(notif: *types.Notification) callconv(.c) void;

// ── consume_stdout ────────────────────────────────────────────────
export fn consume_stdout(notif: *types.Notification, eof: bool) callconv(.c) void {
    const data_start = notif.stdout_data orelse {
        return;
    };
    var data: [*]u8 = data_start;
    var left: usize = notif.stdout_sz;
    var line: [*]u8 = data;

    while (left > 0) {
        line = data;
        var len: usize = left;

        const idx = std.mem.indexOfScalar(u8, data[0..left], '\n');
        const eol: ?[*]u8 = if (idx) |i| data + i else null;
        if (eol) |e| {
            e[0] = 0;
            len = std.mem.len(@as([*:0]u8, @ptrCast(line)));
            data = e + 1;
        } else if (!eof) {
            break;
        }

        var maybe_id: u32 = 0;
        var maybe_button_nr: u32 = 0;

        if ((notif.external_id == 0 and to_integer(line, len, &maybe_id)) or
            (len > 3 and std.mem.eql(u8, line[0..3], "id=") and
             to_integer(line + 3, len - 3, &maybe_id)))
        {
            notif.external_id = maybe_id;
        } else if ((len == 7 and std.mem.eql(u8, line[0..7], "default")) or
                   (len == 14 and std.mem.eql(u8, line[0..14], "action=default")))
        {
            notif.activated = true;
        } else if (len > 7 and std.mem.eql(u8, line[0..7], "action=")) {
            notif.activated = true;
            if (to_integer(line + 7, len - 7, &maybe_button_nr)) {
                notif.activated_button = maybe_button_nr;
            }
        } else if (notif.external_id > 0 and
                   to_integer(line, len, &maybe_button_nr) and
                   maybe_button_nr > 0 and
                   maybe_button_nr <= notif.button_count)
        {
            notif.activated = true;
            notif.activated_button = maybe_button_nr;
        } else if (len > 9 and std.mem.eql(u8, line[0..9], "xdgtoken=")) {
            notif.xdg_token = xstrndup(line + 9, len - 9);
        }

        left -= len + (if (eol != null) @as(usize, 1) else 0);
    }

    if (left > 0) {
        std.mem.copyForwards(u8, notif.stdout_data.?[0..left], data[0..left]);
    }

    notif.stdout_sz = left;
}

extern fn xstrndup(s: [*]const u8, n: usize) callconv(.c) ?[*:0]u8;

// ── add_icon ──────────────────────────────────────────────────────
fn addIcon(
    icon: *types.NotificationIcon,
    id: [*:0]const u8,
    symbolic_name: ?[*:0]const u8,
    data: ?[*]const u8,
    data_sz: usize,
) void {
    icon.id = xstrdup(id);
    icon.symbolic_name = if (symbolic_name) |s| xstrdup(s) else null;
    icon.tmp_file_name = null;
    icon.tmp_file_fd = -1;

    if (symbolic_name == null and data_sz > 0) {
        _ = write_icon_file(
            @ptrCast(data.?),
            data_sz,
            &icon.tmp_file_fd,
            &icon.tmp_file_name,
            &icon.symbolic_name,
        );
    }
}

// ── notify_icon_add ───────────────────────────────────────────────
export fn notify_icon_add(
    term: *types.Terminal,
    id: [*:0]const u8,
    symbolic_name: ?[*:0]const u8,
    data: ?[*]const u8,
    data_sz: usize,
) callconv(.c) void {
    const count = notify_icon_count();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const icon = notify_icon_at(term, i);
        if (icon.id == null) {
            addIcon(icon, id, symbolic_name, data, data_sz);
            return;
        }
    }

    // Cache full — throw out first, shift left, add new at end
    notify_icon_free(notify_icon_at(term, 0));
    var j: usize = 0;
    while (j < count - 1) : (j += 1) {
        notify_icon_at(term, j).* = notify_icon_at(term, j + 1).*;
    }
    addIcon(notify_icon_at(term, count - 1), id, symbolic_name, data, data_sz);
}

// ── notify_icon_del ───────────────────────────────────────────────
export fn notify_icon_del(term: *types.Terminal, id: [*:0]const u8) callconv(.c) void {
    const count = notify_icon_count();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const icon = notify_icon_at(term, i);
        if (icon.id == null) continue;
        if (!std.mem.eql(u8, std.mem.span(icon.id.?), std.mem.span(id))) continue;
        notify_icon_free(icon);
        return;
    }
}

// ── chunk B-1 ─────────────────────────────────────────────────────
extern fn read(fd: c_int, buf: *anyopaque, count: usize) callconv(.c) isize;
extern fn notify_active_first(term: *types.Terminal) callconv(.c) ?*types.Notification;
extern fn notify_active_next(term: *types.Terminal, prev: *types.Notification) callconv(.c) ?*types.Notification;
extern fn notify_conf_action_arg_configured(term: *types.Terminal) callconv(.c) bool;
extern fn notify_spawn_expand_action_arg(term: *types.Terminal, name: [*:0]const u8, label: [*:0]const u8, argc: *usize, argv: *?[*:null]?[*:0]u8) callconv(.c) bool;
extern fn notify_term_fdm(term: *types.Terminal) callconv(.c) ?*anyopaque;
extern fn fdm_add(fdm: *anyopaque, fd: c_int, events: c_int, handler: *const fn (*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) bool, data: ?*anyopaque) callconv(.c) bool;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;

const EPOLLIN: c_int = 0x1;
const EPOLLHUP: c_int = 0x10;
const EINTR: c_int = 4;

extern fn __errno_location() callconv(.c) *c_int;

export fn fdm_notify_stdout(fdm: *anyopaque, fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) bool {
    const term: *types.Terminal = @ptrCast(@alignCast(data.?));

    var notif: ?*types.Notification = null;
    var it = notify_active_first(term);
    while (it) |n| {
        if (n.stdout_fd == fd) { notif = n; break; }
        it = notify_active_next(term, n);
    }

    if (events & EPOLLIN != 0) {
        var buf: [512]u8 = undefined;
        const count = read(fd, &buf, buf.len - 1);
        if (count < 0) {
            if (__errno_location().* == EINTR) return true;
            return false;
        }
        if (count > 0) {
            if (notif) |n| {
                const c: usize = @intCast(count);
                if (n.stdout_data == null) {
                    n.stdout_data = @ptrCast(xmalloc(c) orelse return false);
                } else {
                    n.stdout_data = @ptrCast(xrealloc(@ptrCast(n.stdout_data), n.stdout_sz + c) orelse return false);
                }
                @memcpy(n.stdout_data.?[n.stdout_sz..n.stdout_sz + c], buf[0..c]);
                n.stdout_sz += c;
                consume_stdout(n, false);
            }
        }
    }

    if (events & EPOLLHUP != 0) {
        _ = fdm_del(fdm, fd);
        if (notif) |n| {
            n.stdout_fd = -1;
            consume_stdout(n, true);
        }
    }

    return true;
}

export fn expand_action_to_argv(
    term: *types.Terminal,
    name: [*:0]const u8,
    label: [*:0]const u8,
    argc: *usize,
    argv: *?[*:null]?[*:0]u8,
) callconv(.c) bool {
    var expanded: ?[*:null]?[*:0]u8 = null;
    var count: usize = 0;
    if (!notify_spawn_expand_action_arg(term, name, label, &count, &expanded)) return false;

    const new_size = (argc.* + count) * @sizeOf(?[*:0]u8);
    const old_ptr: ?*anyopaque = @ptrCast(argv.*);
    const new_ptr: ?[*]?[*:0]u8 = @ptrCast(@alignCast(xrealloc(old_ptr, new_size) orelse return false));
    argv.* = @ptrCast(new_ptr);
    if (expanded) |e| {
        @memcpy(new_ptr.?[argc.*..argc.* + count], e[0..count]);
    }
    argc.* += count;
    if (expanded) |e| free(@ptrCast(e));
    return true;
}

// ── chunk B-2 ─────────────────────────────────────────────────────
extern fn notify_active_remove(term: *types.Terminal, notif: *types.Notification) callconv(.c) void;
extern fn notify_term_reaper(term: *types.Terminal) callconv(.c) ?*anyopaque;
extern fn notify_conf_close_configured(term: *types.Terminal) callconv(.c) bool;
extern fn notify_spawn_expand_close(term: *types.Terminal, id: [*:0]const u8, argc: *usize, argv: *?[*:null]?[*:0]u8) callconv(.c) bool;
extern fn xsnprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn kill(pid: c_int, sig: c_int) callconv(.c) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
extern fn spawn(reaper: ?*anyopaque, cwd: ?[*:0]const u8, argv: ?[*:null]?[*:0]u8, stdin_fd: c_int, stdout_fd: c_int, stderr_fd: c_int, cb: ?*const fn (?*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) void, cb_data: ?*anyopaque, token: ?[*:0]const u8) callconv(.c) c_int;

const SIGINT: c_int = 2;
const O_RDONLY: c_int = 0;

export fn notify_close(term: *types.Terminal, id: [*:0]const u8) callconv(.c) void {
    var it = notify_active_first(term);
    while (it) |notif| : (it = notify_active_next(term, notif)) {
        const nid = notif.id orelse continue;
        if (!std.mem.eql(u8, std.mem.span(nid), std.mem.span(id))) continue;

        if (!notify_conf_close_configured(term)) {
            if (notif.pid != 0) {
                _ = kill(notif.pid, SIGINT);
            }
        } else {
            if (notif.external_id == 0) return;

            var external_id_buf: [16]u8 = undefined;
            const n = xsnprintf(&external_id_buf, external_id_buf.len, "%u", notif.external_id);
            external_id_buf[@intCast(n)] = 0;

            var argv: ?[*:null]?[*:0]u8 = null;
            var argc: usize = 0;
            if (!notify_spawn_expand_close(term, @ptrCast(&external_id_buf), &argc, &argv)) return;

            const devnull = open("/dev/null", O_RDONLY);
            _ = spawn(notify_term_reaper(term), null, argv, devnull, -1, -1, null, null, null);
            if (devnull >= 0) _ = close(devnull);

            if (argv) |a| {
                var i: usize = 0;
                while (i < argc) : (i += 1) {
                    if (a[i]) |s| free(@ptrCast(s));
                }
                free(@ptrCast(a));
            }
        }
        return;
    }
}
