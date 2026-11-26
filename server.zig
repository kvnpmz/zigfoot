//! Zig port of server.c: the foot server socket, client handshake and
//! terminal-instance bookkeeping. The private structs live in server.h so
//! the ABI probe can pin them; tll nodes are the C-ABI ones from tll.zig and
//! all allocations use libc malloc/free (C memory is freed with C free).
//!
//! gdb/lldb breakpoints use the original C names, so the FDM callbacks and
//! the two exported socket helpers keep theirs.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xcalloc(count: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;

extern fn close(fd: c_int) callconv(.c) c_int;
extern fn unlink(path: [*:0]const u8) callconv(.c) c_int;
extern fn write(fd: c_int, buf: ?*const anyopaque, count: usize) callconv(.c) isize;
extern fn read(fd: c_int, buf: ?*anyopaque, count: usize) callconv(.c) isize;
extern fn recv(fd: c_int, buf: ?*anyopaque, len: usize, flags: c_int) callconv(.c) isize;

extern fn socket(domain: c_int, type: c_int, protocol: c_int) callconv(.c) c_int;
extern fn connect(fd: c_int, addr: ?*const anyopaque, len: u32) callconv(.c) c_int;
extern fn bind(fd: c_int, addr: ?*const anyopaque, len: u32) callconv(.c) c_int;
extern fn listen(fd: c_int, backlog: c_int) callconv(.c) c_int;
extern fn accept4(
    fd: c_int,
    addr: ?*anyopaque,
    addr_len: ?*u32,
    flags: c_int,
) callconv(.c) c_int;
extern fn getsockopt(
    fd: c_int,
    level: c_int,
    optname: c_int,
    optval: ?*anyopaque,
    optlen: ?*u32,
) callconv(.c) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
extern fn strtol(
    nptr: [*:0]const u8,
    endptr: *?[*:0]u8,
    base: c_int,
) callconv(.c) c_long;

extern fn fdm_add(
    fdm: *anyopaque,
    fd: c_int,
    events: c_int,
    handler: *const fn (*anyopaque, c_int, c_int, ?*anyopaque) callconv(.c) bool,
    data: ?*anyopaque,
) callconv(.c) bool;
extern fn fdm_del(fdm: *anyopaque, fd: c_int) callconv(.c) bool;

extern fn term_init(
    conf: *const types.Config,
    fdm: ?*anyopaque,
    reaper: ?*anyopaque,
    wayl: ?*anyopaque,
    foot_exe: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    token: ?[*:0]const u8,
    pty_path: ?[*:0]const u8,
    slave_argc: c_int,
    slave_argv: ?[*]?[*:0]u8,
    slave_envp: ?[*]?[*:0]const u8,
    foot_argc: c_int,
    foot_argv: ?[*]?[*:0]const u8,
    shutdown_cb: ?*const fn (?*anyopaque, c_int) callconv(.c) void,
    shutdown_data: ?*anyopaque,
) callconv(.c) ?*types.Terminal;
extern fn term_destroy(term: *types.Terminal) callconv(.c) c_int;
extern fn term_shutdown(term: *types.Terminal) callconv(.c) bool;
extern fn term_theme_switch_to_dark(term: *types.Terminal) callconv(.c) void;
extern fn term_theme_switch_to_light(term: *types.Terminal) callconv(.c) void;

extern fn config_clone(old: *const types.Config) callconv(.c) ?*types.Config;
extern fn config_free(conf: *types.Config) callconv(.c) void;
extern fn check_if_font_is_monospaced(
    pattern: [*:0]const u8,
    notifications: *types.UserNotifications,
) callconv(.c) bool;

const Overrides = tll.Tll(?[*:0]u8);

extern fn config_override_apply(
    conf: *types.Config,
    overrides: *Overrides,
    errors_are_fatal: bool,
) callconv(.c) bool;

const builtin = @import("builtin");

// epoll-shim exposes the Linux epoll API on FreeBSD.
const EPOLLIN: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.IN)
else
    0x001;
const EPOLLHUP: c_int = if (builtin.os.tag == .linux)
    @intCast(std.os.linux.EPOLL.HUP)
else
    0x010;
