#ifndef _GNU_SOURCE
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#include <locale.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fcft/fcft.h>
#include <pixman.h>
#include <wayland-client.h>

#include "grid.h"
#include "grid.h"
#include "render.h"

/*
 * Headless render parity corpus.
 *
 * The C oracle build defines FOOT_RENDER_PARITY_C_ORACLE. It uses the weak
 * fallback below because origin/master keeps the margin expression static.
 * The Zig build links the exported render_parity_osd_margin().
 */
#ifdef FOOT_RENDER_PARITY_C_ORACLE
__attribute__((weak)) int
render_parity_osd_margin(float scale)
{
    return (int)roundf(3.0f * scale);
}
#else
extern int render_parity_osd_margin(float scale);
#endif

/* origin/master keeps these painters static. The oracle script removes only
 * these linkage qualifiers in a private copy of render.c. */
extern int render_cell(
    struct terminal *term, pixman_image_t *pix, pixman_region32_t *damage,
    struct row *row, int row_no, int col, bool has_cursor);
extern void render_osd(
    struct terminal *term, const struct wayl_sub_surface *sub_surf,
    struct fcft_font *font, struct buffer *buf, const char32_t *text,
    uint32_t _fg, uint32_t _bg, unsigned x);
extern void render_csd_border(
    struct terminal *term, enum csd_surface surf_idx,
    const struct csd_data *info, struct buffer *buf);
extern void render_csd_title(
    struct terminal *term, const struct csd_data *info, struct buffer *buf);

/* The oracle links the real C painters. Their protocol requests need no
 * compositor in this corpus. */
void __wrap_wl_surface_attach(
    struct wl_surface *surface, struct wl_buffer *buffer, int32_t x, int32_t y)
{
    (void)surface; (void)buffer; (void)x; (void)y;
}
void __wrap_wl_surface_damage_buffer(
    struct wl_surface *surface, int32_t x, int32_t y, int32_t width, int32_t height)
{
    (void)surface; (void)x; (void)y; (void)width; (void)height;
}
void __wrap_wl_surface_commit(struct wl_surface *surface)
{
    (void)surface;
}
void __wrap_wl_surface_set_buffer_scale(struct wl_surface *surface, int32_t scale)
{
    (void)surface; (void)scale;
}

void __wrap_wayland_shim_viewport_set_destination(void *viewport, int32_t width, int32_t height)
{
    (void)viewport; (void)width; (void)height;
}

enum {
    COLS = 16,
    ROWS = 6,
    CELL_W = 10,
    CELL_H = 20,
    ATLAS_W = 320,
    ATLAS_H = 320,
    GRID_W = COLS * CELL_W,
    GRID_H = ROWS * CELL_H,
};

struct corpus {
    uint32_t pixels[ATLAS_W * ATLAS_H];
    pixman_image_t *pix;
    pixman_region32_t damage;
    pixman_image_t *buf_pix[1];
    struct buffer buf;
    struct terminal term;
    struct config conf;
    struct wl_window win;
    struct wayland wayl;
    struct fcft_font *fonts[4];
    struct row *rows[ROWS];
};

