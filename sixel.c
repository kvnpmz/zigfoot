#include "sixel.h"

#include <string.h>
#include <limits.h>

#define LOG_MODULE "sixel"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "debug.h"
#include "grid.h"
#include "hsl.h"
#include "render.h"
#include "srgb.h"
#include "util.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* Ported to sixel.zig (chunk A) */
void sixel_colors_report_current(struct terminal *term);
void sixel_colors_reset(struct terminal *term);
void sixel_colors_set(struct terminal *term, unsigned count);
void sixel_colors_report_max(struct terminal *term);
void sixel_geometry_report_current(struct terminal *term);
void sixel_geometry_reset(struct terminal *term);
void sixel_geometry_set(struct terminal *term, unsigned width, unsigned height);
void sixel_geometry_report_max(struct terminal *term);


extern void _sixel_overwrite_by_rectangle(struct terminal *term, int row, int col, int height, int width, pixman_image_t **pix, bool *opaque);
extern void sixel_overwrite_by_rectangle(struct terminal *term, int row, int col, int height, int width);
extern void sixel_overwrite_by_row(struct terminal *term, int row, int col, int width);
extern void sixel_overwrite_at_cursor(struct terminal *term, int width);
extern void sixel_cell_size_changed(struct terminal *term);

/* Ported to sixel.zig — extern for C callers */
extern void sixel_insert(struct terminal *term, struct sixel sixel);
extern void sixel_erase(struct terminal *term, struct sixel *sixel);
extern void sixel_invalidate_cache(struct sixel *sixel);

/* Ported to sixel.zig */
extern uint32_t color_decode_srgb(const struct terminal *term, uint16_t r, uint16_t g, uint16_t b);
extern void sixel_put_generic(struct terminal *term, uint8_t c);
extern void sixel_put_ar_11(struct terminal *term, uint8_t c);


/* sixel_put_*: ported to sixel.zig */

/* color_decode_srgb: ported to sixel.zig */

/* sixel_fini: ported to sixel.zig */
/* sixel_init: ported to sixel.zig */
/* sixel_invalidate_cache: ported to sixel.zig */
/* sixel_destroy: ported to sixel.zig */
/* sixel_destroy_all: ported to sixel.zig */
/* sixel_erase: ported to sixel.zig */

/*
 * Verify the sixels are sorted correctly.
 *
 * The sixels are sorted on their *end* row, in descending order. This
 * invariant means the most recent sixels appear first in the list.
 *//* verify_list_order: removed (release no-op) */

/*
 * Verifies there aren't any sixels that cross the scrollback
 * wrap-around. This invariant means a sixel's absolute row numbers
 * are strictly increasing.
 *//* verify_no_wraparound_crossover: removed (release no-op) */

/*
 * Verify there aren't any sixels that cross the scrollback end. This
 * invariant means a sixel's rebased row numbers are strictly
 * increasing.
 *//* verify_scrollback_consistency: removed (release no-op) */

/*
 * Verifies no sixel overlap with any other sixels.
 *//* verify_no_overlap: removed (release no-op) */
/* verify_sixels: removed (release no-op) */
/* sixel_insert: ported to sixel.zig */
/* sixel_scroll_up: ported to sixel.zig */
/* sixel_scroll_down: ported to sixel.zig */
/* blend_new_image_over_old: ported to sixel.zig */
/* sixel_overwrite: ported to sixel.zig */

/* Row numbers are absolute *//* _sixel_overwrite_by_rectangle: ported to sixel.zig */
/* sixel_overwrite_by_rectangle: ported to sixel.zig */

/* Row numbers are relative to grid offset *//* sixel_overwrite_by_row: ported to sixel.zig */
/* sixel_overwrite_at_cursor: ported to sixel.zig */
/* sixel_cell_size_changed: ported to sixel.zig */