const AF_UNIX: c_int = @intCast(std.posix.AF.UNIX);
const SOCK_STREAM: c_int = @intCast(std.posix.SOCK.STREAM);
const SOCK_CLOEXEC: c_int = if (builtin.os.tag == .linux)
    @as(c_int, 1) << @bitOffsetOf(std.posix.O, "CLOEXEC")
else
    0; // FreeBSD sets FD_CLOEXEC with fcntl() after socket()

const SOCK_NONBLOCK: c_int = if (builtin.os.tag == .linux)
    @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK")
else
    0; // FreeBSD sets O_NONBLOCK with fcntl() after socket()

const FD_CLOEXEC: c_int = std.posix.FD_CLOEXEC;
const F_GETFD: c_int = @intCast(std.posix.F.GETFD);
const F_SETFD: c_int = @intCast(std.posix.F.SETFD);
const F_GETFL: c_int = @intCast(std.posix.F.GETFL);
const F_SETFL: c_int = @intCast(std.posix.F.SETFL);
const SOL_SOCKET: c_int = @intCast(std.posix.SOL.SOCKET);
const SO_DOMAIN: c_int = @intCast(std.posix.SO.DOMAIN);
const SO_ACCEPTCONN: c_int = @intCast(std.posix.SO.ACCEPTCONN);
const SO_TYPE: c_int = @intCast(std.posix.SO.TYPE);
const SIGUSR1: c_int = @backingInt(std.posix.SIG.USR1);
const SIGUSR2: c_int = @backingInt(std.posix.SIG.USR2);
const NON_ZERO_OPT: c_int = @divTrunc(std.math.minInt(c_int), 7);
const MAX_SETUP_SIZE: u32 = 128 * 1024;
const EXIT_CODE_NO_MONITORS: c_int = -26;

const ConnectStatus = enum(c_int) {
    err = 0,
    fail = 1,
    success = 2,
};

fn err(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "%s", msg);
}
fn warn(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_WARNING, "server", "server.zig", @intCast(@src().line), "%s", msg);
}

fn clientList(server: *types.Server) *tll.Tll(?*types.ServerClient) {
    return @ptrCast(@alignCast(&server.clients));
}
fn instanceList(server: *types.Server) *tll.Tll(?*types.TerminalInstance) {
    return @ptrCast(@alignCast(&server.terminals));
}

fn removeClient(server: *types.Server, client: *types.ServerClient) void {
    const list = clientList(server);
    var it = list.foreach();
    while (it.next()) |node| {
        if (node.item == client) {
            list.removeNode(node);
            return;
        }
    }
}

fn removeInstance(server: *types.Server, instance: *types.TerminalInstance) void {
    const list = instanceList(server);
    var it = list.foreach();
    while (it.next()) |node| {
        if (node.item == instance) {
            list.removeNode(node);
            return;
        }
    }
}

fn sendExitCode(client: *types.ServerClient, exit_code: c_int) void {
    if (client.fd == -1)
        return;

    if (write(client.fd, &exit_code, @sizeOf(c_int)) != @sizeOf(c_int))
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to write slave exit code to client");
}

fn instanceDestroy(instance: *types.TerminalInstance, exit_code: c_int) void {
    if (instance.terminal) |term| _ = term_destroy(term);

    if (instance.server) |server|
        removeInstance(server, instance);

    if (instance.client) |client| {
        client.instance = null;
        sendExitCode(client, exit_code);
        clientDestroy(client);
    }

    // TODO: clone the server conf completely, so conf_free() is enough here.
    if (instance.conf) |conf| {
        config_free(conf);
        free(@ptrCast(conf));
    }
    free(@ptrCast(instance));
}

fn clientDestroy(client_ptr: ?*types.ServerClient) void {
    const client = client_ptr orelse return;

    if (client.instance) |instance| {
        warn("client FD: terminal still alive");
        instance.client = null;
        instanceDestroy(instance, 1);
    }

    if (client.fd != -1) {
        if (client.server) |server| {
            if (server.fdm) |fdm|
                _ = fdm_del(@ptrCast(@alignCast(fdm)), client.fd);
        }
    }

    if (client.server) |server|
        removeClient(server, client);

    free(@ptrCast(client.buffer.data));
    free(@ptrCast(client));
}

export fn term_shutdown_handler(data: ?*anyopaque, exit_code: c_int) callconv(.c) void {
    const instance: *types.TerminalInstance = @ptrCast(@alignCast(data orelse return));
    instance.terminal = null;
    instanceDestroy(instance, exit_code);
}

