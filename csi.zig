const std = @import("std");
const types = @import("terminal_types.zig");

pub export fn csi_dispatch(term: *types.Terminal, final: u8) callconv(.c) void {
    _ = term;
    switch (final) {
        // TODO: transcribe foot csi.c — this is ~2000 lines of finals '@'..'~'
        else => {},
    }
}
