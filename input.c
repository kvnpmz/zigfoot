#include "input.h"

#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <threads.h>
#include <locale.h>
#include <errno.h>
#include <wctype.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include <sys/epoll.h>
#include <fcntl.h>

#include <linux/input-event-codes.h>

#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <xkbcommon/xkbcommon-compose.h>

#include <xdg-shell.h>

#define LOG_MODULE "input"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "commands.h"
#include "config.h"
#include "grid.h"
#include "keymap.h"
#include "kitty-keymap.h"
#include "macros.h"
#include "quirks.h"
#include "render.h"
#include "search.h"
#include "selection.h"
#include "spawn.h"
#include "terminal.h"
#include "tokenize.h"
#include "unicode-mode.h"
#include "url-mode.h"
#include "util.h"
#include "vt.h"
#include "xkbcommon-vmod.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* fdm_write_pipe() and execute_binding() are in input.zig (D4a/D4c). */

/* keymap_data_for_sym() and keymap_lookup() are in input.zig (D4b2); the
 * key tables moved with them. */

UNITTEST
{
    struct terminal term = {
        .num_lock_modifier = false,
        .keypad_keys_mode = KEYPAD_NUMERICAL,
        .cursor_keys_mode = CURSOR_KEYS_NORMAL,
    };

    const struct key_data *info = keymap_lookup(&term, XKB_KEY_ISO_Left_Tab, MOD_SHIFT | MOD_CTRL);
    xassert(info != NULL);
    xassert(streq(info->seq, "\033[27;6;9~"));
}

UNITTEST
{
    struct terminal term = {
        .modify_other_keys_2 = false,
    };

    const struct key_data *info = keymap_lookup(&term, XKB_KEY_Return, MOD_ALT);
    xassert(info != NULL);
    xassert(streq(info->seq, "\033\r"));

    term.modify_other_keys_2 = true;
    info = keymap_lookup(&term, XKB_KEY_Return, MOD_ALT);
    xassert(info != NULL);
    xassert(streq(info->seq, "\033[27;3;13~"));
}


/* legacy_kbd_protocol() and kitty_kbd_protocol() are in input.zig (D4b2b). */
/* key_press_release() is in input.zig (D4b4). */

/* keyboard_modifiers(), keyboard_key(), input_repeat() and
 * key_press_release() live in input.zig (D4b3/D4b4); this UNITTEST still
 * exercises them, with a real keymap and the kitty flag combinations, through
 * the Zig protocol encoders. */

