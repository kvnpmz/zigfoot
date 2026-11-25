/* Zig shim for the terminal port.
 *
 * This file only holds what the Zig code cannot express yet:
 *
 *   1. C-only compile-time knowledge: object-like macros, sizeof/offsetof,
 *      #ifdef'd feature tests, and static inline wrappers around libc or
 *      wayland-client (wl_subsurface_set_sync(), c32width(), ...).
 *   2. Struct mirrors that have not landed yet: field reads of a struct that
 *      terminal_types.zig does not mirror. Delete these as soon as the struct
 *      is mirrored and pinned by the ABI probe (Track B).
 *   3. C-only types and varargs: regex_t, FILE, va_list forwarding.
 *
 * A function that no longer satisfies one of these must be deleted; the audit
 * rule and the current exemptions are documented in MIGRATION_PLAN.md 12.9.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <threads.h>
#include <sys/ioctl.h>
#include <wayland-cursor.h>
#include <regex.h>
#include <presentation-time.h>
#include <cursor-shape.h>
#include "render.h"
#include "macros.h"
#include <signal.h>
#include <pthread.h>
#include "terminal.h"
#include "url-mode.h"
#include "grid.h"
#include "wayland.h"
#include "shm.h"
#define LOG_MODULE "render"
#include "log.h"
#include "xmalloc.h"

/* ── struct seat kbd state (unicode-mode) ─────────────────────────── */

/* struct seat is wayland.h's business; unicode-mode.zig only reads one flag
 * and sets one keysym. */


/* MB_CUR_MAX is a C macro (it expands to a thread-local lookup). */
size_t terminal_shim_mb_cur_max(void) {
    return MB_CUR_MAX;
}


/* The null checks are defensive: in foot itself `window` is always set, but
 * the headless harness runs these paths without a wayland window. */


/* quirks.zig: the CSD subsurfaces the weston workaround walks. */




void quirk_shim_subsurface_set_desync(struct wl_subsurface *sub) {
    wl_subsurface_set_desync(sub);
}

void quirk_shim_subsurface_set_sync(struct wl_subsurface *sub) {
    wl_subsurface_set_sync(sub);
}

struct row *terminal_shim_grid_row_in_view(struct grid *grid, int row) {
    return grid_row_in_view(grid, row);
}

void terminal_shim_wl_surface_commit(struct wl_surface *surf) {
    wl_surface_commit(surf);
}

#include "grid.h"

struct row *terminal_shim_grid_row_and_alloc(struct grid *grid, int row_no) {
    return grid_row_and_alloc(grid, row_no);
}

int terminal_shim_grid_row_absolute(struct grid *grid, int row_no) {
    return grid_row_absolute(grid, row_no);
}

extern void erase_line(struct terminal *term, struct row *row);

void terminal_shim_erase_line(struct terminal *term, struct row *row) {
    erase_line(term, row);
}

struct row *terminal_shim_grid_row(struct grid *grid, int row_no) {
    return grid_row(grid, row_no);
}

void terminal_shim_term_reset_grapheme_state(struct terminal *term) {
    term_reset_grapheme_state(term);
}


/* ── term_process_and_print_non_ascii() support ──────────────────── */

#include <stdlib.h>

#include "emoji-variation-sequences.h"

/* The generated packed table is C data; terminal.zig owns the bsearch logic.
 * Scalar accessors avoid making Zig reproduce C bit-field allocation. */
size_t
terminal_shim_emoji_vs_count(void)
{
#if defined(FOOT_GRAPHEME_CLUSTERING)
    return sizeof(emoji_vs) / sizeof(emoji_vs[0]);
#else
    return 0;
#endif
}

void
terminal_shim_emoji_vs_get(size_t index, uint32_t *start, uint32_t *end,
                           bool *vs15, bool *vs16)
{
#if defined(FOOT_GRAPHEME_CLUSTERING)
    const struct emoji_vs *vs = &emoji_vs[index];
    *start = vs->start;
    *end = vs->end;
    *vs15 = vs->vs15;
    *vs16 = vs->vs16;
#else
    (void)index;
    (void)start;
    (void)end;
    (void)vs15;
    (void)vs16;
#endif
}


/* ── custom glyph freeing (terminal.zig) ─────────────────────────── */

/* fcft_glyph's layout is fcft's business; terminal.zig only needs pix. */
/* ── font metrics (terminal.zig) ─────────────────────────────────── */

/* struct fcft_font is fcft's business; terminal.zig only reads these four
 * values, so hand them over as a plain struct instead of mirroring it. */
struct terminal_font_metrics {
    int height;
    int descent;
    int ascent;
    int max_advance_x;
};

struct terminal_font_metrics
terminal_shim_fcft_font_metrics(const struct fcft_font *font)
{
    return (struct terminal_font_metrics){
        .height = font->height,
        .descent = font->descent,
        .ascent = font->ascent,
        .max_advance_x = font->max_advance.x,
    };
}

const char *terminal_shim_fcft_font_name(const struct fcft_font *font) {
    return font->name;
}

bool terminal_shim_fcft_font_antialias(const struct fcft_font *font) {
    return font->antialias;
}

int terminal_shim_fcft_font_ascent(const struct fcft_font *font) {
    return font->ascent;
}

int terminal_shim_fcft_font_descent(const struct fcft_font *font) {
    return font->descent;
}

int terminal_shim_fcft_font_underline_position(const struct fcft_font *font) {
    return font->underline.position;
}

int terminal_shim_fcft_font_underline_thickness(const struct fcft_font *font) {
    return font->underline.thickness;
}

int terminal_shim_fcft_font_strikeout_position(const struct fcft_font *font) {
    return font->strikeout.position;
}

int terminal_shim_fcft_font_strikeout_thickness(const struct fcft_font *font) {
    return font->strikeout.thickness;
}

/* ── render.zig (D3a/D3c) ──────────────────────────────────────────── */

/* pixman_region32_t is not mirrored in Zig; only union_rect() is needed. */
void render_shim_region_union_rect(
    pixman_region32_t *region, int x, int y, int width, int height)
{
    pixman_region32_union_rect(region, region, x, y, width, height);
}

/* Generated requests; wayland.zig owns their defensive null checks. */
void wayland_shim_surface_damage_buffer_request(
    struct wl_surface *surface, int x, int y, int width, int height)
{
    wl_surface_damage_buffer(surface, x, y, width, height);
}

void wayland_shim_subsurface_set_position_request(
    struct wl_subsurface *sub, int x, int y)
{
    wl_subsurface_set_position(sub, x, y);
}

int render_shim_fcft_font_max_advance_x(const struct fcft_font *font)
{
    return font->max_advance.x;
}

int render_shim_fcft_font_height(const struct fcft_font *font)
{
    return font->height;
}

