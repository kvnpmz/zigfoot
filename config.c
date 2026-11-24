#include "config.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <ctype.h>
#include <unistd.h>
#include <errno.h>
#include <pwd.h>
#include <fcntl.h>

#include <sys/types.h>
#include <sys/stat.h>

#include <linux/input-event-codes.h>
#include <xkbcommon/xkbcommon.h>
#include <fontconfig/fontconfig.h>

#define LOG_MODULE "config"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "char32.h"
#include "debug.h"
#include "input.h"
#include "key-binding.h"
#include "macros.h"
#include "tokenize.h"
#include "util.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* struct context: moved to config.h (mirrored in terminal_types.zig) */

/* Value-parsing helpers: ported to config.zig. */
extern bool str_to_ulong(const char *s, int base, unsigned long *res);
extern bool value_to_bool(struct context *ctx, bool *res);
extern bool value_to_uint16(struct context *ctx, int base, uint16_t *res);
extern bool value_to_uint32(struct context *ctx, int base, uint32_t *res);
extern bool value_to_dimensions(struct context *ctx, uint32_t *x, uint32_t *y);
extern bool value_to_float(struct context *ctx, float *res);
extern bool value_to_str(struct context *ctx, char **res);
extern bool value_to_wchars(struct context *ctx, char32_t **res);
extern bool value_to_enum(struct context *ctx, const char **value_map, int *res);
extern bool value_to_color(struct context *ctx, uint32_t *result, bool allow_alpha);
extern bool value_to_two_colors(
    struct context *ctx, uint32_t *first, uint32_t *second, bool allow_alpha);
extern bool value_to_pt_or_px(struct context *ctx, struct pt_or_px *res);
extern bool value_to_spawn_template(
    struct context *ctx, struct config_spawn_template *template);
extern void free_argv(struct argv *argv);
extern void clone_argv(struct argv *dst, const struct argv *src);
extern void spawn_template_free(struct config_spawn_template *template);
extern void spawn_template_clone(
    struct config_spawn_template *dst, const struct config_spawn_template *src);

/* Section parsers: ported to config.zig. */
/* Binding helpers: ported to config.zig (C2i). */
extern void free_binding_aux(struct binding_aux *aux);
extern void free_key_binding(struct config_key_binding *binding);
extern void free_key_binding_list(struct config_key_binding_list *bindings);
extern void parse_modifiers(const char *text, size_t len, config_modifier_list_t *modifiers);
extern bool binding_aux_equal(const struct binding_aux *a, const struct binding_aux *b);
extern void remove_from_key_bindings_list(struct config_key_binding_list *bindings, int action, const struct binding_aux *aux);
extern int mouse_button_name_to_code(const char *name);
extern const char *mouse_button_code_to_name(int code);
extern bool modifiers_equal(const config_modifier_list_t *mods1, const config_modifier_list_t *mods2);
extern bool modifiers_disjoint(const config_modifier_list_t *mods1, const config_modifier_list_t *mods2);
extern char *modifiers_to_str(const config_modifier_list_t *mods, bool strip_last_plus);
extern bool value_to_key_combos(struct context *ctx, int action, struct binding_aux *aux, struct config_key_binding_list *bindings, enum key_binding_type type);
extern ssize_t pipe_argv_from_value(struct context *ctx, struct argv *argv);
extern ssize_t regex_name_from_value(struct context *ctx, char **regex_name);
extern size_t config_button_map_len(void);
extern int config_button_map_code(size_t idx);
extern const char *config_button_map_name(size_t idx);

extern bool parse_section_security(struct context *ctx);
extern bool parse_section_bell(struct context *ctx);
extern bool parse_section_desktop_notifications(struct context *ctx);
extern bool parse_section_scrollback(struct context *ctx);
extern bool parse_section_cursor(struct context *ctx);
extern bool parse_section_mouse(struct context *ctx);
extern bool parse_section_touch(struct context *ctx);
extern bool parse_section_environment(struct context *ctx);
extern bool parse_color_theme(struct context *ctx, struct color_theme *theme);
extern bool parse_section_colors_dark(struct context *ctx);
extern bool parse_section_colors_light(struct context *ctx);
extern bool parse_section_csd(struct context *ctx);
extern bool parse_section_tweak(struct context *ctx);
extern bool parse_section_main(struct context *ctx);

static const enum user_notification_kind log_class_to_notify_kind[LOG_CLASS_COUNT] = {
    [LOG_CLASS_WARNING] = USER_NOTIFICATION_WARNING,
    [LOG_CLASS_ERROR] = USER_NOTIFICATION_ERROR,
};

