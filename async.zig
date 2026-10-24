const std = @import("std");

extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
extern fn __errno_location() callconv(.c) *c_int;

const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;

const AsyncWriteStatus = enum(c_int) {
    done = 0,
    remain = 1,
    err = 2,
};

export fn async_write(
    fd: c_int,
    data: ?*const anyopaque,
    len: usize,
    idx: *usize,
) callconv(.c) AsyncWriteStatus {
    const bytes: [*]const u8 = @ptrCast(data.?);
    var left = len - idx.*;

    while (left > 0) {
        const ret = write(fd, bytes + idx.*, left);

        if (ret < 0) {
            if (__errno_location().* == EAGAIN or __errno_location().* == EWOULDBLOCK)
                return .remain;

            return .err;
        }

        idx.* += @intCast(ret);
        left -= @intCast(ret);
    }

    return .done;
}
