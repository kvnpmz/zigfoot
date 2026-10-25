#include "osc.h"

void osc_notify_impl(struct terminal *term, char *string);

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

IGNORE_WARNING("-Wpedantic")
static bool
verify_kitty_id_is_valid(const char *id)
{
    const size_t len = strlen(id);

    for (size_t i = 0; i < len; i++) {
        switch (id[i]) {
        case 'a' ... 'z':
        case 'A' ... 'Z':
        case '0' ... '9':
        case '_':
        case '-':
        case '+':
        case '.':
            break;

        default:
            return false;
        }
    }

    return true;
}
UNIGNORE_WARNINGS

void
kitty_notification(struct terminal *term, char *string)
{
    /* https://sw.kovidgoyal.net/kitty/desktop-notifications */

    char *payload_raw = strchr(string, ';');
    if (payload_raw == NULL)
        return;

    char *parameters = string;
    *payload_raw = '\0';
    payload_raw++;

    char *id = NULL;               /* The 'i' parameter */
    char *app_id = NULL;           /* The 'f' parameter */
    char *icon_cache_id = NULL;    /* The 'g' parameter */
    char *symbolic_icon = NULL;    /* The 'n' parameter */
    char *category = NULL;         /* The 't' parameter */
    char *sound_name = NULL;       /* The 's' parameter */
    char *payload = NULL;

    bool focus = true;             /* The 'a' parameter */
    bool report_activated = false; /* The 'a' parameter */
    bool report_closed = false;    /* The 'c' parameter */
    bool done = true;              /* The 'd' parameter */
    bool base64 = false;           /* The 'e' parameter */

    int32_t expire_time = -1;      /* The 'w' parameter */

    size_t payload_size;
    enum {
        PAYLOAD_TITLE,
        PAYLOAD_BODY,
        PAYLOAD_CLOSE,
        PAYLOAD_ALIVE,
        PAYLOAD_ICON,
        PAYLOAD_BUTTON,
    } payload_type = PAYLOAD_TITLE; /* The 'p' parameter */

    enum notify_when when = NOTIFY_ALWAYS;
    enum notify_urgency urgency = NOTIFY_URGENCY_NORMAL;

    bool have_a = false;
    bool have_c = false;
    bool have_o = false;
    bool have_u = false;
    bool have_w = false;

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
        case 'a': {
            /* notification activation action: focus|report|-focus|-report */
            have_a = true;
            char *a_ctx = NULL;

            for (const char *v = strtok_r(value, ",", &a_ctx);
                 v != NULL;
                 v = strtok_r(NULL, ",", &a_ctx))
            {
                bool reverse = v[0] == '-';
                if (reverse)
                    v++;

                if (streq(v, "focus"))
                    focus = !reverse;
                else if (streq(v, "report"))
                    report_activated = !reverse;
            }

            break;
        }

        case 'c':
            if (value[0] == '1' && value[1] == '\0')
                report_closed = true;
            else if (value[0] == '0' && value[1] == '\0')
                report_closed = false;
            have_c = true;
            break;

        case 'd':
            /* done: 0|1 */
            if (value[0] == '0' && value[1] == '\0')
                done = false;
            else if (value[0] == '1' && value[1] == '\0')
                done = true;
            break;

        case 'e':
            /* base64 (payload encoding): 0=utf8, 1=base64(utf8) */
            if (value[0] == '0' && value[1] == '\0')
                base64 = false;
            else if (value[0] == '1' && value[1] == '\0')
                base64 = true;
            break;

        case 'i':
            /* id */
            if (verify_kitty_id_is_valid(value)) {
                free(id);
                id = xstrdup(value);
            } else
                LOG_WARN("OSC-99: ignoring invalid 'i' identifier");
            break;

        case 'p':
            /* payload content: title|body */
            if (streq(value, "title"))
                payload_type = PAYLOAD_TITLE;
            else if (streq(value, "body"))
                payload_type = PAYLOAD_BODY;
            else if (streq(value, "close"))
                payload_type = PAYLOAD_CLOSE;
            else if (streq(value, "alive"))
                payload_type = PAYLOAD_ALIVE;
            else if (streq(value, "icon"))
                payload_type = PAYLOAD_ICON;
            else if (streq(value, "buttons"))
                payload_type = PAYLOAD_BUTTON;
            else if (streq(value, "?")) {
                /* Query capabilities */

                const char *reply_id = id != NULL ? id : "0";

                const char *p_caps = "title,body,?,close,alive,icon,buttons";
                const char *a_caps = "focus,report";
                const char *u_caps = "0,1,2";

                char when_caps[64];
                strcpy(when_caps, "unfocused");
                if (!term->conf->desktop_notifications.inhibit_when_focused)
                    strcat(when_caps, ",always");

                const char *terminator = term->vt.osc.bel ? "\a" : "\033\\";

                char reply[512];
                size_t n = xsnprintf(
                    reply, sizeof(reply),
                    "\033]99;i=%s:p=?;p=%s:a=%s:o=%s:u=%s:c=1:w=1:s=system,silent,error,warn,warning,info,question%s",
                    reply_id, p_caps, a_caps, when_caps, u_caps, terminator);

                term_to_slave(term, reply, n);
                goto out;
            }
            break;

        case 'o':
            /* honor when: always|unfocused|invisible */
            have_o = true;
            if (streq(value, "always"))
                when = NOTIFY_ALWAYS;
            else if (streq(value, "unfocused"))
                when = NOTIFY_UNFOCUSED;
            else if (streq(value, "invisible"))
                when = NOTIFY_INVISIBLE;
            break;

        case 'u':
            /* urgency: 0=low, 1=normal, 2=critical */
            have_u = true;
            if (value[0] == '0' && value[1] == '\0')
                urgency = NOTIFY_URGENCY_LOW;
            else if (value[0] == '1' && value[1] == '\0')
                urgency = NOTIFY_URGENCY_NORMAL;
            else if (value[0] == '2' && value[1] == '\0')
                urgency = NOTIFY_URGENCY_CRITICAL;
            break;

        case 'w': {
            /* Notification timeout */
            errno = 0;
            char *end = NULL;
            long timeout = strtol(value, &end, 10);

            if (errno == 0 && *end == '\0' && timeout <= INT32_MAX) {
                expire_time = timeout;
                have_w = true;
            }
            break;
        }

        case 'f': {
            /* App-name */
            char *decoded = base64_decode(value, NULL);
            if (decoded != NULL) {
                free(app_id);
                app_id = decoded;
            }
            break;
        }

        case 't': {
            /* Type (category) */
            char *decoded = base64_decode(value, NULL);
            if (decoded != NULL) {
                if (category == NULL)
                    category = decoded;
                else {
                    /* Append, comma separated */
                    char *old_category = category;
                    category = xstrjoin3(old_category, ",", decoded);
                    free(decoded);
                    free(old_category);
                }
            }
            break;
        }

        case 's': {
            /* Sound */
            char *decoded = base64_decode(value, NULL);
            if (decoded != NULL) {
                free(sound_name);
                sound_name = decoded;

                const char *translated_name = NULL;

                if (streq(decoded, "error"))
                    translated_name = "dialog-error";
                else if (streq(decoded, "warn") || streq(decoded, "warning"))
                    translated_name = "dialog-warning";
                else if (streq(decoded, "info"))
                    translated_name = "dialog-information";
                else if (streq(decoded, "question"))
                    translated_name = "dialog-question";

                if (translated_name != NULL) {
                    free(sound_name);
                    sound_name = xstrdup(translated_name);
                }
            }
            break;
        }

        case 'g':
            /* graphical ID (see 'n' and 'p=icon') */
            free(icon_cache_id);
            icon_cache_id = xstrdup(value);
            break;

        case 'n': {
            /* Symbolic icon name, may used with 'g' */

            /*
             * Sigh, protocol says 'n' can be used multiple times, and
             * that the terminal picks the first one that it can
             * resolve.
             *
             * We can't resolve any icons at all. So, enter
             * heuristics... let's pick the *shortest* symbolic
             * name. The idea is that icon *names* are typically
             * shorter than .desktop names, and macOS bundle
             * identifiers.
             */
            char *maybe_new_symbolic_icon = base64_decode(value, NULL);
            if (maybe_new_symbolic_icon == NULL)
                break;

            if (symbolic_icon == NULL ||
                strlen(maybe_new_symbolic_icon) < strlen(symbolic_icon))
            {
                free(symbolic_icon);
                symbolic_icon = maybe_new_symbolic_icon;

                /* Translate OSC-99 "special" names */
                if (symbolic_icon != NULL) {
                    const char *translated_name = NULL;

                    if (streq(symbolic_icon, "error"))
                        translated_name = "dialog-error";
                    else if (streq(symbolic_icon, "warn") ||
                             streq(symbolic_icon, "warning"))
                        translated_name = "dialog-warning";
                    else if (streq(symbolic_icon, "info"))
                        translated_name = "dialog-information";
                    else if (streq(symbolic_icon, "question"))
                        translated_name = "dialog-question";
                    else if (streq(symbolic_icon, "help"))
                        translated_name = "system-help";
                    else if (streq(symbolic_icon, "file-manager"))
                        translated_name = "system-file-manager";
                    else if (streq(symbolic_icon, "system-monitor"))
                        translated_name = "utilities-system-monitor";
                    else if (streq(symbolic_icon, "text-editor"))
                        translated_name = "text-editor";

                    if (translated_name != NULL) {
                        free(symbolic_icon);
                        symbolic_icon = xstrdup(translated_name);
                    }
                }
            } else {
                free(maybe_new_symbolic_icon);
            }
            break;
        }
        }
    }

    if (base64) {
        payload = base64_decode(payload_raw, &payload_size);
        if (payload == NULL)
            goto out;
    } else {
        payload = xstrdup(payload_raw);
        payload_size = strlen(payload);
    }

    /* Append metadata to previous notification chunk */
    struct notification *notif = &term->kitty_notification;

    if (!((id == NULL && notif->id == NULL) ||
          (id != NULL && notif->id != NULL && streq(id, notif->id))) ||
        !notif->may_be_programatically_closed)  /* Free:d notification has this as false... */
    {
        /* ID mismatch, ignore previous notification state */
        notify_free(term, notif);

        notif->id = id;
        notif->when = when;
        notif->urgency = urgency;
        notif->expire_time = expire_time;
        notif->focus = focus;
        notif->may_be_programatically_closed = true;
        notif->report_activated = report_activated;
        notif->report_closed = report_closed;

        id = NULL; /* Prevent double free */
    }

    if (have_a) {
        notif->focus = focus;
        notif->report_activated = report_activated;
    }

    if (have_c)
        notif->report_closed = report_closed;

    if (have_o)
        notif->when = when;
    if (have_u)
        notif->urgency = urgency;
    if (have_w)
        notif->expire_time = expire_time;

    if (icon_cache_id != NULL) {
        free(notif->icon_cache_id);
        notif->icon_cache_id = icon_cache_id;
        icon_cache_id = NULL;  /* Prevent double free */
    }

    if (symbolic_icon != NULL) {
        free(notif->icon_symbolic_name);
        notif->icon_symbolic_name = symbolic_icon;
        symbolic_icon = NULL;
    }

    if (app_id != NULL) {
        free(notif->app_id);
        notif->app_id = app_id;
        app_id = NULL;  /* Prevent double free */
    }

    if (category != NULL) {
        if (notif->category == NULL) {
            notif->category = category;
            category = NULL;  /* Prevent double free */
        } else {
            /* Append, comma separated */
            char *new_category = xstrjoin3(notif->category, ",", category);
            free(notif->category);
            notif->category = new_category;
        }
    }

    if (sound_name != NULL) {
        notif->muted = streq(sound_name, "silent");

        if (notif->muted || streq(sound_name, "system")) {
            free(notif->sound_name);
            notif->sound_name = NULL;
        } else {
            free(notif->sound_name);
            notif->sound_name = sound_name;
            sound_name = NULL;  /* Prevent double free */
        }
    }

    /* Handled chunked payload - append to existing metadata */
    switch (payload_type) {
    case PAYLOAD_TITLE:
    case PAYLOAD_BODY: {
        char **ptr = payload_type == PAYLOAD_TITLE
            ? &notif->title
            : &notif->body;

        if (*ptr == NULL) {
            *ptr = payload;
            payload = NULL;
        } else {
            char *old = *ptr;
            *ptr = xstrjoin(old, payload);
            free(old);
        }
        break;
    }

    case PAYLOAD_CLOSE:
    case PAYLOAD_ALIVE:
        /* Ignore payload */
        break;

    case PAYLOAD_ICON:
        if (notif->icon_data == NULL) {
            notif->icon_data = (uint8_t *)payload;
            notif->icon_data_sz = payload_size;
            payload = NULL;
        } else {
            notif->icon_data = xrealloc(
                notif->icon_data, notif->icon_data_sz + payload_size);
            memcpy(&notif->icon_data[notif->icon_data_sz], payload, payload_size);
            notif->icon_data_sz += payload_size;
        }
        break;

    case PAYLOAD_BUTTON: {
        char *ctx = NULL;
        for (const char *button = strtok_r(payload, "\u2028", &ctx);
             button != NULL;
             button = strtok_r(NULL, "\u2028", &ctx))
        {
            if (button[0] != '\0') {
                tll_push_back(notif->actions, xstrdup(button));
            }
        }

        break;
    }
    }

    if (done) {
        /* Update icon cache, if necessary */
        if (notif->icon_cache_id != NULL &&
            (notif->icon_symbolic_name != NULL || notif->icon_data != NULL))
        {
            notify_icon_del(term, notif->icon_cache_id);
            notify_icon_add(term, notif->icon_cache_id,
                            notif->icon_symbolic_name,
                            notif->icon_data, notif->icon_data_sz);

            /* Don't need this anymore */
            free(notif->icon_symbolic_name);
            free(notif->icon_data);
            notif->icon_symbolic_name = NULL;
            notif->icon_data = NULL;
            notif->icon_data_sz = 0;
        }

        if (payload_type == PAYLOAD_CLOSE) {
            if (notif->id != NULL)
                notify_close(term, notif->id);
        } else if (payload_type == PAYLOAD_ALIVE)  {
            char *alive_ids = NULL;

            tll_foreach(term->active_notifications, it) {
                /* TODO: check with kitty: use "0" for all
                   notifications with no ID? */

                const char *item_id = it->item.id != NULL ? it->item.id : "0";

                if (alive_ids == NULL)
                    alive_ids = xstrdup(item_id);
                else {
                    char *old_alive_ids = alive_ids;
                    alive_ids = xstrjoin3(old_alive_ids, ",", item_id);
                    free(old_alive_ids);
                }
            }

            char *reply = xasprintf(
                "\033]99;i=%s:p=alive;%s\033\\",
                notif->id != NULL ? notif->id : "0",
                alive_ids != NULL ? alive_ids : "");

            term_to_slave(term, reply, strlen(reply));
            free(reply);
            free(alive_ids);
        } else {
            /*
             * Show notification.
             *
             * The checks for title|body is to handle notifications that
             * only load icon data into the icon cache
             */
            if (notif->title != NULL || notif->body != NULL) {
                notify_notify(term, notif);
            }
        }

        notify_free(term, notif);
    }

out:
    free(id);
    free(app_id);
    free(icon_cache_id);
    free(symbolic_icon);
    free(payload);
    free(category);
    free(sound_name);
}

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