fn freeOverride(s: ?[*:0]u8) callconv(.c) void {
    free(@ptrCast(s));
}

/// Everything the setup parser allocates; cleaned on both the shutdown and
/// the happy path (cleanup() nulls the fields, so a deferred call is a no-op).
const Setup = struct {
    foot_argv: ?[*]?[*:0]const u8 = null,
    slave_argv: ?[*]?[*:0]u8 = null,
    envp: ?[*]?[*:0]const u8 = null,
    overrides: Overrides = .{},

    fn cleanup(self: *Setup) void {
        if (self.foot_argv) |argv| {
            free(@ptrCast(argv));
            self.foot_argv = null;
        }
        if (self.slave_argv) |argv| {
            free(@ptrCast(argv));
            self.slave_argv = null;
        }
        if (self.envp) |env| {
            free(@ptrCast(env));
            self.envp = null;
        }
        self.overrides.freeListAndFree(freeOverride);
    }
};

fn fits(pos: usize, len: usize, end: usize) bool {
    return pos + len <= end;
}

fn fitsString(data: [*]u8, pos: usize, len: usize, end: usize) bool {
    if (len == 0 or !fits(pos, len, end))
        return false;
    return data[pos + len - 1] == 0;
}

fn u16At(data: [*]u8, pos: usize) u16 {
    const bytes: *const [2]u8 = @ptrCast(data + pos);
    return std.mem.readInt(u16, bytes, .little);
}

fn ptrAt(data: [*]u8, pos: usize) [*:0]const u8 {
    return @ptrCast(data + pos);
}

