/* Zig shim for the csi port.
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
#include <wchar.h>   /* wcwidth(), used when FOOT_GRAPHEME_CLUSTERING is off */
#include "terminal.h"
#include "config.h"

/* ── term->xtsave: 31 bitfields in declaration order ─────────────── */
/* The terminal_types.zig Terminal struct stores xtsave as an opaque
 * [4]u8 blob. These accessors let Zig code read/write individual bits
 * by their C declaration index. On GCC/Clang x86_64 SysV, bool:1
 * bitfields pack LSB-first in the order declared, which is what the
 * Zig-side enum assumes.
 *
 * Note: we use memcpy() rather than type-punning to avoid strict-
 * aliasing warnings under -Werror -fstrict-aliasing. */

#include <string.h>

bool csi_xtsave_get(struct terminal *t, unsigned bit) {
    uint32_t v;
    memcpy(&v, &t->xtsave, sizeof(v));
    return (v >> bit) & 1;
}

void csi_xtsave_set(struct terminal *t, unsigned bit, bool v) {
    uint32_t bits;
    memcpy(&bits, &t->xtsave, sizeof(bits));
    if (v) bits |=  (1u << bit);
    else   bits &= ~(1u << bit);
    memcpy(&t->xtsave, &bits, sizeof(bits));
}

/* ── Direct bool fields on Terminal (not yet in terminal_types.zig) ─ */
/* These are stored in the _font_state opaque blob or standalone
 * trailing fields in the C Terminal; expose via accessors. */

/* c32width is static inline in char32.h — no C symbol. Wrap it. */
int csi_c32width(uint32_t c) {
#if defined(FOOT_GRAPHEME_CLUSTERING)
    return utf8proc_charwidth((utf8proc_int32_t)c);
#else
    return wcwidth((wchar_t)c);
#endif
}

/* XTWINOPS: query first output's physical dimensions (case 15, 19) */
int csi_window_first_output_px_width(struct terminal *t) {
    if (t->window == NULL) return -1;
    tll_foreach(t->window->on_outputs, it) {
        return it->item->dim.px_real.width;
    }
    return -1;
}

int csi_window_first_output_px_height(struct terminal *t) {
    if (t->window == NULL) return -1;
    tll_foreach(t->window->on_outputs, it) {
        return it->item->dim.px_real.height;
    }
    return -1;
}

int csi_window_on_outputs_count(struct terminal *t) {
    if (t->window == NULL) return 0;
    return (int)tll_length(t->window->on_outputs);
}

/* window_title_stack: tll(char *) — needs char* push/pop helpers */
size_t csi_window_title_stack_len(struct terminal *t) {
    return tll_length(t->window_title_stack);
}

void csi_window_title_stack_push(struct terminal *t, char *title) {
    tll_push_back(t->window_title_stack, title);
}

char *csi_window_title_stack_pop(struct terminal *t) {
    if (tll_length(t->window_title_stack) == 0) return NULL;
    return tll_pop_back(t->window_title_stack);
}

/* Foot version (for XTVERSION and secondary DA replies) */
#include "version.h"

unsigned csi_foot_version_major(void) { return FOOT_MAJOR; }
unsigned csi_foot_version_minor(void) { return FOOT_MINOR; }
unsigned csi_foot_version_patch(void) { return FOOT_PATCH; }
const char *csi_foot_version_extra(void) { return FOOT_EXTRA; }
