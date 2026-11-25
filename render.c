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

/* TODO(shim-removal): the context is allocated by grid_render(), which is
 * still C. These accessors go away with grid_render() (D3l2). */
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

/* render_ime_preedit() and its per-seat helper are in render.zig (D3j). */

int
render_worker_thread(void *_ctx)
{
    struct render_worker_context *ctx = _ctx;
    struct terminal *term = ctx->term;
    const int my_id = ctx->my_id;
    free(ctx);

    sigset_t mask;
    sigfillset(&mask);
    pthread_sigmask(SIG_SETMASK, &mask, NULL);

    char proc_title[16];
    snprintf(proc_title, sizeof(proc_title), "foot:render:%d", my_id);

    if (pthread_setname_np(pthread_self(), proc_title) < 0)
        LOG_ERRNO("render worker %d: failed to set process title", my_id);

    sem_t *start = &term->render.workers.start;
    sem_t *done = &term->render.workers.done;
    mtx_t *lock = &term->render.workers.lock;

    while (true) {
        sem_wait(start);

        struct buffer *buf = term->render.workers.buf;

        bool frame_done = false;

        /* Translate offset-relative cursor row to view-relative */
        struct coord cursor = {-1, -1};
        if (!term->hide_cursor) {
            cursor = term->grid->cursor.point;
            cursor.row += term->grid->offset;
            cursor.row -= term->grid->view;
            cursor.row &= term->grid->num_rows - 1;
        }

        while (!frame_done) {
            mtx_lock(lock);
            xassert(tll_length(term->render.workers.queue) > 0);

            int row_no = tll_pop_front(term->render.workers.queue);
            mtx_unlock(lock);

            switch (row_no) {
            default: {
                struct row *row = grid_row_in_view(term->grid, row_no);
                int cursor_col = cursor.row == row_no ? cursor.col : -1;

                render_row(term, buf->pix[my_id], &buf->dirty[my_id],
                           row, row_no, cursor_col);
                break;
            }

            case -1:
                frame_done = true;
                sem_post(done);
                break;

            case -2:
                return 0;

            case -3: {
                if (term->conf->tweak.render_timer != RENDER_TIMER_NONE)
                    clock_gettime(CLOCK_MONOTONIC, &term->render.workers.preapplied_damage.start);

                mtx_lock(&term->render.workers.preapplied_damage.lock);
                buf = term->render.workers.preapplied_damage.buf;
                xassert(buf != NULL);

                if (likely(term->render.last_buf != NULL)) {
                    mtx_unlock(&term->render.workers.preapplied_damage.lock);

                    pixman_region32_t dmg;
                    pixman_region32_init(&dmg);

                    if (buf->age == 0)
                        ; /* No need to do anything */
                    else if (buf->age == 1)
                        pixman_region32_copy(&dmg,
                                             &term->render.last_buf->dirty[0]);
                    else
                        pixman_region32_init_rect(&dmg, 0, 0, buf->width,
                                                  buf->height);

                    pixman_image_set_clip_region32(buf->pix[my_id], &dmg);
                    pixman_image_composite32(PIXMAN_OP_SRC,
                                             term->render.last_buf->pix[my_id],
                                             NULL, buf->pix[my_id], 0, 0, 0, 0, 0,
                                             0, buf->width, buf->height);

                    pixman_region32_fini(&dmg);

                    buf->age = 0;
                    shm_unref(term->render.last_buf);
                    shm_addref(buf);
                    term->render.last_buf = buf;

                    mtx_lock(&term->render.workers.preapplied_damage.lock);
                }

                term->render.workers.preapplied_damage.buf = NULL;
                cnd_signal(&term->render.workers.preapplied_damage.cond);
                mtx_unlock(&term->render.workers.preapplied_damage.lock);

                if (term->conf->tweak.render_timer != RENDER_TIMER_NONE)
                    clock_gettime(CLOCK_MONOTONIC, &term->render.workers.preapplied_damage.stop);

                frame_done = true;
                break;
            }
            }
        }
    };

    return -1;
}

void
render_wait_for_preapply_damage(struct terminal *term)
{
    if (!term->render.preapply_last_frame_damage)
        return;
    if (term->render.workers.preapplied_damage.buf == NULL)
        return;

    mtx_lock(&term->render.workers.preapplied_damage.lock);
    while (term->render.workers.preapplied_damage.buf != NULL) {
        cnd_wait(&term->render.workers.preapplied_damage.cond,
                 &term->render.workers.preapplied_damage.lock);
    }
    mtx_unlock(&term->render.workers.preapplied_damage.lock);
}

/* render_scrollback_position() and render_render_timer() are in
 * render.zig (D3k2b). */

static void frame_callback(
    void *data, struct wl_callback *wl_callback, uint32_t callback_data);

static const struct wl_callback_listener frame_listener = {
    .done = &frame_callback,
};

/* force_full_repaint() and reapply_old_damage() are in render.zig (D3k2a). */