/* fcft's text-run API is optional at runtime; wrap it so render.zig does
 * not have to mirror struct fcft_text_run. */
bool render_shim_fcft_has_text_run(void)
{
    return (fcft_capabilities() & FCFT_CAPABILITY_TEXT_RUN_SHAPING) != 0;
}

void *render_shim_fcft_text_run(
    struct fcft_font *font, size_t len, const uint32_t *text,
    enum fcft_subpixel subpixel,
    const struct fcft_glyph ***out_glyphs, size_t *out_count)
{
    struct fcft_text_run *run = fcft_rasterize_text_run_utf32(
        font, len, text, subpixel);

    if (run == NULL) {
        *out_glyphs = NULL;
        *out_count = 0;
        return NULL;
    }

    *out_glyphs = run->glyphs;
    *out_count = run->count;
    return run;
}

void render_shim_fcft_text_run_destroy(void *run)
{
    fcft_text_run_destroy(run);
}

void render_shim_clip_clear(pixman_image_t *pix)
{
    pixman_image_set_clip_region32(pix, NULL);
}

pixman_image_t *render_shim_solid_fill(const pixman_color_t *color)
{
    return pixman_image_create_solid_fill(color);
}


/* ── render.zig (D3l1: render worker thread) ────────────────────────── */

/* sigset_t and pthread_t are platform types; keep the two calls that need
 * them together. */
/* struct winsize + the ioctl() call itself (C-only varargs). */
int
render_shim_tiocswinsz(int ptmx, int rows, int cols, int xpixel, int ypixel)
{
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = xpixel,
        .ws_ypixel = ypixel,
    };
    return ioctl(ptmx, (unsigned int)TIOCSWINSZ, &ws);
}

void render_shim_block_all_signals(void)
{
    sigset_t mask;
    sigfillset(&mask);
    pthread_sigmask(SIG_SETMASK, &mask, NULL);
}

int render_shim_set_thread_name(const char *name)
{
    return pthread_setname_np(pthread_self(), name);
}

/* ── render.zig (D3j: overlay / IME preedit) ────────────────────────── */

/* The overlay's search path does set arithmetic on pixman regions. Keep the
 * type in C; Zig owns a 24-byte blob (same as Render.last_overlay_clip) and
 * calls these. */
void render_shim_region_init(pixman_region32_t *r)
{
    pixman_region32_init(r);
}

void render_shim_region_init_rect(
    pixman_region32_t *r, int x, int y, int width, int height)
{
    pixman_region32_init_rect(r, x, y, width, height);
}

void render_shim_region_fini(pixman_region32_t *r)
{
    pixman_region32_fini(r);
}

void render_shim_region_copy(
    pixman_region32_t *dst, const pixman_region32_t *src)
{
    pixman_region32_copy(dst, src);
}

void render_shim_region_clear(pixman_region32_t *r)
{
    pixman_region32_clear(r);
}

void render_shim_region_subtract(
    pixman_region32_t *dst, const pixman_region32_t *a,
    const pixman_region32_t *b)
{
    pixman_region32_subtract(dst, a, b);
}

void render_shim_region_union(
    pixman_region32_t *dst, const pixman_region32_t *a,
    const pixman_region32_t *b)
{
    pixman_region32_union(dst, a, b);
}

void render_shim_region_extents(
    const pixman_region32_t *r, pixman_box32_t *out)
{
    *out = *pixman_region32_extents(r);
}

/* pixman_region32_rectangles() returns a borrowed array of boxes. */
const pixman_box32_t *
render_shim_region_rectangles(pixman_region32_t *r, int *count)
{
    return pixman_region32_rectangles(r, count);
}

void render_shim_set_clip_region(
    pixman_image_t *pix, const pixman_region32_t *r)
{
    pixman_image_set_clip_region32(pix, r);
}


/* wp_presentation_feedback_destroy() is a generated static inline. */
void render_shim_presentation_feedback_destroy(
    struct wp_presentation_feedback *feedback)
{
    if (feedback == NULL)
        return;
    wp_presentation_feedback_destroy(feedback);
}

/* wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer() is a generated
 * static inline. */
struct wl_buffer *render_shim_single_pixel_buffer(
    struct wp_single_pixel_buffer_manager_v1 *manager,
    uint32_t r, uint32_t g, uint32_t b, uint32_t a)
{
    if (manager == NULL)
        return NULL;
    return wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
        manager, r, g, b, a);
}


void render_shim_image_unref(pixman_image_t *pix)
{
    pixman_image_unref(pix);
}

/* Sixel compositing needs an explicit operator and a source rect offset. */
void render_shim_composite_op(
    int op,
    pixman_image_t *src, pixman_image_t *mask, pixman_image_t *dest,
    int src_x, int src_y, int x, int y, int width, int height)
{
    pixman_image_composite32(
        (pixman_op_t)op, src, mask, dest,
        src_x, src_y, 0, 0, x, y, width, height);
}

void render_shim_composite(
    pixman_image_t *src, pixman_image_t *mask, pixman_image_t *dest,
    int x, int y, int width, int height)
{
    pixman_image_composite32(
        PIXMAN_OP_OVER, src, mask, dest, 0, 0, 0, 0, x, y, width, height);
}

/* term->render.workers.lock is a pthread mutex the worker threads share. */
void render_shim_workers_lock(struct terminal *term)
{
    mtx_lock(&term->render.workers.lock);
}

void render_shim_workers_unlock(struct terminal *term)
{
    mtx_unlock(&term->render.workers.lock);
}

/*
 * The curly underline is composited from two trapezoids. pixman_trapezoid_t
 * is a library type we would rather not mirror, so the geometry comes in
 * from Zig and the composite happens here.
 */
void render_shim_curly_underline(
    pixman_image_t *pix, const pixman_color_t *color,
    int x, int top, int bot, int half_x, int full_x, int th)
{
#define I(x) pixman_int_to_fixed(x)

    /* characters sit on top of the curlies */
    const pixman_trapezoid_t traps[] = {
        {
            I(top), I(bot),
            {{I(x), I(bot - th)}, {I(half_x), I(top - th)}},
            {{I(x), I(bot + th)}, {I(half_x), I(top + th)}},
        },
        {
            I(top), I(bot),
            {{I(half_x), I(top + th)}, {I(full_x), I(bot + th)}},
            {{I(half_x), I(top - th)}, {I(full_x), I(bot - th)}},
        },
    };

#undef I

    pixman_image_t *fill = pixman_image_create_solid_fill(color);
    pixman_composite_trapezoids(
        PIXMAN_OP_OVER, fill, pix, PIXMAN_a8, 0, 0, 0, 0,
        sizeof(traps) / sizeof(traps[0]), traps);
    pixman_image_unref(fill);
}