UNITTEST
{
    int chan[2];
    xassert(pipe2(chan, O_CLOEXEC) == 0);

    xassert(chan[0] >= 0);
    xassert(chan[1] >= 0);

    struct config conf = {0};
    struct grid grid = {0};

    struct terminal term = {
        .conf = &conf,
        .grid = &grid,
        .ptmx = chan[1],
        .selection = {
            .coords = {
                .start = {-1, -1},
                .end = {-1, -1},
            },
            .auto_scroll = {
                .fd = -1,
             },
        },
    };

    struct key_binding_manager *key_binding_manager = key_binding_manager_new();

    struct wayland wayl = {
        .key_binding_manager = key_binding_manager,
        .terms = tll_init(),
    };

    struct seat seat = {
        .wayl = &wayl,
        .name = "unittest",
    };

    tll_push_back(wayl.terms, &term);
    term.wl = &wayl;

    seat.kbd.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    xassert(seat.kbd.xkb != NULL);

    grid.kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE | KITTY_KBD_REPORT_ALTERNATE;

    /* Swedish keymap */
    {
        seat.kbd.xkb_keymap = xkb_keymap_new_from_names(
            seat.kbd.xkb, &(struct xkb_rule_names){.layout = "se"}, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (seat.kbd.xkb_keymap == NULL) {
            /* Skip test */
            goto no_keymap;
        }

        seat.kbd.xkb_state = xkb_state_new(seat.kbd.xkb_keymap);
        xassert(seat.kbd.xkb_state != NULL);

        seat.kbd.mod_shift = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_SHIFT);
        seat.kbd.mod_alt = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_ALT) ;
        seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CTRL);
        seat.kbd.mod_super = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_LOGO);
        seat.kbd.mod_caps = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CAPS);
        seat.kbd.mod_num = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_NUM);

        /* Significant modifiers in the legacy keyboard protocol */
        seat.kbd.legacy_significant = 0;
        if (seat.kbd.mod_shift != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_shift;
        if (seat.kbd.mod_alt != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_alt;
        if (seat.kbd.mod_ctrl != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_ctrl;
        if (seat.kbd.mod_super != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_super;

        /* Significant modifiers in the kitty keyboard protocol */
        seat.kbd.kitty_significant = seat.kbd.legacy_significant;
        if (seat.kbd.mod_caps != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_caps;
        if (seat.kbd.mod_num != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_num;

        key_binding_new_for_seat(key_binding_manager, &seat);
        key_binding_load_keymap(key_binding_manager, &seat);

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_shift | 1u << seat.kbd.mod_ctrl;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_A + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key: 97 = 'a', alternate: 65 = 'A', base: N/A, mods: 6 = ctrl+shift */
            const char expected_ctrl_shift_a[] = "\033[97:65;6u";
            xassert(count == strlen(expected_ctrl_shift_a));
            xassert(streq(escape, expected_ctrl_shift_a));

            key_press_release(&seat, &term, 1337, KEY_A + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_shift | 1u << seat.kbd.mod_alt;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_2 + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key;. 50 = '2', alternate: 34 = '"', base: N/A, 4 = alt+shift */
            const char expected_alt_shift_2[] = "\033[50:34;4u";
            xassert(count == strlen(expected_alt_shift_2));
            xassert(streq(escape, expected_alt_shift_2));

            key_press_release(&seat, &term, 1337, KEY_2 + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_index_t alt_gr = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, "Mod5");
            xassert(alt_gr != XKB_MOD_INVALID);

            xkb_mod_mask_t mods = 1u << seat.kbd.mod_shift | 1u << seat.kbd.mod_alt | 1u << alt_gr;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_2 + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key; 178 = '²', alternate: N/A, base: 50 = '2', 4 = alt+shift (AltGr not part of the protocol) */
            const char expected_altgr_alt_shift_2[] = "\033[178::50;4u";
            xassert(count == strlen(expected_altgr_alt_shift_2));
            xassert(streq(escape, expected_altgr_alt_shift_2));

            key_press_release(&seat, &term, 1337, KEY_2 + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_alt;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_BACKSPACE + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key; 127 = <backspace>, alternate: N/A, base: N/A, 3 = alt */
            const char expected_alt_backspace[] = "\033[127;3u";
            xassert(count == strlen(expected_alt_backspace));
            xassert(streq(escape, expected_alt_backspace));

            key_press_release(&seat, &term, 1337, KEY_BACKSPACE + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_ctrl;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_ENTER + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key; 13 = <enter>, alternate: N/A, base: N/A, 5 = ctrl */
            const char expected_ctrl_enter[] = "\033[13;5u";
            xassert(count == strlen(expected_ctrl_enter));
            xassert(streq(escape, expected_ctrl_enter));

            key_press_release(&seat, &term, 1337, KEY_ENTER + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_ctrl;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_TAB + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key; 9 = <tab>, alternate: N/A, base: N/A, 5 = ctrl */
            const char expected_ctrl_tab[] = "\033[9;5u";
            xassert(count == strlen(expected_ctrl_tab));
            xassert(streq(escape, expected_ctrl_tab));

            key_press_release(&seat, &term, 1337, KEY_TAB + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        {
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_ctrl | 1u << seat.kbd.mod_shift;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 0);
            key_press_release(&seat, &term, 1337, KEY_LEFT + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            const char expected_ctrl_shift_left[] = "\033[1;6D";
            xassert(count == strlen(expected_ctrl_shift_left));
            xassert(streq(escape, expected_ctrl_shift_left));

            key_press_release(&seat, &term, 1337, KEY_LEFT + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }
        key_binding_unload_keymap(key_binding_manager, &seat);
        key_binding_remove_seat(key_binding_manager, &seat);

        xkb_state_unref(seat.kbd.xkb_state);
        xkb_keymap_unref(seat.kbd.xkb_keymap);

        seat.kbd.xkb_state = NULL;
        seat.kbd.xkb_keymap = NULL;
    }

    /* de(neo) keymap */
    {
        seat.kbd.xkb_keymap = xkb_keymap_new_from_names(
            seat.kbd.xkb, &(struct xkb_rule_names){.layout = "us,de(neo)"},
            XKB_KEYMAP_COMPILE_NO_FLAGS);

        if (seat.kbd.xkb_keymap == NULL) {
            /* Skip test */
            goto no_keymap;
        }

        seat.kbd.xkb_state = xkb_state_new(seat.kbd.xkb_keymap);
        xassert(seat.kbd.xkb_state != NULL);

        seat.kbd.mod_shift = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_SHIFT);
        seat.kbd.mod_alt = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_ALT) ;
        seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CTRL);
        seat.kbd.mod_super = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_LOGO);
        seat.kbd.mod_caps = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CAPS);
        seat.kbd.mod_num = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_NUM);

        /* Significant modifiers in the legacy keyboard protocol */
        seat.kbd.legacy_significant = 0;
        if (seat.kbd.mod_shift != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_shift;
        if (seat.kbd.mod_alt != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_alt;
        if (seat.kbd.mod_ctrl != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_ctrl;
        if (seat.kbd.mod_super != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_super;

        /* Significant modifiers in the kitty keyboard protocol */
        seat.kbd.kitty_significant = seat.kbd.legacy_significant;
        if (seat.kbd.mod_caps != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_caps;
        if (seat.kbd.mod_num != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_num;

        key_binding_new_for_seat(key_binding_manager, &seat);
        key_binding_load_keymap(key_binding_manager, &seat);

        {
            /*
             * In the de(neo) layout, the Y key generates 'k'. This
             * means we should get a key+alternate that indicates 'k',
             * but a base key that is 'y'.
             */
            xkb_mod_mask_t mods = 1u << seat.kbd.mod_shift | 1u << seat.kbd.mod_alt;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 1);
            key_press_release(&seat, &term, 1337, KEY_Y + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key: 107 = 'k', alternate: 75 = 'K', base: 121 = 'y', mods: 4 = alt+shift */
            const char expected_alt_shift_y[] = "\033[107:75:121;4u";
            xassert(count == strlen(expected_alt_shift_y));
            xassert(streq(escape, expected_alt_shift_y));

            key_press_release(&seat, &term, 1337, KEY_Y + 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        }

        key_binding_unload_keymap(key_binding_manager, &seat);
        key_binding_remove_seat(key_binding_manager, &seat);

        xkb_state_unref(seat.kbd.xkb_state);
        xkb_keymap_unref(seat.kbd.xkb_keymap);

        seat.kbd.xkb_state = NULL;
        seat.kbd.xkb_keymap = NULL;
    }

    /* us(intl) keymap */
    {
        seat.kbd.xkb_keymap = xkb_keymap_new_from_names(
            seat.kbd.xkb, &(struct xkb_rule_names){.layout = "us", .variant = "intl"},
            XKB_KEYMAP_COMPILE_NO_FLAGS);

        if (seat.kbd.xkb_keymap == NULL) {
            /* Skip test */
            goto no_keymap;
        }

        seat.kbd.xkb_state = xkb_state_new(seat.kbd.xkb_keymap);
        xassert(seat.kbd.xkb_state != NULL);

        seat.kbd.xkb_compose_table = xkb_compose_table_new_from_locale(
            seat.kbd.xkb, setlocale(LC_CTYPE, NULL), XKB_COMPOSE_COMPILE_NO_FLAGS);
        if (seat.kbd.xkb_compose_table == NULL)
            goto no_keymap;

        seat.kbd.xkb_compose_state = xkb_compose_state_new(
            seat.kbd.xkb_compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
        if (seat.kbd.xkb_compose_state == NULL) {
            xkb_compose_table_unref(seat.kbd.xkb_compose_table);
            goto no_keymap;
        }

        seat.kbd.mod_shift = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_SHIFT);
        seat.kbd.mod_alt = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_ALT) ;
        seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CTRL);
        seat.kbd.mod_super = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_LOGO);
        seat.kbd.mod_caps = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_CAPS);
        seat.kbd.mod_num = xkb_keymap_mod_get_index(seat.kbd.xkb_keymap, XKB_MOD_NAME_NUM);

        /* Significant modifiers in the legacy keyboard protocol */
        seat.kbd.legacy_significant = 0;
        if (seat.kbd.mod_shift != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_shift;
        if (seat.kbd.mod_alt != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_alt;
        if (seat.kbd.mod_ctrl != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_ctrl;
        if (seat.kbd.mod_super != XKB_MOD_INVALID)
            seat.kbd.legacy_significant |= 1 << seat.kbd.mod_super;

        /* Significant modifiers in the kitty keyboard protocol */
        seat.kbd.kitty_significant = seat.kbd.legacy_significant;
        if (seat.kbd.mod_caps != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_caps;
        if (seat.kbd.mod_num != XKB_MOD_INVALID)
            seat.kbd.kitty_significant |= 1 << seat.kbd.mod_num;

        key_binding_new_for_seat(key_binding_manager, &seat);
        key_binding_load_keymap(key_binding_manager, &seat);

        {
            /*
             * Test the compose sequence "shift+', shift+space"
             *
             * Should result in a double quote, but a regression
             * caused it to instead emit a space. See #1987
             *
             * Note: "shift+', space" also results in a double quote,
             * but never regressed to a space.
             */
            grid.kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE;
            xkb_compose_state_reset(seat.kbd.xkb_compose_state);

            xkb_mod_mask_t mods = 1u << seat.kbd.mod_shift;
            keyboard_modifiers(&seat, NULL, 1337, mods, 0, 0, 1);

            key_press_release(&seat, &term, 1337, KEY_APOSTROPHE + 8, WL_KEYBOARD_KEY_STATE_PRESSED);
            key_press_release(&seat, &term, 1337, KEY_APOSTROPHE + 8, WL_KEYBOARD_KEY_STATE_RELEASED);

            key_press_release(&seat, &term, 1337, KEY_SPACE + 8, WL_KEYBOARD_KEY_STATE_PRESSED);

            char escape[64] = {0};
            ssize_t count = read(chan[0], escape, sizeof(escape));

            /* key: 34 = '"', alternate: N/A, base: N/A, mods: 2 = shift */
            const char expected_shift_apostrophe[] = "\033[34;2u";
            xassert(count == strlen(expected_shift_apostrophe));
            xassert(streq(escape, expected_shift_apostrophe));

            key_press_release(&seat, &term, 1337, KEY_SPACE + 8, WL_KEYBOARD_KEY_STATE_RELEASED);

            grid.kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE | KITTY_KBD_REPORT_ALTERNATE;
        }

        key_binding_unload_keymap(key_binding_manager, &seat);
        key_binding_remove_seat(key_binding_manager, &seat);

        xkb_compose_state_unref(seat.kbd.xkb_compose_state);
        xkb_compose_table_unref(seat.kbd.xkb_compose_table);

        xkb_state_unref(seat.kbd.xkb_state);
        xkb_keymap_unref(seat.kbd.xkb_keymap);

        seat.kbd.xkb_state = NULL;
        seat.kbd.xkb_keymap = NULL;
    }

no_keymap:
    xkb_context_unref(seat.kbd.xkb);
    key_binding_manager_destroy(key_binding_manager);

    tll_free(wayl.terms);
    close(chan[0]);
    close(chan[1]);
}

const struct wl_keyboard_listener keyboard_listener = {
    .keymap = &keyboard_keymap,
    .enter = &keyboard_enter,
    .leave = &keyboard_leave,
    .key = &keyboard_key,
    .modifiers = &keyboard_modifiers,
    .repeat_info = &keyboard_repeat_info,
};

/* is_top_left() .. xcursor_for_csd_border(): ported to terminal.zig (chunk
 * C2). They are still called from here, via input.h. */

/* wl_pointer_enter() .. wl_pointer_axis_stop() are ported to input.zig
 * (D4d2b). The listener table below still references them, via input.h. */

const struct wl_pointer_listener pointer_listener = {
    .enter = &wl_pointer_enter,
    .leave = &wl_pointer_leave,
    .motion = &wl_pointer_motion,
    .button = &wl_pointer_button,
    .axis = &wl_pointer_axis,
    .frame = &wl_pointer_frame,
    .axis_source = &wl_pointer_axis_source,
    .axis_stop = &wl_pointer_axis_stop,
    .axis_discrete = &wl_pointer_axis_discrete,
#if defined(WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
    .axis_value120 = &wl_pointer_axis_value120,
#endif
};

static bool
touch_to_scroll(struct seat *seat, struct terminal *term,
                wl_fixed_t surface_x, wl_fixed_t surface_y)
{
    bool coord_updated = false;

    int y = wl_fixed_to_int(surface_y) * term->scale;
    int rows = (y - seat->mouse.y) / term->cell_height;
    if (rows != 0) {
        mouse_scroll(seat, -rows, WL_POINTER_AXIS_VERTICAL_SCROLL);
        seat->mouse.y += rows * term->cell_height;
        coord_updated = true;
    }

    int x = wl_fixed_to_int(surface_x) * term->scale;
    int cols = (x - seat->mouse.x) / term->cell_width;
    if (cols != 0) {
        mouse_scroll(seat, -cols, WL_POINTER_AXIS_HORIZONTAL_SCROLL);
        seat->mouse.x += cols * term->cell_width;
        coord_updated = true;
    }

    return coord_updated;
}

static void
wl_touch_down(void *data, struct wl_touch *wl_touch, uint32_t serial,
              uint32_t time, struct wl_surface *surface, int32_t id,
              wl_fixed_t surface_x, wl_fixed_t surface_y)
{
    struct seat *seat = data;

    if (seat->touch.state != TOUCH_STATE_IDLE)
        return;

    struct wl_window *win = wl_surface_get_user_data(surface);
    struct terminal *term = win->term;

    LOG_DBG("touch_down: touch=%p, x=%d, y=%d", (void *)wl_touch,
            wl_fixed_to_int(surface_x), wl_fixed_to_int(surface_y));

    int x = wl_fixed_to_int(surface_x) * term->scale;
    int y = wl_fixed_to_int(surface_y) * term->scale;

    seat->mouse.x = x;
    seat->mouse.y = y;
    mouse_coord_pixel_to_cell(seat, term, x, y);

    seat->touch.state = TOUCH_STATE_HELD;
    seat->touch.serial = serial;
    seat->touch.time = time + term->conf->touch.long_press_delay;
    seat->touch.surface = surface;
    seat->touch.surface_kind = term_surface_kind(term, surface);
    seat->touch.id = id;
}

static void
wl_touch_up(void *data, struct wl_touch *wl_touch, uint32_t serial,
            uint32_t time, int32_t id)
{
    struct seat *seat = data;

    if (seat->touch.state <= TOUCH_STATE_IDLE || id != seat->touch.id)
        return;

    LOG_DBG("touch_up: touch=%p", (void *)wl_touch);

    struct wl_window *win = wl_surface_get_user_data(seat->touch.surface);
    struct terminal *term = win->term;

    struct terminal *old_term = seat->mouse_focus;
    enum term_surface old_active_surface = term->active_surface;
    seat->mouse_focus = term;
    term->active_surface = seat->touch.surface_kind;

    switch (seat->touch.state) {
    case TOUCH_STATE_HELD:
        wl_pointer_button(seat, NULL, seat->touch.serial, time, BTN_LEFT,
                          WL_POINTER_BUTTON_STATE_PRESSED);
        /* fallthrough */
    case TOUCH_STATE_DRAGGING:
        wl_pointer_button(seat, NULL, serial, time, BTN_LEFT,
                          WL_POINTER_BUTTON_STATE_RELEASED);
        /* fallthrough */
    case TOUCH_STATE_SCROLLING:
        term->active_surface = TERM_SURF_NONE;
        seat->touch.state = TOUCH_STATE_IDLE;
        break;

    case TOUCH_STATE_INHIBITED:
    case TOUCH_STATE_IDLE:
        BUG("Bad touch state: %d", seat->touch.state);
        break;
    }

    seat->mouse_focus = old_term;
    term->active_surface = old_active_surface;
}

static void
wl_touch_motion(void *data, struct wl_touch *wl_touch, uint32_t time,
                int32_t id, wl_fixed_t surface_x, wl_fixed_t surface_y)
{
    struct seat *seat = data;
    if (seat->touch.state <= TOUCH_STATE_IDLE || id != seat->touch.id)
        return;

    LOG_DBG("touch_motion: touch=%p, x=%d, y=%d", (void *)wl_touch,
            wl_fixed_to_int(surface_x), wl_fixed_to_int(surface_y));

    struct wl_window *win = wl_surface_get_user_data(seat->touch.surface);
    struct terminal *term = win->term;

    struct terminal *old_term = seat->mouse_focus;
    enum term_surface old_active_surface = term->active_surface;
    seat->mouse_focus = term;
    term->active_surface = seat->touch.surface_kind;

    switch (seat->touch.state) {
    case TOUCH_STATE_HELD:
        if (time <= seat->touch.time && term->active_surface == TERM_SURF_GRID) {
            if (touch_to_scroll(seat, term, surface_x, surface_y))
                seat->touch.state = TOUCH_STATE_SCROLLING;
            break;
        } else {
            wl_pointer_button(seat, NULL, seat->touch.serial, time, BTN_LEFT,
                              WL_POINTER_BUTTON_STATE_PRESSED);
            seat->touch.state = TOUCH_STATE_DRAGGING;
            /* fallthrough */
        }
    case TOUCH_STATE_DRAGGING:
        wl_pointer_motion(seat, NULL, time, surface_x, surface_y);
        break;
    case TOUCH_STATE_SCROLLING:
        touch_to_scroll(seat, term, surface_x, surface_y);
        break;

    case TOUCH_STATE_INHIBITED:
    case TOUCH_STATE_IDLE:
        BUG("Bad touch state: %d", seat->touch.state);
        break;
    }

    seat->mouse_focus = old_term;
    term->active_surface = old_active_surface;
}

static void
wl_touch_frame(void *data, struct wl_touch *wl_touch)
{
}

static void
wl_touch_cancel(void *data, struct wl_touch *wl_touch)
{
    struct seat *seat = data;
    if (seat->touch.state == TOUCH_STATE_INHIBITED)
        return;

    seat->touch.state = TOUCH_STATE_IDLE;
}

const struct wl_touch_listener touch_listener = {
    .down = wl_touch_down,
    .up = wl_touch_up,
    .motion = wl_touch_motion,
    .frame = wl_touch_frame,
    .cancel = wl_touch_cancel,
};
