/* Zig shim for the osc port.
 *
 * This file only holds what the Zig code cannot express yet:
 *
 *   1. C-only compile-time knowledge: object-like macros, sizeof/offsetof,
 *      #ifdef'd feature tests, and static inline wrappers around libc or
 *      wayland-client (wl_subsurface_set_sync(), c32width(), ...).
 *   2. Struct mirrors that have not landed yet: field reads of a struct that
 *      terminal_types.zig does not mirror. Delete these as soon as the struct
 *      is mirrored and pinned by the ABI probe (Track B).
 *   3. C-only types and varargs: regex_t, FILE, va_list forwarding.
 *
 * A function that no longer satisfies one of these must be deleted; the audit
 * rule and the current exemptions are documented in MIGRATION_PLAN.md 12.9.
 */

#include <stddef.h>
#include <sys/epoll.h>
#include "terminal.h"
#include "char32.h"
#include "xmalloc.h"

/* ── Chunk D: clipboard helpers ─────────────────────────────────── */

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <tllist.h>
#include "terminal.h"
#include "char32.h"
#include "xmalloc.h"
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

/* ── Chunk F: struct color_theme accessors ─────────────────────── */
#include <string.h>


/* ── Chunk E: notification helpers ─────────────────────────────── */
bool
osc_notify_utf8_valid(const char *s, size_t len)
{
    return mbsntoc32(NULL, s, len, 0) != (size_t)-1;
}

/* ── Chunk E-2: kitty_notification helpers ─────────────────────── */



char *
osc_xstrjoin(const char *a, const char *b)
{
    return xstrjoin(a, b);
}

char *
osc_xstrjoin3(const char *a, const char *b, const char *c)
{
    return xstrjoin3(a, b, c);
}

void
osc_kitty_actions_push_back(struct notification *notif, char *s)
{
    tll_push_back(notif->actions, s);
}

/* ── Chunk E-3: kitty_text_size helpers ─────────────────────────── */
size_t
osc_c32len(const uint32_t *s)
{
    return c32len((const char32_t *)s);
}

