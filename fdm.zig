const std = @import("std");
const builtin = @import("builtin");

const SigSet = std.c.sigset_t;
const KSigaction = std.c.Sigaction;

// Linux packs epoll_event. The epoll-shim ABI on FreeBSD follows the
// natural alignment of its epoll_data_t member instead. The mirror lives here
// because fdm owns the epoll FDs; terminal_types.zig mirrors and probe-checks
// the same C type, so a layout drift is caught by the native build.
const EpollEvent = if (builtin.os.tag == .linux)
    extern struct { events: u32 align(1), data: u64 align(1) }
else
    extern struct { events: u32, data: u64 };

comptime {
    if (builtin.os.tag == .linux) {
        // <sys/epoll.h> is the source of truth: no hard-coded numbers here.
        const abi = @import("c_layout");
        if (@sizeOf(EpollEvent) != abi.EpollEvent__size)
            @compileError("fdm: EpollEvent size disagrees with the C probe");
        if (@offsetOf(EpollEvent, "events") != abi.EpollEvent_events)
            @compileError("fdm: EpollEvent.events offset disagrees with the C probe");
        if (@offsetOf(EpollEvent, "data") != abi.EpollEvent_data)
            @compileError("fdm: EpollEvent.data offset disagrees with the C probe");
    } else {
        // epoll-shim is only probed when the native build is FreeBSD. Until
        // then these two literals are the only guard on its 16/8 layout.
        if (@sizeOf(EpollEvent) != 16)
            @compileError("epoll-shim epoll_event size must be 16");
        if (@offsetOf(EpollEvent, "data") != 8)
            @compileError("epoll-shim epoll_event.data offset must be 8");
    }
}

const EPOLL_CLOEXEC: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.CLOEXEC)
else
    0o2000000; // epoll-shim API value
const EPOLL_CTL_ADD: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.CTL_ADD)
else
    1; // epoll-shim API value
const EPOLL_CTL_DEL: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.CTL_DEL)
else
    2; // epoll-shim API value
const EPOLL_CTL_MOD: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.CTL_MOD)
else
    3; // epoll-shim API value
const SIG_BLOCK: c_int = std.posix.SIG.BLOCK;
const SIG_UNBLOCK: c_int = std.posix.SIG.UNBLOCK;
const SIG_SETMASK: c_int = std.posix.SIG.SETMASK;
const SIG_DFL: ?std.c.Sigaction.handler_fn = std.posix.SIG.DFL;
const EINTR: c_int = @backingInt(std.posix.E.INTR);
const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno_provided(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, errnum: c_int, fmt: [*:0]const u8, ...) void;

extern fn sigabbrev_np(sig: c_int) ?[*:0]const u8;
extern fn malloc(n: usize) ?*anyopaque;
extern fn calloc(n: usize, size: usize) ?*anyopaque;
extern fn realloc(p: ?*anyopaque, n: usize) ?*anyopaque;
extern fn free(p: ?*anyopaque) void;
extern fn close(fd: c_int) c_int;
extern fn epoll_create1(flags: c_int) c_int;
extern fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, ev: ?*EpollEvent) c_int;
extern fn epoll_pwait(epfd: c_int, events: ?[*]EpollEvent, maxevents: c_int, timeout: c_int, sigmask: *const SigSet) c_int;
extern fn sigemptyset(set: *SigSet) c_int;
extern fn sigaddset(set: *SigSet, signo: c_int) c_int;
extern fn sigprocmask(how: c_int, set: ?*const SigSet, old: ?*SigSet) c_int;
extern fn sigaction(sig: c_int, act: ?*const KSigaction, old: ?*KSigaction) c_int;
extern fn __libc_current_sigrtmax() c_int;

const FdCb = *const fn (*Fdm, c_int, c_int, ?*anyopaque) callconv(.c) bool;
const SigCb = *const fn (*Fdm, c_int, ?*anyopaque) callconv(.c) bool;
const HookCb = *const fn (*Fdm, ?*anyopaque) callconv(.c) void;

