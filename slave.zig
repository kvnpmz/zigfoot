const std = @import("std");
const types = @import("terminal_types.zig");
const build_options = @import("build_options");

//
// slave.c ported to Zig: the fork/exec of the child process that becomes the
// shell running inside foot, its environment setup, shell validation and the
// user-notification banner written to the pty.
//
// Signal-mask/handler restoration is Zig now. The configured terminfo path
// arrives through build_options. Only execvpe() stays in C because Zig 0.16
// has no execvpeZ(), and its portable PATH-search fallback must use the
// caller-provided environment.
//

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_DEBUG: c_int = 4;

const libc = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno_provided(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, err_no: c_int, fmt: [*:0]const u8, ...) void;

extern fn tokenize_cmdline(cmdline: [*c]const u8, argv: *[*c][*c]u8) bool;
extern fn getline(lineptr: *?[*]u8, n: *usize, stream: *std.c.FILE) isize;

const SlaveConstants = extern struct {
    o_rdwr: c_int,
    o_cloexec: c_int,
    o_nonblock: c_int,
    f_getfl: c_int,
    f_setfl: c_int,
    f_getfd: c_int,
    f_setfd: c_int,
    fd_cloexec: c_int,
    f_ok: c_int,
    stdin_fileno: c_int,
    stdout_fileno: c_int,
    stderr_fileno: c_int,
    cs_path: c_int,
    tiocsctty: c_ulong,
};

// These values are C macros and differ per platform. Read them from the
// target libc headers, then expose the same private struct to the C harness.
const O_RDWR: c_int = @intFromEnum(std.posix.ACCMODE.RDWR);
const O_CLOEXEC: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "CLOEXEC");
const O_NONBLOCK: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
const F_GETFL: c_int = @intCast(std.posix.F.GETFL);
const F_SETFL: c_int = @intCast(std.posix.F.SETFL);
const F_GETFD: c_int = @intCast(std.posix.F.GETFD);
const F_SETFD: c_int = @intCast(std.posix.F.SETFD);
const FD_CLOEXEC: c_int = std.posix.FD_CLOEXEC;
const F_OK: c_int = @intCast(std.posix.F_OK);
const STDIN_FILENO: c_int = std.posix.STDIN_FILENO;
const STDOUT_FILENO: c_int = std.posix.STDOUT_FILENO;
const STDERR_FILENO: c_int = std.posix.STDERR_FILENO;
const CS_PATH: c_int = libc._CS_PATH;
const TIOCSCTTY: c_ulong = libc.TIOCSCTTY;

const constants = SlaveConstants{
    .o_rdwr = O_RDWR,
    .o_cloexec = O_CLOEXEC,
    .o_nonblock = O_NONBLOCK,
    .f_getfl = F_GETFL,
    .f_setfl = F_SETFL,
    .f_getfd = F_GETFD,
    .f_setfd = F_SETFD,
    .fd_cloexec = FD_CLOEXEC,
    .f_ok = F_OK,
    .stdin_fileno = STDIN_FILENO,
    .stdout_fileno = STDOUT_FILENO,
    .stderr_fileno = STDERR_FILENO,
    .cs_path = CS_PATH,
    .tiocsctty = TIOCSCTTY,
};

export fn slave_shim_constants() *const SlaveConstants {
    return &constants;
}

// libc's tcgetattr()/tcsetattr(), rather than std.posix: the latter turns
// EBADF/ENOTTY into unreachable, while the C shim's contract is "1 if the
// attributes cannot be read, 2 if they cannot be written".
extern fn tcgetattr(fd: c_int, termios: *std.posix.termios) c_int;
extern fn tcsetattr(fd: c_int, action: c_int, termios: *const std.posix.termios) c_int;
const TCSANOW: c_int = @intFromEnum(std.posix.TCSA.NOW);

/// Enable IUTF8 on the pty slave: return 0 on success, 1 if the attributes
/// cannot be read, 2 if they cannot be written (the C shim's contract).
export fn slave_shim_set_iutf8(pts: c_int) c_int {
    if (comptime !@hasField(std.posix.tc_iflag_t, "IUTF8"))
        return 0; // the C shim compiles this step out when IUTF8 is undefined

    if (comptime !@hasField(std.posix.tc_iflag_t, "IUTF8"))
        return 0; // the C shim compiles this step out when IUTF8 is undefined

    var flags: std.posix.termios = undefined;
    if (tcgetattr(pts, &flags) < 0)
        return 1;

    flags.iflag.IUTF8 = true;
    if (tcsetattr(pts, TCSANOW, &flags) < 0)
        return 2;

    return 0;
}

