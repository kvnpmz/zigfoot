#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <pixman.h>
#include <wayland-client.h>

#include <tllist.h>

#include "config.h"
#include "wayland.h"

struct damage;

struct buffer {
    int width;
    int height;
    int stride;

    void *data;

    struct wl_buffer *wl_buf;
    pixman_image_t **pix;
    size_t pix_instances;

    unsigned age;

    /*
     * First item in the array is used to track frame-to-frame
     * damage. This is used when re-applying damage from the last
     * frame, when the compositor doesn't release buffers immediately
     * (forcing us to double buffer)
     *
     * The remaining items are used to track surface damage. Each
     * worker thread adds its own cell damage to "its" region. When
     * the frame is done, all damage is converted to a single region,
     * which is then used in calls to wl_surface_damage_buffer().
     */
    pixman_region32_t *dirty;
};

/* Internal, but shared with shm.zig and pinned by the ABI probe. */
struct buffer_pool {
    int fd;                /* memfd */
    struct wl_shm_pool *wl_pool;

    void *real_mmapped;    /* Address returned from mmap */
    size_t mmap_size;      /* Size of mmap (>= size) */

    size_t ref_count;
};

/* Shared with shm.zig and pinned by the ABI probe, like struct buffer_pool. */
struct buffer_chain;
struct buffer_private {
    struct buffer public;
    struct buffer_chain *chain;

    size_t ref_count;
    bool busy;                /* Owned by compositor */

    struct buffer_pool *pool;
    off_t offset;             /* Offset into memfd where data begins */
    size_t size;

    bool scrollable;

    void (*release_cb)(struct buffer *buf, void *data);
    void *cb_data;
};

struct buffer_chain {
    tll(struct buffer_private *) bufs;
    struct wl_shm *shm;
    size_t pix_instances;
    bool scrollable;

    pixman_format_code_t pixman_fmt;
    enum wl_shm_format shm_format;

    void (*release_cb)(struct buffer *buf, void *data);
    void *cb_data;
};


/* Macro-valued pixman/wl_shm_format constants. Shared with shm.zig,
 * mirrored in terminal_types.zig and pinned by the ABI probe; the values
 * are supplied by shm-shim.c. */
struct shm_format_constants {
    uint32_t pixman_a8r8g8b8;
    uint32_t pixman_a2r10g10b10;
    uint32_t pixman_a2b10g10r10;
    uint32_t pixman_a16b16g16r16;
    uint32_t wl_argb8888;
    uint32_t wl_argb2101010;
    uint32_t wl_abgr2101010;
    uint32_t wl_abgr16161616;
};

const struct shm_format_constants *shm_shim_format_constants(void);

/* Exported from shm.zig; attached as the wl_buffer release listener by
 * shm-shim.c, and driven directly by the headless harness. */
void buffer_release(void *data, struct wl_buffer *wl_buffer);

/* Generated-protocol forwarders in shm-shim.c (also driven by the harness). */
void shm_shim_wl_buffer_destroy(struct wl_buffer *buffer);
void shm_shim_wl_shm_pool_destroy(struct wl_shm_pool *pool);
struct wl_shm_pool *shm_shim_wl_shm_create_pool(
    struct wl_shm *shm, int fd, int32_t size);
struct wl_buffer *shm_shim_wl_shm_pool_create_buffer(
    struct wl_shm_pool *pool, int32_t offset, int32_t width, int32_t height,
    int32_t stride, uint32_t format);
void shm_shim_wl_buffer_add_listener(struct wl_buffer *buffer, void *data);

void shm_fini(void);

/* TODO: combine into shm_init() */
void shm_set_max_pool_size(off_t max_pool_size);
void shm_set_min_stride_alignment(size_t min_stride_alignment);

struct buffer_chain;
struct buffer_chain *shm_chain_new(
    struct wayland *wayl, bool scrollable, size_t pix_instances,
    enum shm_bit_depth desired_bit_depth,
    void (*release_cb)(struct buffer *buf, void *data), void *cb_data);
void shm_chain_free(struct buffer_chain *chain);

enum shm_bit_depth shm_chain_bit_depth(const struct buffer_chain *chain);
 
/*
 * Returns a single buffer.
 *
 * May returned a cached buffer. If so, the buffer's age indicates how
 * many shm_get_buffer() calls have been made for the same
 * width/height while the buffer was still busy.
 *
 * A newly allocated buffer has an age of 1234.
 */
struct buffer *shm_get_buffer(struct buffer_chain *chain, int width, int height);
/*
 * Returns many buffers, described by 'info', all sharing the same SHM
 * buffer pool.
 *
 * Never returns cached buffers. However, the newly created buffers
 * are all inserted into the regular buffer cache, and are treated
 * just like buffers created by shm_get_buffer().
 *
 * This function is useful when allocating many small buffers, with
 * (roughly) the same life time.
 *
 * Buffers are tagged for immediate purging, and will be destroyed as
 * soon as the compositor releases them.
 */
void shm_get_many(
    struct buffer_chain *chain, size_t count,
    int widths[static count], int heights[static count],
    struct buffer *bufs[static count]);

void shm_did_not_use_buf(struct buffer *buf);

bool shm_can_scroll(const struct buffer *buf);
bool shm_scroll(struct buffer *buf, int rows,
                int top_margin, int top_keep_rows,
                int bottom_margin, int bottom_keep_rows);

void shm_addref(struct buffer *buf);
void shm_unref(struct buffer *buf);

void shm_purge(struct buffer_chain *chain);
