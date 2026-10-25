#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "notify.h"
#include "terminal.h"
#include "util.h"
#include "xmalloc.h"

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
