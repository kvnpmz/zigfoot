#include "render.h"

#include <limits.h>
#include <stdint.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <sys/epoll.h>
#include <pthread.h>

#include "macros.h"
#if HAS_INCLUDE(<pthread_np.h>)
 #include <pthread_np.h>
 #define pthread_setname_np(thread, name) (pthread_set_name_np(thread, name), 0)
#elif defined(__NetBSD__)
 #define pthread_setname_np(thread, name) pthread_setname_np(thread, "%s", (void *)name)
#endif

#include <presentation-time.h>
#include <wayland-cursor.h>
#include <xdg-shell.h>
#include <xdg-toplevel-icon-v1.h>

#include <fcft/fcft.h>

#define LOG_MODULE "render"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "box-drawing.h"
#include "char32.h"
#include "config.h"
#include "cursor-shape.h"
#include "grid.h"
#include "ime.h"
#include "input.h"
#include "quirks.h"
#include "search.h"
#include "selection.h"
#include "shm.h"
#include "sixel.h"
#include "srgb.h"
#include "url-mode.h"
#include "util.h"
#include "xmalloc.h"

#define TIME_SCROLL_DAMAGE 0

struct renderer {
    struct fdm *fdm;
    struct wayland *wayl;
};

/* render.zig mirrors this layout (two pointers); keep both sides honest. */
_Static_assert(sizeof(struct renderer) == 2 * sizeof(void *),
               "struct renderer is two pointers");

static struct {
    size_t total;
    size_t zero;  /* commits presented in less than one frame interval */
    size_t one;   /* commits presented in one frame interval */
    size_t two;   /* commits presented in two or more frame intervals */
} presentation_statistics = {0};

void fdm_hook_refresh_pending_terminals(struct fdm *fdm, void *data);

/* render_init()/render_destroy() are in render.zig (D3k1). */

static void DESTRUCTOR
log_presentation_statistics(void)
{
    if (presentation_statistics.total == 0)
        return;

    const size_t total = presentation_statistics.total;
    LOG_INFO("presentation statistics: zero=%f%%, one=%f%%, two=%f%%",
             100. * presentation_statistics.zero / total,
             100. * presentation_statistics.one / total,
             100. * presentation_statistics.two / total);
}

/* Ported to render.zig (D3k1). The listener table stays here: its layout is
 * the generated protocol struct. */
void sync_output(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback,
    struct wl_output *output);
void presented(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback,
    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec,
    uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags);
void discarded(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback);

struct presentation_context {
    struct terminal *term;
    struct timeval input;
    struct timeval commit;
};

/* The context is allocated by render_shim_presentation_ctx_new() because
 * struct timeval is a C type; these accessors are how presented() reads it. */
struct terminal *
render_presentation_ctx_term(void *data)
{
    return ((struct presentation_context *)data)->term;
}

void
render_presentation_ctx_input(void *data, int64_t *sec, int64_t *usec)
{
    const struct presentation_context *ctx = data;
    *sec = ctx->input.tv_sec;
    *usec = ctx->input.tv_usec;
}

void
render_presentation_ctx_commit(void *data, int64_t *sec, int64_t *usec)
{
    const struct presentation_context *ctx = data;
    *sec = ctx->commit.tv_sec;
    *usec = ctx->commit.tv_usec;
}

/* The counters and their DESTRUCTOR stay in C: the exit-time log is a C
 * attribute (macros.h), not something Zig can portably express. */
void
render_shim_presentation_stat_add(unsigned frame_count)
{
    presentation_statistics.total++;

    if (frame_count >= 2)
        presentation_statistics.two++;
    else if (frame_count >= 1)
        presentation_statistics.one++;
    else
        presentation_statistics.zero++;
}

static const struct wp_presentation_feedback_listener presentation_feedback_listener = {
    .sync_output = &sync_output,
    .presented = &presented,
    .discarded = &discarded,
};

/* grid_render() (Zig, D3l2) needs the generated protocol inlines, the two
 * listener tables above/below and struct timeval; these shims are the
 * C-only half. */

