const std = @import("std");
const builtin = @import("builtin");
const types = @import("terminal_types.zig");
const build_options = @import("build_options");
const abi = @import("c_layout");

// footclient: command-line parsing and the setup packet sent to foot --server.
// The process entry point is emitted only for the footclient build. The test
// object sets client_entrypoint=false and exports the small helpers below.

const LOG_CLASS_ERROR: c_int = 1;
const LOG_CLASS_WARNING: c_int = 2;
const LOG_FACILITY_USER: c_int = 0;
const EXIT_SUCCESS: c_int = 0;
const FOOT_EXIT_FAILURE: c_int = -36;
const TOPLEVEL_TAG_OPTION: c_int = 128;
const MAX_STRING_LEN: usize = 1 << 16;
const MAX_PACKET_LEN: u64 = 1 << 32;

extern fn log_init(colorize: c_int, do_syslog: bool, facility: c_int, level: c_int) void;
extern fn log_deinit() void;
extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, ...) void;
extern fn log_level_from_string(str: [*:0]const u8) c_int;
extern fn log_level_string_hint() [*:0]const u8;

extern fn printf(format: [*c]const u8, ...) c_int;
extern fn puts(str: [*c]const u8) c_int;
extern fn fputs(str: [*c]const u8, stream: ?*std.c.FILE) c_int;
extern fn fputc(c: c_int, stream: ?*std.c.FILE) c_int;
extern var stdout: *std.c.FILE;
extern var stderr: *std.c.FILE;
extern const version_and_features: [256:0]u8;

extern fn getopt_long(argc: c_int, argv: [*c][*:0]u8, shortopts: [*c]const u8, longopts: [*c]Option, longindex: ?*c_int) c_int;
extern var optind: c_int;
extern var optarg: [*c]u8;

const Option = extern struct {
    name: ?[*:0]const u8,
    has_arg: c_int,
    flag: ?*c_int,
    val: c_int,
};

extern fn getenv(name: [*c]const u8) [*c]u8;
extern var environ: [*c]?[*:0]u8;
extern fn strlen(s: [*c]const u8) usize;
extern fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
extern fn xstrdup(s: [*:0]const u8) [*:0]u8;
extern fn xmalloc(size: usize) *anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) *anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn malloc(size: usize) ?*anyopaque;

extern fn readlink(path: [*c]const u8, buf: [*]u8, size: usize) isize;
extern fn realpath(path: [*c]const u8, resolved: [*c]u8) ?[*:0]u8;
extern fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
extern fn stat(path: [*c]const u8, buf: *Stat) c_int;
extern fn snprintf(buf: [*]u8, size: usize, format: [*c]const u8, ...) c_int;
extern fn sscanf(str: [*c]const u8, format: [*c]const u8, ...) c_int;
extern fn fprintf(stream: ?*std.c.FILE, format: [*c]const u8, ...) c_int;

extern fn uri_parse(uri: [*c]const u8, len: usize, scheme: ?*[*c]u8, user: ?*[*c]u8, password: ?*[*c]u8, host: ?*[*c]u8, port: ?*u16, path: ?*[*c]u8, query: ?*[*c]u8, fragment: ?*[*c]u8) bool;
extern fn hostname_is_localhost(host: [*c]const u8) bool;

extern fn socket(domain: c_int, type: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern fn send(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
extern fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
extern fn close(fd: c_int) c_int;
extern fn sigaction(sig: c_int, act: ?*const std.posix.Sigaction, old: ?*std.posix.Sigaction) c_int;
extern fn sigemptyset(set: *std.posix.sigset_t) c_int;

const SOCK_STREAM: c_int = std.posix.SOCK.STREAM;
const AF_UNIX: c_int = std.posix.AF.UNIX;
const MSG_NOSIGNAL: c_int = std.posix.MSG.NOSIGNAL;
const EINTR: c_int = @backingInt(std.c.E.INTR);
const ERANGE: c_int = 34;
const ENOENT: c_int = @backingInt(std.c.E.NOENT);
const S_IFDIR: u32 = std.posix.S.IFDIR;

// Shared with misc.zig; terminal_types.zig owns and probes the Linux mirror.
const Stat = types.Stat;
const statMode = types.statMode;
const SockaddrUn = std.c.sockaddr.un;

fn initSocketAddr() SockaddrUn {
    var addr = std.mem.zeroes(SockaddrUn);
    addr.family = @intCast(AF_UNIX);
    if (comptime @hasField(SockaddrUn, "len"))
        addr.len = @sizeOf(SockaddrUn);
    return addr;
}

fn errno() c_int {
    return std.c._errno().*;
}

fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{
        LOG_CLASS_ERROR,
        "zigfoot-client",
        "client.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn logErrno(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_errno, .{
        LOG_CLASS_ERROR,
        "zigfoot-client",
        "client.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn logWarn(comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, log_msg, .{
        LOG_CLASS_WARNING,
        "zigfoot-client",
        "client.zig",
        @as(c_int, @intCast(@src().line)),
        fmt,
    } ++ args);
}

