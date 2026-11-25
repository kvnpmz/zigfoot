#include "selection.h"

#include <ctype.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include <sys/epoll.h>
#include <sys/timerfd.h>

#include <pixman.h>

#define LOG_MODULE "selection"
#define LOG_ENABLE_DBG 0
#include "log.h"

#include "async.h"
#include "char32.h"
#include "commands.h"
#include "config.h"
#include "debug.h"
#include "extract.h"
#include "grid.h"
#include "misc.h"
#include "render.h"
#include "search.h"
#include "uri.h"
#include "util.h"
#include "vt.h"
#include "xmalloc.h"

/* Ported to selection.zig — extern for C callers */
extern void text_from_clipboard(struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);
extern void text_from_primary(struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);
extern void selection_from_clipboard(struct seat *seat, struct terminal *term, uint32_t serial);
extern void selection_from_primary(struct seat *seat, struct terminal *term);

/* Ported to selection.zig */
extern struct coord selection_get_start(const struct terminal *term);
extern struct coord selection_get_end(const struct terminal *term);
extern bool selection_on_rows(const struct terminal *term, int row_start, int row_end);
extern void selection_scroll_up(struct terminal *term, int rows);
extern void selection_scroll_down(struct terminal *term, int rows);
extern void selection_view_up(struct terminal *term, int new_view);
extern void selection_view_down(struct terminal *term, int new_view);
extern char *selection_to_text(const struct terminal *term);

/* Ported to selection.zig */
typedef bool (*foreach_selected_cb_t)(struct terminal *term, struct row *row, struct cell *cell, int row_no, int col, void *data);
extern void foreach_selected(struct terminal *term, struct coord start, struct coord end, foreach_selected_cb_t cb, void *data);
extern bool extract_one_const_wrapper(struct terminal *term, struct row *row, struct cell *cell, int row_no, int col, void *data);

/* Ported to selection.zig — extern for C callers */
extern void selection_find_word_boundary_left(const struct terminal *term, struct coord *pos, bool spaces_only);
extern void selection_find_word_boundary_right(const struct terminal *term, struct coord *pos, bool spaces_only, bool stop_on_space_to_word_boundary);
extern bool selection_find_quote_left(struct terminal *term, struct coord *pos, char32_t *quote_char);
extern bool selection_find_quote_right(struct terminal *term, struct coord *pos, char32_t quote_char);
extern void selection_find_line_boundary_left(struct terminal *term, struct coord *pos);
extern void selection_find_line_boundary_right(struct terminal *term, struct coord *pos);

/* Ported to selection.zig — extern for C callers */
extern pixman_region32_t pixman_region_for_coords(const struct terminal *term, const struct coord *start, const struct coord *end);
extern void mark_selected_region(struct terminal *term, pixman_box32_t *boxes, size_t count, int mark_variant);

/* Ported to selection.zig — extern for C callers */
extern void selection_modify(struct terminal *term, struct coord start, struct coord end);
extern void selection_update(struct terminal *term, int col, int row);
extern void set_pivot_point_for_block_and_char_wise(struct terminal *term, struct coord start, enum selection_direction new_direction);

static const char *const mime_type_map[] = {
    [DATA_OFFER_MIME_UNSET] = NULL,
    [DATA_OFFER_MIME_TEXT_PLAIN] = "text/plain",
    [DATA_OFFER_MIME_TEXT_UTF8] = "text/plain;charset=utf-8",
    [DATA_OFFER_MIME_URI_LIST] = "text/uri-list",

    [DATA_OFFER_MIME_TEXT_TEXT] = "TEXT",
    [DATA_OFFER_MIME_TEXT_STRING] = "STRING",
    [DATA_OFFER_MIME_TEXT_UTF8_STRING] = "UTF8_STRING",
};
/* bounded: ported to selection.zig */
/* selection_get_start: ported to selection.zig */
/* selection_get_end: ported to selection.zig */
/* selection_on_rows: ported to selection.zig */
/* selection_scroll_up: ported to selection.zig */
/* selection_scroll_down: ported to selection.zig */
/* selection_view_up: ported to selection.zig */
/* selection_view_down: ported to selection.zig */
/* foreach_selected_normal: ported to selection.zig */
/* foreach_selected_block: ported to selection.zig */
/* foreach_selected: ported to selection.zig */
/* extract_one_const_wrapper: ported to selection.zig */
/* selection_to_text: ported to selection.zig */

/* Coordinates are in *absolute* row numbers (NOT view local) *//* selection_find_word_boundary_left: ported to selection.zig */

