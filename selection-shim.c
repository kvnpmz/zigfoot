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

#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "primary-selection-unstable-v1.h"
#include "wayland.h"

/* Wire protocol shims — these manipulate `struct wl_clipboard` and
 * `struct wl_primary`, plus call the wl_data_* / zwp_primary_selection_*
 * protocol functions. All state remains C-side; Zig only delegates. */

bool selection_shim_text_to_clipboard(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial);

bool selection_shim_text_to_primary(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial);

void selection_shim_selection_from_clipboard(
    struct seat *seat, struct terminal *term, uint32_t serial);

void selection_shim_selection_from_primary(
    struct seat *seat, struct terminal *term);

void selection_shim_text_from_clipboard(
    struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);

void selection_shim_text_from_primary(
    struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);

/* Wire protocol implementations — these replicate the exact C bodies that
 * were removed from selection.c. All state (clipboard, primary, protocol
 * handles) remains C-side. */

/* Forward-decl the removed externs from selection.c that other C code
 * in selection.c still calls (like receive path callbacks). They live
 * elsewhere. */

bool selection_shim_text_to_clipboard(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial)
{
    if (text == NULL || text[0] == '\0')
        return false;
    if (serial == 0)
        return false;

    struct wl_clipboard *clipboard = &seat->clipboard;

    if (clipboard->data_source != NULL) {
        wl_data_device_set_selection(seat->data_device, NULL, clipboard->serial);
        wl_data_source_destroy(clipboard->data_source);
        free(clipboard->text);
        clipboard->data_source = NULL;
        clipboard->serial = 0;
        clipboard->text = NULL;
    }

    clipboard->data_source = wl_data_device_manager_create_data_source(
        term->wl->data_device_manager);
    if (clipboard->data_source == NULL) return false;

    clipboard->text = text;
    wl_data_source_offer(clipboard->data_source, "text/plain;charset=utf-8");
    wl_data_source_offer(clipboard->data_source, "text/plain");
    wl_data_source_offer(clipboard->data_source, "TEXT");
    wl_data_source_offer(clipboard->data_source, "STRING");
    wl_data_source_offer(clipboard->data_source, "UTF8_STRING");

    extern const struct wl_data_source_listener data_source_listener;
    wl_data_source_add_listener(clipboard->data_source, &data_source_listener, seat);
    wl_data_device_set_selection(seat->data_device, clipboard->data_source, serial);
    clipboard->serial = serial;
    return true;
}

bool selection_shim_text_to_primary(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial)
{
    if (text == NULL || text[0] == '\0') return false;
    if (term->wl->primary_selection_device_manager == NULL) return false;
    if (serial == 0) return false;

    struct wl_primary *primary = &seat->primary;

    if (primary->data_source != NULL) {
        zwp_primary_selection_device_v1_set_selection(
            seat->primary_selection_device, NULL, primary->serial);
        zwp_primary_selection_source_v1_destroy(primary->data_source);
        free(primary->text);
        primary->data_source = NULL;
        primary->serial = 0;
        primary->text = NULL;
    }

    primary->data_source = zwp_primary_selection_device_manager_v1_create_source(
        term->wl->primary_selection_device_manager);
    if (primary->data_source == NULL) return false;

    primary->text = text;
    zwp_primary_selection_source_v1_offer(primary->data_source, "text/plain;charset=utf-8");
    zwp_primary_selection_source_v1_offer(primary->data_source, "text/plain");
    zwp_primary_selection_source_v1_offer(primary->data_source, "TEXT");
    zwp_primary_selection_source_v1_offer(primary->data_source, "STRING");
    zwp_primary_selection_source_v1_offer(primary->data_source, "UTF8_STRING");

    extern const struct zwp_primary_selection_source_v1_listener primary_selection_source_listener;
    zwp_primary_selection_source_v1_add_listener(
        primary->data_source, &primary_selection_source_listener, seat);
    zwp_primary_selection_device_v1_set_selection(
        seat->primary_selection_device, primary->data_source, serial);
    primary->serial = serial;
    return true;
}