const SigSet = std.c.sigset_t;
const Sigaction = std.c.Sigaction;
extern fn sigemptyset(set: *SigSet) c_int;
extern fn sigprocmask(how: c_int, set: ?*const SigSet, old: ?*SigSet) c_int;
extern fn sigaction(sig: c_int, act: ?*const Sigaction, old: ?*Sigaction) c_int;

/// Restore the child signal mask and the SIGHUP/SIGPIPE handlers. The
/// caller checks the returned status and reports the libc error.
export fn slave_shim_reset_signals() bool {
    var dfl = Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.mem.zeroes(SigSet),
        .flags = 0,
    };
    var mask = std.mem.zeroes(SigSet);
    _ = sigemptyset(&dfl.mask);
    _ = sigemptyset(&mask);
    if (sigprocmask(std.posix.SIG.SETMASK, &mask, null) < 0 or
        sigaction(@intFromEnum(std.posix.SIG.HUP), &dfl, null) < 0 or
        sigaction(@intFromEnum(std.posix.SIG.PIPE), &dfl, null) < 0)
    {
        return false;
    }
    return true;
}

export fn slave_shim_terminfo_path() ?[*:0]const u8 {
    const path = build_options.foot_terminfo_path;
    if (path.len == 0)
        return null;
    return path.ptr;
}

extern fn slave_shim_execvpe(
    file: [*:0]const u8,
    argv: [*]?[*:0]u8,
    envp: [*]?[*:0]u8,
) c_int;

extern fn fork() c_int;
extern fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern fn setsid() c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;
extern fn strdup(s: [*:0]const u8) ?[*:0]u8;
extern fn ptsname(fd: c_int) ?[*:0]u8;
extern fn grantpt(fd: c_int) c_int;
extern fn unlockpt(fd: c_int) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern var environ: [*]?[*:0]u8;

fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{
        LOG_CLASS_ERROR,
        "slave",
        "slave.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn logDbg(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{
        LOG_CLASS_DEBUG,
        "slave",
        "slave.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn logErrno(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_errno, .{
        LOG_CLASS_ERROR,
        "slave",
        "slave.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn logErrnoProvided(err_no: c_int, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_errno_provided, .{
        LOG_CLASS_ERROR,
        "slave",
        "slave.zig",
        @as(c_int, @intCast(@src().line)),
        err_no,
        fmt,
    } ++ args);
}

fn errno() c_int {
    return std.c._errno().*;
}

fn mallocOrAbort(size: usize) *anyopaque {
    return std.c.malloc(size) orelse @panic("out of memory");
}

fn callocOrAbort(count: usize, size: usize) *anyopaque {
    return std.c.calloc(count, size) orelse @panic("out of memory");
}

fn xstrdup(s: [*:0]const u8) [*:0]u8 {
    return strdup(s) orelse @panic("out of memory");
}

// ── /etc/shells validation ──────────────────────────────────────────

fn isValidShell(shell: [*:0]const u8) bool {
    const f = std.c.fopen("/etc/shells", "r") orelse return false;
    defer _ = std.c.fclose(f);

    const want = std.mem.span(shell);

    var line_buf: ?[*]u8 = null;
    var line_cap: usize = 0;
    defer if (line_buf) |buf| std.c.free(buf);

    while (true) {
        const ret = getline(&line_buf, &line_cap, f);
        if (ret < 0)
            return false;

        var line: []const u8 = line_buf.?[0..@intCast(ret)];

        line = std.mem.trimStart(u8, line, &std.ascii.whitespace);
        if (line.len > 0)
            line = std.mem.trimEnd(u8, line, &std.ascii.whitespace);

        if (line.len > 0 and line[0] == '#')
            continue;

        if (std.mem.eql(u8, line, want))
            return true;
    }
}

// ── user-notification banner ────────────────────────────────────────

const UnResult = enum { ok, no_more, fail };