void
render_shim_presentation_commit_time(
    const struct wayland *wayl, int64_t *sec, int64_t *nsec)
{
    struct timespec commit_time;
    clock_gettime(wayl->presentation_clock_id, &commit_time);
    *sec = commit_time.tv_sec;
    *nsec = commit_time.tv_nsec;
}

struct wp_presentation_feedback *
render_shim_presentation_feedback_new(
    struct wayland *wayl, struct wl_surface *surf)
{
    return wp_presentation_feedback(wayl->presentation, surf);
}

void
render_shim_presentation_feedback_add(
    struct wp_presentation_feedback *feedback, void *ctx)
{
    wp_presentation_feedback_add_listener(
        feedback, &presentation_feedback_listener, ctx);
}

/* struct presentation_context, with its two struct timeval fields, stays a
 * C type: only the accessors in render_presentation_ctx_*() read it back. */
void *
render_shim_presentation_ctx_new(
    struct terminal *term, int64_t input_sec, int64_t input_usec,
    int64_t commit_sec, int64_t commit_usec)
{
    struct presentation_context *ctx = xmalloc(sizeof(*ctx));
    *ctx = (struct presentation_context){
        .term = term,
        .input = {.tv_sec = input_sec, .tv_usec = input_usec},
        .commit = {.tv_sec = commit_sec, .tv_usec = commit_usec},
    };
    return ctx;
}

/* render_ime_preedit() and its per-seat helper are in render.zig (D3j). */

/* render_worker_thread() and render_wait_for_preapply_damage() are in
 * render.zig (D3l1). */

/* render_scrollback_position() and render_render_timer() are in
 * render.zig (D3k2b). */

static void frame_callback(
    void *data, struct wl_callback *wl_callback, uint32_t callback_data);

static const struct wl_callback_listener frame_listener = {
    .done = &frame_callback,
};

/* grid_render() (render.zig) installs the frame callback through this. */
struct wl_callback *
render_shim_add_frame_callback(struct wl_surface *surf, void *data)
{
    struct wl_callback *callback = wl_surface_frame(surf);
    wl_callback_add_listener(callback, &frame_listener, data);
    return callback;
}


/* force_full_repaint() and reapply_old_damage() are in render.zig (D3k2a). */

/* grid_render() is in render.zig (D3l2). The two protocol listener tables
 * below stay here: they reference generated wayland/presentation structs,
 * and the shims at the top of this block are the only places that need
 * them.
 */

/* render_search_box() is in render.zig (D3k3). */

/* render_urls() is in render.zig (D3k4). */

void
render_update_title(struct terminal *term)
{
    static const size_t max_len = 2048;

    const char *title = term->window_title != NULL ? term->window_title : "foot";
    char *copy = NULL;

    if (strlen(title) > max_len) {
        copy = xstrndup(title, max_len);
        title = copy;
    }

    xdg_toplevel_set_title(term->window->xdg_toplevel, title);
    free(copy);
}

static void
frame_callback(void *data, struct wl_callback *wl_callback, uint32_t callback_data)
{
    struct terminal *term = data;

    xassert(term->window->frame_callback == wl_callback);
    wl_callback_destroy(wl_callback);
    term->window->frame_callback = NULL;

    bool grid = term->render.pending.grid;
    bool csd = term->render.pending.csd;
    bool search = term->is_searching && term->render.pending.search;
    bool urls = urls_mode_is_active(term) > 0 && term->render.pending.urls;

    term->render.pending.grid = false;
    term->render.pending.csd = false;
    term->render.pending.search = false;
    term->render.pending.urls = false;

    struct grid *original_grid = term->grid;
    if (urls_mode_is_active(term)) {
        xassert(term->url.grid_snapshot != NULL);
        term->grid = term->url.grid_snapshot;
    }

    if (csd && term->window->csd_mode == CSD_YES) {
        quirk_weston_csd_on(term);
        render_csd(term);
        quirk_weston_csd_off(term);
    }

    if (search)
        render_search_box(term);

    if (urls)
        render_urls(term);

    if ((grid && !term->delayed_render_timer.is_armed) || (csd | search | urls))
        grid_render(term);

    tll_foreach(term->wl->seats, it) {
        if (it->item.ime_focus == term)
            ime_update_cursor_rect(&it->item);
    }

    term->grid = original_grid;
}

