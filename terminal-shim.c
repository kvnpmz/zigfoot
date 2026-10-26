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
