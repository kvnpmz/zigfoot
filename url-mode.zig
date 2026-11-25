//! Zig port of url-mode.c (D5c): URL detection in the visible screen,
//! jump-label assignment, and the URL-mode input/render/reset lifecycle.
//!
//! URLs come from two sources: OSC-8 hyperlink ranges already recorded on the
//! rows, and regex matches over the visible text (each logical line is
//! flattened to utf8 with a byte→cell coordinate map). Overlaps between OSC-8
//! URLs are resolved by marking one duplicate. Key combos are generated from
//! the configured label alphabet (base-N counting, built reversed and then
//! flipped), and reused when the same URL appears twice.
//!
//! regex_t's internals are libc-specific, so the regexec() call itself lives
//! in url_shim_regex_match() (terminal-shim.c); everything around it is here.

const std = @import("std");
const types = @import("terminal_types.zig");
const tll = @import("tll.zig");

const Terminal = types.Terminal;
const Seat = types.Seat;
const Config = types.Config;
const Url = types.Url;
const UrlList = types.UrlList;
const KeyBinding = types.KeyBinding;
const KeyBindingSet = types.KeyBindingSet;

const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;
const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fff_ffff;
const CELL_SPACER: u32 = CELL_COMB_CHARS_HI + 1;

// key-binding.h's enum bind_action_url
const BIND_ACTION_URL_NONE: c_int = 0;
const BIND_ACTION_URL_CANCEL: c_int = 1;
const BIND_ACTION_URL_TOGGLE_URL_ON_JUMP_LABEL: c_int = 2;

const O_RDWR: c_int = 2;

/// url-mode.h's static inline, exported under the existing C ABI name for
/// commands, input and render.
export fn terminal_shim_urls_mode_active(term: *const Terminal) callconv(.c) bool {
    return term.url.list.length > 0;
}

extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn xreallocarray(ptr: ?*anyopaque, nmemb: usize, size: usize) callconv(.c) ?*anyopaque;
extern fn xstrdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8;
extern fn xstrndup(s: [*:0]const u8, n: usize) callconv(.c) ?[*:0]u8;
extern fn xc32dup(s: ?[*:0]const u32) callconv(.c) ?[*:0]u32;
extern fn c32rtomb(s: [*]u8, wc: u32, ps: *anyopaque) callconv(.c) usize;
extern fn c32cpy(dst: [*]u32, src: [*]const u32) callconv(.c) [*]u32;
extern fn c32ncasecmp(s1: [*]const u32, s2: [*]const u32, n: usize) callconv(.c) c_int;
extern fn toc32lower(c: u32) callconv(.c) u32;
extern fn toc32upper(c: u32) callconv(.c) u32;
extern fn xkb_state_key_get_utf32(state: ?*anyopaque, key: u32) callconv(.c) u32;
extern fn rand() callconv(.c) c_int;

extern fn composed_lookup(root: ?*types.Composed, key: u32) callconv(.c) ?*types.Composed;
extern fn grid_snapshot(grid: *const types.Grid) callconv(.c) *types.Grid;
extern fn grid_free(grid: ?*types.Grid) callconv(.c) void;
extern fn terminal_shim_grid_row_in_view(grid: *types.Grid, row: c_int) callconv(.c) ?*types.Row;

extern fn wayl_win_subsurface_new(win: *types.WlWindow, surf: *types.WaylSubSurface, allow_pointer_input: bool) callconv(.c) bool;
extern fn wayl_win_subsurface_destroy(surf: ?*types.WaylSubSurface) callconv(.c) void;
extern fn wayl_get_activation_token(
    wayl: *types.Wayland,
    seat: ?*types.Seat,
    serial: u32,
    win: *types.WlWindow,
    cb: types.ActivationTokenCb,
    cb_data: ?*anyopaque,
) callconv(.c) bool;