static void
grid_render(struct terminal *term)
{
    if (term->shutdown.in_progress)
        return;

    struct timespec start_time;
    struct timespec start_wait_preapply = {0}, stop_wait_preapply = {0};
    struct timespec start_double_buffering = {0}, stop_double_buffering = {0};

    /* Might be a thread doing pre-applied damage */
    if (unlikely(term->render.preapply_last_frame_damage &&
                 term->render.workers.preapplied_damage.buf != NULL))
    {
        clock_gettime(CLOCK_MONOTONIC, &start_wait_preapply);
        render_wait_for_preapply_damage(term);
        clock_gettime(CLOCK_MONOTONIC, &stop_wait_preapply);
    }

    if (term->conf->tweak.render_timer != RENDER_TIMER_NONE)
        clock_gettime(CLOCK_MONOTONIC, &start_time);

    xassert(term->width > 0);
    xassert(term->height > 0);

    struct buffer_chain *chain = term->render.chains.grid;
    struct buffer *buf = shm_get_buffer(chain, term->width, term->height);

    /* Dirty old and current cursor cell, to ensure they're repainted */
    dirty_old_cursor(term);
    dirty_cursor(term);

    LOG_DBG("buffer age: %u (%p)", buf->age, (void *)buf);

    if (term->render.last_buf == NULL ||
        term->render.last_buf->width != buf->width ||
        term->render.last_buf->height != buf->height ||
        term->render.margins)
    {
        force_full_repaint(term, buf);
    }

    else if (buf->age > 0) {
        LOG_DBG("buffer age: %u (%p)", buf->age, (void *)buf);

        xassert(term->render.last_buf != NULL);
        xassert(term->render.last_buf != buf);
        xassert(term->render.last_buf->width == buf->width);
        xassert(term->render.last_buf->height == buf->height);

        if (++term->render.frames_since_last_immediate_release > 10) {
            static bool have_warned = false;

            if (!term->render.preapply_last_frame_damage &&
                term->conf->tweak.preapply_damage &&
                term->render.workers.count > 0)
            {
                LOG_INFO("enabling pre-applied frame damage");
                term->render.preapply_last_frame_damage = true;
            } else if (!have_warned && !term->render.preapply_last_frame_damage) {
                LOG_WARN("compositor is not releasing buffers immediately; "
                         "expect lower rendering performance");
                have_warned = true;
            }
        }

        clock_gettime(CLOCK_MONOTONIC, &start_double_buffering);
        reapply_old_damage(term, buf, term->render.last_buf);
        clock_gettime(CLOCK_MONOTONIC, &stop_double_buffering);
    } else if (!term->render.preapply_last_frame_damage) {
        term->render.frames_since_last_immediate_release = 0;
    }

    if (term->render.last_buf != NULL) {
        shm_unref(term->render.last_buf);
        term->render.last_buf = NULL;
    }

    term->render.last_buf = buf;
    shm_addref(buf);
    buf->age = 0;

    tll_foreach(term->grid->scroll_damage, it) {
        switch (it->item.type) {
        case DAMAGE_SCROLL:
            if (term->grid->view == term->grid->offset)
                grid_render_scroll(term, buf, &it->item);
            break;

        case DAMAGE_SCROLL_REVERSE:
            if (term->grid->view == term->grid->offset)
                grid_render_scroll_reverse(term, buf, &it->item);
            break;

        case DAMAGE_SCROLL_IN_VIEW:
            grid_render_scroll(term, buf, &it->item);
            break;

        case DAMAGE_SCROLL_REVERSE_IN_VIEW:
            grid_render_scroll_reverse(term, buf, &it->item);
            break;
        }

        tll_remove(term->grid->scroll_damage, it);
    }

    /*
     * Ensure selected cells have their 'selected' bit set. This is
     * normally "automatically" true - the bit is set when the
     * selection is made.
     *
     * However, if the cell is updated (printed to) while the
     * selection is active, the 'selected' bit is cleared. Checking
     * for this and re-setting the bit in term_print() is too
     * expensive performance wise.
     *
     * Instead, we synchronize the selection bits here and now. This
     * makes the performance impact linear to the number of selected
     * cells rather than to the number of updated cells.
     *
     * (note that selection_dirty_cells() will not set the dirty flag
     * on cells where the 'selected' bit is already set)
     */
    selection_dirty_cells(term);

    /* Translate offset-relative row to view-relative, unless cursor
     * is hidden, then we just set it to -1 */
    struct coord cursor = {-1, -1};
    if (!term->hide_cursor) {
        cursor = term->grid->cursor.point;
        cursor.row += term->grid->offset;
        cursor.row -= term->grid->view;
        cursor.row &= term->grid->num_rows - 1;
    }

    if (term->conf->tweak.overflowing_glyphs) {
        /*
         * Pre-pass to dirty cells affected by overflowing glyphs.
         *
         * Given any two pair of cells where the first cell is
         * overflowing into the second, *both* cells must be
         * re-rendered if any one of them is dirty.
         *
         * Thus, given a string of overflowing glyphs, with a single
         * dirty cell in the middle, we need to re-render the entire
         * string.
         */
        for (int r = 0; r < term->rows; r++) {
            struct row *row = grid_row_in_view(term->grid, r);

            if (!row->dirty)
                continue;

            /* Loop row from left to right, looking for dirty cells */
            for (struct cell *cell = &row->cells[0];
                 cell < &row->cells[term->cols];
                 cell++)
            {
                if (cell->attrs.clean)
                    continue;

                /*
                 * Cell is dirty, go back and dirty previous cells, if
                 * they are overflowing.
                 *
                 * As soon as we see a non-overflowing cell we can
                 * stop, since it isn't affecting the string of
                 * overflowing glyphs that follows it.
                 *
                 * As soon as we see a dirty cell, we can stop, since
                 * that means we've already handled it (remember the
                 * outer loop goes from left to right).
                 */
                for (struct cell *c = cell - 1; c >= &row->cells[0]; c--) {
                    if (c->attrs.confined)
                        break;
                    if (!c->attrs.clean)
                        break;
                    c->attrs.clean = false;
                }

                /*
                 * Now move forward, dirtying all cells until we hit a
                 * non-overflowing cell.
                 *
                 * Note that the first non-overflowing cell must be
                 * re-rendered as well, but any cell *after* that is
                 * unaffected by the string of overflowing glyphs
                 * we're dealing with right now.
                 *
                 * For performance, this iterates the *outer* loop's
                 * cell pointer - no point in re-checking all these
                 * glyphs again, in the outer loop.
                 */
                for (; cell < &row->cells[term->cols]; cell++) {
                    cell->attrs.clean = false;
                    if (cell->attrs.confined)
                        break;
                }
            }
        }
    }

#if defined(_DEBUG)
    for (int r = 0; r < term->rows; r++) {
        const struct row *row = grid_row_in_view(term->grid, r);

        if (row->dirty) {
            bool all_clean = true;
            for (int c = 0; c < term->cols; c++) {
                if (!row->cells[c].attrs.clean) {
                    all_clean = false;
                    break;
                }
            }
            if (all_clean)
                BUG("row #%d is dirty, but all cells are marked as clean", r);
        } else {
            for (int c = 0; c < term->cols; c++) {
                if (!row->cells[c].attrs.clean)
                    BUG("row #%d is clean, but cell #%d is dirty", r, c);
            }
        }
    }
#endif

    pixman_region32_t damage;
    pixman_region32_init(&damage);

    render_sixel_images(term, buf->pix[0], &damage, &cursor);

    if (term->render.workers.count > 0) {
        mtx_lock(&term->render.workers.lock);
        term->render.workers.buf = buf;
        for (size_t i = 0; i < term->render.workers.count; i++)
            sem_post(&term->render.workers.start);

        xassert(tll_length(term->render.workers.queue) == 0);
    }

    for (int r = 0; r < term->rows; r++) {
        struct row *row = grid_row_in_view(term->grid, r);

        if (!row->dirty)
            continue;

        row->dirty = false;

        if (term->render.workers.count > 0)
            tll_push_back(term->render.workers.queue, r);

        else {
            /* TODO: damage region */
            int cursor_col = cursor.row == r ? cursor.col : -1;
            render_row(term, buf->pix[0], &damage, row, r, cursor_col);
        }
    }

    /* Signal workers the frame is done */
    if (term->render.workers.count > 0) {
        for (size_t i = 0; i < term->render.workers.count; i++)
            tll_push_back(term->render.workers.queue, -1);
        mtx_unlock(&term->render.workers.lock);

        for (size_t i = 0; i < term->render.workers.count; i++)
            sem_wait(&term->render.workers.done);
        term->render.workers.buf = NULL;
    }

    for (size_t i = 0; i < term->render.workers.count; i++)
        pixman_region32_union(&damage, &damage, &buf->dirty[i + 1]);

    pixman_region32_union(&buf->dirty[0], &buf->dirty[0], &damage);

    {
        int box_count = 0;
        pixman_box32_t *boxes = pixman_region32_rectangles(&damage, &box_count);

        for (size_t i = 0; i < box_count; i++) {
            wl_surface_damage_buffer(
                term->window->surface.surf,
                boxes[i].x1, boxes[i].y1,
                boxes[i].x2 - boxes[i].x1, boxes[i].y2 - boxes[i].y1);
        }
    }

    pixman_region32_fini(&damage);

    render_overlay(term);
    render_ime_preedit(term, buf);
    render_scrollback_position(term);

    if (term->conf->tweak.render_timer != RENDER_TIMER_NONE) {
        struct timespec end_time;
        clock_gettime(CLOCK_MONOTONIC, &end_time);

        struct timespec wait_time;
        timespec_sub(&stop_wait_preapply, &start_wait_preapply, &wait_time);

        struct timespec render_time;
        timespec_sub(&end_time, &start_time, &render_time);

        struct timespec double_buffering_time;
        timespec_sub(&stop_double_buffering, &start_double_buffering, &double_buffering_time);

        struct timespec preapply_damage;
        timespec_sub(&term->render.workers.preapplied_damage.stop,
                     &term->render.workers.preapplied_damage.start,
                     &preapply_damage);

        struct timespec total_render_time;
        timespec_add(&render_time, &double_buffering_time, &total_render_time);
        timespec_add(&wait_time, &total_render_time, &total_render_time);

        switch (term->conf->tweak.render_timer) {
        case RENDER_TIMER_LOG:
        case RENDER_TIMER_BOTH:
            LOG_INFO(
                "frame rendered in %lds %9ldns "
                "(%lds %9ldns wait, %lds %9ldns rendering, %lds %9ldns double buffering) not included: %lds %ldns pre-apply damage",
                (long)total_render_time.tv_sec,
                total_render_time.tv_nsec,
                (long)wait_time.tv_sec,
                wait_time.tv_nsec,
                (long)render_time.tv_sec,
                render_time.tv_nsec,
                (long)double_buffering_time.tv_sec,
                double_buffering_time.tv_nsec,
                (long)preapply_damage.tv_sec,
                preapply_damage.tv_nsec);
            break;

        case RENDER_TIMER_OSD:
        case RENDER_TIMER_NONE:
            break;
        }

        switch (term->conf->tweak.render_timer) {
        case RENDER_TIMER_OSD:
        case RENDER_TIMER_BOTH:
            render_render_timer(term, total_render_time);
            break;

        case RENDER_TIMER_LOG:
        case RENDER_TIMER_NONE:
            break;
        }
    }

    xassert(term->grid->offset >= 0 && term->grid->offset < term->grid->num_rows);
    xassert(term->grid->view >= 0 && term->grid->view < term->grid->num_rows);

    xassert(term->window->frame_callback == NULL);
    term->window->frame_callback = wl_surface_frame(term->window->surface.surf);
    wl_callback_add_listener(term->window->frame_callback, &frame_listener, term);

    wayl_win_scale(term->window, buf);

    if (term->wl->presentation != NULL && term->conf->presentation_timings) {
        struct timespec commit_time;
        clock_gettime(term->wl->presentation_clock_id, &commit_time);

        struct wp_presentation_feedback *feedback = wp_presentation_feedback(
            term->wl->presentation, term->window->surface.surf);

        if (feedback == NULL) {
            LOG_WARN("failed to create presentation feedback");
        } else {
            struct presentation_context *ctx = xmalloc(sizeof(*ctx));
            *ctx = (struct presentation_context){
                .term = term,
                .input.tv_sec = term->render.input_time.tv_sec,
                .input.tv_usec = term->render.input_time.tv_nsec / 1000,
                .commit.tv_sec = commit_time.tv_sec,
                .commit.tv_usec = commit_time.tv_nsec / 1000,
            };

            wp_presentation_feedback_add_listener(
                feedback, &presentation_feedback_listener, ctx);

            term->render.input_time.tv_sec = 0;
            term->render.input_time.tv_nsec = 0;
        }
    }

    if (term->conf->tweak.damage_whole_window) {
        wl_surface_damage_buffer(
            term->window->surface.surf, 0, 0, INT32_MAX, INT32_MAX);
    }

    wl_surface_attach(term->window->surface.surf, buf->wl_buf, 0, 0);
    wl_surface_commit(term->window->surface.surf);
}

