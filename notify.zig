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
    // C: if (notif->pid > 0) fdm_del(term->fdm, notif->stdout_fd);
    if (notif.pid > 0) {
        if (term) |t| {
            if (t.fdm) |fdm| _ = fdm_del(fdm, notif.stdout_fd);
        }
    }
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
    const count = term.notification_icons.len;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const icon = &term.notification_icons[i];
        if (icon.id == null) {
            addIcon(icon, id, symbolic_name, data, data_sz);
            return;
        }
    }

    // Cache full — throw out first, shift left, add new at end
    notify_icon_free(&term.notification_icons[0]);
    var j: usize = 0;
    while (j < count - 1) : (j += 1) {
        term.notification_icons[j] = term.notification_icons[j + 1];
    }
    addIcon(&term.notification_icons[count - 1], id, symbolic_name, data, data_sz);
}

// ── notify_icon_del ───────────────────────────────────────────────
export fn notify_icon_del(term: *types.Terminal, id: [*:0]const u8) callconv(.c) void {
    const count = term.notification_icons.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const icon = &term.notification_icons[i];
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
extern fn notify_spawn_expand_action_arg(term: *types.Terminal, name: [*:0]const u8, label: [*:0]const u8, argc: *usize, argv: *?[*:null]?[*:0]u8) callconv(.c) bool;
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

        if (term.conf.?.desktop_notifications.close.argv.args == null) {
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
            _ = spawn(term.reaper, null, argv, devnull, -1, -1, null, null, null);
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

// ── chunk B-3a ────────────────────────────────────────────────────
extern fn notify_wayl_terms_first(wayl: *anyopaque) callconv(.c) ?*types.Terminal;
extern fn notify_wayl_terms_next(wayl: *anyopaque, prev: *types.Terminal) callconv(.c) ?*types.Terminal;
extern fn wayl_win_set_urgent(window: *anyopaque) callconv(.c) bool;
extern fn wayl_activate(wayl: *anyopaque, window: *anyopaque, token: [*:0]const u8) callconv(.c) void;
extern fn term_to_slave(term: *types.Terminal, data: *const anyopaque, len: usize) callconv(.c) bool;

const DoneContext = extern struct {
    wayl: *anyopaque,
    term: *types.Terminal,
};

export fn notif_done(_reaper: ?*anyopaque, pid: c_int, _status: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = _reaper;
    _ = _status;
    const ctx: *DoneContext = @ptrCast(@alignCast(data.?));
    const wayl = ctx.wayl;
    const wanted_term = ctx.term;
    free(@ptrCast(ctx));

    var term: ?*types.Terminal = null;
    var tit = notify_wayl_terms_first(wayl);
    while (tit) |t| : (tit = notify_wayl_terms_next(wayl, t)) {
        if (t == wanted_term) { term = t; break; }
    }

    const found_term = term orelse return;

    var it = notify_active_first(found_term);
    while (it) |notif| : (it = notify_active_next(found_term, notif)) {
        if (notif.pid != pid) continue;

        if (notif.activated and notif.focus) {
            const window = found_term.window;
            if (notif.xdg_token) |token| {
                _ = wayl_activate(found_term.wl.?, window.?, token);
            } else {
                if (window) |w| _ = wayl_win_set_urgent(w);
            }
        }

        const id_str: [*:0]const u8 = if (notif.id) |i| i else "0";

        if (notif.activated and notif.report_activated) {
            var button_nr_buf: [16]u8 = [_]u8{0} ** 16;
            if (notif.activated_button > 0) {
                const bn = xsnprintf(&button_nr_buf, button_nr_buf.len, "%u", notif.activated_button);
                button_nr_buf[@intCast(bn)] = 0;
            }
            var reply: [128]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1b]99;i=%s;%s\x1b\\", id_str, @as([*:0]const u8, @ptrCast(&button_nr_buf)));
            _ = term_to_slave(found_term, &reply, @intCast(n));
        }

        if (notif.report_closed) {
            var reply: [128]u8 = undefined;
            const n = xsnprintf(&reply, reply.len, "\x1b]99;i=%s:p=close;\x1b\\", id_str);
            _ = term_to_slave(found_term, &reply, @intCast(n));
        }

        notify_free(found_term, notif);
        notify_active_remove(found_term, notif);
        return;
    }
}

// ── chunk B-3b ────────────────────────────────────────────────────
extern fn notify_active_push_back(term: *types.Terminal, notif: *types.Notification) callconv(.c) void;
extern fn notify_active_back(term: *types.Terminal) callconv(.c) ?*types.Notification;
extern fn notify_actions_first(notif: *types.Notification) callconv(.c) ?[*:0]const u8;
extern fn notify_actions_next(notif: *types.Notification, prev: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn notify_actions_len(notif: *types.Notification) callconv(.c) usize;
extern fn notify_actions_zero(notif: *types.Notification) callconv(.c) void;
extern fn notify_spawn_expand_command(term: *types.Terminal, app_id: [*:0]const u8, window_title: [*:0]const u8, icon: [*:0]const u8, title: [*:0]const u8, body: [*:0]const u8, category: [*:0]const u8, urgency: [*:0]const u8, muted: [*:0]const u8, sound_name: [*:0]const u8, expire_time: [*:0]const u8, replace_id: [*:0]const u8, action_argument: [*:0]const u8, argc: *usize, argv: *?[*:null]?[*:0]u8) callconv(.c) bool;
extern fn notify_pipe2(fds: [*]c_int, flags: c_int) callconv(.c) c_int;
extern fn notify_fdm_add_stdout(fdm: *anyopaque, fd: c_int, term: *types.Terminal) callconv(.c) void;

const O_NONBLOCK: c_int = 0x800;
const NOTIFY_ALWAYS: types.NotifyWhen = .always;
const NOTIFY_URGENCY_LOW: types.NotifyUrgency = .low;
const NOTIFY_URGENCY_NORMAL: types.NotifyUrgency = .normal;

export fn notify_notify(term: *types.Terminal, notif_in: *types.Notification) callconv(.c) bool {
    var notif: *types.Notification = notif_in;
    notif.pid = -1;
    notif.stdout_fd = -1;
    notif.icon_fd = -1;

    if (term.conf.?.desktop_notifications.command.argv.args == null) return false;

    if ((term.conf.?.desktop_notifications.inhibit_when_focused or notif.when != NOTIFY_ALWAYS)
        and term.kbd_focus)
    {
        return false;
    }

    const app_id: [*:0]const u8 = if (notif.app_id) |a| a
        else if (term.app_id) |a| a
        else term.conf.?.app_id orelse "";

    const title: [*:0]const u8 = if (notif.title) |t| t
        else if (notif.body) |b| b else "";

    const body: [*:0]const u8 = if (notif.title != null and notif.body != null) notif.body.? else "";

    var icon_name_or_path: [*:0]const u8 = "";

    if (notif.icon_cache_id) |cache_id| {
        const count = term.notification_icons.len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const icon = &term.notification_icons[i];
            if (icon.id) |iid| {
                if (std.mem.eql(u8, std.mem.span(iid), std.mem.span(cache_id))) {
                    icon_name_or_path = icon.symbolic_name.?;
                    break;
                }
            }
        }
    } else if (notif.icon_symbolic_name) |sn| {
        icon_name_or_path = sn;
    } else if (notif.icon_data_sz > 0) {
        if (write_icon_file(@ptrCast(notif.icon_data.?), notif.icon_data_sz, &notif.icon_fd, &notif.icon_path, &notif.icon_symbolic_name)) {
            icon_name_or_path = notif.icon_symbolic_name.?;
        }
    }

    const track_notification = notif.focus or notif.report_activated or notif.may_be_programatically_closed;

    var replaces_id: u32 = 0;
    if (notif.id) |id| {
        var it = notify_active_first(term);
        while (it) |existing| : (it = notify_active_next(term, existing)) {
            const eid = existing.id orelse continue;
            if (existing.external_id != 0 and std.mem.eql(u8, std.mem.span(eid), std.mem.span(id))) {
                replaces_id = existing.external_id;
                existing.report_activated = false;
                existing.report_closed = false;
            }
        }
    }

    var replaces_id_buf: [16]u8 = undefined;
    const rn = xsnprintf(&replaces_id_buf, replaces_id_buf.len, "%u", replaces_id);
    replaces_id_buf[@intCast(rn)] = 0;

    const urgency_str: [*:0]const u8 = if (notif.urgency == NOTIFY_URGENCY_LOW) "low"
        else if (notif.urgency == NOTIFY_URGENCY_NORMAL) "normal" else "critical";

    var argv: ?[*:null]?[*:0]u8 = null;
    var argc: usize = 0;
    var action_argv: ?[*:null]?[*:0]u8 = null;
    var action_argc: usize = 0;

    var expire_time_buf: [16]u8 = undefined;
    const en = xsnprintf(&expire_time_buf, expire_time_buf.len, "%d", notif.expire_time);
    expire_time_buf[@intCast(en)] = 0;

    if (term.conf.?.desktop_notifications.command_action_arg.argv.args != null) {
        if (!expand_action_to_argv(term, "default", "Activate", &action_argc, &action_argv)) return false;

        var action_idx: usize = 1;
        var ait = notify_actions_first(notif);
        while (ait) |item| : (ait = notify_actions_next(notif, item)) {
            var name_buf: [16]u8 = undefined;
            const nb = xsnprintf(&name_buf, name_buf.len, "%zu", action_idx);
            action_idx += 1;
            name_buf[@intCast(nb)] = 0;

            if (!expand_action_to_argv(term, @ptrCast(&name_buf), item, &action_argc, &action_argv)) {
                if (action_argv) |a| {
                    var i: usize = 0;
                    while (i < action_argc) : (i += 1) if (a[i]) |s| free(@ptrCast(s));
                    free(@ptrCast(a));
                }
                return false;
            }
        }
    }

    const window_title = term.window_title orelse "";
    const category: [*:0]const u8 = notif.category orelse "";
    const muted_str: [*:0]const u8 = if (notif.muted) "true" else "false";
    const sound_name: [*:0]const u8 = notif.sound_name orelse "";

    if (!notify_spawn_expand_command(term,
        app_id, window_title, icon_name_or_path, title, body, category,
        urgency_str, muted_str, sound_name,
        @ptrCast(&expire_time_buf), @ptrCast(&replaces_id_buf),
        "${action-argument}", &argc, &argv))
    {
        return false;
    }

    // Post-process argv: replace ${action-argument} entry with action_argv entries
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (argv) |a| {
            const s = a[i] orelse continue;
            if (!std.mem.eql(u8, std.mem.span(s), "${action-argument}")) continue;

            if (action_argc == 0) {
                free(@ptrCast(s));
                var j: usize = i;
                while (j < argc) : (j += 1) a[j] = a[j + 1];
                argc -= 1;
            } else {
                const new_size = (argc + action_argc) * @sizeOf(?[*:0]u8);
                const new_ptr: [*]?[*:0]u8 = @ptrCast(@alignCast(xrealloc(@ptrCast(a), new_size) orelse return false));
                argv = @ptrCast(new_ptr);

                var j: usize = argc;
                while (j > i) : (j -= 1) new_ptr[j + action_argc - 1] = new_ptr[j - 1];

                free(@ptrCast(s));

                var k: usize = 0;
                while (k < action_argc) : (k += 1) {
                    if (action_argv) |aa| new_ptr[i + k] = aa[k];
                }
                argc += action_argc;
                argc -= 1;
            }
            break;
        }
    }

    var stdout_fds: [2]c_int = .{ -1, -1 };
    var track = track_notification;
    if (track) {
        if (notify_pipe2(&stdout_fds, O_CLOEXEC | O_NONBLOCK) < 0) {
            track = false;
        } else {
            notify_active_push_back(term, notif);

            notif.id = null;
            notif.title = null;
            notif.body = null;
            notif.category = null;
            notif.app_id = null;
            notif.icon_cache_id = null;
            notif.icon_symbolic_name = null;
            notif.icon_data = null;
            notif.icon_data_sz = 0;
            notif.icon_path = null;
            notif.sound_name = null;
            notif.icon_fd = -1;
            notif.stdout_fd = -1;

            const new_notif = notify_active_back(term).?;
            new_notif.button_count = @intCast(notify_actions_len(notif));
            notify_actions_zero(notif);
            notif = new_notif;
        }
    }

    const fdm = term.fdm.?;
    if (stdout_fds[0] >= 0) {
        notify_fdm_add_stdout(fdm, stdout_fds[0], term);
    }

    var ctx: ?*DoneContext = null;
    if (track) {
        ctx = @ptrCast(@alignCast(xmalloc(@sizeOf(DoneContext)) orelse return false));
        ctx.?.wayl = term.wl orelse @ptrFromInt(1);
        ctx.?.term = term;
    }

    const devnull = open("/dev/null", O_RDONLY);
    const reaper = term.reaper;
    const cb: ?*const fn (?*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) void =
        if (track) @ptrCast(&notif_done) else null;
    const pid = spawn(reaper, null, argv, devnull, stdout_fds[1], -1, cb, if (ctx) |c| @ptrCast(c) else null, null);

    if (stdout_fds[1] >= 0) _ = close(stdout_fds[1]);
    if (pid < 0 and stdout_fds[0] >= 0) _ = fdm_del(fdm, stdout_fds[0]);
    if (devnull >= 0) _ = close(devnull);

    if (argv) |a| {
        var k: usize = 0;
        while (k < argc) : (k += 1) if (a[k]) |s| free(@ptrCast(s));
        free(@ptrCast(a));
    }
    if (action_argv) |a| {
        var k: usize = 0;
        while (k < action_argc) : (k += 1) if (a[k]) |s| free(@ptrCast(s));
        free(@ptrCast(a));
    }

    notif.pid = pid;
    notif.stdout_fd = stdout_fds[0];
    return true;
}
