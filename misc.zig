const std = @import("std");

extern fn iswgraph(wc: u32) c_int;
extern fn wcschr(str: [*c]const u32, wc: u32) [*c]u32;
extern fn ambstoc32(src: [*c]const u8) [*c]u32;
extern fn iswprint(wc: u32) c_int;
extern fn free(ptr: ?*anyopaque) void;

const Timespec = extern struct {
    tv_sec: c_long,
    tv_nsec: c_long,
};

export fn isword(
    wc: u32,
    spaces_only: bool,
    delimiters: [*c]const u32,
) bool {
    if (spaces_only)
        return iswgraph(wc) != 0;

    if (wcschr(delimiters, wc) != null)
        return false;

    return iswgraph(wc) != 0;
}

export fn timespec_add(
    a: *const Timespec,
    b: *const Timespec,
    res: *Timespec,
) void {
    const one_sec_in_ns: c_long = 1_000_000_000;

    res.tv_sec = a.tv_sec + b.tv_sec;
    res.tv_nsec = a.tv_nsec + b.tv_nsec;

    if (res.tv_nsec >= one_sec_in_ns) {
        res.tv_sec += 1;
        res.tv_nsec -= one_sec_in_ns;
    }
}

export fn timespec_sub(
    a: *const Timespec,
    b: *const Timespec,
    res: *Timespec,
) void {
    const one_sec_in_ns: c_long = 1_000_000_000;

    res.tv_sec = a.tv_sec - b.tv_sec;
    res.tv_nsec = a.tv_nsec - b.tv_nsec;

    if (res.tv_nsec < 0) {
        res.tv_sec -= 1;
        res.tv_nsec += one_sec_in_ns;
    }
}

export fn is_valid_utf8_and_printable(value: [*c]const u8) bool {
    const wide = ambstoc32(value);
    if (wide == null)
        return false;
    defer free(wide);

    var c: [*c]const u32 = wide;
    while (c[0] != 0) : (c += 1) {
        if (iswprint(c[0]) == 0)
            return false;
    }

    return true;
}
