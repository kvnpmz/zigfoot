#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "notify.h"
#include "terminal.h"
#include "util.h"
#include "xmalloc.h"
#include "spawn.h"
#include "fdm.h"

char *notify_xstrjoin(const char *a, const char *b) {
    return xstrjoin(a, b);
}

struct notification_icon *
notify_icon_at(struct terminal *term, size_t idx)
{
    return &term->notification_icons[idx];
}

size_t
notify_icon_count(void)
{
    return sizeof(((struct terminal *)0)->notification_icons) /
           sizeof(((struct terminal *)0)->notification_icons[0]);
}

void
notify_tll_free_and_free_actions(struct notification *notif)
{
    tll_free_and_free(notif->actions, free);
}

// ── Chunk B shim surface ──────────────────────────────────────────

struct notification *
notify_active_first(struct terminal *term)
{
    if (tll_length(term->active_notifications) == 0) return NULL;
    return &tll_front(term->active_notifications);
}

struct notification *
notify_active_next(struct terminal *term, struct notification *prev)
{
    tll_foreach(term->active_notifications, it) {
        if (&it->item == prev) {
            it = it->next;
            if (it == NULL) return NULL;
            return &it->item;
        }
    }
    return NULL;
}

bool
notify_conf_action_arg_configured(struct terminal *term)
{
    return term->conf->desktop_notifications.command_action_arg.argv.args != NULL;
}

bool
notify_spawn_expand_action_arg(struct terminal *term, const char *name, const char *label,
                               size_t *argc, char ***argv)
{
    return spawn_expand_template(
        &term->conf->desktop_notifications.command_action_arg, 2,
        (const char *[]){"action-name", "action-label"},
        (const char *[]){name, label},
        argc, argv);
}

struct fdm *notify_term_fdm(struct terminal *term) { return term->fdm; }

// ── Chunk B-2 shim surface ────────────────────────────────────────

void
notify_active_remove(struct terminal *term, struct notification *notif)
{
    tll_foreach(term->active_notifications, it) {
        if (&it->item == notif) {
            tll_remove(term->active_notifications, it);
            return;
        }
    }
}

struct terminal *
notify_wayl_terms_first(struct wayland *wayl)
{
    if (tll_length(wayl->terms) == 0) return NULL;
    return tll_front(wayl->terms);
}

struct terminal *
notify_wayl_terms_next(struct wayland *wayl, struct terminal *prev)
{
    tll_foreach(wayl->terms, it) {
        if (it->item == prev) {
            it = it->next;
            if (it == NULL) return NULL;
            return it->item;
        }
    }
    return NULL;
}

struct wl_window *notify_term_window(struct terminal *term) { return term->window; }
struct wayland *notify_term_wayl(struct terminal *term) { return term->wl; }
bool notify_term_kbd_focus(struct terminal *term) { return term->kbd_focus; }
const char *notify_term_window_title(struct terminal *term) { return term->window_title; }
const char *notify_term_app_id(struct terminal *term) { return term->app_id; }

bool
notify_conf_close_configured(struct terminal *term)
{
    return term->conf->desktop_notifications.close.argv.args != NULL;
}

bool
notify_spawn_expand_close(struct terminal *term, const char *id,
                          size_t *argc, char ***argv)
{
    return spawn_expand_template(
        &term->conf->desktop_notifications.close, 1,
        (const char *[]){"id"}, (const char *[]){id}, argc, argv);
}
struct reaper *notify_term_reaper(struct terminal *term) { return term->reaper; }