static void
render_search_box(struct terminal *term)
{
    xassert(term->window->search.sub != NULL);

    /*
     * We treat the search box pretty much like a row of cells. That
     * is, a glyph is either 1 or 2 (or more) "cells" wide.
     *
     * The search 'length', and 'cursor' (position) is in
     * *characters*, not cells. This means we need to translate from
     * character count to cell count when calculating the length of
     * the search box, where in the search string we should start
     * rendering etc.
     */

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    /* TODO: do we want to/need to handle multi-seat? */
    struct seat *ime_seat = NULL;
    tll_foreach(term->wl->seats, it) {
        if (it->item.kbd_focus == term) {
            ime_seat = &it->item;
            break;
        }
    }

    size_t text_len = term->search.len;
    if (ime_seat != NULL && ime_seat->ime.preedit.text != NULL)
        text_len += c32len(ime_seat->ime.preedit.text);

    char32_t *text = xmalloc((text_len + 1) *  sizeof(char32_t));
    text[0] = U'\0';

    /* Copy everything up to the cursor */
    c32ncpy(text, term->search.buf, term->search.cursor);
    text[term->search.cursor] = U'\0';

    /* Insert pre-edit text at cursor */
    if (ime_seat != NULL && ime_seat->ime.preedit.text != NULL)
        c32cat(text, ime_seat->ime.preedit.text);

    /* And finally everything after the cursor */
    c32ncat(text, &term->search.buf[term->search.cursor],
            term->search.len - term->search.cursor);
#else
    const char32_t *text = term->search.buf;
    const size_t text_len = term->search.len;
#endif

    /* Calculate the width of each character */
    int widths[text_len + 1];
    for (size_t i = 0; i < text_len; i++)
        widths[i] = max(0, c32width(text[i]));
    widths[text_len] = 0;

    const size_t total_cells = c32swidth(text, text_len);
    const size_t wanted_visible_cells = max(20, total_cells);

    const float scale = term->scale;
    xassert(scale >= 1.);
    const size_t margin = (size_t)roundf(3 * scale);

    size_t width = term->width - 2 * margin;
    size_t height = min(
        term->height - 2 * margin,
        margin + 1 * term->cell_height + margin);

    width = roundf(scale * ceilf((term->width - 2 * margin) / scale));
    height = roundf(scale * ceilf(height / scale));

    size_t visible_width = min(
        term->width - 2 * margin,
        margin + wanted_visible_cells * term->cell_width + margin);

    const size_t visible_cells = (visible_width - 2 * margin) / term->cell_width;
    size_t glyph_offset = term->render.search_glyph_offset;

    struct buffer_chain *chain = term->render.chains.search;
    struct buffer *buf = shm_get_buffer(chain, width, height);

    pixman_region32_t clip;
    pixman_region32_init_rect(&clip, 0, 0, width, height);
    pixman_image_set_clip_region32(buf->pix[0], &clip);
    pixman_region32_fini(&clip);

#define WINDOW_X(x) (margin + x)
#define WINDOW_Y(y) (term->height - margin - height + y)

    const bool is_match = term->search.match_len == text_len;
    const bool custom_colors = is_match
        ? term->conf->colors_dark.use_custom.search_box_match
        : term->conf->colors_dark.use_custom.search_box_no_match;

    /* Background - yellow on empty/match, red on mismatch (default) */
    const bool gamma_correct = wayl_do_linear_blending(term->wl, term->conf);
    const pixman_color_t color = color_hex_to_pixman(
        is_match
        ? (custom_colors
           ? term->conf->colors_dark.search_box.match.bg
           : term->colors.table[3])
        : (custom_colors
           ? term->conf->colors_dark.search_box.no_match.bg
           : term->colors.table[1]),
        gamma_correct);

    pixman_image_fill_rectangles(
        PIXMAN_OP_SRC, buf->pix[0], &color,
        1, &(pixman_rectangle16_t){width - visible_width, 0, visible_width, height});

    pixman_color_t transparent = color_hex_to_pixman_with_alpha(0, 0, gamma_correct);
    pixman_image_fill_rectangles(
        PIXMAN_OP_SRC, buf->pix[0], &transparent,
        1, &(pixman_rectangle16_t){0, 0, width - visible_width, height});

    struct fcft_font *font = term->fonts[0];
    const int x_left = width - visible_width + margin;
    const int x_ofs = term->font_x_ofs;
    int x = x_left;
    int y = margin;

    pixman_color_t fg = color_hex_to_pixman(
        custom_colors
        ? (is_match
           ? term->conf->colors_dark.search_box.match.fg
           : term->conf->colors_dark.search_box.no_match.fg)
        : term->colors.table[0],
        gamma_correct);

    /* Move offset we start rendering at, to ensure the cursor is visible */
    for (size_t i = 0, cell_idx = 0; i <= term->search.cursor; cell_idx += widths[i], i++) {
        if (i != term->search.cursor)
            continue;

#if (FOOT_IME_ENABLED) && FOOT_IME_ENABLED
        if (ime_seat != NULL && ime_seat->ime.preedit.cells != NULL) {
            if (ime_seat->ime.preedit.cursor.start == ime_seat->ime.preedit.cursor.end) {
                /* All IME's I've seen so far keeps the cursor at
                 * index 0, so ensure the *end* of the pre-edit string
                 * is visible */
                cell_idx += ime_seat->ime.preedit.count;
            } else {
                /* Try to predict in which direction we'll shift the text */
                if (cell_idx + ime_seat->ime.preedit.cursor.start > glyph_offset)
                    cell_idx += ime_seat->ime.preedit.cursor.end;
                else
                    cell_idx += ime_seat->ime.preedit.cursor.start;
            }
        }
#endif

        if (cell_idx < glyph_offset) {
            /* Shift to the *left*, making *this* character the
             * *first* visible one */
            term->render.search_glyph_offset = glyph_offset = cell_idx;
        }

        else if (cell_idx > glyph_offset + visible_cells) {
            /* Shift to the *right*, making *this* character the
             * *last* visible one */
            term->render.search_glyph_offset = glyph_offset =
                cell_idx - min(cell_idx, visible_cells);
        }

        /* Adjust offset if there is free space available */
        if (total_cells - glyph_offset < visible_cells) {
            term->render.search_glyph_offset = glyph_offset =
                total_cells - min(total_cells, visible_cells);
        }

        break;
    }

    /* Ensure offset is at a character boundary */
    for (size_t i = 0, cell_idx = 0; i <= text_len; cell_idx += widths[i], i++) {
        if (cell_idx >= glyph_offset) {
            term->render.search_glyph_offset = glyph_offset = cell_idx;
            break;
        }
    }

    /*
     * Render the search string, starting at 'glyph_offset'. Note that
     * glyph_offset is in cells, not characters
     */
    for (size_t i = 0,
             cell_idx = 0,
             width = widths[i],
             next_cell_idx = width;
         i < text_len;
         i++,
             cell_idx = next_cell_idx,
             width = widths[i],
             next_cell_idx += width)
    {
    /* Convert subsurface coordinates to window coordinates*/
        /* Render cursor */
        if (i == term->search.cursor) {
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
            bool have_preedit =
                ime_seat != NULL && ime_seat->ime.preedit.cells != NULL;
            bool hidden =
                ime_seat != NULL && ime_seat->ime.preedit.cursor.hidden;

            if (have_preedit && !hidden) {
                /* Cursor may be outside the visible area:
                 * cell_idx-glyph_offset can be negative */
                int cells_left = visible_cells - max(
                    (ssize_t)(cell_idx - glyph_offset), 0);

                /* If cursor is outside the visible area, we need to
                 * adjust our rectangle's position */
                int start = ime_seat->ime.preedit.cursor.start
                    + min((ssize_t)(cell_idx - glyph_offset), 0);
                int end = ime_seat->ime.preedit.cursor.end
                    + min((ssize_t)(cell_idx - glyph_offset), 0);

                if (start == end) {
                    int count = min(ime_seat->ime.preedit.count, cells_left);

                    /* Underline the entire (visible part of) pre-edit text */
                    draw_underline(term, buf->pix[0], font, &fg, x, y, count);

                    /* Bar-styled cursor, if in the visible area */
                    if (start >= 0 && start <= visible_cells) {
                        draw_beam_cursor(
                            term, buf->pix[0], font, &fg,
                            x + start * term->cell_width, y);
                    }

                    term_ime_set_cursor_rect(term,
                        WINDOW_X(x + start * term->cell_width), WINDOW_Y(y),
                        1, term->cell_height);
                } else {
                    /* Underline everything before and after the cursor */
                    int count1 = min(start, cells_left);
                    int count2 = max(
                        min(ime_seat->ime.preedit.count - ime_seat->ime.preedit.cursor.end,
                            cells_left - end),
                        0);
                    draw_underline(term, buf->pix[0], font, &fg, x, y, count1);
                    draw_underline(term, buf->pix[0], font, &fg, x + end * term->cell_width, y, count2);

                    /* TODO: how do we handle a partially hidden rectangle? */
                    if (start >= 0 && end <= visible_cells) {
                        draw_hollow_block(
                            term, buf->pix[0], &fg, x + start * term->cell_width, y, end - start);
                    }
                    term_ime_set_cursor_rect(term,
                        WINDOW_X(x + start * term->cell_width), WINDOW_Y(y),
                        term->cell_width * (end - start), term->cell_height);
                }
            } else if (!have_preedit)
#endif
            {
                /* Cursor *should* be in the visible area */
                xassert(cell_idx >= glyph_offset);
                xassert(cell_idx <= glyph_offset + visible_cells);
                draw_beam_cursor(term, buf->pix[0], font, &fg, x, y);
                term_ime_set_cursor_rect(
                    term, WINDOW_X(x), WINDOW_Y(y), 1, term->cell_height);
            }
        }

        if (next_cell_idx >= glyph_offset && next_cell_idx - glyph_offset > visible_cells) {
            /* We're now beyond the visible area - nothing more to render */
            break;
        }

        if (cell_idx < glyph_offset) {
            /* We haven't yet reached the visible part of the string */
            cell_idx = next_cell_idx;
            continue;
        }

        const struct fcft_glyph *glyph = fcft_rasterize_char_utf32(
            font, text[i], term->font_subpixel);

        if (glyph == NULL) {
            cell_idx = next_cell_idx;
            continue;
        }

        if (unlikely(glyph->is_color_glyph)) {
            pixman_image_composite32(
                PIXMAN_OP_OVER, glyph->pix, NULL, buf->pix[0], 0, 0, 0, 0,
                x + x_ofs + glyph->x, y + term->font_baseline - glyph->y,
                glyph->width, glyph->height);
        } else {
            int combining_ofs = width == 0
                ? (glyph->x < 0
                   ? width * term->cell_width
                   : (width - 1) * term->cell_width)
                : 0;  /* Not a zero-width character - no additional offset */
            pixman_image_t *src = pixman_image_create_solid_fill(&fg);
            pixman_image_composite32(
                PIXMAN_OP_OVER, src, glyph->pix, buf->pix[0], 0, 0, 0, 0,
                x + x_ofs + combining_ofs + glyph->x,
                y + term->font_baseline - glyph->y,
            glyph->width, glyph->height);
            pixman_image_unref(src);
        }

        x += width * term->cell_width;
        cell_idx = next_cell_idx;
    }

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
        if (ime_seat != NULL && ime_seat->ime.preedit.cells != NULL)
            /* Already rendered */;
        else
#endif
        if (term->search.cursor >= term->search.len) {
            draw_beam_cursor(term, buf->pix[0], font, &fg, x, y);
            term_ime_set_cursor_rect(
                term, WINDOW_X(x), WINDOW_Y(y), 1, term->cell_height);
        }

    quirk_weston_subsurface_desync_on(term->window->search.sub);

    /* TODO: this is only necessary on a window resize */
    wl_subsurface_set_position(
        term->window->search.sub,
        roundf(margin / scale),
        roundf(max(0, (int32_t)term->height - height - margin) / scale));

    wayl_surface_scale(term->window, &term->window->search.surface, buf, scale);
    wl_surface_attach(term->window->search.surface.surf, buf->wl_buf, 0, 0);
    wl_surface_damage_buffer(term->window->search.surface.surf, 0, 0, width, height);

    struct wl_region *region = wl_compositor_create_region(term->wl->compositor);
    if (region != NULL) {
        wl_region_add(region, width - visible_width, 0, visible_width, height);
        wl_surface_set_opaque_region(term->window->search.surface.surf, region);
        wl_region_destroy(region);
    }

    wl_surface_commit(term->window->search.surface.surf);
    quirk_weston_subsurface_desync_off(term->window->search.sub);

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    free(text);
#endif
#undef WINDOW_X
#undef WINDOW_Y
}

