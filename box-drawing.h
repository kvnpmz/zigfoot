#pragma once

#include <uchar.h>
#include <fcft/fcft.h>

struct terminal;
struct fcft_glyph *box_drawing(const struct terminal *term, char32_t wc);

/* The rendering buffer. In the header (instead of box-drawing.c) so that the
 * ABI probe can pin it and box-drawing.zig can mirror it. */
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

/* Primitives: ported to box-drawing.zig (chunk A1). */
int box_thickness(int base_thickness, enum thickness thick);
void box_change_buffer_format(struct buf *buf, pixman_format_code_t new_format);
void box_hline(struct buf *buf, int x1, int x2, int y, int thick);
void box_vline(struct buf *buf, int y1, int y2, int x, int thick);
void box_rect(struct buf *buf, int x1, int y1, int x2, int y2);
void box_hline_middle(struct buf *buf, int thick);
void box_hline_middle_left(struct buf *buf, int vthick, int hthick);
void box_hline_middle_right(struct buf *buf, int vthick, int hthick);
void box_vline_middle(struct buf *buf, int thick);
void box_vline_middle_up(struct buf *buf, int vthick, int hthick);
void box_vline_middle_down(struct buf *buf, int vthick, int hthick);

#define hline(x1, x2, y, thick) box_hline(buf, x1, x2, y, thick)
#define vline(y1, y2, x, thick) box_vline(buf, y1, y2, x, thick)
#define rect(x1, y1, x2, y2) box_rect(buf, x1, y1, x2, y2)
#define thickness(thick) buf->thickness[thick]
#define hline_middle(thick) box_hline_middle(buf, thick)
#define hline_middle_left(thick) box_hline_middle_left(buf, thick, thick)
#define hline_middle_right(thick) box_hline_middle_right(buf, thick, thick)
#define hline_middle_left_mixed(vthick, hthick) box_hline_middle_left(buf, vthick, hthick)
#define hline_middle_right_mixed(vthick, hthick) box_hline_middle_right(buf, vthick, hthick)
#define vline_middle(thick) box_vline_middle(buf, thick)
#define vline_middle_up(thick) box_vline_middle_up(buf, thick, thick)
#define vline_middle_down(thick) box_vline_middle_down(buf, thick, thick)
#define vline_middle_up_mixed(vthick, hthick) box_vline_middle_up(buf, vthick, hthick)
#define vline_middle_down_mixed(vthick, hthick) box_vline_middle_down(buf, vthick, hthick)