void
sixel_sync_cache(const struct terminal *term, struct sixel *six)
{
    if (six->pix != NULL) {
#if defined(_DEBUG)
        if (six->cell_width == term->cell_width &&
            six->cell_height == term->cell_height)
        {
            xassert(six->pix == six->original.pix);
            xassert(six->width == six->original.width);
            xassert(six->height == six->original.height);

            xassert(six->scaled.data == NULL);
            xassert(six->scaled.pix == NULL);
            xassert(six->scaled.width < 0);
            xassert(six->scaled.height < 0);
        } else {
            xassert(six->pix == six->scaled.pix);
            xassert(six->width == six->scaled.width);
            xassert(six->height == six->scaled.height);

            xassert(six->scaled.data != NULL);
            xassert(six->scaled.pix != NULL);

            /* TODO: check ratio */
            xassert(six->scaled.width >= 0);
            xassert(six->scaled.height >= 0);
        }
#endif
        return;
    }

    /* Cache should be invalid */
    xassert(six->scaled.data == NULL);
    xassert(six->scaled.pix == NULL);
    xassert(six->scaled.width < 0);
    xassert(six->scaled.height < 0);

    if (six->cell_width == term->cell_width &&
        six->cell_height == term->cell_height)
    {
        six->pix = six->original.pix;
        six->width = six->original.width;
        six->height = six->original.height;
    } else {
        const double width_ratio = (double)term->cell_width / six->cell_width;
        const double height_ratio = (double)term->cell_height / six->cell_height;

        struct pixman_f_transform scale;
        pixman_f_transform_init_scale(
            &scale, 1. / width_ratio, 1. / height_ratio);

        struct pixman_transform _scale;
        pixman_transform_from_pixman_f_transform(&_scale, &scale);
        pixman_image_set_transform(six->original.pix, &_scale);
        pixman_image_set_filter(six->original.pix, PIXMAN_FILTER_BILINEAR, NULL, 0);

        int scaled_width = (double)six->original.width * width_ratio;
        int scaled_height = (double)six->original.height * height_ratio;
        int scaled_stride = scaled_width * sizeof(uint32_t);

        LOG_DBG("scaling sixel: %dx%d -> %dx%d",
                six->original.width, six->original.height,
                scaled_width, scaled_height);

        uint8_t *scaled_data = xmalloc(scaled_height * scaled_stride);
        pixman_image_t *scaled_pix = pixman_image_create_bits_no_clear(
            term->sixel.pixman_fmt, scaled_width, scaled_height,
            (uint32_t *)scaled_data, scaled_stride);

        pixman_image_composite32(
            PIXMAN_OP_SRC, six->original.pix, NULL, scaled_pix, 0, 0, 0, 0,
            0, 0, scaled_width, scaled_height);

        pixman_image_set_transform(six->original.pix, NULL);

        six->scaled.data = scaled_data;
        six->scaled.pix = six->pix = scaled_pix;
        six->scaled.width = six->width = scaled_width;
        six->scaled.height = six->height = scaled_height;
    }
}

