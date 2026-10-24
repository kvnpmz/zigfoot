#include "csi.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(_DEBUG)
 #include <stdio.h>
#endif

#include <sys/timerfd.h>

#define LOG_MODULE "csi"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "char32.h"
#include "config.h"
#include "debug.h"
#include "grid.h"
#include "selection.h"
#include "sixel.h"
#include "util.h"
#include "version.h"
#include "vt.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* Ported to csi.zig (chunk A) */
void sgr_reset(struct terminal *term);
void csi_sgr(struct terminal *term);

/* Ported to csi.zig (chunk B) */
void xtsave(struct terminal *term, unsigned param);
void xtrestore(struct terminal *term, unsigned param);

/* Ported to csi.zig (chunk C1) */
void decset_decrst(struct terminal *term, unsigned param, bool enable);
void decset(struct terminal *term, unsigned param);
void decrst(struct terminal *term, unsigned param);

/* Ported to csi.zig (chunk D) */
bool params_to_rectangular_area(const struct terminal *term, int first_idx, int *top, int *left, int *bottom, int *right);

#define UNHANDLED()        LOG_DBG("unhandled: %s", csi_as_string(term, final, -1))
#define UNHANDLED_SGR(idx) LOG_DBG("unhandled: %s", csi_as_string(term, 'm', idx))

static const char *
csi_as_string(struct terminal *term, uint8_t final, int idx)
{
    static char msg[1024];
    int c = snprintf(msg, sizeof(msg), "CSI: ");

    for (size_t i = idx >= 0 ? idx : 0;
         i < (idx >= 0 ? idx + 1 : term->vt.params.idx);
         i++)
    {
        c += snprintf(&msg[c], sizeof(msg) - c, "%u",
                      term->vt.params.v[i].value);

        for (size_t j = 0; j < term->vt.params.v[i].sub.idx; j++) {
            c += snprintf(&msg[c], sizeof(msg) - c, ":%u",
                          term->vt.params.v[i].sub.value[j]);
        }

        c += snprintf(&msg[c], sizeof(msg) - c, "%s",
                      i == term->vt.params.idx - 1 ? "" : ";");
    }

    for (size_t i = 0; i < sizeof(term->vt.private); i++) {
        char value = (term->vt.private >> (i * 8)) & 0xff;
        if (value == 0)
            break;
        c += snprintf(&msg[c], sizeof(msg) - c, "%c", value);
    }

    snprintf(&msg[c], sizeof(msg) - c, "%c (%u parameters)",
             final, idx >= 0 ? 1 : term->vt.params.idx);
    return msg;
}

/*
 * These values represent the current state of a DEC private mode,
 * as returned in the DECRPM reply to a DECRQM query.
 */
enum decrpm_status {
    DECRPM_NOT_RECOGNIZED = 0,
    DECRPM_SET = 1,
    DECRPM_RESET = 2,
    DECRPM_PERMANENTLY_SET = 3,
    DECRPM_PERMANENTLY_RESET = 4,
};

static enum decrpm_status
decrpm(bool enabled)
{
    return enabled ? DECRPM_SET : DECRPM_RESET;
}

static enum decrpm_status
decrqm(const struct terminal *term, unsigned param)
{
    switch (param) {
    case 1: return decrpm(term->cursor_keys_mode == CURSOR_KEYS_APPLICATION);
    case 5: return decrpm(term->reverse);
    case 6: return decrpm(term->origin);
    case 7: return decrpm(term->auto_margin);
    case 9: return DECRPM_PERMANENTLY_RESET; /* term->mouse_tracking == MOUSE_X10; */
    case 12: return decrpm(term->cursor_blink.decset);
    case 25: return decrpm(!term->hide_cursor);
    case 45: return decrpm(term->reverse_wrap);
    case 66: return decrpm(term->keypad_keys_mode == KEYPAD_APPLICATION);
    case 67: return DECRPM_PERMANENTLY_RESET; /* https://vt100.net/docs/vt510-rm/DECBKM */
    case 80: return decrpm(!term->sixel.scrolling);
    case 1000: return decrpm(term->mouse_tracking == MOUSE_CLICK);
    case 1001: return DECRPM_PERMANENTLY_RESET;
    case 1002: return decrpm(term->mouse_tracking == MOUSE_DRAG);
    case 1003: return decrpm(term->mouse_tracking == MOUSE_MOTION);
    case 1004: return decrpm(term->focus_events);
    case 1005: return DECRPM_PERMANENTLY_RESET; /* term->mouse_reporting == MOUSE_UTF8; */
    case 1006: return decrpm(term->mouse_reporting == MOUSE_SGR);
    case 1007: return decrpm(term->alt_scrolling);
    case 1015: return decrpm(term->mouse_reporting == MOUSE_URXVT);
    case 1016: return decrpm(term->mouse_reporting == MOUSE_SGR_PIXELS);
    case 1034: return decrpm(term->meta.eight_bit);
    case 1035: return decrpm(term->num_lock_modifier);
    case 1036: return decrpm(term->meta.esc_prefix);
    case 1042: return decrpm(term->bell_action_enabled);
    case 47:   /* FALLTHROUGH */
    case 1047: /* FALLTHROUGH */
    case 1049: return decrpm(term->grid == &term->alt);
    case 1070: return decrpm(term->sixel.use_private_palette);
    case 2004: return decrpm(term->bracketed_paste);
    case 2026: return decrpm(term->render.app_sync_updates.enabled);
    case 2027: return term->conf->tweak.grapheme_width_method != GRAPHEME_WIDTH_DOUBLE
        ? DECRPM_PERMANENTLY_RESET
        : decrpm(term->grapheme_shaping);
    case 2031: return decrpm(term->report_theme_changes);
    case 2033: return decrpm(term->visibility_reports);
    case 2048: return decrpm(term->size_notifications);
    case 8452: return decrpm(term->sixel.cursor_right_of_graphics);
    case 737769: return decrpm(term_ime_is_enabled(term));
    }

    return DECRPM_NOT_RECOGNIZED;
}

