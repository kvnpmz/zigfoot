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

//
// Chunk S2 — allocation: instantiate_offset() and get_new_buffers().
//
// Platform bits that are #ifdef-heavy in C (memfd vs FreeBSD shm_open vs
// mkostemp, fallocate probing, sealing, mmap flags) and the generated Wayland
// inline wrappers stay in shm.c; everything about sizes, offsets and buffer
// ownership is here.
//

const LOG_CLASS_ERROR: c_int = 1;

extern fn log_errno(
    class: c_int,
    module: [*:0]const u8,
    file: [*:0]const u8,
    lineno: c_int,
    fmt: [*:0]const u8,
    ...
) void;

extern fn shm_shim_page_size() callconv(.c) usize;
extern fn shm_shim_max_pool_size() callconv(.c) i64;
extern fn shm_shim_min_stride_alignment() callconv(.c) usize;
extern fn shm_shim_stride_for_format(fmt: c_int, width: c_int) callconv(.c) c_int;
extern fn shm_shim_create_backing_file() callconv(.c) c_int;
extern fn shm_shim_punch_hole_supported(fd: c_int) callconv(.c) bool;
extern fn shm_shim_mmap_pool(fd: c_int, size: usize) callconv(.c) ?*anyopaque;
extern fn shm_shim_seal_pool(fd: c_int) callconv(.c) void;
extern fn shm_shim_wl_shm_create_pool(
    shm: ?*anyopaque,
    fd: c_int,
    size: i32,
) callconv(.c) ?*anyopaque;
extern fn shm_shim_wl_shm_pool_create_buffer(
    pool: ?*anyopaque,
    offset: i32,
    width: c_int,
    height: c_int,
    stride: c_int,
    format: u32,
) callconv(.c) ?*anyopaque;
extern fn shm_shim_wl_buffer_add_listener(buffer: ?*anyopaque, data: ?*anyopaque) callconv(.c) void;

extern fn ftruncate(fd: c_int, length: i64) callconv(.c) c_int;
extern fn pixman_image_create_bits_no_clear(
    format: c_int,
    width: c_int,
    height: c_int,
    bits: ?[*]u32,
    rowstride: c_int,
) callconv(.c) ?*anyopaque;
extern fn pixman_region32_init(region: ?*anyopaque) callconv(.c) void;
extern fn shm_can_scroll(buf: ?*types.Buffer) callconv(.c) bool;