static uint64_t
fnv1a_bytes(uint64_t hash, const uint8_t *data, size_t size)
{
    for (size_t i = 0; i < size; i++) {
        hash ^= data[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t
hash_rect(struct corpus *c, int x, int y, int width, int height)
{
    const uint8_t *data = (const uint8_t *)pixman_image_get_data(c->pix);
    const int stride = pixman_image_get_stride(c->pix);
    uint64_t hash = UINT64_C(14695981039346656037);

    for (int row = 0; row < height; row++) {
        const uint8_t *p = data + (y + row) * stride + x * 4;
        hash = fnv1a_bytes(hash, p, (size_t)width * 4);
    }
    return hash;
}

static int
snap_to_scale(int value, float scale)
{
    return (int)roundf((float)scale * ceilf((float)value / scale));
}

static void
hash_cells(struct corpus *c, const char *name, int x, int y, int width, int height)
{
    for (int cy = 0; cy < height; cy += CELL_H) {
        int h = height - cy < CELL_H ? height - cy : CELL_H;
        for (int cx = 0; cx < width; cx += CELL_W) {
            int w = width - cx < CELL_W ? width - cx : CELL_W;
            printf("CELL %s %d %d %016llx\n", name, cy / CELL_H, cx / CELL_W,
                   (unsigned long long)hash_rect(c, x + cx, y + cy, w, h));
        }
    }
}

static pixman_image_t *
region_image(struct corpus *c, int x, int y, int width, int height)
{
    uint32_t *data = c->pixels + y * ATLAS_W + x;
    return pixman_image_create_bits(
        PIXMAN_a8r8g8b8, width, height, data, ATLAS_W * 4);
}

static void
fill_rows(struct corpus *c)
{
    static const char32_t text[ROWS][COLS + 1] = {
        U"ABCDEFGHIJKLMNOP",
        U"abcdefghijklmnop",
        U"\u250c\u2500\u252c\u2500\u2510\u2502\u2514\u2500\u2534\u2500\u2518\u251c\u2500\u253c\u2500\u2524",
        U"\u2591\u2592\u2593\u2588\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588\u28ff\u28c0",
        U"0123456789abcdef",
        U"render parity ok!",
    };

    for (int r = 0; r < ROWS; r++) {
        c->rows[r] = grid_row_alloc(COLS, true);
        c->rows[r]->dirty = true;
        for (int col = 0; col < COLS; col++) {
            struct cell *cell = &c->rows[r]->cells[col];
            cell->wc = text[r][col];
            cell->attrs.clean = false;
        }
    }

    struct row *row = c->rows[0];
    row->cells[0].attrs.bold = true;
    row->cells[1].attrs.italic = true;
    row->cells[2].attrs.reverse = true;
    row->cells[3].attrs.selected = true;
    row->cells[4].attrs.fg_src = COLOR_RGB;
    row->cells[4].attrs.fg = 0x00ff2040;
    row->cells[4].attrs.bg_src = COLOR_RGB;
    row->cells[4].attrs.bg = 0x001020ff;
    row->cells[5].attrs.strikethrough = true;
    row->cells[6].attrs.url = true;
    row->cells[7].attrs.conceal = true;

    row = c->rows[1];
    row->extra = calloc(1, sizeof(*row->extra));
    if (row->extra == NULL) exit(1);
    row->extra->underline_ranges.size = 6;
    row->extra->underline_ranges.count = 6;
    row->extra->underline_ranges.v = calloc(6, sizeof(*row->extra->underline_ranges.v));
    if (row->extra->underline_ranges.v == NULL) exit(1);

    static const enum underline_style styles[6] = {
        UNDERLINE_SINGLE, UNDERLINE_DOUBLE, UNDERLINE_CURLY,
        UNDERLINE_DOTTED, UNDERLINE_DASHED, UNDERLINE_SINGLE,
    };
    for (int i = 0; i < 6; i++) {
        struct row_range *range = &row->extra->underline_ranges.v[i];
        range->start = i * 2;
        range->end = i * 2 + 1;
        range->underline.style = styles[i];
        range->underline.color_src = i == 5 ? COLOR_RGB : COLOR_DEFAULT;
        range->underline.color = 0x00ff8000;
        row->cells[i * 2].attrs.underline = true;
        row->cells[i * 2 + 1].attrs.underline = true;
    }
}

static void
paint_grid(struct corpus *c)
{
    c->buf.width = ATLAS_W;
    c->buf.height = ATLAS_H;
    c->buf.stride = ATLAS_W * 4;
    c->buf.pix[0] = c->pix;

    for (int r = 0; r < ROWS; r++) {
        for (int col = 0; col < COLS; col++) {
            render_cell(
                &c->term, c->pix, &c->damage, c->rows[r], r, col,
                r == ROWS - 1 && col == 5);
        }
    }
}

static void
paint_osd(struct corpus *c, int x, int y, int width, const char32_t *text,
          uint32_t fg, uint32_t bg, int margin)
{
    const int height = margin + CELL_H + margin;
    pixman_image_t *region = region_image(c, x, y, width, height);
    if (region == NULL) {
        fprintf(stderr, "render-parity: pixman region allocation failed\n");
        exit(1);
    }

    struct wayl_sub_surface sub = {0};
    sub.surface.viewport = (void *)1;
    c->buf.width = width;
    c->buf.height = height;
    c->buf.stride = ATLAS_W * 4;
    c->buf.pix[0] = region;
    render_osd(&c->term, &sub, c->fonts[0], &c->buf, text, fg, bg, (unsigned)margin);
    pixman_image_unref(region);
}

static void
paint_csd(struct corpus *c, int x, int y, int width, int height,
          enum csd_surface surface, const struct csd_data *info)
{
    pixman_image_t *region = region_image(c, x, y, width, height);
    if (region == NULL) {
        fprintf(stderr, "render-parity: pixman region allocation failed\n");
        exit(1);
    }
    c->buf.width = width;
    c->buf.height = height;
    c->buf.stride = ATLAS_W * 4;
    c->buf.pix[0] = region;
    if (surface == CSD_SURF_TITLE)
        render_csd_title(&c->term, info, &c->buf);
    else
        render_csd_border(&c->term, surface, info, &c->buf);
    pixman_image_unref(region);
}

static void
run_scale(float scale)
{
    struct corpus c = {0};
    c.pix = pixman_image_create_bits(
        PIXMAN_a8r8g8b8, ATLAS_W, ATLAS_H, c.pixels, ATLAS_W * 4);
    if (c.pix == NULL) {
        fprintf(stderr, "render-parity: pixman image allocation failed\n");
        exit(1);
    }
    pixman_region32_init(&c.damage);
    c.buf.pix = c.buf_pix;
    c.buf.pix = c.buf_pix;
    c.buf.pix[0] = c.pix;
    c.buf.pix_instances = 1;
    c.buf.dirty = &c.damage;

    c.term.conf = &c.conf;
    c.term.window = &c.win;
    c.term.wl = &c.wayl;
    c.win.term = &c.term;
    c.win.csd_mode = CSD_YES;
    c.win.scale = scale;
    c.wayl.fractional_scale_manager = (void *)1;
    c.wayl.viewporter = (void *)1;
    for (int i = 0; i < CSD_SURF_COUNT; i++)
        c.win.csd.surface[i].surface.viewport = (void *)1;
    c.term.scale = scale;
    c.term.cols = COLS;
    c.term.rows = ROWS;
    c.term.cell_width = CELL_W;
    c.term.cell_height = CELL_H;
    c.term.width = GRID_W + 6;
    c.term.height = GRID_H + 6;
    c.term.margins.left = c.term.margins.right = 3;
    c.term.margins.top = c.term.margins.bottom = 3;
    c.term.font_baseline = 12;
    c.term.font_subpixel = FCFT_SUBPIXEL_NONE;
    c.term.colors.fg = 0x00e0e0e0;
    c.term.colors.bg = 0x00102030;
    c.term.colors.alpha = 0xffff;
    c.term.colors.selection_fg = 0x00000000;
    c.term.colors.selection_bg = 0x00406080;
    c.term.cursor_blink.state = CURSOR_BLINK_ON;
    c.term.cursor_style = CURSOR_BLOCK;
    c.term.kbd_focus = false;
    c.term.visual_focus = true;
    c.term.blink.fd = -1;

    for (int i = 0; i < 256; i++) {
        uint32_t v = (uint32_t)i;
        c.term.colors.table[i] = (v << 16) | ((v * 3) << 8) | (255 - v);
    }
    c.conf.box_drawings_uses_font_glyphs = false;
    c.conf.can_shape_grapheme = false;
    c.conf.use_custom_underline_offset = true;
    c.conf.underline_offset.px = 3;
    c.conf.underline_thickness.px = 1;
    c.conf.url.style = UNDERLINE_SINGLE;
    c.conf.csd.border_width = 12;
    c.conf.csd.border_width_visible = 10;
    c.conf.csd.color.border_set = true;
    c.conf.csd.color.border = 0xff406080;
    c.conf.csd.color.title_set = true;
    c.conf.csd.color.title = 0xff203040;
    c.conf.colors_dark.fg = 0x00e0e0e0;
    c.conf.colors_dark.bg = 0x00102030;

    const char *font_name = "monospace";
    for (int i = 0; i < 4; i++) {
        c.fonts[i] = fcft_from_name(1, &font_name, ":size=8");
        if (c.fonts[i] == NULL) {
            fprintf(stderr, "render-parity: no monospace font available\n");
            exit(1);
        }
        c.term.fonts[i] = c.fonts[i];
    }
    c.win.csd.font = c.fonts[0];
    c.term.window_title = (char *)"foot render parity";

    fill_rows(&c);
    paint_grid(&c);

    const int margin = render_parity_osd_margin(scale);
    const int url_w = snap_to_scale(200, scale);
    const int url_h = snap_to_scale(margin + CELL_H + margin, scale);
    const int timer_w = snap_to_scale(160, scale);
    const int timer_h = snap_to_scale(margin + CELL_H + margin, scale);
    paint_osd(
        &c, 0, 128, url_w, U"1: https://example.com/render-parity",
        0x00ffffff, 0xff203040, margin);
    paint_osd(
        &c, 0, 176, timer_w, U"12.34 \u00b5s", 0x00000000, 0xff806020, margin);

    const int top_w = snap_to_scale(160, scale), top_h = snap_to_scale(12, scale);
    const struct csd_data top = {.width = top_w, .height = top_h};
    paint_csd(&c, 0, 216, top_w, top_h, CSD_SURF_TOP, &top);
    const int left_w = snap_to_scale(12, scale), left_h = snap_to_scale(60, scale);
    const struct csd_data left = {.width = left_w, .height = left_h};
    paint_csd(&c, 160, 216, left_w, left_h, CSD_SURF_LEFT, &left);
    const int title_w = snap_to_scale(144, scale), title_h = snap_to_scale(26, scale);
    const struct csd_data title = {.width = title_w, .height = title_h};
    paint_csd(&c, 176, 216, title_w, title_h, CSD_SURF_TITLE, &title);

    printf("SCALE %.9g margin=%d cell=%dx%d atlas=%dx%d\n",
           (double)scale, margin, CELL_W, CELL_H, ATLAS_W, ATLAS_H);
    hash_cells(&c, "grid", 3, 3, GRID_W, GRID_H);
    hash_cells(&c, "url", 0, 128, url_w, url_h);
    hash_cells(&c, "timer", 0, 176, timer_w, timer_h);
    hash_cells(&c, "csd-top", 0, 216, top_w, top_h);
    hash_cells(&c, "csd-left", 160, 216, left_w, left_h);
    hash_cells(&c, "csd-title", 176, 216, title_w, title_h);
    printf("TOTAL %016llx\n", (unsigned long long)hash_rect(&c, 0, 0, ATLAS_W, ATLAS_H));

    for (int r = 0; r < ROWS; r++) grid_row_free(c.rows[r]);
    for (int i = 0; i < 4; i++) fcft_destroy(c.fonts[i]);
    pixman_region32_fini(&c.damage);
    pixman_image_unref(c.pix);
}

int
main(void)
{
    setlocale(LC_ALL, "C.UTF-8");
    if (!fcft_init(FCFT_LOG_COLORIZE_AUTO, false, FCFT_LOG_CLASS_ERROR)) {
        fprintf(stderr, "render-parity: fcft_init() failed\n");
        return 1;
    }
    run_scale(126.0f / 120.0f);
    run_scale(100.0f / 120.0f);
    fcft_fini();
    return 0;
}