/* Coordinates are in *absolute* row numbers (NOT view local) *//* selection_find_word_boundary_right: ported to selection.zig */
/* selection_find_quote_left: ported to selection.zig */
/* selection_find_quote_right: ported to selection.zig */
/* selection_find_line_boundary_left: ported to selection.zig */
/* selection_find_line_boundary_right: ported to selection.zig */
/* selection_start: ported to selection.zig */
/* pixman_region_for_coords_normal: ported to selection.zig */
/* pixman_region_for_coords_block: ported to selection.zig */

/* Returns a pixman region representing the selection between 'start'
 * and 'end' (given the current selection kind), in *scrollback
 * relative coordinates* *//* pixman_region_for_coords: ported to selection.zig */

enum mark_selection_variant {
    MARK_SELECTION_MARK_AND_DIRTY,
    MARK_SELECTION_UNMARK_AND_DIRTY,
    MARK_SELECTION_MARK_FOR_RENDER,
};
/* mark_selected_region: ported to selection.zig */
/* selection_modify: ported to selection.zig */
/* set_pivot_point_for_block_and_char_wise: ported to selection.zig */
/* selection_update: ported to selection.zig */
/* selection_dirty_cells: ported to selection.zig */
/* selection_extend_normal: ported to selection.zig */
/* selection_extend_block: ported to selection.zig */
/* selection_extend: ported to selection.zig */

//static const struct zwp_primary_selection_source_v1_listener primary_selection_source_listener;
/* selection_finalize: ported to selection.zig */
/* unmark_selected: ported to selection.zig */
/* selection_cancel: ported to selection.zig */
/* selection_clipboard_has_data: ported to selection.zig */
/* selection_primary_has_data: ported to selection.zig */
/* selection_clipboard_unset: ported to selection.zig */
/* selection_primary_unset: ported to selection.zig */
/* fdm_scroll_timer: ported to selection.zig */
/* selection_start_scroll_timer: ported to selection.zig */
/* selection_stop_scroll_timer: ported to selection.zig */

const struct wl_data_source_listener data_source_listener = {
    .target = &selection_data_source_target,
    .send = &selection_data_source_send,
    .cancelled = &selection_data_source_cancelled,
    .dnd_drop_performed = &selection_data_source_dnd_drop_performed,
    .dnd_finished = &selection_data_source_dnd_finished,
    .action = &selection_data_source_action,
};

const struct zwp_primary_selection_source_v1_listener primary_selection_source_listener = {
    .send = &selection_primary_source_send,
    .cancelled = &selection_primary_source_cancelled,
};
/* text_to_clipboard: ported to selection.zig */
/* selection_to_clipboard: ported to selection.zig */

/* clipboard_receive pipeline (timeout, decoders, URI handling) and
 * begin_receive_clipboard: ported to selection.zig */

extern void begin_receive_clipboard(
    struct terminal *term, bool no_strip, int read_fd,
    enum data_offer_mime_type mime_type,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);

void
selection_text_from_clipboard_c(struct seat *seat, struct terminal *term,
                    bool no_strip,
                    void (*cb)(char *data, size_t size, void *user),
                    void (*done)(void *user), void *user)
{
    struct wl_clipboard *clipboard = &seat->clipboard;
    if (clipboard->data_offer == NULL ||
        clipboard->mime_type == DATA_OFFER_MIME_UNSET)
    {
        done(user);
        return;
    }

    /* Prepare a pipe the other client can write its selection to us */
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) == -1) {
        LOG_ERRNO("failed to create pipe");
        done(user);
        return;
    }

    LOG_DBG("receive from clipboard: mime-type=%s",
            mime_type_map[clipboard->mime_type]);

    int read_fd = fds[0];
    int write_fd = fds[1];

    /* Give write-end of pipe to other client */
    wl_data_offer_receive(
        clipboard->data_offer, mime_type_map[clipboard->mime_type], write_fd);

    /* Don't keep our copy of the write-end open (or we'll never get EOF) */
    close(write_fd);

    begin_receive_clipboard(
        term, no_strip, read_fd, clipboard->mime_type, cb, done, user);
}

static void
receive_offer(char *data, size_t size, void *user)
{
    struct terminal *term = user;
    xassert(term->is_sending_paste_data);
    term_paste_data_to_slave(term, data, size);
}

