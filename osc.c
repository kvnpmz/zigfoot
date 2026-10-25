#include "osc.h"

void osc_notify_impl(struct terminal *term, char *string);
void kitty_notification_impl(struct terminal *term, char *string);

#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>

#include <sys/epoll.h>

#define LOG_MODULE "osc"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "base64.h"
#include "config.h"
#include "macros.h"
#include "notify.h"
#include "selection.h"
#include "terminal.h"
#include "uri.h"
#include "util.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* Ported to osc.zig (chunk B) */
void osc_flash(struct terminal *term);
void osc_set_pwd(struct terminal *term, char *string);
void osc_uri(struct terminal *term, char *string);

/* Ported to osc.zig (chunk C) */
bool parse_legacy_color(const char *string, uint32_t *color, bool *_have_alpha, uint16_t *_alpha);
bool parse_rgb(const char *string, uint32_t *color, bool *_have_alpha, uint16_t *_alpha);

/* Ported to osc.zig (chunk D) */
void osc_selection(struct terminal *term, char *string);
void osc_to_clipboard(struct terminal *term, const char *target, const char *base64_data);
void osc_from_clipboard(struct terminal *term, const char *source);

#define UNHANDLED() LOG_DBG("unhandled: OSC: %.*s", (int)term->vt.osc.idx, term->vt.osc.data)

void
kitty_text_size(struct terminal *term, char *string)
{
    char *text = strchr(string, ';');
    if (text == NULL)
        return;

    char *parameters = string;
    *text = '\0';
    text++;

    if (text[0] == '\0')
        return;

    char32_t *wchars = ambstoc32(text);
    if (wchars == NULL)
        return;

    int forced_width = 0;

    char *ctx = NULL;
    for (char *param = strtok_r(parameters, ":", &ctx);
         param != NULL;
         param = strtok_r(NULL, ":", &ctx))
    {
        /* All parameters are on the form X=value, where X is always
           exactly one character */
        if (param[0] == '\0' || param[1] != '=')
            continue;

        char *value = &param[2];

        switch (param[0]) {
        case 'w': {
            errno = 0;
            char *end = NULL;
            unsigned long w = strtoul(value, &end, 10);

            if (*end == '\0' && errno == 0 && w <= 7) {
                forced_width = (int)w;
                break;
            } else
                LOG_ERR("OSC-66: invalid 'w' value, ignoring");
            break;
        }

        case 's':
        case 'n':
        case 'd':
        case 'v':
            LOG_WARN("OSC-66: unsupported: '%c' parameter, ignoring", param[0]);
            break;
        }
    }

    const size_t len = c32len(wchars);

    if (forced_width == 0) {
        /*
         * w=0 means we split the text up as we'd normally do... Since
         * we don't support any other parameters of the text-sizing
         * protocol, that means we just process the string as if it
         * has been printed without this OSC.
         */
        for (size_t i = 0; i < len; i++)
            term_process_and_print_non_ascii(term, wchars[i]);
        free(wchars);
        return;
    }

    size_t max_cp_width = 0;
    size_t all_cp_width = 0;

    for (size_t i = 0; i < len; i++) {
        const size_t cp_width = c32width(wchars[i]);
        all_cp_width += cp_width;
        max_cp_width = max(max_cp_width, cp_width);
    }

    size_t calculated_width = 0;
    switch (term->conf->tweak.grapheme_width_method) {
    case GRAPHEME_WIDTH_WCSWIDTH: calculated_width = all_cp_width; break;
    case GRAPHEME_WIDTH_MAX:      calculated_width = max_cp_width; break;
    case GRAPHEME_WIDTH_DOUBLE:   calculated_width = min(max_cp_width, 2); break;
    }

    const size_t width = forced_width == 0 ? calculated_width : forced_width;

    LOG_DBG("len=%zu, forced=%d, calculated=%zu, using=%zu",
            len, forced_width, calculated_width, width);

#if 0
    if (len == 1 && calculated_width == forced_width) {
        /*
         * Optimization: if there's a single codepoint, and either
         * w=0, or the 'w' matches the calculated width, print
         * codepoint directly instead of creating a combining
         * character.
         */
        term_print(term, wchars[0], width);
        free(wchars);
        return;
    }
#endif

    uint32_t key = composed_key_from_chars(wchars, len);

    const struct composed *composed = composed_lookup_without_collision(
        term->composed, &key, wchars, len - 1, wchars[len - 1], forced_width);

    if (composed == NULL) {
        struct composed *new_cc = xmalloc(sizeof(*new_cc));
        new_cc->chars = wchars;
        new_cc->count = len;
        new_cc->key = key;
        new_cc->width = width;
        new_cc->forced_width = forced_width;

        term->composed_count++;
        composed_insert(&term->composed, new_cc);
        composed = new_cc;
    } else if (composed->width == width) {
        free(wchars);
    }

    term_print(
        term, CELL_COMB_CHARS_LO + composed->key,
        composed->forced_width > 0 ? composed->forced_width : composed->width,
        false);
}

