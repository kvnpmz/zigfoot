const std = @import("std");
const builtin = @import("builtin");
const types = @import("terminal_types.zig");

//
// The shm module: buffer lifetime (S1), allocation (S2), the buffer cache
// (S3), chain construction/bit depth (S4), scrolling (S5), and the state that
// used to be static in shm.c (S6). shm.c is gone; shm-shim.c keeps only what
// Zig still cannot express: the generated wl_shm/wl_buffer request inlines,
// the headless sentinels, the stride wrapper and the macro-valued format
// constants. The platform/syscall bodies live here, under their original C
// symbol names.
//
// The private structs live in shm.h so the ABI probe can pin them; this file
// mirrors them in terminal_types.zig (including struct shm_format_constants)
// and owns the tllist heads it has to manipulate after C stops touching them
// (deferred) or that it shares with C (buffer_chain.bufs). The compositor's
// format capabilities are read straight out of the mirrored struct wayland.
//

const LOG_CLASS_WARNING: c_int = 2;

// State that used to be file-static in shm.c. main.zig sets the first two
// through shm_set_max_pool_size()/shm_set_min_stride_alignment().
var max_pool_size: i64 = 512 * 1024 * 1024;
var min_stride_alignment: usize = 0;

// The fallocate() capability is probed once, on the first scrollable pool.
// The raw probe is shm_shim_probe_punch_hole(), ported below.
var punch_hole_probed: bool = false;
var can_punch_hole: bool = false;

export fn shm_set_max_pool_size(size: i64) callconv(.c) void {
    max_pool_size = size;
}

export fn shm_set_min_stride_alignment(alignment: usize) callconv(.c) void {
    min_stride_alignment = alignment;
}

extern fn log_msg(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;
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
    const node: *BufferNode = @ptrCast(@alignCast(std.c.malloc(@sizeOf(BufferNode)) orelse @panic("out of memory")));
    const tail: ?*BufferNode = if (list.tail) |t| @ptrCast(@alignCast(t)) else null;

    node.* = .{ .prev = tail, .next = null, .item = item };

    if (tail) |t| t.next = node else list.head = node;
    list.tail = node;
    list.length += 1;
}