fn logErr(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_ERROR, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

fn logErrno(msg: [*:0]const u8) void {
    log_errno(LOG_CLASS_ERROR, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

fn mallocOrAbort(size: usize) *anyopaque {
    return std.c.malloc(size) orelse @panic("out of memory");
}

fn callocOrAbort(count: usize, size: usize) *anyopaque {
    return std.c.calloc(count, size) orelse @panic("out of memory");
}

fn freePixImages(pix: [*]?*anyopaque, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pix[i]) |image| pixman_image_unref(image);
    }
    std.c.free(@ptrCast(pix));
}

export fn instantiate_offset(
    buf: *types.ShmBufferPrivate,
    new_offset: i64,
) callconv(.c) bool {
    std.debug.assert(buf.public.data == null);
    std.debug.assert(buf.public.pix == null);
    std.debug.assert(buf.public.wl_buf == null);
    std.debug.assert(buf.pool != null);

    const pool = buf.pool.?;
    const chain = buf.chain.?;

    const pix: [*]?*anyopaque = @ptrCast(@alignCast(
        callocOrAbort(buf.public.pix_instances, @sizeOf(?*anyopaque))));

    const base: [*]u8 = @ptrCast(pool.real_mmapped.?);
    const mmapped: *anyopaque = @ptrCast(base + @as(usize, @intCast(new_offset)));

    const wl_buf = shm_shim_wl_shm_pool_create_buffer(
        pool.wl_pool.?,
        @intCast(new_offset),
        buf.public.width,
        buf.public.height,
        buf.public.stride,
        chain.shm_format,
    );

    if (wl_buf == null) {
        logErr("failed to create SHM buffer");
        freePixImages(pix, buf.public.pix_instances);
        std.c.abort();
    }

    var i: usize = 0;
    while (i < buf.public.pix_instances) : (i += 1) {
        pix[i] = pixman_image_create_bits_no_clear(
            @intCast(chain.pixman_fmt),
            buf.public.width,
            buf.public.height,
            @ptrCast(@alignCast(mmapped)),
            buf.public.stride,
        );

        if (pix[i] == null) {
            logErr("failed to create pixman image");
            freePixImages(pix, buf.public.pix_instances);
            shm_shim_wl_buffer_destroy(wl_buf);
            std.c.abort();
        }
    }

    buf.public.data = mmapped;
    buf.public.wl_buf = wl_buf;
    buf.public.pix = pix;
    buf.offset = new_offset;

    shm_shim_wl_buffer_add_listener(wl_buf, buf);
    return true;
}

fn abortAllocation(
    pool_fd: c_int,
    wl_pool: ?*anyopaque,
    real_mmapped: ?*anyopaque,
    mmap_size: i64,
) noreturn {
    if (wl_pool) |p| shm_shim_wl_shm_pool_destroy(p);
    if (real_mmapped != null and real_mmapped != MAP_FAILED)
        _ = munmap(real_mmapped, @intCast(mmap_size));
    if (pool_fd != -1) _ = close(pool_fd);
    std.c.abort();
}

fn getNewBuffers(
    chain: *types.ShmBufferChain,
    count: usize,
    widths: [*]c_int,
    heights: [*]c_int,
    bufs: [*]?*types.Buffer,
    immediate_purge: bool,
) void {
    std.debug.assert(count == 1 or !chain.scrollable);

    const alloc = std.heap.c_allocator;
    const strides = alloc.alloc(c_int, count) catch @panic("out of memory");
    defer alloc.free(strides);
    const sizes = alloc.alloc(c_int, count) catch @panic("out of memory");
    defer alloc.free(sizes);

    const alignment = shm_shim_min_stride_alignment();
    var total_size: usize = 0;

    for (0..count) |i| {
        var stride: c_int = shm_shim_stride_for_format(
            @intCast(chain.pixman_fmt), widths[i]);

        if (alignment > 0) {
            const m: c_int = @intCast(alignment);
            stride = @divTrunc(stride + m - 1, m) * m;
        }

        std.debug.assert(alignment == 0 or
            @rem(stride, @as(c_int, @intCast(alignment))) == 0);

        strides[i] = stride;
        sizes[i] = stride * heights[i];
        total_size += @intCast(sizes[i]);
    }

    if (total_size == 0) return;

    const page_sz = shm_shim_page_size();
    const page: i64 = @intCast(page_sz);
    const max_pool = shm_shim_max_pool_size();

    const pool_fd = shm_shim_create_backing_file();
    if (pool_fd == -1) {
        logErrno("failed to create SHM backing memory file");
        std.c.abort();
    }

    var offset: i64 = 0;
    var memfd_size: i64 = @intCast(total_size);

    if (comptime @sizeOf(usize) == 8) {
        if (chain.scrollable and max_pool > 0) {
            offset = @divTrunc(max_pool, 4) & ~(page - 1);
            memfd_size = max_pool;
        }
    }

    memfd_size = (memfd_size + page - 1) & ~(page - 1);

    if (ftruncate(pool_fd, memfd_size) == -1) {
        logErrno("failed to set size of SHM backing memory file");
        abortAllocation(pool_fd, null, null, memfd_size);
    }

    if (chain.scrollable and !shm_shim_punch_hole_supported(pool_fd)) {
        offset = 0;
        memfd_size = @intCast(total_size);
        chain.scrollable = false;

        memfd_size = (memfd_size + page - 1) & ~(page - 1);

        if (ftruncate(pool_fd, memfd_size) < 0) {
            logErrno("failed to set size of SHM backing memory file");
            abortAllocation(pool_fd, null, null, memfd_size);
        }
    }

    const real_mmapped = shm_shim_mmap_pool(pool_fd, @intCast(memfd_size));
    if (real_mmapped == null or real_mmapped == MAP_FAILED) {
        logErrno("failed to mmap SHM backing memory file");
        abortAllocation(pool_fd, null, null, memfd_size);
    }

    shm_shim_seal_pool(pool_fd);

    const wl_pool = shm_shim_wl_shm_create_pool(chain.shm, pool_fd, @intCast(memfd_size));
    if (wl_pool == null) {
        logErr("failed to create SHM pool");
        abortAllocation(pool_fd, null, real_mmapped, memfd_size);
    }

    const pool: *types.ShmBufferPool = @ptrCast(@alignCast(
        mallocOrAbort(@sizeOf(types.ShmBufferPool))));
    pool.* = .{
        .fd = pool_fd,
        .wl_pool = wl_pool,
        .real_mmapped = real_mmapped,
        .mmap_size = @intCast(memfd_size),
        .ref_count = 0,
    };

    for (0..count) |i| {
        if (sizes[i] == 0) {
            bufs[i] = null;
            continue;
        }

        const buf: *types.ShmBufferPrivate = @ptrCast(@alignCast(
            mallocOrAbort(@sizeOf(types.ShmBufferPrivate))));
        buf.* = .{
            .public = .{
                .width = widths[i],
                .height = heights[i],
                .stride = strides[i],
                .data = null,
                .wl_buf = null,
                .pix = null,
                .pix_instances = chain.pix_instances,
                .age = 1234, // force a full repaint
                .dirty = null,
            },
            .chain = chain,
            .ref_count = if (immediate_purge) 0 else 1,
            .busy = true,
            .pool = pool,
            .offset = 0,
            .size = @intCast(sizes[i]),
            .scrollable = chain.scrollable,
            .release_cb = chain.release_cb,
            .cb_data = chain.cb_data,
        };

        if (!instantiate_offset(buf, offset)) {
            std.c.free(buf);
            abortAllocation(pool_fd, wl_pool, real_mmapped, memfd_size);
        }

        if (immediate_purge)
            listPushFront(&deferred, buf)
        else
            listPushFront(&chain.bufs, buf);

        const dirty = mallocOrAbort(chain.pix_instances * @sizeOf(types.PixmanRegion32));
        buf.public.dirty = dirty;

        const regions: [*]types.PixmanRegion32 = @ptrCast(@alignCast(dirty));
        for (0..chain.pix_instances) |j|
            pixman_region32_init(&regions[j]);

        pool.ref_count += 1;
        offset += @intCast(buf.size);
        bufs[i] = &buf.public;
    }

    // Keep the pool FD open only if we are going to SHM-scroll it.
    if (!(bufs[0] != null and shm_can_scroll(bufs[0]))) {
        _ = close(pool_fd);
        pool.fd = -1;
    }
}

export fn get_new_buffers(
    chain: *types.ShmBufferChain,
    count: usize,
    widths: [*]c_int,
    heights: [*]c_int,
    bufs: [*]?*types.Buffer,
    immediate_purge: bool,
) callconv(.c) void {
    getNewBuffers(chain, count, widths, heights, bufs, immediate_purge);
}
