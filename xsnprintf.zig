const std = @import("std");

extern fn vsnprintf(str: [*c]u8, size: usize, format: [*c]const u8, ap: *anyopaque) callconv(.c) c_int;

fn fatalError(msg: []const u8) noreturn {
    std.debug.print("xsnprintf fatal error: {s}\n", .{msg});
    std.process.abort();
}

export fn xvsnprintf(buf: [*c]u8, n: usize, format: [*c]const u8, ap: *std.builtin.VaList) callconv(.c) usize {
    const len = vsnprintf(buf, n, format, ap);
    if (len < 0) {
        fatalError("vsnprintf failed");
    }

    const ulen: usize = @intCast(len);
    if (ulen >= n) {
        fatalError("buffer too small (ENOBUFS)");
    }

    return ulen;
}
