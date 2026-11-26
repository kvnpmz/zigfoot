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
#include <tllist.h>
#include <wayland-client.h>

#include "composed.h"
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
extern void render_sixel_images(
    struct terminal *term, pixman_image_t *pix, pixman_region32_t *damage,
    const struct coord *cursor);

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
    /* Eight rows (a power of two, as required by grid row masking): the
     * original six, one cursor-shape matrix, one wide/combining row. */
    ROWS = 8,
    CELL_W = 10,
    CELL_H = 20,
    /* Scale 2 doubles the OSD/CSD surfaces; keep them all disjoint. */
    ATLAS_W = 640,
    ATLAS_H = 640,
    GRID_W = COLS * CELL_W,
    GRID_H = ROWS * CELL_H,

    GRID_X = 3, GRID_Y = 3,
    URL_X = 0, URL_Y = 176,
    TIMER_X = 0, TIMER_Y = 256,
    CSD_TOP_X = 0, CSD_TOP_Y = 336,
    CSD_LEFT_X = 0, CSD_LEFT_Y = 376,
    CSD_RIGHT_X = 32, CSD_RIGHT_Y = 376,
    CSD_BOTTOM_X = 64, CSD_BOTTOM_Y = 376,
    CSD_TITLE_X = 352, CSD_TITLE_Y = 512,
    SIXEL_X = 0, SIXEL_Y = 592,
};

struct corpus {
    uint32_t pixels[ATLAS_W * ATLAS_H];
    pixman_image_t *pix;
    pixman_region32_t damage;
    pixman_image_t *buf_pix[1];
    struct buffer buf;
    struct terminal term;
    struct config conf;
    struct grid grid;
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

static char32_t
insert_composed(
    struct corpus *c, const char32_t *chars, uint8_t count, uint8_t forced_width)
{
    struct composed *node = calloc(1, sizeof(*node));
    if (node == NULL) exit(1);
    node->chars = calloc(count, sizeof(*node->chars));
    if (node->chars == NULL) exit(1);
    memcpy(node->chars, chars, (size_t)count * sizeof(*chars));
    node->key = composed_key_from_chars(node->chars, count);
    node->count = count;
    node->forced_width = forced_width;
    composed_insert(&c->term.composed, node);
    return (char32_t)(CELL_COMB_CHARS_LO + node->key);
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
        U"cursor-styles!!!",
        U"wide+combining!!",
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

    /* Row 6 is the cursor-shape matrix; paint_grid() assigns the style,
     * focus and blink state to each cell. */
    /* Row 7: a real double-width glyph followed by its spacer, a second
     * pair, and three composed (combining-character) clusters. */
    row = c->rows[ROWS - 1];
    row->cells[0].wc = U'\u4e2d';
    row->cells[1].wc = CELL_SPACER + 1;
    row->cells[2].wc = U'\u65e5';
    row->cells[3].wc = CELL_SPACER + 1;

    static const char32_t acute[] = {U'A', U'\u0301'};
    static const char32_t wide_acute[] = {U'\u4e2d', U'\u0301'};
    static const char32_t forced[] = {U'B', U'\u0300', U'\u0301'};
    row->cells[4].wc = insert_composed(c, acute, 2, 0);
    row->cells[5].wc = insert_composed(c, wide_acute, 2, 0);
    row->cells[6].wc = insert_composed(c, forced, 3, 2);
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
            bool has_cursor = false;
            c->term.kbd_focus = false;
            c->term.cursor_blink.state = CURSOR_BLINK_OFF;
            c->term.cursor_style = CURSOR_BLOCK;