fn isWouldBlock(e: c_int) bool {
    // EWOULDBLOCK == EAGAIN on Linux; only EAGAIN exists in std.c.E.
    return e == @intFromEnum(std.c.E.AGAIN);
}

fn writeStr(fd: c_int, s: []const u8) bool {
    // Note: like the C code, this only treats `write() < 0` as an error and
    // does not bother with partial writes.
    return std.c.write(fd, s.ptr, s.len) >= 0;
}

fn emitOneNotification(fd: c_int, notif: *const types.UserNotification) UnResult {
    const prefix: []const u8 = switch (notif.kind) {
        .deprecated => "\x1b[33;1mdeprecated\x1b[39;22m: ",
        .warning => "\x1b[33;1mwarning\x1b[39;22m: ",
        .err => "\x1b[31;1merror\x1b[39;22m: ",
    };

    const postfix = "\x1b[m\n";
    const text: []const u8 = if (notif.text) |t| std.mem.span(t) else "";

    if (!writeStr(fd, prefix) or
        !writeStr(fd, "foot: ") or
        !writeStr(fd, text) or
        !writeStr(fd, postfix))
    {
        // The main process is blocking and waiting for us to close the error
        // pipe, so once the kernel buffer is full we cannot write anymore.
        // Don't treat that as a fatal error.
        if (isWouldBlock(errno()))
            return .no_more;

        logErrno("failed to write user-notification", .{});
        return .fail;
    }

    return .ok;
}

fn emitNotificationsOfKind(
    fd: c_int,
    notifications: *const types.UserNotifications,
    kind: types.UserNotificationKind,
) bool {
    var node: ?*types.UserNotificationNode = notifications.head;
    while (node) |n| : (node = n.next) {
        if (n.item.kind != kind)
            continue;

        switch (emitOneNotification(fd, &n.item)) {
            .ok => {},
            .no_more => return true,
            .fail => return false,
        }
    }

    return true;
}

fn emitNotifications(
    fd: c_int,
    notifications: *const types.UserNotifications,
) bool {
    return emitNotificationsOfKind(fd, notifications, .err) and
        emitNotificationsOfKind(fd, notifications, .warning) and
        emitNotificationsOfKind(fd, notifications, .deprecated);
}

// ── the child ───────────────────────────────────────────────────────

fn slaveExec(
    ptmx_in: c_int,
    argv: [*]?[*:0]u8,
    envp: [*]?[*:0]u8,
    err_fd: c_int,
    login_shell: bool,
    notifications: *const types.UserNotifications,
) noreturn {
    const c = slave_shim_constants().*;

    var ptmx = ptmx_in;
    var child_errno: c_int = 0;
    var pts: c_int = -1;

    exec: {
        const pts_name = ptsname(ptmx) orelse {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to get the pseudo terminal slave device name", .{});
            break :exec;
        };

        if (grantpt(ptmx) == -1) {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to grantpt()", .{});
            break :exec;
        }
        if (unlockpt(ptmx) == -1) {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to unlockpt()", .{});
            break :exec;
        }

        _ = std.c.close(ptmx);
        ptmx = -1;

        if (setsid() == -1) {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to setsid()", .{});
            break :exec;
        }

        pts = open(pts_name, c.o_rdwr);
        if (pts == -1) {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to open pseudo terminal slave device", .{});
            break :exec;
        }

        if (ioctl(pts, c.tiocsctty, @as(c_int, 0)) < 0) {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to configure controlling terminal", .{});
            break :exec;
        }

        switch (slave_shim_set_iutf8(pts)) {
            0 => {},
            1 => {
                child_errno = errno();
                logErrnoProvided(child_errno, "failed to get terminal attributes", .{});
                break :exec;
            },
            2 => {
                child_errno = errno();
                logErrnoProvided(child_errno, "failed to set IUTF8 terminal attribute", .{});
                break :exec;
            },
            else => unreachable,
        }

        if (notifications.length > 0) {
            const flags = fcntl(pts, c.f_getfl);
            if (flags < 0) {
                child_errno = errno();
                break :exec;
            }
            if (fcntl(pts, c.f_setfl, flags | c.o_nonblock) < 0) {
                child_errno = errno();
                break :exec;
            }

            if (!emitNotifications(pts, notifications)) {
                child_errno = errno();
                break :exec;
            }

            _ = fcntl(pts, c.f_setfl, flags);
        }

        if (std.c.dup2(pts, c.stdin_fileno) == -1 or
            std.c.dup2(pts, c.stdout_fileno) == -1 or
            std.c.dup2(pts, c.stderr_fileno) == -1)
        {
            child_errno = errno();
            logErrnoProvided(child_errno, "failed to dup stdin/stdout/stderr", .{});
            break :exec;
        }

        _ = std.c.close(pts);
        pts = -1;

        var file: [*:0]const u8 = undefined;
        if (login_shell) {
            const arg0_orig = argv[0].?;
            file = xstrdup(arg0_orig);

            const len = std.mem.len(arg0_orig);
            const arg0: [*:0]u8 = @ptrCast(mallocOrAbort(len + 2));
            arg0[0] = '-';
            @memcpy(arg0[1 .. len + 1], arg0_orig[0..len]);
            arg0[len + 1] = 0;

            argv[0] = arg0;
        } else {
            file = argv[0].?;
        }

        _ = slave_shim_execvpe(file, argv, envp);
        child_errno = errno();
        // Getting here is an error
    }

    const err_no = child_errno;
    _ = std.c.write(err_fd, @as([*]const u8, @ptrCast(&err_no)), @sizeOf(c_int));
    if (pts != -1)
        _ = std.c.close(pts);
    if (ptmx != -1)
        _ = std.c.close(ptmx);
    _ = std.c.close(err_fd);
    logErrnoProvided(err_no, "failed to spawn child", .{});
    std.c._exit(err_no);
}

