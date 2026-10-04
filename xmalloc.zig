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

export fn xmalloc(size: usize) ?*anyopaque {
    const ptr = malloc(size);
    if (ptr == null and size > 0) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return ptr;
}

export fn xcalloc(nmemb: usize, size: usize) ?*anyopaque {
    const ptr = calloc(nmemb, size);
    if (ptr == null and nmemb > 0 and size > 0) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return ptr;
}

export fn xrealloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const new_ptr = realloc(ptr, size);
    if (new_ptr == null and size > 0) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return new_ptr;
}

export fn xreallocarray(ptr: ?*anyopaque, nmemb: usize, size: usize) ?*anyopaque {
    const res = @mulWithOverflow(nmemb, size);
    if (res[1] != 0) {
        _ = fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return xrealloc(ptr, res[0]);
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