            if (r == 4 && col == 5) {
                /* focused block cursor, blink ON */
                has_cursor = true;
                c->term.kbd_focus = true;
                c->term.cursor_blink.state = CURSOR_BLINK_ON;
            } else if (r == 4 && col == 6) {
                /* focused block cursor, blink OFF */
                has_cursor = true;
                c->term.kbd_focus = true;
                c->term.cursor_blink.state = CURSOR_BLINK_OFF;
            } else if (r == ROWS - 1 && col == 5) {
                /* unfocused block cursor, blink OFF */
                has_cursor = true;
            } else if (r == ROWS - 2 && col < 12) {
                /* Three styles (legacy "bar" == BEAM) x focus x blink. */
                static const enum cursor_style styles[3] = {
                    CURSOR_UNDERLINE, CURSOR_BEAM, CURSOR_HOLLOW,
                };
                has_cursor = true;
                c->term.cursor_style = styles[col / 4];
                c->term.kbd_focus = (col % 4) < 2;
                c->term.cursor_blink.state =
                    (col % 2) == 0 ? CURSOR_BLINK_ON : CURSOR_BLINK_OFF;
            }

            render_cell(
                &c->term, c->pix, &c->damage, c->rows[r], r, col, has_cursor);
        }
    }

    c->term.kbd_focus = false;
    c->term.cursor_blink.state = CURSOR_BLINK_ON;
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
paint_sixels(struct corpus *c)
{
    /* render_sixel_images() needs only a grid with dirty rows and a tll of
     * sixels whose cached pixman image is already present. No compositor,
     * Wayland shm pool, or VT parser is involved. */
    memset(&c->grid, 0, sizeof(c->grid));
    c->grid.num_rows = ROWS;
    c->grid.num_cols = COLS;
    c->grid.rows = c->rows;
    c->term.grid = &c->grid;
    c->term.margins.left = SIXEL_X;
    c->term.margins.right = ATLAS_W - SIXEL_X - 120;
    c->term.margins.top = SIXEL_Y;
    c->term.margins.bottom = 0;
    c->term.width = ATLAS_W;
    c->term.height = ATLAS_H;

    enum { SIXEL_W = 65, SIXEL_H = 20 };
    static uint32_t data_a[SIXEL_W * SIXEL_H];
    static uint32_t data_b[SIXEL_W * SIXEL_H];
    for (int y = 0; y < SIXEL_H; y++) {
        for (int x = 0; x < SIXEL_W; x++) {
            data_a[y * SIXEL_W + x] =
                (uint32_t)(0x80000000u | ((x * 4) & 0xff) << 16 |
                           ((y * 9) & 0xff) << 8 | ((x + y) & 0xff));
            data_b[y * SIXEL_W + x] =
                (uint32_t)(0xff000000u | ((y * 7) & 0xff) << 16 |
                           ((x * 3) & 0xff) << 8 | ((x ^ y) & 0xff));
        }
    }

    for (int i = 0; i < 2; i++) {
        struct sixel six = {0};
        six.width = six.height = -1;
        six.scaled.width = six.scaled.height = -1;
        six.rows = 1;
        six.cols = 6;
        six.pos = (struct coord){.row = i, .col = i == 0 ? 0 : 5};
        six.opaque = i == 1;
        six.cell_width = CELL_W;
        six.cell_height = CELL_H;
        six.original.width = SIXEL_W;
        six.original.height = SIXEL_H;
        six.original.pix = pixman_image_create_bits(
            PIXMAN_a8r8g8b8, SIXEL_W, SIXEL_H,
            i == 0 ? data_a : data_b, SIXEL_W * 4);
        if (six.original.pix == NULL) exit(1);
        tll_push_back(c->grid.sixel_images, six);
    }

    static const struct coord cursor = {.row = -1, .col = -1};
    render_sixel_images(&c->term, c->pix, &c->damage, &cursor);
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
    c.term.colors.cursor_bg = 0xff1040c0;
    c.term.colors.cursor_fg = 0xfff0e0d0;
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
    /* Exercise the real HarfBuzz/fcft grapheme path, not only the
     * per-codepoint fallback, for the composed row. */
    c.conf.can_shape_grapheme = true;
    c.conf.tweak.grapheme_shaping = true;
    c.conf.cursor.beam_thickness = (struct pt_or_px){.px = 0, .pt = 1.0f};
    c.conf.cursor.underline_thickness = (struct pt_or_px){.px = 0, .pt = 0.75f};
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
        &c, URL_X, URL_Y, url_w, U"1: https://example.com/render-parity",
        0x00ffffff, 0xff203040, margin);
    paint_osd(
        &c, TIMER_X, TIMER_Y, timer_w, U"12.34 \u00b5s", 0x00000000, 0xff806020,
        margin);

    /* Border surfaces must be at least 2 * visible border width wide/tall,
     * otherwise the painter's own bounds assertions reject them at HiDPI. */
    const int top_w = snap_to_scale(160, scale), top_h = snap_to_scale(24, scale);
    const struct csd_data top = {.width = top_w, .height = top_h};
    paint_csd(&c, CSD_TOP_X, CSD_TOP_Y, top_w, top_h, CSD_SURF_TOP, &top);
    const int left_w = snap_to_scale(24, scale), left_h = snap_to_scale(60, scale);
    const struct csd_data left = {.width = left_w, .height = left_h};
    paint_csd(&c, CSD_LEFT_X, CSD_LEFT_Y, left_w, left_h, CSD_SURF_LEFT, &left);
    const int right_w = snap_to_scale(24, scale), right_h = snap_to_scale(60, scale);
    const struct csd_data right = {.width = right_w, .height = right_h};
    paint_csd(
        &c, CSD_RIGHT_X, CSD_RIGHT_Y, right_w, right_h, CSD_SURF_RIGHT, &right);
    const int bottom_w = snap_to_scale(160, scale), bottom_h = snap_to_scale(24, scale);
    const struct csd_data bottom = {.width = bottom_w, .height = bottom_h};
    paint_csd(
        &c, CSD_BOTTOM_X, CSD_BOTTOM_Y, bottom_w, bottom_h, CSD_SURF_BOTTOM,
        &bottom);
    const int title_w = snap_to_scale(144, scale), title_h = snap_to_scale(26, scale);
    const struct csd_data title = {.width = title_w, .height = title_h};
    paint_csd(
        &c, CSD_TITLE_X, CSD_TITLE_Y, title_w, title_h, CSD_SURF_TITLE, &title);

    paint_sixels(&c);

    printf("SCALE %.9g margin=%d cell=%dx%d atlas=%dx%d\n",
           (double)scale, margin, CELL_W, CELL_H, ATLAS_W, ATLAS_H);
    hash_cells(&c, "grid", GRID_X, GRID_Y, GRID_W, GRID_H);
    hash_cells(&c, "url", URL_X, URL_Y, url_w, url_h);
    hash_cells(&c, "timer", TIMER_X, TIMER_Y, timer_w, timer_h);
    hash_cells(&c, "csd-top", CSD_TOP_X, CSD_TOP_Y, top_w, top_h);
    hash_cells(&c, "csd-left", CSD_LEFT_X, CSD_LEFT_Y, left_w, left_h);
    hash_cells(&c, "csd-right", CSD_RIGHT_X, CSD_RIGHT_Y, right_w, right_h);
    hash_cells(&c, "csd-bottom", CSD_BOTTOM_X, CSD_BOTTOM_Y, bottom_w, bottom_h);
    hash_cells(&c, "csd-title", CSD_TITLE_X, CSD_TITLE_Y, title_w, title_h);
    hash_cells(&c, "sixel", SIXEL_X, SIXEL_Y, 120, 48);
    printf("TOTAL %016llx\n", (unsigned long long)hash_rect(&c, 0, 0, ATLAS_W, ATLAS_H));

    tll_foreach(c.grid.sixel_images, it)
        pixman_image_unref(it->item.original.pix);
    tll_free(c.grid.sixel_images);
    composed_free(c.term.composed);
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
    run_scale(2.0f);
    fcft_fini();
    return 0;
}