fn listPushFront(list: *types.TllBufferPrivate, item: *types.ShmBufferPrivate) void {
    const node: *BufferNode = @ptrCast(@alignCast(std.c.malloc(@sizeOf(BufferNode)) orelse @panic("out of memory")));
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

fn unrefChainBuffer(private: *types.ShmBufferPrivate) void {
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

export fn shm_unref(buf_ptr: ?*types.Buffer) callconv(.c) void {
    const buf = buf_ptr orelse return;
    const private: *types.ShmBufferPrivate = @ptrCast(@alignCast(buf));
    unrefChainBuffer(private);
}

export fn shm_get_many(
    chain: *types.ShmBufferChain,
    count: usize,
    widths: [*]c_int,
    heights: [*]c_int,
    bufs: [*]?*types.Buffer,
) callconv(.c) void {
    getNewBuffers(chain, count, widths, heights, bufs, true);
}

export fn shm_get_buffer(
    chain: *types.ShmBufferChain,
    width: c_int,
    height: c_int,
) callconv(.c) ?*types.Buffer {
    var cached: ?*types.ShmBufferPrivate = null;

    // Snapshot the next pointer before a possible removal, like tll_foreach.
    var node = listHead(&chain.bufs);
    while (node) |n| {
        const next = n.next;
        const buf = n.item;

        if (buf.public.width != width or buf.public.height != height) {
            if (bufferUnrefNoRemoveFromChain(buf))
                listRemove(&chain.bufs, n);
            node = next;
            continue;
        }

        if (buf.busy) {
            buf.public.age += 1;
        } else if (cached == null) {
            cached = buf;
        } else if (buf.public.age < cached.?.public.age) {
            // Several reusable candidates: keep the youngest.
            unrefChainBuffer(cached.?);
            cached = buf;
        } else {
            if (bufferUnrefNoRemoveFromChain(buf))
                listRemove(&chain.bufs, n);
        }

        node = next;
    }

    if (cached) |c| {
        c.busy = true;

        if (c.public.dirty) |dirty| {
            const regions: [*]types.PixmanRegion32 = @ptrCast(@alignCast(dirty));
            for (0..c.public.pix_instances) |i|
                pixman_region32_clear(&regions[i]);
        }

        std.debug.assert(c.public.pix_instances == chain.pix_instances);
        return &c.public;
    }

    var ret: ?*types.Buffer = null;
    var w = width;
    var h = height;
    getNewBuffers(chain, 1, @ptrCast(&w), @ptrCast(&h), @ptrCast(&ret), false);
    return ret;
}

//
// Chunk S2 — allocation: instantiate_offset() and get_new_buffers().
//
// Platform bits that are #ifdef-heavy in C (memfd vs FreeBSD shm_open vs
// mkostemp, fallocate probing, sealing, mmap flags) are ported above; the
// generated Wayland inline wrappers stay in shm-shim.c. Everything about sizes,
// offsets and buffer ownership is here.
//

const LOG_CLASS_ERROR: c_int = 1;

extern fn log_errno(class: c_int, module: [*:0]const u8, file: [*:0]const u8, lineno: c_int, fmt: [*:0]const u8, ...) void;

extern fn shm_shim_stride_for_format(fmt: c_int, width: c_int) callconv(.c) c_int;

//
// Platform/syscall bodies ported from shm-shim.c. The C `#ifdef`s become
// comptime branches on the target OS; no runtime probing beyond the original
// MFD_NOEXEC_SEAL retry and the fallocate() capability probe is introduced.
//
const os_tag = builtin.os.tag;

// C's off_t is i64 on the tested targets; std.c.off_t mirrors the C ABI type
// (linux.off_t == i64), with an explicit i64 fallback for targets that do not
// expose it.
const shm_off_t = if (@hasDecl(std.c, "off_t")) std.c.off_t else i64;

extern fn memfd_create(
    name: [*:0]const u8,
    flags: c_uint,
) callconv(.c) c_int;
extern fn fallocate(
    fd: c_int,
    mode: c_int,
    offset: shm_off_t,
    len: shm_off_t,
) callconv(.c) c_int;
extern fn mmap(
    addr: ?*anyopaque,
    len: usize,
    prot: c_int,
    flags: c_int,
    fd: c_int,
    offset: shm_off_t,
) callconv(.c) ?*anyopaque;
extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
extern fn shm_open(
    name: [*:0]const u8,
    flags: c_int,
    mode: std.c.mode_t,
) callconv(.c) c_int;
extern fn mkostemp(template: [*]u8, flags: c_int) callconv(.c) c_int;
extern fn unlink(path: [*:0]const u8) callconv(.c) c_int;
extern fn strerror(errnum: c_int) callconv(.c) [*:0]const u8;

// Linux UAPI values the port defines locally: std.os.linux has no
// MFD.NOEXEC_SEAL, and the FALLOC masks are kept explicit here.
const MFD_NOEXEC_SEAL: c_uint = 0x0008;
const FALLOC_FL_KEEP_SIZE: c_int = 0x01;
const FALLOC_FL_PUNCH_HOLE: c_int = 0x02;

export fn shm_shim_create_backing_file() callconv(.c) c_int {
    if (comptime os_tag == .linux) {
        const name = "foot-wayland-shm-buffer-pool";

        // Older kernels reject MFD_NOEXEC_SEAL with EINVAL; try with it
        // first, then retry without it.
        const flags: c_uint = @intCast(
            std.c.MFD.CLOEXEC | std.c.MFD.ALLOW_SEALING | MFD_NOEXEC_SEAL,
        );
        var fd = memfd_create(name, flags);
        if (fd < 0 and std.c._errno().* == @as(c_int, @intFromEnum(std.os.linux.E.INVAL))) {
            fd = memfd_create(
                name,
                @intCast(std.c.MFD.CLOEXEC | std.c.MFD.ALLOW_SEALING),
            );
        }
        return fd;
    } else if (comptime os_tag == .freebsd) {
        // FreeBSD 13's memfd_create is SHM_ANON without sealing support.
        // SHM_ANON is ((char *)-1) in <sys/mman.h>.
        const shm_anon: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
        const flags: c_int = @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true });
        return shm_open(shm_anon, flags, @as(std.c.mode_t, 0o600));
    } else {
        const template = "/tmp/foot-wayland-shm-buffer-pool-XXXXXX";
        var name: [template.len:0]u8 = undefined;
        @memcpy(name[0..template.len], template);
        name[template.len] = 0;

        const flags: c_int = @bitCast(std.c.O{ .CLOEXEC = true });
        const fd = mkostemp(&name, flags);
        if (fd >= 0)
            _ = unlink(&name);
        return fd;
    }
}

