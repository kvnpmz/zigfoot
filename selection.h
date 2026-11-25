#pragma once

#include <stdbool.h>
#include <wayland-client.h>

#include "terminal.h"

extern const struct wl_data_device_listener data_device_listener;
extern const struct zwp_primary_selection_device_v1_listener primary_selection_device_listener;


/* The wl_data_source / zwp_primary_selection_source_v1 callbacks are Zig
 * (selection.zig, D5d-a); the listener tables in selection.c reference
 * them. */
void selection_data_source_target(void *data,
                                struct wl_data_source *wl_data_source,
                                const char *mime_type);
void selection_data_source_send(void *data,
                                struct wl_data_source *wl_data_source,
                                const char *mime_type, int32_t fd);
void selection_data_source_cancelled(void *data,
                                     struct wl_data_source *wl_data_source);
void selection_data_source_dnd_drop_performed(
    void *data, struct wl_data_source *wl_data_source);
void selection_data_source_dnd_finished(
    void *data, struct wl_data_source *wl_data_source);
void selection_data_source_action(void *data,
                                  struct wl_data_source *wl_data_source,
                                  uint32_t dnd_action);
void selection_primary_source_send(
    void *data, struct zwp_primary_selection_source_v1 *source,
    const char *mime_type, int32_t fd);
void selection_primary_source_cancelled(
    void *data, struct zwp_primary_selection_source_v1 *source);

/* Send `text` to `fd` (the compositor's pipe) as selection data. */
void selection_send_clipboard_or_primary(
    struct seat *seat, int fd, const char *text, const char *source_name);

/* Data offers (selection.zig, D5d-b1). */
void selection_select_mime_type_for_offer(const char *mime_type,
                                          enum data_offer_mime_type *type);
void selection_data_offer_reset(struct wl_clipboard *clipboard);
void selection_primary_offer_reset(struct wl_primary *primary);
void selection_offer(void *data, struct wl_data_offer *wl_data_offer,
                     const char *mime_type);
void selection_offer_source_actions(void *data,
                                    struct wl_data_offer *wl_data_offer,
                                    uint32_t source_actions);
void selection_offer_action(void *data, struct wl_data_offer *wl_data_offer,
                            uint32_t dnd_action);
void selection_primary_offer(
    void *data, struct zwp_primary_selection_offer_v1 *offer,
    const char *mime_type);
void selection_start(
    struct terminal *term, int col, int row,
    enum selection_kind new_kind, bool spaces_only);
void selection_update(struct terminal *term, int col, int row);
void selection_finalize(
    struct seat *seat, struct terminal *term, uint32_t serial);
void selection_dirty_cells(struct terminal *term);
void selection_cancel(struct terminal *term);
void selection_extend(
    struct seat *seat, struct terminal *term,
    int col, int row, enum selection_kind kind);

bool selection_on_rows(const struct terminal *term, int start, int end);

void selection_scroll_up(struct terminal *term, int rows);
void selection_scroll_down(struct terminal *term, int rows);
void selection_view_up(struct terminal *term, int new_view);
void selection_view_down(struct terminal *term, int new_view);

void selection_clipboard_unset(struct seat *seat);
void selection_primary_unset(struct seat *seat);

bool selection_clipboard_has_data(const struct seat *seat);
bool selection_primary_has_data(const struct seat *seat);

char *selection_to_text(const struct terminal *term);
void selection_to_clipboard(
    struct seat *seat, struct terminal *term, uint32_t serial);
void selection_from_clipboard(
    struct seat *seat, struct terminal *term, uint32_t serial);
void selection_to_primary(
    struct seat *seat, struct terminal *term, uint32_t serial);
void selection_from_primary(struct seat *seat, struct terminal *term);

/* Copy text *to* primary/clipboard */
bool text_to_clipboard(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial);
bool text_to_primary(
    struct seat *seat, struct terminal *term, char *text, uint32_t serial);

/*
 * Copy text *from* primary/clipboard
 *
 * Note that these are asynchronous; they *will* return
 * immediately. The 'cb' callback will be called 0..n times with
 * clipboard data. When done (or on error), the 'done' callback is
 * called.
 *
 * As such, keep this in mind:
 *  - The 'user' context must not be stack allocated
 * - Don't expect clipboard data to have been received when these
 *   functions return (it will *never* have been received at this
 *   point).
 */
void text_from_clipboard(
    struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);

void text_from_primary(
    struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*dont)(void *user), void *user);

void selection_start_scroll_timer(
    struct terminal *term, int interval_ns,
    enum selection_scroll_direction direction, int col);
void selection_stop_scroll_timer(struct terminal *term);

void selection_find_word_boundary_left(
    const struct terminal *term, struct coord *pos, bool spaces_only);
void selection_find_word_boundary_right(
    const struct terminal *term, struct coord *pos, bool spaces_only,
    bool stop_on_space_to_word_boundary);

struct coord selection_get_start(const struct terminal *term);
struct coord selection_get_end(const struct terminal *term);
