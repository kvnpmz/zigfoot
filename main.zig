const std = @import("std");
const builtin = @import("builtin");
const types = @import("terminal_types.zig");
const libc = @cImport({
    @cInclude("sys/utsname.h");
});
const build_options = @import("build_options");

//
// main.c ported to Zig (D6). This is the process entry point: argument
// parsing, locale setup, config load, the FDM/reaper/wayland/render/terminal
// construction chain, the signal wiring and the cleanup path.
//
// Everything that is C-only knowledge stays in main-shim.c (the struct stat
// directory test); the FOOT_DEFAULT_TERM #define arrives as a build option.
//

// ── log classes / colorize (log.h) ──────────────────────────────────
const LOG_COLORIZE_NEVER: c_int = 0;
const LOG_COLORIZE_ALWAYS: c_int = 1;
const LOG_COLORIZE_AUTO: c_int = 2;

const LOG_FACILITY_USER: c_int = 0;
const LOG_FACILITY_DAEMON: c_int = 1;

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_CLASS_INFO: c_int = 3;

const USER_NOTIFICATION_WARNING: c_int = 1;
const USER_NOTIFICATION_ERROR: c_int = 2;

const EXIT_SUCCESS: c_int = 0;

// ── libc ────────────────────────────────────────────────────────────
extern fn printf(format: [*:0]const u8, ...) c_int;
extern fn fprintf(stream: *std.c.FILE, format: [*:0]const u8, ...) c_int;
extern fn fputs(str: [*:0]const u8, stream: *std.c.FILE) c_int;
extern var stdout: *std.c.FILE;
extern var stderr: *std.c.FILE;