static void
render_urls(struct terminal *term)
{
    struct wl_window *win = term->window;
    xassert(tll_length(win->urls) > 0);

    const float scale = term->scale;
    const int x_margin = (int)roundf(2 * scale);
    const int y_margin = (int)roundf(1 * scale);

    /* Calculate view start, counted from the *current* scrollback start */
    const int scrollback_end
        = (term->grid->offset + term->rows) & (term->grid->num_rows - 1);
    const int view_start
        = (term->grid->view
           - scrollback_end
           + term->grid->num_rows) & (term->grid->num_rows - 1);
    const int view_end = view_start + term->rows - 1;

    const bool show_url = term->url.show_uri_on_jump_label;

    /*
     * There can potentially be a lot of URLs.
     *
     * Since each URL is a separate sub-surface, and requires its own
     * SHM buffer, we may be allocating a lot of buffers.
     *
     * SHM buffers normally have their own, private SHM buffer
     * pool. Each pool is mmapped, and thus allocates *at least*
     * 4K. Since URL labels are typically small, we end up using an
     * excessive amount of both virtual and physical memory.
     *
     * For this reason, we instead use shm_get_many(), which uses a
     * single, shared pool for all buffers.
     *
     * To be able to use it, we need to have all the *all* the buffer
     * dimensions up front.
     *
     * Thus, the first iteration through the URLs do the heavy
     * lifting: builds the label contents and calculates both its
     * position and size. But instead of rendering the label
     * immediately, we store the calculated data, and then do a second
     * pass, where we first get all our buffers, and then render to
     * them.
     */

    /* Positioning data + label contents */
    struct {
        const struct wl_url *url;
        char32_t *text;
        int x;
        int y;
    } info[tll_length(win->urls)];

    /* For shm_get_many() */
    int widths[tll_length(win->urls)];
    int heights[tll_length(win->urls)];

    size_t render_count = 0;

    tll_foreach(win->urls, it) {
        const struct url *url = it->item.url;
        const char32_t *key = url->key;
        const size_t entered_key_len = c32len(term->url.keys);

        if (key == NULL) {
            /* TODO: if we decide to use the .text field, we cannot
             * just skip the entire jump label like this */
            continue;
        }

        struct wl_surface *surf = it->item.surf.surface.surf;
        struct wl_subsurface *sub_surf = it->item.surf.sub;

        if (surf == NULL || sub_surf == NULL)
            continue;

        bool hide = false;
        const struct coord *pos = &url->range.start;
        const int _row
            = (pos->row
               - scrollback_end
               + term->grid->num_rows) & (term->grid->num_rows - 1);

        if (_row < view_start || _row > view_end)
            hide = true;
        if (c32len(key) <= entered_key_len)
            hide = true;
        if (c32ncasecmp(term->url.keys, key, entered_key_len) != 0)
            hide = true;

        if (hide) {
            wl_surface_attach(surf, NULL, 0, 0);
            wl_surface_commit(surf);
            continue;
        }

        int col = pos->col;
        int row = pos->row - term->grid->view;
        while (row < 0)
            row += term->grid->num_rows;
        row &= (term->grid->num_rows - 1);

        /* Position label slightly above and to the left */
        int x = col * term->cell_width - 15 * term->cell_width / 10;
        int y = row * term->cell_height - 5 * term->cell_height / 10;

        /* Don't position it outside our window */
        if (x < -term->margins.left)
            x = -term->margins.left;
        if (y < -term->margins.top)
            y = -term->margins.top;

        /* Maximum width of label, in pixels */
        const int max_width =
            term->width - term->margins.left - term->margins.right - x;
        const int max_cols = max_width / term->cell_width;

        const size_t key_len = c32len(key);

        size_t url_len = mbstoc32(NULL, url->url, 0);
        if (url_len == (size_t)-1)
            url_len = 0;

        char32_t url_wchars[url_len + 1];
        mbstoc32(url_wchars, url->url, url_len + 1);

        /* Format label, not yet subject to any size limitations */
        size_t chars = key_len + (show_url ? (2 + url_len) : 0);
        char32_t label[chars + 1];
        label[chars] = U'\0';

        if (show_url) {
            c32cpy(label, key);
            c32cat(label, U": ");
            c32cat(label, url_wchars);
        } else
            c32ncpy(label, key, chars);

        /* Upper case the key characters */
        for (size_t i = 0; i < c32len(key); i++)
            label[i] = toc32upper(label[i]);

        /* Blank already entered key characters */
        for (size_t i = 0; i < entered_key_len; i++)
            label[i] = U' ';

        /*
         * Don't extend outside our window
         *
         * Truncate label so that it doesn't extend outside our
         * window.
         *
         * Do it in a way such that we don't cut the label in the
         * middle of a double-width character.
         */

        int cols = 0;

        for (size_t i = 0; i <= c32len(label); i++) {
            int _cols = c32swidth(label, i);

            if (_cols == (size_t)-1)
                continue;

            if (_cols >= max_cols) {
                if (i > 0)
                    label[i - 1] = U'…';
                label[i] = U'\0';
                cols = max_cols;
                break;
            }
            cols = _cols;
        }

        if (cols == 0)
            continue;

        int width = x_margin + cols * term->cell_width + x_margin;
        int height = y_margin + term->cell_height + y_margin;

        width = roundf(scale * ceilf(width / scale));
        height = roundf(scale * ceilf(height / scale));

        info[render_count].url = &it->item;
        info[render_count].text = xc32dup(label);
        info[render_count].x = x;
        info[render_count].y = y;

        widths[render_count] = width;
        heights[render_count] = height;

        render_count++;
    }

    struct buffer_chain *chain = term->render.chains.url;
    struct buffer *bufs[render_count];
    shm_get_many(chain, render_count, widths, heights, bufs);

    uint32_t fg = term->conf->colors_dark.use_custom.jump_label
        ? term->conf->colors_dark.jump_label.fg
        : term->colors.table[0];
    uint32_t bg = term->conf->colors_dark.use_custom.jump_label
        ? term->conf->colors_dark.jump_label.bg
        : term->colors.table[3];

    for (size_t i = 0; i < render_count; i++) {
        const struct wayl_sub_surface *sub_surf = &info[i].url->surf;

        const char32_t *label = info[i].text;
        const int x = info[i].x;
        const int y = info[i].y;

        xassert(sub_surf->surface.surf != NULL);
        xassert(sub_surf->sub != NULL);

        wl_subsurface_set_position(
            sub_surf->sub,
            roundf((term->margins.left + x) / scale),
            roundf((term->margins.top + y) / scale));

        render_osd(
            term, sub_surf, term->fonts[0], bufs[i], label,
            fg, 0xffu << 24 | bg, x_margin);

        free(info[i].text);
    }
}

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