void
sixel_reflow_grid(struct terminal *term, struct grid *grid)
{
    /* Meh - the sixel functions we call use term->grid... */
    struct grid *active_grid = term->grid;
    term->grid = grid;

    /* Need the "real" list to be empty from the beginning */
    tll(struct sixel) copy = tll_init();
    tll_foreach(grid->sixel_images, it)
        tll_push_back(copy, it->item);
    tll_free(grid->sixel_images);

    tll_rforeach(copy, it) {
        struct sixel *six = &it->item;
        int start = six->pos.row;
        int end = (start + six->rows - 1) & (grid->num_rows - 1);

        if (end < start) {
            /* Crosses scrollback wrap-around */
            /* TODO: split image */
            sixel_destroy(six);
            continue;
        }

        if (six->rows > grid->num_rows) {
            /* Image too large */
            /* TODO: keep bottom part? */
            sixel_destroy(six);
            continue;
        }

        /* Drop sixels that now cross the current scrollback end
         * border. This is similar to a sixel that have been
         * scrolled out */
        /* TODO: should be possible to optimize this */
        bool sixel_destroyed = false;
        int last_row = -1;

        for (int j = 0; j < six->rows; j++) {
            int row_no = grid_row_abs_to_sb(
                term->grid, term->rows, six->pos.row + j);
            if (last_row != -1 && last_row >= row_no) {
                sixel_destroy(six);
                sixel_destroyed = true;
                break;
            }

            last_row = row_no;
        }

        if (sixel_destroyed) {
            LOG_WARN("destroyed sixel that now crossed history");
            continue;
        }

        /* Sixels that didn't overlap may now do so, which isn't
         * allowed of course */
        _sixel_overwrite_by_rectangle(
            term, six->pos.row, six->pos.col, six->rows, six->cols,
            &it->item.original.pix, &it->item.opaque);

        if (it->item.original.data != pixman_image_get_data(it->item.original.pix)) {
            it->item.original.data = pixman_image_get_data(it->item.original.pix);
            it->item.original.width = pixman_image_get_width(it->item.original.pix);
            it->item.original.height = pixman_image_get_height(it->item.original.pix);
            it->item.cols = (it->item.original.width + it->item.cell_width - 1) / it->item.cell_width;
            it->item.rows = (it->item.original.height + it->item.cell_height - 1) / it->item.cell_height;
            sixel_invalidate_cache(&it->item);
        }

        sixel_insert(term, it->item);
    }

    tll_free(copy);
    term->grid = active_grid;
}

void
sixel_reflow(struct terminal *term)
{
    for (size_t i = 0; i < 2; i++) {
        struct grid *grid = i == 0 ? &term->normal : &term->alt;
        sixel_reflow_grid(term, grid);
    }
}