const FdHandler = struct {
    fd: c_int,
    events: c_int,
    callback: FdCb,
    data: ?*anyopaque,
    deleted: bool,
    prev: ?*FdHandler = null,
    next: ?*FdHandler = null,
};

const Hook = struct {
    callback: HookCb,
    data: ?*anyopaque,
    deleted: bool = false,
    prev: ?*Hook = null,
    next: ?*Hook = null,
};

const SigHandler = struct { callback: ?SigCb, data: ?*anyopaque };

fn List(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        len: usize = 0,
        const Self = @This();

        fn pushBack(self: *Self, n: *T) void {
            n.prev = self.tail;
            n.next = null;
            if (self.tail) |t| t.next = n else self.head = n;
            self.tail = n;
            self.len += 1;
        }

        fn remove(self: *Self, n: *T) void {
            if (n.prev) |p| p.next = n.next else self.head = n.next;
            if (n.next) |x| x.prev = n.prev else self.tail = n.prev;
            n.prev = null;
            n.next = null;
            self.len -= 1;
        }
    };
}

const Fdm = struct {
    epoll_fd: c_int,
    is_polling: bool,
    hooks_dispatching: bool,
    fds: List(FdHandler),
    deferred: List(FdHandler),
    sigmask: SigSet,
    signal_handlers: [*]SigHandler,
    hooks: [3]List(Hook), // 0 = low, 1 = normal, 2 = high
    events: ?[*]EpollEvent,
    events_cap: usize,
};

var got_signal: std.c.sig_atomic_t = 0;
var received_signals: ?[*]volatile std.c.sig_atomic_t = null;

fn gs() *volatile c_int {
    return &got_signal;
}

fn dropReceivedSignals() void {
    free(@ptrCast(@volatileCast(received_signals)));
    received_signals = null;
}

fn signalHandler(signo: c_int) callconv(.c) void {
    gs().* = 1;
    received_signals.?[@intCast(signo)] = 1;
}

fn logCall(comptime f: anytype, class: c_int, src: std.lang.SourceLocation, fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, f, .{ class, "fdm", "fdm.zig", @as(c_int, @intCast(src.line)), fmt } ++ args);
}
fn logErr(src: std.lang.SourceLocation, fmt: [*:0]const u8, args: anytype) void {
    logCall(log_msg, LOG_CLASS_ERROR, src, fmt, args);
}
fn logWarn(src: std.lang.SourceLocation, fmt: [*:0]const u8, args: anytype) void {
    logCall(log_msg, LOG_CLASS_WARNING, src, fmt, args);
}
fn logErrno(src: std.lang.SourceLocation, fmt: [*:0]const u8, args: anytype) void {
    logCall(log_errno, LOG_CLASS_ERROR, src, fmt, args);
}
fn logErrnoP(src: std.lang.SourceLocation, errnum: c_int, fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_errno_provided, .{ LOG_CLASS_ERROR, "fdm", "fdm.zig", @as(c_int, @intCast(src.line)), errnum, fmt } ++ args);
}

fn sigabbrev(sig: c_int) [*:0]const u8 {
    if (comptime builtin.abi.isGnu()) return sigabbrev_np(sig) orelse "?";
    return "?";
}

fn zeroSet() SigSet {
    return std.mem.zeroes(SigSet);
}

fn signalCount() usize {
    if (comptime builtin.os.tag == .linux) {
        if (comptime builtin.abi.isGnu())
            return @intCast(__libc_current_sigrtmax());
        return @intCast(std.os.linux.sigrtmax());
    }
    return @intCast(std.posix.SIG.RTMAX);
}

