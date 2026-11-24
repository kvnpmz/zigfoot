#include "shm.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>
#include <time.h>

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>

#include <pixman.h>

#include <tllist.h>

#define LOG_MODULE "shm"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "debug.h"
#include "macros.h"
#include "stride.h"
#include "xmalloc.h"

#if !defined(MAP_UNINITIALIZED)
 #define MAP_UNINITIALIZED 0
#endif

#if !defined(MFD_NOEXEC_SEAL)
 #define MFD_NOEXEC_SEAL 0
#endif

/* wl_buffer_destroy()/wl_shm_pool_destroy() are static inline in the
 * generated protocol header, so shm.zig needs real symbols. */
/* Headless harness has no wl_shm connection: chain->shm == NULL selects a
 * pair of never-dereferenced sentinels, so allocation and cache logic can run
 * without a compositor. */
static struct wl_shm_pool *shm_stub_pool;
static struct wl_buffer *shm_stub_buffer;

void shm_shim_wl_buffer_destroy(struct wl_buffer *buffer) {
    if (buffer == (struct wl_buffer *)&shm_stub_buffer)
        return;
    wl_buffer_destroy(buffer);
}

void shm_shim_wl_shm_pool_destroy(struct wl_shm_pool *pool) {
    if (pool == (struct wl_shm_pool *)&shm_stub_pool)
        return;
    wl_shm_pool_destroy(pool);
}

/* Ported to shm.zig — extern for C callers */
extern void buffer_destroy_dont_close(struct buffer *buf);
extern void pool_unref(struct buffer_pool *pool);
extern void buffer_destroy(struct buffer_private *buf);
extern bool buffer_unref_no_remove_from_chain(struct buffer_private *buf);
extern void buffer_release(void *data, struct wl_buffer *wl_buffer);
/* C still populates the deferred list during allocation (shm.zig owns it). */
extern void shm_defer_push_front(struct buffer_private *buf);
extern bool instantiate_offset(struct buffer_private *buf, off_t new_offset);
extern void get_new_buffers(
    struct buffer_chain *chain, size_t count,
    int widths[static count], int heights[static count],
    struct buffer *bufs[static count], bool immediate_purge);

#define TIME_SCROLL 0

#define FORCED_DOUBLE_BUFFERING 0

/*
 * Maximum memfd size allowed.
 *
 * On 64-bit, we could in theory use up to 2GB (wk_shm_create_pool()
 * is limited to int32_t), since we never mmap() the entire region.
 *
 * The compositor is different matter - it needs to mmap() the entire
 * range, and *keep* the mapping for as long as is has buffers
 * referencing it (thus - always). And if we open multiple terminals,
 * then the required address space multiples...
 *
 * That said, 128TB (the total amount of available user address space
 * on 64-bit) is *a lot*; we can fit 67108864 2GB memfds into
 * that. But, let's be conservative for now.
 *
 * On 32-bit the available address space is too small and SHM
 * scrolling is disabled.
 *
 * Note: this is the _default_ size. It can be overridden by calling
 * shm_set_max_pool_size();
 */
static off_t max_pool_size = 512 * 1024 * 1024;

static bool can_punch_hole = false;
static bool can_punch_hole_initialized = false;

static size_t min_stride_alignment = 0;

#undef MEASURE_SHM_ALLOCS
#if defined(MEASURE_SHM_ALLOCS)
static size_t max_alloced = 0;
#endif

void
shm_set_max_pool_size(off_t _max_pool_size)
{
    max_pool_size = _max_pool_size;
}

void
shm_set_min_stride_alignment(size_t _min_stride_alignment)
{
    min_stride_alignment = _min_stride_alignment;
}

/* buffer_destroy_dont_close / pool_unref / buffer_destroy /
 * buffer_unref_no_remove_from_chain / shm_fini: ported to shm.zig */

/* buffer_release: ported to shm.zig */

static const struct wl_buffer_listener buffer_listener = {
    .release = &buffer_release,
};

static size_t
page_size(void)
{
    static size_t size = 0;
    if (size == 0) {
        long n = sysconf(_SC_PAGE_SIZE);
        if (n <= 0) {
            LOG_ERRNO("failed to get page size");
            size = 4096;
        } else {
            size = (size_t)n;
        }
    }
    xassert(size > 0);
    return size;
}

/* ── platform/protocol shims for shm.zig's allocation path ────────── */

