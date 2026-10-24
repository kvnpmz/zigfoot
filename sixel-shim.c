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
