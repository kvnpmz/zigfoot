#pragma once

#include <stdint.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <wayland-client.h>

#include "cursor-shape.h"
#include "keymap.h"
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
void get_current_modifiers(const struct seat *seat, xkb_mod_mask_t *effective,
                           xkb_mod_mask_t *consumed, uint32_t key,
                           bool filter_locked);
bool keysym_is_modifier(xkb_keysym_t keysym);
void modifier_string(xkb_mod_mask_t mods, size_t sz, char mod_str[static sz],
                     const struct seat *seat);
void keyboard_repeat_info(void *data, struct wl_keyboard *wl_keyboard,
                          int32_t rate, int32_t delay);
void keyboard_key(void *data, struct wl_keyboard *wl_keyboard, uint32_t serial,
                  uint32_t time, uint32_t key, uint32_t state);
void input_repeat(struct seat *seat, uint32_t key);
void alternate_scroll(struct seat *seat, int amount, int button);
const struct key_binding *match_mouse_binding(const struct seat *seat,
                                             const struct terminal *term,
                                             int button);
void mouse_scroll(struct seat *seat, int amount, enum wl_pointer_axis axis);

void key_press_release(struct seat *seat, struct terminal *term, uint32_t serial,
                       uint32_t key, uint32_t state);
/* Implemented in input.zig (D4c). */
bool execute_binding(struct seat *seat, struct terminal *term,
                     const struct key_binding *binding, uint32_t serial,
                     int amount);

/* The pointer callbacks: ported to input.zig (D4d2b). The listener table in
 * input.c still references them. */
void wl_pointer_enter(void *data, struct wl_pointer *wl_pointer, uint32_t serial,
                      struct wl_surface *surface, wl_fixed_t surface_x,
                      wl_fixed_t surface_y);
void wl_pointer_leave(void *data, struct wl_pointer *wl_pointer, uint32_t serial,
                      struct wl_surface *surface);
void wl_pointer_motion(void *data, struct wl_pointer *wl_pointer, uint32_t time,
                       wl_fixed_t surface_x, wl_fixed_t surface_y);
void wl_pointer_button(void *data, struct wl_pointer *wl_pointer, uint32_t serial,
                       uint32_t time, uint32_t button, uint32_t state);
void wl_pointer_axis(void *data, struct wl_pointer *wl_pointer, uint32_t time,
                     uint32_t axis, wl_fixed_t value);
void wl_pointer_frame(void *data, struct wl_pointer *wl_pointer);
void wl_pointer_axis_source(void *data, struct wl_pointer *wl_pointer,
                            uint32_t axis_source);
void wl_pointer_axis_stop(void *data, struct wl_pointer *wl_pointer,
                          uint32_t time, uint32_t axis);
void wl_pointer_axis_discrete(void *data, struct wl_pointer *wl_pointer,
                              enum wl_pointer_axis axis, int32_t discrete);
#if defined(WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
void wl_pointer_axis_value120(void *data, struct wl_pointer *wl_pointer,
                              enum wl_pointer_axis axis, int32_t value120);
#endif

/* The touch callbacks: ported to input.zig (D4e). The listener table in
 * terminal-shim.c references them. */
void wl_touch_down(void *data, struct wl_touch *wl_touch, uint32_t serial,
                   uint32_t time, struct wl_surface *surface, int32_t id,
                   wl_fixed_t surface_x, wl_fixed_t surface_y);
void wl_touch_up(void *data, struct wl_touch *wl_touch, uint32_t serial,
                 uint32_t time, int32_t id);
void wl_touch_motion(void *data, struct wl_touch *wl_touch, uint32_t time,
                     int32_t id, wl_fixed_t surface_x, wl_fixed_t surface_y);
void wl_touch_frame(void *data, struct wl_touch *wl_touch);
void wl_touch_cancel(void *data, struct wl_touch *wl_touch);

void keyboard_modifiers(void *data, struct wl_keyboard *wl_keyboard,
                        uint32_t serial, uint32_t mods_depressed,
                        uint32_t mods_latched, uint32_t mods_locked,
                        uint32_t group);
const struct key_data *keymap_data_for_sym(xkb_keysym_t sym, size_t *count);
const struct key_data *keymap_lookup(struct terminal *term, xkb_keysym_t sym,
                                     enum modifier mods);
/* One key events worth of resolved state: filled in by key_press_release()
 * and consumed by the two protocol encoders. */
struct kbd_ctx {
    xkb_layout_index_t layout;
    xkb_keycode_t key;
    xkb_keysym_t sym;

    struct {
        const xkb_keysym_t *syms;
        size_t count;
    } level0_syms;

    xkb_mod_mask_t mods;
    xkb_mod_mask_t consumed;

    struct {
        const uint8_t *buf;
        size_t count;
    } utf8;
    uint32_t *utf32;

    enum xkb_compose_status compose_status;
    enum wl_keyboard_key_state key_state;
};

bool legacy_kbd_protocol(struct seat *seat, struct terminal *term,
                          const struct kbd_ctx *ctx);
bool kitty_kbd_protocol(struct seat *seat, struct terminal *term,
                        const struct kbd_ctx *ctx);
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
void mouse_button_state_reset(struct seat *seat);
bool touch_is_active(const struct seat *seat);
double mouse_scroll_multiplier(const struct terminal *term, const struct seat *seat);