extern fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern fn unsetenv(name: [*:0]const u8) c_int;
extern fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]u8;
extern fn mbrtoc32(pc32: *u32, s: [*]const u8, n: usize, ps: ?*anyopaque) usize;
extern fn srand(seed: c_uint) void;
extern fn time(t: ?*i64) i64;
extern fn sscanf(str: [*:0]const u8, format: [*:0]const u8, ...) c_int;
extern fn strtoul(str: [*:0]const u8, end: ?*?[*:0]u8, base: c_int) c_ulong;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn write(fd: c_int, buf: *const anyopaque, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn getpid() c_int;
extern fn unlink(path: [*:0]const u8) c_int;
extern fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern fn free(ptr: ?*anyopaque) void;
extern fn strlen(s: [*:0]const u8) usize;

// getopt_long() and its globals. `optarg`/`optind` are exported by glibc.
const Option = extern struct {
    name: [*:0]const u8,
    has_arg: c_int,
    flag: ?*c_int,
    val: c_int,
};

const no_argument: c_int = 0;
const required_argument: c_int = 1;
const optional_argument: c_int = 2;

extern fn getopt_long(
    argc: c_int,
    argv: [*]?[*:0]u8,
    optstring: [*:0]const u8,
    longopts: [*]const Option,
    longindex: ?*c_int,
) c_int;
extern var optarg: ?[*:0]u8;
extern var optind: c_int;

// ── C helpers ───────────────────────────────────────────────────────
extern fn xmalloc(size: usize) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn xstrdup(str: [*:0]const u8) ?[*:0]u8;
extern fn xasprintf(format: [*:0]const u8, ...) ?[*:0]u8;
extern fn xsnprintf(buf: [*]u8, n: usize, format: [*:0]const u8, ...) usize;
extern fn main_shim_is_directory(path: [*:0]const u8) bool;

extern fn log_init(
    colorize: c_int,
    do_syslog: bool,
    syslog_facility: c_int,
    log_level: c_int,
) callconv(.c) void;
extern fn log_deinit() callconv(.c) void;
extern fn log_msg(log_class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn log_errno(log_class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn log_level_from_string(str: [*:0]const u8) callconv(.c) c_int;
extern fn log_level_string_hint() callconv(.c) [*:0]const u8;

extern fn fcft_init(colorize: c_int, do_syslog: bool, log_level: c_int) void;
extern fn fcft_fini() void;

extern fn foot_version_and_features() callconv(.c) [*:0]const u8;

// ── other modules ───────────────────────────────────────────────────
const Fdm = anyopaque;
const SigCb = *const fn (*Fdm, c_int, ?*anyopaque) callconv(.c) bool;

extern fn fdm_init() callconv(.c) ?*Fdm;
extern fn fdm_destroy(fdm: ?*Fdm) callconv(.c) void;
extern fn fdm_poll(fdm: *Fdm) callconv(.c) bool;
extern fn fdm_signal_add(
    fdm: *Fdm,
    signo: c_int,
    handler: SigCb,
    data: ?*anyopaque,
) callconv(.c) bool;
extern fn fdm_signal_del(fdm: *Fdm, signo: c_int) callconv(.c) bool;

extern fn reaper_init(fdm: *Fdm) callconv(.c) ?*anyopaque;
extern fn reaper_destroy(reaper: ?*anyopaque) callconv(.c) void;
extern fn key_binding_manager_new() callconv(.c) ?*anyopaque;
extern fn key_binding_manager_destroy(mgr: ?*anyopaque) callconv(.c) void;
extern fn wayl_init(
    fdm: ?*anyopaque,
    key_binding_manager: ?*anyopaque,
    presentation_timings: bool,
) callconv(.c) ?*types.Wayland;
extern fn wayl_destroy(wayl: ?*types.Wayland) callconv(.c) void;
extern fn render_init(fdm: *Fdm, wayl: *types.Wayland) callconv(.c) ?*anyopaque;
extern fn render_destroy(renderer: ?*anyopaque) callconv(.c) void;

extern fn term_init(
    conf: *const types.Config,
    fdm: ?*anyopaque,
    reaper: ?*anyopaque,
    wayl: *types.Wayland,
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
extern fn term_destroy(term: ?*types.Terminal) callconv(.c) c_int;
extern fn term_theme_switch_to_dark(term: *types.Terminal) callconv(.c) void;
extern fn term_theme_switch_to_light(term: *types.Terminal) callconv(.c) void;

extern fn server_init(
    conf: *types.Config,
    fdm: ?*anyopaque,
    reaper: ?*anyopaque,
    wayl: *types.Wayland,
) callconv(.c) ?*anyopaque;
extern fn server_destroy(server: ?*anyopaque) callconv(.c) void;
extern fn server_global_theme_switch_to_dark(server: ?*anyopaque) callconv(.c) void;
extern fn server_global_theme_switch_to_light(server: ?*anyopaque) callconv(.c) void;

extern fn shm_set_max_pool_size(size: i64) callconv(.c) void;
extern fn shm_set_min_stride_alignment(alignment: usize) callconv(.c) void;
extern fn shm_fini() callconv(.c) void;

// tll(char *) — `config_override_t`
const StrList = extern struct {
    head: ?*anyopaque,
    tail: ?*anyopaque,
    length: usize,
};

extern fn config_load(
    conf: *types.Config,
    conf_path: ?[*:0]const u8,
    initial_user_notifications: *types.UserNotifications,
    overrides: *StrList,
    errors_are_fatal: bool,
    as_server: bool,
) callconv(.c) bool;
extern fn config_free(conf: *types.Config) callconv(.c) void;
extern fn check_if_font_is_monospaced(
    pattern: [*:0]const u8,
    notifications: *types.UserNotifications,
) callconv(.c) void;
extern fn user_notification_add_fmt(notifications: *types.UserNotifications, kind: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

extern fn uri_parse(
    uri: [*c]const u8,
    len: usize,
    scheme: ?*[*c]u8,
    user: ?*[*c]u8,
    password: ?*[*c]u8,
    host: ?*[*c]u8,
    port: ?*u16,
    path: ?*[*c]u8,
    query: ?*[*c]u8,
    fragment: ?*[*c]u8,
) callconv(.c) bool;
extern fn hostname_is_localhost(hostname: [*c]const u8) callconv(.c) bool;

// ── small helpers ───────────────────────────────────────────────────

fn logInfo(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{ LOG_CLASS_INFO, "main", "main.zig", @as(c_int, @intCast(@src().line)), fmt } ++ args);
}

fn logWarn(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{ LOG_CLASS_WARNING, "main", "main.zig", @as(c_int, @intCast(@src().line)), fmt } ++ args);
}

fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{ LOG_CLASS_ERROR, "main", "main.zig", @as(c_int, @intCast(@src().line)), fmt } ++ args);
}

fn logErrno(comptime fmt: [*:0]const u8) void {
    log_errno(LOG_CLASS_ERROR, "main", "main.zig", @intCast(@src().line), fmt);
}

fn spanOf(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// xmalloc.h: `static inline char *xstrjoin(const char *s1, const char *s2)`
fn xstrjoin(s1: [*:0]const u8, s2: [*:0]const u8) [*:0]u8 {
    const n1 = strlen(s1);
    const n2 = strlen(s2);
    const joined: [*]u8 = @ptrCast(xmalloc(n1 + n2 + 1).?);
    @memcpy(joined[0..n1], s1[0..n1]);
    @memcpy(joined[n1..][0..n2], s2[0..n2]);
    joined[n1 + n2] = 0;
    return @ptrCast(joined);
}

fn tllPushBack(list: *StrList, item: ?[*:0]u8) void {
    const Node = types.TllNode(?[*:0]u8);
    const node: *Node = @ptrCast(@alignCast(xmalloc(@sizeOf(Node)) orelse unreachable));
    node.item = item;
    node.prev = list.tail;
    node.next = null;

    if (list.tail) |tail|
        @as(*Node, @ptrCast(@alignCast(tail))).next = node
    else
        list.head = node;

    list.tail = node;
    list.length += 1;
}

/// tll_free_and_free(overrides, free)
fn freeStrList(list: *StrList) void {
    const Node = types.TllNode(?[*:0]u8);
    var it = list.head;
    while (it) |raw| {
        const node: *Node = @ptrCast(@alignCast(raw));
        it = node.next;
        if (node.item) |s|
            free(@ptrCast(s));
        free(node);
    }
    list.* = .{ .head = null, .tail = null, .length = 0 };
}

fn printVersionAndFeatures(prefix: [*:0]const u8) void {
    _ = fputs(prefix, stdout);
    _ = fputs(foot_version_and_features(), stdout);
    _ = fputs("\n", stdout);
}

// ── signals ─────────────────────────────────────────────────────────

fn fdm_sigint(fdm: *Fdm, signo: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm;
    _ = signo;
    const flag: *volatile c_int = @ptrCast(@alignCast(data orelse return true));
    flag.* = 1;
    return true;
}

const SigusrContext = extern struct {
    term: ?*types.Terminal,
    server: ?*anyopaque,
};

fn fdm_sigusr(fdm: *Fdm, signo: c_int, data: ?*anyopaque) callconv(.c) bool {
    _ = fdm;
    std.debug.assert(signo == SIGUSR1 or signo == SIGUSR2);

    const ctx: *SigusrContext = @ptrCast(@alignCast(data orelse return true));

    if (ctx.server) |server| {
        if (signo == SIGUSR1)
            server_global_theme_switch_to_dark(server)
        else
            server_global_theme_switch_to_light(server);
    } else if (ctx.term) |term| {
        if (signo == SIGUSR1)
            term_theme_switch_to_dark(term)
        else
            term_theme_switch_to_light(term);
    }

    return true;
}

const SIGHUP: c_int = @intFromEnum(std.posix.SIG.HUP);
const SIGINT: c_int = @intFromEnum(std.posix.SIG.INT);
const SIGPIPE: c_int = @intFromEnum(std.posix.SIG.PIPE);
const SIGTERM: c_int = @intFromEnum(std.posix.SIG.TERM);
const SIGUSR1: c_int = @intFromEnum(std.posix.SIG.USR1);
const SIGUSR2: c_int = @intFromEnum(std.posix.SIG.USR2);

const SigSet = std.c.sigset_t;
const Sigaction = std.c.Sigaction;
extern fn sigemptyset(set: *SigSet) c_int;
extern fn sigprocmask(how: c_int, set: ?*const SigSet, oldset: ?*SigSet) c_int;
extern fn sigaction(signo: c_int, act: ?*const Sigaction, oldact: ?*Sigaction) c_int;

const SIG_SETMASK: c_int = std.posix.SIG.SETMASK;

fn signalCount() c_int {
    if (comptime builtin.os.tag == .linux) {
        if (comptime builtin.abi.isGnu())
            return __libc_current_sigrtmax();
        return @intCast(std.os.linux.sigrtmax());
    }
    return std.posix.SIG.RTMAX;
}

extern fn __libc_current_sigrtmax() c_int;

/// C's sanitize_signals(): clear the mask and reset every handler to SIG_DFL.
/// SIGKILL/SIGSTOP cannot be changed, so they are skipped (C calls
/// sigaction() and ignores EINVAL).
fn sanitizeSignals() void {
    var mask = std.mem.zeroes(SigSet);
    _ = sigemptyset(&mask);
    _ = sigprocmask(SIG_SETMASK, &mask, null);

    var dfl = Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.mem.zeroes(SigSet),
        .flags = 0,
    };
    _ = sigemptyset(&dfl.mask);

    const rtmax = signalCount();
    var i: c_int = 1;
    while (i < rtmax) : (i += 1) {
        if (i == @intFromEnum(std.posix.SIG.KILL) or
            i == @intFromEnum(std.posix.SIG.STOP))
        {
            continue;
        }
        _ = sigaction(i, &dfl, null);
    }
}

// ── locale ──────────────────────────────────────────────────────────

fn localeIsUtf8() bool {
    // u8"ö"
    const u8s = "\xc3\xb6";
    var w: u32 = 0;
    // C passes a zeroed local mbstate_t; NULL selects libc's initial state,
    // which is the same thing before any other conversion has run.
    if (mbrtoc32(&w, u8s, 2, null) != 2)
        return false;
    return w == 0xf6;
}

// ── misc ────────────────────────────────────────────────────────────

const ShutdownContext = extern struct {
    term: *?*types.Terminal,
    exit_code: c_int,
};

fn term_shutdown_cb(data: ?*anyopaque, exit_code: c_int) callconv(.c) void {
    const ctx: *ShutdownContext = @ptrCast(@alignCast(data orelse return));
    ctx.term.* = null;
    ctx.exit_code = exit_code;
}

const O_WRONLY: c_int = @intFromEnum(std.posix.ACCMODE.WRONLY);
const O_CREAT: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "CREAT");
const O_EXCL: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "EXCL");
const O_CLOEXEC: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "CLOEXEC");