export fn fdm_init() ?*Fdm {
    var sigmask = zeroSet();
    if (sigprocmask(0, null, &sigmask) < 0) {
        logErrno(@src(), "failed to get process signal mask", .{});
        return null;
    }

    const epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (epoll_fd == -1) {
        logErrno(@src(), "failed to create epoll FD", .{});
        return null;
    }

    const rtmax = signalCount();

    const rs = calloc(rtmax, @sizeOf(c_int)) orelse {
        logErrno(@src(), "calloc() failed", .{});
        _ = close(epoll_fd);
        return null;
    };
    received_signals = @ptrCast(@alignCast(rs));
    gs().* = 0;

    const raw = malloc(@sizeOf(Fdm)) orelse {
        logErrno(@src(), "malloc() failed", .{});
        _ = close(epoll_fd);
        dropReceivedSignals();
        return null;
    };
    const sh = calloc(rtmax, @sizeOf(SigHandler)) orelse {
        logErrno(@src(), "failed to allocate signal handler array", .{});
        free(raw);
        _ = close(epoll_fd);
        dropReceivedSignals();
        return null;
    };

    const fdm: *Fdm = @ptrCast(@alignCast(raw));
    fdm.* = .{
        .epoll_fd = epoll_fd,
        .is_polling = false,
        .hooks_dispatching = false,
        .fds = .{},
        .deferred = .{},
        .sigmask = sigmask,
        .signal_handlers = @ptrCast(@alignCast(sh)),
        .hooks = .{ .{}, .{}, .{} },
        .events = null,
        .events_cap = 0,
    };
    return fdm;
}

export fn fdm_destroy(fdm_opt: ?*Fdm) void {
    const fdm = fdm_opt orelse return;

    if (fdm.fds.len > 0)
        logWarn(@src(), "FD list not empty", .{});

    const rtmax = signalCount();
    var i: usize = 0;
    while (i < rtmax) : (i += 1) {
        if (fdm.signal_handlers[i].callback != null)
            logWarn(@src(), "handler for signal %d (SIG%s) not removed", .{ @as(c_int, @intCast(i)), sigabbrev(@intCast(i)) });
    }

    if (fdm.hooks[0].len > 0 or fdm.hooks[1].len > 0 or fdm.hooks[2].len > 0)
        logWarn(@src(), "hook list not empty", .{});

    _ = sigprocmask(SIG_SETMASK, &fdm.sigmask, null);
    free(fdm.signal_handlers);

    while (fdm.fds.head) |h| {
        fdm.fds.remove(h);
        free(h);
    }
    while (fdm.deferred.head) |h| {
        fdm.deferred.remove(h);
        free(h);
    }
    for (&fdm.hooks) |*l| {
        while (l.head) |h| {
            l.remove(h);
            free(h);
        }
    }

    _ = close(fdm.epoll_fd);
    if (fdm.events) |e| free(@ptrCast(e));
    free(fdm);

    dropReceivedSignals();
}

