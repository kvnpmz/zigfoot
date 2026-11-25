const std = @import("std");

const SigSet = std.c.sigset_t;
const SignalHandler = std.c.Sigaction.handler_fn;

const O_CLOEXEC: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "CLOEXEC");
const SIG_SETMASK: c_int = std.posix.SIG.SETMASK;
const SIGHUP: c_int = @intFromEnum(std.posix.SIG.HUP);
const SIGPIPE: c_int = @intFromEnum(std.posix.SIG.PIPE);
const SIG_DFL: ?SignalHandler = std.posix.SIG.DFL;
const SIG_ERR: ?SignalHandler = std.posix.SIG.ERR;
const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno_provided(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, errnum: c_int, fmt: [*:0]const u8, ...) void;
extern fn reaper_add(reaper: ?*anyopaque, pid: c_int, cb: ?*const anyopaque, cb_data: ?*anyopaque) void;

extern fn strerror(e: c_int) [*:0]const u8;
extern fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern fn fork() c_int;
extern fn close(fd: c_int) c_int;
extern fn setsid() c_int;
extern fn sigemptyset(set: *SigSet) c_int;
extern fn sigprocmask(how: c_int, set: ?*const SigSet, old: ?*SigSet) c_int;
extern fn signal(sig: c_int, handler: ?SignalHandler) ?SignalHandler;
extern fn setenv(name: [*c]const u8, value: [*c]const u8, overwrite: c_int) c_int;
extern fn getenv(name: [*c]const u8) [*c]u8;
extern fn chdir(path: [*c]const u8) c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn execvp(file: [*c]const u8, argv: [*c]const [*c]u8) c_int;
extern fn write(fd: c_int, buf: ?*const anyopaque, n: usize) isize;
extern fn read(fd: c_int, buf: ?*anyopaque, n: usize) isize;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn _exit(code: c_int) noreturn;

inline fn errnoPtr() *c_int {
    return std.c._errno();
}

fn childErr(wfd: c_int) noreturn {
    const errno_copy: c_int = errnoPtr().*;
    _ = write(wfd, &errno_copy, @sizeOf(c_int));
    _exit(errno_copy);
}

fn child(
    pipe_fds: *[2]c_int,
    cwd: [*c]const u8,
    argv: [*c]const [*c]u8,
    stdin_fd: c_int,
    stdout_fd: c_int,
    stderr_fd: c_int,
    token: [*c]const u8,
) noreturn {
    const w = pipe_fds[1];
    _ = close(pipe_fds[0]);

    if (setsid() < 0) childErr(w);

    var mask: SigSet = std.mem.zeroes(SigSet);
    _ = sigemptyset(&mask);
    if (sigprocmask(SIG_SETMASK, &mask, null) < 0) childErr(w);

    if (signal(SIGHUP, SIG_DFL) == SIG_ERR or signal(SIGPIPE, SIG_DFL) == SIG_ERR)
        childErr(w);

    if (cwd != null) {
        _ = setenv("PWD", cwd, 1);
        if (chdir(cwd) < 0) {
            log_msg(LOG_CLASS_WARNING, "spawn", "spawn.zig", @as(c_int, @intCast(@src().line)), "failed to change working directory to %s: %s", cwd, strerror(errnoPtr().*));
        }
    }

    if (token != null) {
        _ = setenv("XDG_ACTIVATION_TOKEN", token, 1);
        if (getenv("DISPLAY") != null)
            _ = setenv("DESKTOP_STARTUP_ID", token, 1);
    }

    const close_stderr = stderr_fd >= 0;
    const close_stdout = stdout_fd >= 0 and stdout_fd != stderr_fd;
    const close_stdin = stdin_fd >= 0 and stdin_fd != stdout_fd and stdin_fd != stderr_fd;

    if (stdin_fd >= 0 and (dup2(stdin_fd, 0) < 0 or (close_stdin and close(stdin_fd) < 0))) childErr(w);
    if (stdout_fd >= 0 and (dup2(stdout_fd, 1) < 0 or (close_stdout and close(stdout_fd) < 0))) childErr(w);
    if (stderr_fd >= 0 and (dup2(stderr_fd, 2) < 0 or (close_stderr and close(stderr_fd) < 0))) childErr(w);

    if (execvp(argv[0], argv) < 0) childErr(w);

    _exit(errnoPtr().*);
}

fn closePipe(fds: *[2]c_int) c_int {
    if (fds[0] != -1) _ = close(fds[0]);
    if (fds[1] != -1) _ = close(fds[1]);
    return -1;
}

export fn spawn(
    reaper: ?*anyopaque,
    cwd: [*c]const u8,
    argv: [*c]const [*c]u8,
    stdin_fd: c_int,
    stdout_fd: c_int,
    stderr_fd: c_int,
    cb: ?*const anyopaque,
    cb_data: ?*anyopaque,
    xdg_activation_token: [*c]const u8,
) c_int {
    var pipe_fds: [2]c_int = .{ -1, -1 };
    if (pipe2(&pipe_fds, O_CLOEXEC) < 0) {
        log_errno(LOG_CLASS_ERROR, "spawn", "spawn.zig", @as(c_int, @intCast(@src().line)), "failed to create pipe");
        return closePipe(&pipe_fds);
    }

    const pid = fork();
    if (pid < 0) {
        log_errno(LOG_CLASS_ERROR, "spawn", "spawn.zig", @as(c_int, @intCast(@src().line)), "failed to fork");
        return closePipe(&pipe_fds);
    }

    if (pid == 0)
        child(&pipe_fds, cwd, argv, stdin_fd, stdout_fd, stderr_fd, xdg_activation_token);

    // Parent
    _ = close(pipe_fds[1]);

    var errno_copy: c_int = 0;
    const ret = read(pipe_fds[0], &errno_copy, @sizeOf(c_int));
    _ = close(pipe_fds[0]);

    if (ret == 0) {
        reaper_add(reaper, pid, cb, cb_data);
        return pid;
    } else if (ret < 0) {
        log_errno(LOG_CLASS_ERROR, "spawn", "spawn.zig", @as(c_int, @intCast(@src().line)), "failed to read from pipe");
        return -1;
    } else {
        log_errno_provided(LOG_CLASS_ERROR, "spawn", "spawn.zig", @as(c_int, @intCast(@src().line)), errno_copy, "%s: failed to spawn", argv[0]);
        errnoPtr().* = errno_copy;
        _ = waitpid(pid, null, 0);
        return -1;
    }
}
