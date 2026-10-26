#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "terminal.h"
#include "grid.h"

/* word_delimiters from config — `struct config` is opaque to Zig */
const char32_t *selection_conf_word_delimiters(const struct terminal *term) {
    return term->conf->word_delimiters;
}

/* grid_row_in_view is static inline in grid.h */
struct row *selection_grid_row_in_view(struct grid *grid, int row_no) {
    return grid_row_in_view(grid, row_no);
}

/* Clipboard/primary data_offer pointer, for has-data checks.
 * struct seat and struct wl_clipboard/primary are opaque to Zig. */
void *selection_seat_clipboard_data_offer(const struct seat *seat) {
    return seat->clipboard.data_offer;
}

void *selection_seat_primary_data_offer(const struct seat *seat) {
    return seat->primary.data_offer;
}

/* selection_target from config */
int selection_conf_selection_target(const struct terminal *term) {
    return term->conf->selection_target;
}