/// Parse the setup packet and instantiate the terminal. Returns true only
/// when the client stays attached to the instance (the no-wait case returns
/// false, which makes the caller take the shutdown path, just like C).
fn parseAndInit(
    server: *types.Server,
    client: *types.ServerClient,
    setup: *Setup,
) bool {
    const data = client.buffer.data orelse return false;
    const end: usize = client.buffer.idx;
    var pos: usize = 0;

    if (!fits(pos, @sizeOf(types.ClientData), end))
        return false;

    const flags = data[0];
    const hold = (flags & 0x01) != 0;
    const no_wait = (flags & 0x02) != 0;
    const xdga_token = (flags & 0x04) != 0;
    const token_len = data[1];
    const exe_len = u16At(data, 2);
    const cwd_len = u16At(data, 4);
    const override_count = u16At(data, 6);
    const foot_argc = u16At(data, 8);
    const slave_argc = u16At(data, 10);
    const env_count = u16At(data, 12);
    pos += @sizeOf(types.ClientData);

    if (!fitsString(data, pos, exe_len, end))
        return false;
    const footclient_exe = ptrAt(data, pos);
    pos += exe_len;

    if (!fitsString(data, pos, cwd_len, end))
        return false;
    const cwd = ptrAt(data, pos);
    pos += cwd_len;

    var token: ?[*:0]const u8 = null;
    if (xdga_token) {
        if (!fitsString(data, pos, token_len, end))
            return false;
        token = ptrAt(data, pos);
        pos += token_len;
    }

    var i: u16 = 0;
    while (i < override_count) : (i += 1) {
        if (!fits(pos, @sizeOf(types.ClientString), end))
            return false;
        const len = u16At(data, pos);
        pos += @sizeOf(types.ClientString);

        if (!fitsString(data, pos, len, end))
            return false;
        const dup = xstrdup(ptrAt(data, pos)) orelse return false;
        pos += len;
        setup.overrides.pushBack(dup);
    }

    const foot_ptrs = @sizeOf(?[*:0]const u8);
    const foot_raw = xcalloc(@as(usize, foot_argc) + 1, foot_ptrs) orelse return false;
    setup.foot_argv = @ptrCast(@alignCast(foot_raw));
    i = 0;
    while (i < foot_argc) : (i += 1) {
        if (!fits(pos, @sizeOf(types.ClientString), end))
            return false;
        const len = u16At(data, pos);
        pos += @sizeOf(types.ClientString);

        if (!fitsString(data, pos, len, end))
            return false;
        setup.foot_argv.?[@intCast(i)] = ptrAt(data, pos);
        pos += len;
    }

    const slave_ptrs = @sizeOf(?[*:0]u8);
    const slave_raw = xcalloc(@as(usize, slave_argc) + 1, slave_ptrs) orelse return false;
    setup.slave_argv = @ptrCast(@alignCast(slave_raw));
    i = 0;
    while (i < slave_argc) : (i += 1) {
        if (!fits(pos, @sizeOf(types.ClientString), end))
            return false;
        const len = u16At(data, pos);
        pos += @sizeOf(types.ClientString);

        if (!fitsString(data, pos, len, end))
            return false;
        setup.slave_argv.?[@intCast(i)] = @constCast(ptrAt(data, pos));
        pos += len;
    }

    var envp: ?[*]?[*:0]const u8 = null;
    if (env_count != 0) {
        const env_raw = xcalloc(@as(usize, env_count) + 1, foot_ptrs) orelse return false;
        envp = @ptrCast(@alignCast(env_raw));
        setup.envp = envp;
    }
    i = 0;
    while (i < env_count) : (i += 1) {
        if (!fits(pos, @sizeOf(types.ClientString), end))
            return false;
        const len = u16At(data, pos);
        pos += @sizeOf(types.ClientString);

        if (!fitsString(data, pos, len, end))
            return false;
        envp.?[@intCast(i)] = ptrAt(data, pos);
        pos += len;
    }

    const base_conf = server.conf orelse return false;
    const need_to_clone_conf = setup.overrides.length > 0 or hold != base_conf.hold_at_exit;

    var conf: ?*types.Config = null;
    if (need_to_clone_conf) {
        conf = config_clone(base_conf);
        if (conf == null)
            return false;

        if (hold != base_conf.hold_at_exit)
            conf.?.hold_at_exit = hold;

        _ = config_override_apply(conf.?, &setup.overrides, false);

        if (conf.?.tweak.font_monospace_warn and conf.?.fonts[0].count > 0) {
            const arr = conf.?.fonts[0].arr orelse return false;
            if (arr[0].pattern) |pattern|
                _ = check_if_font_is_monospaced(pattern, &conf.?.notifications);
        }
    }

    const raw = xmalloc(@sizeOf(types.TerminalInstance)) orelse return false;
    const instance: *types.TerminalInstance = @ptrCast(@alignCast(raw));
    instance.* = .{
        .terminal = null,
        .client = null,
        .server = server,
        .conf = conf,
    };

    instance.terminal = term_init(
        conf orelse base_conf,
        server.fdm,
        server.reaper,
        server.wayl,
        footclient_exe,
        cwd,
        token,
        null,
        @intCast(slave_argc),
        setup.slave_argv,
        envp,
        @intCast(foot_argc),
        setup.foot_argv,
        &term_shutdown_handler,
        instance,
    );

    if (instance.terminal == null) {
        err("failed to instantiate new terminal");
        sendExitCode(client, EXIT_CODE_NO_MONITORS);
        instanceDestroy(instance, -1);
        return false;
    }

    if (no_wait) {
        instanceList(server).pushBack(instance);
        sendExitCode(client, 0);
        return false;
    }

    instance.client = client;
    client.instance = instance;
    setup.cleanup();
    return true;
}

fn shutdownClient(server: *types.Server, client: *types.ServerClient, fd: c_int) void {
    if (client.server) |s| {
        if (s.fdm) |fdm|
            _ = fdm_del(@ptrCast(@alignCast(fdm)), fd);
    } else if (server.fdm) |fdm| {
        _ = fdm_del(@ptrCast(@alignCast(fdm)), fd);
    }

    client.fd = -1;

    if (client.instance) |instance| {
        _ = term_shutdown(instance.terminal orelse return);
    } else {
        clientDestroy(client);
    }
}

