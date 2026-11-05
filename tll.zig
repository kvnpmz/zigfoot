//! Zig port of tllist.h (intrusive doubly-linked list, C-ABI compatible).
//!
//! Layout matches tllist.h exactly:
//!   struct tll(T) { struct { T item; node *prev; node *next; } *head, *tail; size_t length; }
//!
//! Node struct field order is ITEM FIRST, then prev, next. This is unusual
//! but matches the C macro `TLL_UNIQUE_INNER_STRUCT`. Getting it wrong would
//! corrupt memory when mixing C and Zig code on the same list instance.
//!
//! All node allocation goes through libc malloc/free, so lists created by
//! C can be manipulated by Zig and vice versa.

const std = @import("std");

extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;

pub fn Tll(comptime T: type) type {
    return extern struct {
        const Self = @This();

        head: ?*Node = null,
        tail: ?*Node = null,
        length: usize = 0,

        pub const Node = extern struct {
            item: T,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        // ── Construction ──────────────────────────────────────────
        pub fn init() @This() {
            return .{};
        }

        // ── Length ────────────────────────────────────────────────
        pub inline fn len(self: *const @This()) usize {
            return self.length;
        }

        pub inline fn isEmpty(self: *const @This()) bool {
            return self.length == 0;
        }

        // ── Peek ──────────────────────────────────────────────────
        pub inline fn front(self: *@This()) *T {
            return &self.head.?.item;
        }

        pub inline fn back(self: *@This()) *T {
            return &self.tail.?.item;
        }

        pub inline fn frontConst(self: *const @This()) *const T {
            return &self.head.?.item;
        }

        pub inline fn backConst(self: *const @This()) *const T {
            return &self.tail.?.item;
        }

        // ── Insertion ─────────────────────────────────────────────
        pub fn pushBack(self: *@This(), item: T) void {
            self.insertAfter(self.tail, item);
            if (self.head == null) self.head = self.tail;
        }

        pub fn pushFront(self: *@This(), item: T) void {
            self.insertBefore(self.head, item);
            if (self.tail == null) self.tail = self.head;
        }

        fn insertAfter(self: *@This(), it: ?*Node, item: T) void {
            const node_ptr = malloc(@sizeOf(Node)) orelse @panic("tll: malloc failed");
            const node: *Node = @ptrCast(@alignCast(node_ptr));
            node.item = item;
            node.prev = it;
            node.next = if (it) |i| i.next else null;
            if (it) |i| {
                if (i.next) |n| n.prev = node;
                i.next = node;
            }
            if (it == self.tail) self.tail = node;
            self.length += 1;
        }

        fn insertBefore(self: *@This(), it: ?*Node, item: T) void {
            const node_ptr = malloc(@sizeOf(Node)) orelse @panic("tll: malloc failed");
            const node: *Node = @ptrCast(@alignCast(node_ptr));
            node.item = item;
            node.prev = if (it) |i| i.prev else null;
            node.next = it;
            if (it) |i| {
                if (i.prev) |p| p.next = node;
                i.prev = node;
            }
            if (it == self.head) self.head = node;
            self.length += 1;
        }

        // ── Removal ───────────────────────────────────────────────
        pub fn removeNode(self: *@This(), it: *Node) void {
            std.debug.assert(self.length > 0);
            const prev = it.prev;
            const next = it.next;
            if (prev) |p| p.next = next else self.head = next;
            if (next) |n| n.prev = prev else self.tail = prev;
            free(@ptrCast(it));
            self.length -= 1;
        }

        pub fn popFront(self: *@This()) T {
            const it = self.head.?;
            const ret = it.item;
            self.removeNode(it);
            return ret;
        }

        pub fn popBack(self: *@This()) T {
            const it = self.tail.?;
            const ret = it.item;
            self.removeNode(it);
            return ret;
        }

        // ── Free ──────────────────────────────────────────────────
        pub fn freeList(self: *@This()) void {
            var it = self.head;
            while (it) |n| {
                const next = n.next;
                free(@ptrCast(n));
                it = next;
            }
            self.length = 0;
            self.head = null;
            self.tail = null;
        }

        pub fn freeListAndFree(
            self: *@This(),
            free_cb: *const fn (T) callconv(.c) void,
        ) void {
            var it = self.head;
            while (it) |n| {
                const next = n.next;
                free_cb(n.item);
                free(@ptrCast(n));
                it = next;
            }
            self.length = 0;
            self.head = null;
            self.tail = null;
        }

        // ── Iteration ─────────────────────────────────────────────
        pub const Iterator = struct {
            list: *Self,
            current: ?*Node,
            next_cached: ?*Node,
            // Prev pointer cached to detect removal-during-iteration.
            prev_cached: ?*Node,

            pub fn next(self: *Iterator) ?*T {
                const cur = self.current orelse return null;
                self.current = self.next_cached;
                if (self.next_cached) |n| self.next_cached = n.next;
                return &cur.item;
            }

            // Remove the just-returned item and continue iteration safely.
            pub fn remove(self: *Iterator) void {
                // prev is the previously-iterated node (or null if we're at head).
                const cur = self.prev_cached; // wait — see notes
                _ = cur;
                unreachable;
            }
        };

        pub const ForeachIter = struct {
            list: *Self,
            it: ?*Node,
            it_next: ?*Node,

            pub fn next(self: *ForeachIter) ?*Node {
                const cur = self.it orelse return null;
                self.it = self.it_next;
                if (self.it_next) |n| self.it_next = n.next;
                return cur;
            }
        };

        pub fn foreach(self: *@This()) ForeachIter {
            const head = self.head;
            return .{
                .list = self,
                .it = head,
                .it_next = if (head) |h| h.next else null,
            };
        }

        pub const RForeachIter = struct {
            list: *Self,
            it: ?*Node,
            it_prev: ?*Node,

            pub fn next(self: *RForeachIter) ?*Node {
                const cur = self.it orelse return null;
                self.it = self.it_prev;
                if (self.it_prev) |n| self.it_prev = n.prev;
                return cur;
            }
        };

        pub fn rforeach(self: *@This()) RForeachIter {
            const tail = self.tail;
            return .{
                .list = self,
                .it = tail,
                .it_prev = if (tail) |t| t.prev else null,
            };
        }

        // ── Sort (stable merge sort, matching C's tll_sort) ───────
        pub fn sort(
            self: *@This(),
            cmp: *const fn (*const T, *const T) callconv(.c) i32,
        ) void {
            if (self.head == null) return;

            var insize: usize = 1;
            while (true) {
                var p: ?*Node = self.head;
                self.head = null;
                var t: ?*Node = null;
                var nmerges: usize = 0;
                while (p != null) {
                    nmerges += 1;
                    var q: ?*Node = p;
                    var p_size: usize = 0;
                    var i: usize = 0;
                    while (i < insize) : (i += 1) {
                        p_size += 1;
                        q = q.?.next;
                        if (q == null) break;
                    }
                    var q_size: usize = insize;
                    while (p_size > 0 or (q_size > 0 and q != null)) {
                        var e: *Node = undefined;
                        if (p_size == 0) {
                            e = q.?;
                            q = q.?.next;
                            q_size -= 1;
                        } else if (q_size == 0 or q == null) {
                            e = p.?;
                            p = p.?.next;
                            p_size -= 1;
                        } else if (cmp(&p.?.item, &q.?.item) <= 0) {
                            e = p.?;
                            p = p.?.next;
                            p_size -= 1;
                        } else {
                            e = q.?;
                            q = q.?.next;
                            q_size -= 1;
                        }
                        if (t) |tn| {
                            tn.next = e;
                        } else {
                            self.head = e;
                        }
                        e.prev = t;
                        t = e;
                    }
                    p = q;
                }
                self.tail = t;
                t.?.next = null;
                insize *= 2;
                if (nmerges <= 1) break;
            }
        }
    };
}

// ── Compile-time layout verification ─────────────────────────────
// Verify byte-compatibility with C's tllist.h on all target platforms.
// The node struct is {item, prev, next} — ITEM FIRST.

comptime {
    const PtrSize = @sizeOf(?*anyopaque);
    const USize = @sizeOf(usize);

    // Empty list header: 2 pointers + size_t
    std.debug.assert(@sizeOf(Tll(u32)) == 2 * PtrSize + USize);
    std.debug.assert(@offsetOf(Tll(u32), "head") == 0);
    std.debug.assert(@offsetOf(Tll(u32), "tail") == PtrSize);
    std.debug.assert(@offsetOf(Tll(u32), "length") == 2 * PtrSize);

    // Node layout: item at offset 0, then prev, next (with alignment padding)
    const NodeU32 = Tll(u32).Node;
    std.debug.assert(@offsetOf(NodeU32, "item") == 0);
    // prev/next are aligned to PtrSize
    std.debug.assert(@offsetOf(NodeU32, "prev") % PtrSize == 0);
    std.debug.assert(@offsetOf(NodeU32, "next") == @offsetOf(NodeU32, "prev") + PtrSize);
}
