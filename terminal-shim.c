#include <stdbool.h>
#include <stdint.h>
#include "terminal.h"
#include "grid.h"
#include "wayland.h"

struct wl_surface *terminal_shim_window_surface(struct terminal *term) {
    return term->window->surface.surf;
}

bool terminal_shim_window_is_configured(struct terminal *term) {
    return term->window->is_configured;
}

int terminal_shim_conf_cursor_blink_rate_ms(struct terminal *term) {
    return term->conf->cursor.blink.rate_ms;
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

int terminal_shim_conf_url_osc8_underline(struct terminal *term) {
    return term->conf->url.osc8_underline;
}


/* ── term_process_and_print_non_ascii() support ──────────────────── */

#include <stdlib.h>

#include "config.h"
#include "emoji-variation-sequences.h"

int
terminal_shim_conf_grapheme_width_method(const struct terminal *term)
{
    return term->conf->tweak.grapheme_width_method;
}

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

/* ── fdm_ptmx() support ──────────────────────────────────────────── */

/* delayed_render_timer lives in the opaque _font_state block */
int terminal_shim_delayed_render_lower_fd(struct terminal *term) {
    return term->delayed_render_timer.lower_fd;
}

int terminal_shim_delayed_render_upper_fd(struct terminal *term) {
    return term->delayed_render_timer.upper_fd;
}

bool terminal_shim_delayed_render_is_armed(struct terminal *term) {
    return term->delayed_render_timer.is_armed;
}

void terminal_shim_delayed_render_set_armed(struct terminal *term, bool armed) {
    term->delayed_render_timer.is_armed = armed;
}

uint32_t terminal_shim_conf_delayed_render_lower_ns(struct terminal *term) {
    return term->conf->tweak.delayed_render_lower_ns;
}

uint32_t terminal_shim_conf_delayed_render_upper_ns(struct terminal *term) {
    return term->conf->tweak.delayed_render_upper_ns;
}

bool terminal_shim_conf_hold_at_exit(struct terminal *term) {
    return term->conf->hold_at_exit;
}