const S_IRUSR: c_int = @intCast(std.posix.S.IRUSR);
const S_IWUSR: c_int = @intCast(std.posix.S.IWUSR);
const S_IRGRP: c_int = @intCast(std.posix.S.IRGRP);
const S_IROTH: c_int = @intCast(std.posix.S.IROTH);

fn printPid(pid_file: [*:0]const u8, unlink_at_exit: *bool) bool {
    std.c._errno().* = 0;
    var end: ?[*:0]u8 = null;
    const parsed = strtoul(pid_file, &end, 10);
    // C assigns an unsigned long to an int here; keep the same truncation.
    var pid_fd: c_int = @bitCast(@as(u32, @truncate(parsed)));

    const numeric = std.c._errno().* == 0 and end != null and end.?[0] == 0;
    if (!numeric) {
        pid_fd = open(
            pid_file,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH,
        );
        if (pid_fd < 0) {
            logErrno("failed to open");
            return false;
        }
        unlink_at_exit.* = true;
    }

    if (pid_fd >= 0) {
        var pid: [32]u8 = undefined;
        const n = xsnprintf(&pid, pid.len, "%u\n", getpid());
        const bytes = write(pid_fd, &pid, n);
        _ = close(pid_fd);

        if (bytes < 0) {
            logErrno("failed to write PID to FD");
            return false;
        }
        return true;
    }

    return false;
}

