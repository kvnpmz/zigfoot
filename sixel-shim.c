/* Zig shim for the sixel port.
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
#include <stddef.h>
#include "terminal.h"

/* ── term->sixel.* accessors ─────────────────────────────────────── */
/* Terminal.sixel is a ~30-field parser state struct that isn't yet
 * ported to terminal_types.zig. Accessors expose only the fields the
 * ported Zig code needs, and only through this file — the layout of
 * `struct sixel` remains a C concern. */

bool sixel_get_scrolling(struct terminal *t) {
    return t->sixel.scrolling;
}

bool sixel_get_use_private_palette(struct terminal *t) {
    return t->sixel.use_private_palette;
}

bool sixel_get_cursor_right_of_graphics(struct terminal *t) {
    return t->sixel.cursor_right_of_graphics;
}

void sixel_set_scrolling(struct terminal *t, bool v) {
    t->sixel.scrolling = v;
}

void sixel_set_use_private_palette(struct terminal *t, bool v) {
    t->sixel.use_private_palette = v;
}

void sixel_set_cursor_right_of_graphics(struct terminal *t, bool v) {
    t->sixel.cursor_right_of_graphics = v;
}

unsigned sixel_get_palette_size(struct terminal *t) {
    return t->sixel.palette_size;
}

void sixel_set_palette_size(struct terminal *t, unsigned v) {
    t->sixel.palette_size = v;
}

unsigned sixel_get_max_width(struct terminal *t) {
    return t->sixel.max_width;
}

void sixel_set_max_width(struct terminal *t, unsigned v) {
    t->sixel.max_width = v;
}

unsigned sixel_get_max_height(struct terminal *t) {
    return t->sixel.max_height;
}

void sixel_set_max_height(struct terminal *t, unsigned v) {
    t->sixel.max_height = v;
}

/* Palette pointers. The C code does:
 *     free(term->sixel.palette);
 *     term->sixel.palette = NULL;
 * so we expose both a getter (returning the raw pointer, which Zig
 * passes to libc free) and a setter (usually called with NULL). */

uint32_t *sixel_get_palette(struct terminal *t) {
    return t->sixel.palette;
}

void sixel_set_palette(struct terminal *t, uint32_t *p) {
    t->sixel.palette = p;
}

uint32_t *sixel_get_private_palette(struct terminal *t) {
    return t->sixel.private_palette;
}

void sixel_set_private_palette(struct terminal *t, uint32_t *p) {
    t->sixel.private_palette = p;
}

uint32_t *sixel_get_shared_palette(struct terminal *t) {
    return t->sixel.shared_palette;
}

void sixel_set_shared_palette(struct terminal *t, uint32_t *p) {
    t->sixel.shared_palette = p;
}

/* ── Shims for sixel_init / color_decode_srgb / later chunks ──── */
/* These wrap fields of struct wayland, struct config, struct
 * buffer_chain that are still opaque to Zig. */

#include "wayland.h"
#include "shm.h"

bool sixel_wayl_do_linear_blending(struct terminal *t) {
    return wayl_do_linear_blending(t->wl, t->conf);
}

/* Return the raw enum value; Zig compares to hardcoded SHM_BITS_10 (=1)
 * and SHM_BITS_8 (=0) constants. */
int sixel_shm_chain_bit_depth(struct terminal *t) {
    return (int)shm_chain_bit_depth(t->render.chains.grid);
}

bool sixel_wl_have_argb2101010(struct terminal *t) {
    return t->wl->shm_have_argb2101010;
}

bool sixel_wl_have_abgr2101010(struct terminal *t) {
    return t->wl->shm_have_abgr2101010;
}

/* Number of entries in the default sixel palette config
 * (ALEN(term->conf->colors_dark.sixel)). */
size_t sixel_conf_sixel_palette_entries(struct terminal *t) {
    return sizeof(t->conf->colors_dark.sixel) / sizeof(t->conf->colors_dark.sixel[0]);
}

/* Copy up to `max` entries of the configured sixel palette to dst. */
void sixel_conf_sixel_palette_copy(struct terminal *t, uint32_t *dst, size_t max) {
    const size_t n = sixel_conf_sixel_palette_entries(t);
    const size_t cnt = n < max ? n : max;
    for (size_t i = 0; i < cnt; i++)
        dst[i] = t->conf->colors_dark.sixel[i];
}

/* pixman format constants (enum values from pixman.h). */
unsigned sixel_pixman_fmt_a8r8g8b8(void) {
    return (unsigned)PIXMAN_a8r8g8b8;
}
unsigned sixel_pixman_fmt_a2r10g10b10(void) {
    return (unsigned)PIXMAN_a2r10g10b10;
}
unsigned sixel_pixman_fmt_a2b10g10r10(void) {
    return (unsigned)PIXMAN_a2b10g10r10;
}
int sixel_pixman_type_argb(void) {
    return PIXMAN_TYPE_ARGB;
}