export fn shm_shim_probe_punch_hole(fd: c_int) callconv(.c) bool {
    // 32-bit lacks the address space; FALLOC_FL_* is Linux-only.
    if (comptime (@sizeOf(usize) != 8 or os_tag != .linux))
        return false;

    const supported = fallocate(
        fd,
        FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
        0,
        1,
    ) == 0;

    if (!supported) {
        log_msg(
            LOG_CLASS_WARNING,
            "shm",
            "shm.zig",
            @intCast(@src().line),
            "fallocate(FALLOC_FL_PUNCH_HOLE) not supported (%s): expect lower performance",
            strerror(std.c._errno().*),
        );
    }
    return supported;
}

export fn shm_shim_mmap_pool(fd: c_int, size: usize) callconv(.c) ?*anyopaque {
    const prot: c_int = @bitCast(std.c.PROT{ .READ = true, .WRITE = true });

    // MAP_UNINITIALIZED is 0 where it is not defined by the platform.
    const flags: c_int = if (comptime os_tag == .linux)
        @bitCast(std.c.MAP{ .TYPE = .SHARED, .UNINITIALIZED = true })
    else
        @bitCast(std.c.MAP{ .TYPE = .SHARED });

    return mmap(null, size, prot, flags, fd, 0);
}

export fn shm_shim_seal_pool(fd: c_int) callconv(.c) void {
    if (comptime os_tag != .linux)
        return;

    // TODO: wayland mmaps(PROT_WRITE); F_SEAL_FUTURE_WRITE would break it.
    const seals: c_int = @intCast(
        std.os.linux.F.SEAL_GROW | std.os.linux.F.SEAL_SHRINK |
            std.os.linux.F.SEAL_SEAL,
    );
    if (fcntl(fd, @intCast(std.os.linux.F.ADD_SEALS), seals) < 0) {
        logErrno("failed to seal SHM backing memory file");
        // Not a fatal error.
    }
}
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
extern fn pixman_region32_clear(region: ?*anyopaque) callconv(.c) void;
export fn shm_shim_punch_hole(
    fd: c_int,
    ofs: shm_off_t,
    len: shm_off_t,
) callconv(.c) bool {
    if (comptime (@sizeOf(usize) != 8 or os_tag != .linux))
        return false;

    return fallocate(
        fd,
        FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
        ofs,
        len,
    ) == 0;
}
extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;

fn punchHoleSupported(fd: c_int) bool {
    if (comptime @sizeOf(usize) != 8)
        return false; // Not enough virtual address space in 32-bit

    if (!punch_hole_probed) {
        punch_hole_probed = true;
        can_punch_hole = shm_shim_probe_punch_hole(fd);
    }
    return can_punch_hole;
}