const PATH_MAX = std.posix.PATH_MAX;

fn getFootExe() [*:0]const u8 {
    // Linux only, fallback to "foot"
    const S = struct {
        var lnk: [PATH_MAX]u8 = undefined;
    };
    const ret = readlink("/proc/self/exe", &S.lnk, S.lnk.len - 1);
    if (ret < 0)
        return "foot";

    S.lnk[@intCast(ret)] = 0;
    return @ptrCast(&S.lnk);
}

extern fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;

// ── usage ───────────────────────────────────────────────────────────

const usage_options_head =
    "\nOptions:\n" ++
    "  -c,--config=PATH                         load configuration from PATH ($XDG_CONFIG_HOME/foot/foot.ini)\n" ++
    "  -C,--check-config                        verify configuration, exit with 0 if ok, otherwise exit with 1\n" ++
    "  -o,--override=[section.]key=value        override configuration option\n" ++
    "  -f,--font=FONT                           comma separated list of fonts in fontconfig format (monospace)\n" ++
    "  -t,--term=TERM                           value to set the environment variable TERM to (" ++ build_options.default_terminfo ++ ")\n" ++
    "  -T,--title=TITLE                         initial window title (foot)\n" ++
    "  -a,--app-id=ID                           window application ID (foot)\n" ++
    "     --toplevel-tag=TAG                    set a custom toplevel tag\n" ++
    "  -m,--maximized                           start in maximized mode\n" ++
    "  -F,--fullscreen                          start in fullscreen mode\n" ++
    "  -L,--login-shell                         start shell as a login shell\n" ++
    "  --pty=PATH                               display an existing PTY instead of creating one\n" ++
    "  -D,--working-directory=DIR               directory to start in (CWD)\n" ++
    "  -w,--window-size-pixels=WIDTHxHEIGHT     initial width and height, in pixels\n" ++
    "  -W,--window-size-chars=WIDTHxHEIGHT      initial width and height, in characters\n" ++
    "  -s,--server[=PATH]                       run as a server (use 'footclient' to start terminals).\n" ++
    "                                           Without PATH, $XDG_RUNTIME_DIR/foot-$WAYLAND_DISPLAY.sock will be used.\n" ++
    "  -H,--hold                                remain open after child process exits\n" ++
    "  -p,--print-pid=FILE|FD                   print PID to file or FD (only applicable in server mode)\n" ++
    "  -d,--log-level={info|warning|error|none} log level (warning)\n" ++
    "  -l,--log-colorize=[{never|always|auto}]  enable/disable colorization of log output on stderr\n" ++
    "  -S,--log-no-syslog                       disable syslog logging (only applicable in server mode)\n" ++
    "  -v,--version                             show the version number and quit\n" ++
    "  -e                                       ignored (for compatibility with xterm -e)\n";

fn printUsage(prog_name: [*:0]const u8) void {
    _ = printf("Usage: %s [OPTIONS...]\n", prog_name);
    _ = printf("Usage: %s [OPTIONS...] command [ARGS...]\n", prog_name);
    _ = fputs(usage_options_head ++ "\n", stdout);
}

// ── long options ────────────────────────────────────────────────────

const char_max: c_int = 127;
const PTY_OPTION: c_int = char_max + 1;
const TOPLEVEL_TAG_OPTION: c_int = char_max + 2;