/* tiocswinsz(), delayed_reflow_of_normal_grid(), fdm_tiocswinsz(),
 * send_dimensions_to_client() and set_size_from_grid() are in render.zig
 * (D3l3a). */

/* Move to terminal.c? */
/* render_resize() is in render.zig (D3l3b). */
static void xcursor_callback(
    void *data, struct wl_callback *wl_callback, uint32_t callback_data);
static const struct wl_callback_listener xcursor_listener = {
    .done = &xcursor_callback,
};

bool
render_xcursor_is_valid(const struct seat *seat, const char *cursor)
{
    if (cursor == NULL)
        return false;
    if (seat->pointer.theme == NULL)
        return false;
    return wl_cursor_theme_get_cursor(seat->pointer.theme, cursor) != NULL;
}

static void
render_xcursor_update(struct seat *seat)
{
    /* If called from a frame callback, we may no longer have mouse focus */
    if (!seat->mouse_focus)
        return;

    xassert(seat->pointer.shape != CURSOR_SHAPE_NONE);

    if (seat->pointer.shape == CURSOR_SHAPE_HIDDEN) {
        /* Hide cursor */
        LOG_DBG("hiding cursor using client-side NULL-surface");
        wl_surface_attach(seat->pointer.surface.surf, NULL, 0, 0);
        wl_pointer_set_cursor(
            seat->wl_pointer, seat->pointer.serial, seat->pointer.surface.surf,
            0, 0);
        wl_surface_commit(seat->pointer.surface.surf);
        return;
    }

    const enum cursor_shape shape = seat->pointer.shape;
    const char *const xcursor = seat->pointer.last_custom_xcursor;

    if (seat->pointer.shape_device != NULL) {
        xassert(shape != CURSOR_SHAPE_CUSTOM || xcursor != NULL);

        const enum wp_cursor_shape_device_v1_shape custom_shape =
            (shape == CURSOR_SHAPE_CUSTOM && xcursor != NULL
                ? cursor_string_to_server_shape(
                    xcursor, seat->wayl->shape_manager_version)
                : 0);

        if (shape != CURSOR_SHAPE_CUSTOM || custom_shape != 0) {
            xassert(custom_shape == 0 || shape == CURSOR_SHAPE_CUSTOM);

            const enum wp_cursor_shape_device_v1_shape wp_shape = custom_shape != 0
                ? custom_shape
                : cursor_shape_to_server_shape(shape);

            LOG_DBG("setting %scursor shape using cursor-shape-v1",
                    custom_shape != 0 ? "custom " : "");

            wp_cursor_shape_device_v1_set_shape(
                seat->pointer.shape_device,
                seat->pointer.serial,
                wp_shape);

            return;
        }
    }

    LOG_DBG("setting %scursor shape using a client-side cursor surface",
            seat->pointer.shape == CURSOR_SHAPE_CUSTOM ? "custom " : "");

    if (seat->pointer.cursor == NULL) {
        /*
         * Normally, we never get here with a NULL-cursor, because we
         * only schedule a cursor update when we succeed to load the
         * cursor image.
         *
         * However, it is possible that we did succeed to load an
         * image, and scheduled an update. But, *before* the scheduled
         * update triggers, the user mvoes the pointer, and we try to
         * load a new cursor image. This time failing.
         *
         * In this case, we have a NULL cursor, but the scheduled
         * update is still scheduled.
         */
        return;
    }

    const float scale = seat->pointer.scale;
    struct wl_cursor_image *image = seat->pointer.cursor->images[0];
    struct wl_buffer *buf = wl_cursor_image_get_buffer(image);

    wayl_surface_scale_explicit_width_height(
        seat->mouse_focus->window,
        &seat->pointer.surface, image->width, image->height, scale);

    wl_surface_attach(seat->pointer.surface.surf, buf, 0, 0);

    wl_pointer_set_cursor(
        seat->wl_pointer, seat->pointer.serial,
        seat->pointer.surface.surf,
        image->hotspot_x / scale, image->hotspot_y / scale);

    wl_surface_damage_buffer(
        seat->pointer.surface.surf, 0, 0, INT32_MAX, INT32_MAX);

    xassert(seat->pointer.xcursor_callback == NULL);
    seat->pointer.xcursor_callback = wl_surface_frame(seat->pointer.surface.surf);
    wl_callback_add_listener(seat->pointer.xcursor_callback, &xcursor_listener, seat);

    wl_surface_commit(seat->pointer.surface.surf);
}

