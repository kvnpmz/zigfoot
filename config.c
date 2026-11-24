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

char *
get_shell(void)
{
    const char *shell = getenv("SHELL");

    if (shell == NULL) {
        struct passwd *passwd = getpwuid(getuid());
        if (passwd == NULL) {
            LOG_ERRNO("failed to lookup user: falling back to 'sh'");
            shell = "sh";
        } else
            shell = passwd->pw_shell;
    }

    LOG_DBG("user's shell: %s", shell);
    return xstrdup(shell);
}

/* Non-static: config.zig's [csd] parser calls it. */
struct config_font_list NOINLINE
value_to_fonts(struct context *ctx)
{
    size_t count = 0;
    size_t size = 0;
    struct config_font *fonts = NULL;

    char *copy = xstrdup(ctx->value);
    for (const char *font = strtok(copy, ",");
         font != NULL;
         font = strtok(NULL, ","))
    {
        /* Trim spaces, strictly speaking not necessary, but looks nice :) */
        while (isspace(font[0]))
            font++;

        if (font[0] == '\0')
            continue;

        struct config_font font_data;
        if (!config_font_parse(font, &font_data)) {
            ctx->value = font;
            LOG_CONTEXTUAL_ERR("invalid font specification");
            goto err;
        }

        if (count + 1 > size) {
            size += 4;
            fonts = xrealloc(fonts, size * sizeof(fonts[0]));
        }

        xassert(count + 1 <= size);
        fonts[count++] = font_data;
    }

    free(copy);
    return (struct config_font_list){.arr = fonts, .count = count};

err:
    free(copy);
    free(fonts);
    return (struct config_font_list){.arr = NULL, .count = 0};
}

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

bool
config_font_parse(const char *pattern, struct config_font *font)
{
    FcPattern *pat = FcNameParse((const FcChar8 *)pattern);
    if (pat == NULL)
        return false;

    /*
     * First look for user specified {pixel}size option
     * e.g. "font-name:size=12"
     */

    double pt_size = -1.0;
    FcResult have_pt_size = FcPatternGetDouble(pat, FC_SIZE, 0, &pt_size);

    int px_size = -1;
    FcResult have_px_size = FcPatternGetInteger(pat, FC_PIXEL_SIZE, 0, &px_size);

    if (have_pt_size != FcResultMatch && have_px_size != FcResultMatch) {
        /*
         * Apply fontconfig config. Can't do that until we've first
         * checked for a user provided size, since we may end up with
         * both "size" and "pixelsize" being set, and we don't know
         * which one takes priority.
         */
        FcConfig *fc_conf = FcConfigCreate();
        FcPattern *pat_copy = FcPatternDuplicate(pat);
        if (pat_copy == NULL ||
            !FcConfigSubstitute(fc_conf, pat_copy, FcMatchPattern))
        {
            LOG_WARN("%s: failed to do config substitution", pattern);
        } else {
            have_pt_size = FcPatternGetDouble(pat_copy, FC_SIZE, 0, &pt_size);
            have_px_size = FcPatternGetInteger(pat_copy, FC_PIXEL_SIZE, 0, &px_size);
        }

        FcPatternDestroy(pat_copy);
        FcConfigDestroy(fc_conf);

        if (have_pt_size != FcResultMatch && have_px_size != FcResultMatch)
            pt_size = 8.0;
    }

    FcPatternRemove(pat, FC_SIZE, 0);
    FcPatternRemove(pat, FC_PIXEL_SIZE, 0);

    /* Only the family part, with '\', '-', ':' and ',' \-escaped */
    FcChar8 *escaped_family = FcPatternFormat(
        pat, (const FcChar8 *)"%{+family{%{family|escape(\\\\-:,)}}}");

    /* Everything but the family, size and pixelsize */
    FcChar8 *rest = FcPatternFormat(
        pat, (const FcChar8 *)"%{-family,size,pixelsize{%{=unparse}}}");

    char *stripped_pattern = NULL;
    if (escaped_family == NULL || rest == NULL) {
        free(escaped_family);
        free(rest);
        stripped_pattern = (char *)FcNameUnparse(pat);
    } else {
        stripped_pattern = xasprintf("%s%s", escaped_family, rest);
        free(escaped_family);
        free(rest);
    }

    FcPatternDestroy(pat);

    LOG_DBG("%s: pt-size=%.2f, px-size=%d", stripped_pattern, pt_size, px_size);

    if (stripped_pattern == NULL) {
        LOG_ERR("failed to convert font pattern to string");
        return false;
    }

    *font = (struct config_font){
        .pattern = stripped_pattern,
        .pt_size = pt_size,
        .px_size = px_size
    };
    return true;
}

void
config_font_list_destroy(struct config_font_list *font_list)
{
    for (size_t i = 0; i < font_list->count; i++)
        free(font_list->arr[i].pattern);
    free(font_list->arr);
    font_list->count = 0;
    font_list->arr = NULL;
}


bool
check_if_font_is_monospaced(const char *pattern,
                            user_notifications_t *notifications)
{
    struct fcft_font *f = fcft_from_name(
        1, (const char *[]){pattern}, ":size=8");

    if (f == NULL)
        return true;

    static const char32_t chars[] = {U'a', U'i', U'l', U'M', U'W'};

    bool is_monospaced = true;
    int last_width = -1;

    for (size_t i = 0; i < sizeof(chars) / sizeof(chars[0]); i++) {
        const struct fcft_glyph *g = fcft_rasterize_char_utf32(
            f, chars[i], FCFT_SUBPIXEL_NONE);

        if (g == NULL)
            continue;

        if (last_width >= 0 && g->advance.x != last_width) {
            const char *font_name = f->name != NULL
                ? f->name
                : pattern;

            LOG_WARN("%s: font does not appear to be monospace; "
                     "check your config, or disable this warning by "
                     "setting [tweak].font-monospace-warn=no",
                     font_name);

            static const char fmt[] =
                "%s: font does not appear to be monospace; "
                "check your config, or disable this warning by "
                "setting \033[1m[tweak].font-monospace-warn=no\033[22m";

            user_notification_add_fmt(
                notifications, USER_NOTIFICATION_WARNING, fmt, font_name);

            is_monospaced = false;
            break;
        }

        last_width = g->advance.x;
    }

    fcft_destroy(f);
    return is_monospaced;
}

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


