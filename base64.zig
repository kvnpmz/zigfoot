const std = @import("std");

extern fn strlen(s: [*c]const u8) usize;
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn __errno_location() *c_int;

fn setErrno(err: c_int) void {
    __errno_location().* = err;
}

const EINVAL: c_int = 22;

const P: u8 = 1 << 6; // Padding byte (=)
const I: u8 = 1 << 7; // Invalid byte

const reverse_lookup = [256]u8{
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  62, I,  I,  I,  63,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, I,  I,  I,  P,  I,  I,
    I,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, I,  I,  I,  I,  I,
    I,  26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
    I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,  I,
};

const lookup = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export fn base64_decode(s: [*c]const u8, size: ?*usize) callconv(.c) [*c]u8 {
    if (s == null) return null;
    const len = strlen(s);
    if (len % 4 != 0) {
        setErrno(EINVAL);
        return null;
    }

    const alloc_size = (len / 4) * 3 + 1;
    const ret_ptr = malloc(alloc_size) orelse return null;
    const ret: [*]u8 = @ptrCast(ret_ptr);

    if (size) |sz| {
        sz.* = (len / 4) * 3;
    }

    var i: usize = 0;
    var o: usize = 0;
    while (i < len) : ({
        i += 4;
        o += 3;
    }) {
        const a: u32 = reverse_lookup[s[i + 0]];
        const b: u32 = reverse_lookup[s[i + 1]];
        var c_val: u32 = reverse_lookup[s[i + 2]];
        var d: u32 = reverse_lookup[s[i + 3]];

        const u = a | b | c_val | d;
        if ((u & I) != 0) {
            free(ret_ptr);
            setErrno(EINVAL);
            return null;
        }

        if ((u & P) != 0) {
            if (i + 4 != len or ((a | b) & P) != 0 or ((c_val & P) != 0 and (d & P) == 0)) {
                free(ret_ptr);
                setErrno(EINVAL);
                return null;
            }

            if (size) |sz| {
                if ((c_val & P) != 0) {
                    sz.* = (len / 4) * 3 - 2;
                } else {
                    sz.* = (len / 4) * 3 - 1;
                }
            }

            c_val &= 63;
            d &= 63;
        }

        const v = (a << 18) | (b << 12) | (c_val << 6) | d;
        ret[o + 0] = @truncate(v >> 16);
        ret[o + 1] = @truncate(v >> 8);
        ret[o + 2] = @truncate(v);
    }

    ret[(len / 4) * 3] = 0;
    return ret;
}

export fn base64_encode(data: [*c]const u8, size: usize) callconv(.c) [*c]u8 {
    if (size % 3 != 0) return null;

    const alloc_size = (size / 3) * 4 + 1;
    const ret_ptr = malloc(alloc_size) orelse return null;
    const ret: [*]u8 = @ptrCast(ret_ptr);

    var i: usize = 0;
    var o: usize = 0;
    while (i < size) : ({
        i += 3;
        o += 4;
    }) {
        const x: u32 = data[i + 0];
        const y: u32 = data[i + 1];
        const z: u32 = data[i + 2];

        const v = (x << 16) | (y << 8) | z;

        const a = (v >> 18) & 0x3f;
        const b = (v >> 12) & 0x3f;
        const c_idx = (v >> 6) & 0x3f;
        const d = v & 0x3f;

        ret[o + 0] = lookup[a];
        ret[o + 1] = lookup[b];
        ret[o + 2] = lookup[c_idx];
        ret[o + 3] = lookup[d];
    }

    ret[(size / 3) * 4] = 0;
    return ret;
}

export fn base64_encode_final(data: [*c]const u8, size: usize, result: [*c]u8) callconv(.c) void {
    var v: u32 = 0;
    if (size >= 1) v |= @as(u32, data[0]) << 16;
    if (size >= 2) v |= @as(u32, data[1]) << 8;

    const a = (v >> 18) & 0x3f;
    const b = (v >> 12) & 0x3f;
    const c_idx = (v >> 6) & 0x3f;

    const c0 = lookup[a];
    const c1 = lookup[b];
    const c2 = if (size == 2) lookup[c_idx] else '=';
    const c3: u8 = '=';

    result[0] = c0;
    result[1] = c1;
    result[2] = c2;
    result[3] = c3;
}