const longopts = [_]Option{
    .{ .name = "config", .has_arg = required_argument, .flag = null, .val = 'c' },
    .{ .name = "check-config", .has_arg = no_argument, .flag = null, .val = 'C' },
    .{ .name = "override", .has_arg = required_argument, .flag = null, .val = 'o' },
    .{ .name = "term", .has_arg = required_argument, .flag = null, .val = 't' },
    .{ .name = "title", .has_arg = required_argument, .flag = null, .val = 'T' },
    .{ .name = "app-id", .has_arg = required_argument, .flag = null, .val = 'a' },
    .{ .name = "class", .has_arg = required_argument, .flag = null, .val = 'a' },
    .{ .name = "toplevel-tag", .has_arg = required_argument, .flag = null, .val = TOPLEVEL_TAG_OPTION },
    .{ .name = "login-shell", .has_arg = no_argument, .flag = null, .val = 'L' },
    .{ .name = "working-directory", .has_arg = required_argument, .flag = null, .val = 'D' },
    .{ .name = "font", .has_arg = required_argument, .flag = null, .val = 'f' },
    .{ .name = "window-size-pixels", .has_arg = required_argument, .flag = null, .val = 'w' },
    .{ .name = "window-size-chars", .has_arg = required_argument, .flag = null, .val = 'W' },
    .{ .name = "server", .has_arg = optional_argument, .flag = null, .val = 's' },
    .{ .name = "hold", .has_arg = no_argument, .flag = null, .val = 'H' },
    .{ .name = "maximized", .has_arg = no_argument, .flag = null, .val = 'm' },
    .{ .name = "fullscreen", .has_arg = no_argument, .flag = null, .val = 'F' },
    .{ .name = "presentation-timings", .has_arg = no_argument, .flag = null, .val = 'P' }, // Undocumented
    .{ .name = "pty", .has_arg = required_argument, .flag = null, .val = PTY_OPTION },
    .{ .name = "print-pid", .has_arg = required_argument, .flag = null, .val = 'p' },
    .{ .name = "log-level", .has_arg = required_argument, .flag = null, .val = 'd' },
    .{ .name = "log-colorize", .has_arg = optional_argument, .flag = null, .val = 'l' },
    .{ .name = "log-no-syslog", .has_arg = no_argument, .flag = null, .val = 'S' },
    .{ .name = "version", .has_arg = no_argument, .flag = null, .val = 'v' },
    .{ .name = "help", .has_arg = no_argument, .flag = null, .val = 'h' },
    .{ .name = "", .has_arg = no_argument, .flag = null, .val = 0 },
};

const LC_CTYPE: c_int = 0;

/// C: `static char *const bad_locale_fake_argv[] = {"/bin/sh", "-c", "", NULL}`
const fake_argv = [_]?[*:0]const u8{ "/bin/sh", "-c", "", null };

