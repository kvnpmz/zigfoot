#pragma once

#include <uchar.h>
#include <fcft/fcft.h>

struct terminal;

/* The whole module is implemented in box-drawing.zig (chunks A1-A5c). */
struct fcft_glyph *box_drawing(const struct terminal *term, char32_t wc);

/* The rendering buffer. Kept in the header (instead of in the Zig module) so
 * that the ABI probe can pin it and box-drawing.zig can mirror it as
 * types.BoxBuf. */
enum thickness {
    LIGHT,
    HEAVY,
};

struct buf {
    uint8_t *data;
    pixman_image_t *pix;
    pixman_format_code_t format;
    int width;
    int height;
    int stride;
    bool solid_shades;

    int thickness[2];

    /* For octants, sextants and wedges */
    int x_halfs[2];
    int y_thirds[2];

    /* For octants */
    int y_quads[3];
};
