#include "terminal.h"

#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <xdg-shell.h>

#define LOG_MODULE "terminal"
#define LOG_ENABLE_DBG 0
#include "log.h"

#include "async.h"
#include "commands.h"
#include "config.h"
#include "debug.h"
#include "emoji-variation-sequences.h"
#include "extract.h"
#include "grid.h"
#include "ime.h"
#include "input.h"
#include "notify.h"
#include "quirks.h"
#include "reaper.h"
#include "render.h"
#include "selection.h"
#include "shm.h"
#include "sixel.h"
#include "slave.h"
#include "spawn.h"
#include "url-mode.h"
#include "util.h"
#include "vt.h"
#include "xmalloc.h"

/* Ported to terminal.zig — extern for C callers */

/* Ported to terminal.zig — extern for C callers */
extern void term_update_ascii_printer(struct terminal *term);
extern void term_single_shift(struct terminal *term, enum charset_designator idx);

/* Ported to terminal.zig — extern for C callers */
extern void term_erase(struct terminal *term, int start_row, int start_col, int end_row, int end_col);
extern void term_fill(struct terminal *term, int r, int c, uint8_t data, size_t count, bool use_sgr_attrs);
extern void term_print(struct terminal *term, char32_t wc, int width, bool insert_mode_disable);
/* Ported to terminal.zig — extern for C callers */
extern void term_process_and_print_non_ascii(struct terminal *term, char32_t wc);
extern void print_spacer(struct terminal *term, int col, int remaining);

/* Ported to terminal.zig — extern for C callers */
extern void term_scroll_partial(struct terminal *term, struct scroll_region region, int rows);
extern void term_scroll(struct terminal *term, int rows);
extern void term_scroll_reverse_partial(struct terminal *term, struct scroll_region region, int rows);
extern void term_scroll_reverse(struct terminal *term, int rows);
extern void term_linefeed(struct terminal *term);
extern void term_reverse_index(struct terminal *term);

/* Ported to terminal.zig — extern for C callers */
extern bool fdm_flash(struct fdm *fdm, int fd, int events, void *data);
extern void cursor_refresh(struct terminal *term);
extern bool cursor_blink_rearm_timer(struct terminal *term);
extern bool cursor_blink_disarm_timer(struct terminal *term);
extern void term_arm_blink_timer(struct terminal *term);
extern void term_cursor_blink_update(struct terminal *term);
extern int term_row_rel_to_abs(const struct terminal *term, int row);
#include "xsnprintf.h"

#define PTMX_TIMING 0

/* Ported to terminal.zig — extern for C callers */
extern bool term_to_slave(struct terminal *term, const void *data, size_t len);
extern bool term_paste_data_to_slave(struct terminal *term, const void *data, size_t len);
extern bool term_ptmx_pause(struct terminal *term);
extern bool term_ptmx_resume(struct terminal *term);
extern bool fdm_ptmx_out(struct fdm *fdm, int fd, int events, void *data);

/* enqueue_data_for_slave: ported to terminal.zig */
/* data_to_slave: ported to terminal.zig */
/* term_paste_data_to_slave: ported to terminal.zig */
/* term_to_slave: ported to terminal.zig */
/* fdm_ptmx_out: ported to terminal.zig */

static bool
add_utmp_record(const struct config *conf, struct reaper *reaper, int ptmx)
{
#if defined(UTMP_ADD)
    if (ptmx < 0)
        return true;
    if (conf->utmp_helper_path == NULL)
        return true;

    char *const argv[] = {conf->utmp_helper_path, UTMP_ADD, getenv("WAYLAND_DISPLAY"), NULL};
    return spawn(reaper, NULL, argv, ptmx, -1, -1, NULL, NULL, NULL) >= 0;
#else
    return true;
#endif
}

/* Externally visible for terminal.zig (was static) */
bool
del_utmp_record(const struct config *conf, struct reaper *reaper, int ptmx)
{
#if defined(UTMP_DEL)
    if (ptmx < 0)
        return true;
    if (conf->utmp_helper_path == NULL)
        return true;

    char *del_argument =
#if defined(UTMP_DEL_HAVE_ARGUMENT)
        getenv("WAYLAND_DISPLAY")
#else
        NULL
#endif
        ;

    char *const argv[] = {conf->utmp_helper_path, UTMP_DEL, del_argument, NULL};
    return spawn(reaper, NULL, argv, ptmx, -1, -1, NULL, NULL, NULL) >= 0;
#else
    return true;
#endif
}

#if PTMX_TIMING
static struct timespec last = {0};
#endif


/* fdm_ptmx: ported to terminal.zig */
extern bool fdm_ptmx(struct fdm *fdm, int fd, int events, void *data);

/* term_ptmx_pause: ported to terminal.zig */
/* term_ptmx_resume: ported to terminal.zig */
/* fdm_flash: ported to terminal.zig */
/* fdm_blink: ported to terminal.zig */
/* term_arm_blink_timer: ported to terminal.zig */
/* cursor_refresh: ported to terminal.zig */
/* fdm_cursor_blink: ported to terminal.zig */

static bool
fdm_delayed_render(struct fdm *fdm, int fd, int events, void *data)
{
    if (events & EPOLLHUP)
        return false;

    struct terminal *term = data;

    uint64_t unused;
    ssize_t ret1 = 0;
    ssize_t ret2 = 0;

    if (fd == term->delayed_render_timer.lower_fd)
        ret1 = read(term->delayed_render_timer.lower_fd, &unused, sizeof(unused));
    if (fd == term->delayed_render_timer.upper_fd)
        ret2 = read(term->delayed_render_timer.upper_fd, &unused, sizeof(unused));

    if ((ret1 < 0 || ret2 < 0)) {
        if (errno == EAGAIN)
            return true;

        LOG_ERRNO("failed to read timeout timer");
        return false;
    }

    if (ret1 > 0)
        LOG_DBG("lower delay timer expired");
    else if (ret2 > 0)
        LOG_DBG("upper delay timer expired");

    if (ret1 == 0 && ret2 == 0)
        return true;

#if PTMX_TIMING
    last = (struct timespec){0};
#endif

    /* Reset timers */
    struct itimerspec reset = {{0}};
    timerfd_settime(term->delayed_render_timer.lower_fd, 0, &reset, NULL);
    timerfd_settime(term->delayed_render_timer.upper_fd, 0, &reset, NULL);
    term->delayed_render_timer.is_armed = false;

    render_refresh(term);
    return true;
}

/* fdm_app_sync_updates_timeout, fdm_title_update_timeout,
 * fdm_icon_update_timeout, fdm_app_id_update_timeout: ported to terminal.zig */
extern bool fdm_app_sync_updates_timeout(struct fdm *fdm, int fd, int events, void *data);
extern bool fdm_title_update_timeout(struct fdm *fdm, int fd, int events, void *data);
extern bool fdm_icon_update_timeout(struct fdm *fdm, int fd, int events, void *data);
extern bool fdm_app_id_update_timeout(struct fdm *fdm, int fd, int events, void *data);

static bool
initialize_render_workers(struct terminal *term)
{
    LOG_INFO("using %hu rendering threads", term->render.workers.count);

    if (sem_init(&term->render.workers.start, 0, 0) < 0 ||
        sem_init(&term->render.workers.done, 0, 0) < 0)
    {
        LOG_ERRNO("failed to instantiate render worker semaphores");
        return false;
    }

    int err;
    if ((err = mtx_init(&term->render.workers.lock, mtx_plain)) != thrd_success) {
        LOG_ERR("failed to instantiate render worker mutex: %s (%d)",
                thrd_err_as_string(err), err);
        goto err_sem_destroy;
    }

    mtx_init(&term->render.workers.preapplied_damage.lock, mtx_plain);
    cnd_init(&term->render.workers.preapplied_damage.cond);

    term->render.workers.threads = xcalloc(
        term->render.workers.count, sizeof(term->render.workers.threads[0]));

    for (size_t i = 0; i < term->render.workers.count; i++) {
        struct render_worker_context *ctx = xmalloc(sizeof(*ctx));
        *ctx = (struct render_worker_context) {
            .term = term,
            .my_id = 1 + i,
        };

        int ret = thrd_create(
            &term->render.workers.threads[i], &render_worker_thread, ctx);
        if (ret != thrd_success) {

            LOG_ERR("failed to create render worker thread: %s (%d)",
                    thrd_err_as_string(ret), ret);
            term->render.workers.threads[i] = 0;
            return false;
        }
    }

    return true;

err_sem_destroy:
    sem_destroy(&term->render.workers.start);
    sem_destroy(&term->render.workers.done);
    return false;
}

static void
free_custom_glyph(struct fcft_glyph **glyph)
{
    if (*glyph == NULL)
        return;

    free(pixman_image_get_data((*glyph)->pix));
    pixman_image_unref((*glyph)->pix);
    free(*glyph);
    *glyph = NULL;
}

static void
free_custom_glyphs(struct fcft_glyph ***glyphs, size_t count)
{
    if (*glyphs == NULL)
        return;

    for (size_t i = 0; i < count; i++)
        free_custom_glyph(&(*glyphs)[i]);

    free(*glyphs);
    *glyphs = NULL;
}

static void
term_line_height_update(struct terminal *term)
{
    const struct config *conf = term->conf;

    if (term->conf->line_height.px < 0) {
        term->font_line_height.pt = 0;
        term->font_line_height.px = -1;
        return;
    }

    const float dpi = term->font_is_sized_by_dpi ? term->font_dpi : 96.;

    const float font_original_pt_size =
        conf->fonts[0].arr[0].px_size > 0
        ? conf->fonts[0].arr[0].px_size * 72. / dpi
        : conf->fonts[0].arr[0].pt_size;
    const float font_current_pt_size =
        term->font_sizes[0][0].px_size > 0
        ? term->font_sizes[0][0].px_size * 72. / dpi
        : term->font_sizes[0][0].pt_size;

    const float change = font_current_pt_size / font_original_pt_size;
    const float line_original_pt_size = conf->line_height.px > 0
            ? conf->line_height.px * 72. / dpi
            : conf->line_height.pt;

    term->font_line_height.px = 0;
    term->font_line_height.pt = fmaxf(line_original_pt_size * change, 0.);
}

