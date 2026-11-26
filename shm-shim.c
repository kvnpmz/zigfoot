/* C shims for the shm port.
 *
 * This file holds only what Zig cannot express: generated wl_shm/wl_buffer
 * request inlines (static inline in wayland-client-protocol.h), the headless
 * wl_shm/wl_buffer sentinels (recognised by those forwarders), the
 * stride_for_format_and_width() wrapper, and the pixman/wl_shm_format macro
 * values. The platform/syscall bodies (memfd_create/SHM_ANON/mkostemp,
 * fallocate()'s FALLOC_FL_PUNCH_HOLE, mmap flags, sealing, _SC_PAGE_SIZE) now
 * live in shm.zig under their original exported C symbol names.
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

/* ── page_size() / shm_shim_page_size(): ported to shm.zig ──────── */

int shm_shim_stride_for_format(pixman_format_code_t fmt, int width) {
    return stride_for_format_and_width(fmt, width);
}

/* The backing-file, punch-hole, mmap and sealing bodies are now exported by
 * shm.zig under the same shm_shim_* symbols; see the platform section there.
 */

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