static void
receive_offer_done(void *user)
{
    struct terminal *term = user;

    if (term->bracketed_paste)
        term_paste_data_to_slave(term, "\033[201~", 6);

    term->is_sending_paste_data = false;

    /* Make sure we send any queued up non-paste data */
    if (tll_length(term->ptmx_buffers) > 0)
        fdm_event_add(term->fdm, term->ptmx, EPOLLOUT);
}

void
selection_selection_from_clipboard_c(struct seat *seat, struct terminal *term, uint32_t serial)
{
    if (term->is_sending_paste_data) {
        /* We're already pasting... */
        return;
    }

    struct wl_clipboard *clipboard = &seat->clipboard;
    if (clipboard->data_offer == NULL)
        return;

    term->is_sending_paste_data = true;

    if (term->bracketed_paste)
        term_paste_data_to_slave(term, "\033[200~", 6);

    selection_text_from_clipboard_c(
        seat, term, false, &receive_offer, &receive_offer_done, term);
}
/* text_to_primary: ported to selection.zig */
/* selection_to_primary: ported to selection.zig */

void
selection_text_from_primary_c(
    struct seat *seat, struct terminal *term, bool no_strip,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user)
{
    if (term->wl->primary_selection_device_manager == NULL) {
        done(user);
        return;
    }

    struct wl_primary *primary = &seat->primary;
    if (primary->data_offer == NULL ||
        primary->mime_type == DATA_OFFER_MIME_UNSET)
    {
        done(user);
        return;
    }

    /* Prepare a pipe the other client can write its selection to us */
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) == -1) {
        LOG_ERRNO("failed to create pipe");
        done(user);
        return;
    }

    LOG_DBG("receive from primary: mime-type=%s",
            mime_type_map[primary->mime_type]);

    int read_fd = fds[0];
    int write_fd = fds[1];

    /* Give write-end of pipe to other client */
    zwp_primary_selection_offer_v1_receive(
        primary->data_offer, mime_type_map[primary->mime_type], write_fd);

    /* Don't keep our copy of the write-end open (or we'll never get EOF) */
    close(write_fd);

    begin_receive_clipboard(
        term, no_strip, read_fd, primary->mime_type, cb, done, user);
}

void
selection_selection_from_primary_c(struct seat *seat, struct terminal *term)
{
    if (term->wl->primary_selection_device_manager == NULL)
        return;

    if (term->is_sending_paste_data) {
        /* We're already pasting... */
        return;
    }

    struct wl_primary *primary = &seat->primary;
    if (primary->data_offer == NULL)
        return;

    term->is_sending_paste_data = true;
    if (term->bracketed_paste)
        term_paste_data_to_slave(term, "\033[200~", 6);

    selection_text_from_primary_c(
        seat, term, false, &receive_offer, &receive_offer_done, term);
}

static void
select_mime_type_for_offer(const char *_mime_type,
                           enum data_offer_mime_type *type)
{
    enum data_offer_mime_type mime_type = DATA_OFFER_MIME_UNSET;

    /* Translate offered mime type to our mime type enum */
    for (size_t i = 0; i < ALEN(mime_type_map); i++) {
        if (mime_type_map[i] == NULL)
            continue;

        if (streq(_mime_type, mime_type_map[i])) {
            mime_type = i;
            break;
        }
    }

    LOG_DBG("mime-type: %s -> %s (offered type was %s)",
            mime_type_map[*type], mime_type_map[mime_type], _mime_type);

    /* Mime-type transition; if the new mime-type is "better" than
     * previously offered types, use the new type */

    switch (mime_type) {
    case DATA_OFFER_MIME_TEXT_PLAIN:
    case DATA_OFFER_MIME_TEXT_TEXT:
    case DATA_OFFER_MIME_TEXT_STRING:
        /* text/plain is our least preferred type. Only use if current
         * type is unset */
        switch (*type) {
        case DATA_OFFER_MIME_UNSET:
            *type = mime_type;
            break;

        default:
            break;
        }
        break;

    case DATA_OFFER_MIME_TEXT_UTF8:
    case DATA_OFFER_MIME_TEXT_UTF8_STRING:
        /* text/plain;charset=utf-8 is preferred over text/plain */
        switch (*type) {
        case DATA_OFFER_MIME_UNSET:
        case DATA_OFFER_MIME_TEXT_PLAIN:
        case DATA_OFFER_MIME_TEXT_TEXT:
        case DATA_OFFER_MIME_TEXT_STRING:
            *type = mime_type;
            break;

        default:
            break;
        }
        break;

    case DATA_OFFER_MIME_URI_LIST:
        /* text/uri-list is always used when offered */
        *type = mime_type;
        break;

    case DATA_OFFER_MIME_UNSET:
        break;
    }
}

