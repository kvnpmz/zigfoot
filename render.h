#pragma once
#include <stdbool.h>
#include <pixman.h>

#include "terminal.h"
#include "fdm.h"
#include "wayland.h"
#include "misc.h"

struct renderer;
struct renderer *render_init(struct fdm *fdm, struct wayland *wayl);
void render_destroy(struct renderer *renderer);

enum resize_options {
    RESIZE_NORMAL = 0,
    RESIZE_FORCE = 1 << 0,
    RESIZE_BY_CELLS = 1 << 1,
    RESIZE_KEEP_GRID = 1 << 2,
};

bool render_resize(
    struct terminal *term, int width, int height, uint8_t resize_options);

struct buffer;
struct damage;
void grid_render_scroll(
    struct terminal *term, struct buffer *buf, const struct damage *dmg);
void grid_render_scroll_reverse(
    struct terminal *term, struct buffer *buf, const struct damage *dmg);

struct row;
int render_cell(
    struct terminal *term, pixman_image_t *pix, pixman_region32_t *damage,
    struct row *row, int row_no, int col, bool has_cursor);
void render_row(
    struct terminal *term, pixman_image_t *pix, pixman_region32_t *damage,
    struct row *row, int row_no, int cursor_col);
void render_urgency(struct terminal *term, struct buffer *buf);
void render_margin(
    struct terminal *term, struct buffer *buf,
    int start_line, int end_line, bool apply_damage);

void dirty_old_cursor(struct terminal *term);
void dirty_cursor(struct terminal *term);
void render_update_title(struct terminal *term);

void render_refresh(struct terminal *term);
void render_refresh_app_id(struct terminal *term);
void render_refresh_icon(struct terminal *term);
void render_refresh_csd(struct terminal *term);
void render_refresh_search(struct terminal *term);
void render_refresh_title(struct terminal *term);
void render_refresh_urls(struct terminal *term);
bool render_xcursor_set(
    struct seat *seat, struct terminal *term, enum cursor_shape shape);
bool render_xcursor_is_valid(const struct seat *seat, const char *cursor);

void render_overlay(struct terminal *term);

struct render_worker_context {
    int my_id;
    struct terminal *term;
};
int render_worker_thread(void *_ctx);

struct csd_data {
    int x;
    int y;
    int width;
    int height;
};

struct csd_data get_csd_data(const struct terminal *term, enum csd_surface surf_idx);
void csd_commit(
    struct terminal *term, struct wayl_surface *surf, struct buffer *buf);
void render_csd_part(
    struct terminal *term, struct wl_surface *surf, struct buffer *buf,
    int width, int height, pixman_color_t *color);

void render_buffer_release_callback(struct buffer *buf, void *data);
void render_wait_for_preapply_damage(struct terminal *term);

/* ── Ported to render.zig (D3a: drawing primitives) ─────────────────── */

struct fcft_font *attrs_to_font(
    const struct terminal *term, const struct attributes *attrs);
pixman_color_t color_hex_to_pixman_with_alpha(
    uint32_t color, uint16_t alpha, bool srgb);
pixman_color_t color_hex_to_pixman(uint32_t color, bool srgb);
uint32_t color_blend_towards(uint32_t from, uint32_t to, float amount);
uint32_t color_dim(const struct terminal *term, uint32_t color);
uint32_t color_brighten(const struct terminal *term, uint32_t color);
void draw_hollow_block(
    const struct terminal *term, pixman_image_t *pix,
    const pixman_color_t *color, int x, int y, int cell_cols);
void draw_beam_cursor(
    const struct terminal *term, pixman_image_t *pix,
    const struct fcft_font *font, const pixman_color_t *color,
    int x, int y);
void draw_underline_cursor(
    const struct terminal *term, pixman_image_t *pix,
    const struct fcft_font *font, const pixman_color_t *color,
    int x, int y, int cols);
void draw_underline(
    const struct terminal *term, pixman_image_t *pix,
    const struct fcft_font *font, const pixman_color_t *color,
    int x, int y, int cols);
void draw_styled_underline(
    const struct terminal *term, pixman_image_t *pix,
    const struct fcft_font *font, const pixman_color_t *color,
    enum underline_style style, int x, int y, int cols);
void draw_strikeout(
    const struct terminal *term, pixman_image_t *pix,
    const struct fcft_font *font, const pixman_color_t *color,
    int x, int y, int cols);
void cursor_colors_for_cell(
    const struct terminal *term, const struct cell *cell,
    const pixman_color_t *fg, const pixman_color_t *bg,
    pixman_color_t *cursor_color, pixman_color_t *text_color,
    bool gamma_correct);
void draw_cursor(
    const struct terminal *term, const struct cell *cell,
    const struct fcft_font *font, pixman_image_t *pix,
    pixman_color_t *fg, const pixman_color_t *bg,
    int x, int y, int cols);
