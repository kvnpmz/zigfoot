/* Zig shim for the grid port.
 *
 * This file only holds what the Zig code cannot express yet:
 *
 *   1. C-only compile-time knowledge: object-like macros, sizeof/offsetof,
 *      #ifdef'd feature tests, and static inline wrappers around libc or
 *      wayland-client (wl_subsurface_set_sync(), c32width(), ...).
 *   2. Struct mirrors that have not landed yet: field reads of a struct that
 *      terminal_types.zig does not mirror. Delete these as soon as the struct
 *      is mirrored and pinned by the ABI probe (Track B).
 *   3. C-only types and varargs: regex_t, FILE, va_list forwarding.
 *
 * A function that no longer satisfies one of these must be deleted; the audit
 * rule and the current exemptions are documented in MIGRATION_PLAN.md 12.9.
 */

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
