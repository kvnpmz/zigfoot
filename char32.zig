const std = @import("std");

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
