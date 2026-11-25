#pragma once

#include <stdint.h>
#include <wayland-client.h>

#include "cursor-shape.h"
#include "misc.h"
#include "wayland.h"

/*
 * Custom defines for mouse wheel left/right buttons.
 *
 * Libinput does not define these. On Wayland, all scroll events (both
 * vertical and horizontal) are reported not as buttons, as 'axis'
 * events.
 *
 * Libinput _does_ define BTN_BACK and BTN_FORWARD, which is
 * what we use for vertical scroll events. But for horizontal scroll
 * events, there aren't any pre-defined mouse buttons.
 *
 * Mouse buttons are in the range 0x110 - 0x11f, with joystick defines
 * starting at 0x120.
 */
#define BTN_WHEEL_BACK 0x11c
#define BTN_WHEEL_FORWARD 0x11d
#define BTN_WHEEL_LEFT 0x11e
#define BTN_WHEEL_RIGHT 0x11f

extern const struct wl_keyboard_listener keyboard_listener;
extern const struct wl_pointer_listener pointer_listener;
extern const struct wl_touch_listener touch_listener;

void input_repeat(struct seat *seat, uint32_t key);

/* Ported to input.zig (D4a). The protocol listeners in input.c still call
 * these. */
bool fdm_write_pipe(struct fdm *fdm, int fd, int events, void *data);
void keyboard_keymap(void *data, struct wl_keyboard *wl_keyboard,
                     uint32_t format, int32_t fd, uint32_t size);
void keyboard_enter(void *data, struct wl_keyboard *wl_keyboard, uint32_t serial,
                    struct wl_surface *surface, struct wl_array *keys);
void keyboard_leave(void *data, struct wl_keyboard *wl_keyboard, uint32_t serial,
                    struct wl_surface *surface);
bool start_repeater(struct seat *seat, uint32_t key);
bool stop_repeater(struct seat *seat, uint32_t key);

void get_current_modifiers(const struct seat *seat,
                           xkb_mod_mask_t *effective,
                           xkb_mod_mask_t *consumed,
                           uint32_t key, bool filter_locked);

/* is_top_left() and friends are ported to terminal.zig (chunk C2), but are
 * still needed by the border-drag code here. */
bool is_top_left(const struct terminal *term, int x, int y);
bool is_top_right(const struct terminal *term, int x, int y);
bool is_bottom_left(const struct terminal *term, int x, int y);
bool is_bottom_right(const struct terminal *term, int x, int y);
enum cursor_shape xcursor_for_csd_border(struct terminal *term, int x, int y);
void mouse_coord_pixel_to_cell(struct seat *seat, const struct terminal *term,
                               int x, int y);
