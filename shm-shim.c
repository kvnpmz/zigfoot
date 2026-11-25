/* C shims for the shm port.
 *
 * This file holds only what Zig cannot express: generated wl_shm/wl_buffer
 * request inlines (static inline in wayland-client-protocol.h), the
 * #ifdef'd platform feature tests (memfd_create/SHM_ANON/mkostemp,
 * fallocate()'s FALLOC_FL_PUNCH_HOLE, mmap flags, sealing), sysconf()'s
 * _SC_PAGE_SIZE, and the pixman/wl_shm_format macro values. Everything else
 * lives in shm.zig; the headless wl_shm/wl_buffer sentinels stay here because
 * the inline forwarders have to recognise them.
 */

#include "shm.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <pixman.h>

#include <tllist.h>

#define LOG_MODULE "shm"
#define LOG_ENABLE_DBG 0
#include "debug.h"
#include "log.h"
#include "macros.h"
#include "stride.h"

#if !defined(MAP_UNINITIALIZED)
 #define MAP_UNINITIALIZED 0
#endif

#if !defined(MFD_NOEXEC_SEAL)
 #define MFD_NOEXEC_SEAL 0
#endif

/* Headless harness has no wl_shm connection: chain->shm == NULL selects a
 * pair of never-dereferenced sentinels, so allocation and cache logic can run
 * without a compositor. */
static struct wl_shm_pool *shm_stub_pool;
static struct wl_buffer *shm_stub_buffer;

static const struct wl_buffer_listener buffer_listener = {
    .release = &buffer_release,
};

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

size_t shm_shim_page_size(void) {
    return page_size();
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

/* Zig owns the "already probed" cache; this is the raw #ifdef'd probe. */
bool shm_shim_probe_punch_hole(int fd) {
#if __SIZEOF_POINTER__ == 8 && defined(FALLOC_FL_PUNCH_HOLE)
    bool supported = fallocate(
        fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, 0, 1) == 0;

    if (!supported) {
        LOG_WARN(
            "fallocate(FALLOC_FL_PUNCH_HOLE) not "
            "supported (%s): expect lower performance", strerror(errno));
    }
    return supported;
#else
    (void)fd;
    return false;
#endif
}

bool shm_shim_punch_hole(int fd, off_t ofs, off_t len) {
#if __SIZEOF_POINTER__ == 8 && defined(FALLOC_FL_PUNCH_HOLE)
    return fallocate(
        fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, ofs, len) == 0;
#else
    (void)fd; (void)ofs; (void)len;
    return false;
#endif
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

/* Format/wayland-capability constants: pixman and wl_shm_format values are
 * macros/enums, so they are exported once here rather than hard-coded. */
static const struct shm_format_constants format_constants = {
    .pixman_a8r8g8b8 = PIXMAN_a8r8g8b8,
    .pixman_a2r10g10b10 = PIXMAN_a2r10g10b10,
    .pixman_a2b10g10r10 = PIXMAN_a2b10g10r10,
    .wl_argb8888 = WL_SHM_FORMAT_ARGB8888,
    .wl_argb2101010 = WL_SHM_FORMAT_ARGB2101010,
    .wl_abgr2101010 = WL_SHM_FORMAT_ABGR2101010,
#if defined(HAVE_PIXMAN_RGBA_16)
    .pixman_a16b16g16r16 = PIXMAN_a16b16g16r16,
    .wl_abgr16161616 = WL_SHM_FORMAT_ABGR16161616,
#else
    .pixman_a16b16g16r16 = 0,
    .wl_abgr16161616 = 0,
#endif
};

const struct shm_format_constants *shm_shim_format_constants(void) {
    return &format_constants;
}