extern fn spawn(
    reaper: ?*anyopaque,
    cwd: [*c]const u8,
    argv: [*c]const [*c]u8,
    stdin_fd: c_int,
    stdout_fd: c_int,
    stderr_fd: c_int,
    cb: ?*const anyopaque,
    cb_data: ?*anyopaque,
    xdg_activation_token: [*c]const u8,
) callconv(.c) c_int;
extern fn spawn_expand_template(
    template: *const types.ConfigSpawnTemplate,
    key_count: usize,
    key_names: ?[*]const ?[*:0]const u8,
    key_values: ?[*]const ?[*:0]const u8,
    argc: *usize,
    argv: *?[*:null]?[*:0]u8,
) callconv(.c) bool;

extern fn text_to_clipboard(seat: ?*anyopaque, term: *Terminal, text: ?[*:0]u8, serial: u32) callconv(.c) bool;
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

extern fn term_to_slave(term: *Terminal, data: ?*const anyopaque, len: usize) callconv(.c) bool;
extern fn term_damage_view(term: *Terminal) callconv(.c) void;
extern fn render_refresh(term: *Terminal) callconv(.c) void;
extern fn render_refresh_urls(term: *Terminal) callconv(.c) void;
extern fn term_ime_is_enabled(term: *const Terminal) callconv(.c) bool;
extern fn term_ime_enable(term: *Terminal) callconv(.c) void;
extern fn term_ime_disable(term: *Terminal) callconv(.c) void;

extern fn url_shim_regex_match(
    preg: ?*const anyopaque,
    str: [*:0]const u8,
    so0: *usize,
    eo0: *usize,
    so1: *usize,
    eo1: *usize,
) callconv(.c) bool;

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) callconv(.c) void;

const LOG_CLASS_ERROR: c_int = 1;

/// free() for any optional pointer type (many-pointers included).
fn freeSlice(p: anytype) void {
    if (p) |q| free(@ptrCast(q));
}

fn c32Len(s: [*]const u32) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn streq(a: ?[*:0]const u8, b: ?[*:0]const u8) bool {
    const ap = a orelse return false;
    const bp = b orelse return false;
    return std.mem.eql(u8, std.mem.span(ap), std.mem.span(bp));
}

fn urlList(term: *Terminal) *tll.Tll(Url) {
    return @ptrCast(&term.url.list);
}

// ─────────────────────────────────────────────────────────────────────────
// URL-mode key bindings
// ─────────────────────────────────────────────────────────────────────────

fn executeBinding(
    seat: *Seat,
    term: *Terminal,
    binding: *const KeyBinding,
    serial: u32,
) bool {
    _ = seat;
    _ = serial;
    const action = binding.action;

    if (action == BIND_ACTION_URL_NONE)
        return false;

    if (action == BIND_ACTION_URL_CANCEL) {
        urls_reset(term);
        return true;
    }

    if (action == BIND_ACTION_URL_TOGGLE_URL_ON_JUMP_LABEL) {
        term.url.show_uri_on_jump_label = !term.url.show_uri_on_jump_label;
        render_refresh_urls(term);
        return true;
    }

    // BIND_ACTION_URL_COUNT
    return false;
}

// ─────────────────────────────────────────────────────────────────────────
// Activation / spawning
// ─────────────────────────────────────────────────────────────────────────

fn spawnUrlLauncherWithToken(
    term: *Terminal,
    url: [*:0]const u8,
    xdg_activation_token: ?[*:0]const u8,
) bool {
    const dev_null = open("/dev/null", O_RDWR);
    if (dev_null < 0) {
        log_errno(LOG_CLASS_ERROR, "url-mode", "url-mode.zig", @intCast(@src().line), "failed to open /dev/null");
        return false;
    }

    const launch: *const types.ConfigSpawnTemplate =
        @ptrCast(@alignCast(term.url.launch orelse unreachable));

    var ret = false;

    const names = [2]?[*:0]const u8{ "url", "match" };
    const values = [2]?[*:0]const u8{ url, url };

    var argc: usize = 0;
    var argv: ?[*:null]?[*:0]u8 = null;

    if (spawn_expand_template(launch, 2, &names, &values, &argc, &argv)) {
        const cwd: [*c]const u8 = if (term.cwd) |c| c else null;
        const token: [*c]const u8 = if (xdg_activation_token) |t| t else null;

        ret = spawn(term.reaper, cwd, @ptrCast(argv), dev_null, dev_null, dev_null, null, null, token) >= 0;

        var i: usize = 0;
        while (i < argc) : (i += 1)
            free(argv.?[i]);
        free(@ptrCast(argv));
    }

    _ = close(dev_null);
    return ret;
}

