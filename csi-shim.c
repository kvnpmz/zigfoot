#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
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

bool csi_size_notifications(struct terminal *t) {
    return t->size_notifications;
}

void csi_set_size_notifications(struct terminal *t, bool v) {
    t->size_notifications = v;
}

bool csi_grapheme_shaping(struct terminal *t) {
    return t->grapheme_shaping;
}

void csi_set_grapheme_shaping(struct terminal *t, bool v) {
    t->grapheme_shaping = v;
}

bool csi_modify_other_keys_2(struct terminal *t) {
    return t->modify_other_keys_2;
}

void csi_set_modify_other_keys_2(struct terminal *t, bool v) {
    t->modify_other_keys_2 = v;
}

/* ── Config accessors (term->conf is opaque to Zig) ──────────────── */

bool csi_conf_cursor_blink_enabled(struct terminal *t) {
    return t->conf->cursor.blink.enabled;
}

int csi_conf_cursor_style(struct terminal *t) {
    return (int)t->conf->cursor.style;
}

int csi_conf_security_osc52(struct terminal *t) {
    return (int)t->conf->security.osc52;
}

int csi_conf_grapheme_width_method(struct terminal *t) {
    return (int)t->conf->tweak.grapheme_width_method;
}

bool csi_conf_tweak_sixel(struct terminal *t) {
    return t->conf->tweak.sixel;
}