fn streq(a: [*c]const u8, b: [*c]const u8) bool {
    if (a == null or b == null)
        return a == b;
    return std.mem.eql(u8, std.mem.span(a), std.mem.span(b));
}

var aborted: std.c.sig_atomic_t = 0;
var sigusr: std.c.sig_atomic_t = 0;

fn sigintHandler(signo: std.posix.SIG) callconv(.c) void {
    _ = signo;
    aborted = 1;
}

fn sigusrHandler(signo: std.posix.SIG) callconv(.c) void {
    sigusr = @bitCast(@backingInt(signo));
}

/// Send all bytes, matching the C client's EINTR and MSG_NOSIGNAL behavior.
export fn client_shim_sendall(fd: c_int, data: [*]const u8, len: usize) isize {
    var left = len;
    var cursor = data;
    while (left > 0) {
        const count = send(fd, cursor, left, MSG_NOSIGNAL);
        if (count < 0) {
            if (errno() == EINTR)
                continue;
            return count;
        }
        cursor += @intCast(count);
        left -= @intCast(count);
    }
    return @bitCast(len);
}

/// Parse the exact "%ux%u" form accepted by the C command-line parser.
export fn client_shim_parse_window_size(text: [*:0]const u8, width: *c_uint, height: *c_uint) bool {
    return sscanf(text, "%ux%u", width, height) == 2 and width.* != 0 and height.* != 0;
}

export fn client_shim_string_len_ok(len: usize) bool {
    return len < MAX_STRING_LEN - 1;
}

export fn client_shim_protocol_sizes(sizes: *[4]usize) void {
    sizes.* = .{ @sizeOf(types.ClientString), @sizeOf(types.ClientData), @sizeOf(types.ClientIpcHdr), @sizeOf(types.ClientIpcSigusr) };
}

/// Encode FOOT_IPC_SIGUSR in host byte order, as the C packed structs do.
export fn client_shim_sigusr_ipc(buf: [*]u8, signo: c_int) usize {
    var hdr = types.ClientIpcHdr{ .ipc_code = undefined, .size = @sizeOf(types.ClientIpcSigusr) };
    const payload = types.ClientIpcSigusr{ .signo = signo };
    std.mem.writeInt(c_int, &hdr.ipc_code, 0, builtin.cpu.arch.endian());
    @memcpy(buf[0..@sizeOf(types.ClientIpcHdr)], std.mem.asBytes(&hdr));
    @memcpy(buf[@sizeOf(types.ClientIpcHdr)..][0..@sizeOf(types.ClientIpcSigusr)], std.mem.asBytes(&payload));
    return @sizeOf(types.ClientIpcHdr) + @sizeOf(types.ClientIpcSigusr);
}

const StringNode = struct {
    next: ?*StringNode,
    str: [*:0]u8,
    len: usize,
};