/* ── font loading (terminal.zig) ─────────────────────────────────── */

/* util.h's thrd_err_as_string() is a static inline switch, which Zig cannot
 * call; the render-worker error paths log through this. */
#include "util.h"
#include "char32.h"
#include "input.h"
const char *terminal_shim_thrd_err_as_string(int thrd_err)
{
    return thrd_err_as_string(thrd_err);
}

/* sys/wait.h's status macros cannot be expressed in Zig; keep the platform's
 * own encoding instead of hard-coding the Linux one. */
#include <sys/wait.h>
#include <fcntl.h>
int terminal_shim_wifexited(int status)
{
    return WIFEXITED(status);
}
int terminal_shim_wexitstatus(int status)
{
    return WEXITSTATUS(status);
}
int terminal_shim_wifsignaled(int status)
{
    return WIFSIGNALED(status);
}
int terminal_shim_wtermsig(int status)
{
    return WTERMSIG(status);
}

/* xdg-shell's xdg_toplevel_set_maximized()/set_fullscreen() are static
 * inlines in the generated protocol header. */
void terminal_shim_xdg_toplevel_set_maximized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_set_maximized(toplevel);
}
void terminal_shim_xdg_toplevel_set_fullscreen(struct xdg_toplevel *toplevel,
                                               struct wl_output *output)
{
    xdg_toplevel_set_fullscreen(toplevel, output);
}
void terminal_shim_xdg_toplevel_set_minimized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_set_minimized(toplevel);
}
void terminal_shim_xdg_toplevel_unset_maximized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_unset_maximized(toplevel);
}
void terminal_shim_xdg_toplevel_unset_fullscreen(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_unset_fullscreen(toplevel);
}
void terminal_shim_xdg_toplevel_move(struct xdg_toplevel *toplevel,
                                     struct wl_seat *seat, uint32_t serial)
{
    xdg_toplevel_move(toplevel, seat, serial);
}
void terminal_shim_xdg_toplevel_resize(struct xdg_toplevel *toplevel,
                                       struct wl_seat *seat, uint32_t serial,
                                       uint32_t edges)
{
    xdg_toplevel_resize(toplevel, seat, serial, edges);
}
void terminal_shim_xdg_toplevel_show_window_menu(struct xdg_toplevel *toplevel,
                                                 struct wl_seat *seat,
                                                 uint32_t serial, int x, int y)
{
    xdg_toplevel_show_window_menu(toplevel, seat, serial, x, y);
}
/* char32.h's comparison and predicate helpers are static inlines. */
int terminal_shim_c32ncmp(const char32_t *s1, const char32_t *s2, size_t n)
{
    return c32ncmp(s1, s2, n);
}
int terminal_shim_c32ncasecmp(const char32_t *s1, const char32_t *s2, size_t n)
{
    return c32ncasecmp(s1, s2, n);
}
bool terminal_shim_isc32print(char32_t c32)
{
    return isc32print(c32);
}
bool terminal_shim_isc32space(char32_t c32)
{
    return isc32space(c32);
}

bool terminal_shim_hasc32upper(const char32_t *s)
{
    return hasc32upper(s);
}

/* Generated-protocol static inlines (wayland.zig cannot see them). */
/* wayland.zig: window creation (D2i). */
void wayland_shim_region_add(
    struct wl_region *region, int32_t x, int32_t y, int32_t w, int32_t h)
{
    wl_region_add(region, x, y, w, h);
}

void wayland_shim_surface_set_opaque_region(
    struct wl_surface *surf, struct wl_region *region)
{
    wl_surface_set_opaque_region(surf, region);
}

void wayland_shim_set_blur_region(
    struct ext_background_effect_surface_v1 *effect, struct wl_region *region)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_surface_v1_set_blur_region(effect, region);
#else
    (void)effect;
    (void)region;
#endif
}

void *wayland_shim_activation_get_token(struct xdg_activation_v1 *activation)
{
    return xdg_activation_v1_get_activation_token(activation);
}

void wayland_shim_activation_token_set_serial(
    struct xdg_activation_token_v1 *token, uint32_t serial,
    struct wl_seat *seat)
{
    xdg_activation_token_v1_set_serial(token, serial, seat);
}

void wayland_shim_activation_token_set_surface(
    struct xdg_activation_token_v1 *token, struct wl_surface *surf)
{
    xdg_activation_token_v1_set_surface(token, surf);
}

void wayland_shim_activation_token_commit(
    struct xdg_activation_token_v1 *token)
{
    xdg_activation_token_v1_commit(token);
}

/* wayland.zig: seat setup/teardown (D2k). */
void *wayland_shim_data_device_manager_get_device(
    struct wl_data_device_manager *m, struct wl_seat *seat)
{
    return wl_data_device_manager_get_data_device(m, seat);
}

void *wayland_shim_primary_selection_device_manager_get_device(
    struct zwp_primary_selection_device_manager_v1 *m, struct wl_seat *seat)
{
    return zwp_primary_selection_device_manager_v1_get_device(m, seat);
}

void *wayland_shim_text_input_manager_get_text_input(
    struct zwp_text_input_manager_v3 *m, struct wl_seat *seat)
{
    return zwp_text_input_manager_v3_get_text_input(m, seat);
}

void wayland_shim_data_source_destroy(struct wl_data_source *src)
{
    wl_data_source_destroy(src);
}

void wayland_shim_data_offer_destroy(struct wl_data_offer *offer)
{
    wl_data_offer_destroy(offer);
}

void wayland_shim_data_device_release(struct wl_data_device *dev)
{
    wl_data_device_release(dev);
}

void wayland_shim_primary_selection_source_destroy(
    struct zwp_primary_selection_source_v1 *src)
{
    zwp_primary_selection_source_v1_destroy(src);
}

void wayland_shim_primary_selection_offer_destroy(
    struct zwp_primary_selection_offer_v1 *offer)
{
    zwp_primary_selection_offer_v1_destroy(offer);
}

void wayland_shim_primary_selection_device_destroy(
    struct zwp_primary_selection_device_v1 *dev)
{
    zwp_primary_selection_device_v1_destroy(dev);
}

void wayland_shim_cursor_shape_device_destroy(
    struct wp_cursor_shape_device_v1 *dev)
{
    wp_cursor_shape_device_v1_destroy(dev);
}

void wayland_shim_keyboard_release(struct wl_keyboard *kbd)
{
    wl_keyboard_release(kbd);
}

void wayland_shim_pointer_release(struct wl_pointer *pointer)
{
    wl_pointer_release(pointer);
}

void wayland_shim_touch_release(struct wl_touch *touch)
{
    wl_touch_release(touch);
}

