const std = @import("std");

extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xstrndup(src: [*c]const u8, n: usize) callconv(.c) [*c]u8;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn strcmp(s1: [*c]const u8, s2: [*c]const u8) callconv(.c) c_int;
extern fn gethostname(name: [*c]u8, len: usize) callconv(.c) c_int;

fn hex2nibble(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0xFF,
    };
}

fn streq(s1: [*c]const u8, s2: [*c]const u8) bool {
    if (s1 == null or s2 == null) return false;
    return strcmp(s1, s2) == 0;
}

fn freeIfNotNull(ptr_loc: ?*[*c]u8) void {
    if (ptr_loc) |loc| {
        if (loc.* != null) {
            free(@ptrCast(loc.*));
            loc.* = null;
        }
    }
}

fn cleanup(
    scheme: ?*[*c]u8,
    user: ?*[*c]u8,
    password: ?*[*c]u8,
    host: ?*[*c]u8,
    path: ?*[*c]u8,
    query: ?*[*c]u8,
    fragment: ?*[*c]u8,
) bool {
    freeIfNotNull(scheme);
    freeIfNotNull(user);
    freeIfNotNull(password);
    freeIfNotNull(host);
    freeIfNotNull(path);
    freeIfNotNull(query);
    freeIfNotNull(fragment);
    return false;
}

export fn uri_parse(
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
) callconv(.c) bool {
    if (scheme) |s| s.* = null;
    if (user) |u| u.* = null;
    if (password) |pw| pw.* = null;
    if (host) |h| h.* = null;
    if (port) |pt| pt.* = 0;
    if (path) |p| p.* = null;
    if (query) |q| q.* = null;
    if (fragment) |f| f.* = null;

    if (uri == null or len == 0) return false;

    const slice = uri[0..len];

    // Buscar ':'
    const col_idx = std.mem.indexOfScalar(u8, slice, ':') orelse return false;
    if (col_idx == 0) return false;

    if (scheme) |s| {
        s.* = xstrndup(slice[0..col_idx].ptr, col_idx);
    }

    var start: usize = col_idx + 1;

    // Authinfo
    if (len - start >= 2 and slice[start] == '/' and slice[start + 1] == '/') {
        start += 2;

        const path_seg_rel = std.mem.indexOfScalar(u8, slice[start..], '/') orelse return cleanup(scheme, user, password, host, path, query, fragment);
        const path_segment = start + path_seg_rel;
        var auth_left = path_segment - start;

        if (std.mem.indexOfScalar(u8, slice[start .. start + auth_left], '@')) |at_rel| {
            const user_pw_len = at_rel;
            const user_pw_start = start;

            if (std.mem.indexOfScalar(u8, slice[user_pw_start .. user_pw_start + user_pw_len], ':')) |colon_rel| {
                const user_len = colon_rel;
                if (user_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);

                if (user) |u| u.* = xstrndup(slice[user_pw_start..].ptr, user_len);

                const pw_start = user_pw_start + user_len + 1;
                const pw_len = user_pw_len - (user_len + 1);
                if (pw_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);

                if (password) |pw| pw.* = xstrndup(slice[pw_start..].ptr, pw_len);
            } else {
                if (user_pw_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);
                if (user) |u| u.* = xstrndup(slice[user_pw_start..].ptr, user_pw_len);
            }

            start = user_pw_start + user_pw_len + 1;
            auth_left = path_segment - start;
        }

        if (std.mem.indexOfScalar(u8, slice[start .. start + auth_left], ':')) |colon_rel| {
            const host_len = colon_rel;
            if (host) |h| h.* = xstrndup(slice[start..].ptr, host_len);

            const port_str_start = start + host_len + 1;
            const port_len = path_segment - port_str_start;
            if (port_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);

            // C accumulates in a uint16_t, i.e. it wraps. Keep the wrap
            // (`*%`/`+%`) instead of trapping in ReleaseSafe.
            var parsed_port: u16 = 0;
            for (slice[port_str_start..path_segment]) |ch| {
                if (ch < '0' or ch > '9') return cleanup(scheme, user, password, host, path, query, fragment);
                parsed_port = parsed_port *% 10 +% (ch - '0');
            }

            if (port) |pt| pt.* = parsed_port;
        } else {
            const host_len = path_segment - start;
            if (host) |h| h.* = xstrndup(slice[start..].ptr, host_len);
        }

        start = path_segment;
    }

    var query_idx: ?usize = if (std.mem.indexOfScalar(u8, slice[start..], '?')) |rel| start + rel else null;
    var fragment_idx: ?usize = if (std.mem.indexOfScalar(u8, slice[start..], '#')) |rel| start + rel else null;

    if (scheme) |s| {
        if (s.* != null and streq(s.*, "file")) {
            query_idx = null;
            fragment_idx = null;
        }
    }

    if (query_idx != null and fragment_idx != null and fragment_idx.? < query_idx.?) {
        query_idx = null;
        fragment_idx = null;
    }

    const path_end = query_idx orelse (fragment_idx orelse len);
    const path_len = path_end - start;
    if (path_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);

    if (path) |p| {
        const decoded_ptr: [*c]u8 = @ptrCast(xmalloc(path_len + 1) orelse return cleanup(scheme, user, password, host, path, query, fragment));

        var enc_i: usize = start;
        var dec_i: usize = 0;

        while (enc_i < path_end) {
            if (slice[enc_i] == '%') {
                if (enc_i + 2 < path_end) {
                    const n1 = hex2nibble(slice[enc_i + 1]);
                    const n2 = hex2nibble(slice[enc_i + 2]);
                    if (n1 <= 15 and n2 <= 15) {
                        decoded_ptr[dec_i] = (n1 << 4) | n2;
                        dec_i += 1;
                        enc_i += 3;
                        continue;
                    }
                }
                decoded_ptr[dec_i] = slice[enc_i];
                dec_i += 1;
                enc_i += 1;
            } else {
                decoded_ptr[dec_i] = slice[enc_i];
                dec_i += 1;
                enc_i += 1;
            }
        }

        decoded_ptr[dec_i] = 0;
        p.* = decoded_ptr;
    }

    start = if (query_idx) |q_i| q_i + 1 else if (fragment_idx) |f_i| f_i + 1 else len;

    if (query_idx != null) {
        const q_end = fragment_idx orelse len;
        const query_len = q_end - start;
        if (query_len == 0) return cleanup(scheme, user, password, host, path, query, fragment);

        if (query) |q| q.* = xstrndup(slice[start..].ptr, query_len);

        start = if (fragment_idx) |f_i| f_i + 1 else len;
    }

    if (fragment_idx != null) {
        const frag_left = len - start;
        if (frag_left == 0) return cleanup(scheme, user, password, host, path, query, fragment);

        if (fragment) |f| f.* = xstrndup(slice[start..].ptr, frag_left);
    }

    return true;
}

export fn hostname_is_localhost(hostname: [*c]const u8) callconv(.c) bool {
    if (hostname == null) return false;

    var this_host: [256]u8 = undefined;
    if (gethostname(&this_host, this_host.len) < 0) {
        this_host[0] = 0;
    } else {
        this_host[this_host.len - 1] = 0;
    }

    const host_str = std.mem.span(hostname);
    if (std.mem.eql(u8, host_str, "") or std.mem.eql(u8, host_str, "localhost")) {
        return true;
    }

    const local_str = std.mem.span(@as([*c]const u8, @ptrCast(&this_host)));
    return std.mem.eql(u8, host_str, local_str);
}