fn logErr(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_ERROR, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

fn logErrno(msg: [*:0]const u8) void {
    log_errno(LOG_CLASS_ERROR, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

// ── page_size() from shm-shim.c ───────────────────────────────────
// Zig's std.heap.pageSize() is not exactly equivalent: on a failed query
// it falls back to a compile-time bound instead of C's 4096 + LOG_ERRNO.
// Keep the shim's body (including its one-time cache) here; the C ABI
// name stays an export for any remaining C caller.
const page_size_cache = struct {
    var size: usize = 0;
};

fn page_size() usize {
    if (page_size_cache.size == 0) {
        const n = std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE));
        if (n <= 0) {
            logErrno("failed to get page size");
            page_size_cache.size = 4096;
        } else {
            page_size_cache.size = @intCast(n);
        }
    }
    std.debug.assert(page_size_cache.size > 0);
    return page_size_cache.size;
}

export fn shm_shim_page_size() callconv(.c) usize {
    return page_size();
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

    const pix: [*]?*anyopaque = @ptrCast(@alignCast(callocOrAbort(buf.public.pix_instances, @sizeOf(?*anyopaque))));

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

    const alignment = min_stride_alignment;
    var total_size: usize = 0;

    for (0..count) |i| {
        var stride: c_int = shm_shim_stride_for_format(@intCast(chain.pixman_fmt), widths[i]);

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

    const page_sz = page_size();
    const page: i64 = @intCast(page_sz);
    const max_pool = max_pool_size;

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

    if (chain.scrollable and !punchHoleSupported(pool_fd)) {
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

    const pool: *types.ShmBufferPool = @ptrCast(@alignCast(mallocOrAbort(@sizeOf(types.ShmBufferPool))));
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

        const buf: *types.ShmBufferPrivate = @ptrCast(@alignCast(mallocOrAbort(@sizeOf(types.ShmBufferPrivate))));
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
    if (!(bufs[0] != null and
        canScroll(@ptrCast(@alignCast(bufs[0].?)))))
    {
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

//
// Chunk S4 — buffer-chain construction/free and bit depth. The pixman and
// wl_shm_format constants, and the compositor's format capabilities, come
// from shm-shim.c because they are macros/enums; the compositor's capability
// flags come from the mirrored struct wayland.
//

extern fn shm_shim_format_constants() callconv(.c) *const types.ShmFormatConstants;

// enum shm_bit_depth { SHM_BITS_AUTO, SHM_BITS_8, SHM_BITS_10, SHM_BITS_16 }
const SHM_BITS_8: c_int = 1;
const SHM_BITS_10: c_int = 2;
const SHM_BITS_16: c_int = 3;

const LOG_CLASS_INFO: c_int = 3;

var logged: bool = false;
var logged_10_fallback: bool = false;
var logged_16_fallback: bool = false;

fn logInfo(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_INFO, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

fn logWarn(msg: [*:0]const u8) void {
    log_msg(LOG_CLASS_WARNING, "shm", "shm.zig", @intCast(@src().line), "%s", msg);
}

export fn shm_chain_new(
    wayl: ?*types.Wayland,
    scrollable: bool,
    pix_instances: usize,
    desired_bit_depth: c_int,
    release_cb: ?*const anyopaque,
    cb_data: ?*anyopaque,
) callconv(.c) ?*types.ShmBufferChain {
    const constants = shm_shim_format_constants().*;
    const shm: ?*anyopaque = if (wayl) |w| w.shm else null;
    const abgr161616 = if (wayl) |w| w._shm_format_bits.abgr161616 else false;
    const argb2101010 = if (wayl) |w| w._shm_format_bits.argb2101010 else false;
    const abgr2101010 = if (wayl) |w| w._shm_format_bits.abgr2101010 else false;

    var pixman_fmt: u32 = constants.pixman_a8r8g8b8;
    var shm_fmt: u32 = constants.wl_argb8888;

    if (constants.pixman_a16b16g16r16 != 0 and desired_bit_depth == SHM_BITS_16) {
        if (abgr161616) {
            pixman_fmt = constants.pixman_a16b16g16r16;
            shm_fmt = constants.wl_abgr16161616;

            if (!logged) {
                logged = true;
                logInfo("using 16-bit BGR surfaces");
            }
        } else if (!logged_16_fallback) {
            logged_16_fallback = true;
            logWarn("16-bit surfaces requested, but compositor does not implement ABGR161616+XBGR161616");
        }
    }

    if (desired_bit_depth >= SHM_BITS_10 and pixman_fmt == constants.pixman_a8r8g8b8) {
        if (argb2101010) {
            pixman_fmt = constants.pixman_a2r10g10b10;
            shm_fmt = constants.wl_argb2101010;

            if (!logged) {
                logged = true;
                logInfo("using 10-bit RGB surfaces");
            }
        } else if (abgr2101010) {
            pixman_fmt = constants.pixman_a2b10g10r10;
            shm_fmt = constants.wl_abgr2101010;

            if (!logged) {
                logged = true;
                logInfo("using 10-bit BGR surfaces");
            }
        } else if (!logged_10_fallback) {
            logged_10_fallback = true;
            logWarn("10-bit surfaces requested, but compositor does not implement ARGB2101010+XRGB2101010, or ABGR2101010+XBGR2101010");
        }
    } else if (!logged) {
        logged = true;
        logInfo("using 8-bit RGB surfaces");
    }

    const chain: *types.ShmBufferChain = @ptrCast(@alignCast(mallocOrAbort(@sizeOf(types.ShmBufferChain))));
    chain.* = .{
        .bufs = .{ .head = null, .tail = null, .length = 0 },
        .shm = shm,
        .pix_instances = pix_instances,
        .scrollable = scrollable,
        .pixman_fmt = pixman_fmt,
        .shm_format = shm_fmt,
        .release_cb = release_cb,
        .cb_data = cb_data,
    };
    return chain;
}

export fn shm_chain_free(chain_ptr: ?*types.ShmBufferChain) callconv(.c) void {
    const chain = chain_ptr orelse return;

    shm_purge(chain);

    if (chain.bufs.length > 0) {
        logErr("chain still has buffers; is a shm_unref() missing?");
        std.c.abort();
    }

    std.c.free(chain);
}

export fn shm_chain_bit_depth(
    chain: *const types.ShmBufferChain,
) callconv(.c) c_int {
    const constants = shm_shim_format_constants().*;

    if (chain.pixman_fmt == constants.pixman_a8r8g8b8)
        return SHM_BITS_8;

    if (constants.pixman_a16b16g16r16 != 0 and
        chain.pixman_fmt == constants.pixman_a16b16g16r16)
        return SHM_BITS_16;

    return SHM_BITS_10;
}

//
// Chunk S5 — SHM scrolling. The punch-hole capability probe and the
// fallocate() call are guarded by comptime pointer-width/OS checks in the
// ported platform bodies, so the 32-bit and no-punch-hole builds fall out of
// shm_shim_punch_hole() returning false and shm_can_scroll() returning false.
//

fn canScroll(buf: *const types.ShmBufferPrivate) bool {
    if (comptime @sizeOf(usize) != 8)
        return false; // Not enough virtual address space in 32-bit

    return can_punch_hole and
        max_pool_size > 0 and
        buf.scrollable;
}

export fn shm_can_scroll(buf_ptr: *const types.Buffer) callconv(.c) bool {
    const buf: *const types.ShmBufferPrivate = @ptrCast(@alignCast(buf_ptr));
    return canScroll(buf);
}

fn wrapBuffer(buf: *types.ShmBufferPrivate, new_offset: i64) bool {
    const pool = buf.pool.?;
    std.debug.assert(pool.ref_count == 1);

    // We don't allow overlapping offsets
    const diff: i64 = if (new_offset < buf.offset)
        buf.offset - new_offset
    else
        new_offset - buf.offset;
    std.debug.assert(diff > @as(i64, @intCast(buf.size)));

    const base: [*]u8 = @ptrCast(pool.real_mmapped.?);
    _ = memcpy(
        base + @as(usize, @intCast(new_offset)),
        buf.public.data.?,
        buf.size,
    );

    var trim_ofs: i64 = undefined;
    var trim_len: i64 = undefined;
    if (new_offset > buf.offset) {
        // Trim everything *before* the new offset
        trim_ofs = 0;
        trim_len = new_offset;
    } else {
        // Trim everything *after* the new buffer location
        trim_ofs = new_offset + @as(i64, @intCast(buf.size));
        trim_len = @as(i64, @intCast(pool.mmap_size)) - trim_ofs;
    }

    if (!shm_shim_punch_hole(pool.fd, trim_ofs, trim_len)) {
        logErrno("failed to trim SHM backing memory file");
        return false;
    }

    // Re-instantiate pixman+wl_buffer+raw pointers
    bufferDestroyDontClose(&buf.public);
    return instantiate_offset(buf, new_offset);
}

fn topRegionBase(buf: *types.ShmBufferPrivate) [*]u8 {
    return @ptrCast(buf.public.data.?);
}

fn scrollForward(
    buf: *types.ShmBufferPrivate,
    rows: c_int,
    top_margin: c_int,
    top_keep_rows: c_int,
    bottom_margin: c_int,
    bottom_keep_rows: c_int,
) bool {
    const pool = buf.pool.?;

    std.debug.assert(can_punch_hole);
    std.debug.assert(buf.busy);
    std.debug.assert(buf.public.pix != null);
    std.debug.assert(buf.public.wl_buf != null);
    std.debug.assert(pool.ref_count == 1);
    std.debug.assert(pool.fd >= 0);

    const diff: i64 = @as(i64, rows) * @as(i64, buf.public.stride);
    std.debug.assert(rows > 0);
    std.debug.assert(diff < @as(i64, @intCast(buf.size)));

    const max_pool = max_pool_size;

    if (buf.offset + diff + @as(i64, @intCast(buf.size)) > max_pool) {
        if (!wrapBuffer(buf, 0))
            std.c.abort();
    }

    const new_offset = buf.offset + diff;
    std.debug.assert(new_offset > buf.offset);
    std.debug.assert(new_offset + @as(i64, @intCast(buf.size)) <= max_pool);

    if (top_keep_rows > 0) {
        // Copy current 'top' region to its new location
        const stride: i64 = buf.public.stride;
        const base = topRegionBase(buf);

        _ = memmove(
            base + @as(usize, @intCast((@as(i64, top_margin) + rows) * stride)),
            base + @as(usize, @intCast(@as(i64, top_margin) * stride)),
            @as(usize, @intCast(@as(i64, top_keep_rows) * stride)),
        );
    }

    // Destroy old objects (they point to the old offset)
    bufferDestroyDontClose(&buf.public);

    // Free unused memory - everything up until the new offset
    if (!shm_shim_punch_hole(pool.fd, 0, new_offset)) {
        logErrno("failed to trim SHM backing memory file");
        std.c.abort();
    }

    // Re-instantiate pixman+wl_buffer+raw pointers
    const ret = instantiate_offset(buf, new_offset);

    if (ret and bottom_keep_rows > 0) {
        // Copy 'bottom' region to its new location
        const size: i64 = @intCast(buf.size);
        const stride: i64 = buf.public.stride;
        const base = topRegionBase(buf);

        _ = memmove(
            base + @as(usize, @intCast(size - (@as(i64, bottom_margin) + bottom_keep_rows) * stride)),
            base + @as(usize, @intCast(size - (@as(i64, bottom_margin) + rows + bottom_keep_rows) * stride)),
            @as(usize, @intCast(@as(i64, bottom_keep_rows) * stride)),
        );
    }

    return ret;
}

fn scrollReverse(
    buf: *types.ShmBufferPrivate,
    rows: c_int,
    top_margin: c_int,
    top_keep_rows: c_int,
    bottom_margin: c_int,
    bottom_keep_rows: c_int,
) bool {
    std.debug.assert(rows > 0);

    const pool = buf.pool.?;
    std.debug.assert(pool.ref_count == 1);

    const max_pool = max_pool_size;
    const diff: i64 = @as(i64, rows) * @as(i64, buf.public.stride);

    if (diff > buf.offset) {
        const page: i64 = @intCast(page_size());
        if (!wrapBuffer(
            buf,
            (max_pool - @as(i64, @intCast(buf.size))) & ~(page - 1),
        )) std.c.abort();
    }

    const new_offset = buf.offset - diff;
    std.debug.assert(new_offset < buf.offset);
    std.debug.assert(new_offset <= max_pool);

    if (bottom_keep_rows > 0) {
        // Copy 'bottom' region to its new location
        const size: i64 = @intCast(buf.size);
        const stride: i64 = buf.public.stride;
        const base = topRegionBase(buf);

        _ = memmove(
            base + @as(usize, @intCast(size - (@as(i64, bottom_margin) + rows + bottom_keep_rows) * stride)),
            base + @as(usize, @intCast(size - (@as(i64, bottom_margin) + bottom_keep_rows) * stride)),
            @as(usize, @intCast(@as(i64, bottom_keep_rows) * stride)),
        );
    }

    // Destroy old objects (they point to the old offset)
    bufferDestroyDontClose(&buf.public);

    // Free unused memory - everything after the relocated buffer
    const trim_ofs = new_offset + @as(i64, @intCast(buf.size));
    const trim_len = @as(i64, @intCast(pool.mmap_size)) - trim_ofs;

    if (!shm_shim_punch_hole(pool.fd, trim_ofs, trim_len)) {
        logErrno("failed to trim SHM backing memory file");
        std.c.abort();
    }

    // Re-instantiate pixman+wl_buffer+raw pointers
    const ret = instantiate_offset(buf, new_offset);

    if (ret and top_keep_rows > 0) {
        // Copy current 'top' region to its new location
        const stride: i64 = buf.public.stride;
        const base = topRegionBase(buf);

        _ = memmove(
            base + @as(usize, @intCast(@as(i64, top_margin) * stride)),
            base + @as(usize, @intCast((@as(i64, top_margin) + rows) * stride)),
            @as(usize, @intCast(@as(i64, top_keep_rows) * stride)),
        );
    }

    return ret;
}

export fn shm_scroll(
    buf_ptr: *types.Buffer,
    rows: c_int,
    top_margin: c_int,
    top_keep_rows: c_int,
    bottom_margin: c_int,
    bottom_keep_rows: c_int,
) callconv(.c) bool {
    if (!canScroll(@ptrCast(@alignCast(buf_ptr))))
        return false;

    const buf: *types.ShmBufferPrivate = @ptrCast(@alignCast(buf_ptr));

    std.debug.assert(rows != 0);
    return if (rows > 0)
        scrollForward(buf, rows, top_margin, top_keep_rows, bottom_margin, bottom_keep_rows)
    else
        scrollReverse(buf, -rows, top_margin, top_keep_rows, bottom_margin, bottom_keep_rows);
}
