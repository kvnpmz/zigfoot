const std = @import("std");
const build_options = @import("build_options");

extern fn xmalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn xrealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn strlen(s: [*c]const u8) callconv(.c) usize;
extern fn wcslen(s: [*c]const u32) callconv(.c) usize;

const MbState = opaque {};

extern fn mbrtoc32(pwc: ?*u32, s: [*c]const u8, n: usize, ps: *MbState) callconv(.c) usize;
extern fn c32rtomb(s: [*c]u8, c32: u32, ps: *MbState) callconv(.c) usize;

export fn mbsntoc32(
    dst: ?[*]u32,
    src: [*c]const u8,
    nms: usize,
    len: usize,
) callconv(.c) usize {
    var ps_buf: [128]u8 align(@alignOf(usize)) = std.mem.zeroes([128]u8);
    const ps: *MbState = @ptrCast(&ps_buf);

    const out_ptr = dst;
    var in_ptr = src;

    var consumed: usize = 0;
    var chars: usize = 0;

    while ((out_ptr == null or chars < len) and consumed < nms) {
        const remaining = nms - consumed;
        if (remaining == 0) break;

        const current_dst: ?*u32 = if (out_ptr) |p| &p[chars] else null;
        const rc = mbrtoc32(current_dst, in_ptr, remaining, ps);

        if (rc == 0) break;

        const invalid: usize = ~@as(usize, 0);
        if (rc == invalid or rc == invalid - 1 or rc == invalid - 2) {
            return invalid;
        }

        in_ptr += rc;
        consumed += rc;
        chars += 1;
    }

    return chars;
}

export fn ambstoc32(src: [*c]const u8) callconv(.c) ?[*]u32 {
    if (src == null) return null;

    const src_len = strlen(src);

    const ret_raw = xmalloc((src_len + 1) * @sizeOf(u32)) orelse return null;
    const ret: [*]u32 = @ptrCast(@alignCast(ret_raw));

    var ps_buf: [128]u8 align(@alignOf(usize)) = std.mem.zeroes([128]u8);
    const ps: *MbState = @ptrCast(&ps_buf);

    var in_ptr = src;
    const end_ptr = src + src_len + 1;

    var chars: usize = 0;

    while (true) {
        const remaining = @intFromPtr(end_ptr) - @intFromPtr(in_ptr);
        const rc = mbrtoc32(&ret[chars], in_ptr, remaining, ps);

        if (rc == 0) break;

        const invalid: usize = ~@as(usize, 0);
        if (rc == invalid or rc == invalid - 1 or rc == invalid - 2) {
            free(ret_raw);
            return null;
        }

        in_ptr += rc;
        chars += 1;
    }

    ret[chars] = 0;

    if (xrealloc(ret_raw, (chars + 1) * @sizeOf(u32))) |resized| {
        return @ptrCast(@alignCast(resized));
    }

    return ret;
}

export fn ac32tombs(src: [*c]const u32) callconv(.c) ?[*]u8 {
    if (src == null) return null;

    const src_len = wcslen(src);

    var allocated: usize = src_len + 1;
    var ret_raw = xmalloc(allocated) orelse return null;
    var ret: [*]u8 = @ptrCast(ret_raw);

    var ps_buf: [128]u8 align(@alignOf(usize)) = std.mem.zeroes([128]u8);
    const ps: *MbState = @ptrCast(&ps_buf);

    var bytes: usize = 0;
    var mb: [16]u8 = undefined;

    var i: usize = 0;
    while (i <= src_len) : (i += 1) {
        const c32 = src[i];
        const rc = c32rtomb(&mb, c32, ps);

        const invalid: usize = ~@as(usize, 0);
        if (rc == invalid) {
            free(ret_raw);
            return null;
        }

        if (bytes + rc > allocated) {
            allocated *= 2;
            if (xrealloc(ret_raw, allocated)) |resized| {
                ret_raw = resized;
                ret = @ptrCast(ret_raw);
            } else {
                free(ret_raw);
                return null;
            }
        }

        for (mb[0..rc]) |b| {
            ret[bytes] = b;
            bytes += 1;
        }
    }

    if (xrealloc(ret_raw, bytes)) |resized| {
        return @ptrCast(resized);
    }

    return ret;
}

extern fn utf8proc_charwidth(c: i32) callconv(.c) c_int;
extern fn wcwidth(wc: i32) callconv(.c) c_int;

export fn c32width(c: u32) callconv(.c) c_int {
    // Mirrors char32.h: utf8proc when grapheme clustering is enabled,
    // plain wcwidth() otherwise. The condition is comptime so the unused
    // branch (and its extern reference) is dropped from the object.
    if (comptime build_options.grapheme_clustering)
        return utf8proc_charwidth(@bitCast(c));

    return wcwidth(@bitCast(c));
}

export fn c32swidth(s: [*]const u32, n: usize) callconv(.c) c_int {
    var width: c_int = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const w = c32width(s[i]);
        if (w < 0) return -1;
        width += w;
    }
    return width;
}

// ─────────────────────────────────────────────────────────────────────────
// Wide-string helpers (char32.h's wcs* wrappers), needed by the search box
// ─────────────────────────────────────────────────────────────────────────

/// `wcsncpy()`: copy at most `n` characters, zero-padding the remainder.
export fn c32ncpy(dst: [*]u32, src: [*]const u32, n: usize) callconv(.c) [*]u32 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1)
        dst[i] = src[i];
    while (i < n) : (i += 1)
        dst[i] = 0;
    return dst;
}

/// `wcsncat()`: append at most `n` characters, then NUL-terminate.
export fn c32ncat(dst: [*]u32, src: [*]const u32, n: usize) callconv(.c) [*]u32 {
    var d: usize = 0;
    while (dst[d] != 0) : (d += 1) {}

    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1)
        dst[d + i] = src[i];
    dst[d + i] = 0;
    return dst;
}

/// `wcscat()`.
export fn c32cat(dst: [*]u32, src: [*]const u32) callconv(.c) [*]u32 {
    return c32ncat(dst, src, std.math.maxInt(usize));
}