static void
data_offer_reset(struct wl_clipboard *clipboard)
{
    if (clipboard->data_offer != NULL) {
        wl_data_offer_destroy(clipboard->data_offer);
        clipboard->data_offer = NULL;
    }

    clipboard->window = NULL;
    clipboard->mime_type = DATA_OFFER_MIME_UNSET;
}

static void
offer(void *data, struct wl_data_offer *wl_data_offer, const char *mime_type)
{
    struct seat *seat = data;
    select_mime_type_for_offer(mime_type, &seat->clipboard.mime_type);
}

static void
source_actions(void *data, struct wl_data_offer *wl_data_offer,
                uint32_t source_actions)
{
#if defined(_DEBUG) && LOG_ENABLE_DBG
    char actions_as_string[1024];
    size_t idx = 0;

    actions_as_string[0] = '\0';
    actions_as_string[sizeof(actions_as_string) - 1] = '\0';

    for (size_t i = 0; i < 31; i++) {
        if (((source_actions >> i) & 1) == 0)
            continue;

        enum wl_data_device_manager_dnd_action action = 1 << i;

        const char *s = NULL;

        switch (action) {
        case WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE: s = NULL; break;
        case WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY: s = "copy"; break;
        case WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE: s = "move"; break;
        case WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK: s = "ask"; break;
        }

        if (s == NULL)
            continue;

        strncat(actions_as_string, s, sizeof(actions_as_string) - idx - 1);
        idx += strlen(s);
        strncat(actions_as_string, ", ", sizeof(actions_as_string) - idx - 1);
        idx += 2;
    }

    /* Strip trailing ", " */
    if (strlen(actions_as_string) > 2)
        actions_as_string[strlen(actions_as_string) - 2] = '\0';

    LOG_DBG("DnD actions: %s (0x%08x)", actions_as_string, source_actions);
#endif
}

static void
offer_action(void *data, struct wl_data_offer *wl_data_offer, uint32_t dnd_action)
{
#if defined(_DEBUG) && LOG_ENABLE_DBG
    const char *s = NULL;

    switch (dnd_action) {
    case WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE: s = "<none>"; break;
    case WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY: s = "copy"; break;
    case WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE: s = "move"; break;
    case WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK: s = "ask"; break;
    }

    LOG_DBG("DnD offer action: %s (0x%08x)", s, dnd_action);
#endif
}

static const struct wl_data_offer_listener data_offer_listener = {
    .offer = &offer,
    .source_actions = &source_actions,
    .action = &offer_action,
};

static void
data_offer(void *data, struct wl_data_device *wl_data_device,
           struct wl_data_offer *offer)
{
    struct seat *seat = data;
    data_offer_reset(&seat->clipboard);
    seat->clipboard.data_offer = offer;
    wl_data_offer_add_listener(offer, &data_offer_listener, seat);
}

static void
enter(void *data, struct wl_data_device *wl_data_device, uint32_t serial,
      struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
      struct wl_data_offer *offer)
{
    struct seat *seat = data;
    struct wayland *wayl = seat->wayl;

    xassert(offer == seat->clipboard.data_offer);

    if (seat->clipboard.mime_type == DATA_OFFER_MIME_UNSET)
        goto reject_offer;

    /* Remember _which_ terminal the current DnD offer is targeting */
    xassert(seat->clipboard.window == NULL);
    tll_foreach(wayl->terms, it) {
        if (term_surface_kind(it->item, surface) == TERM_SURF_GRID &&
            !it->item->is_sending_paste_data)
        {
            wl_data_offer_accept(
                offer, serial, mime_type_map[seat->clipboard.mime_type]);
            wl_data_offer_set_actions(
                offer,
                WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY,
                WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);

            seat->clipboard.window = it->item->window;
            return;
        }
    }

reject_offer:
    /* Either terminal is already busy sending paste data, or mouse
     * pointer isn't over the grid */
    seat->clipboard.window = NULL;
    wl_data_offer_accept(offer, serial, NULL);
    wl_data_offer_set_actions(
        offer,
        WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE,
        WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE);
}

static void
leave(void *data, struct wl_data_device *wl_data_device)
{
    struct seat *seat = data;
    seat->clipboard.window = NULL;
}

static void
motion(void *data, struct wl_data_device *wl_data_device, uint32_t time,
       wl_fixed_t x, wl_fixed_t y)
{
}