void wayland_shim_text_input_destroy(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_destroy(ti);
}

/* selection.zig: `grid_row_in_view()` is a static inline in grid.h. */
struct row *selection_grid_row_in_view(struct grid *grid, int row_no)
{
    return grid_row_in_view(grid, row_no);
}

/* selection.zig (D5d-b2): the data-offer / data-source / primary-selection
 * request wrappers are generated static inlines, so they stay here. The
 * destroy wrappers are the wayland_shim_* ones above. */
#include "primary-selection-unstable-v1.h"

void *wayland_shim_data_source_create(struct wl_data_device_manager *manager)
{
    return wl_data_device_manager_create_data_source(manager);
}

void wayland_shim_data_source_offer(
    struct wl_data_source *source, const char *mime_type)
{
    wl_data_source_offer(source, mime_type);
}

void wayland_shim_data_device_set_selection(
    struct wl_data_device *dev, struct wl_data_source *source, uint32_t serial)
{
    wl_data_device_set_selection(dev, source, serial);
}

void *wayland_shim_primary_source_create(
    struct zwp_primary_selection_device_manager_v1 *manager)
{
    return zwp_primary_selection_device_manager_v1_create_source(manager);
}

void wayland_shim_primary_source_offer(
    struct zwp_primary_selection_source_v1 *source, const char *mime_type)
{
    zwp_primary_selection_source_v1_offer(source, mime_type);
}

void wayland_shim_primary_device_set_selection(
    struct zwp_primary_selection_device_v1 *dev,
    struct zwp_primary_selection_source_v1 *source, uint32_t serial)
{
    zwp_primary_selection_device_v1_set_selection(dev, source, serial);
}

void wayland_shim_data_offer_receive(
    struct wl_data_offer *offer, const char *mime_type, int32_t fd)
{
    wl_data_offer_receive(offer, mime_type, fd);
}

void wayland_shim_primary_offer_receive(
    struct zwp_primary_selection_offer_v1 *offer, const char *mime_type,
    int32_t fd)
{
    zwp_primary_selection_offer_v1_receive(offer, mime_type, fd);
}

void wayland_shim_data_offer_accept(
    struct wl_data_offer *offer, uint32_t serial, const char *mime_type)
{
    wl_data_offer_accept(offer, serial, mime_type);
}

void wayland_shim_data_offer_set_actions(
    struct wl_data_offer *offer, uint32_t actions, uint32_t preferred_action)
{
    wl_data_offer_set_actions(offer, actions, preferred_action);
}

void wayland_shim_data_offer_finish(struct wl_data_offer *offer)
{
    wl_data_offer_finish(offer);
}

/* url-mode.zig (D5c): regex_t's internals (re_nsub, regmatch_t) are
 * libc-specific, so extracting one match's spans stays here. Returns false on
 * REG_NOMATCH (or any regexec() error). */
bool url_shim_regex_match(const regex_t *preg, const char *str,
                          size_t *so0, size_t *eo0,
                          size_t *so1, size_t *eo1)
{
    const size_t nmatch = preg->re_nsub + 1;
    regmatch_t *matches = xmalloc(nmatch * sizeof(matches[0]));
    int r = regexec(preg, str, nmatch, matches, 0);
    bool matched = r == 0;
    if (matched) {
        *so0 = matches[0].rm_so;
        *eo0 = matches[0].rm_eo;
        *so1 = matches[1].rm_so;
        *eo1 = matches[1].rm_eo;
    }
    free(matches);
    return matched;
}

/* text-input-v3 requests are generated static inlines (ime.zig, D5b). */
void terminal_shim_text_input_enable(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_enable(ti);
}
void terminal_shim_text_input_disable(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_disable(ti);
}
void terminal_shim_text_input_commit(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_commit(ti);
}
void terminal_shim_text_input_set_content_type(
    struct zwp_text_input_v3 *ti, uint32_t hint, uint32_t purpose)
{
    zwp_text_input_v3_set_content_type(ti, hint, purpose);
}
void terminal_shim_text_input_set_cursor_rectangle(
    struct zwp_text_input_v3 *ti, int32_t x, int32_t y,
    int32_t width, int32_t height)
{
    zwp_text_input_v3_set_cursor_rectangle(ti, x, y, width, height);
}

void wayland_shim_seat_release(struct wl_seat *seat)
{
    wl_seat_release(seat);
}

/* Generated xdg-shell inlines: render_resize() sizes the CSD-decorated
 * toplevel in surface-logical coordinates. */
void
wayland_shim_xdg_toplevel_set_min_size(
    struct xdg_toplevel *toplevel, int width, int height)
{
    xdg_toplevel_set_min_size(toplevel, width, height);
}

void
wayland_shim_xdg_surface_set_window_geometry(
    struct xdg_surface *xdg_surface, int x, int y, int width, int height)
{
    xdg_surface_set_window_geometry(xdg_surface, x, y, width, height);
}

void wayland_shim_ack_configure(struct xdg_surface *xdg_surface, uint32_t serial)
{
    xdg_surface_ack_configure(xdg_surface, serial);
}

/* wayland.zig: wayl_init()/wayl_destroy() (D2k5). */
struct wl_registry *wayland_shim_display_get_registry(
    struct wl_display *display)
{
    return wl_display_get_registry(display);
}

/* wayland.zig: seat capabilities (D2k6). */
struct wl_keyboard *wayland_shim_seat_get_keyboard(struct wl_seat *seat)
{
    return wl_seat_get_keyboard(seat);
}

struct wl_pointer *wayland_shim_seat_get_pointer(struct wl_seat *seat)
{
    return wl_seat_get_pointer(seat);
}

struct wl_touch *wayland_shim_seat_get_touch(struct wl_seat *seat)
{
    return wl_seat_get_touch(seat);
}

struct wp_cursor_shape_device_v1 *wayland_shim_cursor_shape_get_pointer(
    struct wp_cursor_shape_manager_v1 *manager, struct wl_pointer *pointer)
{
    return wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
}

/* The protocol listener tables. The callbacks are Zig (input.zig); the
 * tables stay C-side, as they are plain structs of function pointers, and
 * wayland_shim_add_*_listener() below is what wayland.zig calls. */
const struct wl_keyboard_listener keyboard_listener = {
    .keymap = &keyboard_keymap,
    .enter = &keyboard_enter,
    .leave = &keyboard_leave,
    .key = &keyboard_key,
    .modifiers = &keyboard_modifiers,
    .repeat_info = &keyboard_repeat_info,
};