export fn fdm_client(
    fdm_ptr: *anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fdm_ptr;
    const client: *types.ServerClient = @ptrCast(@alignCast(data orelse return true));
    const server = client.server orelse return true;
    var setup = Setup{};
    defer setup.cleanup();

    if (events & EPOLLHUP != 0) {
        shutdownClient(server, client, fd);
        return true;
    }

    std.debug.assert(events & EPOLLIN != 0);

    if (client.instance) |instance| {
        var hdr: types.ClientIpcHdr = undefined;
        var hdr_bytes: [@sizeOf(types.ClientIpcHdr)]u8 = undefined;
        const hdr_count = read(fd, &hdr_bytes, hdr_bytes.len);
        if (hdr_count != hdr_bytes.len) {
            warn("client unexpectedly sent data");
            return true;
        }
        hdr = std.mem.bytesToValue(types.ClientIpcHdr, &hdr_bytes);

        const ipc_code = std.mem.readInt(u32, &hdr.ipc_code, .little);
        switch (ipc_code) {
            0 => { // FOOT_IPC_SIGUSR
                var sigusr_bytes: [@sizeOf(types.ClientIpcSigusr)]u8 = undefined;
                const count = read(fd, &sigusr_bytes, sigusr_bytes.len);
                if (count < 0) {
                    log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to read SIGUSR IPC data from client");
                    return true;
                }
                if (count != sigusr_bytes.len) {
                    err("failed to read SIGUSR IPC data from client");
                    return true;
                }
                const sigusr = std.mem.bytesToValue(types.ClientIpcSigusr, &sigusr_bytes);
                const term = instance.terminal orelse return true;

                switch (@as(c_int, @bitCast(sigusr.signo))) {
                    SIGUSR1 => term_theme_switch_to_dark(term),
                    SIGUSR2 => term_theme_switch_to_light(term),
                    else => log_msg(
                        LOG_CLASS_ERROR,
                        "server",
                        "server.zig",
                        @intCast(@src().line),
                        "client sent bad SIGUSR number: %d (expected SIGUSR1=%d or SIGUSR2=%d)",
                        @as(c_int, @bitCast(sigusr.signo)),
                        SIGUSR1,
                        SIGUSR2,
                    ),
                }
            },
            else => {
                log_msg(
                    LOG_CLASS_WARNING,
                    "server",
                    "server.zig",
                    @intCast(@src().line),
                    "client sent unrecognized IPC (0x%04x), ignoring %hhu bytes",
                    ipc_code,
                    hdr.size,
                );
                // Drain the advertised payload; C could not know whether all
                // of it had arrived yet, so this is best-effort here too.
                var dummy: [256]u8 = undefined;
                const n: usize = @min(hdr.size, dummy.len);
                _ = read(fd, &dummy, n);
            },
        }
        return true;
    }

    // First packet: the total size of the initialization data.
    if (client.buffer.data == null) {
        var total: u32 = 0;
        const count = recv(fd, &total, @sizeOf(u32), 0);
        if (count < 0) {
            log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to read total length");
            shutdownClient(server, client, fd);
            return true;
        }
        if (count != @sizeOf(u32)) {
            err("client did not send setup packet size");
            shutdownClient(server, client, fd);
            return true;
        }
        if (total > MAX_SETUP_SIZE) {
            err("client wants to send too large setup packet");
            shutdownClient(server, client, fd);
            return true;
        }

        const raw = xmalloc(@as(usize, total) + 1) orelse return true;
        const buf = @as([*]u8, @ptrCast(@alignCast(raw)));
        buf[total] = 0; // keep strlen() inside the buffer
        client.buffer.data = buf;
        client.buffer.left = total;
        client.buffer.idx = 0;
        return true;
    }

    const buf = client.buffer.data orelse return true;
    const count = recv(fd, buf + client.buffer.idx, client.buffer.left, 0);
    if (count < 0) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to read");
        shutdownClient(server, client, fd);
        return true;
    }

    client.buffer.idx += @intCast(count);
    client.buffer.left -= @intCast(count);
    if (client.buffer.left > 0)
        return true;

    const wayl: *types.Wayland = @ptrCast(@alignCast(server.wayl orelse {
        err("no monitors available for new terminal");
        sendExitCode(client, EXIT_CODE_NO_MONITORS);
        shutdownClient(server, client, fd);
        return true;
    }));
    const monitors: *const types.Tll(types.Monitor) = @ptrCast(@alignCast(&wayl.monitors));
    if (monitors.length == 0) {
        err("no monitors available for new terminal");
        sendExitCode(client, EXIT_CODE_NO_MONITORS);
        shutdownClient(server, client, fd);
        return true;
    }

    if (!parseAndInit(server, client, &setup)) {
        shutdownClient(server, client, fd);
        return true;
    }
    return true;
}