static void
xcursor_callback(void *data, struct wl_callback *wl_callback, uint32_t callback_data)
{
    struct seat *seat = data;

    xassert(seat->pointer.xcursor_callback == wl_callback);
    wl_callback_destroy(wl_callback);
    seat->pointer.xcursor_callback = NULL;

    if (seat->pointer.xcursor_pending) {
        render_xcursor_update(seat);
        seat->pointer.xcursor_pending = false;
    }
}

void
fdm_hook_refresh_pending_terminals(struct fdm *fdm, void *data)
{
    struct renderer *renderer = data;
    struct wayland *wayl = renderer->wayl;

    tll_foreach(renderer->wayl->terms, it) {
        struct terminal *term = it->item;

        if (unlikely(term->shutdown.in_progress || !term->window->is_configured))
            continue;

        bool grid = term->render.refresh.grid;
        bool csd = term->render.refresh.csd;
        bool search = term->is_searching && term->render.refresh.search;
        bool urls = urls_mode_is_active(term) && term->render.refresh.urls;

        if (!(grid | csd | search | urls))
            continue;

        if (term->render.app_sync_updates.enabled && !(csd | search | urls))
            continue;

        term->render.refresh.grid = false;
        term->render.refresh.csd = false;
        term->render.refresh.search = false;
        term->render.refresh.urls = false;

        if (term->window->frame_callback == NULL) {
            struct grid *original_grid = term->grid;
            if (urls_mode_is_active(term)) {
                xassert(term->url.grid_snapshot != NULL);
                term->grid = term->url.grid_snapshot;
            }

            if (csd && term->window->csd_mode == CSD_YES) {
                quirk_weston_csd_on(term);
                render_csd(term);
                quirk_weston_csd_off(term);
            }
            if (search)
                render_search_box(term);
            if (urls)
                render_urls(term);
            if (grid | csd | search | urls)
                grid_render(term);

            tll_foreach(term->wl->seats, it) {
                if (it->item.ime_focus == term)
                    ime_update_cursor_rect(&it->item);
            }

            term->grid = original_grid;
        } else {
            /* Tells the frame callback to render again */
            term->render.pending.grid |= grid;
            term->render.pending.csd |= csd;
            term->render.pending.search |= search;
            term->render.pending.urls |= urls;
        }
    }

    tll_foreach(wayl->seats, it) {
        if (it->item.pointer.xcursor_pending) {
            if (it->item.pointer.xcursor_callback == NULL) {
                render_xcursor_update(&it->item);
                it->item.pointer.xcursor_pending = false;
            } else {
                /* Frame callback will call render_xcursor_update() */
            }
        }
    }
}

bool
render_xcursor_set(struct seat *seat, struct terminal *term,
                   enum cursor_shape shape)
{
    if (seat->pointer.theme == NULL && seat->pointer.shape_device == NULL)
        return false;

    if (seat->mouse_focus == NULL) {
        seat->pointer.shape = CURSOR_SHAPE_NONE;
        return true;
    }

    if (seat->mouse_focus != term) {
        /* This terminal doesn't have mouse focus */
        return true;
    }

    if (seat->pointer.shape == shape &&
        !(shape == CURSOR_SHAPE_CUSTOM &&
          !streq(seat->pointer.last_custom_xcursor,
                 term->mouse_user_cursor)))
    {
        return true;
    }

    if (shape == CURSOR_SHAPE_HIDDEN) {
        seat->pointer.cursor = NULL;
        free(seat->pointer.last_custom_xcursor);
        seat->pointer.last_custom_xcursor = NULL;
    }