static bool
term_set_fonts(struct terminal *term, struct fcft_font *fonts[static 4],
               bool resize_grid)
{
    for (size_t i = 0; i < 4; i++) {
        xassert(fonts[i] != NULL);

        fcft_destroy(term->fonts[i]);
        term->fonts[i] = fonts[i];
    }

    free_custom_glyphs(
        &term->custom_glyphs.box_drawing, GLYPH_BOX_DRAWING_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.braille, GLYPH_BRAILLE_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.legacy, GLYPH_LEGACY_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.octants, GLYPH_OCTANTS_COUNT);

    const struct config *conf = term->conf;

    const struct fcft_glyph *M = fcft_rasterize_char_utf32(
        fonts[0], U'M', term->font_subpixel);
    int advance = M != NULL ? M->advance.x : term->fonts[0]->max_advance.x;

    term_line_height_update(term);

    term->cell_width = advance +
        term_pt_or_px_as_pixels(term, &conf->letter_spacing);

    term->cell_height = term->font_line_height.px >= 0
        ? term_pt_or_px_as_pixels(term, &term->font_line_height)
        : max(term->fonts[0]->height,
              term->fonts[0]->ascent + term->fonts[0]->descent);

    if (term->cell_width <= 0)
        term->cell_width = 1;
    if (term->cell_height <= 0)
        term->cell_height = 1;

    term->font_x_ofs = term_pt_or_px_as_pixels(term, &conf->horizontal_letter_offset);
    term->font_y_ofs = term_pt_or_px_as_pixels(term, &conf->vertical_letter_offset);

    term->font_baseline = term_font_baseline(term);

    LOG_INFO("cell width=%d, height=%d", term->cell_width, term->cell_height);

    sixel_cell_size_changed(term);

    /* Optimization - some code paths (are forced to) call
     * render_resize() after this function */
    if (resize_grid) {
        /* Use force, since cell-width/height may have changed */
        enum resize_options resize_opts = RESIZE_FORCE;
        if (conf->resize_keep_grid)
            resize_opts |= RESIZE_KEEP_GRID;

        render_resize(
            term,
            (int)roundf(term->width / term->scale),
            (int)roundf(term->height / term->scale),
            resize_opts);
    }
    return true;
}

static float
get_font_dpi(const struct terminal *term)
{
    /*
     * Use output's DPI to scale font. This is to ensure the font has
     * the same physical height (if measured by a ruler) regardless of
     * monitor.
     *
     * Conceptually, we use the physical monitor specs to calculate
     * the DPI, and we ignore the output's scaling factor.
     *
     * However, to deal with legacy fractional scaling, where we're
     * told to render at e.g. 2x, but are then downscaled by the
     * compositor to e.g. 1.25, we use the scaled DPI value multiplied
     * by the scale factor instead.
     *
     * For integral scaling factors the resulting DPI is the same as
     * if we had used the physical DPI.
     *
     * For legacy fractional scaling factors we'll get a DPI *larger*
     * than the physical DPI, that ends up being right when later
     * downscaled by the compositor.
     *
     * With the newer fractional-scale-v1 protocol, we use the
     * monitor's real DPI, since we scale everything to the correct
     * scaling factor (no downscaling done by the compositor).
     */

    const struct wl_window *win = term->window;
    const struct monitor *mon = NULL;

    if (tll_length(win->on_outputs) > 0)
        mon = tll_back(win->on_outputs);
    else {
        if (term->font_dpi_before_unmap > 0.) {
            /*
             * Use last known "good" DPI
             *
             * This avoids flickering when window is unmapped/mapped
             * (some compositors do this when a window is minimized),
             * on a multi-monitor setup with different monitor DPIs.
             */
            return term->font_dpi_before_unmap;
        }

        if (tll_length(term->wl->monitors) > 0)
            mon = &tll_front(term->wl->monitors);
    }

    const float monitor_dpi = mon != NULL
        ? term_fractional_scaling(term)
            ? mon->dpi.physical
            : mon->dpi.scaled
        : 96.;

    return monitor_dpi > 0. ? monitor_dpi : 96.;
}

static enum fcft_subpixel
get_font_subpixel(const struct terminal *term)
{
    if (term->colors.alpha != 0xffff) {
        /* Can't do subpixel rendering on transparent background */
        return FCFT_SUBPIXEL_NONE;
    }

    enum wl_output_subpixel wl_subpixel;

    /*
     * Wayland doesn't tell us *which* part of the surface that goes
     * on a specific output, only whether the surface is mapped to an
     * output or not.
     *
     * Thus, when determining which subpixel mode to use, we can't do
     * much but select *an* output. So, we pick the one we were most
     * recently mapped on.
     *
     * If we're not mapped at all, we pick the first available
     * monitor, and hope that's where we'll eventually get mapped.
     *
     * If there aren't any monitors we use the "default" subpixel
     * mode.
     */

    if (tll_length(term->window->on_outputs) > 0)
        wl_subpixel = tll_back(term->window->on_outputs)->subpixel;
    else if (tll_length(term->wl->monitors) > 0)
        wl_subpixel = tll_front(term->wl->monitors).subpixel;
    else
        wl_subpixel = WL_OUTPUT_SUBPIXEL_UNKNOWN;

    switch (wl_subpixel) {
    case WL_OUTPUT_SUBPIXEL_UNKNOWN:        return FCFT_SUBPIXEL_DEFAULT;
    case WL_OUTPUT_SUBPIXEL_NONE:           return FCFT_SUBPIXEL_NONE;
    case WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB: return FCFT_SUBPIXEL_HORIZONTAL_RGB;
    case WL_OUTPUT_SUBPIXEL_HORIZONTAL_BGR: return FCFT_SUBPIXEL_HORIZONTAL_BGR;
    case WL_OUTPUT_SUBPIXEL_VERTICAL_RGB:   return FCFT_SUBPIXEL_VERTICAL_RGB;
    case WL_OUTPUT_SUBPIXEL_VERTICAL_BGR:   return FCFT_SUBPIXEL_VERTICAL_BGR;
    }

    return FCFT_SUBPIXEL_DEFAULT;
}

int
term_pt_or_px_as_pixels(const struct terminal *term,
                        const struct pt_or_px *pt_or_px)
{
    float scale = !term->font_is_sized_by_dpi ? term->scale : 1.;
    float dpi = term->font_is_sized_by_dpi  ? term->font_dpi : 96.;

    return pt_or_px->px == 0
        ? (int)roundf(pt_or_px->pt * scale * dpi / 72)
        : (int)roundf(pt_or_px->px * scale);
}

struct font_load_data {
    size_t count;
    const char **names;
    const char *attrs;

    const struct fcft_font_options *options;
    struct fcft_font **font;
};

static int
font_loader_thread(void *_data)
{
    struct font_load_data *data = _data;
    *data->font = fcft_from_name2(
        data->count, data->names, data->attrs, data->options);
    return *data->font != NULL;
}

static bool
reload_fonts(struct terminal *term, bool resize_grid)
{
    const struct config *conf = term->conf;

    const size_t counts[4] = {
        conf->fonts[0].count,
        conf->fonts[1].count,
        conf->fonts[2].count,
        conf->fonts[3].count,
    };

    /* Configure size (which may have been changed run-time) */
    char **names[4];
    for (size_t i = 0; i < 4; i++) {
        names[i] = xmalloc(counts[i] * sizeof(names[i][0]));

        const struct config_font_list *font_list = &conf->fonts[i];

        for (size_t j = 0; j < font_list->count; j++) {
            const struct config_font *font = &font_list->arr[j];
            bool use_px_size = term->font_sizes[i][j].px_size > 0;
            char size[64];

            const float scale = term->font_is_sized_by_dpi ? 1. : term->scale;

            if (use_px_size)
                snprintf(size, sizeof(size), ":pixelsize=%d",
                         (int)roundf(term->font_sizes[i][j].px_size * scale));
            else
                snprintf(size, sizeof(size), ":size=%.2f",
                         term->font_sizes[i][j].pt_size * scale);

            names[i][j] = xstrjoin(font->pattern, size);
        }
    }

    /* Did user configure custom bold/italic fonts?
     * Or should we use the regular font, with weight/slant attributes? */
    const bool custom_bold = counts[1] > 0;
    const bool custom_italic = counts[2] > 0;
    const bool custom_bold_italic = counts[3] > 0;

    const size_t count_regular = counts[0];
    const char **names_regular = (const char **)names[0];

    const size_t count_bold = custom_bold ? counts[1] : counts[0];
    const char **names_bold = (const char **)(custom_bold ? names[1] : names[0]);

    const size_t count_italic = custom_italic ? counts[2] : counts[0];
    const char **names_italic = (const char **)(custom_italic ? names[2] : names[0]);

    const size_t count_bold_italic = custom_bold_italic ? counts[3] : counts[0];
    const char **names_bold_italic = (const char **)(custom_bold_italic ? names[3] : names[0]);

    const bool use_dpi = term->font_is_sized_by_dpi;
    char *dpi = xasprintf("dpi=%.2f", use_dpi ? term->font_dpi : 96.);

    char *attrs[4] = {
        [0] = dpi, /* Takes ownership */
        [1] = xstrjoin(dpi, !custom_bold ? ":weight=bold" : ""),
        [2] = xstrjoin(dpi, !custom_italic ? ":slant=italic" : ""),
        [3] = xstrjoin(dpi, !custom_bold_italic ? ":weight=bold:slant=italic" : ""),
        };

    struct fcft_font_options *options = fcft_font_options_create();

    options->scaling_filter = conf->tweak.fcft_filter;
    options->color_glyphs.format = PIXMAN_a8r8g8b8;
    options->color_glyphs.srgb_decode =
        wayl_do_linear_blending(term->wl, term->conf);

    if (shm_chain_bit_depth(term->render.chains.grid) >= SHM_BITS_10) {
        /*
         * Use a high-res buffer type for emojis. We don't want to use
         * an a2r10g0b10 type of surface, since we need more than 2
         * bits for alpha.
         */
#if defined(HAVE_PIXMAN_RGBA_16)
        options->color_glyphs.format = PIXMAN_a16b16g16r16;
#else
        options->color_glyphs.format = PIXMAN_rgba_float;
#endif
    }

    struct fcft_font *fonts[4];
    struct font_load_data data[4] = {
        {count_regular,     names_regular,     attrs[0], options, &fonts[0]},
        {count_bold,        names_bold,        attrs[1], options, &fonts[1]},
        {count_italic,      names_italic,      attrs[2], options, &fonts[2]},
        {count_bold_italic, names_bold_italic, attrs[3], options, &fonts[3]},
    };

    thrd_t tids[4] = {0};
    for (size_t i = 0; i < 4; i++) {
        int ret = thrd_create(&tids[i], &font_loader_thread, &data[i]);
        if (ret != thrd_success) {
            LOG_ERR("failed to create font loader thread: %s (%d)",
                    thrd_err_as_string(ret), ret);
            break;
        }
    }

    bool success = true;
    for (size_t i = 0; i < 4; i++) {
        if (tids[i] != 0) {
            int ret;
            if (thrd_join(tids[i], &ret) != thrd_success)
                success = false;
            else
                success = success && ret;
        } else
            success = false;
    }

    fcft_font_options_destroy(options);

    for (size_t i = 0; i < 4; i++) {
        for (size_t j = 0; j < counts[i]; j++)
            free(names[i][j]);
        free(names[i]);
        free(attrs[i]);
    }

    if (!success) {
        LOG_ERR("failed to load primary fonts");
        for (size_t i = 0; i < 4; i++) {
            fcft_destroy(fonts[i]);
            fonts[i] = NULL;
        }
    }

    return success ? term_set_fonts(term, fonts, resize_grid) : success;
}