export fn fdm_server(
    fdm_ptr: *anyopaque,
    fd: c_int,
    events: c_int,
    data: ?*anyopaque,
) callconv(.c) bool {
    _ = fdm_ptr;
    _ = fd;
    if (events & EPOLLHUP != 0)
        return false;

    const server: *types.Server = @ptrCast(@alignCast(data orelse return false));

    var addr: types.SockaddrUn = undefined;
    var addr_len: u32 = @sizeOf(types.SockaddrUn);
    const client_fd = accept4(
        server.fd,
        &addr,
        &addr_len,
        SOCK_CLOEXEC | SOCK_NONBLOCK,
    );
    if (client_fd == -1) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to accept client connection");
        return false;
    }

    const raw = xmalloc(@sizeOf(types.ServerClient)) orelse {
        _ = close(client_fd);
        return false;
    };
    const client: *types.ServerClient = @ptrCast(@alignCast(raw));
    client.* = .{
        .server = server,
        .fd = client_fd,
        .buffer = .{ .data = null, .left = 0, .idx = 0 },
        .instance = null,
    };

    if (server.fdm == null or !fdm_add(
        @ptrCast(@alignCast(server.fdm.?)),
        client_fd,
        EPOLLIN,
        &fdm_client,
        client,
    )) {
        _ = close(client_fd);
        free(raw);
        return false;
    }

    clientList(server).pushBack(client);
    return true;
}

fn copySockPath(addr: *types.SockaddrUn, sock_path: [*:0]const u8) void {
    const path = std.mem.span(sock_path);
    const n = @min(path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..n], path[0..n]);
    addr.sun_path[n] = 0;
}

fn tryConnect(sock_path: [*:0]const u8) ConnectStatus {
    const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd == -1) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to create UNIX socket");
        return .err;
    }
    defer _ = close(fd);

    var addr = std.mem.zeroes(types.SockaddrUn);
    addr.sun_family = AF_UNIX;
    copySockPath(&addr, sock_path);

    return switch (connect(fd, &addr, @sizeOf(types.SockaddrUn))) {
        0 => .success,
        -1 => .fail,
        else => .err,
    };
}

/// Exported under its C name so the harness can compare it with the macros.
export fn server_try_connect(sock_path: [*:0]const u8) callconv(.c) c_int {
    return @backingInt(tryConnect(sock_path));
}

fn setSocketFdFlags(fd: c_int) bool {
    var flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to get file descriptors flag for passed socket");
        return false;
    }
    if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to set FD_CLOEXEC for passed socket");
        return false;
    }

    flags = fcntl(fd, F_GETFL);
    if (flags < 0) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to get file status flags for passed socket");
        return false;
    }
    if (fcntl(fd, F_SETFL, flags | @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK")) == -1) {
        log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to set non-blocking mode on passed socket");
        return false;
    }

    return true;
}

export fn prepare_socket(fd: c_int) callconv(.c) bool {
    if (!setSocketFdFlags(fd))
        return false;

    const options = [_]c_int{ SO_DOMAIN, SO_ACCEPTCONN, SO_TYPE };
    const expected = [_]c_int{ AF_UNIX, NON_ZERO_OPT, SOCK_STREAM };
    const names = [_][*:0]const u8{ "SO_DOMAIN", "SO_ACCEPTCONN", "SO_TYPE" };

    for (options, expected, names) |opt, want, name| {
        var value: c_int = 0;
        var len: u32 = @sizeOf(c_int);
        if (getsockopt(fd, SOL_SOCKET, opt, &value, &len) == -1 or
            len != @sizeOf(c_int))
        {
            log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to read socket option from passed file descriptor");
            return false;
        }
        if (want == NON_ZERO_OPT and value != 0)
            value = NON_ZERO_OPT;
        if (value != want) {
            log_msg(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "wrong socket value for socket option '%s' on passed file descriptor", name);
            return false;
        }
    }
    return true;
}

fn initFail(server: ?*types.Server, fd: c_int) ?*types.Server {
    if (server) |s|
        free(s);
    if (fd != -1)
        _ = close(fd);
    return null;
}

