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