const struct wl_pointer_listener pointer_listener = {
    .enter = &wl_pointer_enter,
    .leave = &wl_pointer_leave,
    .motion = &wl_pointer_motion,
    .button = &wl_pointer_button,
    .axis = &wl_pointer_axis,
    .frame = &wl_pointer_frame,
    .axis_source = &wl_pointer_axis_source,
    .axis_stop = &wl_pointer_axis_stop,
    .axis_discrete = &wl_pointer_axis_discrete,
#if defined(WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
    .axis_value120 = &wl_pointer_axis_value120,
#endif
};

const struct wl_touch_listener touch_listener = {
    .down = wl_touch_down,
    .up = wl_touch_up,
    .motion = wl_touch_motion,
    .frame = wl_touch_frame,
    .cancel = wl_touch_cancel,
};

void wayland_shim_add_keyboard_listener(
    struct wl_keyboard *kbd, struct seat *seat)
{
    wl_keyboard_add_listener(kbd, &keyboard_listener, seat);
}

void wayland_shim_add_pointer_listener(
    struct wl_pointer *pointer, struct seat *seat)
{
    wl_pointer_add_listener(pointer, &pointer_listener, seat);
}

void wayland_shim_add_touch_listener(struct wl_touch *touch, struct seat *seat)
{
    wl_touch_add_listener(touch, &touch_listener, seat);
}

/* wayland.zig: registry globals (D2k7). The interface objects and the
 * listener tables are all static or generated C, so the names are matched
 * and the bind performed here, keyed by an integer the Zig side switches on. */
enum wayland_iface {
    WAYLAND_IFACE_NONE = 0,
    WAYLAND_IFACE_COMPOSITOR,
    WAYLAND_IFACE_SUBCOMPOSITOR,
    WAYLAND_IFACE_SHM,
    WAYLAND_IFACE_XDG_WM_BASE,
    WAYLAND_IFACE_XDG_DECORATION,
    WAYLAND_IFACE_SEAT,
    WAYLAND_IFACE_XDG_OUTPUT_MANAGER,
    WAYLAND_IFACE_OUTPUT,
    WAYLAND_IFACE_DATA_DEVICE_MANAGER,
    WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER,
    WAYLAND_IFACE_PRESENTATION,
    WAYLAND_IFACE_XDG_ACTIVATION,
    WAYLAND_IFACE_VIEWPORTER,
    WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER,
    WAYLAND_IFACE_CURSOR_SHAPE_MANAGER,
    WAYLAND_IFACE_SINGLE_PIXEL_MANAGER,
    WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER,
    WAYLAND_IFACE_SYSTEM_BELL,
    WAYLAND_IFACE_COLOR_MANAGER,
    WAYLAND_IFACE_FIXES,
    WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER,
    WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER,
    WAYLAND_IFACE_TEXT_INPUT_MANAGER,
};

int wayland_shim_iface_id(const char *interface)
{
    if (streq(interface, wl_compositor_interface.name))
        return WAYLAND_IFACE_COMPOSITOR;
    if (streq(interface, wl_subcompositor_interface.name))
        return WAYLAND_IFACE_SUBCOMPOSITOR;
    if (streq(interface, wl_shm_interface.name))
        return WAYLAND_IFACE_SHM;
    if (streq(interface, xdg_wm_base_interface.name))
        return WAYLAND_IFACE_XDG_WM_BASE;
    if (streq(interface, zxdg_decoration_manager_v1_interface.name))
        return WAYLAND_IFACE_XDG_DECORATION;
    if (streq(interface, wl_seat_interface.name))
        return WAYLAND_IFACE_SEAT;
    if (streq(interface, zxdg_output_manager_v1_interface.name))
        return WAYLAND_IFACE_XDG_OUTPUT_MANAGER;
    if (streq(interface, wl_output_interface.name))
        return WAYLAND_IFACE_OUTPUT;
    if (streq(interface, wl_data_device_manager_interface.name))
        return WAYLAND_IFACE_DATA_DEVICE_MANAGER;
    if (streq(interface, zwp_primary_selection_device_manager_v1_interface.name))
        return WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER;
    if (streq(interface, wp_presentation_interface.name))
        return WAYLAND_IFACE_PRESENTATION;
    if (streq(interface, xdg_activation_v1_interface.name))
        return WAYLAND_IFACE_XDG_ACTIVATION;
    if (streq(interface, wp_viewporter_interface.name))
        return WAYLAND_IFACE_VIEWPORTER;
    if (streq(interface, wp_fractional_scale_manager_v1_interface.name))
        return WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER;
    if (streq(interface, wp_cursor_shape_manager_v1_interface.name))
        return WAYLAND_IFACE_CURSOR_SHAPE_MANAGER;
    if (streq(interface, wp_single_pixel_buffer_manager_v1_interface.name))
        return WAYLAND_IFACE_SINGLE_PIXEL_MANAGER;
    if (streq(interface, xdg_toplevel_icon_manager_v1_interface.name))
        return WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER;
    if (streq(interface, xdg_system_bell_v1_interface.name))
        return WAYLAND_IFACE_SYSTEM_BELL;
    if (streq(interface, wp_color_manager_v1_interface.name))
        return WAYLAND_IFACE_COLOR_MANAGER;
#if defined(WL_FIXES_INTERFACE)
    if (streq(interface, wl_fixes_interface.name))
        return WAYLAND_IFACE_FIXES;
#endif
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    if (streq(interface, xdg_toplevel_tag_manager_v1_interface.name))
        return WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER;
#endif
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    if (streq(interface, ext_background_effect_manager_v1_interface.name))
        return WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER;
#endif
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    if (streq(interface, zwp_text_input_manager_v3_interface.name))
        return WAYLAND_IFACE_TEXT_INPUT_MANAGER;
#endif
    return WAYLAND_IFACE_NONE;
}

