#include <stdbool.h>
#include <stdint.h>
#include "terminal.h"
#include "grid.h"
#include "wayland.h"

struct wl_surface *terminal_shim_window_surface(struct terminal *term) {
    return term->window->surface.surf;
}

bool terminal_shim_window_is_configured(struct terminal *term) {
    return term->window->is_configured;
}

int terminal_shim_conf_cursor_blink_rate_ms(struct terminal *term) {
    return term->conf->cursor.blink.rate_ms;
}

struct row *terminal_shim_grid_row_in_view(struct grid *grid, int row) {
    return grid_row_in_view(grid, row);
}

void terminal_shim_wl_surface_commit(struct wl_surface *surf) {
    wl_surface_commit(surf);
}

#include "grid.h"

struct row *terminal_shim_grid_row_and_alloc(struct grid *grid, int row_no) {
    return grid_row_and_alloc(grid, row_no);
}

int terminal_shim_grid_row_absolute(struct grid *grid, int row_no) {
    return grid_row_absolute(grid, row_no);
}

extern void erase_line(struct terminal *term, struct row *row);

void terminal_shim_erase_line(struct terminal *term, struct row *row) {
    erase_line(term, row);
}

struct row *terminal_shim_grid_row(struct grid *grid, int row_no) {
    return grid_row(grid, row_no);
}

void terminal_shim_term_reset_grapheme_state(struct terminal *term) {
    term_reset_grapheme_state(term);
}

int terminal_shim_conf_url_osc8_underline(struct terminal *term) {
    return term->conf->url.osc8_underline;
}
