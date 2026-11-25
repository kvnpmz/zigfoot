const std = @import("std");

const FILE = opaque {};
extern "c" var stderr: *FILE;
extern "c" fn fprintf(stream: *FILE, format: [*:0]const u8, ...) c_int;
extern "c" fn exit(status: c_int) noreturn;
extern "c" fn malloc(size: usize) ?*anyopaque;
extern "c" fn calloc(nmemb: usize, size: usize) ?*anyopaque;
extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn strdup(s: [*:0]const u8) ?[*:0]u8;
extern "c" fn strndup(s: [*:0]const u8, n: usize) ?[*:0]u8;
extern "c" fn vasprintf(strp: *?[*:0]u8, fmt: [*:0]const u8, ap: [*c]const u8) c_int;

// xmalloc.c's contract, restored (audit PL-06): a zero size is normalized so
// the result is always a unique, non-NULL pointer; xcalloc()/xrealloc()
// require a non-zero size; xreallocarray() rejects a zero factor (EINVAL) and
// an overflowing product (EOVERFLOW) *before* it touches the pointer, so a
// rejected call cannot free the caller's allocation.

fn checkAlloc(alloc: ?*anyopaque) ?*anyopaque {
    if (alloc == null) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return alloc;
}

fn fatalErrorOn(cond: bool, comptime msg: []const u8) void {
    if (cond) {
        _ = fprintf(stderr, "xmalloc: " ++ msg ++ "\n");
        exit(1);
    }
}

export fn xmalloc(size: usize) ?*anyopaque {
    return checkAlloc(malloc(if (size == 0) 1 else size));
}

export fn xcalloc(nmemb: usize, size: usize) ?*anyopaque {
    std.debug.assert(size != 0);
    return checkAlloc(calloc(if (nmemb == 0) 1 else nmemb, size));
}

export fn xrealloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    std.debug.assert(size != 0);
    return checkAlloc(realloc(ptr, size));
}

export fn xreallocarray(ptr: ?*anyopaque, nmemb: usize, size: usize) ?*anyopaque {
    fatalErrorOn(nmemb == 0 or size == 0, "xreallocarray: Invalid argument");
    fatalErrorOn(nmemb > std.math.maxInt(usize) / size, "xreallocarray: Numerical result out of range");
    return xrealloc(ptr, nmemb * size);
}

export fn xstrdup(str: [*:0]const u8) ?[*:0]u8 {
    const p = strdup(str);
    if (p == null) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return p;
}

export fn xstrndup(str: [*:0]const u8, n: usize) ?[*:0]u8 {
    const p = strndup(str, n);
    if (p == null) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return p;
}

export fn xc32dup(str: ?[*:0]const u32) ?[*:0]u32 {
    const s = str orelse return null;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const dup = xmalloc((len + 1) * @sizeOf(u32)) orelse return null;
    const dest: [*:0]u32 = @ptrCast(@alignCast(dup));
    @memcpy(dest[0 .. len + 1], s[0 .. len + 1]);
    return dest;
}

export fn xvasprintf(format: [*:0]const u8, ap: ?*anyopaque) ?[*:0]u8 {
    var ret: ?[*:0]u8 = null;
    const res = vasprintf(&ret, format, @ptrCast(ap));
    if (res < 0) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return ret;
}