export fn main(argc_in: c_int, argv_in: [*]?[*:0]u8) c_int {
    var argc: c_int = argc_in;
    var argv: [*]?[*:0]u8 = argv_in;

    // Custom exit code, to enable users to differentiate between foot
    // itself failing, and the client application failing
    const foot_exit_failure: c_int = -26;
    var ret: c_int = foot_exit_failure;

    sanitizeSignals();

    // XDG startup notifications
    const token = getenv("XDG_ACTIVATION_TOKEN");
    _ = unsetenv("XDG_ACTIVATION_TOKEN");

    // Startup notifications; we don't support it, but must ensure we
    // don't pass this on to programs launched by us
    _ = unsetenv("DESKTOP_STARTUP_ID");

    // Temporary "clean" copy of argv, for term_init()
    const foot_argc = argc;
    const foot_argv = argv;

    const prog_name: [*:0]const u8 = if (argc > 0) (argv[0] orelse "<nullptr>") else "<nullptr>";

    var check_config = false;
    var conf_path: ?[*:0]const u8 = null;
    var custom_cwd: ?[*:0]u8 = null;
    var pty_path: ?[*:0]const u8 = null;
    var as_server = false;
    var conf_server_socket_path: ?[*:0]const u8 = null;
    var presentation_timings = false;
    var hold = false;
    var unlink_pid_file = false;
    var pid_file: ?[*:0]const u8 = null;
    var log_level: c_int = LOG_CLASS_WARNING;
    var log_colorize: c_int = LOG_COLORIZE_AUTO;
    var log_syslog = true;
    var user_notifications: types.UserNotifications = std.mem.zeroes(types.UserNotifications);
    var overrides = StrList{ .head = null, .tail = null, .length = 0 };

    while (true) {
        const c = getopt_long(argc, argv, "+c:Co:t:T:a:LD:f:w:W:s::HmFPp:d:l::Sveh", &longopts, null);

        if (c == -1)
            break;

        switch (c) {
            'c' => conf_path = optarg,

            'C' => check_config = true,

            'o' => tllPushBack(&overrides, xstrdup(optarg.?)),

            't' => tllPushBack(&overrides, xstrjoin("term=", optarg.?)),

            'L' => tllPushBack(&overrides, xstrdup("login-shell=yes")),

            'T' => tllPushBack(&overrides, xstrjoin("title=", optarg.?)),

            'a' => tllPushBack(&overrides, xstrjoin("app-id=", optarg.?)),

            TOPLEVEL_TAG_OPTION => tllPushBack(&overrides, xstrjoin("toplevel-tag=", optarg.?)),

            'D' => {
                // try to parse optarg as a local file URL. if it's not a
                // URL, use optarg directly
                var scheme: [*c]u8 = null;
                var host: [*c]u8 = null;
                var path: [*c]u8 = null;

                const arg = optarg.?;
                if (uri_parse(arg, strlen(arg), &scheme, null, null, &host, null, &path, null, null)) {
                    const is_file = scheme != null and host != null and
                        streq(spanOf(@ptrCast(scheme)), "file") and
                        hostname_is_localhost(host);

                    if (!is_file) {
                        _ = fprintf(stderr, "error: %s: not a local path\n", arg);
                        free(@ptrCast(scheme));
                        free(@ptrCast(host));
                        free(@ptrCast(path));
                        return ret;
                    }

                    // ownership moved to custom_cwd, freed at out:
                    custom_cwd = @ptrCast(path);
                    path = null;
                } else {
                    custom_cwd = xstrdup(arg);
                }

                free(@ptrCast(scheme));
                free(@ptrCast(host));
                free(@ptrCast(path));

                if (!main_shim_is_directory(custom_cwd.?)) {
                    _ = fprintf(stderr, "error: %s: not a directory\n", arg);
                    free(custom_cwd);
                    custom_cwd = null;
                    return ret;
                }
            },

            'f' => tllPushBack(&overrides, xstrjoin("font=", optarg.?)),

            'w' => {
                var width: c_uint = 0;
                var height: c_uint = 0;
                if (sscanf(optarg.?, "%ux%u", &width, &height) != 2 or width == 0 or height == 0) {
                    _ = fprintf(stderr, "error: invalid window-size-pixels: %s\n", optarg.?);
                    freeStrList(&overrides);
                    return ret;
                }

                tllPushBack(&overrides, xasprintf("initial-window-size-pixels=%ux%u", width, height));
            },

            'W' => {
                var width: c_uint = 0;
                var height: c_uint = 0;
                if (sscanf(optarg.?, "%ux%u", &width, &height) != 2 or width == 0 or height == 0) {
                    _ = fprintf(stderr, "error: invalid window-size-chars: %s\n", optarg.?);
                    freeStrList(&overrides);
                    return ret;
                }

                tllPushBack(&overrides, xasprintf("initial-window-size-chars=%ux%u", width, height));
            },

            's' => {
                as_server = true;
                if (optarg) |o|
                    conf_server_socket_path = o;
            },

            PTY_OPTION => pty_path = optarg,

            'P' => presentation_timings = true,

            'H' => hold = true,

            'm' => tllPushBack(&overrides, xstrdup("initial-window-mode=maximized")),

            'F' => tllPushBack(&overrides, xstrdup("initial-window-mode=fullscreen")),

            'p' => pid_file = optarg,

            'd' => {
                const lvl = log_level_from_string(optarg.?);
                if (lvl < 0) {
                    _ = fprintf(
                        stderr,
                        "-d,--log-level: %s: argument must be one of %s\n",
                        optarg.?,
                        log_level_string_hint(),
                    );
                    freeStrList(&overrides);
                    return ret;
                }
                log_level = lvl;
            },

            'l' => {
                const arg = optarg;
                if (arg == null or streq(spanOf(arg.?), "auto")) {
                    log_colorize = LOG_COLORIZE_AUTO;
                } else if (streq(spanOf(arg.?), "never")) {
                    log_colorize = LOG_COLORIZE_NEVER;
                } else if (streq(spanOf(arg.?), "always")) {
                    log_colorize = LOG_COLORIZE_ALWAYS;
                } else {
                    _ = fprintf(
                        stderr,
                        "%s: argument must be one of 'never', 'always' or 'auto'\n",
                        arg.?,
                    );
                    freeStrList(&overrides);
                    return ret;
                }
            },

            'S' => log_syslog = false,

            'v' => {
                printVersionAndFeatures("foot ");
                freeStrList(&overrides);
                return EXIT_SUCCESS;
            },

            'h' => {
                printUsage(prog_name);
                freeStrList(&overrides);
                return EXIT_SUCCESS;
            },

            'e' => {},

            '?' => {
                freeStrList(&overrides);
                return ret;
            },

            else => {},
        }
    }

    if (as_server and pty_path != null) {
        _ = fputs("error: --pty is incompatible with server mode\n", stderr);
        freeStrList(&overrides);
        return ret;
    }

    log_init(
        log_colorize,
        as_server and log_syslog,
        if (as_server) LOG_FACILITY_DAEMON else LOG_FACILITY_USER,
        log_level,
    );

    if (argc > 0) {
        argc -= optind;
        argv += @intCast(optind);
    }

    logInfo("%s", .{foot_version_and_features()});

    {
        var name: libc.struct_utsname = undefined;
        if (libc.uname(&name) == 0) {
            logInfo("arch: %s %s/%zu-bit", .{
                @as([*:0]const u8, @ptrCast(&name.sysname)),
                @as([*:0]const u8, @ptrCast(&name.machine)),
                @as(usize, @sizeOf(usize) * 8),
            });
        }
    }

    const now = time(null);
    srand(@truncate(@as(u64, @bitCast(now))));

    const locale = setlocale(LC_CTYPE, "");
    if (locale == null) {
        // If the user has configured an invalid locale, or a name of a locale
        // that does not exist on this system, then the above call may return
        // NULL. We should just continue with the fallback method below.
        logErr("setlocale() failed. The most common cause is that the " ++
            "configured locale is not available, or has been misspelled", .{});
    }

    logInfo("locale: %s", .{locale orelse "<invalid>"});

    var bad_locale = locale == null or !localeIsUtf8();
    if (bad_locale) {
        const fallback_locales = [_][*:0]const u8{ "C.UTF-8", "en_US.UTF-8" };
        const saved_locale: ?[*:0]u8 = if (locale) |l| xstrdup(l) else null;

        // Try to force an UTF-8 locale. If we succeed, launch the user's
        // shell as usual, but add a user-notification saying the locale has
        // been changed.
        for (fallback_locales) |fallback_locale| {
            if (setlocale(LC_CTYPE, fallback_locale) != null) {
                if (saved_locale) |saved| {
                    logWarn("'%s' is not a UTF-8 locale, falling back to '%s'", .{ saved, fallback_locale });
                    user_notification_add_fmt(
                        &user_notifications,
                        USER_NOTIFICATION_WARNING,
                        "'%s' is not a UTF-8 locale, falling back to '%s'",
                        saved,
                        fallback_locale,
                    );
                } else {
                    logWarn("invalid locale, falling back to '%s'", .{fallback_locale});
                    user_notification_add_fmt(
                        &user_notifications,
                        USER_NOTIFICATION_WARNING,
                        "invalid locale, falling back to '%s'",
                        fallback_locale,
                    );
                }

                bad_locale = false;
                break;
            }
        }

        if (bad_locale) {
            if (saved_locale) |saved| {
                logErr("'%s' is not a UTF-8 locale, and failed to find a fallback", .{saved});
                user_notification_add_fmt(
                    &user_notifications,
                    USER_NOTIFICATION_ERROR,
                    "'%s' is not a UTF-8 locale, and failed to find a fallback",
                    saved,
                );
            } else {
                logErr("invalid locale, and failed to find a fallback", .{});
                user_notification_add_fmt(
                    &user_notifications,
                    USER_NOTIFICATION_ERROR,
                    "invalid locale, and failed to find a fallback",
                );
            }
        }
        if (saved_locale) |s|
            free(@ptrCast(s));
    }

    var conf: types.Config = std.mem.zeroes(types.Config);
    const conf_successful = config_load(&conf, conf_path, &user_notifications, &overrides, check_config, as_server);

    freeStrList(&overrides);
    if (!conf_successful) {
        config_free(&conf);
        return ret;
    }

    if (check_config) {
        config_free(&conf);
        return EXIT_SUCCESS;
    }

    // The C build asserts that log_class/log_colorize line up with fcft's
    // enums; both are fixed ABI, so pass the values straight through.
    comptime {
        std.debug.assert(LOG_CLASS_ERROR == 1); // FCFT_LOG_CLASS_ERROR
        std.debug.assert(LOG_COLORIZE_ALWAYS == 1); // FCFT_LOG_COLORIZE_ALWAYS
    }
    fcft_init(log_colorize, as_server and log_syslog, log_level);

    if (conf_server_socket_path) |socket_path| {
        if (conf.server_socket_path) |old|
            free(@ptrCast(old));
        conf.server_socket_path = xstrdup(socket_path);
    }
    conf.presentation_timings = presentation_timings;
    conf.hold_at_exit = hold;

    if (conf.tweak.font_monospace_warn and conf.fonts[0].count > 0) {
        if (conf.fonts[0].arr.?[0].pattern) |pattern|
            check_if_font_is_monospaced(pattern, &conf.notifications);
    }

    if (bad_locale) {
        // argc/argv are only read for argc entries; "-c ''" keeps it quiet.
        argc = 1;
        argv = @ptrCast(@constCast(&fake_argv));
        conf.hold_at_exit = true;
    }

    var fdm: ?*Fdm = null;
    var reaper: ?*anyopaque = null;
    var key_binding_manager: ?*anyopaque = null;
    var wayl: ?*types.Wayland = null;
    var renderer: ?*anyopaque = null;
    var term: ?*types.Terminal = null;
    var server: ?*anyopaque = null;
    var shutdown_ctx = ShutdownContext{ .term = &term, .exit_code = foot_exit_failure };

    var cwd: ?[*:0]const u8 = if (custom_cwd) |c| c else null;
    var owned_cwd: ?[*:0]u8 = null;

    var aborted: c_int = 0;

    out: {
        if (cwd == null) {
            var buf_len: usize = 1024;
            while (true) {
                owned_cwd = @ptrCast(xrealloc(owned_cwd, buf_len));
                std.c._errno().* = 0;
                if (getcwd(owned_cwd.?, buf_len) == null and std.c._errno().* != @intFromEnum(std.posix.E.RANGE)) {
                    logErrno("failed to get current working directory");
                    break :out;
                }
                buf_len *= 2;
                if (std.c._errno().* != @intFromEnum(std.posix.E.RANGE))
                    break;
            }
            cwd = owned_cwd;
        }

        if (getenv("PWD")) |pwd| {
            const resolved_path_cwd = realpath(cwd.?, null);
            const resolved_path_pwd = realpath(pwd, null);

            if (resolved_path_cwd != null and resolved_path_pwd != null and
                streq(spanOf(resolved_path_cwd.?), spanOf(resolved_path_pwd.?)))
            {
                // The resolved path of $PWD matches the resolved path of the
                // *actual* working directory - use $PWD. This makes a
                // difference when $PWD refers to a symlink.
                cwd = pwd;
            }

            free(@ptrCast(resolved_path_cwd));
            free(@ptrCast(resolved_path_pwd));
        }

        shm_set_max_pool_size(conf.tweak.max_shm_pool_size);
        shm_set_min_stride_alignment(conf.tweak.min_stride_alignment);

        fdm = fdm_init() orelse break :out;

        reaper = reaper_init(fdm.?) orelse break :out;

        key_binding_manager = key_binding_manager_new() orelse break :out;

        wayl = wayl_init(fdm, key_binding_manager, conf.presentation_timings) orelse break :out;

        renderer = render_init(fdm.?, wayl.?) orelse break :out;

        if (!as_server) {
            term = term_init(
                &conf,
                fdm,
                reaper,
                wayl.?,
                getFootExe(),
                cwd,
                token,
                pty_path,
                argc,
                argv,
                null,
                foot_argc,
                @ptrCast(foot_argv),
                &term_shutdown_cb,
                &shutdown_ctx,
            ) orelse break :out;
        }
        if (owned_cwd) |c| {
            free(@ptrCast(c));
            owned_cwd = null;
        }

        if (as_server) {
            server = server_init(&conf, fdm, reaper, wayl.?) orelse break :out;
        }

        if (!fdm_signal_add(fdm.?, SIGINT, &fdm_sigint, &aborted) or
            !fdm_signal_add(fdm.?, SIGTERM, &fdm_sigint, &aborted))
        {
            break :out;
        }

        var sigusr_context = SigusrContext{ .term = term, .server = server };

        if (!fdm_signal_add(fdm.?, SIGUSR1, &fdm_sigusr, &sigusr_context) or
            !fdm_signal_add(fdm.?, SIGUSR2, &fdm_sigusr, &sigusr_context))
        {
            break :out;
        }

        var sig_ign = Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = undefined, .flags = 0 };
        _ = sigemptyset(&sig_ign.mask);
        if (sigaction(SIGHUP, &sig_ign, null) < 0 or
            sigaction(SIGPIPE, &sig_ign, null) < 0)
        {
            logErrno("failed to ignore SIGHUP+SIGPIPE");
            break :out;
        }

        if (as_server)
            logInfo("running as server; launch terminals by running footclient", .{});

        if (as_server and pid_file != null) {
            if (!printPid(pid_file.?, &unlink_pid_file))
                break :out;
        }

        ret = EXIT_SUCCESS;
        const aborted_ptr: *volatile c_int = @ptrCast(&aborted);
        while (aborted_ptr.* == 0 and (as_server or wayl.?.terms.length > 0)) {
            if (!fdm_poll(fdm.?)) {
                ret = foot_exit_failure;
                break;
            }
        }
    }

    // out:
    if (owned_cwd) |c|
        free(@ptrCast(c));
    if (custom_cwd) |c|
        free(@ptrCast(c));
    server_destroy(server);
    _ = term_destroy(term);

    shm_fini();
    render_destroy(renderer);
    wayl_destroy(wayl);
    key_binding_manager_destroy(key_binding_manager);
    reaper_destroy(reaper);
    if (fdm) |f| {
        _ = fdm_signal_del(f, SIGUSR1);
        _ = fdm_signal_del(f, SIGUSR2);
        _ = fdm_signal_del(f, SIGTERM);
        _ = fdm_signal_del(f, SIGINT);
        fdm_destroy(f);
    }

    config_free(&conf);

    if (unlink_pid_file) {
        if (pid_file) |p|
            _ = unlink(p);
    }

    logInfo("goodbye", .{});
    fcft_fini();
    log_deinit();
    return if (ret == EXIT_SUCCESS and !as_server) shutdown_ctx.exit_code else ret;
}
