#include <stddef.h>
#include <sys/epoll.h>
#include "terminal.h"

char **osc_term_cwd_ptr(struct terminal *term) {
    return &term->cwd;
}

/* ── Chunk D: clipboard helpers ─────────────────────────────────── */

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <tllist.h>
#include "terminal.h"
#include "wayland.h"
#include "fdm.h"

/* Return the seat with keyboard focus matching `term`, or NULL. */
struct seat *
osc_seat_with_focus(struct terminal *term)
{
    tll_foreach(term->wl->seats, it) {
        if (it->item.kbd_focus == term)
            return &it->item;
    }
    return NULL;
}

uint32_t
osc_seat_serial(struct seat *seat)
{
    return seat->kbd.serial;
}


bool
osc_osc52_copy_allowed(struct terminal *term)
{
    return term->conf->security.osc52 == OSC52_ENABLED
        || term->conf->security.osc52 == OSC52_COPY_ENABLED;
}

bool
osc_osc52_paste_allowed(struct terminal *term)
{
    return term->conf->security.osc52 == OSC52_ENABLED
        || term->conf->security.osc52 == OSC52_PASTE_ENABLED;
}

size_t
osc_ptmx_buffers_len(struct terminal *term)
{
    return tll_length(term->ptmx_buffers);
}

void
osc_fdm_epollout_ptmx(struct terminal *term)
{
    fdm_event_add(term->fdm, term->ptmx, EPOLLOUT);
}