void
sixel_unhook(struct terminal *term)
{
    if (term->sixel.pos.row < term->sixel.image.height &&
        term->sixel.pos.row + 6 * term->sixel.pan >= term->sixel.image.height)
    {
        /*
         * Handle case where image has had its size set by raster
         * attributes, and then one or more sixels were printed on the
         * last row of the RA area.
         *
         * In this case, the image height may not be a multiple of
         * 6*pan. But the printed sixels may still be outside the RA
         * area. In this case, using the size from the RA would
         * truncate the image.
         *
         * So, extend the image to a multiple of 6*pan.
         *
         * If this is a transparent image, the image may get trimmed
         * below (most likely back the size set by RA).
         */
        term->sixel.image.height = term->sixel.image.alloc_height;
    }

    /* Strip trailing fully transparent rows, *unless* we *ended* with
     * a trailing GNL, in which case we do *not* want to strip all 6
     * pixel rows */
    if (term->sixel.pos.col > 0) {
        const int bits = sizeof(term->sixel.image.bottom_pixel) * 8;
        const int leading_zeroes = term->sixel.image.bottom_pixel == 0
            ? bits
            : __builtin_clz(term->sixel.image.bottom_pixel);
        const int rows_to_trim = leading_zeroes + 6 - bits;

        LOG_DBG("bottom-pixel: 0x%02x, bits=%d, leading-zeroes=%d, "
                "rows-to-trim=%d*%d", term->sixel.image.bottom_pixel,
                bits, leading_zeroes, rows_to_trim, term->sixel.pan);

        /*
         * If the current graphical cursor position is at the last row
         * of the image, *and* the image is transparent (P2=1), trim
         * the entire image.
         *
         * If the image is not transparent, then we can't trim the RA
         * region (it is supposed to "erase", with the current
         * background color.)
         *
         * We *do* "trim" transparent rows from the graphical cursor
         * position, as this affects the positioning of the text
         * cursor.
         *
         * See https://raw.githubusercontent.com/hackerb9/vt340test/main/sixeltests/p2effect.sh
         */
        if (term->sixel.pos.row + 6 * term->sixel.pan >= term->sixel.image.alloc_height) {
            LOG_DBG("trimming image");
            const int trimmed_height =
                term->sixel.image.alloc_height - rows_to_trim * term->sixel.pan;

            if (term->sixel.transparent_bg) {
                /* Image is transparent - trim as much as possible */
                term->sixel.image.height = trimmed_height;
            } else  {
                /* Image is opaque. We can't trim anything "inside"
                   the RA region */
                if (trimmed_height > term->sixel.image.height) {
                    /* There are non-empty pixels *outside* the RA
                       region - trim up to that point */
                    term->sixel.image.height = trimmed_height;
                }
            }
        } else {
            LOG_DBG("only adjusting cursor position");
        }

        term->sixel.pos.row += 6 * term->sixel.pan;
        term->sixel.pos.row -= rows_to_trim * term->sixel.pan;
    }

    int pixel_row_idx = 0;
    int pixel_rows_left = term->sixel.image.height;
    const int stride = term->sixel.image.width * sizeof(uint32_t);

    /*
     * When sixel scrolling is enabled (the default), sixels behave
     * pretty much like normal output; the sixel starts at the current
     * cursor position and the cursor is moved to a point after the
     * sixel.
     *
     * Furthermore, if the sixel reaches the bottom of the scrolling
     * region, the terminal content is scrolled.
     *
     * When scrolling is disabled, sixels always start at (0,0), the
     * cursor is not moved at all, and the terminal content never
     * scrolls.
     */

    const bool do_scroll = term->sixel.scrolling;

    /* Number of rows we're allowed to use.
     *
     * When scrolling is enabled, we always allow the entire sixel to
     * be emitted.
     *
     * When disabled, only the number of screen rows may be used. */
    int rows_avail = do_scroll
        ? (term->sixel.image.height + term->cell_height - 1) / term->cell_height
        : term->scroll_region.end;

    /* Initial sixel coordinates */
    int start_row = do_scroll ? term->grid->cursor.point.row : 0;
    const int start_col = do_scroll ? term->grid->cursor.point.col : 0;

    /* Total number of rows needed by image */
    const int rows_needed =
        (term->sixel.image.height + term->cell_height - 1) / term->cell_height;

    bool free_image_data = true;

    /* We do not allow sixels to cross the scrollback wrap-around, as
     * this makes intersection calculations much more complicated */
    while (pixel_rows_left > 0 &&
           rows_avail > 0 &&
           rows_needed <= term->grid->num_rows)
    {
        const int cur_row = (term->grid->offset + start_row) & (term->grid->num_rows - 1);
        const int rows_left_until_wrap_around = term->grid->num_rows - cur_row;
        const int usable_rows = min(rows_avail, rows_left_until_wrap_around);

        const int pixel_rows_avail = usable_rows * term->cell_height;

        const int width = term->sixel.image.width;
        const int height = min(pixel_rows_left, pixel_rows_avail);

        uint32_t *img_data;
        if (pixel_row_idx == 0 && height == pixel_rows_left) {
            /* Entire image will be emitted as a single chunk - reuse
             * the source buffer */
            img_data = term->sixel.image.data;
            free_image_data = false;
        } else {
            xassert(free_image_data);
            img_data = xmalloc(height * stride);
            memcpy(
                img_data,
                &((uint8_t *)term->sixel.image.data)[pixel_row_idx * stride],
                height * stride);
        }

        struct sixel image = {
            .pix = NULL,
            .width = -1,
            .height = -1,
            .rows = (height + term->cell_height - 1) / term->cell_height,
            .cols = (width + term->cell_width - 1) / term->cell_width,
            .pos = (struct coord){start_col, cur_row},
            .opaque = !term->sixel.transparent_bg,
            .cell_width = term->cell_width,
            .cell_height = term->cell_height,
            .original = {
                .data = img_data,
                .pix = NULL,
                .width = width,
                .height = height,
            },
            .scaled = {
                .data = NULL,
                .pix = NULL,
                .width = -1,
                .height = -1,
            },
        };

        xassert(image.rows <= term->grid->num_rows);
        xassert(image.pos.row + image.rows - 1 < term->grid->num_rows);

        LOG_DBG("generating %s %dx%d pixman image at %d-%d",
                image.opaque ? "opaque" : "transparent",
                image.original.width, image.original.height,
                image.pos.row, image.pos.row + image.rows);

        image.original.pix = pixman_image_create_bits_no_clear(
            term->sixel.pixman_fmt, image.original.width, image.original.height,
            img_data, stride);

        pixel_row_idx += height;
        pixel_rows_left -= height;
        rows_avail -= image.rows;

        if (do_scroll) {
            /*
             * Linefeeds - always one less than the number of rows
             * occupied by the image.
             *
             * Unless this is *not* the last chunk. In that case,
             * linefeed past the chunk, so that the next chunk
             * "starts" at a "new" row.
             */
            const int linefeed_count = rows_avail == 0
                ? max(0, image.rows - 1)
                : image.rows;

            xassert(rows_avail == 0 ||
                    image.original.height % term->cell_height == 0);

            for (size_t i = 0; i < linefeed_count; i++)
                term_linefeed(term);

            /* Position text cursor if this is the last image chunk */
            if (rows_avail == 0) {
                int row = term->grid->cursor.point.row;

                /*
                 * Position the text cursor based on the text row
                 * touched by the last sixel
                 */
                const int pixel_rows = pixel_rows_left > 0
                    ? image.original.height
                    : term->sixel.pos.row;
                const int term_rows =
                    (pixel_rows + term->cell_height - 1) / term->cell_height;

                xassert(term_rows <= image.rows);

                row -= (image.rows - term_rows);

                term_cursor_to(
                    term,
                    max(0, row),
                    (term->sixel.cursor_right_of_graphics
                     ? min(image.pos.col + image.cols, term->cols - 1)
                     : image.pos.col));
            }

            term->sixel.pos.row -= image.original.height;
        }

        /* Dirty touched cells, and scroll terminal content if necessary */
        for (size_t i = 0; i < image.rows; i++) {
            struct row *row = term->grid->rows[cur_row + i];
            row->dirty = true;

            for (int col = image.pos.col;
                 col < min(image.pos.col + image.cols, term->cols);
                 col++)
            {
                row->cells[col].attrs.clean = 0;
            }

        }

        _sixel_overwrite_by_rectangle(
            term, image.pos.row, image.pos.col, image.rows, image.cols,
            &image.original.pix, &image.opaque);

        if (image.original.data != pixman_image_get_data(image.original.pix)) {
            image.original.data = pixman_image_get_data(image.original.pix);
            image.original.width = pixman_image_get_width(image.original.pix);
            image.original.height = pixman_image_get_height(image.original.pix);
            image.cols = (image.original.width + image.cell_width - 1) / image.cell_width;
            image.rows = (image.original.height + image.cell_height - 1) / image.cell_height;
            sixel_invalidate_cache(&image);
        }

        sixel_insert(term, image);

        if (do_scroll)
            start_row = term->grid->cursor.point.row;
        else
            start_row -= image.rows;
    }

    if (free_image_data)
        free(term->sixel.image.data);

    term->sixel.image.data = NULL;
    term->sixel.image.p = NULL;
    term->sixel.image.width = 0;
    term->sixel.image.height = 0;
    term->sixel.pos = (struct coord){0, 0};

    free(term->sixel.private_palette);
    term->sixel.private_palette = NULL;

    LOG_DBG("you now have %zu sixels in current grid",
            tll_length(term->grid->sixel_images));


    term->bits_affecting_ascii_printer.sixels =
        tll_length(term->grid->sixel_images) > 0;
    term_update_ascii_printer(term);
    render_refresh(term);
}

IGNORE_WARNING("-Wpedantic")

/* decsixel_generic: ported to sixel.zig */

UNIGNORE_WARNINGS

/* decsixel_ar_11: ported to sixel.zig */

/* decgra: ported to sixel.zig */

IGNORE_WARNING("-Wpedantic")

/* decgri_generic: ported to sixel.zig */

UNIGNORE_WARNINGS

/* decgri_ar_11: ported to sixel.zig */

/* decgci: ported to sixel.zig */

/* sixel_put_generic: ported to sixel.zig */

/* sixel_put_ar_11: ported to sixel.zig */