static void
tiocswinsz(struct terminal *term)
{
    if (term->ptmx >= 0) {
        if (ioctl(term->ptmx, (unsigned int)TIOCSWINSZ,
                     &(struct winsize){
                         .ws_row = term->rows,
                         .ws_col = term->cols,
                         .ws_xpixel = term->cols * term->cell_width,
                         .ws_ypixel = term->rows * term->cell_height}) < 0)
        {
            LOG_ERRNO("TIOCSWINSZ");
        }

        term_send_size_notification(term);
    }
}

static void
delayed_reflow_of_normal_grid(struct terminal *term)
{
    if (term->interactive_resizing.grid == NULL)
        return;

    xassert(term->interactive_resizing.new_rows > 0);

    if (term->grid == &term->normal)
        term->selection.coords = term->interactive_resizing.selection_coords;

    struct coord *const tracking_points[] = {
        &term->selection.coords.start,
        &term->selection.coords.end,
    };

    /* Reflow the original (since before the resize was started) grid,
     * to the *current* dimensions */
    grid_resize_and_reflow(
        term->interactive_resizing.grid, term,
        term->interactive_resizing.new_rows, term->normal.num_cols,
        term->interactive_resizing.old_screen_rows, term->rows,
        term->selection.coords.end.row >= 0 ? ALEN(tracking_points) : 0,
        tracking_points);

    /* Replace the current, truncated, "normal" grid with the
     * correctly reflowed one */
    grid_free(&term->normal);
    term->normal = *term->interactive_resizing.grid;
    free(term->interactive_resizing.grid);

    term->hide_cursor = term->interactive_resizing.old_hide_cursor;

    /* Reset */
    term->interactive_resizing.grid = NULL;
    term->interactive_resizing.old_screen_rows = 0;
    term->interactive_resizing.new_rows = 0;
    term->interactive_resizing.old_hide_cursor = false;
    term->interactive_resizing.selection_coords = (struct range){{-1, -1}, {-1, -1}};

    /* Invalidate render pointers */
    render_wait_for_preapply_damage(term);
    shm_unref(term->render.last_buf);
    term->render.last_buf = NULL;
    term->render.last_cursor.row = NULL;

    tll_free(term->normal.scroll_damage);
    sixel_reflow_grid(term, &term->normal);

    if (term->grid == &term->normal) {
        term_damage_view(term);
        render_refresh(term);
    }

    term_ptmx_resume(term);
}