size_t shm_shim_page_size(void) {
    return page_size();
}

off_t shm_shim_max_pool_size(void) {
    return max_pool_size;
}

size_t shm_shim_min_stride_alignment(void) {
    return min_stride_alignment;
}

int shm_shim_stride_for_format(pixman_format_code_t fmt, int width) {
    return stride_for_format_and_width(fmt, width);
}

int shm_shim_create_backing_file(void) {
#if defined(MEMFD_CREATE)
    /*
     * Older kernels reject MFD_NOEXEC_SEAL with EINVAL. Try first
     * *with* it, and if that fails, try again *without* it.
     */
    errno = 0;
    int fd = memfd_create(
        "foot-wayland-shm-buffer-pool",
        MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_NOEXEC_SEAL);

    if (fd < 0 && errno == EINVAL && MFD_NOEXEC_SEAL != 0) {
        fd = memfd_create(
            "foot-wayland-shm-buffer-pool", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    }
    return fd;
#elif defined(__FreeBSD__)
    // memfd_create on FreeBSD 13 is SHM_ANON without sealing support
    return shm_open(SHM_ANON, O_RDWR | O_CLOEXEC, 0600);
#else
    char name[] = "/tmp/foot-wayland-shm-buffer-pool-XXXXXX";
    int fd = mkostemp(name, O_CLOEXEC);
    if (fd >= 0)
        unlink(name);
    return fd;
#endif
}

bool shm_shim_punch_hole_supported(int fd) {
    if (!can_punch_hole_initialized) {
        can_punch_hole_initialized = true;
#if __SIZEOF_POINTER__ == 8 && defined(FALLOC_FL_PUNCH_HOLE)
        can_punch_hole = fallocate(
            fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, 0, 1) == 0;

        if (!can_punch_hole) {
            LOG_WARN(
                "fallocate(FALLOC_FL_PUNCH_HOLE) not "
                "supported (%s): expect lower performance", strerror(errno));
        }
#else
        can_punch_hole = false;
#endif
    }
    return can_punch_hole;
}

void *shm_shim_mmap_pool(int fd, size_t size) {
    return mmap(
        NULL, size, PROT_READ | PROT_WRITE,
        MAP_SHARED | MAP_UNINITIALIZED, fd, 0);
}

void shm_shim_seal_pool(int fd) {
#if defined(MEMFD_CREATE)
    /* TODO: wayland mmaps(PROT_WRITE), for some unknown reason, hence we
     * cannot use F_SEAL_FUTURE_WRITE */
    if (fcntl(fd, F_ADD_SEALS,
              F_SEAL_GROW | F_SEAL_SHRINK | /*F_SEAL_FUTURE_WRITE |*/ F_SEAL_SEAL) < 0)
    {
        LOG_ERRNO("failed to seal SHM backing memory file");
        /* This is not a fatal error */
    }
#else
    (void)fd;
#endif
}

struct wl_shm_pool *shm_shim_wl_shm_create_pool(
    struct wl_shm *shm, int fd, int32_t size)
{
    if (shm == NULL)
        return (struct wl_shm_pool *)&shm_stub_pool;
    return wl_shm_create_pool(shm, fd, size);
}

struct wl_buffer *shm_shim_wl_shm_pool_create_buffer(
    struct wl_shm_pool *pool, int32_t offset, int32_t width, int32_t height,
    int32_t stride, uint32_t format)
{
    if (pool == (struct wl_shm_pool *)&shm_stub_pool)
        return (struct wl_buffer *)&shm_stub_buffer;

    return wl_shm_pool_create_buffer(
        pool, offset, width, height, stride, format);
}

void shm_shim_wl_buffer_add_listener(struct wl_buffer *buffer, void *data) {
    if (buffer == (struct wl_buffer *)&shm_stub_buffer)
        return;
    wl_buffer_add_listener(buffer, &buffer_listener, data);
}

/* instantiate_offset / get_new_buffers: ported to shm.zig */

/* shm_did_not_use_buf: ported to shm.zig */

/* shm_get_many / shm_get_buffer: ported to shm.zig */

bool
shm_can_scroll(const struct buffer *_buf)
{
#if __SIZEOF_POINTER__ == 8
    const struct buffer_private *buf = (const struct buffer_private *)_buf;
    return can_punch_hole && max_pool_size > 0 && buf->scrollable;
#else
    /* Not enough virtual address space in 32-bit */
    return false;
#endif
}

#if __SIZEOF_POINTER__ == 8 && defined(FALLOC_FL_PUNCH_HOLE)
static bool
wrap_buffer(struct buffer_private *buf, off_t new_offset)
{
    struct buffer_pool *pool = buf->pool;
    xassert(pool->ref_count == 1);

    /* We don't allow overlapping offsets */
    off_t UNUSED diff = new_offset < buf->offset
        ? buf->offset - new_offset
        : new_offset - buf->offset;
    xassert(diff > buf->size);

    memcpy((uint8_t *)pool->real_mmapped + new_offset,
           buf->public.data,
           buf->size);

    off_t trim_ofs, trim_len;
    if (new_offset > buf->offset) {
        /* Trim everything *before* the new offset */
        trim_ofs = 0;
        trim_len = new_offset;
    } else {
        /* Trim everything *after* the new buffer location */
        trim_ofs = new_offset + buf->size;
        trim_len = pool->mmap_size - trim_ofs;
    }

    if (fallocate(
            pool->fd,
            FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
            trim_ofs, trim_len) < 0)
    {
        LOG_ERRNO("failed to trim SHM backing memory file");
        return false;
    }

    /* Re-instantiate pixman+wl_buffer+raw pointersw */
    buffer_destroy_dont_close(&buf->public);
    return instantiate_offset(buf, new_offset);
}

static bool
shm_scroll_forward(struct buffer_private *buf, int rows,
                   int top_margin, int top_keep_rows,
                   int bottom_margin, int bottom_keep_rows)
{
    struct buffer_pool *pool = buf->pool;

    xassert(can_punch_hole);
    xassert(buf->busy);
    xassert(buf->public.pix != NULL);
    xassert(buf->public.wl_buf != NULL);
    xassert(pool != NULL);
    xassert(pool->ref_count == 1);
    xassert(pool->fd >= 0);

    LOG_DBG("scrolling %d rows (%d bytes)", rows, rows * buf->public.stride);

    const off_t diff = rows * buf->public.stride;
    xassert(rows > 0);
    xassert(diff < buf->size);

    if (buf->offset + diff + buf->size > max_pool_size) {
        LOG_DBG("memfd offset wrap around");
        if (!wrap_buffer(buf, 0))
            goto err;
    }

    off_t new_offset = buf->offset + diff;
    xassert(new_offset > buf->offset);
    xassert(new_offset + buf->size <= max_pool_size);

#if TIME_SCROLL
    struct timespec tot;
    struct timespec time1;
    clock_gettime(CLOCK_MONOTONIC, &time1);

    struct timespec time2 = time1;
#endif

    if (top_keep_rows > 0) {
        /* Copy current 'top' region to its new location */
        const int stride = buf->public.stride;
        uint8_t *base = buf->public.data;

        memmove(
            base + (top_margin + rows) * stride,
            base + (top_margin + 0) * stride,
            top_keep_rows * stride);

#if TIME_SCROLL
        clock_gettime(CLOCK_MONOTONIC, &time2);
        timespec_sub(&time2, &time1, &tot);
        LOG_INFO("memmove (top region): %lds %ldns",
                 (long)tot.tv_sec, tot.tv_nsec);
#endif
    }

    /* Destroy old objects (they point to the old offset) */
    buffer_destroy_dont_close(&buf->public);

    /* Free unused memory - everything up until the new offset */
    const off_t trim_ofs = 0;
    const off_t trim_len = new_offset;

    if (fallocate(
            pool->fd,
            FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
            trim_ofs, trim_len) < 0)
    {
        LOG_ERRNO("failed to trim SHM backing memory file");
        goto err;
    }

#if TIME_SCROLL
    struct timespec time3;
    clock_gettime(CLOCK_MONOTONIC, &time3);
    timespec_sub(&time3, &time2, &tot);
    LOG_INFO("PUNCH HOLE: %lds %ldns", (long)tot.tv_sec, tot.tv_nsec);
#endif

    /* Re-instantiate pixman+wl_buffer+raw pointersw */
    bool ret = instantiate_offset(buf, new_offset);

#if TIME_SCROLL
    struct timespec time4;
    clock_gettime(CLOCK_MONOTONIC, &time4);
    timespec_sub(&time4, &time3, &tot);
    LOG_INFO("instantiate offset: %lds %ldns", (long)tot.tv_sec, tot.tv_nsec);
#endif

    if (ret && bottom_keep_rows > 0) {
        /* Copy 'bottom' region to its new location */
        const size_t size = buf->size;
        const int stride = buf->public.stride;
        uint8_t *base = buf->public.data;

        memmove(
            base + size - (bottom_margin + bottom_keep_rows) * stride,
            base + size - (bottom_margin + rows + bottom_keep_rows) * stride,
            bottom_keep_rows * stride);

#if TIME_SCROLL
        struct timespec time5;
        clock_gettime(CLOCK_MONOTONIC, &time5);

        timespec_sub(&time5, &time4, &tot);
        LOG_INFO("memmove (bottom region): %lds %ldns",
                 (long)tot.tv_sec, tot.tv_nsec);
#endif
    }

    return ret;

err:
    abort();
    return false;
}

static bool
shm_scroll_reverse(struct buffer_private *buf, int rows,
                   int top_margin, int top_keep_rows,
                   int bottom_margin, int bottom_keep_rows)
{
    xassert(rows > 0);

    struct buffer_pool *pool = buf->pool;
    xassert(pool->ref_count == 1);

    const off_t diff = rows * buf->public.stride;
    if (diff > buf->offset) {
        LOG_DBG("memfd offset reverse wrap-around");
        if (!wrap_buffer(buf, (max_pool_size - buf->size) & ~(page_size() - 1)))
            goto err;
    }

    off_t new_offset = buf->offset - diff;
    xassert(new_offset < buf->offset);
    xassert(new_offset <= max_pool_size);

#if TIME_SCROLL
    struct timespec time0;
    clock_gettime(CLOCK_MONOTONIC, &time0);

    struct timespec tot;
    struct timespec time1 = time0;
#endif

    if (bottom_keep_rows > 0) {
        /* Copy 'bottom' region to its new location */
        const size_t size = buf->size;
        const int stride = buf->public.stride;
        uint8_t *base = buf->public.data;

        memmove(
            base + size - (bottom_margin + rows + bottom_keep_rows) * stride,
            base + size - (bottom_margin + bottom_keep_rows) * stride,
            bottom_keep_rows * stride);

#if TIME_SCROLL
        clock_gettime(CLOCK_MONOTONIC, &time1);
        timespec_sub(&time1, &time0, &tot);
        LOG_INFO("memmove (bottom region): %lds %ldns",
                 (long)tot.tv_sec, tot.tv_nsec);
#endif
    }

    /* Destroy old objects (they point to the old offset) */
    buffer_destroy_dont_close(&buf->public);

    /* Free unused memory - everything after the relocated buffer */
    const off_t trim_ofs = new_offset + buf->size;
    const off_t trim_len = pool->mmap_size - trim_ofs;

    if (fallocate(
            pool->fd,
            FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
            trim_ofs, trim_len) < 0)
    {
        LOG_ERRNO("failed to trim SHM backing memory");
        goto err;
    }
#if TIME_SCROLL
    struct timespec time2;
    clock_gettime(CLOCK_MONOTONIC, &time2);
    timespec_sub(&time2, &time1, &tot);
    LOG_INFO("fallocate: %lds %ldns", (long)tot.tv_sec, tot.tv_nsec);
#endif

    /* Re-instantiate pixman+wl_buffer+raw pointers */
    bool ret = instantiate_offset(buf, new_offset);

#if TIME_SCROLL
    struct timespec time3;
    clock_gettime(CLOCK_MONOTONIC, &time3);
    timespec_sub(&time3, &time2, &tot);
    LOG_INFO("instantiate offset: %lds %ldns", (long)tot.tv_sec, tot.tv_nsec);
#endif

    if (ret && top_keep_rows > 0) {
        /* Copy current 'top' region to its new location */
        const int stride = buf->public.stride;
        uint8_t *base = buf->public.data;

        memmove(
            base + (top_margin + 0) * stride,
            base + (top_margin + rows) * stride,
            top_keep_rows * stride);

#if TIME_SCROLL
        struct timespec time4;
        clock_gettime(CLOCK_MONOTONIC, &time4);
        timespec_sub(&time4, &time3, &tot);
        LOG_INFO("memmove (top region): %lds %ldns",
                 (long)tot.tv_sec, tot.tv_nsec);
#endif
    }

    return ret;

err:
    abort();
    return false;
}
#endif /* FALLOC_FL_PUNCH_HOLE */

bool
shm_scroll(struct buffer *_buf, int rows,
           int top_margin, int top_keep_rows,
           int bottom_margin, int bottom_keep_rows)
{
#if __SIZEOF_POINTER__ == 8 && defined(FALLOC_FL_PUNCH_HOLE)
    if (!shm_can_scroll(_buf))
        return false;

    struct buffer_private *buf = (struct buffer_private *)_buf;

    xassert(rows != 0);
    return rows > 0
        ? shm_scroll_forward(buf, rows, top_margin, top_keep_rows, bottom_margin, bottom_keep_rows)
        : shm_scroll_reverse(buf, -rows, top_margin, top_keep_rows, bottom_margin, bottom_keep_rows);
#else
    return false;
#endif
}

/* shm_purge / shm_addref / shm_unref: ported to shm.zig */

struct buffer_chain *
shm_chain_new(struct wayland *wayl, bool scrollable, size_t pix_instances,
              enum shm_bit_depth desired_bit_depth,
              void (*release_cb)(struct buffer *buf, void *data), void *cb_data)
{
    pixman_format_code_t pixman_fmt = PIXMAN_a8r8g8b8;
    enum wl_shm_format shm_fmt = WL_SHM_FORMAT_ARGB8888;

    static bool have_logged = false;
    static bool have_logged_10_fallback = false;

#if defined(HAVE_PIXMAN_RGBA_16)
    static bool have_logged_16_fallback = false;

    if (desired_bit_depth == SHM_BITS_16) {
        if (wayl->shm_have_abgr161616) {
            pixman_fmt = PIXMAN_a16b16g16r16;
            shm_fmt = WL_SHM_FORMAT_ABGR16161616;

            if (!have_logged) {
                have_logged = true;
                LOG_INFO("using 16-bit BGR surfaces");
            }
        } else {
            if (!have_logged_16_fallback) {
                have_logged_16_fallback = true;

                LOG_WARN(
                    "16-bit surfaces requested, but compositor does not "
                    "implement ABGR161616+XBGR161616");
            }
        }
    }
#endif

    if (desired_bit_depth >= SHM_BITS_10 && pixman_fmt == PIXMAN_a8r8g8b8) {
        if (wayl->shm_have_argb2101010) {
            pixman_fmt = PIXMAN_a2r10g10b10;
            shm_fmt = WL_SHM_FORMAT_ARGB2101010;

            if (!have_logged) {
                have_logged = true;
                LOG_INFO("using 10-bit RGB surfaces");
            }
        }

        else if (wayl->shm_have_abgr2101010) {
            pixman_fmt = PIXMAN_a2b10g10r10;
            shm_fmt = WL_SHM_FORMAT_ABGR2101010;

            if (!have_logged) {
                have_logged = true;
                LOG_INFO("using 10-bit BGR surfaces");
            }
        }

        else {
            if (!have_logged_10_fallback) {
                have_logged_10_fallback = true;

                LOG_WARN(
                    "10-bit surfaces requested, but compositor does not "
                    "implement ARGB2101010+XRGB2101010, or "
                    "ABGR2101010+XBGR2101010");
            }
        }
    } else  {
        if (!have_logged) {
            have_logged = true;
            LOG_INFO("using 8-bit RGB surfaces");
        }
    }

    struct buffer_chain *chain = xmalloc(sizeof(*chain));
    *chain = (struct buffer_chain){
        .bufs = tll_init(),
        .shm = wayl->shm,
        .pix_instances = pix_instances,
        .scrollable = scrollable,

        .pixman_fmt = pixman_fmt,
        .shm_format = shm_fmt,

        .release_cb = release_cb,
        .cb_data = cb_data,
    };
    return chain;
}

void
shm_chain_free(struct buffer_chain *chain)
{
    if (chain == NULL)
        return;

    shm_purge(chain);

    if (tll_length(chain->bufs) > 0) {
        BUG("chain=%p: there are buffers remaining; "
            "is there a missing call to shm_unref()?", (void *)chain);
    }

    free(chain);
}

enum shm_bit_depth
shm_chain_bit_depth(const struct buffer_chain *chain)
{
    const pixman_format_code_t fmt = chain->pixman_fmt;

    return fmt == PIXMAN_a8r8g8b8
        ? SHM_BITS_8
#if defined(HAVE_PIXMAN_RGBA_16)
        : fmt == PIXMAN_a16b16g16r16
            ? SHM_BITS_16
#endif
        : SHM_BITS_10;
}