static bool
load_fonts_from_conf(struct terminal *term)
{
    const struct config *conf = term->conf;

    for (size_t i = 0; i < 4; i++) {
        const struct config_font_list *font_list = &conf->fonts[i];

        for (size_t j = 0; j < font_list->count; j++) {
            const struct config_font *font = &font_list->arr[j];
            term->font_sizes[i][j] = (struct config_font){
                .pt_size = font->pt_size, .px_size = font->px_size};
        }
    }

    return reload_fonts(term, true);
}

static void fdm_client_terminated(
    struct reaper *reaper, pid_t pid, int status, void *data);

static const int PTY_OPEN_FLAGS = O_RDWR | O_NOCTTY;

struct terminal *
term_init(const struct config *conf, struct fdm *fdm, struct reaper *reaper,
          struct wayland *wayl, const char *foot_exe, const char *cwd,
          const char *token, const char *pty_path,
          int slave_argc, char *const *slave_argv, const char *const *slave_envp,
          int foot_argc, const char *const *foot_argv,
          void (*shutdown_cb)(void *data, int exit_code), void *shutdown_data)
{
    int ptmx = -1;
    int flash_fd = -1;
    int delay_lower_fd = -1;
    int delay_upper_fd = -1;
    int app_sync_updates_fd = -1;
    int title_update_fd = -1;
    int icon_update_fd = -1;
    int app_id_update_fd = -1;

    struct terminal *term = malloc(sizeof(*term));
    if (unlikely(term == NULL)) {
        LOG_ERRNO("malloc() failed");
        return NULL;
    }

    ptmx = pty_path ? open(pty_path, PTY_OPEN_FLAGS) : posix_openpt(PTY_OPEN_FLAGS);
    if (ptmx < 0) {
        LOG_ERRNO("failed to open PTY");
        goto close_fds;
    }
    if ((flash_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0) {
        LOG_ERRNO("failed to create flash timer FD");
        goto close_fds;
    }
    if ((delay_lower_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0 ||
        (delay_upper_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0)
    {
        LOG_ERRNO("failed to create delayed rendering timer FDs");
        goto close_fds;
    }

    if ((app_sync_updates_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0)
    {
        LOG_ERRNO("failed to create application synchronized updates timer FD");
        goto close_fds;
    }

    if ((title_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0)
    {
        LOG_ERRNO("failed to create title update throttle timer FD");
        goto close_fds;
    }

    if ((icon_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0)
    {
        LOG_ERRNO("failed to create icon update throttle timer FD");
        goto close_fds;
    }

    if ((app_id_update_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK)) < 0)
    {
        LOG_ERRNO("failed to create app ID update throttle timer FD");
        goto close_fds;
    }

    if (ioctl(ptmx, (unsigned int)TIOCSWINSZ,
              &(struct winsize){.ws_row = 24, .ws_col = 80}) < 0)
    {
        LOG_ERRNO("failed to set initial TIOCSWINSZ");
        goto close_fds;
    }

    /* Need to register *very* early (before the first "goto err"), to
     * ensure term_destroy() doesn't unref a key-binding we haven't
     * yet ref:d */
    key_binding_new_for_conf(wayl->key_binding_manager, wayl, conf);

    int ptmx_flags;
    if ((ptmx_flags = fcntl(ptmx, F_GETFL)) < 0 ||
        fcntl(ptmx, F_SETFL, ptmx_flags | O_NONBLOCK) < 0)
    {
        LOG_ERRNO("failed to configure ptmx as non-blocking");
        goto err;
    }

    /*
     * Enable all FDM callbackes *except* ptmx - we can't do that
     * until the window has been 'configured' since we don't have a
     * size (and thus no grid) before then.
     */

    if (!fdm_add(fdm, flash_fd, EPOLLIN, &fdm_flash, term) ||
        !fdm_add(fdm, delay_lower_fd, EPOLLIN, &fdm_delayed_render, term) ||
        !fdm_add(fdm, delay_upper_fd, EPOLLIN, &fdm_delayed_render, term) ||
        !fdm_add(fdm, app_sync_updates_fd, EPOLLIN, &fdm_app_sync_updates_timeout, term) ||
        !fdm_add(fdm, title_update_fd, EPOLLIN, &fdm_title_update_timeout, term) ||
        !fdm_add(fdm, icon_update_fd, EPOLLIN, &fdm_icon_update_timeout, term) ||
        !fdm_add(fdm, app_id_update_fd, EPOLLIN, &fdm_app_id_update_timeout, term))
    {
        goto err;
    }

    const enum shm_bit_depth desired_bit_depth =
        conf->tweak.surface_bit_depth == SHM_BITS_AUTO
            ? wayl_do_linear_blending(wayl, conf) ? SHM_BITS_16 : SHM_BITS_8
            : conf->tweak.surface_bit_depth;

    const struct color_theme *theme = NULL;
    switch (conf->initial_color_theme) {
    case COLOR_THEME_DARK: theme = &conf->colors_dark; break;
    case COLOR_THEME_LIGHT: theme = &conf->colors_light; break;
    case COLOR_THEME_1: BUG("COLOR_THEME_1 should not be used"); break;
    case COLOR_THEME_2: BUG("COLOR_THEME_2 should not be used"); break;
    }

    /* Initialize configure-based terminal attributes */
    *term = (struct terminal) {
        .fdm = fdm,
        .reaper = reaper,
        .conf = conf,
        .slave = -1,
        .ptmx = ptmx,
        .ptmx_buffers = tll_init(),
        .ptmx_paste_buffers = tll_init(),
        .font_sizes = {
            xmalloc(sizeof(term->font_sizes[0][0]) * conf->fonts[0].count),
            xmalloc(sizeof(term->font_sizes[1][0]) * conf->fonts[1].count),
            xmalloc(sizeof(term->font_sizes[2][0]) * conf->fonts[2].count),
            xmalloc(sizeof(term->font_sizes[3][0]) * conf->fonts[3].count),
        },
        .font_dpi = 0.,
        .font_dpi_before_unmap = -1.,
        .font_subpixel = (theme->alpha == 0xffff  /* Can't do subpixel rendering on transparent background */
                          ? FCFT_SUBPIXEL_DEFAULT
                          : FCFT_SUBPIXEL_NONE),
        .cursor_keys_mode = CURSOR_KEYS_NORMAL,
        .keypad_keys_mode = KEYPAD_NUMERICAL,
        .reverse_wrap = true,
        .auto_margin = true,
        .window_title_stack = tll_init(),
        .scale = 1.,
        .scale_before_unmap = -1,
        .flash = {.fd = flash_fd},
        .blink = {.fd = -1},
        .vt = {
            .state = 0,  /* STATE_GROUND */
        },
        .colors = {
            .fg = theme->fg,
            .bg = theme->bg,
            .alpha = theme->alpha,
            .cursor_fg = (theme->use_custom.cursor ? 1u << 31 : 0) | theme->cursor.text,
            .cursor_bg = (theme->use_custom.cursor ? 1u << 31 : 0) | theme->cursor.cursor,
            .selection_fg = theme->selection_fg,
            .selection_bg = theme->selection_bg,
            .active_theme = conf->initial_color_theme,
        },
        .color_stack = {
            .stack = NULL,
            .size = 0,
            .idx = 0,
        },
        .origin = ORIGIN_ABSOLUTE,
        .cursor_style = conf->cursor.style,
        .cursor_blink = {
            .decset = false,
            .deccsusr = conf->cursor.blink.enabled,
            .state = CURSOR_BLINK_ON,
            .fd = -1,
        },
        .selection = {
            .coords = {
                .start = {-1, -1},
                .end = {-1, -1},
            },
            .pivot = {
                .start = {-1, -1},
                .end = {-1, -1},
            },
            .auto_scroll = {
                .fd = -1,
            },
        },
        .normal = {.scroll_damage = tll_init(), .sixel_images = tll_init()},
        .alt = {.scroll_damage = tll_init(), .sixel_images = tll_init()},
        .grid = &term->normal,
        .composed = NULL,
        .alt_scrolling = conf->mouse.alternate_scroll_mode,
        .meta = {
            .esc_prefix = true,
            .eight_bit = true,
        },
        .num_lock_modifier = true,
        .bell_action_enabled = true,
        .tab_stops = tll_init(),
        .wl = wayl,
        .render = {
            .chains = {
                .grid = shm_chain_new(wayl, true, 1 + conf->render_worker_count,
                                      desired_bit_depth, &render_buffer_release_callback, term),
                .search = shm_chain_new(wayl, false, 1 ,desired_bit_depth, NULL, NULL),
                .scrollback_indicator = shm_chain_new(wayl, false, 1, desired_bit_depth, NULL, NULL),
                .render_timer = shm_chain_new(wayl, false, 1, desired_bit_depth, NULL, NULL),
                .url = shm_chain_new(wayl, false, 1, desired_bit_depth, NULL, NULL),
                .csd = shm_chain_new(wayl, false, 1, desired_bit_depth, NULL, NULL),
                .overlay = shm_chain_new(wayl, false, 1, desired_bit_depth, NULL, NULL),
            },
            .scrollback_lines = conf->scrollback.lines,
            .app_sync_updates.timer_fd = app_sync_updates_fd,
            .title = {
                .timer_fd = title_update_fd,
            },
            .icon = {
                .timer_fd = icon_update_fd,
            },
            .app_id = {
                .timer_fd = app_id_update_fd,
            },
            .workers = {
                .count = conf->render_worker_count,
                .queue = tll_init(),
            },
        },
        .delayed_render_timer = {
            .is_armed = false,
            .lower_fd = delay_lower_fd,
            .upper_fd = delay_upper_fd,
        },
        .sixel = {
            .scrolling = true,
            .use_private_palette = true,
            .palette_size = SIXEL_MAX_COLORS,
            .max_width = SIXEL_MAX_WIDTH,
            .max_height = SIXEL_MAX_HEIGHT,
        },
        .shutdown = {
            .terminate_timeout_fd = -1,
            .cb = shutdown_cb,
            .cb_data = shutdown_data,
        },
        .foot_exe = xstrdup(foot_exe),
        .cwd = xstrdup(cwd),
        .grapheme_shaping = conf->tweak.grapheme_shaping,
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
        .ime_enabled = true,
#endif
        .active_notifications = tll_init(),
        .argc = foot_argc,
        .argv = xcalloc(foot_argc, sizeof(char *)),
    };

    for (int i = 0; i < foot_argc; i++)
        term->argv[i] = xstrdup(foot_argv[i]);

    pixman_region32_init(&term->render.last_overlay_clip);

    term_update_ascii_printer(term);
    memcpy(term->colors.table, theme->table, sizeof(term->colors.table));

    for (size_t i = 0; i < 4; i++) {
        const struct config_font_list *font_list = &conf->fonts[i];
        for (size_t j = 0; j < font_list->count; j++) {
            const struct config_font *font = &font_list->arr[j];
            term->font_sizes[i][j] = (struct config_font){
                .pt_size = font->pt_size, .px_size = font->px_size};
        }
    }

    for (size_t i = 0; i < ALEN(term->notification_icons); i++) {
        term->notification_icons[i].tmp_file_fd = -1;
    }

    add_utmp_record(conf, reaper, ptmx);

    if (!pty_path) {
        /* Start the slave/client */
        if ((term->slave = slave_spawn(
                 term->ptmx, slave_argc, term->cwd, slave_argv, slave_envp,
                 &conf->env_vars, conf->term, conf->shell, conf->login_shell,
                 &conf->notifications)) == -1)
        {
            goto err;
        }

        reaper_add(term->reaper, term->slave, &fdm_client_terminated, term);
    }

    /* Guess scale; we're not mapped yet, so we don't know on which
     * output we'll be. Use scaling factor from first monitor */
    xassert(tll_length(term->wl->monitors) > 0);
    term->scale = tll_front(term->wl->monitors).scale;

    /* Initialize the Wayland window backend */
    if ((term->window = wayl_win_init(term, token)) == NULL)
        goto err;

    /* Load fonts */
    if (!term_font_dpi_changed(term, 0.))
        goto err;

    term->font_subpixel = get_font_subpixel(term);

    term_set_window_title(term, conf->title);

    /* Let the Wayland backend know we exist */
    tll_push_back(wayl->terms, term);

    switch (conf->startup_mode) {
    case STARTUP_WINDOWED:
        break;

    case STARTUP_MAXIMIZED:
        xdg_toplevel_set_maximized(term->window->xdg_toplevel);
        break;

    case STARTUP_FULLSCREEN:
        xdg_toplevel_set_fullscreen(term->window->xdg_toplevel, NULL);
        break;
    }

    if (!initialize_render_workers(term))
        goto err;

    return term;

err:
    term->shutdown.in_progress = true;
    term_destroy(term);
    return NULL;

close_fds:
    close(ptmx);
    fdm_del(fdm, flash_fd);
    fdm_del(fdm, delay_lower_fd);
    fdm_del(fdm, delay_upper_fd);
    fdm_del(fdm, app_sync_updates_fd);
    fdm_del(fdm, title_update_fd);
    fdm_del(fdm, icon_update_fd);
    fdm_del(fdm, app_id_update_fd);

    free(term);
    return NULL;
}

void
term_window_configured(struct terminal *term)
{
    /* Enable ptmx FDM callback */
    if (!term->shutdown.in_progress) {
        xassert(term->window->is_configured);
        fdm_add(term->fdm, term->ptmx, EPOLLIN, &fdm_ptmx, term);

        const bool gamma_correct = wayl_do_linear_blending(term->wl, term->conf);
        LOG_INFO("gamma-correct blending: %s", gamma_correct ? "enabled" : "disabled");
    }
}

/*
 * Shutdown logic
 *
 * A foot instance can be terminated in two ways:
 *
 *  - the client application terminates (user types 'exit', or pressed C-d in the
 *    shell, etc)
 *  - the foot window is closed
 *
 * Both variants need to trigger to "other" action. I.e. if the client
 * application is terminated, then we need to close the window. If the window is
 * closed, we need to terminate the client application.
 *
 * Only when *both* tasks have completed do we consider ourselves fully
 * shutdown. This is when we can call term_destroy(), and the user provided
 * shutdown callback.
 *
 * The functions involved with this are:
 *
 * - shutdown_maybe_done(): called after any of the two tasks above have
 *   completed. When it determines that *both* tasks are done, it calls
 *   term_destroy() and the user provided shutdown callback.
 *
 * - fdm_client_terminated(): reaper callback, called when the client
 *   application has terminated.
 *
 *     + Kills the "terminate" timeout timer
 *     + Calls shutdown_maybe_done() if the shutdown procedure has already
 *       started (i.e. the window being closed initiated the shutdown)
 *    -OR-
 *       Initiates the shutdown itself, by calling term_shutdown() (client
 *       application termination initiated the shutdown).
 *
 * - term_shutdown(): unregisters all FDM callbacks, sends SIGTERM to the client
 *   application and installs a "terminate" timeout timer (if it hasn't already
 *   terminated). Finally registers an event FD with the FDM, which is
 *   immediately triggered. This is done to ensure any pending FDM events are
 *   handled before shutting down.
 *
 * - fdm_shutdown(): FDM callback, triggered by the event FD in
 *   term_shutdown(). Unmaps and destroys the window resources, and ensures the
 *   seats' focused pointers don't reference us. Finally calls
 *   shutdown_maybe_done().
 *
 * - fdm_terminate_timeout(): FDM callback for the "terminate" timeout
 *   timer. This function is called when the client application hasn't
 *   terminated after 60 seconds (after the SIGTERM). Sends SIGKILL to the
 *   client application.
 *
 * - term_destroy(): normally called from shutdown_maybe_done(), when both the
 *   window has been unmapped, and the client application has terminated. In
 *   this case, it simply destroys all resources.
 *
 *   It may however also be called without term_shutdown() having been called
 *   (typically in error code paths - for example, when the Wayland connection
 *   is closed by the compositor). In this case, the client application is
 *   typically still running, and we can't assume the FDM is running. To handle
 *   this, we install configure a 60 second SIGALRM, send SIGTERM to the client
 *   application, and then enter a blocking waitpid().
 *
 *   If the alarm triggers, we send SIGKILL and once again enter a blocking
 *   waitpid().
 */

static void
shutdown_maybe_done(struct terminal *term)
{
    bool shutdown_done =
        term->window == NULL && term->shutdown.client_has_terminated;

    LOG_DBG("window=%p, slave-has-been-reaped=%d --> %s",
            (void *)term->window, term->shutdown.client_has_terminated,
            (shutdown_done
             ? "shutdown done, calling term_destroy()"
             : "no action"));

    if (!shutdown_done)
        return;

    void (*cb)(void *, int) = term->shutdown.cb;
    void *cb_data = term->shutdown.cb_data;

    int exit_code = term_destroy(term);
    if (cb != NULL)
        cb(cb_data, exit_code);
}

static void
fdm_client_terminated(struct reaper *reaper, pid_t pid, int status, void *data)
{
    struct terminal *term = data;
    LOG_DBG("slave (PID=%u) died", pid);

    term->shutdown.client_has_terminated = true;
    term->shutdown.exit_status = status;

    if (term->shutdown.terminate_timeout_fd >= 0) {
        fdm_del(term->fdm, term->shutdown.terminate_timeout_fd);
        term->shutdown.terminate_timeout_fd = -1;
    }

    if (term->shutdown.in_progress)
        shutdown_maybe_done(term);
    else if (!term->conf->hold_at_exit)
        term_shutdown(term);
}

static bool
fdm_shutdown(struct fdm *fdm, int fd, int events, void *data)
{
    struct terminal *term = data;

    /* Kill the event FD */
    fdm_del(term->fdm, fd);

    wayl_win_destroy(term->window);
    term->window = NULL;

    struct wayland *wayl = term->wl;

    /*
     * Normally we'd get unmapped when we destroy the Wayland
     * above.
     *
     * However, it appears that under certain conditions, those events
     * are deferred (for example, when a screen locker is active), and
     * thus we can get here without having been unmapped.
     */
    tll_foreach(wayl->seats, it) {
        if (it->item.kbd_focus == term)
            it->item.kbd_focus = NULL;
        if (it->item.mouse_focus == term)
            it->item.mouse_focus = NULL;
    }

    shutdown_maybe_done(term);
    return true;
}

static bool
fdm_terminate_timeout(struct fdm *fdm, int fd, int events, void *data)
{
    uint64_t unused;
    ssize_t bytes = read(fd, &unused, sizeof(unused));
    if (bytes < 0) {
        LOG_ERRNO("failed to read from slave terminate timeout FD");
        return false;
    }

    struct terminal *term = data;
    xassert(!term->shutdown.client_has_terminated);

    LOG_DBG("slave (PID=%u) has not terminated, sending %s (%d)",
            term->slave,
            term->shutdown.next_signal == SIGTERM ? "SIGTERM"
                : term->shutdown.next_signal == SIGKILL ? "SIGKILL"
                    : "<unknown>",
            term->shutdown.next_signal);

    kill(-term->slave, term->shutdown.next_signal);

    switch (term->shutdown.next_signal) {
    case SIGTERM:
        term->shutdown.next_signal = SIGKILL;
        break;

    case SIGKILL:
        /* Disarm. Shouldn't be necessary, as we should be able to
           shutdown completely after sending SIGKILL, before the next
           timeout occurs). But lets play it safe... */
        if (term->shutdown.terminate_timeout_fd >= 0) {
            timerfd_settime(
                term->shutdown.terminate_timeout_fd, 0,
                &(const struct itimerspec){0}, NULL);
        }
        break;

    default:
        BUG("can only handle SIGTERM and SIGKILL");
        return false;
    }

    return true;
}

bool
term_shutdown(struct terminal *term)
{
    if (term->shutdown.in_progress)
        return true;

    term->shutdown.in_progress = true;

    /*
     * Close FDs then postpone self-destruction to the next poll
     * iteration, by creating an event FD that we trigger immediately.
     */

    term_cursor_blink_update(term);
    xassert(term->cursor_blink.fd < 0);

    fdm_del(term->fdm, term->selection.auto_scroll.fd);
    fdm_del(term->fdm, term->render.app_sync_updates.timer_fd);
    fdm_del(term->fdm, term->render.app_id.timer_fd);
    fdm_del(term->fdm, term->render.icon.timer_fd);
    fdm_del(term->fdm, term->render.title.timer_fd);
    fdm_del(term->fdm, term->delayed_render_timer.lower_fd);
    fdm_del(term->fdm, term->delayed_render_timer.upper_fd);
    fdm_del(term->fdm, term->blink.fd);
    fdm_del(term->fdm, term->flash.fd);

    del_utmp_record(term->conf, term->reaper, term->ptmx);

    if (term->window != NULL && term->window->is_configured)
        fdm_del(term->fdm, term->ptmx);
    else
        close(term->ptmx);

    if (!term->shutdown.client_has_terminated) {
        if (term->slave <= 0) {
            term->shutdown.client_has_terminated = true;
        } else {
            LOG_DBG("initiating asynchronous terminate of slave; "
                    "sending SIGHUP to PID=%u", term->slave);

            kill(-term->slave, SIGHUP);

            /*
             * Set up a timer, with an interval - on the first timeout
             * we'll send SIGTERM. If the the client application still
             * isn't terminating, we'll wait an additional interval,
             * and then send SIGKILL.
             */
            const struct itimerspec timeout = {.it_value = {.tv_sec = 30},
                                               .it_interval = {.tv_sec = 30}};

            int timeout_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
            if (timeout_fd < 0 ||
                timerfd_settime(timeout_fd, 0, &timeout, NULL) < 0 ||
                !fdm_add(term->fdm, timeout_fd, EPOLLIN, &fdm_terminate_timeout, term))
            {
                if (timeout_fd >= 0)
                    close(timeout_fd);
                LOG_ERRNO("failed to create slave terminate timeout FD");
                return false;
            }

            xassert(term->shutdown.terminate_timeout_fd < 0);
            term->shutdown.terminate_timeout_fd = timeout_fd;
            term->shutdown.next_signal = SIGTERM;
        }
    }

    term->selection.auto_scroll.fd = -1;
    term->render.app_sync_updates.timer_fd = -1;
    term->render.app_id.timer_fd = -1;
    term->render.icon.timer_fd = -1;
    term->render.title.timer_fd = -1;
    term->delayed_render_timer.lower_fd = -1;
    term->delayed_render_timer.upper_fd = -1;
    term->blink.fd = -1;
    term->flash.fd = -1;
    term->ptmx = -1;

    int event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (event_fd == -1) {
        LOG_ERRNO("failed to create terminal shutdown event FD");
        return false;
    }

    if (!fdm_add(term->fdm, event_fd, EPOLLIN, &fdm_shutdown, term)) {
        close(event_fd);
        return false;
    }

    if (write(event_fd, &(uint64_t){1}, sizeof(uint64_t)) != sizeof(uint64_t)) {
        LOG_ERRNO("failed to send terminal shutdown event");
        fdm_del(term->fdm, event_fd);
        return false;
    }

    return true;
}

static volatile sig_atomic_t alarm_raised;

static void
sig_alarm(int signo)
{
    LOG_DBG("SIGALRM");
    alarm_raised = 1;
}

int
term_destroy(struct terminal *term)
{
    if (term == NULL)
        return 0;

    tll_foreach(term->wl->terms, it) {
        if (it->item == term) {
            tll_remove(term->wl->terms, it);
            break;
        }
    }

    del_utmp_record(term->conf, term->reaper, term->ptmx);

    fdm_del(term->fdm, term->selection.auto_scroll.fd);
    fdm_del(term->fdm, term->render.app_sync_updates.timer_fd);
    fdm_del(term->fdm, term->render.app_id.timer_fd);
    fdm_del(term->fdm, term->render.icon.timer_fd);
    fdm_del(term->fdm, term->render.title.timer_fd);
    fdm_del(term->fdm, term->delayed_render_timer.lower_fd);
    fdm_del(term->fdm, term->delayed_render_timer.upper_fd);
    fdm_del(term->fdm, term->cursor_blink.fd);
    fdm_del(term->fdm, term->blink.fd);
    fdm_del(term->fdm, term->flash.fd);
    fdm_del(term->fdm, term->ptmx);
    if (term->shutdown.terminate_timeout_fd >= 0)
        fdm_del(term->fdm, term->shutdown.terminate_timeout_fd);

    if (term->window != NULL) {
        wayl_win_destroy(term->window);
        term->window = NULL;
    }

    mtx_lock(&term->render.workers.lock);
    xassert(tll_length(term->render.workers.queue) == 0);

    /* Count livinig threads - we may get here when only some of the
     * threads have been successfully started */
    size_t worker_count = 0;
    if (term->render.workers.threads != NULL) {
        for (size_t i = 0; i < term->render.workers.count; i++, worker_count++) {
            if (term->render.workers.threads[i] == 0)
                break;
        }

        for (size_t i = 0; i < worker_count; i++) {
            sem_post(&term->render.workers.start);
            tll_push_back(term->render.workers.queue, -2);
        }
    }
    mtx_unlock(&term->render.workers.lock);

    key_binding_unref(term->wl->key_binding_manager, term->conf);

    urls_reset(term);

    free(term->vt.osc.data);
    free(term->vt.osc8.uri);

    composed_free(term->composed);

    free(term->app_id);
    free(term->window_title);
    tll_free_and_free(term->window_title_stack, free);

    for (size_t i = 0; i < sizeof(term->fonts) / sizeof(term->fonts[0]); i++)
        fcft_destroy(term->fonts[i]);
    for (size_t i = 0; i < 4; i++)
        free(term->font_sizes[i]);


    free_custom_glyphs(
        &term->custom_glyphs.box_drawing, GLYPH_BOX_DRAWING_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.braille, GLYPH_BRAILLE_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.legacy, GLYPH_LEGACY_COUNT);
    free_custom_glyphs(
        &term->custom_glyphs.octants, GLYPH_OCTANTS_COUNT);

    free(term->search.buf);
    free(term->search.last.buf);

    if (term->render.workers.threads != NULL) {
        for (size_t i = 0; i < term->render.workers.count; i++) {
            if (term->render.workers.threads[i] != 0)
                thrd_join(term->render.workers.threads[i], NULL);
        }
    }
    free(term->render.workers.threads);
    mtx_destroy(&term->render.workers.preapplied_damage.lock);
    cnd_destroy(&term->render.workers.preapplied_damage.cond);
    mtx_destroy(&term->render.workers.lock);
    sem_destroy(&term->render.workers.start);
    sem_destroy(&term->render.workers.done);
    xassert(tll_length(term->render.workers.queue) == 0);
    tll_free(term->render.workers.queue);

    shm_unref(term->render.last_buf);
    shm_chain_free(term->render.chains.grid);
    shm_chain_free(term->render.chains.search);
    shm_chain_free(term->render.chains.scrollback_indicator);
    shm_chain_free(term->render.chains.render_timer);
    shm_chain_free(term->render.chains.url);
    shm_chain_free(term->render.chains.csd);
    shm_chain_free(term->render.chains.overlay);
    pixman_region32_fini(&term->render.last_overlay_clip);

    tll_free(term->tab_stops);

    tll_foreach(term->ptmx_buffers, it) {
        free(it->item.data);
        tll_remove(term->ptmx_buffers, it);
    }
    tll_foreach(term->ptmx_paste_buffers, it) {
        free(it->item.data);
        tll_remove(term->ptmx_paste_buffers, it);
    }

    notify_free(term, &term->kitty_notification);
    tll_foreach(term->active_notifications, it) {
        notify_free(term, &it->item);
        tll_remove(term->active_notifications, it);
    }

    for (size_t i = 0; i < ALEN(term->notification_icons); i++)
        notify_icon_free(&term->notification_icons[i]);

    sixel_fini(term);

    term_ime_reset(term);

    grid_free(&term->normal);
    grid_free(&term->alt);
    grid_free(term->interactive_resizing.grid);
    free(term->interactive_resizing.grid);

    free(term->foot_exe);
    free(term->cwd);
    free(term->mouse_user_cursor);
    free(term->color_stack.stack);

    for (int i = 0; i < term->argc; i++)
        free(term->argv[i]);
    free(term->argv);

    int ret = EXIT_SUCCESS;

    if (term->slave > 0) {
        /* We'll deal with this explicitly */
        reaper_del(term->reaper, term->slave);

        int exit_status;

        if (term->shutdown.client_has_terminated)
            exit_status = term->shutdown.exit_status;
        else {
            LOG_DBG("initiating blocking terminate of slave; "
                    "sending SIGHUP to PID=%u", term->slave);

            kill(-term->slave, SIGHUP);

            /*
             * we've closed the ptxm, and sent SIGTERM to the client
             * application. It *should* exit...
             *
             * But, since it is possible to write clients that ignore
             * this, we need to handle it in *some* way.
             *
             * So, what we do is register a SIGALRM handler, and configure a 30
             * second alarm. If the slave hasn't died after this time, we send
             * it a SIGKILL,
             *
             * Note that this solution is *not* asynchronous, and any
             * other events etc will be ignored during this time. This of
             * course only applies to a 'foot --server' instance, where
             * there might be other terminals running.
             */
            struct sigaction action = {.sa_handler = &sig_alarm};
            sigemptyset(&action.sa_mask);
            sigaction(SIGALRM, &action, NULL);

            /* Wait, then send SIGTERM, wait again, then send SIGKILL */
            int next_signal = SIGTERM;

            alarm_raised = 0;
            alarm(30);

            while (true) {
                int r = waitpid(term->slave, &exit_status, 0);

                if (r == term->slave)
                    break;

                if (r == -1) {
                    xassert(errno == EINTR);

                    if (alarm_raised) {
                        LOG_DBG("slave (PID=%u) has not terminated yet, "
                                "sending: %s (%d)", term->slave,
                                next_signal == SIGTERM ? "SIGTERM" : "SIGKILL",
                                next_signal);

                        kill(-term->slave, next_signal);
                        next_signal = SIGKILL;

                        alarm_raised = 0;
                        alarm(30);
                    }
                }
            }

            /* Cancel alarm */
            alarm(0);
            action.sa_handler = SIG_DFL;
            sigaction(SIGALRM, &action, NULL);
        }

        ret = EXIT_FAILURE;
        if (WIFEXITED(exit_status)) {
            ret = WEXITSTATUS(exit_status);
            LOG_DBG("slave exited with code %d", ret);
        } else if (WIFSIGNALED(exit_status)) {
            ret = WTERMSIG(exit_status);
            LOG_WARN("slave exited with signal %d (%s)", ret, strsignal(ret));
        } else {
            LOG_WARN("slave exited for unknown reason (status = 0x%08x)",
                     exit_status);
        }
    }

    free(term);

#if defined(__GLIBC__)
    if (!malloc_trim(0))
        LOG_WARN("failed to trim memory");
#endif

    return ret;
}

/* erase_cell_range/erase_line: ported to terminal.zig */
extern void erase_line(struct terminal *term, struct row *row);



/* term_theme_apply: ported to terminal.zig. Still called from term_reset()
 * (T11), hence the prototype. */
extern void term_theme_apply(struct terminal *term, const struct color_theme *theme);

void
term_reset(struct terminal *term, bool hard)
{
    LOG_INFO("%s resetting the terminal", hard ? "hard" : "soft");

    term->cursor_keys_mode = CURSOR_KEYS_NORMAL;
    term->keypad_keys_mode = KEYPAD_NUMERICAL;
    term->reverse = false;
    term->hide_cursor = false;
    term->reverse_wrap = true;
    term->auto_margin = true;
    term->insert_mode = false;
    term->bracketed_paste = false;
    term->focus_events = false;
    term->visibility_reports = false;
    term->num_lock_modifier = true;
    term->bell_action_enabled = true;
    term->mouse_tracking = MOUSE_NONE;
    term->mouse_reporting = MOUSE_NORMAL;
    term->charsets.selected = G0;
    term->charsets.set[G0] = CHARSET_ASCII;
    term->charsets.set[G1] = CHARSET_ASCII;
    term->charsets.set[G2] = CHARSET_ASCII;
    term->charsets.set[G3] = CHARSET_ASCII;
    term->saved_charsets = term->charsets;
    tll_free_and_free(term->window_title_stack, free);
    term_set_window_title(term, term->conf->title);
    term_set_app_id(term, NULL);

    term_set_user_mouse_cursor(term, NULL);

    term->modify_other_keys_2 = false;
    memset(term->normal.kitty_kbd.flags, 0, sizeof(term->normal.kitty_kbd.flags));
    memset(term->alt.kitty_kbd.flags, 0, sizeof(term->alt.kitty_kbd.flags));
    term->normal.kitty_kbd.idx = term->alt.kitty_kbd.idx = 0;

    term->scroll_region.start = 0;
    term->scroll_region.end = term->rows;

    free(term->vt.osc8.uri);
    free(term->vt.osc.data);

    term->vt = (struct vt){
        .state = 0,     /* STATE_GROUND */
    };

    if (term->grid == &term->alt) {
        term->grid = &term->normal;
        selection_cancel(term);
    }

    term->meta.esc_prefix = true;
    term->meta.eight_bit = true;

    tll_foreach(term->normal.sixel_images, it) {
        sixel_destroy(&it->item);
        tll_remove(term->normal.sixel_images, it);
    }
    tll_foreach(term->alt.sixel_images, it) {
        sixel_destroy(&it->item);
        tll_remove(term->alt.sixel_images, it);
    }

    notify_free(term, &term->kitty_notification);
    tll_foreach(term->active_notifications, it) {
        notify_free(term, &it->item);
        tll_remove(term->active_notifications, it);
    }

    for (size_t i = 0; i < ALEN(term->notification_icons); i++)
        notify_icon_free(&term->notification_icons[i]);

    term->grapheme_shaping = term->conf->tweak.grapheme_shaping;

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    term_ime_enable(term);
#endif

    term->bits_affecting_ascii_printer.value = 0;
    term_update_ascii_printer(term);

    if (!hard)
        return;

    const struct color_theme *theme = NULL;

    switch (term->conf->initial_color_theme) {
    case COLOR_THEME_DARK: theme = &term->conf->colors_dark; break;
    case COLOR_THEME_LIGHT: theme = &term->conf->colors_light; break;
    case COLOR_THEME_1: BUG("COLOR_THEME_1 should not be used"); break;
    case COLOR_THEME_2: BUG("COLOR_THEME_2 should not be used"); break;
    }

    term->flash.active = false;
    term->blink.state = BLINK_ON;
    fdm_del(term->fdm, term->blink.fd); term->blink.fd = -1;
    term_theme_apply(term, theme);
    term->colors.active_theme = term->conf->initial_color_theme;
    free(term->color_stack.stack);
    term->color_stack.stack = NULL;
    term->color_stack.size = 0;
    term->color_stack.idx = 0;
    term->origin = ORIGIN_ABSOLUTE;
    term->normal.cursor.lcf = false;
    term->alt.cursor.lcf = false;
    term->normal.cursor = (struct cursor){.point = {0, 0}};
    term->normal.saved_cursor = (struct cursor){.point = {0, 0}};
    term->alt.cursor = (struct cursor){.point = {0, 0}};
    term->alt.saved_cursor = (struct cursor){.point = {0, 0}};
    term->cursor_style = term->conf->cursor.style;
    term->cursor_blink.decset = false;
    term->cursor_blink.deccsusr = term->conf->cursor.blink.enabled;
    term_cursor_blink_update(term);
    selection_cancel(term);
    term->normal.offset = term->normal.view = 0;
    term->alt.offset = term->alt.view = 0;
    for (size_t i = 0; i < term->rows; i++) {
        struct row *r = grid_row_and_alloc(&term->normal, i);
        erase_line(term, r);
    }
    for (size_t i = 0; i < term->rows; i++) {
        struct row *r = grid_row_and_alloc(&term->alt, i);
        erase_line(term, r);
    }
    for (size_t i = term->rows; i < term->normal.num_rows; i++) {
        grid_row_free(term->normal.rows[i]);
        term->normal.rows[i] = NULL;
    }
    for (size_t i = term->rows; i < term->alt.num_rows; i++) {
        grid_row_free(term->alt.rows[i]);
        term->alt.rows[i] = NULL;
    }
    term->normal.cur_row = term->normal.rows[0];
    term->alt.cur_row = term->alt.rows[0];
    tll_free(term->normal.scroll_damage);
    tll_free(term->alt.scroll_damage);
    term->render.last_cursor.row = NULL;
    term_damage_all(term);

    term->sixel.scrolling = true;
    term->sixel.cursor_right_of_graphics = false;
    term->sixel.use_private_palette = true;
    term->sixel.max_width = SIXEL_MAX_WIDTH;
    term->sixel.max_height = SIXEL_MAX_HEIGHT;
    term->sixel.palette_size = SIXEL_MAX_COLORS;
    free(term->sixel.private_palette);
    free(term->sixel.shared_palette);
    term->sixel.private_palette = term->sixel.shared_palette = NULL;
}

static bool
term_font_size_adjust_by_points(struct terminal *term, float amount)
{
    const struct config *conf = term->conf;
    const float dpi = term->font_is_sized_by_dpi ? term->font_dpi : 96.;

    for (size_t i = 0; i < 4; i++) {
        const struct config_font_list *font_list = &conf->fonts[i];

        for (size_t j = 0; j < font_list->count; j++) {
            struct config_font *font = &term->font_sizes[i][j];
            float old_pt_size = font->pt_size;

            if (font->px_size > 0)
                old_pt_size = font->px_size * 72. / dpi;

            font->pt_size = fmaxf(old_pt_size + amount, 0.);
            font->px_size = -1;
        }
    }

    return reload_fonts(term, true);
}

static bool
term_font_size_adjust_by_pixels(struct terminal *term, int amount)
{
    const struct config *conf = term->conf;
    const float dpi = term->font_is_sized_by_dpi ? term->font_dpi : 96.;

    for (size_t i = 0; i < 4; i++) {
        const struct config_font_list *font_list = &conf->fonts[i];

        for (size_t j = 0; j < font_list->count; j++) {
            struct config_font *font = &term->font_sizes[i][j];
            int old_px_size = font->px_size;

            if (font->px_size <= 0)
                old_px_size = font->pt_size * dpi / 72.;

            font->px_size = max(old_px_size + amount, 1);
        }
    }

    return reload_fonts(term, true);
}

static bool
term_font_size_adjust_by_percent(struct terminal *term, bool increment, float percent)
{
    const struct config *conf = term->conf;
    const float multiplier = increment
        ? 1. + percent
        : 1. / (1. + percent);

    for (size_t i = 0; i < 4; i++) {
        const struct config_font_list *font_list = &conf->fonts[i];

        for (size_t j = 0; j < font_list->count; j++) {
            struct config_font *font = &term->font_sizes[i][j];

            if (font->px_size > 0)
                font->px_size = max(font->px_size * multiplier, 1);
            else
                font->pt_size = fmax(font->pt_size * multiplier, 0);
        }
    }

    return reload_fonts(term, true);
}

bool
term_font_size_increase(struct terminal *term)
{
    const struct config *conf = term->conf;
    const struct font_size_adjustment *inc_dec = &conf->font_size_adjustment;

    if (inc_dec->percent > 0.)
        return term_font_size_adjust_by_percent(term, true, inc_dec->percent);
    else if (inc_dec->pt_or_px.px > 0)
        return term_font_size_adjust_by_pixels(term, inc_dec->pt_or_px.px);
    else
        return term_font_size_adjust_by_points(term, inc_dec->pt_or_px.pt);
}

bool
term_font_size_decrease(struct terminal *term)
{
    const struct config *conf = term->conf;
    const struct font_size_adjustment *inc_dec = &conf->font_size_adjustment;

    if (inc_dec->percent > 0.)
        return term_font_size_adjust_by_percent(term, false, inc_dec->percent);
    else if (inc_dec->pt_or_px.px > 0)
        return term_font_size_adjust_by_pixels(term, -inc_dec->pt_or_px.px);
    else
        return term_font_size_adjust_by_points(term, -inc_dec->pt_or_px.pt);
}

bool
term_font_size_reset(struct terminal *term)
{
    return load_fonts_from_conf(term);
}

bool
term_fractional_scaling(const struct terminal *term)
{
    return term->wl->fractional_scale_manager != NULL &&
           term->wl->viewporter != NULL &&
           term->window->scale > 0.;
}

bool
term_preferred_buffer_scale(const struct terminal *term)
{
    return term->window->preferred_buffer_scale > 0;
}

bool
term_update_scale(struct terminal *term)
{
    const struct wl_window *win = term->window;

    /*
     * We have a number of "sources" we can use as scale. We choose
     * the scale in the following order:
     *
     *  - "preferred" scale, from the fractional-scale-v1 protocol
     *  - "preferred" scale, from wl_compositor version 6.
          NOTE: if the compositor advertises version 6 we must use 1.0
          until wl_surface.preferred_buffer_scale is sent
     *  - scaling factor of output we most recently were mapped on
     *  - if we're not mapped, use the last known scaling factor
     *  - if we're not mapped, and we don't have a last known scaling
     *    factor, use the scaling factor from the first available
     *    output.
     *  - if there aren't any outputs available, use 1.0
     */
    const float new_scale = (term_fractional_scaling(term)
        ? win->scale
        : term_preferred_buffer_scale(term)
            ? win->preferred_buffer_scale
            : tll_length(win->on_outputs) > 0
                ? tll_back(win->on_outputs)->scale
                : term->scale_before_unmap > 0.
                    ? term->scale_before_unmap
                    : tll_length(term->wl->monitors) > 0
                        ? tll_front(term->wl->monitors).scale
                        : 1.);

    if (new_scale == term->scale)
        return false;

    LOG_DBG("scaling factor changed: %.2f -> %.2f", term->scale, new_scale);
    term->scale_before_unmap = new_scale;
    term->scale = new_scale;
    return true;
}

bool
term_font_dpi_changed(struct terminal *term, float old_scale)
{
    float dpi = get_font_dpi(term);
    xassert(term->scale > 0.);

    bool was_scaled_using_dpi = term->font_is_sized_by_dpi;
    bool will_scale_using_dpi = term->conf->dpi_aware;

    bool need_font_reload =
        was_scaled_using_dpi != will_scale_using_dpi ||
        (will_scale_using_dpi
         ? term->font_dpi != dpi
         : old_scale != term->scale);

    if (need_font_reload) {
        LOG_DBG("DPI/scale change: DPI-aware=%s, "
                "DPI: %.2f -> %.2f, scale: %.2f -> %.2f, "
                "sizing font based on monitor's %s",
                term->conf->dpi_aware ? "yes" : "no",
                term->font_dpi, dpi, old_scale, term->scale,
                will_scale_using_dpi ? "DPI" : "scaling factor");
    }

    term->font_dpi = dpi;
    term->font_dpi_before_unmap = dpi;
    term->font_is_sized_by_dpi = will_scale_using_dpi;

    if (!need_font_reload)
        return false;

    return reload_fonts(term, false);
}

void
term_font_subpixel_changed(struct terminal *term)
{
    enum fcft_subpixel subpixel = get_font_subpixel(term);

    if (term->font_subpixel == subpixel)
        return;

#if defined(_DEBUG) && LOG_ENABLE_DBG
    static const char *const str[] = {
        [FCFT_SUBPIXEL_DEFAULT] = "default",
        [FCFT_SUBPIXEL_NONE] = "disabled",
        [FCFT_SUBPIXEL_HORIZONTAL_RGB] = "RGB",
        [FCFT_SUBPIXEL_HORIZONTAL_BGR] = "BGR",
        [FCFT_SUBPIXEL_VERTICAL_RGB] = "V-RGB",
        [FCFT_SUBPIXEL_VERTICAL_BGR] = "V-BGR",
    };

    LOG_DBG("subpixel mode changed: %s -> %s", str[term->font_subpixel], str[subpixel]);
#endif

    term->font_subpixel = subpixel;
    term_damage_view(term);
    render_refresh(term);
}

int
term_font_baseline(const struct terminal *term)
{
    const struct fcft_font *font = term->fonts[0];
    const int line_height = term->cell_height;
    const int font_height = font->ascent + font->descent;

    /*
     * Center glyph on the line *if* using a custom line height,
     * otherwise the baseline is simply 'descent' pixels above the
     * bottom of the cell
     */
    const int glyph_top_y = term->font_line_height.px >= 0
        ? round((line_height - font_height) / 2.)
        : 0;

    return term->font_y_ofs + line_height - glyph_top_y - font->descent;
}

/* term_erase: ported to terminal.zig */

/* term_erase_scrollback: ported to terminal.zig */

UNITTEST
{
    const int scrollback_rows = 16;
    const int term_rows = 5;
    const int cols = 5;

    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);

    struct terminal term = {
        .fdm = fdm,
        .rows = term_rows,
        .cols = cols,
        .normal = {
            .rows = xcalloc(scrollback_rows, sizeof(term.normal.rows[0])),
            .num_rows = scrollback_rows,
            .num_cols = cols,
        },
        .grid = &term.normal,
        .selection = {
            .coords = {
                .start = {-1, -1},
                .end = {-1, -1},
            },
            .kind = SELECTION_NONE,
            .auto_scroll = {
                .fd = -1,
            },
        },
    };

#define populate_scrollback() do {                                      \
        for (int i = 0; i < scrollback_rows; i++) {                     \
            if (term.normal.rows[i] == NULL) {                          \
                struct row *r = xcalloc(1, sizeof(*term.normal.rows[i])); \
                r->cells = xcalloc(cols, sizeof(r->cells[0]));          \
                term.normal.rows[i] = r;                                \
            }                                                           \
        }                                                               \
    } while (0)

    /*
     * Test case 1 - no selection, just verify all rows except those
     * on screen have been deleted.
     */

    populate_scrollback();
    term.normal.offset = 11;
    term_erase_scrollback(&term);
    for (int i = 0; i < scrollback_rows; i++) {
        if (i >= term.normal.offset && i < term.normal.offset + term_rows)
            xassert(term.normal.rows[i] != NULL);
        else
            xassert(term.normal.rows[i] == NULL);
    }

    /*
     * Test case 2 - selection that touches the scrollback. Verify the
     * selection is cancelled.
     */

    term.normal.offset = 14;  /* Screen covers rows 14,15,0,1,2 */

    /* Selection covers rows 15,0,1,2,3 */
    term.selection.coords.start = (struct coord){.row = 15};
    term.selection.coords.end = (struct coord){.row = 19};
    term.selection.kind = SELECTION_CHAR_WISE;

    populate_scrollback();
    term_erase_scrollback(&term);
    xassert(term.selection.coords.start.row < 0);
    xassert(term.selection.coords.end.row < 0);
    xassert(term.selection.kind == SELECTION_NONE);

    /*
     * Test case 3 - selection that does *not* touch the
     * scrollback. Verify the selection is *not* cancelled.
     */

    /* Selection covers rows 15,0 */
    term.selection.coords.start = (struct coord){.row = 15};
    term.selection.coords.end = (struct coord){.row = 16};
    term.selection.kind = SELECTION_CHAR_WISE;

    populate_scrollback();
    term_erase_scrollback(&term);
    xassert(term.selection.coords.start.row == 15);
    xassert(term.selection.coords.end.row == 16);
    xassert(term.selection.kind == SELECTION_CHAR_WISE);

    term.selection.coords.start = (struct coord){-1, -1};
    term.selection.coords.end = (struct coord){-1, -1};
    term.selection.kind = SELECTION_NONE;

    /*
     * Test case 4 - sixel that touch the scrollback
     */

    struct sixel six = {
        .rows = 5,
        .pos = {
            .row = 15,
        },
    };
    tll_push_back(term.normal.sixel_images, six);
    populate_scrollback();
    term_erase_scrollback(&term);
    xassert(tll_length(term.normal.sixel_images) == 0);

    /*
     * Test case 5 - sixel that does *not* touch the scrollback
     */
    six.rows = 3;
    tll_push_back(term.normal.sixel_images, six);
    populate_scrollback();
    term_erase_scrollback(&term);
    xassert(tll_length(term.normal.sixel_images) == 1);

    /* Cleanup */
    tll_free(term.normal.sixel_images);
    xassert(term.selection.auto_scroll.fd == -1);
    for (int i = 0; i < scrollback_rows; i++)
        grid_row_free(term.normal.rows[i]);
    free(term.normal.rows);
    fdm_destroy(fdm);
}
/* term_row_rel_to_abs: ported to terminal.zig */
/* cursor_blink_rearm_timer: ported to terminal.zig */
/* cursor_blink_disarm_timer: ported to terminal.zig */
/* term_cursor_blink_update: ported to terminal.zig */
/* selection_on_top_region: ported to terminal.zig */
/* selection_on_bottom_region: ported to terminal.zig */
/* term_scroll_partial: ported to terminal.zig */
/* term_scroll: ported to terminal.zig */
/* term_scroll_reverse_partial: ported to terminal.zig */
/* term_scroll_reverse: ported to terminal.zig */

/* term_linefeed: ported to terminal.zig */
/* term_reverse_index: ported to terminal.zig */





/* term_send_visibility_report: ported to terminal.zig */


/* term_kbd_focus_in: ported to terminal.zig */

void
term_kbd_focus_out(struct terminal *term)
{
    if (!term->kbd_focus)
        return;

    tll_foreach(term->wl->seats, it)
        if (it->item.kbd_focus == term)
            return;

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    if (term_ime_reset(term))
        render_refresh(term);
#endif

    term->kbd_focus = false;
    cursor_refresh(term);

    if (term->focus_events)
        term_to_slave(term, "\033[O", 3);
}

/* mouse reporting: ported to terminal.zig */







bool
term_mouse_grabbed(const struct terminal *term, const struct seat *seat)
{
    /*
     * Mouse is grabbed by us, regardless of whether mouse tracking
     * has been enabled or not.
     */

    xkb_mod_mask_t mods;
    get_current_modifiers(seat, &mods, NULL, 0, true);

    const struct key_binding_set *bindings =
        key_binding_for(term->wl->key_binding_manager, term->conf, seat);
    const xkb_mod_mask_t override_modmask = bindings->selection_overrides;
    bool override_mods_pressed = seat->kbd.xkb_keymap != NULL &&
        mods != 0 && (mods & override_modmask) == override_modmask;

    return term->mouse_tracking == MOUSE_NONE ||
        (seat->kbd_focus == term && override_mods_pressed);
}

/* term_mouse_down/up/motion: ported to terminal.zig */





void
term_xcursor_update_for_seat(struct terminal *term, struct seat *seat)
{
    enum cursor_shape shape = CURSOR_SHAPE_NONE;

    switch (term->active_surface) {
    case TERM_SURF_GRID:
        if (seat->pointer.hidden)
            shape = CURSOR_SHAPE_HIDDEN;

        else if (cursor_string_to_server_shape(
            term->mouse_user_cursor,
            term->wl->shape_manager_version) != 0 ||
                 render_xcursor_is_valid(seat, term->mouse_user_cursor))
        {
            shape = CURSOR_SHAPE_CUSTOM;
        }

        else if (term_mouse_grabbed(term, seat)) {
            shape = CURSOR_SHAPE_TEXT;
        }

        else
            shape = CURSOR_SHAPE_LEFT_PTR;
        break;

    case TERM_SURF_TITLE:
    case TERM_SURF_BUTTON_MINIMIZE:
    case TERM_SURF_BUTTON_MAXIMIZE:
    case TERM_SURF_BUTTON_CLOSE:
        shape = CURSOR_SHAPE_LEFT_PTR;
        break;

    case TERM_SURF_BORDER_LEFT:
    case TERM_SURF_BORDER_RIGHT:
    case TERM_SURF_BORDER_TOP:
    case TERM_SURF_BORDER_BOTTOM:
        shape = xcursor_for_csd_border(term, seat->mouse.x, seat->mouse.y);
        break;

    case TERM_SURF_NONE:
        return;
    }

    if (shape == CURSOR_SHAPE_NONE)
        BUG("xcursor not set");

    render_xcursor_set(seat, term, shape);
}

void
term_xcursor_update(struct terminal *term)
{
    tll_foreach(term->wl->seats, it)
        term_xcursor_update_for_seat(term, &it->item);
}

/* term_set_window_title: ported to terminal.zig */

/* term_set_app_id: ported to terminal.zig */

/* term_icon: ported to terminal.zig */

/* term_flash: ported to terminal.zig */

/* term_bell: ported to terminal.zig */

/* term_spawn_new: ported to terminal.zig */

/* term_enable_app_sync_updates: ported to terminal.zig */

/* term_disable_app_sync_updates: ported to terminal.zig */

/* print_linewrap/print_insert: ported to terminal.zig */



/* print_spacer: ported to terminal.zig */

/*
 * Puts a character on the grid. Coordinates are in screen coordinates
 * (i.e. ‘cursor’ coordinates).
 *
 * Does NOT:
 *  - update the cursor
 *  - linewrap
 *  - erase sixels
 *
 * Limitations:
 *   - double width characters not supported
 *//* term_fill: ported to terminal.zig */
/* term_print: ported to terminal.zig */
/* ascii_printer_generic: ported to terminal.zig */
/* ascii_printer_fast: ported to terminal.zig */
/* ascii_printer_single_shift: ported to terminal.zig */
/* term_update_ascii_printer: ported to terminal.zig */
/* term_single_shift: ported to terminal.zig */

#if defined(FOOT_GRAPHEME_CLUSTERING)

UNITTEST
{
    /* Verify the emoji_vs list is sorted */
    int64_t last_end = -1;

    for (size_t i = 0; i < sizeof(emoji_vs) / sizeof(emoji_vs[0]); i++) {
        const struct emoji_vs *vs = &emoji_vs[i];
        xassert(vs->start <= vs->end);
        xassert(vs->start > last_end);
        xassert(vs->vs15 || vs->vs16);
        last_end = vs->end;
    }
}
#endif
/* term_process_and_print_non_ascii: ported to terminal.zig */


enum term_surface
term_surface_kind(const struct terminal *term, const struct wl_surface *surface)
{
    if (likely(surface == term->window->surface.surf))
        return TERM_SURF_GRID;
    else if (surface == term->window->csd.surface[CSD_SURF_TITLE].surface.surf)
        return TERM_SURF_TITLE;
    else if (surface == term->window->csd.surface[CSD_SURF_LEFT].surface.surf)
        return TERM_SURF_BORDER_LEFT;
    else if (surface == term->window->csd.surface[CSD_SURF_RIGHT].surface.surf)
        return TERM_SURF_BORDER_RIGHT;
    else if (surface == term->window->csd.surface[CSD_SURF_TOP].surface.surf)
        return TERM_SURF_BORDER_TOP;
    else if (surface == term->window->csd.surface[CSD_SURF_BOTTOM].surface.surf)
        return TERM_SURF_BORDER_BOTTOM;
    else if (surface == term->window->csd.surface[CSD_SURF_MINIMIZE].surface.surf)
        return TERM_SURF_BUTTON_MINIMIZE;
    else if (surface == term->window->csd.surface[CSD_SURF_MAXIMIZE].surface.surf)
        return TERM_SURF_BUTTON_MAXIMIZE;
    else if (surface == term->window->csd.surface[CSD_SURF_CLOSE].surface.surf)
        return TERM_SURF_BUTTON_CLOSE;
    else
        return TERM_SURF_NONE;
}

/* rows_to_text, term_scrollback_to_text, term_view_to_text,
 * term_command_output_to_text: ported to terminal.zig */

bool
term_ime_is_enabled(const struct terminal *term)
{
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    return term->ime_enabled;
#else
    return false;
#endif
}

void
term_ime_enable(struct terminal *term)
{
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    if (term->ime_enabled)
        return;

    LOG_DBG("IME enabled");

    term->ime_enabled = true;

    /* IME is per seat - enable on all seat currently focusing us */
    tll_foreach(term->wl->seats, it) {
        if (it->item.kbd_focus == term)
            ime_enable(&it->item);
    }
#endif
}

void
term_ime_disable(struct terminal *term)
{
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    if (!term->ime_enabled)
        return;

    LOG_DBG("IME disabled");

    term->ime_enabled = false;

    /* IME is per seat - disable on all seat currently focusing us */
    tll_foreach(term->wl->seats, it) {
        if (it->item.kbd_focus == term)
            ime_disable(&it->item);
    }
#endif
}

bool
term_ime_reset(struct terminal *term)
{
    bool at_least_one_seat_was_reset = false;

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    tll_foreach(term->wl->seats, it) {
        struct seat *seat = &it->item;

        if (seat->kbd_focus != term)
            continue;

        ime_reset_preedit(seat);
        at_least_one_seat_was_reset = true;
    }
#endif

    return at_least_one_seat_was_reset;
}

void
term_ime_set_cursor_rect(struct terminal *term, int x, int y, int width,
                         int height)
{
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    tll_foreach(term->wl->seats, it) {
        if (it->item.kbd_focus == term) {
            it->item.ime.cursor_rect.pending.x = x;
            it->item.ime.cursor_rect.pending.y = y;
            it->item.ime.cursor_rect.pending.width = width;
            it->item.ime.cursor_rect.pending.height = height;
        }
    }
#endif
}

/* term_osc8_open/term_osc8_close: ported to terminal.zig */


/* term_set_user_mouse_cursor: ported to terminal.zig */

/* size notifications: ported to terminal.zig */

/* size notifications: ported to terminal.zig */

/* size notifications: ported to terminal.zig */

/* term_theme_switch_to_dark/light/toggle/get: ported to terminal.zig */