export fn fdm_add(fdm: *Fdm, fd: c_int, events: c_int, cb: FdCb, data: ?*anyopaque) bool {
    const raw = malloc(@sizeOf(FdHandler)) orelse {
        logErrno(@src(), "malloc() failed", .{});
        return false;
    };
    const h: *FdHandler = @ptrCast(@alignCast(raw));
    h.* = .{ .fd = fd, .events = events, .callback = cb, .data = data, .deleted = false };

    fdm.fds.pushBack(h);

    var ev = EpollEvent{ .events = @bitCast(events), .data = @intFromPtr(h) };
    if (epoll_ctl(fdm.epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) {
        logErrno(@src(), "failed to register FD=%d with epoll", .{fd});
        fdm.fds.remove(h);
        free(h);
        return false;
    }
    return true;
}

fn delInternal(fdm: *Fdm, fd: c_int, close_fd: bool) bool {
    if (fd == -1)
        return true;

    var it = fdm.fds.head;
    while (it) |h| : (it = h.next) {
        if (h.fd != fd)
            continue;

        if (epoll_ctl(fdm.epoll_fd, EPOLL_CTL_DEL, fd, null) < 0)
            logErrno(@src(), "failed to unregister FD=%d from epoll", .{fd});

        if (close_fd)
            _ = close(h.fd);

        h.deleted = true;
        fdm.fds.remove(h);
        if (fdm.is_polling)
            fdm.deferred.pushBack(h)
        else
            free(h);
        return true;
    }

    logErr(@src(), "no such FD: %d", .{fd});
    _ = close(fd);
    return false;
}

export fn fdm_del(fdm: *Fdm, fd: c_int) bool {
    return delInternal(fdm, fd, true);
}

export fn fdm_del_no_close(fdm: *Fdm, fd: c_int) bool {
    return delInternal(fdm, fd, false);
}

fn eventModify(fdm: *Fdm, h: *FdHandler, new_events: c_int) bool {
    if (new_events == h.events)
        return true;

    var ev = EpollEvent{ .events = @bitCast(new_events), .data = @intFromPtr(h) };
    if (epoll_ctl(fdm.epoll_fd, EPOLL_CTL_MOD, h.fd, &ev) < 0) {
        logErrno(@src(), "failed to modify FD=%d with epoll (events 0x%08x -> 0x%08x)", .{ h.fd, h.events, new_events });
        return false;
    }
    h.events = new_events;
    return true;
}

fn findFd(fdm: *Fdm, fd: c_int) ?*FdHandler {
    var it = fdm.fds.head;
    while (it) |h| : (it = h.next) {
        if (h.fd == fd) return h;
    }
    return null;
}

export fn fdm_event_add(fdm: *Fdm, fd: c_int, events: c_int) bool {
    if (findFd(fdm, fd)) |h|
        return eventModify(fdm, h, h.events | events);
    logErr(@src(), "FD=%d not registered with the FDM", .{fd});
    return false;
}

export fn fdm_event_del(fdm: *Fdm, fd: c_int, events: c_int) bool {
    if (findFd(fdm, fd)) |h|
        return eventModify(fdm, h, h.events & ~events);
    logErr(@src(), "FD=%d not registered with the FDM", .{fd});
    return false;
}

fn hookList(fdm: *Fdm, priority: c_int) *List(Hook) {
    return switch (priority) {
        0 => &fdm.hooks[0],
        1 => &fdm.hooks[1],
        2 => &fdm.hooks[2],
        else => unreachable,
    };
}

export fn fdm_hook_add(fdm: *Fdm, hook: HookCb, data: ?*anyopaque, priority: c_int) bool {
    const raw = malloc(@sizeOf(Hook)) orelse {
        logErrno(@src(), "malloc() failed", .{});
        return false;
    };
    const node: *Hook = @ptrCast(@alignCast(raw));
    node.* = .{ .callback = hook, .data = data };
    hookList(fdm, priority).pushBack(node);
    return true;
}

export fn fdm_hook_del(fdm: *Fdm, hook: HookCb, priority: c_int) bool {
    const list = hookList(fdm, priority);
    var it = list.head;
    while (it) |n| : (it = n.next) {
        if (n.callback != hook or n.deleted)
            continue;
        if (fdm.hooks_dispatching) {
            // A callback that deletes another hook must not free the node
            // runHooks() is walking. Reap it when dispatch ends instead.
            n.deleted = true;
            return true;
        }
        list.remove(n);
        free(n);
        return true;
    }
    logWarn(@src(), "hook=0x%zx not registered", .{@intFromPtr(hook)});
    return false;
}

export fn fdm_signal_add(fdm: *Fdm, signo: c_int, handler: SigCb, data: ?*anyopaque) bool {
    const idx: usize = @intCast(signo);
    if (fdm.signal_handlers[idx].callback != null) {
        logErr(@src(), "signal %d (SIG%s) already has a handler", .{ signo, sigabbrev(signo) });
        return false;
    }

    var mask = zeroSet();
    var original = zeroSet();
    _ = sigemptyset(&mask);
    _ = sigaddset(&mask, signo);

    if (sigprocmask(SIG_BLOCK, &mask, &original) < 0) {
        logErrno(@src(), "failed to block signal %d (SIG%s)", .{ signo, sigabbrev(signo) });
        return false;
    }

    var action = KSigaction{ .handler = .{ .handler = @ptrCast(&signalHandler) }, .mask = zeroSet(), .flags = 0 };
    _ = sigemptyset(&action.mask);
    if (sigaction(signo, &action, null) < 0) {
        logErrno(@src(), "failed to set signal handler for signal %d (SIG%s)", .{ signo, sigabbrev(signo) });
        _ = sigprocmask(SIG_SETMASK, &original, null);
        return false;
    }

    received_signals.?[idx] = 0;
    fdm.signal_handlers[idx] = .{ .callback = handler, .data = data };
    return true;
}

export fn fdm_signal_del(fdm: *Fdm, signo: c_int) bool {
    const idx: usize = @intCast(signo);
    if (fdm.signal_handlers[idx].callback == null)
        return false;

    var action = KSigaction{ .handler = .{ .handler = SIG_DFL }, .mask = zeroSet(), .flags = 0 };
    _ = sigemptyset(&action.mask);
    if (sigaction(signo, &action, null) < 0) {
        logErrno(@src(), "failed to restore signal handler for signal %d (SIG%s)", .{ signo, sigabbrev(signo) });
        return false;
    }

    received_signals.?[idx] = 0;
    fdm.signal_handlers[idx] = .{ .callback = null, .data = null };

    var mask = zeroSet();
    _ = sigemptyset(&mask);
    _ = sigaddset(&mask, signo);
    if (sigprocmask(SIG_UNBLOCK, &mask, null) < 0) {
        logErrno(@src(), "failed to unblock signal %d (SIG%s)", .{ signo, sigabbrev(signo) });
        return false;
    }
    return true;
}

fn runHooks(fdm: *Fdm, list: *List(Hook)) void {
    var it = list.head;
    while (it) |n| {
        const next = n.next;
        if (!n.deleted)
            n.callback(fdm, n.data);
        it = next;
    }
}

fn reapDeletedHooks(fdm: *Fdm) void {
    for (&fdm.hooks) |*list| {
        var it = list.head;
        while (it) |n| {
            const next = n.next;
            if (n.deleted) {
                list.remove(n);
                free(n);
            }
            it = next;
        }
    }
}

export fn fdm_poll(fdm: *Fdm) bool {
    if (fdm.is_polling) {
        logErr(@src(), "nested calls to fdm_poll() not allowed", .{});
        return false;
    }

    fdm.hooks_dispatching = true;
    runHooks(fdm, &fdm.hooks[2]);
    runHooks(fdm, &fdm.hooks[1]);
    runHooks(fdm, &fdm.hooks[0]);
    fdm.hooks_dispatching = false;
    reapDeletedHooks(fdm);

    const n = fdm.fds.len;
    if (n > fdm.events_cap) {
        const old: ?*anyopaque = if (fdm.events) |e| @ptrCast(e) else null;
        const raw = realloc(old, n * @sizeOf(EpollEvent)) orelse {
            logErrno(@src(), "failed to allocate epoll event buffer", .{});
            return false;
        };
        fdm.events = @ptrCast(@alignCast(raw));
        fdm.events_cap = n;
    }

    const r = epoll_pwait(fdm.epoll_fd, fdm.events, @intCast(n), -1, &fdm.sigmask);
    const errno_copy = std.c._errno().*;

    // Signal callbacks may delete handlers already present in the captured
    // event array. Keep those handlers allocated until dispatch has finished.
    fdm.is_polling = true;
    defer {
        fdm.is_polling = false;
        while (fdm.deferred.head) |h| {
            fdm.deferred.remove(h);
            free(h);
        }
    }

    if (gs().* != 0) {
        gs().* = 0;

        const rtmax = signalCount();
        const rs = received_signals.?;
        var i: usize = 0;
        while (i < rtmax) : (i += 1) {
            if (rs[i] != 0) {
                rs[i] = 0;
                const h = &fdm.signal_handlers[i];
                if (!h.callback.?(fdm, @intCast(i), h.data))
                    return false;
            }
        }
    }

    if (r < 0) {
        if (errno_copy == EINTR)
            return true;
        logErrnoP(@src(), errno_copy, "failed to epoll", .{});
        return false;
    }

    var ret = true;
    if (r > 0) {
        const evs = fdm.events.?;
        var i: usize = 0;
        while (i < @as(usize, @intCast(r))) : (i += 1) {
            const h: *FdHandler = @ptrFromInt(@as(usize, @intCast(evs[i].data)));
            if (h.deleted)
                continue;
            if (!h.callback(fdm, h.fd, @bitCast(evs[i].events), h.data)) {
                ret = false;
                break;
            }
        }
    }
    return ret;
}