const StringList = struct {
    head: ?*StringNode,
    tail: ?*StringNode,
    count: usize,

    fn push(self: *StringList, text: [*:0]const u8, total_len: *u64) bool {
        const len = strlen(text) + 1;
        if (len >= MAX_STRING_LEN) {
            logErr("string length overflow", .{});
            return false;
        }
        const node = @as(*StringNode, @ptrCast(@alignCast(xmalloc(@sizeOf(StringNode)))));
        node.* = .{ .next = null, .str = xstrdup(text), .len = len };
        if (self.tail) |tail|
            tail.next = node
        else
            self.head = node;
        self.tail = node;
        self.count += 1;
        total_len.* +%= @sizeOf(types.ClientString) + len;
        return true;
    }

    fn sendAll(self: *const StringList, fd: c_int) bool {
        var it = self.head;
        while (it) |node| : (it = node.next) {
            const header = types.ClientString{ .len = @intCast(node.len) };
            if (client_shim_sendall(fd, @ptrCast(&header), @sizeOf(types.ClientString)) < 0 or
                client_shim_sendall(fd, node.str, node.len) < 0)
            {
                logErrno("failed to send setup packet to server", .{});
                return false;
            }
        }
        return true;
    }

    fn deinit(self: *StringList) void {
        var it = self.head;
        while (it) |node| {
            const next = node.next;
            free(node.str);
            free(node);
            it = next;
        }
        self.* = .{ .head = null, .tail = null, .count = 0 };
    }
};

var exe_buffer: [4096]u8 = undefined;

fn getFootclientExe() [*:0]const u8 {
    const count = readlink("/proc/self/exe", &exe_buffer, exe_buffer.len - 1);
    if (count < 0)
        return "zigfootclient";
    exe_buffer[@intCast(count)] = 0;
    return @ptrCast(&exe_buffer);
}

fn printUsage(prog: [*:0]const u8) void {
    const options =
        "\nOptions:\n" ++
        "  -t,--term=TERM                           value to set the environment variable TERM to (" ++ build_options.default_terminfo ++ ")\n" ++
        "  -T,--title=TITLE                         initial window title (Zigfoot)\n" ++
        "  -a,--app-id=ID                           window application ID (zigfoot)\n" ++
        "     --toplevel-tag=TAG                    set a custom toplevel tag\n" ++
        "  -w,--window-size-pixels=WIDTHxHEIGHT     initial width and height, in pixels\n" ++
        "  -W,--window-size-chars=WIDTHxHEIGHT      initial width and height, in characters\n" ++
        "  -m,--maximized                           start in maximized mode\n" ++
        "  -F,--fullscreen                          start in fullscreen mode\n" ++
        "  -L,--login-shell                         start shell as a login shell\n" ++
        "  -D,--working-directory=DIR               directory to start in (CWD)\n" ++
        "  -s,--server-socket=PATH                  path to the server UNIX domain socket (default=$XDG_RUNTIME_DIR/zigfoot-$WAYLAND_DISPLAY.sock)\n" ++
        "  -H,--hold                                remain open after child process exits\n" ++
        "  -N,--no-wait                             detach the client process from the running terminal, exiting immediately\n" ++
        "  -o,--override=[section.]key=value        override configuration option\n" ++
        "  -E, --client-environment                 exec shell using zigfootclient's environment, instead of the server's\n" ++
        "  -d,--log-level={info|warning|error|none} log level (warning)\n" ++
        "  -l,--log-colorize=[{never|always|auto}]  enable/disable colorization of log output on stderr\n" ++
        "  -v,--version                             show the version number and quit\n" ++
        "  -e                                       ignored (for compatibility with xterm -e)\n";
    _ = printf("Usage: %s [OPTIONS...]\n", prog);
    _ = printf("Usage: %s [OPTIONS...] command [ARGS...]\n", prog);
    _ = puts(options);
}

fn printVersionAndFeatures() void {
    _ = fputs(@as([*c]const u8, &version_and_features), stdout);
    _ = fputc('\n', stdout);
}

fn setSocketPath(addr: *SockaddrUn, path: [*:0]const u8) void {
    @memset(&addr.path, 0);
    const source = std.mem.span(path);
    const count = @min(source.len, addr.path.len);
    @memcpy(addr.path[0..count], source[0..count]);
}

fn addOverride(list: *StringList, total_len: *u64, text: [*:0]const u8) bool {
    return list.push(text, total_len);
}

