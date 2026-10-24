#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include "terminal.h"

/* ── term->sixel.* accessors ─────────────────────────────────────── */

bool sixel_get_scrolling(struct terminal *t) {
    return t->sixel.scrolling;
}

bool sixel_get_use_private_palette(struct terminal *t) {
    return t->sixel.use_private_palette;
}

bool sixel_get_cursor_right_of_graphics(struct terminal *t) {
    return t->sixel.cursor_right_of_graphics;
}

unsigned sixel_get_palette_size(struct terminal *t) {
    return t->sixel.palette_size;
}

unsigned sixel_get_max_width(struct terminal *t) {
    return t->sixel.max_width;
}

unsigned sixel_get_max_height(struct terminal *t) {
    return t->sixel.max_height;
}

bool sixel_get_shared_palette(struct terminal *t) {
    return t->sixel.shared_palette;
}

unsigned sixel_get_image_width(struct terminal *t) {
    return (unsigned)t->sixel.image.width;
}

unsigned sixel_get_image_height(struct terminal *t) {
    return (unsigned)t->sixel.image.height;
}