const SpawnActivationContext = extern struct {
    term: *Terminal,
    url: ?[*:0]u8,
};

fn activationTokenDone(token: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const ctx: *SpawnActivationContext = @ptrCast(@alignCast(data orelse return));

    _ = spawnUrlLauncherWithToken(ctx.term, ctx.url orelse "", token);
    free(ctx.url);
    free(ctx);
}

fn spawnUrlLauncher(
    seat: *Seat,
    term: *Terminal,
    url: [*:0]const u8,
    serial: u32,
) bool {
    std.debug.assert(term.url.launch != null);

    const raw = xmalloc(@sizeOf(SpawnActivationContext)) orelse unreachable;
    const ctx: *SpawnActivationContext = @ptrCast(@alignCast(raw));
    ctx.* = .{
        .term = term,
        .url = xstrdup(url),
    };

    if (wayl_get_activation_token(seat.wayl.?, seat, serial, term.window.?, &activationTokenDone, ctx)) {
        // Context free:d by callback
        return true;
    }

    free(ctx.url);
    free(ctx);

    return spawnUrlLauncherWithToken(term, url, null);
}

fn activateUrl(
    seat: *Seat,
    term: *Terminal,
    url: *const Url,
    serial: u32,
    paste_url_to_self: bool,
) void {
    var url_string: ?[*:0]u8 = null;

    var scheme: [*c]u8 = null;
    var host: [*c]u8 = null;
    var path: [*c]u8 = null;

    const raw = url.url orelse "";

    if (uri_parse(&raw[0], std.mem.len(raw), &scheme, null, null, &host, null, &path, null, null)) {
        const scheme_z: [*:0]const u8 = @ptrCast(scheme);
        if (std.mem.eql(u8, std.mem.span(scheme_z), "file") and hostname_is_localhost(host)) {
            // This is a file in *this* computer. Pass only the filename to
            // the URL-launcher, i.e. strip the ‘file://user@host/’ prefix.
            url_string = @ptrCast(path);
        } else {
            free(path);
        }

        free(scheme);
        free(host);
    }

    if (url_string == null)
        url_string = xstrdup(url.url.?);

    switch (url.action) {
        .COPY => {
            if (paste_url_to_self) {
                if (term.bracketed_paste)
                    _ = term_to_slave(term, "\x1b[200~", 6);

                _ = term_to_slave(term, @ptrCast(url_string.?), std.mem.len(url_string.?));

                if (term.bracketed_paste)
                    _ = term_to_slave(term, "\x1b[201~", 6);
            }
            if (text_to_clipboard(seat, term, url_string, seat.kbd.serial)) {
                // Now owned by our clipboard “manager”
                url_string = null;
            }
        },

        .LAUNCH, .PERSISTENT => {
            _ = spawnUrlLauncher(seat, term, url_string.?, serial);
        },
    }

    free(url_string);
}

