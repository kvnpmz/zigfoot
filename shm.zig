const std = @import("std");
const types = @import("terminal_types.zig");

//
// Chunk S1 — shm buffer lifetime: destruction, pool refcounting, deferred
// release and chain bookkeeping. Allocation (get_new_buffers), scrolling and
// chain creation remain in shm.c for now.
//
// The private structs live in shm.h so the ABI probe can pin them; this file
// mirrors them in terminal_types.zig and owns the tllist heads it has to
// manipulate after C stops touching them (deferred) or that it shares with C
// (buffer_chain.bufs).
//

const LOG_CLASS_WARNING: c_int = 2;

extern fn log_msg(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;
extern fn pixman_image_unref(image: ?*anyopaque) callconv(.c) void;
extern fn pixman_region32_fini(region: ?*anyopaque) callconv(.c) void;
extern fn shm_shim_wl_buffer_destroy(wl_buffer: ?*anyopaque) callconv(.c) void;
extern fn shm_shim_wl_shm_pool_destroy(pool: ?*anyopaque) callconv(.c) void;
extern fn munmap(addr: ?*anyopaque, length: usize) callconv(.c) c_int;
extern fn close(fd: c_int) callconv(.c) c_int;

const MAP_FAILED: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// tllist node layout is { item, prev, next } -- order matters: buffer_chain.bufs
// is shared with C, so this must match tllist.h exactly.
const BufferNode = extern struct {
    item: *types.ShmBufferPrivate,
    prev: ?*BufferNode,
    next: ?*BufferNode,
};

var deferred: types.TllBufferPrivate = .{ .head = null, .tail = null, .length = 0 };

fn listHead(list: *const types.TllBufferPrivate) ?*BufferNode {
    const head = list.head orelse return null;
    return @ptrCast(@alignCast(head));
}

fn listPushBack(list: *types.TllBufferPrivate, item: *types.ShmBufferPrivate) void {
    const node: *BufferNode = @ptrCast(@alignCast(
        std.c.malloc(@sizeOf(BufferNode)) orelse @panic("out of memory")));
    const tail: ?*BufferNode = if (list.tail) |t| @ptrCast(@alignCast(t)) else null;

    node.* = .{ .prev = tail, .next = null, .item = item };

    if (tail) |t| t.next = node else list.head = node;
    list.tail = node;
    list.length += 1;
}

fn listPushFront(list: *types.TllBufferPrivate, item: *types.ShmBufferPrivate) void {
    const node: *BufferNode = @ptrCast(@alignCast(
        std.c.malloc(@sizeOf(BufferNode)) orelse @panic("out of memory")));
    const head = listHead(list);

    node.* = .{ .prev = null, .next = head, .item = item };

    if (head) |h| h.prev = node else list.tail = node;
    list.head = node;
    list.length += 1;
}

fn listRemove(list: *types.TllBufferPrivate, node: *BufferNode) void {
    if (node.prev) |prev| prev.next = node.next else list.head = node.next;
    if (node.next) |next| next.prev = node.prev else list.tail = node.prev;
    list.length -= 1;
    std.c.free(node);
}

fn bufferDestroyDontClose(buf: *types.Buffer) void {
    if (buf.pix) |pix| {
        var i: usize = 0;
        while (i < buf.pix_instances) : (i += 1) {
            if (pix[i]) |image| pixman_image_unref(image);
        }
    }

    if (buf.wl_buf) |wl_buf| shm_shim_wl_buffer_destroy(wl_buf);

    std.c.free(@ptrCast(buf.pix));
    buf.pix = null;
    buf.wl_buf = null;
    buf.data = null;
}

export fn buffer_destroy_dont_close(buf: *types.Buffer) callconv(.c) void {
    bufferDestroyDontClose(buf);
}

fn poolUnref(pool_ptr: ?*types.ShmBufferPool) void {
    const pool = pool_ptr orelse return;

    std.debug.assert(pool.ref_count > 0);
    pool.ref_count -= 1;

    if (pool.ref_count > 0) return;

    if (pool.real_mmapped != MAP_FAILED)
        _ = munmap(pool.real_mmapped, pool.mmap_size);
    if (pool.wl_pool) |wl_pool| shm_shim_wl_shm_pool_destroy(wl_pool);
    if (pool.fd >= 0) _ = close(pool.fd);

    pool.real_mmapped = MAP_FAILED;
    pool.wl_pool = null;
    pool.fd = -1;
    std.c.free(pool);
}

export fn pool_unref(pool: ?*types.ShmBufferPool) callconv(.c) void {
    poolUnref(pool);
}

fn bufferDestroy(buf: *types.ShmBufferPrivate) void {
    bufferDestroyDontClose(&buf.public);
    poolUnref(buf.pool);
    buf.pool = null;

    if (buf.public.dirty) |dirty| {
        const regions: [*]types.PixmanRegion32 = @ptrCast(@alignCast(dirty));
        var i: usize = 0;
        while (i < buf.public.pix_instances) : (i += 1)
            pixman_region32_fini(&regions[i]);
    }
    std.c.free(@ptrCast(buf.public.dirty));
    std.c.free(buf);
}

export fn buffer_destroy(buf: *types.ShmBufferPrivate) callconv(.c) void {
    bufferDestroy(buf);
}

fn bufferUnrefNoRemoveFromChain(buf: *types.ShmBufferPrivate) bool {
    std.debug.assert(buf.ref_count > 0);
    buf.ref_count -= 1;

    if (buf.ref_count > 0) return false;

    if (buf.busy) listPushBack(&deferred, buf) else bufferDestroy(buf);
    return true;
}

export fn buffer_unref_no_remove_from_chain(
    buf: *types.ShmBufferPrivate,
) callconv(.c) bool {
    return bufferUnrefNoRemoveFromChain(buf);
}

export fn shm_fini() callconv(.c) void {
    var node = listHead(&deferred);
    while (node) |n| {
        const next = n.next;
        bufferDestroy(n.item);
        listRemove(&deferred, n);
        node = next;
    }
}

export fn buffer_release(data: ?*anyopaque, wl_buffer: ?*anyopaque) callconv(.c) void {
    const buf: *types.ShmBufferPrivate = @ptrCast(@alignCast(data.?));

    std.debug.assert(buf.public.wl_buf == wl_buffer);
    std.debug.assert(buf.busy);
    buf.busy = false;

    if (buf.ref_count == 0) {
        var found = false;
        var node = listHead(&deferred);
        while (node) |n| {
            if (n.item == buf) {
                listRemove(&deferred, n);
                found = true;
                break;
            }
            node = n.next;
        }

        bufferDestroy(buf);

        std.debug.assert(found);
        if (!found)
            log_msg(LOG_CLASS_WARNING, "shm", "shm.zig", @intCast(@src().line), "deferred delete: buffer not on the deferred list");
    } else {
        if (buf.release_cb) |cb| {
            const release: *const fn (*types.Buffer, ?*anyopaque) callconv(.c) void =
                @ptrCast(cb);
            release(&buf.public, buf.cb_data);
        }
    }
}

export fn shm_defer_push_front(buf: *types.ShmBufferPrivate) callconv(.c) void {
    listPushFront(&deferred, buf);
}

export fn shm_did_not_use_buf(buf: *types.Buffer) callconv(.c) void {
    const private: *types.ShmBufferPrivate = @ptrCast(@alignCast(buf));
    private.busy = false;
}

export fn shm_purge(chain: *types.ShmBufferChain) callconv(.c) void {
    var node = listHead(&chain.bufs);
    while (node) |n| {
        const next = n.next;
        if (bufferUnrefNoRemoveFromChain(n.item))
            listRemove(&chain.bufs, n);
        node = next;
    }
}

export fn shm_addref(buf: *types.Buffer) callconv(.c) void {
    const private: *types.ShmBufferPrivate = @ptrCast(@alignCast(buf));
    private.ref_count += 1;
}

export fn shm_unref(buf_ptr: ?*types.Buffer) callconv(.c) void {
    const buf = buf_ptr orelse return;
    const private: *types.ShmBufferPrivate = @ptrCast(@alignCast(buf));
    const chain = private.chain.?;

    var node = listHead(&chain.bufs);
    while (node) |n| {
        if (n.item == private) {
            if (bufferUnrefNoRemoveFromChain(private))
                listRemove(&chain.bufs, n);
            break;
        }
        node = n.next;
    }
}
