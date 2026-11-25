#pragma once

#include <stdint.h>

struct seat;
struct terminal;
struct wl_surface;
struct zwp_text_input_v3;
struct zwp_text_input_v3_listener;

/* The text-input-v3 callbacks are Zig (ime.zig, D5b). Declared outside the
 * feature guard so the harness can drive then without the protocol header;
 * the listener table itself is only needed (and only defined) with IME
 * enabled. */
void ime_enter(void *data, struct zwp_text_input_v3 *zwp_text_input_v3,
               struct wl_surface *surface);
void ime_leave(void *data, struct zwp_text_input_v3 *zwp_text_input_v3,
               struct wl_surface *surface);
void ime_preedit_string(void *data, struct zwp_text_input_v3 *zwp_text_input_v3,
                        const char *text, int32_t cursor_begin,
                        int32_t cursor_end);
void ime_commit_string(void *data, struct zwp_text_input_v3 *zwp_text_input_v3,
                       const char *text);
void ime_delete_surrounding_text(void *data,
                                 struct zwp_text_input_v3 *zwp_text_input_v3,
                                 uint32_t before_length, uint32_t after_length);
void ime_done(void *data, struct zwp_text_input_v3 *zwp_text_input_v3,
              uint32_t serial);

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
#include "text-input-unstable-v3.h"
extern const struct zwp_text_input_v3_listener text_input_listener;
#endif /* FOOT_IME_ENABLED */

void ime_enable(struct seat *seat);
void ime_disable(struct seat *seat);
void ime_update_cursor_rect(struct seat *seat);

void ime_reset_pending(struct seat *seat);
void ime_reset_preedit(struct seat *seat);