export fn urls_input(
    seat: *Seat,
    term: *Terminal,
    bindings: *const KeyBindingSet,
    key: u32,
    sym: u32,
    mods: u32,
    consumed: u32,
    raw_syms: [*c]const u32,
    raw_count: usize,
    serial: u32,
) callconv(.c) void {
    const url_bindings: *tll.Tll(KeyBinding) = @ptrCast(@constCast(&bindings.url));

    // Match untranslated symbols
    var it = url_bindings.foreach();
    while (it.next()) |node| {
        const bind = &node.item;
        if (bind.mods != mods or bind.mods == 0)
            continue;

        var i: usize = 0;
        while (i < raw_count) : (i += 1) {
            if (bind._u.k.sym == raw_syms[i]) {
                _ = executeBinding(seat, term, bind, serial);
                seat.kbd.last_shortcut_sym = sym;
                return;
            }
        }
    }

    // Match translated symbol
    it = url_bindings.foreach();
    while (it.next()) |node| {
        const bind = &node.item;

        if (bind._u.k.sym == sym and bind.mods == (mods & ~consumed)) {
            _ = executeBinding(seat, term, bind, serial);
            seat.kbd.last_shortcut_sym = sym;
            return;
        }
    }

    // Match raw key code
    it = url_bindings.foreach();
    while (it.next()) |node| {
        const bind = &node.item;
        if (bind.mods != mods or bind.mods == 0)
            continue;

        const key_codes: *tll.Tll(u32) = @ptrCast(@constCast(&bind._u.k.key_codes));
        var code_it = key_codes.foreach();
        while (code_it.next()) |code| {
            if (code.item == key) {
                _ = executeBinding(seat, term, bind, serial);
                seat.kbd.last_shortcut_sym = sym;
                return;
            }
        }
    }

    const keys_ptr: [*]u32 = @ptrCast(&term.url.keys);
    const seq_len = c32Len(keys_ptr);

    if (sym == XKB_KEY_BackSpace) {
        if (seq_len > 0) {
            keys_ptr[seq_len - 1] = 0;
            render_refresh_urls(term);
        }

        return;
    }

    if (mods & ~consumed != 0)
        return;

    const wc = xkb_state_key_get_utf32(seat.kbd.xkb_state, key);

    // Determine if this is a "valid" key. I.e. if there is a URL label with a
    // key combo where this key is the next in sequence.
    var is_valid = false;
    var match: ?*const Url = null;

    const urls = urlList(term);
    var url_it = urls.foreach();
    while (url_it.next()) |node| {
        const url = &node.item;

        const key_ptr = url.key orelse continue;
        const key_len = c32Len(key_ptr);

        if (key_len >= seq_len + 1 and
            c32ncasecmp(key_ptr, keys_ptr, seq_len) == 0 and
            toc32lower(key_ptr[seq_len]) == toc32lower(wc))
        {
            is_valid = true;
            if (key_len == seq_len + 1) {
                match = url;
                break;
            }
        }
    }

    if (match) |m| {
        // If the last hint character was uppercase, copy and paste
        const insert = (term.conf.?.uppercase_regex_insert and wc == toc32upper(wc));
        activateUrl(seat, term, m, serial, insert);

        switch (m.action) {
            .COPY, .LAUNCH => urls_reset(term),

            .PERSISTENT => {
                keys_ptr[0] = 0;
                render_refresh_urls(term);
            },
        }
    } else if (is_valid) {
        std.debug.assert(seq_len + 1 <= term.url.keys.len);
        keys_ptr[seq_len] = wc;
        render_refresh_urls(term);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Detection
// ─────────────────────────────────────────────────────────────────────────

const Vline = extern struct {
    utf8: ?[*]u8,
    len: usize, // Length of utf8[]
    sz: usize, // utf8[] allocated size
    map: ?[*]types.Coord, // Maps utf8[ofs] to grid coordinates
};

const XKB_KEY_BackSpace: u32 = 0xff08;

fn regexDetected(
    term: *const Terminal,
    action: types.UrlAction,
    preg: ?*const anyopaque,
    urls: *tll.Tll(Url),
) void {
    // Each string represents a logical line (i.e. handle line-wrap). To map
    // regex matches back to the grid, the grid coordinates of *each*
    // character are stored too; utf8[ofs] has its coordinates in map[ofs].

    const vline_count: usize = @intCast(term.rows);
    const raw_vlines = xmalloc(vline_count * @sizeOf(Vline)) orelse unreachable;
    defer free(raw_vlines);
    const vlines: [*]Vline = @ptrCast(@alignCast(raw_vlines));

    var vline_idx: usize = 0;
    for (vlines[0..vline_count]) |*v|
        v.* = .{ .utf8 = null, .len = 0, .sz = 0, .map = null };

    var vline = &vlines[vline_idx];

    // glibc's mbstate_t is 8 bytes.
    var ps: [8]u8 align(4) = .{0} ** 8;

    const grid = term.grid orelse return;
    const view = grid.view;

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const row = terminal_shim_grid_row_in_view(grid, r) orelse continue;

        var c: c_int = 0;
        while (c < term.cols) : (c += 1) {
            const cell = &row.cells.?[@intCast(c)];

            var wc: [*]const u32 = @ptrCast(&cell.wc);
            var wc_count: usize = 1;

            // Expand combining characters
            if (cell.wc >= CELL_COMB_CHARS_LO and cell.wc <= CELL_COMB_CHARS_HI) {
                const composed = composed_lookup(term.composed, cell.wc - CELL_COMB_CHARS_LO) orelse unreachable;

                wc = composed.chars.?;
                wc_count = composed.count;
            } else if (cell.wc >= CELL_SPACER) {
                continue;
            }

            // Convert wide character to utf8
            var i: usize = 0;
            while (i < wc_count) : (i += 1) {
                var buf: [16]u8 = undefined;
                const char_len = c32rtomb(&buf, wc[i], @ptrCast(&ps));

                if (char_len == std.math.maxInt(usize))
                    continue;

                var j: usize = 0;
                while (j < char_len) : (j += 1) {
                    const requires_size = vline.len + char_len;

                    // Need to grow? Remember to save at least one byte for
                    // the terminator.
                    if (vline.sz == 0 or requires_size > vline.sz - 1) {
                        const new_size = requires_size * 2;
                        vline.utf8 = @ptrCast(@alignCast(xreallocarray(if (vline.utf8) |p| @as(?*anyopaque, @ptrCast(p)) else null, new_size, 1)));
                        vline.map = @ptrCast(@alignCast(xreallocarray(if (vline.map) |p| @as(?*anyopaque, @ptrCast(p)) else null, new_size, @sizeOf(types.Coord))));
                        vline.sz = new_size;
                    }

                    vline.utf8.?[vline.len + j] =
                        if (buf[j] == 0) ' ' else buf[j];
                    vline.map.?[vline.len + j] = .{ .col = c, .row = view + r };
                }

                vline.len += char_len;
            }
        }

        if (row.linebreak) {
            if (vline.len > 0) {
                vline.utf8.?[vline.len] = 0;
                vline.len += 1;
                ps = .{0} ** 8;

                vline_idx += 1;
                vline = &vlines[vline_idx];
            }
        }
    }

    // Terminate the last line, if necessary
    if (vline_idx < vline_count and
        vline.len > 0 and vline.utf8.?[vline.len - 1] != 0)
    {
        vline.utf8.?[vline.len] = 0;
        vline.len += 1;
    }

    for (vlines[0..vline_count]) |*v| {
        const str = v.utf8 orelse continue;

        var search_ofs: usize = 0;
        while (true) {
            var so0: usize = undefined;
            var eo0: usize = undefined;
            var so1: usize = undefined;
            var eo1: usize = undefined;

            const str_z: [*:0]const u8 = @ptrCast(str + search_ofs);
            if (!url_shim_regex_match(preg, str_z, &so0, &eo0, &so1, &eo1))
                break;

            const mlen = eo1 - so1;
            const start = search_ofs + so1;
            const end = start + mlen;

            const url_id: u64 = (@as(u64, @intCast(@as(u32, @bitCast(rand())))) << 32) |
                @as(u32, @bitCast(rand()));

            urls.pushBack(.{
                .id = url_id,
                .url = xstrndup(@ptrCast(str + start), mlen),
                .key = null,
                .range = .{
                    .start = v.map.?[start],
                    .end = v.map.?[end - 1], // Inclusive
                },
                .action = action,
                .url_mode_dont_change_url_attr = false,
                .osc8 = false,
                .duplicate = false,
            });

            search_ofs += eo0;
        }

        free(str);
        free(v.map);
    }
}

fn osc8Uris(
    term: *const Terminal,
    action: types.UrlAction,
    urls: *tll.Tll(Url),
) void {
    const dont_touch_url_attr = switch (term.conf.?.url.osc8_underline) {
        .url_mode => false,
        .always => true,
    };

    const grid = term.grid orelse return;

    var r: c_int = 0;
    while (r < term.rows) : (r += 1) {
        const row = terminal_shim_grid_row_in_view(grid, r) orelse continue;
        const extra = row.extra orelse continue;

        var i: usize = 0;
        while (i < @as(usize, @intCast(extra.uri_ranges.count))) : (i += 1) {
            const range = &extra.uri_ranges.v.?[i];

            const start: types.Coord = .{ .col = range.start, .row = r + grid.view };
            const end: types.Coord = .{ .col = range.end, .row = r + grid.view };

            urls.pushBack(.{
                .id = range.data.uri.id,
                .url = xstrdup(range.data.uri.uri.?),
                .key = null,
                .range = .{ .start = start, .end = end },
                .action = action,
                .url_mode_dont_change_url_attr = dont_touch_url_attr,
                .osc8 = true,
                .duplicate = false,
            });
        }
    }
}

fn removeOverlapping(urls: *tll.Tll(Url), cols: c_int) void {
    var outer = urls.foreach();
    while (outer.next()) |outer_node| {
        const out_url = &outer_node.item;

        var inner = urls.foreach();
        while (inner.next()) |inner_node| {
            if (outer_node == inner_node)
                continue;

            const in_url = &inner_node.item;

            const in_start: u64 = @as(u64, @intCast(in_url.range.start.row)) * @as(u64, @intCast(cols)) +
                @as(u64, @intCast(in_url.range.start.col));
            const in_end: u64 = @as(u64, @intCast(in_url.range.end.row)) * @as(u64, @intCast(cols)) +
                @as(u64, @intCast(in_url.range.end.col));

            const out_start: u64 = @as(u64, @intCast(out_url.range.start.row)) * @as(u64, @intCast(cols)) +
                @as(u64, @intCast(out_url.range.start.col));
            const out_end: u64 = @as(u64, @intCast(out_url.range.end.row)) * @as(u64, @intCast(cols)) +
                @as(u64, @intCast(out_url.range.end.col));

            if ((in_start <= out_start and in_end >= out_start) or
                (in_start <= out_end and in_end >= out_end) or
                (in_start >= out_start and in_end <= out_end))
            {
                // OSC-8 URLs can't overlap with each other. Similarly,
                // auto-detected URLs cannot overlap with each other. But
                // OSC-8 URLs can overlap with auto-detected ones.
                std.debug.assert(in_url.osc8 or out_url.osc8);

                if (in_url.osc8)
                    outer_node.item.duplicate = true
                else
                    inner_node.item.duplicate = true;
            }
        }
    }

    var it = urls.foreach();
    while (it.next()) |node| {
        if (node.item.duplicate) {
            urlDestroy(&node.item);
            urls.removeNode(node);
        }
    }
}

export fn urls_collect(
    term: ?*const Terminal,
    action: types.UrlAction,
    preg: ?*const anyopaque,
    osc8: bool,
    urls_in: ?*anyopaque,
) callconv(.c) void {
    const t = term orelse return;
    const urls: *tll.Tll(Url) = @ptrCast(@alignCast(urls_in orelse return));

    std.debug.assert(urlList(@constCast(t)).len() == 0);
    if (osc8)
        osc8Uris(t, action, urls);
    regexDetected(t, action, preg, urls);
    removeOverlapping(urls, t.grid.?.num_cols);
}

const EMPTY_C32: [1:0]u32 = .{0};

fn generateKeyCombos(
    conf: *const Config,
    count: usize,
    combos: [*]?[*:0]u32,
) void {
    const alphabet = conf.url.label_letters.?;
    const alphabet_len = c32Len(alphabet);

    var hints_count: usize = 1;
    var hints: [*]?[*:0]u32 = @ptrCast(@alignCast(xmalloc(hints_count * @sizeOf(?[*:0]u32)) orelse unreachable));

    hints[0] = xc32dup(&EMPTY_C32);

    var offset: usize = 0;
    while (true) {
        const prefix: [*:0]const u32 = hints[offset] orelse &EMPTY_C32;
        offset += 1;
        const prefix_len = c32Len(prefix);

        hints = @ptrCast(@alignCast(xrealloc(@ptrCast(hints), (hints_count + alphabet_len) * @sizeOf(?[*:0]u32)) orelse unreachable));

        var i: usize = 0;
        while (i < alphabet_len) : (i += 1) {
            const hint = xmalloc((prefix_len + 1 + 1) * @sizeOf(u32)) orelse unreachable;
            const hint_c32: [*]u32 = @ptrCast(@alignCast(hint));
            hints[hints_count + i] = @ptrCast(hint_c32);

            // Will be reversed later
            hint_c32[0] = alphabet[i];
            _ = c32cpy(hint_c32 + 1, prefix);
        }
        hints_count += alphabet_len;

        if (hints_count - offset >= count)
            break;
    }

    std.debug.assert(hints_count - offset >= count);

    // Copy slice of 'hints' array to the caller provided array
    var i: usize = 0;
    while (i < hints_count) : (i += 1) {
        if (i >= offset and i < offset + count)
            combos[i - offset] = hints[i]
        else
            free(hints[i]);
    }
    free(@as(?*anyopaque, @ptrCast(hints)));

    // Reverse all strings
    i = 0;
    while (i < count) : (i += 1) {
        const combo = combos[i].?;
        const len = c32Len(combo);
        var j: usize = 0;
        while (j < len / 2) : (j += 1) {
            const tmp = combo[j];
            combo[j] = combo[len - j - 1];
            combo[len - j - 1] = tmp;
        }
    }
}

export fn urls_assign_key_combos(
    conf: ?*const Config,
    urls_in: ?*anyopaque,
) callconv(.c) void {
    const c = conf orelse return;
    const urls: *tll.Tll(Url) = @ptrCast(@alignCast(urls_in orelse return));

    const count = urls.len();
    if (count == 0)
        return;

    const raw_combos = xmalloc(count * @sizeOf(?[*:0]u32)) orelse unreachable;
    defer free(raw_combos);
    const combos: [*]?[*:0]u32 = @ptrCast(@alignCast(raw_combos));

    generateKeyCombos(c, count, combos);

    var combo_idx: usize = 0;
    var it: ?*tll.Tll(Url).Node = urls.tail;
    while (it) |node| : (it = node.prev) {
        var id_already_seen = false;

        // Look for already processed URLs where both the URI and the ID match
        var it2 = urls.tail;
        while (it2 != null and it2 != node) : (it2 = it2.?.prev) {
            if (node.item.id == it2.?.item.id and streq(node.item.url, it2.?.item.url)) {
                id_already_seen = true;
                break;
            }
        }

        if (id_already_seen)
            continue;

        // Scan previous URLs, and check if *this* URL matches any of them; if
        // so, reuse the *same* key combo.
        var url_already_seen = false;
        it2 = urls.tail;
        while (it2 != null and it2 != node) : (it2 = it2.?.prev) {
            if (streq(node.item.url, it2.?.item.url)) {
                node.item.key = xc32dup(if (it2.?.item.key) |k| @ptrCast(k) else null);
                url_already_seen = true;
                break;
            }
        }

        if (!url_already_seen) {
            node.item.key = combos[combo_idx];
            combo_idx += 1;
        }
    }

    // Free combos we didn't use up
    var i: usize = combo_idx;
    while (i < count) : (i += 1)
        free(combos[i]);
}

fn tagCellsForUrl(term: *Terminal, url: *const Url, value: bool) void {
    if (url.url_mode_dont_change_url_attr)
        return;

    const grid = term.url.grid_snapshot orelse unreachable;

    const start = &url.range.start;
    const end = &url.range.end;

    const end_r: usize = @intCast(end.row & (grid.num_rows - 1));

    var r: usize = @intCast(start.row & (grid.num_rows - 1));
    var c: usize = @intCast(start.col);

    var row = grid.rows.?[r] orelse return;
    row.dirty = true;

    while (true) {
        const cell = &row.cells.?[c];
        cell.attrs.url = value;
        cell.attrs.clean = false;

        if (r == end_r and c == @as(usize, @intCast(end.col)))
            break;

        c += 1;
        if (c >= @as(usize, @intCast(term.cols))) {
            c = 0;
            r = (r + 1) & @as(usize, @intCast(grid.num_rows - 1));

            const next = grid.rows.?[r] orelse {
                // Un-allocated scrollback. This most likely means a runaway
                // OSC-8 URL.
                break;
            };
            row = next;
            row.dirty = true;
        }
    }
}

export fn urls_render(
    term: ?*Terminal,
    launch: ?*const types.ConfigSpawnTemplate,
) callconv(.c) void {
    const t = term orelse return;

    const win = t.window orelse return;
    const win_term: *Terminal = @ptrCast(@alignCast(win.term.?));

    if (urlList(win_term).len() == 0)
        return;

    // Disable IME while in URL-mode
    if (term_ime_is_enabled(t)) {
        t.url.ime_reenable_after_url_mode = true;
        term_ime_disable(t);
    }

    // Dirty the last cursor, to ensure it is erased
    {
        if (t.render.last_cursor.row) |cursor_row| {
            const cell = &cursor_row.cells.?[@intCast(t.render.last_cursor.col)];
            cell.attrs.clean = false;
            cursor_row.dirty = true;
        }
    }
    t.render.last_cursor.row = null;

    // Clear scroll damage, to ensure we don't apply it twice (once on the
    // snapshot:ed grid, and then later again on the real grid)
    const scroll_damage: *tll.Tll(?*anyopaque) = @ptrCast(&t.grid.?.scroll_damage);
    scroll_damage.freeList();

    // Damage the entire view, to ensure a full screen redraw, both now, when
    // entering URL mode, and later, when exiting it.
    term_damage_view(t);

    // Snapshot the current grid
    t.url.grid_snapshot = grid_snapshot(t.grid.?);

    // Remember which launcher to use
    t.url.launch = @ptrCast(launch);

    const win_urls: *tll.Tll(types.WlUrl) = @ptrCast(&win.urls);
    std.debug.assert(win_urls.len() == 0);

    var it = urlList(win_term).foreach();
    while (it.next()) |node| {
        var url: types.WlUrl = .{ .url = &node.item, .surf = undefined };
        _ = wayl_win_subsurface_new(win, &url.surf, false);

        win_urls.pushBack(url);
        tagCellsForUrl(t, &node.item, true);
    }

    render_refresh_urls(t);
    render_refresh(t);
}

fn urlDestroy(url: *Url) void {
    free(url.url);
    free(url.key);
}

export fn urls_reset(term: ?*Terminal) callconv(.c) void {
    const t = term orelse return;

    const urls = urlList(t);
    if (urls.len() == 0) {
        std.debug.assert(t.url.grid_snapshot == null);
        return;
    }

    grid_free(t.url.grid_snapshot);
    free(t.url.grid_snapshot);
    t.url.grid_snapshot = null;

    // Make sure "last cursor" doesn't point to a row in the just free:d
    // snapshot grid. Note that it will still be erased properly (if hasn't
    // already), since we marked the cell as dirty *before* taking the grid
    // snapshot.
    t.render.last_cursor.row = null;

    if (t.window) |win| {
        const win_urls: *tll.Tll(types.WlUrl) = @ptrCast(&win.urls);
        var it = win_urls.foreach();
        while (it.next()) |node| {
            wayl_win_subsurface_destroy(&node.item.surf);
            win_urls.removeNode(node);
        }
    }

    var it = urls.foreach();
    while (it.next()) |node| {
        urlDestroy(&node.item);
        urls.removeNode(node);
    }

    t.url.show_uri_on_jump_label = false;
    @memset(&t.url.keys, 0);

    // Re-enable IME, if it was enabled before we entered URL-mode
    if (t.url.ime_reenable_after_url_mode) {
        t.url.ime_reenable_after_url_mode = false;
        term_ime_enable(t);
    }

    render_refresh(t);
}