void *wayland_shim_registry_bind(
    struct wl_registry *registry, uint32_t name, int which, uint32_t version)
{
    switch (which) {
    case WAYLAND_IFACE_COMPOSITOR:
        return wl_registry_bind(
            registry, name, &wl_compositor_interface, version);
    case WAYLAND_IFACE_SUBCOMPOSITOR:
        return wl_registry_bind(
            registry, name, &wl_subcompositor_interface, version);
    case WAYLAND_IFACE_SHM:
        return wl_registry_bind(registry, name, &wl_shm_interface, version);
    case WAYLAND_IFACE_XDG_WM_BASE:
        return wl_registry_bind(registry, name, &xdg_wm_base_interface, version);
    case WAYLAND_IFACE_XDG_DECORATION:
        return wl_registry_bind(
            registry, name, &zxdg_decoration_manager_v1_interface, version);
    case WAYLAND_IFACE_SEAT:
        return wl_registry_bind(registry, name, &wl_seat_interface, version);
    case WAYLAND_IFACE_XDG_OUTPUT_MANAGER:
        return wl_registry_bind(
            registry, name, &zxdg_output_manager_v1_interface, version);
    case WAYLAND_IFACE_OUTPUT:
        return wl_registry_bind(registry, name, &wl_output_interface, version);
    case WAYLAND_IFACE_DATA_DEVICE_MANAGER:
        return wl_registry_bind(
            registry, name, &wl_data_device_manager_interface, version);
    case WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER:
        return wl_registry_bind(
            registry, name, &zwp_primary_selection_device_manager_v1_interface,
            version);
    case WAYLAND_IFACE_PRESENTATION:
        return wl_registry_bind(
            registry, name, &wp_presentation_interface, version);
    case WAYLAND_IFACE_XDG_ACTIVATION:
        return wl_registry_bind(
            registry, name, &xdg_activation_v1_interface, version);
    case WAYLAND_IFACE_VIEWPORTER:
        return wl_registry_bind(
            registry, name, &wp_viewporter_interface, version);
    case WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_fractional_scale_manager_v1_interface, version);
    case WAYLAND_IFACE_CURSOR_SHAPE_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_cursor_shape_manager_v1_interface, version);
    case WAYLAND_IFACE_SINGLE_PIXEL_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_single_pixel_buffer_manager_v1_interface,
            version);
    case WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER:
        return wl_registry_bind(
            registry, name, &xdg_toplevel_icon_manager_v1_interface, version);
    case WAYLAND_IFACE_SYSTEM_BELL:
        return wl_registry_bind(
            registry, name, &xdg_system_bell_v1_interface, version);
    case WAYLAND_IFACE_COLOR_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_color_manager_v1_interface, version);
#if defined(WL_FIXES_INTERFACE)
    case WAYLAND_IFACE_FIXES:
        return wl_registry_bind(registry, name, &wl_fixes_interface, version);
#endif
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    case WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER:
        return wl_registry_bind(
            registry, name, &xdg_toplevel_tag_manager_v1_interface, version);
#endif
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    case WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER:
        return wl_registry_bind(
            registry, name, &ext_background_effect_manager_v1_interface,
            version);
#endif
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    case WAYLAND_IFACE_TEXT_INPUT_MANAGER:
        return wl_registry_bind(
            registry, name, &zwp_text_input_manager_v3_interface, version);
#endif
    }
    return NULL;
}

void *wayland_shim_get_xdg_output(struct zxdg_output_manager_v1 *manager,
                                  struct wl_output *output)
{
    return zxdg_output_manager_v1_get_xdg_output(manager, output);
}

bool wayland_shim_fdm_add_repeat(struct fdm *fdm, struct seat *seat);

/* wayland.zig: colour management (D2k8). */
void *wayland_shim_color_create_parametric_creator(
    struct wp_color_manager_v1 *manager)
{
    return wp_color_manager_v1_create_parametric_creator(manager);
}

void wayland_shim_color_params_set_tf_named(
    struct wp_image_description_creator_params_v1 *params, uint32_t tf)
{
    wp_image_description_creator_params_v1_set_tf_named(params, tf);
}

void wayland_shim_color_params_set_primaries_named(
    struct wp_image_description_creator_params_v1 *params, uint32_t primaries)
{
    wp_image_description_creator_params_v1_set_primaries_named(params, primaries);
}

void *wayland_shim_color_params_create(
    struct wp_image_description_creator_params_v1 *params)
{
    return wp_image_description_creator_params_v1_create(params);
}

void wayland_shim_wm_base_pong(struct xdg_wm_base *shell, uint32_t serial)
{
    xdg_wm_base_pong(shell, serial);
}

void wayland_shim_fixes_ack_global_remove(
    struct wl_fixes *fixes, struct wl_registry *registry, uint32_t name)
{
#if defined(WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION)
    wl_fixes_ack_global_remove(fixes, registry, name);
#else
    (void)fixes;
    (void)registry;
    (void)name;
#endif
}


int wayland_shim_fcntl_getfl(int fd)
{
    return fcntl(fd, F_GETFL);
}

int wayland_shim_fcntl_setfl(int fd, int flags)
{
    return fcntl(fd, F_SETFL, flags);
}

void wayland_shim_text_input_manager_destroy(struct zwp_text_input_manager_v3 *m)
{
    zwp_text_input_manager_v3_destroy(m);
}

void wayland_shim_toplevel_tag_manager_destroy(
    struct xdg_toplevel_tag_manager_v1 *m)
{
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    xdg_toplevel_tag_manager_v1_destroy(m);
#else
    (void)m;
#endif
}

void wayland_shim_background_effect_manager_destroy(
    struct ext_background_effect_manager_v1 *m)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_manager_v1_destroy(m);
#else
    (void)m;
#endif
}

void wayland_shim_image_description_destroy(
    struct wp_image_description_v1 *desc)
{
    wp_image_description_v1_destroy(desc);
}

void wayland_shim_color_manager_destroy(struct wp_color_manager_v1 *m)
{
    wp_color_manager_v1_destroy(m);
}

void wayland_shim_system_bell_destroy(struct xdg_system_bell_v1 *bell)
{
    xdg_system_bell_v1_destroy(bell);
}

void wayland_shim_toplevel_icon_manager_destroy(
    struct xdg_toplevel_icon_manager_v1 *m)
{
    xdg_toplevel_icon_manager_v1_destroy(m);
}

void wayland_shim_single_pixel_manager_destroy(
    struct wp_single_pixel_buffer_manager_v1 *m)
{
    wp_single_pixel_buffer_manager_v1_destroy(m);
}

void wayland_shim_fractional_scale_manager_destroy(
    struct wp_fractional_scale_manager_v1 *m)
{
    wp_fractional_scale_manager_v1_destroy(m);
}

void wayland_shim_viewporter_destroy(struct wp_viewporter *viewporter)
{
    wp_viewporter_destroy(viewporter);
}

void wayland_shim_cursor_shape_manager_destroy(
    struct wp_cursor_shape_manager_v1 *m)
{
    wp_cursor_shape_manager_v1_destroy(m);
}

void wayland_shim_activation_destroy(struct xdg_activation_v1 *activation)
{
    xdg_activation_v1_destroy(activation);
}

void wayland_shim_output_manager_destroy(struct zxdg_output_manager_v1 *m)
{
    zxdg_output_manager_v1_destroy(m);
}

void wayland_shim_wm_base_destroy(struct xdg_wm_base *shell)
{
    xdg_wm_base_destroy(shell);
}

void wayland_shim_decoration_manager_destroy(
    struct zxdg_decoration_manager_v1 *m)
{
    zxdg_decoration_manager_v1_destroy(m);
}

void wayland_shim_presentation_destroy(struct wp_presentation *presentation)
{
    wp_presentation_destroy(presentation);
}

