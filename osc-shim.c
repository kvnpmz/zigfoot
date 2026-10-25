#include <stddef.h>
#include <sys/epoll.h>
#include "terminal.h"
#include "char32.h"
#include "xmalloc.h"

char **osc_term_cwd_ptr(struct terminal *term) {
    return &term->cwd;
}

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

/* ── Chunk F: struct color_theme accessors ─────────────────────── */
#include <string.h>

uint32_t osc_theme_fg(struct terminal *t) { return term_theme_get(t)->fg; }
uint32_t osc_theme_bg(struct terminal *t) { return term_theme_get(t)->bg; }
uint16_t osc_theme_alpha(struct terminal *t) { return term_theme_get(t)->alpha; }
uint32_t osc_theme_cursor_text(struct terminal *t) { return term_theme_get(t)->cursor.text; }
uint32_t osc_theme_cursor_cursor(struct terminal *t) { return term_theme_get(t)->cursor.cursor; }
uint32_t osc_theme_selection_bg(struct terminal *t) { return term_theme_get(t)->selection_bg; }
uint32_t osc_theme_selection_fg(struct terminal *t) { return term_theme_get(t)->selection_fg; }
void osc_theme_table_copy(struct terminal *t, uint32_t *out) {
    memcpy(out, term_theme_get(t)->table, sizeof(uint32_t) * 256);
}
bool osc_conf_colors_dark_use_custom_cursor(struct terminal *t) {
    return t->conf->colors_dark.use_custom.cursor;
}


/* ── Chunk E: notification helpers ─────────────────────────────── */
bool
osc_notify_utf8_valid(const char *s, size_t len)
{
    return mbsntoc32(NULL, s, len, 0) != (size_t)-1;
}

/* ── Chunk E-2: kitty_notification helpers ─────────────────────── */
struct notification *
osc_kitty_notif_get(struct terminal *term)
{
    return &term->kitty_notification;
}

bool
osc_kitty_osc_bel(struct terminal *term)
{
    return term->vt.osc.bel;
}

bool
osc_kitty_conf_inhibit_when_focused(struct terminal *term)
{
    return term->conf->desktop_notifications.inhibit_when_focused;
}

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
