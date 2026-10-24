const std = @import("std");
const types = @import("terminal_types.zig");

extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: ERROR: " ++ fmt ++ "\n", args);
}
fn logErrno(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: " ++ fmt ++ " (errno)\n", args);
}
fn logDbg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("osc: " ++ fmt ++ "\n", args);
}

export fn osc_ensure_size(term: *types.Terminal, required_size: usize) callconv(.c) bool {
    if (required_size <= term.vt.osc.size)
        return true;

    const pow2_max: usize = ~(@as(usize, std.math.maxInt(usize)) >> 1);
    if (required_size > pow2_max) {
        logErr("required OSC buffer size ({d}) exceeds limit ({d})", .{ required_size, pow2_max });
        return false;
    }

    var new_size: usize = @max(term.vt.osc.size, 4096);
    while (new_size < required_size) {
        new_size <<= 1;
    }

    const new_data: ?[*]u8 = @ptrCast(realloc(
        if (term.vt.osc.data) |d| @ptrCast(d) else null,
        new_size,
    ));
    if (new_data == null) {
        logErrno("failed to increase size of OSC buffer", .{});
        return false;
    }

    logDbg("resized OSC buffer: {d}", .{new_size});
    term.vt.osc.data = new_data;
    term.vt.osc.size = new_size;
    return true;
}
