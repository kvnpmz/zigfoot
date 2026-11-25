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













/* Palette pointers. The C code does:
 *     free(term->sixel.palette);
 *     term->sixel.palette = NULL;
 * so we expose both a getter (returning the raw pointer, which Zig
 * passes to libc free) and a setter (usually called with NULL). */







/* ── Shims for sixel_init / color_decode_srgb / later chunks ──── */
/* These wrap fields of struct wayland, struct config, struct
 * buffer_chain that are still opaque to Zig. */

#include "wayland.h"
#include "shm.h"

/* ── wayl_do_linear_blending / shm_chain_bit_depth: ported to sixel.zig ─ */




/* Number of entries in the default sixel palette config
 * (ALEN(term->conf->colors_dark.sixel)). */

/* ── conf_sixel_palette_copy: ported to sixel.zig ────────────────── */


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
