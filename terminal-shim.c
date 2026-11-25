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
#include "terminal.h"
#include "url-mode.h"
#include "grid.h"
#include "wayland.h"
#include "shm.h"

/* ── struct seat kbd state (unicode-mode) ─────────────────────────── */

/* struct seat is wayland.h's business; unicode-mode.zig only reads one flag
 * and sets one keysym. */


/* MB_CUR_MAX is a C macro (it expands to a thread-local lookup). */
size_t terminal_shim_mb_cur_max(void) {
    return MB_CUR_MAX;
}


/* urls_mode_is_active() is static inline in url-mode.h. */
bool terminal_shim_urls_mode_active(const struct terminal *term) {
    return urls_mode_is_active(term);
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

uint32_t
terminal_shim_precompose(struct terminal *term, uint32_t base, uint32_t wc,
                         bool *base_from_primary,
                         bool *comb_from_primary,
                         bool *pre_from_primary)
{
    if (term->fonts[0] == NULL) {
        *base_from_primary = false;
        *comb_from_primary = false;
        *pre_from_primary = false;
        return (uint32_t)-1;
    }

    return fcft_precompose(
        term->fonts[0], base, wc,
        base_from_primary, comb_from_primary, pre_from_primary);
}

#if defined(FOOT_GRAPHEME_CLUSTERING)
static int
emoji_vs_compare(const void *_key, const void *_entry)
{
    const struct emoji_vs *key = _key;
    const struct emoji_vs *entry = _entry;

    uint32_t cp = key->start;

    if (cp < entry->start)
        return -1;
    else if (cp > entry->end)
        return 1;
    else
        return 0;
}
#endif

/*
 * Returns the forced grapheme width for a VS-15 (1) / VS-16 (2)
 * variation selector sequence, or -1 if the base character isn't in the
 * table (or isn't followed by a supported variation selector).
 */
int
terminal_shim_emoji_vs_width(uint32_t cp, uint32_t wc)
{
#if defined(FOOT_GRAPHEME_CLUSTERING)
    const struct emoji_vs *vs =
        bsearch(
            &(struct emoji_vs){.start = cp},
            emoji_vs, sizeof(emoji_vs) / sizeof(emoji_vs[0]),
            sizeof(struct emoji_vs),
            &emoji_vs_compare);

    if (vs != NULL) {
        if (wc == 0xfe0e && vs->vs15)
            return 1;
        if (wc == 0xfe0f && vs->vs16)
            return 2;
    }
#else
    (void)cp;
    (void)wc;
#endif

    return -1;
}


/* ── custom glyph freeing (terminal.zig) ─────────────────────────── */

/* fcft_glyph's layout is fcft's business; terminal.zig only needs pix. */
pixman_image_t *terminal_shim_fcft_glyph_pix(const struct fcft_glyph *glyph) {
    return glyph->pix;
}

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

int terminal_shim_fcft_glyph_advance_x(const struct fcft_glyph *glyph) {
    return glyph->advance.x;
}

const char *terminal_shim_fcft_font_name(const struct fcft_font *font) {
    return font->name;
}

bool terminal_shim_fcft_font_antialias(const struct fcft_font *font) {
    return font->antialias;
}

/* ── font loading (terminal.zig) ─────────────────────────────────── */

/* Headless harness has no wayland object; foot itself always does. */
bool terminal_shim_linear_blending(const struct terminal *term) {
    return term->wl != NULL && wayl_do_linear_blending(term->wl, term->conf);
}

/* Likewise: the harness has no buffer chains. */
bool terminal_shim_grid_is_high_bit_depth(const struct terminal *term) {
    return term->render.chains.grid != NULL &&
           shm_chain_bit_depth(term->render.chains.grid) >= SHM_BITS_10;
}

/* struct fcft_font_options is fcft's business; set only the three fields
 * reload_fonts() needs. The high-res format choice keeps the
 * HAVE_PIXMAN_RGBA_16 build option on the C side. */
void
terminal_shim_fcft_font_options_configure(
    struct fcft_font_options *options,
    enum fcft_scaling_filter scaling_filter,
    bool srgb_decode,
    bool high_res_color)
{
    options->scaling_filter = scaling_filter;
    options->color_glyphs.format = PIXMAN_a8r8g8b8;
    options->color_glyphs.srgb_decode = srgb_decode;

    if (high_res_color) {
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
}

/* util.h's thrd_err_as_string() is a static inline switch, which Zig cannot
 * call; the render-worker error paths log through this. */
#include "util.h"
const char *terminal_shim_thrd_err_as_string(int thrd_err)
{
    return thrd_err_as_string(thrd_err);
}

/* sys/wait.h's status macros cannot be expressed in Zig; keep the platform's
 * own encoding instead of hard-coding the Linux one. */
#include <sys/wait.h>
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
