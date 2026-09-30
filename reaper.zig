const Fdm = opaque {};

const SIGCHLD: c_int = 17;
const WNOHANG: c_int = 1;

extern fn fdm_signal_add(
    fdm: *Fdm,
    signo: c_int,
    handler: SigCb,
    data: ?*anyopaque,
) bool;
extern fn fdm_signal_del(fdm: *Fdm, signo: c_int) bool;

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const LOG_CLASS_DEBUG: c_int = 4;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;

const Reaper = struct {
    fdm: *Fdm,
    children: List(Child) = .{},
};

const ChildCb = *const fn (
    reaper: *Reaper,
    pid: c_int,
    status: c_int,
    data: ?*anyopaque,
) callconv(.c) void;

const SigCb = *const fn (
    fdm: *Fdm,
    signo: c_int,
    data: ?*anyopaque,
) callconv(.c) bool;

const Child = struct {
    pid: c_int,
    cb: ?ChildCb,
    cb_data: ?*anyopaque,
    prev: ?*Child = null,
    next: ?*Child = null,
};

fn List(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        fn pushBack(self: *Self, node: *T) void {
            node.prev = self.tail;
            node.next = null;

            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }

            self.tail = node;
        }

        fn remove(self: *Self, node: *T) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            node.prev = null;
            node.next = null;
        }
    };
}

fn logDebug(fmt: [*:0]const u8, args: anytype) void {
    _ = args;
    // Temporary: the C logging ABI is variadic, so keep logging disabled
    // until the Zig logging interface is ported.
    _ = fmt;
}

fn fdmReap(_: *Fdm, _: c_int, data: ?*anyopaque) callconv(.c) bool {
    const reaper = @as(*Reaper, @ptrCast(@alignCast(data.?)));

    while (true) {
        var status: c_int = 0;
        const pid = waitpid(-1, &status, WNOHANG);

        if (pid <= 0)
            break;

        var it = reaper.children.head;
        while (it) |child| {
            const next = child.next;

            if (child.pid == pid) {
                reaper.children.remove(child);

                const cb = child.cb;
                const cb_data = child.cb_data;

                free(@ptrCast(child));

                if (cb) |callback|
                    callback(reaper, pid, status, cb_data);

                break;
            }

            it = next;
        }
    }

    return true;
}

export fn reaper_init(fdm: *Fdm) callconv(.c) ?*Reaper {
    const raw = malloc(@sizeOf(Reaper)) orelse return null;
    const reaper: *Reaper = @ptrCast(@alignCast(raw));

    reaper.* = .{
        .fdm = fdm,
        .children = .{},
    };

    if (!fdm_signal_add(fdm, SIGCHLD, fdmReap, reaper)) {
        free(raw);
        return null;
    }

    return reaper;
}

export fn reaper_destroy(reaper_opt: ?*Reaper) callconv(.c) void {
    const reaper = reaper_opt orelse return;

    _ = fdm_signal_del(reaper.fdm, SIGCHLD);

    var it = reaper.children.head;
    while (it) |child| {
        const next = child.next;
        free(@ptrCast(child));
        it = next;
    }

    free(@ptrCast(reaper));
}

export fn reaper_add(
    reaper: *Reaper,
    pid: c_int,
    cb: ?ChildCb,
    cb_data: ?*anyopaque,
) callconv(.c) void {
    const raw = malloc(@sizeOf(Child)) orelse return;
    const child: *Child = @ptrCast(@alignCast(raw));

    child.* = .{
        .pid = pid,
        .cb = cb,
        .cb_data = cb_data,
    };

    reaper.children.pushBack(child);
}

export fn reaper_del(reaper: *Reaper, pid: c_int) callconv(.c) void {
    var it = reaper.children.head;

    while (it) |child| {
        const next = child.next;

        if (child.pid == pid) {
            reaper.children.remove(child);
            free(@ptrCast(child));
            return;
        }

        it = next;
    }
}
