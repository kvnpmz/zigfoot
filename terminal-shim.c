#include <stdbool.h>
#include <stdint.h>
#include "terminal.h"
#include "url-mode.h"
#include "grid.h"
#include "wayland.h"

struct wl_surface *terminal_shim_window_surface(struct terminal *term) {
    return term->window->surface.surf;
}

/* urls_mode_is_active() is static inline in url-mode.h. */
bool terminal_shim_urls_mode_active(const struct terminal *term) {
    return urls_mode_is_active(term);
}

/* The null checks are defensive: in foot itself `window` is always set, but
 * the headless harness runs these paths without a wayland window. */
bool terminal_shim_window_is_suspended(struct terminal *term) {
    return term->window != NULL && term->window->is_suspended;
}

bool terminal_shim_window_is_configured(struct terminal *term) {
    return term->window != NULL && term->window->is_configured;
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
