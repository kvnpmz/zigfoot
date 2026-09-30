#include "grid.h"
#include "terminal.h"

void grid_resize_and_reflow_zig(
    struct grid *grid, struct composed *composed, int new_rows, int new_cols,
    int old_screen_rows, int new_screen_rows,
    size_t tracking_points_count,
    struct coord *const tracking_points[]);

void
grid_resize_and_reflow(
    struct grid *grid, const struct terminal *term, int new_rows, int new_cols,
    int old_screen_rows, int new_screen_rows,
    size_t tracking_points_count,
    struct coord *const tracking_points[static tracking_points_count])
{
    grid_resize_and_reflow_zig(
        grid, term->composed, new_rows, new_cols,
        old_screen_rows, new_screen_rows,
        tracking_points_count, tracking_points);
}
