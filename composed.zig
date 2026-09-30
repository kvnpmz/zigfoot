const std = @import("std");

extern fn free(ptr: ?*anyopaque) void;

pub const CELL_COMB_CHARS_LO: u32 = 0x0020_0000;
pub const CELL_COMB_CHARS_HI: u32 = CELL_COMB_CHARS_LO + 0x3fff_ffff;

pub const Composed = extern struct {
    chars: [*c]u32,
    left: ?*Composed,
    right: ?*Composed,
    key: u32,
    count: u8,
    width: u8,
    forced_width: u8,
};

export fn composed_key_from_key(prev_key: u32, next_char: u32) callconv(.c) u32 {
    const range = CELL_COMB_CHARS_HI - CELL_COMB_CHARS_LO;
    const bits: u5 = @truncate(32 - @clz(range));

    const shift_amt: u5 = bits - 8;
    var new_key: u32 = (prev_key << 8) | (prev_key >> shift_amt);

    new_key ^= next_char;
    new_key = new_key *% 2654435761;
    new_key &= range;

    return new_key;
}

export fn composed_key_from_chars(chars: [*c]const u32, count: usize) callconv(.c) u32 {
    if (count == 0 or chars == null) return 0;

    var key: u32 = chars[0];
    var i: usize = 1;
    while (i < count) : (i += 1) {
        key = composed_key_from_key(key, chars[i]);
    }

    return key;
}

pub export fn composed_lookup(root: ?*Composed, key: u32) callconv(.c) ?*Composed {
    var node = root;
    while (node) |n| {
        if (key == n.key) {
            return n;
        }
        node = if (key < n.key) n.left else n.right;
    }
    return null;
}

export fn composed_lookup_without_collision(
    root: ?*Composed,
    key: *u32,
    prefix_text: [*c]const u32,
    prefix_len: usize,
    wc: u32,
    forced_width: c_int,
) callconv(.c) ?*Composed {
    const range = CELL_COMB_CHARS_HI - CELL_COMB_CHARS_LO;

    while (true) {
        const cc = composed_lookup(root, key.*) orelse return null;

        var match: bool = (cc.count == prefix_len + 1) and
            (cc.forced_width == forced_width) and
            (cc.chars[prefix_len] == wc);

        if (match) {
            var i: usize = 0;
            while (i < prefix_len) : (i += 1) {
                if (cc.chars[i] != prefix_text[i]) {
                    match = false;
                    break;
                }
            }
        }

        if (match) return cc;

        key.* = (key.* +% 1) & range;
    }
}

export fn composed_insert(root: *?*Composed, node: ?*Composed) callconv(.c) void {
    const n_node = node orelse return;
    n_node.left = null;
    n_node.right = null;

    if (root.* == null) {
        root.* = n_node;
        return;
    }

    const key = n_node.key;
    var prev: ?*Composed = null;
    var current = root.*;

    while (current) |curr| {
        prev = curr;
        current = if (key < curr.key) curr.left else curr.right;
    }

    if (prev) |p| {
        if (key < p.key) {
            p.left = n_node;
        } else {
            p.right = n_node;
        }
    }
}

export fn composed_free(root: ?*Composed) callconv(.c) void {
    const n = root orelse return;

    composed_free(n.left);
    composed_free(n.right);

    free(n.chars);
    free(n);
}