static void NOINLINE VPRINTF(5)
log_and_notify_va(struct config *conf, enum log_class log_class,
                  const char *file, int lineno, const char *fmt, va_list va)
{
    xassert(log_class < ALEN(log_class_to_notify_kind));
    enum user_notification_kind kind = log_class_to_notify_kind[log_class];

    if (kind == 0) {
        BUG("unsupported log class: %d", (int)log_class);
        return;
    }

    char *formatted_msg = xvasprintf(fmt, va);
    log_msg(log_class, LOG_MODULE, file, lineno, "%s", formatted_msg);
    user_notification_add(&conf->notifications, kind, formatted_msg);
}

/* Non-static: config.zig's collision logging calls it. */
void NOINLINE PRINTF(5)
log_and_notify(struct config *conf, enum log_class log_class,
               const char *file, int lineno, const char *fmt, ...)
{
    va_list va;
    va_start(va, fmt);
    log_and_notify_va(conf, log_class, file, lineno, fmt, va);
    va_end(va);
}

/* Non-static: config.zig logs through it. */
void NOINLINE PRINTF(5)
log_contextual(struct context *ctx, enum log_class log_class,
               const char *file, int lineno, const char *fmt, ...)
{
    va_list va;
    va_start(va, fmt);
    char *formatted_msg = xvasprintf(fmt, va);
    va_end(va);

    const bool print_dot = ctx->key != NULL;
    const bool print_colon = ctx->value != NULL;
    const bool print_section_suffix = ctx->section_suffix != NULL;

    if (!print_dot)
        ctx->key = "";

    if (!print_colon)
        ctx->value = "";

    if (!print_section_suffix)
        ctx->section_suffix = "";

    log_and_notify(
        ctx->conf, log_class, file, lineno, "%s:%d: [%s%s%s]%s%s%s%s: %s",
        ctx->path, ctx->lineno, ctx->section,
        print_section_suffix ? ":" : "", ctx->section_suffix,
        print_dot ? "." : "", ctx->key, print_colon ? ": " : "",
        ctx->value, formatted_msg);
    free(formatted_msg);
}


static void NOINLINE VPRINTF(4)
log_and_notify_errno_va(struct config *conf, const char *file, int lineno,
                     const char *fmt, va_list va)
{
    int errno_copy = errno;
    char *formatted_msg = xvasprintf(fmt, va);
    log_and_notify(
        conf, LOG_CLASS_ERROR, file, lineno,
        "%s: %s", formatted_msg, strerror(errno_copy));
    free(formatted_msg);
}

/* Non-static: config.zig's parse_config_file() logs through it. */
void NOINLINE PRINTF(4)
log_and_notify_errno(struct config *conf, const char *file, int lineno,
                     const char *fmt, ...)
{
    va_list va;
    va_start(va, fmt);
    log_and_notify_errno_va(conf, file, lineno, fmt, va);
    va_end(va);
}

/* Non-static: config.zig logs through it. */
void NOINLINE PRINTF(4)
log_contextual_errno(struct context *ctx, const char *file, int lineno,
                     const char *fmt, ...)
{
    va_list va;
    va_start(va, fmt);
    char *formatted_msg = xvasprintf(fmt, va);
    va_end(va);

    bool print_dot = ctx->key != NULL;
    bool print_colon = ctx->value != NULL;

    if (!print_dot)
        ctx->key = "";

    if (!print_colon)
        ctx->value = "";

    log_and_notify_errno(
        ctx->conf, file, lineno, "%s:%d: [%s]%s%s%s%s: %s",
        ctx->path, ctx->lineno, ctx->section, print_dot ? "." : "",
        ctx->key, print_colon ? ": " : "", ctx->value, formatted_msg);

    free(formatted_msg);
}

#define LOG_CONTEXTUAL_ERR(...) \
    log_contextual(ctx, LOG_CLASS_ERROR, __FILE__, __LINE__, __VA_ARGS__)

#define LOG_CONTEXTUAL_WARN(...) \
    log_contextual(ctx, LOG_CLASS_WARNING, __FILE__, __LINE__, __VA_ARGS__)

#define LOG_CONTEXTUAL_ERRNO(...) \
    log_contextual_errno(ctx, __FILE__, __LINE__, __VA_ARGS__)

#define LOG_AND_NOTIFY_ERR(...) \
    log_and_notify(conf, LOG_CLASS_ERROR, __FILE__, __LINE__, __VA_ARGS__)

#define LOG_AND_NOTIFY_WARN(...) \
    log_and_notify(conf, LOG_CLASS_WARNING, __FILE__, __LINE__, __VA_ARGS__)