export fn server_init(
    conf_ptr: ?*types.Config,
    fdm_ptr: ?*anyopaque,
    reaper: ?*anyopaque,
    wayl: ?*anyopaque,
) callconv(.c) ?*types.Server {
    const conf = conf_ptr orelse return null;
    const configured_path = conf.server_socket_path orelse return null;

    var fd: c_int = -1;
    var sock_path: ?[*:0]const u8 = configured_path;
    var end: ?[*:0]u8 = null;
    _ = strtol(configured_path, &end, 10);

    const numeric_fd = if (end) |e| e[0] == 0 and configured_path[0] != 0 else false;
    if (numeric_fd) {
        // C assigns strtol()'s long to an int: truncate, do not trap.
        const pid_long = strtol(configured_path, &end, 10);
        fd = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(pid_long)))));
        if (!prepare_socket(fd))
            return initFail(null, fd);
        sock_path = null;
    } else {
        fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd == -1) {
            log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to create UNIX socket");
            return null;
        }
        if (builtin.os.tag != .linux and !setSocketFdFlags(fd))
            return initFail(null, fd);

        switch (tryConnect(configured_path)) {
            .fail => {},
            .success => err("socket is already accepting connections"),
            .err => return initFail(null, fd),
        }

        _ = unlink(configured_path);

        var addr = std.mem.zeroes(types.SockaddrUn);
        addr.sun_family = AF_UNIX;
        copySockPath(&addr, configured_path);

        if (bind(fd, &addr, @sizeOf(types.SockaddrUn)) < 0) {
            log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to bind socket");
            return initFail(null, fd);
        }
        if (listen(fd, 0) < 0) {
            log_errno(LOG_CLASS_ERROR, "server", "server.zig", @intCast(@src().line), "failed to listen on socket");
            return initFail(null, fd);
        }
    }

    const raw = std.c.malloc(@sizeOf(types.Server)) orelse
        return initFail(null, fd);
    const server: *types.Server = @ptrCast(@alignCast(raw));
    server.* = .{
        .conf = conf,
        .fdm = fdm_ptr,
        .reaper = reaper,
        .wayl = wayl,
        .fd = fd,
        .sock_path = sock_path,
        .clients = .{ .head = null, .tail = null, .length = 0 },
        .terminals = .{ .head = null, .tail = null, .length = 0 },
    };

    if (fdm_ptr == null or !fdm_add(
        @ptrCast(@alignCast(fdm_ptr.?)),
        fd,
        EPOLLIN,
        &fdm_server,
        server,
    ))
        return initFail(server, fd);

    return server;
}

export fn server_destroy(server_ptr: ?*types.Server) callconv(.c) void {
    const server = server_ptr orelse return;

    var clients = clientList(server).foreach();
    while (clients.next()) |node| {
        if (node.item) |client|
            sendExitCode(client, EXIT_CODE_NO_MONITORS);
    }

    clients = clientList(server).foreach();
    while (clients.next()) |node| {
        if (node.item) |client|
            clientDestroy(client);
    }
    clientList(server).freeList();

    var instances = instanceList(server).foreach();
    while (instances.next()) |node| {
        if (node.item) |instance|
            instanceDestroy(instance, 1);
    }
    instanceList(server).freeList();

    if (server.fdm) |fdm|
        _ = fdm_del(@ptrCast(@alignCast(fdm)), server.fd);

    if (server.sock_path) |path|
        _ = unlink(path);

    free(@ptrCast(server));
}

fn switchAll(
    server: *types.Server,
    theme: types.WhichColorTheme,
    comptime switchFn: *const fn (*types.Terminal) callconv(.c) void,
) void {
    if (server.conf) |conf|
        conf.initial_color_theme = theme;

    var clients = clientList(server).foreach();
    while (clients.next()) |node| {
        if (node.item) |client| {
            if (client.instance) |instance| {
                if (instance.terminal) |term|
                    switchFn(term);
            }
        }
    }

    var instances = instanceList(server).foreach();
    while (instances.next()) |node| {
        if (node.item) |instance| {
            if (instance.terminal) |term|
                switchFn(term);
        }
    }
}

export fn server_global_theme_switch_to_dark(server: *types.Server) callconv(.c) void {
    switchAll(server, .dark, &term_theme_switch_to_dark);
}

export fn server_global_theme_switch_to_light(server: *types.Server) callconv(.c) void {
    switchAll(server, .light, &term_theme_switch_to_light);
}