    else if (seat->pointer.shape_device == NULL) {
        const char *const custom_xcursors[] = {term->mouse_user_cursor, NULL};
        const char *const *xcursors = shape == CURSOR_SHAPE_CUSTOM
            ? custom_xcursors
            : cursor_shape_to_string(shape);

        xassert(xcursors[0] != NULL);

        seat->pointer.cursor = NULL;

        for (size_t i = 0; xcursors[i] != NULL; i++) {
            seat->pointer.cursor =
                wl_cursor_theme_get_cursor(seat->pointer.theme, xcursors[i]);

            if (seat->pointer.cursor != NULL) {
                LOG_DBG("loaded xcursor %s", xcursors[i]);
                break;
            }
        }

        if (seat->pointer.cursor == NULL) {
            LOG_ERR(
                "failed to load xcursor pointer '%s', and all of its fallbacks",
                xcursors[0]);
            return false;
        }
    } else {
        /* Server-side cursors - no need to load anything */
    }

    if (shape == CURSOR_SHAPE_CUSTOM) {
        free(seat->pointer.last_custom_xcursor);
        seat->pointer.last_custom_xcursor =
            xstrdup(term->mouse_user_cursor);
    }

    /* FDM hook takes care of actual rendering */
    seat->pointer.shape = shape;
    seat->pointer.xcursor_pending = true;
    return true;
}

void
render_buffer_release_callback(struct buffer *buf, void *data)
{
    /*
     * Called from shm.c when a buffer is released
     *
     * We use it to pre-apply last-frame's damage to it, when we're
     * forced to double buffer (compositor doesn't release buffers
     * immediately).
     *
     * The timeline is thus:
     *   1. We render and push a new frame
     *   2. Some (hopefully short) time after that, the compositor releases the previous buffer
     *   3. We're called, and kick off the thread that copies the changes from (1) to the just freed buffer
     *   4. Time passes....
     *   5. The compositor calls our frame callback, signalling to us that it's time to start rendering the next frame
     *   6. Hopefully, our thread is already done with copying the changes, otherwise we stall, waiting for it
     *   7. We render the frame as if the compositor does immediate releases.
     *
     * What's the gain? Reduced latency, by applying the previous
     * frame's damage as soon as possible, we shorten the time it
     * takes to render the frame after the frame callback.
     *
     * This means the compositor can, in theory, push the frame
     * callback closer to the vblank deadline, and thus reduce input
     * latency. Not all compositors (most, in fact?) don't adapt like
     * this, unfortunately. But some allows the user to manually
     * configure the deadline.
     */
    struct terminal *term = data;

    if (likely(buf->age != 1))
        return;

    if (likely(!term->render.preapply_last_frame_damage))
        return;

    if (term->render.last_buf == NULL)
        return;

    if (term->render.last_buf->age != 0)
        return;

    if (buf->width != term->render.last_buf->width)
        return;

    if (buf->height != term->render.last_buf->height)
        return;

    xassert(term->render.workers.count > 0);
    xassert(term->render.last_buf != NULL);

    xassert(term->render.last_buf->age == 0);
    xassert(term->render.last_buf != buf);

    mtx_lock(&term->render.workers.preapplied_damage.lock);
    if (term->render.workers.preapplied_damage.buf != NULL) {
        mtx_unlock(&term->render.workers.preapplied_damage.lock);
        return;
    }

    xassert(term->render.workers.preapplied_damage.buf == NULL);
    term->render.workers.preapplied_damage.buf = buf;
    term->render.workers.preapplied_damage.start = (struct timespec){0};
    term->render.workers.preapplied_damage.stop = (struct timespec){0};
    mtx_unlock(&term->render.workers.preapplied_damage.lock);

    mtx_lock(&term->render.workers.lock);
    sem_post(&term->render.workers.start);
    xassert(tll_length(term->render.workers.queue) == 0);
    tll_push_back(term->render.workers.queue, -3);
    mtx_unlock(&term->render.workers.lock);
}