void wayland_shim_data_device_manager_destroy(
    struct wl_data_device_manager *m)
{
    wl_data_device_manager_destroy(m);
}

void wayland_shim_primary_selection_device_manager_destroy(
    struct zwp_primary_selection_device_manager_v1 *m)
{
    zwp_primary_selection_device_manager_v1_destroy(m);
}

void wayland_shim_shm_destroy(struct wl_shm *shm, bool use_release)
{
#if defined(WL_SHM_RELEASE_SINCE_VERSION)
    if (use_release) {
        wl_shm_release(shm);
        return;
    }
#else
    (void)use_release;
#endif
    wl_shm_destroy(shm);
}

void wayland_shim_subcompositor_destroy(struct wl_subcompositor *sub_compositor)
{
    wl_subcompositor_destroy(sub_compositor);
}

void wayland_shim_compositor_destroy(struct wl_compositor *compositor)
{
    wl_compositor_destroy(compositor);
}

void wayland_shim_fixes_destroy(struct wl_fixes *fixes)
{
#if defined(WL_FIXES_INTERFACE)
    wl_fixes_destroy(fixes);
#else
    (void)fixes;
#endif
}

void wayland_shim_registry_destroy(struct wl_registry *registry)
{
    wl_registry_destroy(registry);
}


void *wayland_shim_fractional_scale_get(struct wp_fractional_scale_manager_v1 *m,
                                        struct wl_surface *surf)
{
    return wp_fractional_scale_manager_v1_get_fractional_scale(m, surf);
}

void *wayland_shim_background_effect_get(
    struct ext_background_effect_manager_v1 *m, struct wl_surface *surf)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    return ext_background_effect_manager_v1_get_background_effect(m, surf);
#else
    (void)m;
    (void)surf;
    return NULL;
#endif
}

void *wayland_shim_xdg_wm_base_get_xdg_surface(
    struct xdg_wm_base *shell, struct wl_surface *surf)
{
    return xdg_wm_base_get_xdg_surface(shell, surf);
}

void *wayland_shim_xdg_surface_get_toplevel(struct xdg_surface *xdg_surface)
{
    return xdg_surface_get_toplevel(xdg_surface);
}

void wayland_shim_xdg_toplevel_set_app_id(
    struct xdg_toplevel *toplevel, const char *app_id)
{
    xdg_toplevel_set_app_id(toplevel, app_id);
}

void wayland_shim_toplevel_tag_set(
    struct xdg_toplevel_tag_manager_v1 *m, struct xdg_toplevel *toplevel,
    const char *tag)
{
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    xdg_toplevel_tag_manager_v1_set_toplevel_tag(m, toplevel, tag);
    /* TODO: the description is recommended to be the tag, but translated */
    xdg_toplevel_tag_manager_v1_set_toplevel_description(m, toplevel, tag);
#else
    (void)m;
    (void)toplevel;
    (void)tag;
#endif
}

/* Generated requests; wayland.zig preserves the create/set/destroy order. */
struct xdg_toplevel_icon_v1 *
wayland_shim_toplevel_icon_manager_create_icon(
    struct xdg_toplevel_icon_manager_v1 *m)
{
    return xdg_toplevel_icon_manager_v1_create_icon(m);
}

void wayland_shim_toplevel_icon_set_name(
    struct xdg_toplevel_icon_v1 *icon, const char *name)
{
    xdg_toplevel_icon_v1_set_name(icon, name);
}

void wayland_shim_toplevel_icon_manager_set_icon(
    struct xdg_toplevel_icon_manager_v1 *m, struct xdg_toplevel *toplevel,
    struct xdg_toplevel_icon_v1 *icon)
{
    xdg_toplevel_icon_manager_v1_set_icon(m, toplevel, icon);
}

void wayland_shim_toplevel_icon_destroy(struct xdg_toplevel_icon_v1 *icon)
{
    xdg_toplevel_icon_v1_destroy(icon);
}

void *wayland_shim_decoration_get(
    struct zxdg_decoration_manager_v1 *m, struct xdg_toplevel *toplevel)
{
    return zxdg_decoration_manager_v1_get_toplevel_decoration(m, toplevel);
}

void wayland_shim_decoration_set_mode(void *decoration, uint32_t mode)
{
    zxdg_toplevel_decoration_v1_set_mode(decoration, mode);
}

void wayland_shim_surface_attach(
    struct wl_surface *surf, struct wl_buffer *buffer, int32_t x, int32_t y)
{
    if (surf == NULL)
        return;
    wl_surface_attach(surf, buffer, x, y);
}

void wayland_shim_surface_commit(struct wl_surface *surf)
{
    if (surf == NULL)
        return;
    wl_surface_commit(surf);
}

void *wayland_shim_surface_get_user_data(struct wl_surface *surf)
{
    return wl_surface_get_user_data(surf);
}

void wayland_shim_wl_callback_destroy(struct wl_callback *callback)
{
    wl_callback_destroy(callback);
}

void wayland_shim_xdg_surface_destroy(struct xdg_surface *xdg_surface)
{
    xdg_surface_destroy(xdg_surface);
}

void wayland_shim_xdg_toplevel_destroy(struct xdg_toplevel *xdg_toplevel)
{
    xdg_toplevel_destroy(xdg_toplevel);
}

void wayland_shim_xdg_toplevel_decoration_destroy(
    struct zxdg_toplevel_decoration_v1 *decoration)
{
    zxdg_toplevel_decoration_v1_destroy(decoration);
}

void wayland_shim_fractional_scale_destroy(
    struct wp_fractional_scale_v1 *scale)
{
    wp_fractional_scale_v1_destroy(scale);
}

void wayland_shim_destroy_background_effect(
    struct ext_background_effect_surface_v1 *effect)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_surface_v1_destroy(effect);
#else
    (void)effect;
#endif
}

void wayland_shim_xdg_activation_token_destroy(
    struct xdg_activation_token_v1 *token)
{
    xdg_activation_token_v1_destroy(token);
}

void wayland_shim_zxdg_output_destroy(struct zxdg_output_v1 *xdg_output)
{
    zxdg_output_v1_destroy(xdg_output);
}

void wayland_shim_wl_output_destroy(struct wl_output *output)
{
    wl_output_destroy(output);
}

void wayland_shim_wl_output_release(struct wl_output *output)
{
    wl_output_release(output);
}

struct wl_surface *wayland_shim_compositor_create_surface(
    struct wl_compositor *compositor)
{
    return wl_compositor_create_surface(compositor);
}

struct wl_region *wayland_shim_compositor_create_region(
    struct wl_compositor *compositor)
{
    return wl_compositor_create_region(compositor);
}