static bool
fdm_tiocswinsz(struct fdm *fdm, int fd, int events, void *data)
{
    struct terminal *term = data;

    if (events & EPOLLIN) {
        tiocswinsz(term);
        delayed_reflow_of_normal_grid(term);
    }

    if (term->window->resize_timeout_fd >= 0) {
        fdm_del(fdm, term->window->resize_timeout_fd);
        term->window->resize_timeout_fd = -1;
    }
    return true;
}

static void
send_dimensions_to_client(struct terminal *term)
{
    struct wl_window *win = term->window;

    if (!win->is_resizing || term->conf->resize_delay_ms == 0) {
        /* Send new dimensions to client immediately */
        tiocswinsz(term);
        delayed_reflow_of_normal_grid(term);

        /* And make sure to reset and deallocate a lingering timer */
        if (win->resize_timeout_fd >= 0) {
            fdm_del(term->fdm, win->resize_timeout_fd);
            win->resize_timeout_fd = -1;
        }
    } else {
        /* Send new dimensions to client "in a while" */
        assert(win->is_resizing && term->conf->resize_delay_ms > 0);

        int fd = win->resize_timeout_fd;
        uint16_t delay_ms = term->conf->resize_delay_ms;
        bool successfully_scheduled = false;

        if (fd < 0) {
            /* Lazy create timer fd */
            fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
            if (fd < 0)
                LOG_ERRNO("failed to create TIOCSWINSZ timer");
            else if (!fdm_add(term->fdm, fd, EPOLLIN, &fdm_tiocswinsz, term)) {
                close(fd);
                fd = -1;
            }

            win->resize_timeout_fd = fd;
        }

        if (fd >= 0) {
            /* Reset timeout */
            const struct itimerspec timeout = {
                .it_value = {
                    .tv_sec = delay_ms / 1000,
                    .tv_nsec = (delay_ms % 1000) * 1000000,
                },
            };

            if (timerfd_settime(fd, 0, &timeout, NULL) < 0) {
                LOG_ERRNO("failed to arm TIOCSWINSZ timer");
                fdm_del(term->fdm, fd);
                win->resize_timeout_fd = -1;
            } else
                successfully_scheduled = true;
        }

        if (!successfully_scheduled) {
            tiocswinsz(term);
            delayed_reflow_of_normal_grid(term);
        }
    }
}

static void
set_size_from_grid(struct terminal *term, int *width, int *height, int cols, int rows)
{
    int new_width, new_height;

    /* Nominal grid dimensions */
    new_width = cols * term->cell_width;
    new_height = rows * term->cell_height;

    /* Include any configured padding */
    new_width  += (term->conf->pad_left + term->conf->pad_right) * term->scale;
    new_height += (term->conf->pad_top + term->conf->pad_bottom) * term->scale;

    /* Round to multiples of scale */
    new_width = round(term->scale * round(new_width / term->scale));
    new_height = round(term->scale * round(new_height / term->scale));

    if (width != NULL)
        *width = new_width;
    if (height != NULL)
        *height = new_height;
}