// ── environment list ────────────────────────────────────────────────

const Environ = struct {
    count: usize,
    envp: ?[*]?[*:0]u8,
};

fn envMatchesVarName(e: [*:0]const u8, name: [*:0]const u8) bool {
    const e_len = std.mem.len(e);
    const name_len = std.mem.len(name);

    if (e_len <= name_len)
        return false;
    if (!std.mem.eql(u8, e[0..name_len], name[0..name_len]))
        return false;
    if (e[name_len] != '=')
        return false;
    return true;
}

fn joinEq(name: [*:0]const u8, value: [*:0]const u8) [*:0]u8 {
    const name_len = std.mem.len(name);
    const value_len = std.mem.len(value);

    const buf: [*:0]u8 = @ptrCast(mallocOrAbort(name_len + 1 + value_len + 1));
    @memcpy(buf[0..name_len], name[0..name_len]);
    buf[name_len] = '=';
    @memcpy(buf[name_len + 1 .. name_len + 1 + value_len], value[0..value_len]);
    buf[name_len + 1 + value_len] = 0;
    return buf;
}

fn addToEnv(env: *Environ, name: [*:0]const u8, value: [*:0]const u8) void {
    if (env.envp == null) {
        _ = setenv(name, value, 1);
        return;
    }

    const e = joinEq(name, value);

    // Search for an existing variable. If found, replace it with the new
    // value.
    for (0..env.count) |i| {
        const existing = env.envp.?[i].?;
        if (envMatchesVarName(existing, name)) {
            std.c.free(existing);
            env.envp.?[i] = e;
            return;
        }
    }

    // If the variable does not already exist, add it.
    env.envp = @ptrCast(@alignCast(std.c.realloc(@ptrCast(env.envp.?), (env.count + 2) * @sizeOf(?[*:0]u8)) orelse
        @panic("out of memory")));
    env.envp.?[env.count] = e;
    env.count += 1;
    env.envp.?[env.count] = null;
}

fn delFromEnv(env: *Environ, name: [*:0]const u8) void {
    if (env.envp == null) {
        _ = unsetenv(name);
        return;
    }

    for (0..env.count) |i| {
        const e = env.envp.?[i].?;
        if (!envMatchesVarName(e, name))
            continue;

        std.c.free(e);

        const rest = env.count - i;
        var j: usize = 0;
        while (j < rest) : (j += 1)
            env.envp.?[i + j] = env.envp.?[i + j + 1];

        env.count -= 1;
        std.debug.assert(env.envp.?[env.count] == null);
        break;
    }
}