void
csi_dispatch(struct terminal *term, uint8_t final)
{
    LOG_DBG("%s (%08x)", csi_as_string(term, final, -1), term->vt.private);

    switch (term->vt.private) {
    case 0: {
        switch (final) {
        case 'b':
            if (term->vt.last_printed != 0) {
                /*
                 * Note: we never reset 'last-printed'. According to
                 * ECMA-48, the behaviour is undefined if REP was
                 * _not_ preceded by a graphical character.
                 */
                const size_t max_count = term->grid->num_rows * term->cols;
                int count = min(vt_param_get(term, 0, 1), max_count);
                LOG_DBG("REP: '%lc' %d times", (wint_t)term->vt.last_printed, count);

                int width;

                if (term->vt.last_printed >= CELL_COMB_CHARS_LO) {
                    const struct composed *comp = composed_lookup(
                        term->composed, term->vt.last_printed - CELL_COMB_CHARS_LO);

                    xassert(comp != NULL);
                    width = comp->forced_width > 0 ? comp->forced_width : comp->width;
                } else
                    width = c32width(term->vt.last_printed);

                if (width > 0) {
                    for (int i = 0; i < count; i++)
                        term_print(term, term->vt.last_printed, width, false);
                }
            }
            break;

        case 'c': {
            if (vt_param_get(term, 0, 0) != 0) {
                UNHANDLED();
                break;
            }

            /* Send Device Attributes (Primary DA) */

            /*
             * Responses:
             *  - CSI?1;2c      vt100 with advanced video option
             *  - CSI?1;0c      vt101 with no options
             *  - CSI?6c        vt102
             *  - CSI?62;<Ps>c  vt220
             *  - CSI?63;<Ps>c  vt320
             *  - CSI?64;<Ps>c  vt420
             *
             * Ps (response may contain multiple):
             *  - 1    132 columns
             *  - 2    Printer.
             *  - 3    ReGIS graphics.
             *  - 4    Sixel graphics.
             *  - 6    Selective erase.
             *  - 8    User-defined keys.
             *  - 9    National Replacement Character sets.
             *  - 15   Technical characters.
             *  - 16   Locator port.
             *  - 17   Terminal state interrogation.
             *  - 18   User windows.
             *  - 21   Horizontal scrolling.
             *  - 22   ANSI color, e.g., VT525.
             *  - 28   Rectangular editing.
             *  - 29   ANSI text locator (i.e., DEC Locator mode).
             *  - 52   Clipboard access
             *
             * Note: we report ourselves as a VT220, mainly to be able
             * to pass parameters, to indicate we support sixel, and
             * ANSI colors.
             *
             * The VT level must be synchronized with the secondary DA
             * response.
             *
             * Note: tertiary DA responds with "FOOT".
             */
            char reply[32];

            int len = snprintf(
                reply, sizeof(reply), "\033[?62%s;22;28%sc",
                term->conf->tweak.sixel ? ";4" : "",
                (term->conf->security.osc52 == OSC52_ENABLED ||
                 term->conf->security.osc52 == OSC52_COPY_ENABLED ? ";52" : ""));

            term_to_slave(term, reply, len);
            break;
        }

        case 'd': {
            /* VPA - vertical line position absolute */
            int rel_row = vt_param_get(term, 0, 1) - 1;
            int row = term_row_rel_to_abs(term, rel_row);
            term_cursor_to(term, row, term->grid->cursor.point.col);
            break;
        }

        case 'm':
            csi_sgr(term);
            break;

        case 'A':
            term_cursor_up(term, vt_param_get(term, 0, 1));
            break;

        case 'e':
        case 'B':
            term_cursor_down(term, vt_param_get(term, 0, 1));
            break;

        case 'a':
        case 'C':
            term_cursor_right(term, vt_param_get(term, 0, 1));
            break;

        case 'D':
            term_cursor_left(term, vt_param_get(term, 0, 1));
            break;

        case 'E':
            /* CNL - Cursor Next Line */
            term_cursor_down(term, vt_param_get(term, 0, 1));
            term_cursor_left(term, term->grid->cursor.point.col);
            break;

        case 'F':
            /* CPL - Cursor Previous Line */
            term_cursor_up(term, vt_param_get(term, 0, 1));
            term_cursor_left(term, term->grid->cursor.point.col);
            break;

        case 'g': {
            int param = vt_param_get(term, 0, 0);
            switch (param) {
            case 0:
                /* Clear tab stop at *current* column */
                tll_foreach(term->tab_stops, it) {
                    if (it->item == term->grid->cursor.point.col)
                        tll_remove(term->tab_stops, it);
                    else if (it->item > term->grid->cursor.point.col)
                        break;
                }

                break;

            case 3:
                /* Clear *all* tabs */
                tll_free(term->tab_stops);
                break;

            default:
                UNHANDLED();
                break;
            }
            break;
        }

        case '`':
        case 'G': {
            /* Cursor horizontal absolute */
            int col = min(vt_param_get(term, 0, 1), term->cols) - 1;
            term_cursor_col(term, col);
            break;
        }

        case 'f':
        case 'H': {
            /* Move cursor */
            int rel_row = vt_param_get(term, 0, 1) - 1;
            int row = term_row_rel_to_abs(term, rel_row);
            int col = min(vt_param_get(term, 1, 1), term->cols) - 1;
            term_cursor_to(term, row, col);
            break;
        }

        case 'J': {
            /* Erase screen */

            int param = vt_param_get(term, 0, 0);
            switch (param) {
            case 0: {
                /* From cursor to end of screen */
                const struct coord *cursor = &term->grid->cursor.point;
                term_erase(
                    term,
                    cursor->row, cursor->col,
                    term->rows - 1, term->cols - 1);
                term->grid->cursor.lcf = false;
                break;
            }

            case 1: {
                /* From start of screen to cursor */
                const struct coord *cursor = &term->grid->cursor.point;
                term_erase(term, 0, 0, cursor->row, cursor->col);
                term->grid->cursor.lcf = false;
                break;
            }

            case 2:
                /* Erase entire screen */
                term_erase(term, 0, 0, term->rows - 1, term->cols - 1);
                term->grid->cursor.lcf = false;
                break;

            case 3: {
                /* Erase scrollback */
                term_erase_scrollback(term);
                break;
            }

            default:
                UNHANDLED();
                break;
            }
            break;
        }

        case 'K': {
            /* Erase line */

            int param = vt_param_get(term, 0, 0);
            switch (param) {
            case 0: {
                /* From cursor to end of line */
                const struct coord *cursor = &term->grid->cursor.point;
                term_erase(
                    term,
                    cursor->row, cursor->col,
                    cursor->row, term->cols - 1);
                term->grid->cursor.lcf = false;
                break;
            }

            case 1: {
                /* From start of line to cursor */
                const struct coord *cursor = &term->grid->cursor.point;
                term_erase(term, cursor->row, 0, cursor->row, cursor->col);
                term->grid->cursor.lcf = false;
                break;
            }

            case 2: {
                /* Entire line */
                const struct coord *cursor = &term->grid->cursor.point;
                term_erase(term, cursor->row, 0, cursor->row, term->cols - 1);
                term->grid->cursor.lcf = false;
                break;
            }

            default:
                UNHANDLED();
                break;
            }

            break;
        }

        case 'L': {  /* IL */
            if (term->grid->cursor.point.row < term->scroll_region.start ||
                term->grid->cursor.point.row >= term->scroll_region.end)
                break;

            int count = min(
                vt_param_get(term, 0, 1),
                term->scroll_region.end - term->grid->cursor.point.row);

            term_scroll_reverse_partial(
                term,
                (struct scroll_region){
                    .start = term->grid->cursor.point.row,
                    .end = term->scroll_region.end},
                count);
            term->grid->cursor.lcf = false;
            term->grid->cursor.point.col = 0;
            break;
        }

        case 'M': {  /* DL */
            if (term->grid->cursor.point.row < term->scroll_region.start ||
                term->grid->cursor.point.row >= term->scroll_region.end)
                break;

            int count = min(
                vt_param_get(term, 0, 1),
                term->scroll_region.end - term->grid->cursor.point.row);

            term_scroll_partial(
                term,
                (struct scroll_region){
                    .start = term->grid->cursor.point.row,
                    .end = term->scroll_region.end},
                count);
            term->grid->cursor.lcf = false;
            term->grid->cursor.point.col = 0;
            break;
        }

        case 'P': {
            /* DCH: Delete character(s) */

            /* Number of characters to delete */
            int count = min(
                vt_param_get(term, 0, 1), term->cols - term->grid->cursor.point.col);

            /* Number of characters left after deletion (on current line) */
            int remaining = term->cols - (term->grid->cursor.point.col + count);

            /* 'Delete' characters by moving the remaining ones */
            memmove(&term->grid->cur_row->cells[term->grid->cursor.point.col],
                    &term->grid->cur_row->cells[term->grid->cursor.point.col + count],
                    remaining * sizeof(term->grid->cur_row->cells[0]));

            for (size_t c = 0; c < remaining; c++)
                term->grid->cur_row->cells[term->grid->cursor.point.col + c].attrs.clean = 0;
            term->grid->cur_row->dirty = true;

            /* Erase the remainder of the line */
            const struct coord *cursor = &term->grid->cursor.point;
            term_erase(
                term,
                cursor->row, cursor->col + remaining,
                cursor->row, term->cols - 1);
            term->grid->cursor.lcf = false;
            break;
        }

        case '@': {
            /* ICH: insert character(s) */

            /* Number of characters to insert */
            int count = min(
                vt_param_get(term, 0, 1), term->cols - term->grid->cursor.point.col);

            /* Characters to move */
            int remaining = term->cols - (term->grid->cursor.point.col + count);

            /* Push existing characters */
            memmove(&term->grid->cur_row->cells[term->grid->cursor.point.col + count],
                    &term->grid->cur_row->cells[term->grid->cursor.point.col],
                    remaining * sizeof(term->grid->cur_row->cells[0]));
            for (size_t c = 0; c < remaining; c++)
                term->grid->cur_row->cells[term->grid->cursor.point.col + count + c].attrs.clean = 0;
            term->grid->cur_row->dirty = true;

            /* Erase (insert space characters) */
            const struct coord *cursor = &term->grid->cursor.point;
            term_erase(
                term,
                cursor->row, cursor->col,
                cursor->row, cursor->col + count - 1);
            term->grid->cursor.lcf = false;
            break;
        }

        case 'S': {
            const struct scroll_region *r = &term->scroll_region;
            int amount = min(vt_param_get(term, 0, 1), r->end - r->start);
            term_scroll(term, amount);
            break;
        }

        case 'T': {
            const struct scroll_region *r = &term->scroll_region;
            int amount = min(vt_param_get(term, 0, 1), r->end - r->start);
            term_scroll_reverse(term, amount);
            break;
        }

        case 'X': {
            /* Erase chars */
            int count = min(
                vt_param_get(term, 0, 1), term->cols - term->grid->cursor.point.col);

            const struct coord *cursor = &term->grid->cursor.point;
            term_erase(
                term,
                cursor->row, cursor->col,
                cursor->row, cursor->col + count - 1);
            term->grid->cursor.lcf = false;
            break;
        }

        case 'I': {
            /* CHT - Tab Forward (param is number of tab stops to move through) */
            int count = vt_param_get(term, 0, 1);
            int new_col = term->grid->cursor.point.col;
            tll_foreach(term->tab_stops, it) {
                if (it->item > new_col) {
                    if (--count < 0) {
                        break;
                    }
                    new_col = it->item;
                }
            }
            xassert(new_col >= term->grid->cursor.point.col);

            bool lcf = term->grid->cursor.lcf;
            term_cursor_right(term, new_col - term->grid->cursor.point.col);
            term->grid->cursor.lcf = lcf;
            break;
        }

        case 'Z': {
            /* CBT - Back tab (param is number of tab stops to move back through) */
            int count = vt_param_get(term, 0, 1);
            int new_col = term->grid->cursor.point.col;
            tll_rforeach(term->tab_stops, it) {
                if (it->item < new_col) {
                    if (--count < 0) {
                        break;
                    }
                    new_col = it->item;
                }
            }
            xassert(term->grid->cursor.point.col >= new_col);
            term_cursor_left(term, term->grid->cursor.point.col - new_col);
            break;
        }

        case 'h':
        case 'l': {
            /* Set/Reset Mode (SM/RM) */
            int param = vt_param_get(term, 0, 0);
            bool sm = final == 'h';
            if (param == 4) {
                /* Insertion Replacement Mode (IRM) */
                term->insert_mode = sm;
                term->bits_affecting_ascii_printer.insert_mode = sm;
                term_update_ascii_printer(term);
                break;
            }

            /*
             * ECMA-48 defines modes 1-22, all of which were optional
             * (§7.1; "may have one state only") and are considered
             * deprecated (§7.1) in the latest (5th) edition. xterm only
             * documents modes 2, 4, 12 and 20, the last of which was
             * outright removed (§8.3.106) in 5th edition ECMA-48.
             */
            if (sm) {
                LOG_WARN("SM with unimplemented mode: %d", param);
            }
            break;
        }

        case 'r': {
            int start = vt_param_get(term, 0, 1);
            int end = min(vt_param_get(term, 1, term->rows), term->rows);

            if (end > start) {

                /* 1-based */
                term->scroll_region.start = start - 1;
                term->scroll_region.end = end;
                term_cursor_home(term);

                LOG_DBG("scroll region: %d-%d",
                        term->scroll_region.start,
                        term->scroll_region.end);
            }
            break;
        }

        case 's':
            term_save_cursor(term);
            break;

        case 'u':
            term_restore_cursor(term, &term->grid->saved_cursor);
            break;

        case 't': {
            /*
             * Window operations
             */

            const unsigned param = vt_param_get(term, 0, 0);

            switch (param) {
            case 1: LOG_WARN("unimplemented: de-iconify"); break;
            case 2: LOG_WARN("unimplemented: iconify"); break;
            case 3: LOG_WARN("unimplemented: move window to pixel position"); break;
            case 4: LOG_WARN("unimplemented: resize window in pixels"); break;
            case 5: LOG_WARN("unimplemented: raise window to front of stack"); break;
            case 6: LOG_WARN("unimplemented: raise window to back of stack"); break;
            case 7: LOG_WARN("unimplemented: refresh window"); break;
            case 8: LOG_WARN("unimplemented: resize window in chars"); break;
            case 9: LOG_WARN("unimplemented: maximize/unmaximize window"); break;
            case 10: LOG_WARN("unimplemented: to/from full screen"); break;
            case 20: LOG_WARN("unimplemented: report icon label"); break;
            case 24: LOG_WARN("unimplemented: resize window (DECSLPP)"); break;

            case 11:   /* report if window is iconified */
                /* We don't know - always report *not* iconified */
                /* 1=not iconified, 2=iconified */
                term_to_slave(term, "\033[1t", 4);
                break;

            case 13: { /* report window position */
                /* We don't know our position - always report (0,0) */
                static const char reply[] = "\033[3;0;0t";
                switch (vt_param_get(term, 1, 0)) {
                case 0: /* window position */
                case 2: /* text area position */
                    term_to_slave(term, reply, sizeof(reply) - 1);
                    break;

                default:
                    UNHANDLED();
                    break;
                }

                break;
            }

            case 14: { /* report window size in pixels */
                int width = -1;
                int height = -1;

                switch (vt_param_get(term, 1, 0)) {
                case 0:
                    /* text area size */
                    width = term->width - term->margins.left - term->margins.right;
                    height = term->height - term->margins.top - term->margins.bottom;
                    break;

                case 2:
                    /* window size */
                    width = term->width;
                    height = term->height;
                    break;

                default:
                    UNHANDLED();
                    break;
                }

                if (width >= 0 && height >= 0) {
                    char reply[64];
                    size_t n = xsnprintf(
                        reply, sizeof(reply), "\033[4;%d;%dt", height, width);
                    term_to_slave(term, reply, n);
                }
                break;
            }

            case 15:   /* report screen size in pixels */
                tll_foreach(term->window->on_outputs, it) {
                    char reply[64];
                    size_t n = xsnprintf(reply, sizeof(reply), "\033[5;%d;%dt",
                             it->item->dim.px_real.height,
                             it->item->dim.px_real.width);
                    term_to_slave(term, reply, n);
                    break;
                }

                if (tll_length(term->window->on_outputs) == 0)
                    term_to_slave(term, "\033[5;0;0t", 8);
                break;

            case 16: { /* report cell size in pixels */
                char reply[64];
                size_t n = xsnprintf(
                    reply, sizeof(reply), "\033[6;%d;%dt",
                    term->cell_height, term->cell_width);
                term_to_slave(term, reply, n);
                break;
            }

            case 18: { /* text area size in chars */
                char reply[64];
                size_t n = xsnprintf(reply, sizeof(reply), "\033[8;%d;%dt",
                         term->rows, term->cols);
                term_to_slave(term, reply, n);
                break;
            }

            case 19: { /* report screen size in chars */
                tll_foreach(term->window->on_outputs, it) {
                    char reply[64];
                    size_t n = xsnprintf(
                        reply, sizeof(reply), "\033[9;%d;%dt",
                        it->item->dim.px_real.height / term->cell_height,
                        it->item->dim.px_real.width / term->cell_width);
                    term_to_slave(term, reply, n);
                    break;
                }

                if (tll_length(term->window->on_outputs) == 0)
                    term_to_slave(term, "\033[9;0;0t", 8);
                break;
            }

            case 21: {
#if 0  /* Disabled for now, see #1894 */
                char reply[3 + strlen(term->window_title) + 2 + 1];
                int chars = xsnprintf(
                    reply, sizeof(reply), "\033]l%s\033\\", term->window_title);
                term_to_slave(term, reply, chars);
#else
                LOG_WARN("CSI 21 t (report window title) ignored");
#endif
                break;
            }

            case 22: { /* push window title */
                /* 0 - icon + title, 1 - icon, 2 - title */
                unsigned what = vt_param_get(term, 1, 0);
                if (what == 0 || what == 2) {
                    if (tll_length(term->window_title_stack) < 128)
                        tll_push_back(
                            term->window_title_stack, xstrdup(term->window_title));
                    else
                        LOG_WARN("window title stack depth capped at 128 entries");
                }
                break;
            }

            case 23: { /* pop window title */
                /* 0 - icon + title, 1 - icon, 2 - title */
                unsigned what = vt_param_get(term, 1, 0);
                if (what == 0 || what == 2) {
                    if (tll_length(term->window_title_stack) > 0) {
                        char *title = tll_pop_back(term->window_title_stack);
                        term_set_window_title(term, title);
                        free(title);
                    }
                }
                break;
            }

            case 1001: {
            }

            default:
                LOG_DBG("ignoring %s", csi_as_string(term, final, -1));
                break;
            }
            break;
        }

        case 'n': {
            if (term->vt.params.idx > 0) {
                int param = vt_param_get(term, 0, 0);
                switch (param) {
                case 5:
                    /* Query device status */
                    term_to_slave(term, "\x1b[0n", 4);  /* "Device OK" */
                    break;

                case 6: {
                    /* u7 - cursor position query */

                    int row = term->origin == ORIGIN_ABSOLUTE
                        ? term->grid->cursor.point.row
                        : term->grid->cursor.point.row - term->scroll_region.start;

                    /* TODO: we use 0-based position, while the xterm
                     * terminfo says the receiver of the reply should
                     * decrement, hence we must add 1 */
                    char reply[64];
                    size_t n = xsnprintf(reply, sizeof(reply), "\x1b[%d;%dR",
                             row + 1, term->grid->cursor.point.col + 1);
                    term_to_slave(term, reply, n);
                    break;
                }

                default:
                    UNHANDLED();
                    break;
                }
            } else
                UNHANDLED();

            break;
        }

        default:
            UNHANDLED();
            break;
        }

        break;  /* private[0] == 0 */
    }

    case '?': {
        switch (final) {
        case 'h':
            /* DECSET - DEC private mode set */
            for (size_t i = 0; i < term->vt.params.idx; i++)
                decset(term, term->vt.params.v[i].value);
            break;

        case 'l':
            /* DECRST - DEC private mode reset */
            for (size_t i = 0; i < term->vt.params.idx; i++)
                decrst(term, term->vt.params.v[i].value);
            break;

        case 's':
            for (size_t i = 0; i < term->vt.params.idx; i++)
                xtsave(term, term->vt.params.v[i].value);
            break;

        case 'r':
            for (size_t i = 0; i < term->vt.params.idx; i++)
                xtrestore(term, term->vt.params.v[i].value);
            break;

        case 'S': {
            if (!term->conf->tweak.sixel) {
                UNHANDLED();
                break;
            }

            unsigned target = vt_param_get(term, 0, 0);
            unsigned operation = vt_param_get(term, 1, 0);

            switch (target) {
            case 1:
                switch (operation) {
                case 1: sixel_colors_report_current(term); break;
                case 2: sixel_colors_reset(term); break;
                case 3: sixel_colors_set(term, vt_param_get(term, 2, 0)); break;
                case 4: sixel_colors_report_max(term); break;
                default: UNHANDLED(); break;
                }
                break;

            case 2:
                switch (operation) {
                case 1: sixel_geometry_report_current(term); break;
                case 2: sixel_geometry_reset(term); break;
                case 3: sixel_geometry_set(term, vt_param_get(term, 2, 0), vt_param_get(term, 3, 0)); break;
                case 4: sixel_geometry_report_max(term); break;
                default: UNHANDLED(); break;
                }
                break;

            default:
                UNHANDLED();
                break;
            }

            break;
        }

        case 'm': {
            int resource = vt_param_get(term, 0, 0);
            int value = -1;

            switch (resource) {
            case 0:  /* modifyKeyboard */
                value = 0;
                break;

            case 1:  /* modifyCursorKeys */
            case 2:  /* modifyFunctionKeys */
                value = 1;
                break;

            case 4:  /* modifyOtherKeys */
                value = term->modify_other_keys_2 ? 2 : 1;
                break;

            default:
                LOG_WARN("XTQMODKEYS: invalid resource '%d' in '%s'",
                         resource, csi_as_string(term, final, -1));
                break;
            }

            if (value >= 0) {
                char reply[16] = {0};
                int chars = snprintf(reply, sizeof(reply),
                                     "\033[>%d;%dm", resource, value);
                term_to_slave(term, reply, chars);
            }
            break;
        }

        case 'n': {
            const int param = vt_param_get(term, 0, 0);

            switch (param) {
            case 996: {  /* Query current theme mode (see private mode 2031) */
                /*
                 * 1 - dark mode
                 * 2 - light mode
                 *
                 * In foot, the themes aren't necessarily light/dark,
                 * but by convention, the primary theme is dark, and
                 * the alternative theme is light.
                 */
                char reply[16] = {0};
                int chars = snprintf(
                    reply, sizeof(reply),
                    "\033[?997;%dn",
                    term->colors.active_theme == COLOR_THEME_DARK ? 1 : 2);

                term_to_slave(term, reply, chars);
                break;
            }

            case 998:
                term_send_visibility_report(term);
                break;
            }
            break;
        }

        case 'p': {
            /*
             * Request status of ECMA-48/"ANSI" private mode (DECRQM
             * for SM/RM modes; see private="?$" case further below for
             * DECSET/DECRST modes)
             */
            unsigned param = vt_param_get(term, 0, 0);
            unsigned status = DECRPM_NOT_RECOGNIZED;
            if (param == 4) {
                status = decrpm(term->insert_mode);
            }
            char reply[32];
            size_t n = xsnprintf(reply, sizeof(reply), "\033[%u;%u$y", param, status);
            term_to_slave(term, reply, n);
            break;
        }

        case 'u': {
            enum kitty_kbd_flags flags =
                term->grid->kitty_kbd.flags[term->grid->kitty_kbd.idx];

            char reply[8];
            int chars = snprintf(reply, sizeof(reply), "\033[?%uu", flags);
            term_to_slave(term, reply, chars);
            break;
        }

        default:
            UNHANDLED();
            break;
        }

        break; /* private[0] == '?' */
    }

    case '>': {
        switch (final) {
            case 'c':
                /* Send Device Attributes (Secondary DA) */
                if (vt_param_get(term, 0, 0) != 0) {
                    UNHANDLED();
                    break;
                }

                /*
                 * Param 1 - terminal type:
                 *   0 - vt100
                 *   1 - vt220
                 *   2 - vt240
                 *  18 - vt330
                 *  19 - vt340
                 *  24 - vt320
                 *  41 - vt420
                 *  61 - vt510
                 *  64 - vt520
                 *  65 - vt525
                 *
                 * Param 2 - firmware version xterm uses its version
                 *  number. We do to, in the format "MAJORMINORPATCH",
                 *  where all three version numbers are always two
                 *  digits. So e.g. 1.25.0 is reported as 012500.
                 *
                 * We report ourselves as a VT220. This must be
                 * synchronized with the primary DA response.
                 *
                 * Note: tertiary DA replies with "FOOT".
                 */

                static_assert(FOOT_MAJOR < 100, "Major version must not exceed 99");
                static_assert(FOOT_MINOR < 100, "Minor version must not exceed 99");
                static_assert(FOOT_PATCH < 100, "Patch version must not exceed 99");

                char reply[64];
                size_t n = xsnprintf(reply, sizeof(reply), "\033[>1;%02u%02u%02u;0c",
                         FOOT_MAJOR, FOOT_MINOR, FOOT_PATCH);

                term_to_slave(term, reply, n);
                break;

        case 'm':
            if (term->vt.params.idx == 0) {
                /* Reset all */
            } else {
                int resource = vt_param_get(term, 0, 0);
                int value = vt_param_get(term, 1, -1);

                switch (resource) {
                case 0: /* modifyKeyboard */
                    break;

                case 1: /* modifyCursorKeys */
                case 2: /* modifyFunctionKeys */
                    /* Ignored, we always report modifiers */
                    if (value != 2 && value != -1) {
                        LOG_WARN(
                            "unimplemented: %s = %d",
                            resource == 1 ? "modifyCursorKeys" :
                            resource == 2 ? "modifyFunctionKeys" : "<invalid>",
                            value);
                    }
                    break;

                case 4: /* modifyOtherKeys */
                    term->modify_other_keys_2 = value == 2;
                    LOG_DBG("modifyOtherKeys=%d", value);
                    break;

                default:
                    LOG_WARN("XTMODKEYS: invalid resource '%d' in '%s'",
                             resource, csi_as_string(term, final, -1));
                    break;
                }
            }
            break; /* final == 'm' */

        case 'n': {
            int resource = vt_param_get(term, 0, 2);  /* Default is modifyFunctionKeys */
            switch (resource) {
            case 0:  /* modifyKeyboard */
            case 1:  /* modifyCursorKeys */
            case 2:  /* modifyFunctionKeys */
                break;

            case 4:  /* modifyOtherKeys */
                /* We don't support fully disabling modifyOtherKeys,
                 * but simply revert back to mode '1' */
                term->modify_other_keys_2 = false;
                LOG_DBG("modifyOtherKeys=1");
                break;
            }
            break;
        }

        case 'u': {
            int flags = vt_param_get(term, 0, 0) & KITTY_KBD_SUPPORTED;

            struct grid *grid = term->grid;
            uint8_t idx = grid->kitty_kbd.idx;

            if (idx + 1 >= ALEN(grid->kitty_kbd.flags)) {
                /* Stack full, evict oldest by wrapping around */
                idx = 0;
            } else
                idx++;

            grid->kitty_kbd.flags[idx] = flags;
            grid->kitty_kbd.idx = idx;

            LOG_DBG("kitty kbd: pushed new flags: 0x%03x", flags);
            break;
        }

        case 'q': {
            /* XTVERSION */
            if (vt_param_get(term, 0, 0) != 0) {
                UNHANDLED();
                break;
            }

            char reply[64];
            size_t n = xsnprintf(
                reply, sizeof(reply), "\033P>|foot(%u.%u.%u%s%s)\033\\",
                FOOT_MAJOR, FOOT_MINOR, FOOT_PATCH,
                FOOT_EXTRA[0] != '\0' ? "-" : "", FOOT_EXTRA);
            term_to_slave(term, reply, n);
            break;
        }

        default:
            UNHANDLED();
            break;
        }

        break; /* private[0] == '>' */
    }

    case '<': {
        switch (final) {
        case 'u': {
            struct grid *grid = term->grid;
            int count = min(vt_param_get(term, 0, 1),  ALEN(grid->kitty_kbd.flags));
            LOG_DBG("kitty kbd: popping %d levels of flags", count);

            uint8_t idx = grid->kitty_kbd.idx;

            for (int i = 0; i < count; i++) {
                /* Reset flags. This ensures we get flags=0 when
                 * over-popping */
                grid->kitty_kbd.flags[idx] = 0;

                if (idx == 0)
                    idx = ALEN(grid->kitty_kbd.flags) - 1;
                else
                    idx--;
            }

            grid->kitty_kbd.idx = idx;

            LOG_DBG("kitty kbd: flags after pop: 0x%03x",
                    term->grid->kitty_kbd.flags[idx]);
            break;
        }
        }
        break; /* private[0] == '<' */
    }

    case ' ': {
        switch (final) {
        case 'q': {
            int param = vt_param_get(term, 0, 0);
            switch (param) {
            case 0: /* blinking block, but we use it to reset to configured default */
                term->cursor_style = term->conf->cursor.style;
                term->cursor_blink.deccsusr = term->conf->cursor.blink.enabled;
                term_cursor_blink_update(term);
                break;

            case 1:         /* blinking block */
            case 2:         /* steady block */
                term->cursor_style = term->conf->cursor.style == CURSOR_HOLLOW
                    ? CURSOR_HOLLOW : CURSOR_BLOCK;
                break;

            case 3:         /* blinking underline */
            case 4:         /* steady underline */
                term->cursor_style = CURSOR_UNDERLINE;
                break;

            case 5:         /* blinking bar */
            case 6:         /* steady bar */
                term->cursor_style = CURSOR_BEAM;
                break;

            default:
                UNHANDLED();
                break;
            }

            if (param > 0 && param <= 6) {
                term->cursor_blink.deccsusr = param & 1;
                term_cursor_blink_update(term);
            }
            break;
        }

        default:
            UNHANDLED();
            break;
        }
        break; /* private[0] == ' ' */
    }

    case '!': {
        if (final == 'p') {
            term_reset(term, false);
            break;
        }

        UNHANDLED();
        break; /* private[0] == '!' */
    }

    case '=': {
        switch (final) {
        case 'c':
            if (vt_param_get(term, 0, 0) != 0) {
                UNHANDLED();
                break;
            }

            /*
             * Send Device Attributes (Tertiary DA)
             *
             * Reply format is "DCS ! | DDDDDDDD ST"
             *
             * D..D is the unit ID of the terminal, consisting of four
             * hexadecimal pairs. The first pair represents the
             * manufacturing site code. This code can be any
             * hexadecimal value from 00 through FF.
             */

            term_to_slave(term, "\033P!|464f4f54\033\\", 14);  /* FOOT */
            break;

        case 'u': {
            int flag_set = vt_param_get(term, 0, 0) & KITTY_KBD_SUPPORTED;
            int mode = vt_param_get(term, 1, 1);

            struct grid *grid = term->grid;
            uint8_t idx = grid->kitty_kbd.idx;

            switch (mode) {
            case 1:
                /* set bits are set, unset bits are reset */
                grid->kitty_kbd.flags[idx] = flag_set;
                break;

            case 2:
                /* set bits are set, unset bits are left unchanged */
                grid->kitty_kbd.flags[idx] |= flag_set;
                break;

            case 3:
                /* set bits are reset, unset bits are left unchanged */
                grid->kitty_kbd.flags[idx] &= ~flag_set;
                break;

            default:
                UNHANDLED();
                break;
            }

            LOG_DBG("kitty kbd: flags after update: 0x%03x",
                    grid->kitty_kbd.flags[idx]);
            break;
        }

        default:
            UNHANDLED();
            break;
        }
        break; /* private[0] == '=' */
    }

    case '$': {
        switch (final) {
        case 'r': {  /* DECCARA */
            int top, left, bottom, right;
            if (!params_to_rectangular_area(
                    term, 0, &top, &left, &bottom, &right))
            {
                break;
            }

            for (int r = top; r <= bottom; r++) {
                struct row *row = grid_row(term->grid, r);
                row->dirty = true;

                for (int c = left; c <= right; c++) {
                    struct attributes *a = &row->cells[c].attrs;
                    a->clean = 0;

                    for (size_t i = 4; i < term->vt.params.idx; i++) {
                        const int param = term->vt.params.v[i].value;

                        /* DECCARA only supports a sub-set of SGR parameters */
                        switch (param) {
                        case 0:
                            a->bold = false;
                            a->underline = false;
                            a->blink = false;
                            a->reverse = false;
                            break;

                        case 1: a->bold = true; break;
                        case 4: a->underline = true; break;
                        case 5: a->blink = true; break;
                        case 7: a->reverse = true; break;

                        case 22: a->bold = false; break;
                        case 24: a->underline = false; break;
                        case 25: a->blink = false; break;
                        case 27: a->reverse = false; break;
                        }
                    }
                }
            }
            break;
        }

        case 't': {  /* DECRARA */
            int top, left, bottom, right;
            if (!params_to_rectangular_area(
                    term, 0, &top, &left, &bottom, &right))
            {
                break;
            }

            for (int r = top; r <= bottom; r++) {
                struct row *row = grid_row(term->grid, r);
                row->dirty = true;

                for (int c = left; c <= right; c++) {
                    struct attributes *a = &row->cells[c].attrs;
                    a->clean = 0;

                    for (size_t i = 4; i < term->vt.params.idx; i++) {
                        const int param = term->vt.params.v[i].value;

                        /* DECRARA only supports a sub-set of SGR parameters */
                        switch (param) {
                        case 0:
                            a->bold = !a->bold;
                            a->underline = !a->underline;
                            a->blink = !a->blink;
                            a->reverse = !a->reverse;
                            break;

                        case 1: a->bold = !a->bold; break;
                        case 4: a->underline = !a->underline; break;
                        case 5: a->blink = !a->blink; break;
                        case 7: a->reverse = !a->reverse; break;
                        }
                    }
                }
            }
            break;
        }

        case 'v': {  /* DECCRA */
            int src_top, src_left, src_bottom, src_right;
            if (!params_to_rectangular_area(
                    term, 0, &src_top, &src_left, &src_bottom, &src_right))
            {
                break;
            }

            int src_page = vt_param_get(term, 4, 1);
            int dst_rel_top = vt_param_get(term, 5, 1) - 1;
            int dst_left = min(vt_param_get(term, 6, 1) - 1, term->cols - 1);
            int dst_page = vt_param_get(term, 7, 1);

            if (unlikely(src_page != 1 || dst_page != 1)) {
                /* We don’t support “pages” */
                break;
            }

            int dst_rel_bottom = dst_rel_top + (src_bottom - src_top);
            int dst_right = min(dst_left + (src_right - src_left), term->cols - 1);

            int dst_top = term_row_rel_to_abs(term, dst_rel_top);
            int dst_bottom = term_row_rel_to_abs(term, dst_rel_bottom);

            if (unlikely(dst_left > dst_right || dst_top > dst_bottom))
                break;

            /*
             * src validated by params_to_rectangular_area()
             * dst validated above
             */
            xassert(src_bottom - src_top >= 0);
            xassert(dst_bottom - dst_top >= 0);
            xassert(src_right - src_left >= 0);
            xassert(dst_right - dst_left >= 0);

            /* Target area outside the screen is clipped */
            const size_t row_count = min(src_bottom - src_top,
                                         dst_bottom - dst_top) + 1;
            const size_t cell_count = min(src_right - src_left,
                                          dst_right - dst_left) + 1;

            sixel_overwrite_by_rectangle(
                term, dst_top, dst_left, row_count, cell_count);

            /*
             * Copy source area
             *
             * Note: since source and destination may overlap, we need
             * to copy out the entire source region first, and _then_
             * write the destination. I.e. this is similar to how
             * memmove() behaves, but adapted to our row/cell
             * structure.
             */
            struct cell **copy = xmalloc(row_count * sizeof(copy[0]));
            for (int r = 0; r < row_count; r++) {
                copy[r] = xmalloc(cell_count * sizeof(copy[r][0]));

                const struct row *row = grid_row(term->grid, src_top + r);
                const struct cell *cell = &row->cells[src_left];
                memcpy(copy[r], cell, cell_count * sizeof(copy[r][0]));
            }

            /* Paste into destination area */
            for (int r = 0; r < row_count; r++) {
                struct row *row = grid_row(term->grid, dst_top + r);
                row->dirty = true;

                struct cell *cell = &row->cells[dst_left];
                memcpy(cell, copy[r], cell_count * sizeof(copy[r][0]));
                free(copy[r]);

                for (;cell < &row->cells[dst_left + cell_count]; cell++)
                    cell->attrs.clean = 0;

                if (unlikely(row->extra != NULL)) {
                    /* TODO: technically, we should copy the source URIs... */
                    grid_row_uri_range_erase(row, dst_left, dst_right);
                }
            }
            free(copy);
            break;
        }

        case 'x': {  /* DECFRA */
            const uint8_t c = vt_param_get(term, 0, 0);

            if (unlikely(!((c >= 32 && c < 126) || c >= 160)))
                break;

            int top, left, bottom, right;
            if (!params_to_rectangular_area(
                    term, 1, &top, &left, &bottom, &right))
            {
                break;
            }

            /* Erase the entire region at once (MUCH cheaper than
             * doing it row by row, or even character by
             * character). */
            sixel_overwrite_by_rectangle(
                term, top, left, bottom - top + 1, right - left + 1);

            for (int r = top; r <= bottom; r++)
                term_fill(term, r, left, c, right - left + 1, true);

            break;
        }

        case 'z': {  /* DECERA */
            int top, left, bottom, right;
            if (!params_to_rectangular_area(
                    term, 0, &top, &left, &bottom, &right))
            {
                break;
            }

            /*
             * Note: term_erase() _also_ erases sixels, but since
             * we’re forced to erase one row at a time, erasing the
             * entire sixel here is more efficient.
             */
            sixel_overwrite_by_rectangle(
                term, top, left, bottom - top + 1, right - left + 1);

            for (int r = top; r <= bottom; r++)
                term_erase(term, r, left, r, right);
            break;
        }
        }

        break; /* private[0] == ‘$’ */
    }

    case '#': {
        switch (final) {
        case 'P': { /* XTPUSHCOLORS */
            int slot = vt_param_get(term, 0, 0);

            /* Pm == 0, "push" (what xterm does is take take the
               *current* slot + 1, even if that's in the middle of the
               stack, and overwrites whatever is already in that
               slot) */
            if (slot == 0)
                slot = term->color_stack.idx + 1;

            const size_t max_slot = 128;
            if (slot > max_slot) {
                LOG_WARN("XTPUSHCOLORS slot index capped to 128");
                slot = max_slot;
            }

            if (term->color_stack.size < slot) {
                const size_t new_size = slot;
                term->color_stack.stack = xrealloc(
                    term->color_stack.stack,
                    new_size * sizeof(term->color_stack.stack[0]));

                /* Initialize new slots (except the selected slot,
                   which is done below) */
                xassert(new_size > 0);
                for (size_t i = term->color_stack.size; i < new_size - 1; i++) {
                    memcpy(&term->color_stack.stack[i], &term->colors,
                           sizeof(term->colors));
                }
                term->color_stack.size = new_size;
            }

            xassert(slot > 0);
            xassert(slot <= term->color_stack.size);
            term->color_stack.idx = slot;
            memcpy(&term->color_stack.stack[slot - 1], &term->colors,
                   sizeof(term->colors));
            break;
        }

        case 'Q': {  /* XTPOPCOLORS */
            int slot = vt_param_get(term, 0, 0);

            /* Pm == 0, "pop" (what xterm does is copy colors from the
              *current* slot, *and* decrease the current slot index,
              even if that's in the middle of the stack) */
            if (slot == 0)
                slot = term->color_stack.idx;

            if (slot > 0 && slot <= term->color_stack.size) {
                memcpy(&term->colors, &term->color_stack.stack[slot - 1],
                       sizeof(term->colors));
                term->color_stack.idx = slot - 1;

                /* Assume a full palette switch *will* affect almost
                   all cells. The alternative is to call
                   term_damage_color() for all 256 palette entries
                   *and* the default fg/bg (256 + 2 calls in total) */
                term_damage_view(term);
                term_damage_margins(term);
            } else if (slot == 0) {
                LOG_ERR("XTPOPCOLORS: cannot pop beyond the first element");
            } else {
                LOG_ERR(
                    "XTPOPCOLORS: invalid color slot: %d "
                    "(stack has %zu slots, current slot is %zu)",
                    vt_param_get(term, 0, 0),
                    term->color_stack.size, term->color_stack.idx);
            }
            break;
        }

        case 'R': {  /* XTREPORTCOLORS */
            char reply[64];
            size_t n = xsnprintf(reply, sizeof(reply), "\033[?%zu;%zu#Q",
                              term->color_stack.idx, term->color_stack.size);
            term_to_slave(term, reply, n);
            break;
        }
        }
        break; /* private[0] == '#' */
    }

    case 0x243f:  /* ?$ */
        switch (final) {
        case 'p': {
            unsigned param = vt_param_get(term, 0, 0);

            /*
             * Request DEC private mode (DECRQM)
             * Reply:
             *   0 - not recognized
             *   1 - set
             *   2 - reset
             *   3 - permanently set
             *   4 - permantently reset
             */
            unsigned status = decrqm(term, param);
            char reply[32];
            size_t n = xsnprintf(reply, sizeof(reply), "\033[?%u;%u$y", param, status);
            term_to_slave(term, reply, n);
            break;

        }

        default:
            UNHANDLED();
            break;
        }

        break; /* private[0] == '?' && private[1] == '$' */

    default:
        UNHANDLED();
        break;
    }
}