#define LOG_AND_NOTIFY_ERRNO(...) \
    log_and_notify_errno(conf, __FILE__, __LINE__, __VA_ARGS__)

/* Non-static: config.zig's [main] parser handles `include=`. */
bool parse_config_file(
    FILE *f, struct config *conf, const char *path, bool errors_are_fatal);

/* parse_section_main: ported to config.zig */

/* parse_section_security: ported to config.zig */
/* parse_section_bell: ported to config.zig */
/* parse_section_desktop_notifications: ported to config.zig */
/* parse_section_scrollback: ported to config.zig */
/* [url] and [regex]: ported to config.zig (C2h). regex_t stays here */
/* because glibc and musl disagree on its layout; Zig keeps it opaque. */
extern bool parse_section_url(struct context *ctx);
extern bool parse_section_regex(struct context *ctx);

/* Compile + validate a regex for config.zig. Returns 0 on success, -1 on
 * regcomp() failure (err_buf holds regerror() text), -2 when the pattern
 * has no marked subexpressions (the regex is already freed). */
int
config_regex_compile(const char *regex, regex_t *preg,
                     char *err_buf, size_t err_buf_len)
{
    int r = regcomp(preg, regex, REG_EXTENDED);
    if (r != 0) {
        regerror(r, preg, err_buf, err_buf_len);
        return -1;
    }

    if (preg->re_nsub == 0) {
        regfree(preg);
        return -2;
    }

    return 0;
}

/* parse_color_theme: ported to config.zig */
/* parse_section_colors_dark: ported to config.zig */
/* parse_section_colors_light: ported to config.zig */
/* parse_section_cursor: ported to config.zig */
/* parse_section_mouse: ported to config.zig */
/* parse_section_csd: ported to config.zig */
/*
 * Parses a key binding value in the form
 *  "[cmd-to-exec arg1 arg2] Mods+Key"
 *
 * and extracts 'cmd-to-exec' and its arguments.
 *
 * Input:
 *  - value: raw string, in the form mentioned above
 *  - cmd: pointer to string to will be allocated and filled with
 *        'cmd-to-exec arg1 arg2'
 *  - argv: point to array of string. Array will be allocated. Will be
 *          filled with {'cmd-to-exec', 'arg1', 'arg2', NULL}
 *
 * Returns:
 *  - ssize_t, number of bytes that were stripped from 'value' to remove the '[]'
 *    enclosed cmd and its arguments, including any subsequent
 *    whitespace characters. I.e. if 'value' is "[cmd] BTN_RIGHT", the
 *    return value is 6 (strlen("[cmd] ")).
 *  - cmd: allocated string containing "cmd arg1 arg2...". Caller frees.
 *  - argv: allocated array containing {"cmd", "arg1", "arg2", NULL}. Caller frees.
 */
/* parse_section_environment: ported to config.zig */
/* parse_section_tweak: ported to config.zig */

/* parse_section_touch: ported to config.zig */
/* enum section, section_info[], str_to_section(), parse_key_value() and
 * parse_config_file(): ported to config.zig */

extern char *get_server_socket_path(void);
extern void add_default_key_bindings(struct config *conf);
extern void add_default_search_bindings(struct config *conf);
extern void add_default_url_bindings(struct config *conf);
extern void add_default_mouse_bindings(struct config *conf);

#if 0
xkb_mod_mask_t
conf_modifiers_to_mask(const struct seat *seat,
                       const struct config_key_modifiers *modifiers)
{
    xkb_mod_mask_t mods = 0;
    if (seat->kbd.mod_shift != XKB_MOD_INVALID)
        mods |= modifiers->shift << seat->kbd.mod_shift;
    if (seat->kbd.mod_ctrl != XKB_MOD_INVALID)
        mods |= modifiers->ctrl << seat->kbd.mod_ctrl;
    if (seat->kbd.mod_alt != XKB_MOD_INVALID)
        mods |= modifiers->alt << seat->kbd.mod_alt;
    if (seat->kbd.mod_super != XKB_MOD_INVALID)
        mods |= modifiers->super << seat->kbd.mod_super;
    return mods;
}
#endif


/* fcft_font and fcft_glyph are public structs, but the port only needs one
 * field out of each; exposing them here avoids mirroring ~30 fields of
 * layout (and the ABI probe that would come with it). */
int
config_fcft_glyph_advance_x(const struct fcft_glyph *glyph)
{
    return glyph->advance.x;
}

const char *
config_fcft_font_name(const struct fcft_font *font)
{
    return font->name;
}