export fn footclient_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var ret = FOOT_EXIT_FAILURE;
    const foot_argc = argc;

    var foot_argv: ?[*][*:0]u8 = null;
    if (foot_argc > 0)
        foot_argv = @ptrCast(@alignCast(xmalloc(@as(usize, @intCast(foot_argc)) * @sizeOf([*:0]u8))));
    if (foot_argv) |args| {
        for (0..@as(usize, @intCast(foot_argc))) |i|
            args[i] = argv[i];
    }
    const prog: [*:0]const u8 = if (argc > 0) argv[0] else "<nullptr>";

    var longopts = [_]Option{
        .{ .name = "term", .has_arg = 1, .flag = null, .val = 't' },
        .{ .name = "title", .has_arg = 1, .flag = null, .val = 'T' },
        .{ .name = "app-id", .has_arg = 1, .flag = null, .val = 'a' },
        .{ .name = "class", .has_arg = 1, .flag = null, .val = 'a' },
        .{ .name = "toplevel-tag", .has_arg = 1, .flag = null, .val = TOPLEVEL_TAG_OPTION },
        .{ .name = "window-size-pixels", .has_arg = 1, .flag = null, .val = 'w' },
        .{ .name = "window-size-chars", .has_arg = 1, .flag = null, .val = 'W' },
        .{ .name = "maximized", .has_arg = 0, .flag = null, .val = 'm' },
        .{ .name = "fullscreen", .has_arg = 0, .flag = null, .val = 'F' },
        .{ .name = "login-shell", .has_arg = 0, .flag = null, .val = 'L' },
        .{ .name = "working-directory", .has_arg = 1, .flag = null, .val = 'D' },
        .{ .name = "server-socket", .has_arg = 1, .flag = null, .val = 's' },
        .{ .name = "hold", .has_arg = 0, .flag = null, .val = 'H' },
        .{ .name = "no-wait", .has_arg = 0, .flag = null, .val = 'N' },
        .{ .name = "override", .has_arg = 1, .flag = null, .val = 'o' },
        .{ .name = "client-environment", .has_arg = 0, .flag = null, .val = 'E' },
        .{ .name = "log-level", .has_arg = 1, .flag = null, .val = 'd' },
        .{ .name = "log-colorize", .has_arg = 2, .flag = null, .val = 'l' },
        .{ .name = "version", .has_arg = 0, .flag = null, .val = 'v' },
        .{ .name = "help", .has_arg = 0, .flag = null, .val = 'h' },
        .{ .name = null, .has_arg = 0, .flag = null, .val = 0 },
    };

    var custom_cwd: ?[*:0]u8 = null;
    var server_socket_path: ?[*:0]u8 = null;
    var log_level: c_int = LOG_CLASS_WARNING;
    var log_colorize: c_int = 2; // LOG_COLORIZE_AUTO
    var hold = false;
    var client_environment = false;
    var no_wait = false;

    const token = getenv("XDG_ACTIVATION_TOKEN");
    const xdga_token = token != null;
    const token_len = if (xdga_token) strlen(token) + 1 else 0;
    var buf: [1024]u8 = undefined;
    var total_len: u64 = 0;
    var fd: c_int = -1;
    var cwd_buffer: ?[*]u8 = null;
    var cfoot_argv: ?[*]types.ClientString = null;
    var cslave_argv: ?[*]types.ClientString = null;
    var overrides = StringList{ .head = null, .tail = null, .count = 0 };
    var envp = StringList{ .head = null, .tail = null, .count = 0 };

    defer {
        envp.deinit();
        overrides.deinit();
        free(cfoot_argv);
        free(cslave_argv);
        free(@ptrCast(foot_argv)); // C keeps this in a VLA; the port heap-copies it
        free(cwd_buffer);
        free(custom_cwd);
        if (fd != -1)
            _ = close(fd);
        log_deinit();
    }

    while (true) {
        const c = getopt_long(argc, argv, "+t:T:a:w:W:mFLD:s:HNo:Ed:l::veh", &longopts, null);
        if (c == -1)
            break;
        switch (c) {
            't' => {
                _ = snprintf(&buf, buf.len, "term=%s", optarg);
                if (!addOverride(&overrides, &total_len, @ptrCast(&buf))) return ret;
            },
            'T' => {
                _ = snprintf(&buf, buf.len, "title=%s", optarg);
                if (!addOverride(&overrides, &total_len, @ptrCast(&buf))) return ret;
            },
            'a' => {
                _ = snprintf(&buf, buf.len, "app-id=%s", optarg);
                if (!addOverride(&overrides, &total_len, @ptrCast(&buf))) return ret;
            },
            TOPLEVEL_TAG_OPTION => {
                _ = snprintf(&buf, buf.len, "toplevel-tag=%s", optarg);
                if (!addOverride(&overrides, &total_len, @ptrCast(&buf))) return ret;
            },
            'L' => if (!addOverride(&overrides, &total_len, "login-shell=yes")) return ret,
            'D' => {
                var scheme: [*c]u8 = null;
                var host: [*c]u8 = null;
                var path: [*c]u8 = null;
                if (uri_parse(optarg, strlen(optarg), &scheme, null, null, &host, null, &path, null, null)) {
                    const local = streq(scheme, "file") and hostname_is_localhost(host);
                    if (!local) {
                        _ = fprintf(stderr, "error: %s: not a local path\n", optarg);
                        free(scheme);
                        free(host);
                        free(path);
                        return ret;
                    }
                    custom_cwd = @ptrCast(path);
                    path = null;
                } else {
                    custom_cwd = xstrdup(optarg);
                }
                free(scheme);
                free(host);
                free(path);

                if (custom_cwd) |cwd_path| {
                    var st: Stat = undefined;
                    if (stat(cwd_path, &st) < 0 or (statMode(&st) & S_IFDIR) == 0) {
                        _ = fprintf(stderr, "error: %s: not a directory\n", optarg);
                        return ret;
                    }
                }
            },
            'w', 'W' => {
                var width: c_uint = 0;
                var height: c_uint = 0;
                const valid = client_shim_parse_window_size(optarg, &width, &height);
                if (!valid) {
                    const message = if (c == 'w') "error: invalid window-size-pixels: %s\n" else "error: invalid window-size-chars: %s\n";
                    _ = fprintf(stderr, message, optarg);
                    return ret;
                }
                const format = if (c == 'w') "initial-window-size-pixels=%ux%u" else "initial-window-size-chars=%ux%u";
                _ = snprintf(&buf, buf.len, format, width, height);
                if (!addOverride(&overrides, &total_len, @ptrCast(&buf))) return ret;
            },
            'm' => if (!addOverride(&overrides, &total_len, "initial-window-mode=maximized")) return ret,
            'F' => if (!addOverride(&overrides, &total_len, "initial-window-mode=fullscreen")) return ret,
            's' => server_socket_path = @ptrCast(optarg),
            'H' => hold = true,
            'N' => no_wait = true,
            'o' => if (!addOverride(&overrides, &total_len, optarg)) return ret,
            'E' => client_environment = true,
            'd' => {
                const level = log_level_from_string(optarg);
                if (level < 0) {
                    _ = fprintf(stderr, "-d,--log-level: %s: argument must be one of %s\n", optarg, log_level_string_hint());
                    return ret;
                }
                log_level = level;
            },
            'l' => {
                if (optarg == null or streq(optarg, "auto"))
                    log_colorize = 2
                else if (streq(optarg, "never"))
                    log_colorize = 0
                else if (streq(optarg, "always"))
                    log_colorize = 1
                else {
                    _ = fprintf(stderr, "%s: argument must be one of 'never', 'always' or 'auto'\n", optarg);
                    return ret;
                }
            },
            'v' => {
                printVersionAndFeatures();
                return EXIT_SUCCESS;
            },
            'h' => {
                printUsage(prog);
                return EXIT_SUCCESS;
            },
            'e' => {},
            '?' => return ret,
            else => return ret,
        }
    }

    var slave_argc = argc;
    var slave_argv = argv;
    if (argc > 0) {
        slave_argc -= optind;
        slave_argv += @intCast(optind);
    }

    log_init(log_colorize, false, LOG_FACILITY_USER, log_level);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == -1) {
        logErrno("failed to create socket", .{});
        return ret;
    }

    var addr = initSocketAddr();
    if (server_socket_path) |path| {
        setSocketPath(&addr, path);
        if (connect(fd, &addr, @sizeOf(SockaddrUn)) < 0) {
            logErr("{s}: failed to connect (is 'zigfoot --server' running?)", .{std.mem.span(path).ptr});
            return ret;
        }
    } else {
        var connected = false;
        const xdg_runtime = getenv("XDG_RUNTIME_DIR");
        if (xdg_runtime != null) {
            const wayland_display = getenv("WAYLAND_DISPLAY");
            if (wayland_display != null) {
                _ = snprintf(&addr.path, addr.path.len, "%s/zigfoot-%s.sock", xdg_runtime, wayland_display);
                connected = connect(fd, &addr, @sizeOf(SockaddrUn)) == 0;
            }
            if (!connected) {
                logWarn("{s}: failed to connect, will now try {s}/zigfoot.sock", .{ std.mem.span(@as([*:0]const u8, @ptrCast(&addr.path))).ptr, std.mem.span(xdg_runtime).ptr });
                _ = snprintf(&addr.path, addr.path.len, "%s/zigfoot.sock", xdg_runtime);
                connected = connect(fd, &addr, @sizeOf(SockaddrUn)) == 0;
            }
            if (!connected)
                logWarn("{s}: failed to connect, will now try /tmp/zigfoot.sock", .{std.mem.span(@as([*:0]const u8, @ptrCast(&addr.path))).ptr});
        }
        if (!connected) {
            setSocketPath(&addr, "/tmp/zigfoot.sock");
            if (connect(fd, &addr, @sizeOf(SockaddrUn)) < 0) {
                logErrno("failed to connect (is 'zigfoot --server' running?)", .{});
                return ret;
            }
        }
    }

    const exe = getFootclientExe();
    var cwd: [*:0]const u8 = custom_cwd orelse ".";
    if (custom_cwd == null) {
        var capacity: usize = 1024;
        while (true) {
            cwd_buffer = @ptrCast(xrealloc(cwd_buffer, capacity));
            std.c._errno().* = 0;
            const buffer = cwd_buffer orelse unreachable;
            if (getcwd(buffer, capacity) == null and errno() != ERANGE) {
                logErrno("failed to get current working directory", .{});
                return ret;
            }
            if (errno() != ERANGE)
                break;
            capacity *%= 2;
        }
        cwd = @ptrCast(cwd_buffer orelse unreachable);
    }

    const pwd = getenv("PWD");
    if (pwd != null) {
        const resolved_cwd = realpath(cwd, null);
        const resolved_pwd = realpath(pwd, null);
        if (resolved_cwd) |left| {
            if (resolved_pwd) |right| {
                if (streq(left, right))
                    cwd = @ptrCast(pwd);
            }
        }
        free(resolved_cwd);
        free(resolved_pwd);
    }

    if (client_environment) {
        var env_it = environ;
        while (env_it[0]) |entry| : (env_it += 1) {
            if (!envp.push(entry, &total_len))
                return ret;
        }
    }

    const exe_len = strlen(exe) + 1;
    const cwd_len = strlen(cwd) + 1;
    const override_count = overrides.count;
    const env_count = envp.count;
    const data = types.ClientData{
        ._bits = @as(u8, @intFromBool(hold)) |
            (@as(u8, @intFromBool(no_wait)) << 1) |
            (@as(u8, @intFromBool(xdga_token)) << 2),
        .token_len = @truncate(token_len),
        .exe_len = @truncate(exe_len),
        .cwd_len = @truncate(cwd_len),
        .override_count = @truncate(override_count),
        .foot_argc = @truncate(@as(u32, @bitCast(foot_argc))),
        .slave_argc = @truncate(@as(u32, @bitCast(slave_argc))),
        .env_count = @truncate(env_count),
    };
    total_len +%= @sizeOf(types.ClientData) + exe_len + cwd_len + token_len;

    if (foot_argc > 0)
        cfoot_argv = @ptrCast(@alignCast(xmalloc(@as(usize, @intCast(foot_argc)) * @sizeOf(types.ClientString))));
    if (cfoot_argv) |args| {
        const original = foot_argv orelse unreachable;
        for (0..@as(usize, @intCast(foot_argc))) |i| {
            const len = strlen(original[i]) + 1;
            if (len >= MAX_STRING_LEN) {
                logErr("argv length overflow", .{});
                return ret;
            }
            args[i].len = @intCast(len);
            total_len +%= @sizeOf(types.ClientString) + len;
        }
    }

    if (slave_argc > 0)
        cslave_argv = @ptrCast(@alignCast(xmalloc(@as(usize, @intCast(slave_argc)) * @sizeOf(types.ClientString))));
    if (cslave_argv) |args| {
        for (0..@as(usize, @intCast(slave_argc))) |i| {
            const len = strlen(slave_argv[i]) + 1;
            if (len >= MAX_STRING_LEN) {
                logErr("argv length overflow", .{});
                return ret;
            }
            args[i].len = @intCast(len);
            total_len +%= @sizeOf(types.ClientString) + len;
        }
    }

    if (total_len >= MAX_PACKET_LEN or exe_len >= MAX_STRING_LEN or
        cwd_len >= MAX_STRING_LEN or token_len >= 256 or
        override_count > data.override_count or foot_argc > data.foot_argc or
        slave_argc > data.slave_argc or env_count > data.env_count)
    {
        logErr("size overflow", .{});
        return ret;
    }

    const packet_len: u32 = @truncate(total_len);
    if (client_shim_sendall(fd, @ptrCast(&packet_len), @sizeOf(u32)) < 0 or
        client_shim_sendall(fd, @ptrCast(&data), @sizeOf(types.ClientData)) < 0 or
        client_shim_sendall(fd, exe, exe_len) < 0 or
        client_shim_sendall(fd, cwd, cwd_len) < 0)
    {
        logErrno("failed to send setup packet to server", .{});
        return ret;
    }

    if (xdga_token) {
        if (client_shim_sendall(fd, token, token_len) != @as(isize, @bitCast(token_len))) {
            logErrno("failed to send xdg activation token to server", .{});
            return ret;
        }
    }
    if (!overrides.sendAll(fd))
        return ret;

    if (cfoot_argv) |args| {
        const original = foot_argv orelse unreachable;
        for (0..@as(usize, @intCast(foot_argc))) |i| {
            if (client_shim_sendall(fd, @ptrCast(&args[i]), @sizeOf(types.ClientString)) < 0 or
                client_shim_sendall(fd, original[i], args[i].len) < 0)
            {
                logErrno("failed to send setup packet (foot argv) to server", .{});
                return ret;
            }
        }
    }
    if (cslave_argv) |args| {
        for (0..@as(usize, @intCast(slave_argc))) |i| {
            if (client_shim_sendall(fd, @ptrCast(&args[i]), @sizeOf(types.ClientString)) < 0 or
                client_shim_sendall(fd, slave_argv[i], args[i].len) < 0)
            {
                logErrno("failed to send setup packet (slave argv) to server", .{});
                return ret;
            }
        }
    }
    if (!envp.sendAll(fd))
        return ret;

    var sa_int = std.posix.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var sa_usr = std.posix.Sigaction{
        .handler = .{ .handler = &sigusrHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    _ = sigemptyset(&sa_int.mask);
    _ = sigemptyset(&sa_usr.mask);
    if (sigaction(@backingInt(std.posix.SIG.INT), &sa_int, null) < 0 or
        sigaction(@backingInt(std.posix.SIG.TERM), &sa_int, null) < 0 or
        sigaction(@backingInt(std.posix.SIG.USR1), &sa_usr, null) < 0 or
        sigaction(@backingInt(std.posix.SIG.USR2), &sa_usr, null) < 0)
    {
        logErrno("failed to register signal handlers", .{});
        return ret;
    }

    var exit_code: c_int = 0;
    var received: isize = -1;
    while (true) {
        received = recv(fd, &exit_code, @sizeOf(c_int), 0);
        const got_sigusr = sigusr;
        sigusr = 0;
        if (received < 0 and errno() == EINTR) {
            if (aborted != 0)
                break;
            if (got_sigusr != 0) {
                var ipc: [9]u8 = undefined;
                const ipc_len = client_shim_sigusr_ipc(&ipc, got_sigusr);
                const count = send(fd, &ipc, ipc_len, 0);
                if (count < 0) {
                    logErrno("failed to send SIGUSR IPC to server", .{});
                    return ret;
                } else if (count != ipc_len) {
                    logErr("failed to send SIGUSR IPC to server", .{});
                    return ret;
                }
            }
            continue;
        }
        break;
    }

    if (received == -1 and errno() == EINTR)
        std.debug.assert(aborted != 0)
    else if (received != @sizeOf(c_int))
        logErrno("failed to read server response", .{})
    else
        ret = exit_code;
    return ret;
}

comptime {
    if (build_options.client_entrypoint)
        @export(&footclient_main, .{ .name = "main" });
}
