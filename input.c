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

struct pipe_context {
    char *text;
    size_t idx;
    size_t left;
};

static void alternate_scroll(struct seat *seat, int amount, int button);

static bool
execute_binding(struct seat *seat, struct terminal *term,
                const struct key_binding *binding, uint32_t serial, int amount)
{
    const enum bind_action_normal action = binding->action;

    switch (action) {
    case BIND_ACTION_NONE:
        return true;

    case BIND_ACTION_NOOP:
        return true;

    case BIND_ACTION_SCROLLBACK_UP_PAGE:
        if (term->grid == &term->normal) {
            cmd_scrollback_up(term, term->rows);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_UP_HALF_PAGE:
        if (term->grid == &term->normal) {
            cmd_scrollback_up(term, max(term->rows / 2, 1));
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_UP_LINE:
        if (term->grid == &term->normal) {
            cmd_scrollback_up(term, 1);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_UP_MOUSE:
        if (term->grid == &term->alt) {
            if (term->alt_scrolling) {
                alternate_scroll(seat, amount, BTN_BACK);
                return true;
            }
        } else {
            cmd_scrollback_up(term, amount);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_DOWN_PAGE:
        if (term->grid == &term->normal) {
            cmd_scrollback_down(term, term->rows);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_DOWN_HALF_PAGE:
        if (term->grid == &term->normal) {
            cmd_scrollback_down(term, max(term->rows / 2, 1));
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_DOWN_LINE:
        if (term->grid == &term->normal) {
            cmd_scrollback_down(term, 1);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_DOWN_MOUSE:
        if (term->grid == &term->alt) {
            if (term->alt_scrolling) {
                alternate_scroll(seat, amount, BTN_FORWARD);
                return true;
            }
        } else {
            cmd_scrollback_down(term, amount);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_HOME:
        if (term->grid == &term->normal) {
            cmd_scrollback_up(term, term->grid->num_rows);
            return true;
        }
        break;

    case BIND_ACTION_SCROLLBACK_END:
        if (term->grid == &term->normal) {
            cmd_scrollback_down(term, term->grid->num_rows);
            return true;
        }
        break;

    case BIND_ACTION_CLIPBOARD_COPY:
        selection_to_clipboard(seat, term, serial);
        return true;

    case BIND_ACTION_CLIPBOARD_PASTE:
        selection_from_clipboard(seat, term, serial);
        term_reset_view(term);
        return true;

    case BIND_ACTION_PRIMARY_PASTE:
        selection_from_primary(seat, term);
        term_reset_view(term);
        return true;

    case BIND_ACTION_SEARCH_START:
        search_begin(term);
        return true;

    case BIND_ACTION_FONT_SIZE_UP:
        term_font_size_increase(term);
        return true;

    case BIND_ACTION_FONT_SIZE_DOWN:
        term_font_size_decrease(term);
        return true;

    case BIND_ACTION_FONT_SIZE_RESET:
        term_font_size_reset(term);
        return true;

    case BIND_ACTION_SPAWN_TERMINAL:
        term_spawn_new(term);
        return true;

    case BIND_ACTION_MINIMIZE:
        xdg_toplevel_set_minimized(term->window->xdg_toplevel);
        return true;

    case BIND_ACTION_MAXIMIZE:
        if (term->window->is_fullscreen)
            xdg_toplevel_unset_fullscreen(term->window->xdg_toplevel);
        if (term->window->is_maximized)
            xdg_toplevel_unset_maximized(term->window->xdg_toplevel);
        else
            xdg_toplevel_set_maximized(term->window->xdg_toplevel);
        return true;

    case BIND_ACTION_FULLSCREEN:
        if (term->window->is_fullscreen)
            xdg_toplevel_unset_fullscreen(term->window->xdg_toplevel);
        else
            xdg_toplevel_set_fullscreen(term->window->xdg_toplevel, NULL);
        return true;

    case BIND_ACTION_PIPE_SCROLLBACK:
        if (term->grid == &term->alt)
            break;
        /* FALLTHROUGH */
    case BIND_ACTION_PIPE_VIEW:
    case BIND_ACTION_PIPE_SELECTED:
    case BIND_ACTION_PIPE_COMMAND_OUTPUT: {
        if (binding->aux->type != BINDING_AUX_PIPE)
            return true;

        struct pipe_context *ctx = NULL;

        int pipe_fd[2] = {-1, -1};
        int stdout_fd = -1;
        int stderr_fd = -1;

        char *text = NULL;
        size_t len = 0;

        if (pipe(pipe_fd) < 0) {
            LOG_ERRNO("failed to create pipe");
            goto pipe_err;
        }

        stdout_fd = open("/dev/null", O_WRONLY);
        stderr_fd = open("/dev/null", O_WRONLY);

        if (stdout_fd < 0 || stderr_fd < 0) {
            LOG_ERRNO("failed to open /dev/null");
            goto pipe_err;
        }

        bool success;
        switch (action) {
        case BIND_ACTION_PIPE_SCROLLBACK:
            success = term_scrollback_to_text(term, &text, &len);
            break;

        case BIND_ACTION_PIPE_VIEW:
            success = term_view_to_text(term, &text, &len);
            break;

        case BIND_ACTION_PIPE_SELECTED:
            text = selection_to_text(term);
            success = text != NULL;
            len = text != NULL ? strlen(text) : 0;
            break;

        case BIND_ACTION_PIPE_COMMAND_OUTPUT:
            success = term_command_output_to_text(term, &text, &len);
            break;

        default:
            BUG("Unhandled action type");
            success = false;
            break;
        }

        if (!success)
            goto pipe_err;

        /* Make write-end non-blocking; required by the FDM */
        {
            int flags = fcntl(pipe_fd[1], F_GETFL);
            if (flags < 0 ||
                fcntl(pipe_fd[1], F_SETFL, flags | O_NONBLOCK) < 0)
            {
                LOG_ERRNO("failed to make write-end of pipe non-blocking");
                goto pipe_err;
            }
        }

        /* Make sure write-end is closed on exec() - or the spawned
         * program may not terminate*/
        {
            int flags = fcntl(pipe_fd[1], F_GETFD);
            if (flags < 0 ||
                fcntl(pipe_fd[1], F_SETFD, flags | FD_CLOEXEC) < 0)
            {
                LOG_ERRNO("failed to set FD_CLOEXEC on writeend of pipe");
                goto pipe_err;
            }
        }

        if (spawn(term->reaper, term->cwd, binding->aux->pipe.args,
                  pipe_fd[0], stdout_fd, stderr_fd, NULL, NULL, NULL) < 0)
            goto pipe_err;

        /* Close read end */
        close(pipe_fd[0]);

        ctx = xmalloc(sizeof(*ctx));
        *ctx = (struct pipe_context){
            .text = text,
            .left = len,
        };

        /* Asynchronously write the output to the pipe */
        if (!fdm_add(term->fdm, pipe_fd[1], EPOLLOUT, &fdm_write_pipe, ctx))
            goto pipe_err;

        return true;

        pipe_err:
        if (stdout_fd >= 0)
            close(stdout_fd);
        if (stderr_fd >= 0)
            close(stderr_fd);
        if (pipe_fd[0] >= 0)
            close(pipe_fd[0]);
        if (pipe_fd[1] >= 0)
            close(pipe_fd[1]);
        free(text);
        free(ctx);
        return true;
    }

    case BIND_ACTION_SHOW_URLS_COPY:
    case BIND_ACTION_SHOW_URLS_LAUNCH:
    case BIND_ACTION_SHOW_URLS_PERSISTENT: {
        xassert(!urls_mode_is_active(term));

        enum url_action url_action =
            action == BIND_ACTION_SHOW_URLS_COPY ? URL_ACTION_COPY :
            action == BIND_ACTION_SHOW_URLS_LAUNCH ? URL_ACTION_LAUNCH :
            URL_ACTION_PERSISTENT;

        urls_collect(term, url_action, &term->conf->url.preg, true, &term->url.list);
        urls_assign_key_combos(term->conf, &term->url.list);
        urls_render(term, &term->conf->url.launch);
        return true;
    }

    case BIND_ACTION_TEXT_BINDING:
        xassert(binding->aux->type == BINDING_AUX_TEXT);
        term_to_slave(term, binding->aux->text.data, binding->aux->text.len);
        return true;

    case BIND_ACTION_PROMPT_PREV: {
        if (term->grid != &term->normal)
            return false;

        struct grid *grid = term->grid;
        const int sb_start =
            grid_sb_start_ignore_uninitialized(grid, term->rows);

        /* Check each row from current view-1 (that is, the first
         * currently not visible row), up to, and including, the
         * scrollback start */
        for (int r_sb_rel =
                 grid_row_abs_to_sb_precalc_sb_start(
                     grid, sb_start, grid->view) - 1;
             r_sb_rel >= 0; r_sb_rel--)
        {
            const int r_abs =
                grid_row_sb_to_abs_precalc_sb_start(grid, sb_start, r_sb_rel);

            const struct row *row = grid->rows[r_abs];
            xassert(row != NULL);

            if (!row->shell_integration.prompt_marker)
                continue;

            grid->view = r_abs;
            term_damage_view(term);
            render_refresh(term);
            break;
        }

        return true;
    }

    case BIND_ACTION_PROMPT_NEXT: {
        if (term->grid != &term->normal)
            return false;

        struct grid *grid = term->grid;
        const int num_rows = grid->num_rows;

        if (grid->view == grid->offset) {
            /* Already at the bottom */
            return true;
        }

        /* Check each row from view+1, to the bottom of the scrollback */
        for (int r_abs = (grid->view + 1) & (num_rows - 1);
             ;
             r_abs = (r_abs + 1) & (num_rows - 1))
        {
            const struct row *row = grid->rows[r_abs];
            xassert(row != NULL);

            if (!row->shell_integration.prompt_marker) {
                if (r_abs == grid->offset + term->rows - 1) {
                    /* We've reached the bottom of the scrollback */
                    break;
                }
                continue;
            }

            int sb_start = grid_sb_start_ignore_uninitialized(grid, term->rows);
            int ofs_sb_rel =
                grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, grid->offset);
            int new_view_sb_rel =
                grid_row_abs_to_sb_precalc_sb_start(grid, sb_start, r_abs);

            new_view_sb_rel = min(ofs_sb_rel, new_view_sb_rel);
            grid->view = grid_row_sb_to_abs_precalc_sb_start(
                grid, sb_start, new_view_sb_rel);

            term_damage_view(term);
            render_refresh(term);
            break;
        }

        return true;
    }

    case BIND_ACTION_UNICODE_INPUT:
        unicode_mode_activate(term);
        return true;

    case BIND_ACTION_QUIT:
        term_shutdown(term);
        return true;

    case BIND_ACTION_REGEX_LAUNCH:
    case BIND_ACTION_REGEX_COPY:
        if (binding->aux->type != BINDING_AUX_REGEX)
            return true;

        tll_foreach(term->conf->custom_regexes, it) {
            const struct custom_regex *regex = &it->item;

            if (streq(regex->name, binding->aux->regex_name)) {
                xassert(!urls_mode_is_active(term));

                enum url_action url_action = action == BIND_ACTION_REGEX_LAUNCH
                    ? URL_ACTION_LAUNCH : URL_ACTION_COPY;

                if (regex->regex == NULL) {
                    LOG_ERR("regex:%s has no regex defined", regex->name);
                    return true;
                }
                if (url_action == URL_ACTION_LAUNCH && regex->launch.argv.args == NULL) {
                    LOG_ERR("regex:%s has no launch command defined", regex->name);
                    return true;
                }

                urls_collect(term, url_action, &regex->preg, false, &term->url.list);
                urls_assign_key_combos(term->conf, &term->url.list);
                urls_render(term, &regex->launch);
                return true;
            }
        }

        LOG_ERR(
            "no regex section named '%s' defined in the configuration",
            binding->aux->regex_name);

        return true;

    case BIND_ACTION_THEME_SWITCH_DARK:
        term_theme_switch_to_dark(term);
        return true;

    case BIND_ACTION_THEME_SWITCH_LIGHT:
        term_theme_switch_to_light(term);
        return true;

    case BIND_ACTION_THEME_TOGGLE:
        term_theme_toggle(term);
        return true;

    case BIND_ACTION_SELECT_BEGIN:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_CHAR_WISE, false);
        return true;

    case BIND_ACTION_SELECT_BEGIN_BLOCK:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_BLOCK, false);
        return true;

    case BIND_ACTION_SELECT_EXTEND:
        selection_extend(
            seat, term, seat->mouse.col, seat->mouse.row, term->selection.kind);
        return true;

    case BIND_ACTION_SELECT_EXTEND_CHAR_WISE:
        if (term->selection.kind != SELECTION_BLOCK) {
            selection_extend(
                seat, term, seat->mouse.col, seat->mouse.row, SELECTION_CHAR_WISE);
            return true;
        }
        return false;

    case BIND_ACTION_SELECT_WORD:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_WORD_WISE, false);
        return true;

    case BIND_ACTION_SELECT_WORD_WS:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_WORD_WISE, true);
        return true;

    case BIND_ACTION_SELECT_QUOTE:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_QUOTE_WISE, false);
        return true;

    case BIND_ACTION_SELECT_ROW:
        selection_start(
            term, seat->mouse.col, seat->mouse.row, SELECTION_LINE_WISE, false);
        return true;

    case BIND_ACTION_COUNT:
        BUG("Invalid action type");
        return false;
    }

    return false;
}

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
static void
key_press_release(struct seat *seat, struct terminal *term, uint32_t serial,
                  uint32_t key, uint32_t state)
{
    xassert(serial != 0);

    seat->kbd.serial = serial;
    if (seat->kbd.xkb == NULL ||
        seat->kbd.xkb_keymap == NULL ||
        seat->kbd.xkb_state == NULL)
    {
        return;
    }

    const bool pressed = state == WL_KEYBOARD_KEY_STATE_PRESSED;
    //const bool repeated = pressed && seat->kbd.repeat.dont_re_repeat;
    const bool released = state == WL_KEYBOARD_KEY_STATE_RELEASED;

    if (released)
        stop_repeater(seat, key);

    if (pressed)
        seat->kbd.last_shortcut_sym = XKB_KEYSYM_MAX + 1;

    bool should_repeat =
        pressed && xkb_keymap_key_repeats(seat->kbd.xkb_keymap, key);

    xkb_keysym_t sym = xkb_state_key_get_one_sym(seat->kbd.xkb_state, key);

    if (pressed && term->conf->mouse.hide_when_typing && !keysym_is_modifier(sym)) {
        seat->pointer.hidden = true;
        term_xcursor_update_for_seat(term, seat);
    }

    enum xkb_compose_status compose_status = XKB_COMPOSE_NOTHING;

    if (seat->kbd.xkb_compose_state != NULL) {
        if (pressed)
            xkb_compose_state_feed(seat->kbd.xkb_compose_state, sym);
        compose_status = xkb_compose_state_get_status(
            seat->kbd.xkb_compose_state);
    }

    const bool composed = compose_status == XKB_COMPOSE_COMPOSED;

    xkb_mod_mask_t mods, consumed;
    get_current_modifiers(seat, &mods, &consumed, key, true);

    xkb_layout_index_t layout_idx =
        xkb_state_key_get_layout(seat->kbd.xkb_state, key);

    const xkb_keysym_t *raw_syms = NULL;
    size_t raw_count = xkb_keymap_key_get_syms_by_level(
        seat->kbd.xkb_keymap, key, layout_idx, 0, &raw_syms);

    const struct key_binding_set *bindings = key_binding_for(
        seat->wayl->key_binding_manager, term->conf, seat);
    xassert(bindings != NULL);

    if (term->unicode_mode.active) {
        if (pressed)
            unicode_mode_input(seat, term, sym);
        return;
    }

    else if (term->is_searching) {
        if (pressed) {
            if (should_repeat)
                start_repeater(seat, key);

            search_input(
                seat, term, bindings, key, sym, mods, consumed,
                raw_syms, raw_count, serial);
        }
        return;
    }

    else  if (urls_mode_is_active(term)) {
        if (pressed) {
            if (should_repeat)
                start_repeater(seat, key);

            urls_input(
                seat, term, bindings, key, sym, mods, consumed,
                raw_syms, raw_count, serial);
        }
        return;
    }

#if defined(_DEBUG) && defined(LOG_ENABLE_DBG) && LOG_ENABLE_DBG
    char sym_name[100];
    xkb_keysym_get_name(sym, sym_name, sizeof(sym_name));

    char active_mods_str[256] = {0};
    char consumed_mods_str[256] = {0};
    char locked_mods_str[256] = {0};

    const xkb_mod_mask_t locked =
        xkb_state_serialize_mods(seat->kbd.xkb_state, XKB_STATE_MODS_LOCKED);

    modifier_string(mods, sizeof(active_mods_str), active_mods_str, seat);
    modifier_string(consumed, sizeof(consumed_mods_str), consumed_mods_str, seat);
    modifier_string(locked, sizeof(locked_mods_str), locked_mods_str, seat);

    LOG_DBG("%s: %s (%u/0x%x), seat=%s, term=%p, serial=%u, "
            "mods=%s (0x%08x), consumed=%s (0x%08x), locked=%s (0x%08x), "
            "repeats=%d",
            pressed ? "pressed" : "released", sym_name, sym, sym,
            seat->name, (void *)term, serial,
            active_mods_str, mods, consumed_mods_str, consumed,
            locked_mods_str, locked, should_repeat);
#endif

    /*
     * User configurable bindings
     */
    if (pressed) {
        /* Match untranslated symbols */
        tll_foreach(bindings->key, it) {
            const struct key_binding *bind = &it->item;

            if (bind->mods != mods || bind->mods == 0)
                continue;

            for (size_t i = 0; i < raw_count; i++) {
                if (bind->k.sym == raw_syms[i] &&
                    execute_binding(seat, term, bind, serial, 1))
                {
                    seat->kbd.last_shortcut_sym = sym;
                    goto maybe_repeat;
                }
            }
        }

        /* Match translated symbol */
        tll_foreach(bindings->key, it) {
            const struct key_binding *bind = &it->item;

            if (bind->k.sym == sym &&
                bind->mods == (mods & ~consumed) &&
                execute_binding(seat, term, bind, serial, 1))
            {
                seat->kbd.last_shortcut_sym = sym;
                goto maybe_repeat;
            }
        }

        /* Match raw key code */
        tll_foreach(bindings->key, it) {
            const struct key_binding *bind = &it->item;

            if (bind->mods != mods || bind->mods == 0)
                continue;

            tll_foreach(bind->k.key_codes, code) {
                if (code->item == key &&
                    execute_binding(seat, term, bind, serial, 1))
                {
                    seat->kbd.last_shortcut_sym = sym;
                    goto maybe_repeat;
                }
            }
        }
    }

    if (released && seat->kbd.last_shortcut_sym == sym) {
        /*
         * Don't process a release event, if it corresponds to a
         * triggered shortcut.
         *
         * 1. If we consumed a key (press) event, we shouldn't emit an
         *    escape for its release event.
         * 2. Ignoring the incorrectness of doing so; this also caused
         *    us to reset the viewport.
         *
         * Background: if the kitty keyboard protocol was enabled,
         * then the viewport was instantly reset to the bottom, after
         * scrolling up.
         */
        //seat->kbd.last_shortcut_sym = XKB_KEYSYM_MAX + 1;
        goto maybe_repeat;
    }

    /*
     * Keys generating escape sequences
     */


    /*
     * Compose, and maybe emit "normal" character
     */

    xassert(seat->kbd.xkb_compose_state != NULL || !composed);

    if (compose_status == XKB_COMPOSE_CANCELLED)
        goto maybe_repeat;

    int count = composed
        ? xkb_compose_state_get_utf8(seat->kbd.xkb_compose_state, NULL, 0)
        : xkb_state_key_get_utf8(seat->kbd.xkb_state, key, NULL, 0);

    /* Buffer for translated key. Use a static buffer in most cases,
     * and use a malloc:ed buffer when necessary */
    uint8_t buf[32];
    uint8_t *utf8 = count < sizeof(buf) ? buf : xmalloc(count + 1);
    uint32_t *utf32 = NULL;

    if (composed) {
        xkb_compose_state_get_utf8(
            seat->kbd.xkb_compose_state, (char *)utf8, count + 1);

        if (count > 0)
            utf32 = ambstoc32((const char *)utf8);
    } else {
        xkb_state_key_get_utf8(
            seat->kbd.xkb_state, key, (char *)utf8, count + 1);

        utf32 = xcalloc(2, sizeof(utf32[0]));
        utf32[0] = xkb_state_key_get_utf32(seat->kbd.xkb_state, key);
    }

    struct kbd_ctx ctx = {
        .layout = layout_idx,
        .key = key,
        .sym = sym,
        .level0_syms = {
            .syms = raw_syms,
            .count = raw_count,
        },
        .mods = mods,
        .consumed = consumed,
        .utf8 = {
            .buf = utf8,
            .count = count,
        },
        .utf32 = utf32,
        .compose_status = compose_status,
        .key_state = state,
    };

    bool handled = term->grid->kitty_kbd.flags[term->grid->kitty_kbd.idx] != 0
        ? kitty_kbd_protocol(seat, term, &ctx)
        : legacy_kbd_protocol(seat, term, &ctx);

    if (composed && released)
        xkb_compose_state_reset(seat->kbd.xkb_compose_state);

    if (utf8 != buf)
        free(utf8);

    if (handled && !keysym_is_modifier(sym)) {
        term_reset_view(term);
        selection_cancel(term);
    }

    free(utf32);

maybe_repeat:
    clock_gettime(
        term->wl->presentation_clock_id, &term->render.input_time);

    if (should_repeat)
        start_repeater(seat, key);
}

static void
keyboard_key(void *data, struct wl_keyboard *wl_keyboard, uint32_t serial,
             uint32_t time, uint32_t key, uint32_t state)
{
    struct seat *seat = data;
    key_press_release(seat, seat->kbd_focus, serial, key + 8, state);
}

static void
keyboard_modifiers(void *data, struct wl_keyboard *wl_keyboard, uint32_t serial,
                   uint32_t mods_depressed, uint32_t mods_latched,
                   uint32_t mods_locked, uint32_t group)
{
    struct seat *seat = data;

    mods_depressed &= ~seat->kbd.virtual_modifiers;
    mods_latched &= ~seat->kbd.virtual_modifiers;
    mods_locked &= ~seat->kbd.virtual_modifiers;

#if defined(_DEBUG)
    char depressed[256];
    char latched[256];
    char locked[256];

    modifier_string(mods_depressed, sizeof(depressed), depressed, seat);
    modifier_string(mods_latched, sizeof(latched), latched, seat);
    modifier_string(mods_locked, sizeof(locked), locked, seat);

    LOG_DBG(
        "modifiers: depressed=%s (0x%x), latched=%s (0x%x), locked=%s (0x%x), "
        "group=%u",
        depressed, mods_depressed, latched, mods_latched, locked, mods_locked,
        group);
#endif

    if (seat->kbd.xkb_state != NULL) {
        xkb_state_update_mask(
            seat->kbd.xkb_state, mods_depressed, mods_latched, mods_locked, 0, 0, group);

        /* Update state of modifiers we're interested in for e.g mouse events */
        seat->kbd.shift = seat->kbd.mod_shift != XKB_MOD_INVALID
            ? xkb_state_mod_index_is_active(
                seat->kbd.xkb_state, seat->kbd.mod_shift, XKB_STATE_MODS_EFFECTIVE)
            : false;
        seat->kbd.alt = seat->kbd.mod_alt != XKB_MOD_INVALID
            ? xkb_state_mod_index_is_active(
                seat->kbd.xkb_state, seat->kbd.mod_alt, XKB_STATE_MODS_EFFECTIVE)
            : false;
        seat->kbd.ctrl = seat->kbd.mod_ctrl != XKB_MOD_INVALID
            ? xkb_state_mod_index_is_active(
                seat->kbd.xkb_state, seat->kbd.mod_ctrl, XKB_STATE_MODS_EFFECTIVE)
            : false;
        seat->kbd.super = seat->kbd.mod_super != XKB_MOD_INVALID
            ? xkb_state_mod_index_is_active(
                seat->kbd.xkb_state, seat->kbd.mod_super, XKB_STATE_MODS_EFFECTIVE)
            : false;
    }

    if (seat->kbd_focus && seat->kbd_focus->active_surface == TERM_SURF_GRID)
        term_xcursor_update_for_seat(seat->kbd_focus, seat);
}

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

void
input_repeat(struct seat *seat, uint32_t key)
{
    /* Should be cleared as soon as we loose focus */
    xassert(seat->kbd_focus != NULL);
    struct terminal *term = seat->kbd_focus;

    key_press_release(seat, term, seat->kbd.serial, key, XKB_KEY_DOWN);
}

/* is_top_left() .. xcursor_for_csd_border(): ported to terminal.zig (chunk
 * C2). They are still called from here, via input.h. */

static void
mouse_button_state_reset(struct seat *seat)
{
    tll_free(seat->mouse.buttons);
    seat->mouse.count = 0;
    seat->mouse.last_released_button = 0;
    memset(&seat->mouse.last_time, 0, sizeof(seat->mouse.last_time));
}

 void
mouse_coord_pixel_to_cell(struct seat *seat, const struct terminal *term,
                          int x, int y)
{
    /*
     * Translate x,y pixel coordinate to a cell coordinate, or clamp
     * if the cursor is outside the grid. I.e. if it is inside the
     * margins.
     */
    if (x < term->margins.left)
        seat->mouse.col = 0;
    else if (x >= term->width - term->margins.right)
        seat->mouse.col = term->cols - 1;
    else
        seat->mouse.col = (x - term->margins.left) / term->cell_width;

    if (y < term->margins.top)
        seat->mouse.row = 0;
    else if (y >= term->height - term->margins.bottom)
        seat->mouse.row = term->rows - 1;
    else
        seat->mouse.row = (y - term->margins.top) / term->cell_height;
}

static bool
touch_is_active(const struct seat *seat)
{
    if (seat->wl_touch == NULL) {
        return false;
    }

    switch (seat->touch.state) {
    case TOUCH_STATE_IDLE:
    case TOUCH_STATE_INHIBITED:
        return false;

    case TOUCH_STATE_HELD:
    case TOUCH_STATE_DRAGGING:
    case TOUCH_STATE_SCROLLING:
        return true;
    }

    BUG("Bad touch state: %d", seat->touch.state);
    return false;
}

static void
wl_pointer_enter(void *data, struct wl_pointer *wl_pointer,
                 uint32_t serial, struct wl_surface *surface,
                 wl_fixed_t surface_x, wl_fixed_t surface_y)
{
    if (unlikely(surface == NULL))  {
        /* Seen on mutter-3.38 */
        LOG_WARN("compositor sent pointer_enter event with a NULL surface");
        return;
    }

    struct seat *seat = data;

    struct wl_window *win = wl_surface_get_user_data(surface);
    struct terminal *term = win->term;

    seat->mouse_focus = term;
    term->active_surface = term_surface_kind(term, surface);

    if (touch_is_active(seat))
        return;

    int x = wl_fixed_to_int(surface_x) * term->scale;
    int y = wl_fixed_to_int(surface_y) * term->scale;

    seat->pointer.serial = serial;
    seat->pointer.hidden = false;
    seat->mouse.x = x;
    seat->mouse.y = y;

    LOG_DBG("pointer-enter: pointer=%p, serial=%u, surface = %p, new-moused = %p, "
            "x=%d, y=%d",
            (void *)wl_pointer, serial, (void *)surface, (void *)term,
            x, y);

    xassert(tll_length(seat->mouse.buttons) == 0);

    wayl_reload_xcursor_theme(seat, term->scale); /* Scale may have changed */
    term_xcursor_update_for_seat(term, seat);

    switch (term->active_surface) {
    case TERM_SURF_GRID: {
        mouse_coord_pixel_to_cell(seat, term, x, y);
        break;
    }

    case TERM_SURF_TITLE:
    case TERM_SURF_BORDER_LEFT:
    case TERM_SURF_BORDER_RIGHT:
    case TERM_SURF_BORDER_TOP:
    case TERM_SURF_BORDER_BOTTOM:
        break;

    case TERM_SURF_BUTTON_MINIMIZE:
    case TERM_SURF_BUTTON_MAXIMIZE:
    case TERM_SURF_BUTTON_CLOSE:
        render_refresh_csd(term);
        break;

    case TERM_SURF_NONE:
        BUG("Invalid surface type");
        break;
    }
}

static void
wl_pointer_leave(void *data, struct wl_pointer *wl_pointer,
                 uint32_t serial, struct wl_surface *surface)
{
    struct seat *seat = data;

    if (seat->wl_touch != NULL) {
        switch (seat->touch.state) {
        case TOUCH_STATE_IDLE:
            break;

        case TOUCH_STATE_INHIBITED:
            seat->touch.state = TOUCH_STATE_IDLE;
            break;

        case TOUCH_STATE_HELD:
        case TOUCH_STATE_DRAGGING:
        case TOUCH_STATE_SCROLLING:
            return;
        }
    }

    struct terminal *old_moused = seat->mouse_focus;

    LOG_DBG(
        "%s: pointer-leave: pointer=%p, serial=%u, surface = %p, old-moused = %p",
        seat->name, (void *)wl_pointer, serial, (void *)surface,
        (void *)old_moused);

    seat->pointer.hidden = false;

    if (seat->pointer.xcursor_callback != NULL) {
        /* A cursor frame callback may never be called if the pointer leaves our surface */
        wl_callback_destroy(seat->pointer.xcursor_callback);
        seat->pointer.xcursor_callback = NULL;
        seat->pointer.xcursor_pending = false;
    }

    /* Reset last-set-xcursor, to ensure we update it on a pointer-enter event */
    seat->pointer.shape = CURSOR_SHAPE_NONE;

    /* Reset mouse state */
    seat->mouse.x = seat->mouse.y = 0;
    seat->mouse.col = seat->mouse.row = 0;
    mouse_button_state_reset(seat);
    for (size_t i = 0; i < ALEN(seat->mouse.aggregated); i++)
        seat->mouse.aggregated[i] = 0.0;
    seat->mouse.have_discrete = false;

    seat->mouse_focus = NULL;
    if (old_moused == NULL) {
        LOG_WARN(
            "compositor sent pointer_leave event without a pointer_enter "
            "event: surface=%p", (void *)surface);
    } else {
        if (surface != NULL) {
            /* Sway 1.4 sends this event with a NULL surface when we destroy the window */
            const struct wl_window UNUSED *win = wl_surface_get_user_data(surface);
            xassert(old_moused == win->term);
        }

        enum term_surface active_surface = old_moused->active_surface;

        old_moused->active_surface = TERM_SURF_NONE;

        switch (active_surface) {
        case TERM_SURF_BUTTON_MINIMIZE:
        case TERM_SURF_BUTTON_MAXIMIZE:
        case TERM_SURF_BUTTON_CLOSE:
            if (old_moused->shutdown.in_progress)
                break;

            render_refresh_csd(old_moused);
            break;

        case TERM_SURF_GRID:
            selection_finalize(seat, old_moused, seat->pointer.serial);
            break;

        case TERM_SURF_NONE:
        case TERM_SURF_TITLE:
        case TERM_SURF_BORDER_LEFT:
        case TERM_SURF_BORDER_RIGHT:
        case TERM_SURF_BORDER_TOP:
        case TERM_SURF_BORDER_BOTTOM:
            break;
        }

    }
}

static bool
pointer_is_on_button(const struct terminal *term, const struct seat *seat,
                     enum csd_surface csd_surface)
{
    if (seat->mouse.x < 0)
        return false;
    if (seat->mouse.y < 0)
        return false;

    struct csd_data info = get_csd_data(term, csd_surface);
    if (seat->mouse.x > info.width)
        return false;

    if (seat->mouse.y > info.height)
        return false;

    return true;
}

static void
wl_pointer_motion(void *data, struct wl_pointer *wl_pointer,
                  uint32_t time, wl_fixed_t surface_x, wl_fixed_t surface_y)
{
    struct seat *seat = data;

    /* Touch-emulated pointer events have wl_pointer == NULL. */
    if (wl_pointer != NULL && touch_is_active(seat))
        return;

    struct wayland *wayl = seat->wayl;
    struct terminal *term = seat->mouse_focus;

    if (unlikely(term == NULL)) {
        /* Typically happens when the compositor sent a pointer enter
         * event with a NULL surface - see wl_pointer_enter().
         *
         * In this case, we never set seat->mouse_focus (since we
         * can't map the enter event to a specific window). */
        return;
    }

    struct wl_window *win = term->window;

    LOG_DBG("pointer_motion: pointer=%p, x=%d, y=%d", (void *)wl_pointer,
            wl_fixed_to_int(surface_x), wl_fixed_to_int(surface_y));

    xassert(term != NULL);

    int x = wl_fixed_to_int(surface_x) * term->scale;
    int y = wl_fixed_to_int(surface_y) * term->scale;

    enum term_surface surf_kind = term->active_surface;
    int button = 0;
    bool send_to_client = false;
    bool is_on_button = false;

    /* If current surface is a button, check if pointer was on it
       *before* the motion event */
    switch (surf_kind) {
    case TERM_SURF_BUTTON_MINIMIZE:
        is_on_button = pointer_is_on_button(term, seat, CSD_SURF_MINIMIZE);
        break;

    case TERM_SURF_BUTTON_MAXIMIZE:
        is_on_button = pointer_is_on_button(term, seat, CSD_SURF_MAXIMIZE);
        break;

    case TERM_SURF_BUTTON_CLOSE:
        is_on_button = pointer_is_on_button(term, seat, CSD_SURF_CLOSE);
        break;

    case TERM_SURF_NONE:
    case TERM_SURF_GRID:
    case TERM_SURF_TITLE:
    case TERM_SURF_BORDER_LEFT:
    case TERM_SURF_BORDER_RIGHT:
    case TERM_SURF_BORDER_TOP:
    case TERM_SURF_BORDER_BOTTOM:
        break;
    }

    seat->pointer.hidden = false;
    seat->mouse.x = x;
    seat->mouse.y = y;

    term_xcursor_update_for_seat(term, seat);

    if (tll_length(seat->mouse.buttons) > 0) {
        const struct button_tracker *tracker = &tll_front(seat->mouse.buttons);
        surf_kind = tracker->surf_kind;
        button = tracker->button;
        send_to_client = tracker->send_to_client;
    }

    switch (surf_kind) {
    case TERM_SURF_NONE:
        break;

    case TERM_SURF_BUTTON_MINIMIZE:
        if (pointer_is_on_button(term, seat, CSD_SURF_MINIMIZE) != is_on_button)
            render_refresh_csd(term);
        break;

    case TERM_SURF_BUTTON_MAXIMIZE:
        if (pointer_is_on_button(term, seat, CSD_SURF_MAXIMIZE) != is_on_button)
            render_refresh_csd(term);
        break;

    case TERM_SURF_BUTTON_CLOSE:
        if (pointer_is_on_button(term, seat, CSD_SURF_CLOSE) != is_on_button)
            render_refresh_csd(term);
        break;

    case TERM_SURF_TITLE:
        /* We've started a 'move' timer, but user started dragging
         * right away - abort the timer and initiate the actual move
         * right away */
        if (button == BTN_LEFT && win->csd.move_timeout_fd != -1) {
            fdm_del(wayl->fdm, win->csd.move_timeout_fd);
            win->csd.move_timeout_fd = -1;
            xdg_toplevel_move(win->xdg_toplevel, seat->wl_seat, win->csd.serial);
        }
        break;

    case TERM_SURF_BORDER_LEFT:
    case TERM_SURF_BORDER_RIGHT:
    case TERM_SURF_BORDER_TOP:
    case TERM_SURF_BORDER_BOTTOM:
        break;

    case TERM_SURF_GRID: {
        int old_col = seat->mouse.col;
        int old_row = seat->mouse.row;

        mouse_coord_pixel_to_cell(seat, term, seat->mouse.x, seat->mouse.y);

        xassert(seat->mouse.col >= 0 && seat->mouse.col < term->cols);
        xassert(seat->mouse.row >= 0 && seat->mouse.row < term->rows);

        /* Cursor has moved to a different cell since last time */
        bool cursor_is_on_new_cell
            = old_col != seat->mouse.col || old_row != seat->mouse.row;

        if (cursor_is_on_new_cell) {
            /* Prevent multiple/different mouse bindings from
             * triggering if the mouse has moved "too much" (to
             * another cell) */
            seat->mouse.count = 0;
        }

        /* Cursor is inside the grid, i.e. *not* in the margins */
        const bool cursor_is_on_grid = seat->mouse.col >= 0 && seat->mouse.row >= 0;

        enum selection_scroll_direction auto_scroll_direction
            = term->selection.coords.end.row < 0
                ? SELECTION_SCROLL_NOT
                : y < term->margins.top
                    ? SELECTION_SCROLL_UP
                    : y > term->height - term->margins.bottom
                        ? SELECTION_SCROLL_DOWN
                        : SELECTION_SCROLL_NOT;

        if (auto_scroll_direction == SELECTION_SCROLL_NOT)
            selection_stop_scroll_timer(term);

        /* Update selection */
        if (!term->is_searching) {
            if (auto_scroll_direction != SELECTION_SCROLL_NOT) {
                /*
                 * Start 'selection auto-scrolling'
                 *
                 * The speed of the scrolling is proportional to the
                 * distance between the mouse and the grid; the
                 * further away the mouse is, the faster we scroll.
                 *
                 * Note that the speed is measured in 'intervals (in
                 * ns) between each timed scroll of a single line'.
                 *
                 * Thus, the further away the mouse is, the smaller
                 * interval value we use.
                 */

                int distance = auto_scroll_direction == SELECTION_SCROLL_UP
                    ? term->margins.top - y
                    : y - (term->height - term->margins.bottom);

                xassert(distance > 0);
                int divisor
                    = distance * term->conf->scrollback.multiplier / term->scale;

                selection_start_scroll_timer(
                    term, 400000000 / (divisor > 0 ? divisor : 1),
                    auto_scroll_direction, seat->mouse.col);
            }

            if (term->selection.ongoing &&
                (cursor_is_on_new_cell ||
                 (term->selection.coords.end.row < 0 &&
                  seat->mouse.x >= term->margins.left &&
                  seat->mouse.x < term->width - term->margins.right &&
                  seat->mouse.y >= term->margins.top &&
                  seat->mouse.y < term->height - term->margins.bottom)))
            {
                selection_update(term, seat->mouse.col, seat->mouse.row);
            }
        }

        /* Send mouse event to client application */
        if (!term_mouse_grabbed(term, seat) &&
            (cursor_is_on_new_cell ||
                term->mouse_reporting == MOUSE_SGR_PIXELS) &&
            ((button == 0 && cursor_is_on_grid) ||
             (button != 0 && send_to_client)))
        {
            xassert(seat->mouse.col < term->cols);
            xassert(seat->mouse.row < term->rows);

            term_mouse_motion(
                term, button,
                seat->mouse.row, seat->mouse.col,
                seat->mouse.y - term->margins.top,
                seat->mouse.x - term->margins.left,
                seat->kbd.shift, seat->kbd.alt, seat->kbd.ctrl);
        }
        break;
    }
    }
}

static bool
fdm_csd_move(struct fdm *fdm, int fd, int events, void *data)
{
    struct seat *seat = data;
    fdm_del(fdm, fd);

    if (seat->mouse_focus == NULL) {
        LOG_WARN(
            "%s: CSD move timeout triggered, but seat's has no mouse focused terminal",
            seat->name);
        return true;
    }

    struct wl_window *win = seat->mouse_focus->window;

    win->csd.move_timeout_fd = -1;
    xdg_toplevel_move(win->xdg_toplevel, seat->wl_seat, win->csd.serial);
    return true;
}

static const struct key_binding *
match_mouse_binding(const struct seat *seat, const struct terminal *term,
                    int button)
{
    if (seat->wl_keyboard != NULL && seat->kbd.xkb_state != NULL) {
        /* Seat has keyboard - use mouse bindings *with* modifiers */

        const struct key_binding_set *bindings =
            key_binding_for(term->wl->key_binding_manager, term->conf, seat);
        xassert(bindings != NULL);

        xkb_mod_mask_t mods;
        get_current_modifiers(seat, &mods, NULL, 0, true);

        /* Ignore selection override modifiers when
         * matching modifiers */
        mods &= ~bindings->selection_overrides;

        const struct key_binding *match = NULL;

        tll_foreach(bindings->mouse, it) {
            const struct key_binding *binding = &it->item;

            if (binding->m.button != button) {
                /* Wrong button */
                continue;
            }

            if (binding->mods != mods) {
                /* Modifier mismatch */
                continue;
            }

            if (binding->m.count > seat->mouse.count) {
                /* Not correct click count */
                continue;
            }

            if (match == NULL || binding->m.count > match->m.count)
                match = binding;
        }

        return match;
    }

    else {
        /* Seat does NOT have a keyboard - use mouse bindings *without*
         * modifiers */
        const struct config_key_binding *match = NULL;
        const struct config *conf = term->conf;

        for (size_t i = 0; i < conf->bindings.mouse.count; i++) {
            const struct config_key_binding *binding =
                &conf->bindings.mouse.arr[i];

            if (binding->m.button != button) {
                /* Wrong button */
                continue;
            }

            if (binding->m.count > seat->mouse.count) {
                /* Incorrect click count */
                continue;
            }

            if (tll_length(binding->modifiers) > 0) {
                /* Binding has modifiers */
                continue;
            }

            if (match == NULL || binding->m.count > match->m.count)
                match = binding;
        }

        if (match != NULL) {
            static struct key_binding bind;
            bind.action = match->action;
            bind.aux = &match->aux;
            return &bind;
        }

        return NULL;
    }

    BUG("should not get here");
}

static void
wl_pointer_button(void *data, struct wl_pointer *wl_pointer,
                  uint32_t serial, uint32_t time, uint32_t button, uint32_t state)
{
    LOG_DBG("BUTTON: pointer=%p, serial=%u, button=%x, state=%u",
            (void *)wl_pointer, serial, button, state);

    xassert(serial != 0);

    struct seat *seat = data;

    /* Touch-emulated pointer events have wl_pointer == NULL. */
    if (wl_pointer != NULL && touch_is_active(seat))
        return;

    struct wayland *wayl = seat->wayl;
    struct terminal *term = seat->mouse_focus;

    seat->pointer.serial = serial;
    seat->pointer.hidden = false;

    xassert(term != NULL);

    enum term_surface surf_kind = TERM_SURF_NONE;
    bool send_to_client = false;

    if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
        if (seat->wl_touch != NULL && seat->touch.state == TOUCH_STATE_IDLE) {
            seat->touch.state = TOUCH_STATE_INHIBITED;
        }

        /* Time since last click */
        struct timespec now, since_last;
        clock_gettime(CLOCK_MONOTONIC, &now);
        timespec_sub(&now, &seat->mouse.last_time, &since_last);

        if (seat->mouse.last_released_button == button &&
            since_last.tv_sec == 0 && since_last.tv_nsec <= 300 * 1000 * 1000)
        {
            seat->mouse.count++;
        } else
            seat->mouse.count = 1;

        /*
         * Workaround GNOME bug
         *
         * Dragging the window, then stopping the drag (releasing the
         * mouse button), *without* moving the mouse, and then
         * clicking twice, waiting for the CSD timer, and finally
         * clicking once more, results in the following sequence
         * (keyboard and other irrelevant events filtered out, unless
         * they're needed to prove a point):
         *
         * dbg: input.c:1551: cancelling drag timer, moving window
         * dbg: input.c:759: keyboard_leave: keyboard=0x607000003580, serial=873, surface=0x6070000036d0
         * dbg: input.c:1432: seat0: pointer-leave: pointer=0x607000003660, serial=874, surface = 0x6070000396e0, old-moused = 0x622000006100
         *
         * --> drag stopped here
         *
         * --> LMB clicked first time after the drag (generates the
         *     enter event on *release*, but no button events)
         * dbg: input.c:1360: pointer-enter: pointer=0x607000003660, serial=876, surface = 0x6070000396e0, new-moused = 0x622000006100
         *
         * --> LMB clicked, and held until the timer times out, second
         *     time after the drag
         * dbg: input.c:1712: BUTTON: pointer=0x607000003660, serial=877, button=110, state=1
         * dbg: input.c:1806: starting move timer
         * dbg: input.c:1692: move timer timed out
         * dbg: input.c:759: keyboard_leave: keyboard=0x607000003580, serial=878, surface=0x6070000036d0
         *
         * --> NOTE: ^^ no pointer leave event this time, only the
         *     keyboard leave
         *
         * --> LMB clicked one last time
         * dbg: input.c:697: seat0: keyboard_enter: keyboard=0x607000003580, serial=879, surface=0x6070000036d0
         * dbg: input.c:1712: BUTTON: pointer=0x607000003660, serial=880, button=110, state=1
         * err: input.c:1741: BUG in wl_pointer_button(): assertion failed: 'it->item.button != button'
         *
         * What are we seeing?
         *
         * - GNOME does *not* send a pointer *enter* event after the drag
         *   has stopped
         * - The second drag does *not* generate a pointer *leave* event
         * - The missing leave event means we're still tracking LMB as
         *   being held down in our seat struct.
         * - This leads to an assert (debug builds) when LMB is clicked
         *   again (seat's button list already contains LMB).
         *
         * Note: I've also observed variants of the above
         */
        tll_foreach(seat->mouse.buttons, it) {
            if (it->item.button == button) {
                LOG_WARN("multiple button press events for button %d "
                         "(compositor bug?)", button);
                tll_remove(seat->mouse.buttons, it);
                break;
            }
        }

#if defined(_DEBUG)
        tll_foreach(seat->mouse.buttons, it)
            xassert(it->item.button != button);
#endif

        /*
         * Remember which surface "owns" this button, so that we can
         * send motion and button release events to that surface, even
         * if the pointer is no longer over it.
         */
        tll_push_back(
            seat->mouse.buttons,
            ((struct button_tracker){
                .button = button,
                .surf_kind = term->active_surface,
                .send_to_client = false}));

        seat->mouse.last_time = now;

        surf_kind = term->active_surface;
        send_to_client = false;  /* For now, may be set to true if a binding consumes the button */
    } else {
        bool UNUSED have_button = false;
        tll_foreach(seat->mouse.buttons, it) {
            if (it->item.button == button) {
                have_button = true;
                surf_kind = it->item.surf_kind;
                send_to_client = it->item.send_to_client;
                tll_remove(seat->mouse.buttons, it);
                break;
            }
        }

        if (seat->wl_touch != NULL && seat->touch.state == TOUCH_STATE_INHIBITED) {
            if (tll_length(seat->mouse.buttons) == 0) {
                seat->touch.state = TOUCH_STATE_IDLE;
            }
        }

        if (!have_button) {
            /*
             * Seen on Sway with slurp
             *
             *  1. Run slurp
             *  2. Press, and hold left mouse button
             *  3. Press escape, to cancel slurp
             *  4. Release mouse button
             *  5. BAM!
             */
            LOG_WARN("stray button release event (compositor bug?)");
            return;
        }

        seat->mouse.last_released_button = button;
    }

    switch (surf_kind) {
    case TERM_SURF_TITLE:
        if (state == WL_POINTER_BUTTON_STATE_PRESSED) {

            struct wl_window *win = term->window;

            /* Toggle maximized state on double-click */
            if (term->conf->csd.double_click_to_maximize &&
                button == BTN_LEFT &&
                seat->mouse.count == 2)
            {
                if (win->is_maximized)
                    xdg_toplevel_unset_maximized(win->xdg_toplevel);
                else
                    xdg_toplevel_set_maximized(win->xdg_toplevel);
            }

            else if (button == BTN_LEFT && win->csd.move_timeout_fd < 0) {
                const struct itimerspec timeout = {
                    .it_value = {.tv_nsec = 200000000},
                };

                int fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
                if (fd >= 0 &&
                    timerfd_settime(fd, 0, &timeout, NULL) == 0 &&
                    fdm_add(wayl->fdm, fd, EPOLLIN, &fdm_csd_move, seat))
                {
                    win->csd.move_timeout_fd = fd;
                    win->csd.serial = serial;
                } else {
                    LOG_ERRNO("failed to configure XDG toplevel move timer FD");
                    if (fd >= 0)
                        close(fd);
                }
            }

            if (button == BTN_RIGHT && tll_length(seat->mouse.buttons) == 1) {
                const struct csd_data info = get_csd_data(term, CSD_SURF_TITLE);
                xdg_toplevel_show_window_menu(
                    win->xdg_toplevel,
                    seat->wl_seat,
                    seat->pointer.serial,
                    seat->mouse.x + info.x, seat->mouse.y + info.y);
            }
        }

        else if (state == WL_POINTER_BUTTON_STATE_RELEASED) {
            struct wl_window *win = term->window;
            if (win->csd.move_timeout_fd >= 0) {
                fdm_del(wayl->fdm, win->csd.move_timeout_fd);
                win->csd.move_timeout_fd = -1;
            }
        }
        return;

    case TERM_SURF_BORDER_LEFT:
    case TERM_SURF_BORDER_RIGHT:
    case TERM_SURF_BORDER_TOP:
    case TERM_SURF_BORDER_BOTTOM: {
        if (button == BTN_LEFT && state == WL_POINTER_BUTTON_STATE_PRESSED) {
            enum xdg_toplevel_resize_edge resize_type = XDG_TOPLEVEL_RESIZE_EDGE_NONE;

            int x = seat->mouse.x;
            int y = seat->mouse.y;

            if (is_top_left(term, x, y))
                resize_type = XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT;
            else if (is_top_right(term, x, y))
                resize_type = XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT;
            else if (is_bottom_left(term, x, y))
                resize_type = XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT;
            else if (is_bottom_right(term, x, y))
                resize_type = XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT;
            else {
                if (term->active_surface == TERM_SURF_BORDER_LEFT &&
                    !term->window->is_constrained_left)
                {
                    resize_type = XDG_TOPLEVEL_RESIZE_EDGE_LEFT;
                }

                else if (term->active_surface == TERM_SURF_BORDER_RIGHT &&
                    !term->window->is_constrained_right)
                {
                    resize_type = XDG_TOPLEVEL_RESIZE_EDGE_RIGHT;
                }

                else if (term->active_surface == TERM_SURF_BORDER_TOP &&
                    !term->window->is_constrained_top)
                {
                    resize_type = XDG_TOPLEVEL_RESIZE_EDGE_TOP;
                }

                else if (term->active_surface == TERM_SURF_BORDER_BOTTOM &&
                    !term->window->is_constrained_bottom)
                {
                    resize_type = XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM;
                }
            }

            if (resize_type != XDG_TOPLEVEL_RESIZE_EDGE_NONE) {
                xdg_toplevel_resize(
                    term->window->xdg_toplevel, seat->wl_seat, serial, resize_type);
            }
        }
        return;
    }

    case TERM_SURF_BUTTON_MINIMIZE:
        if (button == BTN_LEFT &&
            pointer_is_on_button(term, seat, CSD_SURF_MINIMIZE) &&
            state == WL_POINTER_BUTTON_STATE_RELEASED)
        {
            xdg_toplevel_set_minimized(term->window->xdg_toplevel);
        }
        break;

    case TERM_SURF_BUTTON_MAXIMIZE:
        if (button == BTN_LEFT &&
            pointer_is_on_button(term, seat, CSD_SURF_MAXIMIZE) &&
            state == WL_POINTER_BUTTON_STATE_RELEASED)
        {
            if (term->window->is_maximized)
                xdg_toplevel_unset_maximized(term->window->xdg_toplevel);
            else
                xdg_toplevel_set_maximized(term->window->xdg_toplevel);
        }
        break;

    case TERM_SURF_BUTTON_CLOSE:
        if (button == BTN_LEFT &&
            pointer_is_on_button(term, seat, CSD_SURF_CLOSE) &&
            state == WL_POINTER_BUTTON_STATE_RELEASED)
        {
            term_shutdown(term);
        }
        break;

    case TERM_SURF_GRID: {
        search_cancel(term);
        urls_reset(term);

        bool cursor_is_on_grid = seat->mouse.col >= 0 && seat->mouse.row >= 0;

        switch (state) {
        case WL_POINTER_BUTTON_STATE_PRESSED: {
            bool consumed = false;

            if (cursor_is_on_grid && term_mouse_grabbed(term, seat)) {
                const struct key_binding *match =
                    match_mouse_binding(seat, term, button);

                if (match != NULL)
                    consumed = execute_binding(seat, term, match, serial, 1);
            }

            send_to_client = !consumed && cursor_is_on_grid;

            if (send_to_client)
                tll_back(seat->mouse.buttons).send_to_client = true;

            if (send_to_client &&
                !term_mouse_grabbed(term, seat) &&
                cursor_is_on_grid)
            {
                term_mouse_down(
                    term, button, seat->mouse.row, seat->mouse.col,
                    seat->mouse.y - term->margins.top,
                    seat->mouse.x - term->margins.left,
                    seat->kbd.shift, seat->kbd.alt, seat->kbd.ctrl);
            }
            break;
        }

        case WL_POINTER_BUTTON_STATE_RELEASED:
            selection_finalize(seat, term, serial);

            if (send_to_client && !term_mouse_grabbed(term, seat)) {
                term_mouse_up(
                    term, button, seat->mouse.row, seat->mouse.col,
                    seat->mouse.y - term->margins.top,
                    seat->mouse.x - term->margins.left,
                    seat->kbd.shift, seat->kbd.alt, seat->kbd.ctrl);
            }
            break;
        }
        break;
    }

    case TERM_SURF_NONE:
        BUG("Invalid surface type");
        break;

    }
}

static void
alternate_scroll(struct seat *seat, int amount, int button)
{
    if (seat->wl_keyboard == NULL)
        return;

    /* Should be cleared in leave event */
    xassert(seat->mouse_focus != NULL);
    struct terminal *term = seat->mouse_focus;

    assert(button == BTN_BACK || button == BTN_FORWARD);

    xkb_keycode_t key = button == BTN_BACK
        ? seat->kbd.key_arrow_up : seat->kbd.key_arrow_down;

    for (int i = 0; i < amount; i++)
        key_press_release(seat, term, seat->kbd.serial, key, XKB_KEY_DOWN);
    key_press_release(seat, term, seat->kbd.serial, key, XKB_KEY_UP);
}

static void
mouse_scroll(struct seat *seat, int amount, enum wl_pointer_axis axis)
{
    struct terminal *term = seat->mouse_focus;
    xassert(term != NULL);

    int button = axis == WL_POINTER_AXIS_VERTICAL_SCROLL
        ? amount < 0 ? BTN_WHEEL_BACK : BTN_WHEEL_FORWARD
        : amount < 0 ? BTN_WHEEL_LEFT : BTN_WHEEL_RIGHT;
    amount = abs(amount);

    if (term_mouse_grabbed(term, seat)) {
        seat->mouse.count = 1;

        const struct key_binding *match =
            match_mouse_binding(seat, term, button);

        if (match != NULL)
            execute_binding(seat, term, match, seat->pointer.serial, amount);

        seat->mouse.last_released_button = button;
    }

    else if (seat->mouse.col >= 0 && seat->mouse.row >= 0) {
        xassert(seat->mouse.col < term->cols);
        xassert(seat->mouse.row < term->rows);

        for (int i = 0; i < amount; i++) {
            term_mouse_down(
                term, button, seat->mouse.row, seat->mouse.col,
                seat->mouse.y - term->margins.top,
                seat->mouse.x - term->margins.left,
                seat->kbd.shift, seat->kbd.alt, seat->kbd.ctrl);
        }

        term_mouse_up(
            term, button, seat->mouse.row, seat->mouse.col,
            seat->mouse.y - term->margins.top,
            seat->mouse.x - term->margins.left,
            seat->kbd.shift, seat->kbd.alt, seat->kbd.ctrl);
    }
}

static double
mouse_scroll_multiplier(const struct terminal *term, const struct seat *seat)
{
    return (term->grid == &term->normal ||
            (term_mouse_grabbed(term, seat) && term->alt_scrolling))
        ? term->conf->scrollback.multiplier
        : 1.0;
}

static void
wl_pointer_axis(void *data, struct wl_pointer *wl_pointer,
                uint32_t time, uint32_t axis, wl_fixed_t value)
{
    struct seat *seat = data;

    if (touch_is_active(seat))
        return;

    if (seat->mouse.have_discrete)
        return;

    xassert(seat->mouse_focus != NULL);
    xassert(axis < ALEN(seat->mouse.aggregated));

    const struct terminal *term = seat->mouse_focus;

    /*
     * Aggregate scrolled amount until we get at least 1.0
     *
     * Without this, very slow scrolling will never actually scroll
     * anything.
     */
    seat->mouse.aggregated[axis] +=
        mouse_scroll_multiplier(term, seat) * wl_fixed_to_double(value);
    if (fabs(seat->mouse.aggregated[axis]) < seat->mouse_focus->cell_height)
        return;

    int lines = seat->mouse.aggregated[axis] / seat->mouse_focus->cell_height;
    mouse_scroll(seat, lines, axis);
    seat->mouse.aggregated[axis] -= (double)lines * seat->mouse_focus->cell_height;
}

static void
wl_pointer_axis_discrete(void *data, struct wl_pointer *wl_pointer,
                         enum wl_pointer_axis axis, int32_t discrete)
{
    LOG_DBG("axis_discrete: %d", discrete);
    struct seat *seat = data;

    if (touch_is_active(seat))
        return;

    seat->mouse.have_discrete = true;
    int amount = discrete;

    if (axis == WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
        /* Treat mouse wheel left/right as regular buttons */
    } else
        amount *= mouse_scroll_multiplier(seat->mouse_focus, seat);

    mouse_scroll(seat, amount, axis);
}

#if defined(WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
static void
wl_pointer_axis_value120(void *data, struct wl_pointer *wl_pointer,
                         enum wl_pointer_axis axis, int32_t value120)
{
    LOG_DBG("axis_value120: %d -> %.2f", value120, (float)value120 / 120.);

    struct seat *seat = data;

    if (touch_is_active(seat))
        return;

    seat->mouse.have_discrete = true;

    /*
     * 120 corresponds to a single "low-res" scroll step.
     *
     * When doing high-res scrolling, take the scrollback.multiplier,
     * and calculate how many degrees there are per line.
     *
     * For example, with scrollback.multiplier = 3, we have 120 / 3 == 40.
     *
     * Then, accumulate high-res scroll events, until we have *at
     * least* that much. Translate the accumulated value to number of
     * lines, and scroll.
     *
     * Subtract the "used" degrees from the accumulated value, and
     * keep what's left (this value will always be less than the
     * per-line value).
     */
    const double multiplier = mouse_scroll_multiplier(seat->mouse_focus, seat);
    const double per_line = 120. / multiplier;

    seat->mouse.aggregated_120[axis] += (double)value120;

    if (fabs(seat->mouse.aggregated_120[axis]) < per_line)
        return;

    int lines = (int)(seat->mouse.aggregated_120[axis] / per_line);
    mouse_scroll(seat, lines, axis);
    seat->mouse.aggregated_120[axis] -= (double)lines * per_line;
}
#endif

static void
wl_pointer_frame(void *data, struct wl_pointer *wl_pointer)
{
    struct seat *seat = data;

    if (touch_is_active(seat))
        return;

    seat->mouse.have_discrete = false;
}

static void
wl_pointer_axis_source(void *data, struct wl_pointer *wl_pointer,
                       uint32_t axis_source)
{
}

static void
wl_pointer_axis_stop(void *data, struct wl_pointer *wl_pointer,
                     uint32_t time, uint32_t axis)
{
    struct seat *seat = data;

    if (touch_is_active(seat))
        return;

    xassert(axis < ALEN(seat->mouse.aggregated));
    seat->mouse.aggregated[axis] = 0.;
}

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