struct wl_subsurface *wayland_shim_subcompositor_get_subsurface(
    struct wl_subcompositor *subcompositor, struct wl_surface *surface,
    struct wl_surface *parent)
{
    return wl_subcompositor_get_subsurface(subcompositor, surface, parent);
}

struct wp_viewport *wayland_shim_viewporter_get_viewport(
    struct wp_viewporter *viewporter, struct wl_surface *surface)
{
    return wp_viewporter_get_viewport(viewporter, surface);
}

struct wp_color_management_surface_v1 *wayland_shim_color_manager_get_surface(
    struct wp_color_manager_v1 *manager, struct wl_surface *surface)
{
    return wp_color_manager_v1_get_surface(manager, surface);
}

void wayland_shim_color_management_set_image_description(
    struct wp_color_management_surface_v1 *cm_surface,
    struct wp_image_description_v1 *img, uint32_t intent)
{
    wp_color_management_surface_v1_set_image_description(
        cm_surface, img, intent);
}

void wayland_shim_color_management_surface_destroy(
    struct wp_color_management_surface_v1 *cm_surface)
{
    wp_color_management_surface_v1_destroy(cm_surface);
}

void wayland_shim_surface_destroy(struct wl_surface *surf)
{
    wl_surface_destroy(surf);
}

void wayland_shim_surface_set_user_data(struct wl_surface *surf, void *data)
{
    wl_surface_set_user_data(surf, data);
}

void wayland_shim_surface_set_input_region(
    struct wl_surface *surf, struct wl_region *region)
{
    wl_surface_set_input_region(surf, region);
}

void wayland_shim_region_destroy(struct wl_region *region)
{
    wl_region_destroy(region);
}

void wayland_shim_subsurface_destroy(struct wl_subsurface *sub)
{
    wl_subsurface_destroy(sub);
}

void wayland_shim_viewport_destroy(struct wp_viewport *viewport)
{
    wp_viewport_destroy(viewport);
}

void wayland_shim_xdg_system_bell_ring(
    struct xdg_system_bell_v1 *bell, struct wl_surface *surface)
{
    xdg_system_bell_v1_ring(bell, surface);
}

void wayland_shim_xdg_activation_activate(
    struct xdg_activation_v1 *activation, const char *token,
    struct wl_surface *surface)
{
    xdg_activation_v1_activate(activation, token, surface);
}

void wayland_shim_surface_set_buffer_scale(struct wl_surface *surf, int32_t scale)
{
    if (surf == NULL)
        return;
    wl_surface_set_buffer_scale(surf, scale);
}

void wayland_shim_viewport_set_destination(
    struct wp_viewport *viewport, int32_t width, int32_t height)
{
    wp_viewport_set_destination(viewport, width, height);
}

/* grid.h's grid_row_absolute_in_view() is a static inline. */
int terminal_shim_grid_row_absolute_in_view(const struct grid *grid, int row_no)
{
    return grid_row_absolute_in_view(grid, row_no);
}

/* ======================================================================
 * The last of render.c (D3l4). The exit-time presentation logger keeps C's
 * DESTRUCTOR attribute; its counters and the context allocation are in
 * render.zig. Protocol listener tables remain generated-struct knowledge.
 * ====================================================================== */

void fdm_hook_refresh_pending_terminals(struct fdm *fdm, void *data);

/* render_init()/render_destroy() are in render.zig (D3k1). */

static void DESTRUCTOR
log_presentation_statistics(void)
{
    size_t total, zero, one, two;
    render_shim_presentation_stat_get(&total, &zero, &one, &two);

    if (total == 0)
        return;

    LOG_INFO("presentation statistics: zero=%f%%, one=%f%%, two=%f%%",
             100. * zero / total,
             100. * one / total,
             100. * two / total);
}

/* Ported to render.zig: the callbacks, not the tables. */
void sync_output(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback,
    struct wl_output *output);
void presented(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback,
    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec,
    uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags);
void discarded(
    void *data, struct wp_presentation_feedback *wp_presentation_feedback);

static const struct wp_presentation_feedback_listener presentation_feedback_listener = {
    .sync_output = &sync_output,
    .presented = &presented,
    .discarded = &discarded,
};

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

void frame_callback(
    void *data, struct wl_callback *wl_callback, uint32_t callback_data);

static const struct wl_callback_listener frame_listener = {
    .done = &frame_callback,
};

struct wl_callback *
render_shim_add_frame_callback(struct wl_surface *surf, void *data)
{
    struct wl_callback *callback = wl_surface_frame(surf);
    wl_callback_add_listener(callback, &frame_listener, data);
    return callback;
}

void xcursor_callback(
    void *data, struct wl_callback *wl_callback, uint32_t callback_data);

static const struct wl_callback_listener xcursor_listener = {
    .done = &xcursor_callback,
};

struct wl_callback *
render_shim_add_xcursor_callback(struct wl_surface *surf, void *data)
{
    struct wl_callback *callback = wl_surface_frame(surf);
    wl_callback_add_listener(callback, &xcursor_listener, data);
    return callback;
}

/* Cursor handling: wayland-cursor and the cursor-shape-v1 inlines. */
void *
render_shim_cursor_theme_get_cursor(void *theme, const char *name)
{
    return wl_cursor_theme_get_cursor(theme, name);
}

bool
render_shim_cursor_image_0(
    void *cursor, int32_t *width, int32_t *height,
    int32_t *hotspot_x, int32_t *hotspot_y)
{
    struct wl_cursor *c = cursor;
    if (c == NULL || c->image_count == 0)
        return false;

    const struct wl_cursor_image *image = c->images[0];
    *width = image->width;
    *height = image->height;
    *hotspot_x = image->hotspot_x;
    *hotspot_y = image->hotspot_y;
    return true;
}

void *
render_shim_cursor_image_0_buffer(void *cursor)
{
    struct wl_cursor *c = cursor;
    if (c == NULL || c->image_count == 0)
        return NULL;
    return wl_cursor_image_get_buffer(c->images[0]);
}

void
render_shim_pointer_set_cursor(
    struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface,
    int32_t hotspot_x, int32_t hotspot_y)
{
    wl_pointer_set_cursor(pointer, serial, surface, hotspot_x, hotspot_y);
}

void
render_shim_cursor_shape_device_v1_set_shape(
    struct wp_cursor_shape_device_v1 *device, uint32_t serial, uint32_t shape)
{
    wp_cursor_shape_device_v1_set_shape(device, serial, shape);
}

void
render_shim_xdg_toplevel_set_title(struct xdg_toplevel *toplevel, const char *title)
{
    xdg_toplevel_set_title(toplevel, title);
}

void
render_shim_callback_destroy(struct wl_callback *callback)
{
    if (callback != NULL)
        wl_callback_destroy(callback);
}