// ── the parent ──────────────────────────────────────────────────────

export fn slave_spawn(
    ptmx: c_int,
    argc: c_int,
    cwd: [*:0]const u8,
    argv: ?[*]?[*:0]u8,
    envp: ?[*]?[*:0]const u8,
    extra_env_vars: ?*const types.EnvVarList,
    term_env: [*:0]const u8,
    conf_shell: [*:0]const u8,
    login_shell: bool,
    notifications: *const types.UserNotifications,
) callconv(.c) c_int {
    const c = slave_shim_constants().*;

    var fork_pipe: [2]c_int = undefined;
    if (pipe2(&fork_pipe, c.o_cloexec) < 0) {
        logErrno("failed to create pipe", .{});
        return -1;
    }

    const pid = fork();
    switch (pid) {
        -1 => {
            logErrno("failed to fork", .{});
            _ = std.c.close(fork_pipe[0]);
            _ = std.c.close(fork_pipe[1]);
            return -1;
        },

        0 => {
            // Child
            _ = std.c.close(fork_pipe[0]); // Close read end

            if (std.c.chdir(cwd) < 0) {
                const errno_copy = errno();
                logErrno("failed to change working directory to %s", .{cwd});
                _ = std.c.write(fork_pipe[1], @as([*]const u8, @ptrCast(&errno_copy)), @sizeOf(c_int));
                std.c._exit(errno_copy);
            }

            // Restore signal mask, and SIG_IGN'd signals
            if (!slave_shim_reset_signals()) {
                const errno_copy = errno();
                logErrnoProvided(errno_copy, "failed to restore signals", .{});
                _ = std.c.write(fork_pipe[1], @as([*]const u8, @ptrCast(&errno_copy)), @sizeOf(c_int));
                std.c._exit(errno_copy);
            }

            // Create a mutable copy of the environment
            var custom_env: Environ = .{ .count = 0, .envp = null };
            if (envp) |env| {
                while (env[custom_env.count] != null)
                    custom_env.count += 1;

                const envp_copy: [*]?[*:0]u8 = @ptrCast(@alignCast(callocOrAbort(
                    custom_env.count + 1,
                    @sizeOf(?[*:0]u8),
                )));
                custom_env.envp = envp_copy;

                var i: usize = 0;
                while (env[i]) |e| : (i += 1)
                    envp_copy[i] = xstrdup(@ptrCast(e));
                std.debug.assert(envp_copy[custom_env.count] == null);
            }

            addToEnv(&custom_env, "TERM", term_env);
            addToEnv(&custom_env, "COLORTERM", "truecolor");
            addToEnv(&custom_env, "PWD", cwd);

            delFromEnv(&custom_env, "TERM_PROGRAM"); // Wezterm, Ghostty
            delFromEnv(&custom_env, "TERM_PROGRAM_VERSION"); // Wezterm, Ghostty
            delFromEnv(&custom_env, "TERMINAL_NAME"); // Contour
            delFromEnv(&custom_env, "TERMINAL_VERSION_STRING"); // Contour
            delFromEnv(&custom_env, "TERMINAL_VERSION_TRIPLE"); // Contour

            // XTerm specific
            delFromEnv(&custom_env, "XTERM_SHELL");
            delFromEnv(&custom_env, "XTERM_VERSION");
            delFromEnv(&custom_env, "XTERM_LOCALE");

            // Mlterm specific
            delFromEnv(&custom_env, "MLTERM");

            // Zutty specific
            delFromEnv(&custom_env, "ZUTTY_VERSION");

            // Ghostty specific
            delFromEnv(&custom_env, "GHOSTTY_BIN_DIR");
            delFromEnv(&custom_env, "GHOSTTY_SHELL_INTEGRATION_NO_SUDO");
            delFromEnv(&custom_env, "GHOSTTY_RESOURCES_DIR");

            // Kitty specific
            delFromEnv(&custom_env, "KITTY_WINDOW_ID");
            delFromEnv(&custom_env, "KITTY_PID");
            delFromEnv(&custom_env, "KITTY_PUBLIC_KEY");
            delFromEnv(&custom_env, "KITTY_INSTALLATION_DIR");

            // Contour specific
            delFromEnv(&custom_env, "CONTOUR_PROFILE");

            // Wezterm specific
            delFromEnv(&custom_env, "WEZTERM_PANE");
            delFromEnv(&custom_env, "WEZTERM_EXECUTABLE");
            delFromEnv(&custom_env, "WEZTERM_CONFIG_FILE");
            delFromEnv(&custom_env, "WEZTERM_EXECUTABLE_DIR");
            delFromEnv(&custom_env, "WEZTERM_UNIX_SOCKET");
            delFromEnv(&custom_env, "WEZTERM_CONFIG_DIR");

            // Alacritty specific
            delFromEnv(&custom_env, "ALACRITTY_LOG");
            delFromEnv(&custom_env, "ALACRITTY_WINDOW_ID");
            delFromEnv(&custom_env, "ALACRITTY_SOCKET");

            // VTE, gnome-terminal, kgx etc
            delFromEnv(&custom_env, "VTE_VERSION");
            delFromEnv(&custom_env, "GNOME_TERMINAL_SERVICE");
            delFromEnv(&custom_env, "GNOME_TERMINAL_SCREEN");

            if (slave_shim_terminfo_path()) |terminfo_path|
                addToEnv(&custom_env, "TERMINFO", terminfo_path);

            if (extra_env_vars) |vars| {
                var node: ?*types.EnvVarNode = vars.head;
                while (node) |n| : (node = n.next) {
                    const name = n.item.name orelse continue;
                    const value = n.item.value orelse continue;

                    if (std.mem.len(value) == 0)
                        delFromEnv(&custom_env, name)
                    else
                        addToEnv(&custom_env, name, value);
                }
            }

            var shell_argv: [*]?[*:0]u8 = undefined;

            if (argc == 0) {
                var tokenized: [*c][*c]u8 = null;
                if (!tokenize_cmdline(conf_shell, &tokenized)) {
                    _ = std.c.write(
                        fork_pipe[1],
                        @as([*]const u8, @ptrCast(std.c._errno())),
                        @sizeOf(c_int),
                    );
                    std.c._exit(0);
                }
                shell_argv = @ptrCast(tokenized);
            } else {
                const cmd_argv = argv.?;

                var count: usize = 0;
                while (cmd_argv[count] != null)
                    count += 1;

                const copy: [*]?[*:0]u8 = @ptrCast(@alignCast(mallocOrAbort((count + 1) * @sizeOf(?[*:0]u8))));
                for (0..count) |i|
                    copy[i] = cmd_argv[i];
                copy[count] = null;
                shell_argv = copy;
            }

            if (isValidShell(shell_argv[0].?))
                addToEnv(&custom_env, "SHELL", shell_argv[0].?);

            slaveExec(
                ptmx,
                shell_argv,
                custom_env.envp orelse environ,
                fork_pipe[1],
                login_shell,
                notifications,
            );
        },

        else => {
            // Don't stay in CWD, since it may be an ephemeral path. For
            // example, it may be a mount point of, say, a thumb drive. Us
            // keeping it open will prevent the user from unmounting it.
            _ = std.c.chdir("/");

            _ = std.c.close(fork_pipe[1]); // Close write end
            logDbg("slave has PID %d", .{pid});

            var errno_copy: c_int = 0;
            comptime std.debug.assert(@sizeOf(@TypeOf(errno_copy)) == @sizeOf(c_int));

            const ret = std.c.read(fork_pipe[0], @as([*]u8, @ptrCast(&errno_copy)), @sizeOf(c_int));
            _ = std.c.close(fork_pipe[0]);

            if (ret < 0) {
                logErrno("failed to read from pipe", .{});
                return -1;
            } else if (ret == @sizeOf(c_int)) {
                logErrnoProvided(
                    errno_copy,
                    "%s: failed to execute",
                    .{if (argc == 0) conf_shell else argv.?[0].?},
                );
                return -1;
            } else {
                logDbg("%s: successfully started", .{conf_shell});
            }

            const fd_flags = fcntl(ptmx, c.f_getfd);
            if (fd_flags < 0 or fcntl(ptmx, c.f_setfd, fd_flags | c.fd_cloexec) < 0) {
                logErrno("failed to set FD_CLOEXEC on ptmx", .{});
                return -1;
            }
        },
    }

    return pid;
}