/* Move to terminal.c? */
bool
render_resize(struct terminal *term, int width, int height, uint8_t opts)
{
    if (term->shutdown.in_progress)
        return false;

    if (!term->window->is_configured)
        return false;

    if (term->cell_width == 0 && term->cell_height == 0)
        return false;

    const bool is_floating =
        !term->window->is_maximized &&
        !term->window->is_fullscreen &&
        !term->window->is_tiled;

    /* Convert logical size to physical size */
    const float scale = term->scale;
    width = round(width * scale);
    height = round(height * scale);

    /* If the grid should be kept, the size should be overridden */
    if (is_floating && (opts & RESIZE_KEEP_GRID)) {
        set_size_from_grid(term, &width, &height, term->cols, term->rows);
    }

    if (width == 0) {
        /* The compositor is letting us choose the width */
        if (term->stashed_width != 0) {
            /* If a default size is requested, prefer the "last used" size */
            width = term->stashed_width;
        } else {
            /* Otherwise, use a user-configured size */
            switch (term->conf->size.type) {
            case CONF_SIZE_PX:
                width = term->conf->size.width;

                if (wayl_win_csd_borders_visible(term->window))
                    width -= 2 * term->conf->csd.border_width_visible;

                width *= scale;
                break;

            case CONF_SIZE_CELLS:
                set_size_from_grid(term, &width, NULL,
                                   term->conf->size.width, term->conf->size.height);
                break;
            }
        }
    }

    if (height == 0) {
        /* The compositor is letting us choose the height */
        if (term->stashed_height != 0) {
            /* If a default size is requested, prefer the "last used" size */
            height = term->stashed_height;
        } else {
            /* Otherwise, use a user-configured size */
            switch (term->conf->size.type) {
            case CONF_SIZE_PX:
                height = term->conf->size.height;

                /* Take CSDs into account */
                if (wayl_win_csd_titlebar_visible(term->window))
                    height -= term->conf->csd.title_height;

                if (wayl_win_csd_borders_visible(term->window))
                    height -= 2 * term->conf->csd.border_width_visible;

                height *= scale;
                break;

            case CONF_SIZE_CELLS:
                set_size_from_grid(term, NULL, &height,
                                   term->conf->size.width, term->conf->size.height);
                break;
            }
        }
    }

    /* Don't shrink grid too much */
    const int min_cols = 1;
    const int min_rows = 1;

    /* Minimum window size (must be divisible by the scaling factor)*/
    const int min_width = roundf(scale * ceilf((min_cols * term->cell_width) / scale));
    const int min_height = roundf(scale * ceilf((min_rows * term->cell_height) / scale));

    width = max(width, min_width);
    height = max(height, min_height);

    /* Padding */
    const int max_pad_x = (width - min_width) / 2;
    const int max_pad_y = (height - min_height) / 2;
    const int pad_left  = min(max_pad_x, scale * term->conf->pad_left);
    const int pad_right = min(max_pad_x, scale * term->conf->pad_right);
    const int pad_top   = min(max_pad_y, scale * term->conf->pad_top);
    const int pad_bottom= min(max_pad_y, scale * term->conf->pad_bottom);

    if (is_floating &&
        (opts & RESIZE_BY_CELLS) &&
        term->conf->resize_by_cells)
    {
        /* If resizing in cell increments, restrict the width and height */
        width = ((width - (pad_left + pad_right)) / term->cell_width)
                * term->cell_width + (pad_left + pad_right);
        width = max(min_width, roundf(scale * roundf(width / scale)));

        height = ((height - (pad_top + pad_bottom)) / term->cell_height)
                 * term->cell_height + (pad_top + pad_bottom);
        height = max(min_height, roundf(scale * roundf(height / scale)));
    }

    if (!(opts & RESIZE_FORCE) &&
        width == term->width &&
        height == term->height &&
        scale == term->scale)
    {
        return false;
    }

    /* Cancel an application initiated "Synchronized Update" */
    term_disable_app_sync_updates(term);

    /* Drop out of URL mode */
    urls_reset(term);

    LOG_DBG("resized: size=%dx%d (scale=%.2f)", width, height, term->scale);
    term->width = width;
    term->height = height;

    /* Screen rows/cols before resize */
    int old_cols = term->cols;
    int old_rows = term->rows;

    /* Screen rows/cols after resize */
    const int new_cols =
        (term->width - (pad_left + pad_right)) / term->cell_width;
    const int new_rows =
        (term->height - (pad_top + pad_bottom)) / term->cell_height;

    /*
     * Requirements for scrollback:
     *
     *   a) total number of rows (visible + scrollback history) must be
     *      a power of two
     *   b) must be representable in a plain int (signed)
     *
     * This means that on a "normal" system, where ints are 32-bit,
     * the largest possible scrollback size is 1073741824 (0x40000000,
     * 1 << 30).
     *
     * The largest *signed* int is 2147483647 (0x7fffffff), which is
     * *not* a power of two.
     *
     * Note that these are theoretical limits. Most of the time,
     * you'll get a memory allocation failure when trying to allocate
     * the grid array.
     */
    const unsigned max_scrollback = (INT_MAX >> 1) + 1;
    const unsigned scrollback_lines_not_yet_power_of_two =
        min((uint64_t)term->render.scrollback_lines + new_rows - 1, max_scrollback);

    /* Grid rows/cols after resize */
    const int new_normal_grid_rows =
        min(1u << (32 - __builtin_clz(scrollback_lines_not_yet_power_of_two)),
            max_scrollback);
    const int new_alt_grid_rows =
        min(1u << (32 - __builtin_clz(new_rows)), max_scrollback);

    LOG_DBG("grid rows: %d", new_normal_grid_rows);

    xassert(new_cols >= 1);
    xassert(new_rows >= 1);

    /* Margins */
    const int grid_width = new_cols * term->cell_width;
    const int grid_height = new_rows * term->cell_height;
    const int total_x_pad = term->width - grid_width;
    const int total_y_pad = term->height - grid_height;

    const enum center_when center = term->conf->center_when;
    const bool centered_padding =
        center == CENTER_ALWAYS ||
        (center == CENTER_MAXIMIZED_AND_FULLSCREEN &&
         (term->window->is_fullscreen || term->window->is_maximized)) ||
        (center == CENTER_FULLSCREEN && term->window->is_fullscreen);

    if (centered_padding && !term->window->is_resizing) {
        term->margins.left = total_x_pad / 2;
        term->margins.top = total_y_pad / 2;
    } else {
        term->margins.left = pad_left;
        term->margins.top = pad_top;
    }
    term->margins.right = total_x_pad - term->margins.left;
    term->margins.bottom = total_y_pad - term->margins.top;

    xassert(term->margins.left >= pad_left);
    xassert(term->margins.right >= pad_right);
    xassert(term->margins.top >= pad_top);
    xassert(term->margins.bottom >= pad_bottom);

    if (new_cols == old_cols && new_rows == old_rows) {
        LOG_DBG("grid layout unaffected; skipping reflow");
        term->interactive_resizing.new_rows = new_normal_grid_rows;
        goto damage_view;
    }

    /*
     * Since text reflow is slow, don't do it *while* resizing. Only
     * do it when done, or after "pausing" the resize for sufficiently
     * long. We reuse the TIOCSWINSZ timer to handle this. See
     * send_dimensions_to_client() and fdm_tiocswinsz().
     *
     * To be able to do the final reflow correctly, we need a copy of
     * the original grid, before the resize started.
     */
    if (term->window->is_resizing && term->conf->resize_delay_ms > 0) {
        if (term->interactive_resizing.grid == NULL) {
            term_ptmx_pause(term);

            /* Stash the current 'normal' grid, as-is, to be used when
             * doing the final reflow */
            term->interactive_resizing.old_screen_rows = term->rows;
            term->interactive_resizing.old_cols = term->cols;
            term->interactive_resizing.old_hide_cursor = term->hide_cursor;
            term->interactive_resizing.grid = xmalloc(sizeof(*term->interactive_resizing.grid));
            *term->interactive_resizing.grid = term->normal;

            if (term->grid == &term->normal) {
                term->interactive_resizing.selection_coords = term->selection.coords;
                term->selection.coords.start.row -= term->grid->view;
                term->selection.coords.end.row -= term->grid->view;
            }
        } else {
            /* We'll replace the current temporary grid, with a new
             * one (again based on the original grid) */
            grid_free(&term->normal);
        }

        struct grid *orig = term->interactive_resizing.grid;

        /*
         * Copy the current viewport (of the original grid) to a new
         * grid that will be used during the resize. For now, throw
         * away sixels and OSC-8 URLs. They'll be "restored" when we
         * do the final reflow.
         *
         * Note that OSC-8 URLs are perfectly ok to throw away; they
         * cannot be interacted with during the resize. And, even if
         * url.osc8-underline=always, the "underline" attribute is
         * part of the cell, not the URI struct (and thus our faked
         * grid will still render OSC-8 links underlined).
         *
         * TODO:
         *  - sixels?
         */
        struct grid g = {
            .num_rows = 1 << (32 - __builtin_clz(term->interactive_resizing.old_screen_rows)),
            .num_cols = term->interactive_resizing.old_cols,
            .offset = 0,
            .view = 0,
            .cursor = orig->cursor,
            .saved_cursor = orig->saved_cursor,
            .rows = xcalloc(g.num_rows, sizeof(g.rows[0])),
            .cur_row = NULL,
            .scroll_damage = tll_init(),
            .sixel_images = tll_init(),
            .kitty_kbd = orig->kitty_kbd,
        };

        for (size_t i = 0, j = orig->view;
             i < term->interactive_resizing.old_screen_rows;
             i++, j = (j + 1) & (orig->num_rows - 1))
        {
            g.rows[i] = grid_row_alloc(g.num_cols, false);
            memcpy(g.rows[i]->cells,
                   orig->rows[j]->cells,
                   g.num_cols * sizeof(g.rows[i]->cells[0]));

            if (orig->rows[j]->extra == NULL ||
                orig->rows[j]->extra->underline_ranges.count == 0)
            {
                continue;
            }

            /*
             * Copy underline ranges
             */

            const struct row_ranges *underline_src = &orig->rows[j]->extra->underline_ranges;

            const int count = underline_src->count;
            g.rows[i]->extra = xcalloc(1, sizeof(*g.rows[i]->extra));
            g.rows[i]->extra->underline_ranges.v = xmalloc(
                count * sizeof(g.rows[i]->extra->underline_ranges.v[0]));

            struct row_ranges *underline_dst = &g.rows[i]->extra->underline_ranges;
            underline_dst->count = underline_dst->size = count;

            for (int k = 0; k < count; k++)
                underline_dst->v[k] = underline_src->v[k];
        }

        term->normal = g;
        term->hide_cursor = true;
    }

    if (term->grid == &term->alt)
        selection_cancel(term);
    else {
        /*
         * Don't cancel, but make sure there aren't any ongoing
         * selections after the resize.
         */
        tll_foreach(term->wl->seats, it) {
            if (it->item.kbd_focus == term)
                selection_finalize(&it->item, term, it->item.pointer.serial);
        }
    }

    /* Ensure mouse col/row coordinates are still valid */
    tll_foreach(term->wl->seats, it) {
        struct seat *seat = &it->item;
        if (seat->mouse_focus == term)
            mouse_coord_pixel_to_cell(seat, term, seat->mouse.x, seat->mouse.y);
    }

    /*
     * TODO: if we remove the selection_finalize() call above (i.e. if
     * we start allowing selections to be ongoing across resizes), the
     * selection's pivot point coordinates *must* be added to the
     * tracking points list.
     */
    /* Resize grids */
    if (term->window->is_resizing && term->conf->resize_delay_ms > 0) {
        /* Simple truncating resize, *while* an interactive resize is
         * ongoing. */
        xassert(term->interactive_resizing.grid != NULL);
        xassert(new_normal_grid_rows > 0);
        term->interactive_resizing.new_rows = new_normal_grid_rows;

        grid_resize_without_reflow(
            &term->normal, new_alt_grid_rows, new_cols,
            term->interactive_resizing.old_screen_rows, new_rows);
    } else {
        /* Full text reflow */

        int old_normal_rows = old_rows;

        if (term->interactive_resizing.grid != NULL) {
            /* Throw away the current, truncated, "normal" grid, and
             * use the original grid instead (from before the resize
             * started) */
            grid_free(&term->normal);
            term->normal = *term->interactive_resizing.grid;
            free(term->interactive_resizing.grid);

            term->hide_cursor = term->interactive_resizing.old_hide_cursor;
            term->selection.coords = term->interactive_resizing.selection_coords;

            old_normal_rows = term->interactive_resizing.old_screen_rows;

            term->interactive_resizing.grid = NULL;
            term->interactive_resizing.old_screen_rows = 0;
            term->interactive_resizing.new_rows = 0;
            term->interactive_resizing.old_hide_cursor = false;
            term->interactive_resizing.selection_coords = (struct range){{-1, -1}, {-1, -1}};
            term_ptmx_resume(term);
        }

        struct coord *const tracking_points[] = {
            &term->selection.coords.start,
            &term->selection.coords.end,
        };

        grid_resize_and_reflow(
            &term->normal, term, new_normal_grid_rows, new_cols, old_normal_rows, new_rows,
            term->selection.coords.end.row >= 0 ? ALEN(tracking_points) : 0,
            tracking_points);
    }

    grid_resize_without_reflow(
        &term->alt, new_alt_grid_rows, new_cols, old_rows, new_rows);

    /* Reset tab stops */
    tll_free(term->tab_stops);
    for (int c = 0; c < new_cols; c += 8)
        tll_push_back(term->tab_stops, c);

    term->cols = new_cols;
    term->rows = new_rows;

    sixel_reflow(term);

    LOG_DBG("resized: grid: cols=%d, rows=%d "
            "(left-margin=%d, right-margin=%d, top-margin=%d, bottom-margin=%d)",
            term->cols, term->rows,
            term->margins.left, term->margins.right,
            term->margins.top, term->margins.bottom);

    if (term->scroll_region.start >= term->rows)
        term->scroll_region.start = 0;
    if (term->scroll_region.end > term->rows ||
        term->scroll_region.end >= old_rows)
    {
        term->scroll_region.end = term->rows;
    }

    term->render.last_cursor.row = NULL;

damage_view:
    /* Signal TIOCSWINSZ */
    send_dimensions_to_client(term);

    if (is_floating) {
        /* Stash current size, to enable us to restore it when we're
         * being un-maximized/fullscreened/tiled */
        term->stashed_width = term->width;
        term->stashed_height = term->height;
    }

    {
        const bool title_shown = wayl_win_csd_titlebar_visible(term->window);
        const bool border_shown = wayl_win_csd_borders_visible(term->window);

        const int title = title_shown
            ? roundf(term->conf->csd.title_height * scale)
            : 0;
        const int border = border_shown
            ? roundf(term->conf->csd.border_width_visible * scale)
            : 0;

        /* Must use surface logical coordinates (same calculations as
           in get_csd_data(), but with different inputs) */
        const int toplevel_min_width = roundf(border / scale) +
                                       roundf(min_width / scale) +
                                       roundf(border / scale);

        const int toplevel_min_height = roundf(border / scale) +
                                        roundf(title / scale) +
                                        roundf(min_height / scale) +
                                        roundf(border / scale);

        const int toplevel_width = roundf(border / scale) +
                                   roundf(term->width / scale) +
                                   roundf(border / scale);

        const int toplevel_height = roundf(border / scale) +
                                    roundf(title / scale) +
                                    roundf(term->height / scale) +
                                    roundf(border / scale);

        const int x = roundf(-border / scale);
        const int y = roundf(-title / scale) - roundf(border / scale);

        xdg_toplevel_set_min_size(
            term->window->xdg_toplevel,
            toplevel_min_width, toplevel_min_height);

        xdg_surface_set_window_geometry(
            term->window->xdg_surface,
            x, y, toplevel_width, toplevel_height);
    }

    tll_free(term->normal.scroll_damage);
    tll_free(term->alt.scroll_damage);

    render_wait_for_preapply_damage(term);
    shm_unref(term->render.last_buf);
    term->render.last_buf = NULL;
    term_damage_view(term);
    render_refresh_csd(term);
    render_refresh_search(term);
    render_refresh(term);

    return true;
}

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