struct dnd_context {
    struct terminal *term;
    struct wl_data_offer *data_offer;
};

static void
receive_dnd(char *data, size_t size, void *user)
{
    struct dnd_context *ctx = user;
    receive_offer(data, size, ctx->term);
}

static void
receive_dnd_done(void *user)
{
    struct dnd_context *ctx = user;

    wl_data_offer_finish(ctx->data_offer);
    wl_data_offer_destroy(ctx->data_offer);
    receive_offer_done(ctx->term);
    free(ctx);
}

static void
drop(void *data, struct wl_data_device *wl_data_device)
{
    struct seat *seat = data;

    xassert(seat->clipboard.window != NULL);
    struct terminal *term = seat->clipboard.window->term;

    struct wl_clipboard *clipboard = &seat->clipboard;

    if (clipboard->mime_type == DATA_OFFER_MIME_UNSET) {
        LOG_WARN("compositor called data_device::drop() "
                 "even though we rejected the drag-and-drop");
        return;
    }

    struct dnd_context *ctx = xmalloc(sizeof(*ctx));
    *ctx = (struct dnd_context){
        .term = term,
        .data_offer = clipboard->data_offer,
    };

    /* Prepare a pipe the other client can write its selection to us */
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) == -1) {
        LOG_ERRNO("failed to create pipe");
        free(ctx);
        return;
    }

    int read_fd = fds[0];
    int write_fd = fds[1];

    LOG_DBG("DnD drop: mime-type=%s", mime_type_map[clipboard->mime_type]);

    /* Give write-end of pipe to other client */
    wl_data_offer_receive(
        clipboard->data_offer, mime_type_map[clipboard->mime_type], write_fd);

    /* Don't keep our copy of the write-end open (or we'll never get EOF) */
    close(write_fd);

    term->is_sending_paste_data = true;

    if (term->bracketed_paste)
        term_paste_data_to_slave(term, "\033[200~", 6);

    begin_receive_clipboard(
        term, false, read_fd, clipboard->mime_type,
        &receive_dnd, &receive_dnd_done, ctx);

    /* data offer is now "owned" by the receive context */
    clipboard->data_offer = NULL;
    clipboard->mime_type = DATA_OFFER_MIME_UNSET;
}

static void
selection(void *data, struct wl_data_device *wl_data_device,
          struct wl_data_offer *offer)
{
    /* Selection offer from other client */
    struct seat *seat = data;
    if (offer == NULL)
        data_offer_reset(&seat->clipboard);
    else
        xassert(offer == seat->clipboard.data_offer);
}

const struct wl_data_device_listener data_device_listener = {
    .data_offer = &data_offer,
    .enter = &enter,
    .leave = &leave,
    .motion = &motion,
    .drop = &drop,
    .selection = &selection,
};

static void
primary_offer(void *data,
              struct zwp_primary_selection_offer_v1 *zwp_primary_selection_offer,
              const char *mime_type)
{
    LOG_DBG("primary offer: %s", mime_type);
    struct seat *seat = data;
    select_mime_type_for_offer(mime_type, &seat->primary.mime_type);
}

static const struct zwp_primary_selection_offer_v1_listener primary_selection_offer_listener = {
    .offer = &primary_offer,
};

static void
primary_offer_reset(struct wl_primary *primary)
{
    if (primary->data_offer != NULL) {
        zwp_primary_selection_offer_v1_destroy(primary->data_offer);
        primary->data_offer = NULL;
    }

    primary->mime_type = DATA_OFFER_MIME_UNSET;
}

static void
primary_data_offer(void *data,
                   struct zwp_primary_selection_device_v1 *zwp_primary_selection_device,
                   struct zwp_primary_selection_offer_v1 *offer)
{
    struct seat *seat = data;
    primary_offer_reset(&seat->primary);
    seat->primary.data_offer = offer;
    zwp_primary_selection_offer_v1_add_listener(
        offer, &primary_selection_offer_listener, seat);
}

static void
primary_selection(void *data,
                  struct zwp_primary_selection_device_v1 *zwp_primary_selection_device,
                  struct zwp_primary_selection_offer_v1 *offer)
{
    /* Selection offer from other client, for primary */

    struct seat *seat = data;
    if (offer == NULL)
        primary_offer_reset(&seat->primary);
    else
        xassert(seat->primary.data_offer == offer);
}

const struct zwp_primary_selection_device_v1_listener primary_selection_device_listener = {
    .data_offer = &primary_data_offer,
    .selection = &primary_selection,
};

