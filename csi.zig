const std = @import("std");
const types = @import("terminal_types.zig");

export fn csi_dispatch(term: *types.Terminal, final: u8) void {
    switch (final) {
        'm' => csi_sgr(term),
        else => {
            // Handle or log unhandled sequences
        },
    }
}

fn sgr_reset(term: *types.Terminal) void {
    term.vt.attrs = std.mem.zeroes(types.Attributes);
    term.vt.underline = std.mem.zeroes(types.UnderlineRangeData);

    term.bits_affecting_ascii_printer._.underline_style = false;
    term.bits_affecting_ascii_printer._.underline_color = false;
}

fn csi_sgr(term: *types.Terminal) void {
    if (term.vt.params.idx == 0) {
        sgr_reset(term);
        return;
    }

    var i: usize = 0;
    while (i < term.vt.params.idx) : (i += 1) {
        const param = term.vt.params.v[i].value;

        switch (param) {
            0 => sgr_reset(term),
            1 => term.vt.attrs.bold = true,
            2 => term.vt.attrs.dim = true,
            3 => term.vt.attrs.italic = true,
            5 => term.vt.attrs.blink = true,
            7 => term.vt.attrs.reverse = true,
            8 => term.vt.attrs.conceal = true,
            9 => term.vt.attrs.strikethrough = true,
            22 => {
                term.vt.attrs.bold = false;
                term.vt.attrs.dim = false;
            },
            23 => term.vt.attrs.italic = false,
            25 => term.vt.attrs.blink = false,
            27 => term.vt.attrs.reverse = false,
            28 => term.vt.attrs.conceal = false,
            else => {
                // Handle extended SGR parameters later
            },
        }
    }
}
