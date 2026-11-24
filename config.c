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

static const uint32_t default_foreground = 0xffffff;
static const uint32_t default_background = 0x242424;

#define cube6(r, g) \
    r|g|0x00, r|g|0x5f, r|g|0x87, r|g|0xaf, r|g|0xd7, r|g|0xff

#define cube36(r) \
    cube6(r, 0x0000), \
    cube6(r, 0x5f00), \
    cube6(r, 0x8700), \
    cube6(r, 0xaf00), \
    cube6(r, 0xd700), \
    cube6(r, 0xff00)

static const uint32_t default_color_table[256] = {
    // Regular
    0x242424,
    0xf62b5a,
    0x47b413,
    0xe3c401,
    0x24acd4,
    0xf2affd,
    0x13c299,
    0xe6e6e6,

    // Bright
    0x616161,
    0xff4d51,
    0x35d450,
    0xe9e836,
    0x5dc5f8,
    0xfeabf2,
    0x24dfc4,
    0xffffff,

    // 6x6x6 RGB cube
    // (color channels = i ? i*40+55 : 0, where i = 0..5)
    cube36(0x000000),
    cube36(0x5f0000),
    cube36(0x870000),
    cube36(0xaf0000),
    cube36(0xd70000),
    cube36(0xff0000),

    // 24 shades of gray
    // (color channels = i*10+8, where i = 0..23)
    0x080808, 0x121212, 0x1c1c1c, 0x262626,
    0x303030, 0x3a3a3a, 0x444444, 0x4e4e4e,
    0x585858, 0x626262, 0x6c6c6c, 0x767676,
    0x808080, 0x8a8a8a, 0x949494, 0x9e9e9e,
    0xa8a8a8, 0xb2b2b2, 0xbcbcbc, 0xc6c6c6,
    0xd0d0d0, 0xdadada, 0xe4e4e4, 0xeeeeee
};

/* VT330/VT340 Programmer Reference Manual  - Table 2-3 VT340 Default Color Map */
static const uint32_t default_sixel_colors[16] = {
    0xff000000,
    0xff3333cc,
    0xffcc2121,
    0xff33cc33,
    0xffcc33cc,
    0xff33cccc,
    0xffcccc33,
    0xff878787,
    0xff424242,
    0xff545499,
    0xff994242,
    0xff549954,
    0xff995499,
    0xff549999,
    0xff999954,
    0xffcccccc,
};

static const char *const default_url_regex_string =
    "("
        "("
            "(https?://|mailto:|ftp://|file:|ssh:|ssh://|git://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:)"
            "|"
            "www\\."
        ")"
        "("
            /* Safe + reserved + some unsafe characters parenthesis and double quotes omitted (we only allow them when balanced) */
            "[0-9a-zA-Z:/?#@!$&*+,;=.~_%^'\\-]+"
            "|"
             /* Balanced "(...)". Content is same as above, plus all _other_ characters we require to be balanced */
            "\\([]\\[\"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\\)"
            "|"
             /* Balanced "[...]". Content is same as above, plus all _other_ characters we require to be balanced */
            "\\[[\\(\\)\"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\\]"
            "|"
             /* Balanced '"..."'. Content is same as above, plus all _other_ characters we require to be balanced */
            "\"[]\\[\\(\\)0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\""
            "|"
             /* Balanced "'...'". Content is same as above, plus all _other_ characters we require to be balanced */
            "'[]\\[\\(\\)0-9a-zA-Z:/?#@!$&*+,;=.~_%^\\-]+'"
        ")+"
        "("
            /* Same as above, except :?!,;.' are excluded */
            "[0-9a-zA-Z/#@$&*+=~_%^\\-]"
            "|"
             /* Balanced "(...)". Content is same as above, plus all _other_ characters we require to be balanced */
            "\\([]\\[\"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\\)"
            "|"
             /* Balanced "[...]". Content is same as above, plus all _other_ characters we require to be balanced */
            "\\[[\\(\\)\"0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\\]"
            "|"
             /* Balanced '"..."'. Content is same as above, plus all _other_ characters we require to be balanced */
            "\"[]\\[\\(\\)0-9a-zA-Z:/?#@!$&'*+,;=.~_%^\\-]+\""
            "|"
             /* Balanced "'...'". Content is same as above, plus all _other_ characters we require to be balanced */
            "'[]\\[\\(\\)0-9a-zA-Z:/?#@!$&*+,;=.~_%^\\-]+'"
        ")"
    ")";

static const char *const binding_action_map[] = {
    [BIND_ACTION_NONE] = NULL,
    [BIND_ACTION_NOOP] = "noop",
    [BIND_ACTION_SCROLLBACK_UP_PAGE] = "scrollback-up-page",
    [BIND_ACTION_SCROLLBACK_UP_HALF_PAGE] = "scrollback-up-half-page",
    [BIND_ACTION_SCROLLBACK_UP_LINE] = "scrollback-up-line",
    [BIND_ACTION_SCROLLBACK_DOWN_PAGE] = "scrollback-down-page",
    [BIND_ACTION_SCROLLBACK_DOWN_HALF_PAGE] = "scrollback-down-half-page",
    [BIND_ACTION_SCROLLBACK_DOWN_LINE] = "scrollback-down-line",
    [BIND_ACTION_SCROLLBACK_HOME] = "scrollback-home",
    [BIND_ACTION_SCROLLBACK_END] = "scrollback-end",
    [BIND_ACTION_CLIPBOARD_COPY] = "clipboard-copy",
    [BIND_ACTION_CLIPBOARD_PASTE] = "clipboard-paste",
    [BIND_ACTION_PRIMARY_PASTE] = "primary-paste",
    [BIND_ACTION_SEARCH_START] = "search-start",
    [BIND_ACTION_FONT_SIZE_UP] = "font-increase",
    [BIND_ACTION_FONT_SIZE_DOWN] = "font-decrease",
    [BIND_ACTION_FONT_SIZE_RESET] = "font-reset",
    [BIND_ACTION_SPAWN_TERMINAL] = "spawn-terminal",
    [BIND_ACTION_MINIMIZE] = "minimize",
    [BIND_ACTION_MAXIMIZE] = "maximize",
    [BIND_ACTION_FULLSCREEN] = "fullscreen",
    [BIND_ACTION_PIPE_SCROLLBACK] = "pipe-scrollback",
    [BIND_ACTION_PIPE_VIEW] = "pipe-visible",
    [BIND_ACTION_PIPE_SELECTED] = "pipe-selected",
    [BIND_ACTION_PIPE_COMMAND_OUTPUT] = "pipe-command-output",
    [BIND_ACTION_SHOW_URLS_COPY] = "show-urls-copy",
    [BIND_ACTION_SHOW_URLS_LAUNCH] = "show-urls-launch",
    [BIND_ACTION_SHOW_URLS_PERSISTENT] = "show-urls-persistent",
    [BIND_ACTION_TEXT_BINDING] = "text-binding",
    [BIND_ACTION_PROMPT_PREV] = "prompt-prev",
    [BIND_ACTION_PROMPT_NEXT] = "prompt-next",
    [BIND_ACTION_UNICODE_INPUT] = "unicode-input",
    [BIND_ACTION_QUIT] = "quit",
    [BIND_ACTION_REGEX_LAUNCH] = "regex-launch",
    [BIND_ACTION_REGEX_COPY] = "regex-copy",
    [BIND_ACTION_THEME_SWITCH_DARK] = "color-theme-switch-dark",
    [BIND_ACTION_THEME_SWITCH_LIGHT] = "color-theme-switch-light",
    [BIND_ACTION_THEME_TOGGLE] = "color-theme-toggle",

    /* Mouse-specific actions */
    [BIND_ACTION_SCROLLBACK_UP_MOUSE] = "scrollback-up-mouse",
    [BIND_ACTION_SCROLLBACK_DOWN_MOUSE] = "scrollback-down-mouse",
    [BIND_ACTION_SELECT_BEGIN] = "select-begin",
    [BIND_ACTION_SELECT_BEGIN_BLOCK] = "select-begin-block",
    [BIND_ACTION_SELECT_EXTEND] = "select-extend",
    [BIND_ACTION_SELECT_EXTEND_CHAR_WISE] = "select-extend-character-wise",
    [BIND_ACTION_SELECT_WORD] = "select-word",
    [BIND_ACTION_SELECT_WORD_WS] = "select-word-whitespace",
    [BIND_ACTION_SELECT_QUOTE] = "select-quote",
    [BIND_ACTION_SELECT_ROW] = "select-row",
};

static const char *const search_binding_action_map[] = {
    [BIND_ACTION_SEARCH_NONE] = NULL,
    [BIND_ACTION_SEARCH_SCROLLBACK_UP_PAGE] = "scrollback-up-page",
    [BIND_ACTION_SEARCH_SCROLLBACK_UP_HALF_PAGE] = "scrollback-up-half-page",
    [BIND_ACTION_SEARCH_SCROLLBACK_UP_LINE] = "scrollback-up-line",
    [BIND_ACTION_SEARCH_SCROLLBACK_DOWN_PAGE] = "scrollback-down-page",
    [BIND_ACTION_SEARCH_SCROLLBACK_DOWN_HALF_PAGE] = "scrollback-down-half-page",
    [BIND_ACTION_SEARCH_SCROLLBACK_DOWN_LINE] = "scrollback-down-line",
    [BIND_ACTION_SEARCH_SCROLLBACK_HOME] = "scrollback-home",
    [BIND_ACTION_SEARCH_SCROLLBACK_END] = "scrollback-end",
    [BIND_ACTION_SEARCH_CANCEL] = "cancel",
    [BIND_ACTION_SEARCH_COMMIT] = "commit",
    [BIND_ACTION_SEARCH_FIND_PREV] = "find-prev",
    [BIND_ACTION_SEARCH_FIND_NEXT] = "find-next",
    [BIND_ACTION_SEARCH_EDIT_LEFT] = "cursor-left",
    [BIND_ACTION_SEARCH_EDIT_LEFT_WORD] = "cursor-left-word",
    [BIND_ACTION_SEARCH_EDIT_RIGHT] = "cursor-right",
    [BIND_ACTION_SEARCH_EDIT_RIGHT_WORD] = "cursor-right-word",
    [BIND_ACTION_SEARCH_EDIT_HOME] = "cursor-home",
    [BIND_ACTION_SEARCH_EDIT_END] = "cursor-end",
    [BIND_ACTION_SEARCH_DELETE_PREV] = "delete-prev",
    [BIND_ACTION_SEARCH_DELETE_PREV_WORD] = "delete-prev-word",
    [BIND_ACTION_SEARCH_DELETE_NEXT] = "delete-next",
    [BIND_ACTION_SEARCH_DELETE_NEXT_WORD] = "delete-next-word",
    [BIND_ACTION_SEARCH_DELETE_TO_START] = "delete-to-start",
    [BIND_ACTION_SEARCH_DELETE_TO_END] = "delete-to-end",
    [BIND_ACTION_SEARCH_EXTEND_CHAR] = "extend-char",
    [BIND_ACTION_SEARCH_EXTEND_WORD] = "extend-to-word-boundary",
    [BIND_ACTION_SEARCH_EXTEND_WORD_WS] = "extend-to-next-whitespace",
    [BIND_ACTION_SEARCH_EXTEND_LINE_DOWN] = "extend-line-down",
    [BIND_ACTION_SEARCH_EXTEND_BACKWARD_CHAR] = "extend-backward-char",
    [BIND_ACTION_SEARCH_EXTEND_BACKWARD_WORD] = "extend-backward-to-word-boundary",
    [BIND_ACTION_SEARCH_EXTEND_BACKWARD_WORD_WS] = "extend-backward-to-next-whitespace",
    [BIND_ACTION_SEARCH_EXTEND_LINE_UP] = "extend-line-up",
    [BIND_ACTION_SEARCH_CLIPBOARD_PASTE] = "clipboard-paste",
    [BIND_ACTION_SEARCH_PRIMARY_PASTE] = "primary-paste",
    [BIND_ACTION_SEARCH_UNICODE_INPUT] = "unicode-input",
};

static const char *const url_binding_action_map[] = {
    [BIND_ACTION_URL_NONE] = NULL,
    [BIND_ACTION_URL_CANCEL] = "cancel",
    [BIND_ACTION_URL_TOGGLE_URL_ON_JUMP_LABEL] = "toggle-url-visible",
};

static_assert(ALEN(binding_action_map) == BIND_ACTION_COUNT,
              "binding action map size mismatch");
static_assert(ALEN(search_binding_action_map) == BIND_ACTION_SEARCH_COUNT,
              "search binding action map size mismatch");
static_assert(ALEN(url_binding_action_map) == BIND_ACTION_URL_COUNT,
              "URL binding action map size mismatch");

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

static void NOINLINE PRINTF(5)
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

static char *
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

struct config_file {
    char *path;       /* Full, absolute, path */
    int fd;           /* FD of file, O_RDONLY */
};

static struct config_file
open_config(void)
{
    char *path = NULL;
    struct config_file ret = {.path = NULL, .fd = -1};

    const char *xdg_config_home = getenv("XDG_CONFIG_HOME");
    const char *xdg_config_dirs = getenv("XDG_CONFIG_DIRS");
    const char *home_dir = getenv("HOME");
    char *xdg_config_dirs_copy = NULL;

    /* First, check XDG_CONFIG_HOME (or .config, if unset) */
    if (xdg_config_home != NULL && xdg_config_home[0] != '\0')
        path = xstrjoin(xdg_config_home, "/foot/foot.ini");
    else if (home_dir != NULL)
        path = xstrjoin(home_dir, "/.config/foot/foot.ini");

    if (path != NULL) {
        LOG_DBG("checking for %s", path);
        int fd = open(path, O_RDONLY | O_CLOEXEC);

        if (fd >= 0) {
            ret = (struct config_file) {.path = path, .fd = fd};
            path = NULL;
            goto done;
        }
    }

    xdg_config_dirs_copy = xdg_config_dirs != NULL && xdg_config_dirs[0] != '\0'
        ? strdup(xdg_config_dirs)
        : strdup("/etc/xdg");

    if (xdg_config_dirs_copy == NULL || xdg_config_dirs_copy[0] == '\0')
        goto done;

    for (const char *conf_dir = strtok(xdg_config_dirs_copy, ":");
         conf_dir != NULL;
         conf_dir = strtok(NULL, ":"))
    {
        free(path);
        path = xstrjoin(conf_dir, "/foot/foot.ini");

        LOG_DBG("checking for %s", path);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            ret = (struct config_file){.path = path, .fd = fd};
            path = NULL;
            goto done;
        }
    }

done:
    free(xdg_config_dirs_copy);
    free(path);
    return ret;
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
static void
free_binding_aux(struct binding_aux *aux)
{
    if (!aux->master_copy)
        return;

    switch (aux->type) {
    case BINDING_AUX_NONE: break;
    case BINDING_AUX_PIPE: free_argv(&aux->pipe); break;
    case BINDING_AUX_TEXT: free(aux->text.data); break;
    case BINDING_AUX_REGEX: free(aux->regex_name); break;
    }
}

static void
free_key_binding(struct config_key_binding *binding)
{
    free_binding_aux(&binding->aux);
    tll_free_and_free(binding->modifiers, free);
}

static void NOINLINE
free_key_binding_list(struct config_key_binding_list *bindings)
{
    struct config_key_binding *binding = &bindings->arr[0];

    for (size_t i = 0; i < bindings->count; i++, binding++)
        free_key_binding(binding);
    free(bindings->arr);

    bindings->arr = NULL;
    bindings->count = 0;
}

static void NOINLINE
parse_modifiers(const char *text, size_t len, config_modifier_list_t *modifiers)
{
    tll_free_and_free(*modifiers, free);

    /* Handle "none" separately because e.g. none+shift is nonsense */
    if (strncmp(text, "none", len) == 0)
        return;

    char *copy = xstrndup(text, len);

    for (char *ctx = NULL, *key = strtok_r(copy, "+", &ctx);
         key != NULL;
         key = strtok_r(NULL, "+", &ctx))
    {
        tll_push_back(*modifiers, xstrdup(key));
    }

    free(copy);
    tll_sort(*modifiers, strcmp);
}

static int NOINLINE
argv_compare(const struct argv *argv1, const struct argv *argv2)
{
    if (argv1->args == NULL && argv2->args == NULL)
        return 0;

    if (argv1->args == NULL)
        return -1;
    if (argv2->args == NULL)
        return 1;

    for (size_t i = 0; ; i++) {
        if (argv1->args[i] == NULL && argv2->args[i] == NULL)
            return 0;
        if (argv1->args[i] == NULL)
            return -1;
        if (argv2->args[i] == NULL)
            return 1;

        int ret = strcmp(argv1->args[i], argv2->args[i]);
        if (ret != 0)
            return ret;
    }

    BUG("unexpected loop break");
    return 1;
}

static bool NOINLINE
binding_aux_equal(const struct binding_aux *a,
                  const struct binding_aux *b)
{
    if (a->type != b->type)
        return false;

    switch (a->type) {
    case BINDING_AUX_NONE:
        return true;

    case BINDING_AUX_PIPE:
        return argv_compare(&a->pipe, &b->pipe) == 0;

    case BINDING_AUX_TEXT:
        return a->text.len == b->text.len &&
               memcmp(a->text.data, b->text.data, a->text.len) == 0;

    case BINDING_AUX_REGEX:
        return streq(a->regex_name, b->regex_name);
    }

    BUG("invalid AUX type: %d", a->type);
    return false;
}

static void NOINLINE
remove_from_key_bindings_list(struct config_key_binding_list *bindings,
                              int action, const struct binding_aux *aux)
{
    size_t remove_first_idx = 0;
    size_t remove_count = 0;

    for (size_t i = 0; i < bindings->count; i++) {
        struct config_key_binding *binding = &bindings->arr[i];

        if (binding->action != action)
            continue;

        if (binding_aux_equal(&binding->aux, aux)) {
            if (remove_count++ == 0)
                remove_first_idx = i;

            xassert(remove_first_idx + remove_count - 1 == i);
            free_key_binding(binding);
        }
    }

    if (remove_count == 0)
        return;

    size_t move_count = bindings->count - (remove_first_idx + remove_count);

    memmove(
        &bindings->arr[remove_first_idx],
        &bindings->arr[remove_first_idx + remove_count],
        move_count * sizeof(bindings->arr[0]));
    bindings->count -= remove_count;
}

static const struct {
    const char *name;
    int code;
} button_map[] = {
    /* System defined */
    {"BTN_LEFT", BTN_LEFT},
    {"BTN_RIGHT", BTN_RIGHT},
    {"BTN_MIDDLE", BTN_MIDDLE},
    {"BTN_SIDE", BTN_SIDE},
    {"BTN_EXTRA", BTN_EXTRA},
    {"BTN_FORWARD", BTN_FORWARD},
    {"BTN_BACK", BTN_BACK},
    {"BTN_TASK", BTN_TASK},

    /* Foot custom, to be able to map scroll events to mouse bindings */
    {"BTN_WHEEL_BACK", BTN_WHEEL_BACK},
    {"BTN_WHEEL_FORWARD", BTN_WHEEL_FORWARD},
    {"BTN_WHEEL_LEFT", BTN_WHEEL_LEFT},
    {"BTN_WHEEL_RIGHT", BTN_WHEEL_RIGHT},
};

static int
mouse_button_name_to_code(const char *name)
{
    for (size_t i = 0; i < ALEN(button_map); i++) {
        if (streq(button_map[i].name, name))
            return button_map[i].code;
    }
    return -1;
}

static const char*
mouse_button_code_to_name(int code)
{
    for (size_t i = 0; i < ALEN(button_map); i++) {
        if (code == button_map[i].code)
            return button_map[i].name;
    }

    return NULL;
}

static bool NOINLINE
value_to_key_combos(struct context *ctx, int action,
                    struct binding_aux *aux,
                    struct config_key_binding_list *bindings,
                    enum key_binding_type type)
{
    if (strcasecmp(ctx->value, "none") == 0) {
        remove_from_key_bindings_list(bindings, action, aux);
        return true;
    }

    /* Count number of combinations */
    size_t combo_count = 1;
    size_t used_combos = 1;  /* For error handling */
    for (const char *p = strchr(ctx->value, ' ');
         p != NULL;
         p = strchr(p + 1, ' '))
    {
        combo_count++;
    }

    struct config_key_binding new_combos[combo_count];

    char *copy = xstrdup(ctx->value);
    size_t idx = 0;

    for (char *tok_ctx = NULL, *combo = strtok_r(copy, " ", &tok_ctx);
         combo != NULL;
         combo = strtok_r(NULL, " ", &tok_ctx),
             idx++, used_combos++)
    {
        struct config_key_binding *new_combo = &new_combos[idx];
        new_combo->action = action;
        new_combo->aux = *aux;
        new_combo->aux.master_copy = idx == 0;
#if 0
        new_combo->aux.type = BINDING_AUX_PIPE;
        new_combo->aux.master_copy = idx == 0;
        new_combo->aux.pipe = *argv;
#endif
        memset(&new_combo->modifiers, 0, sizeof(new_combo->modifiers));
        new_combo->path = ctx->path;
        new_combo->lineno = ctx->lineno;

        char *key = strrchr(combo, '+');

        if (key == NULL) {
            /* No modifiers */
            key = combo;
        } else {
            *key = '\0';
            parse_modifiers(combo, key - combo, &new_combo->modifiers);
            key++;  /* Skip past the '+' */
        }

        switch (type) {
        case KEY_BINDING:
            /* Translate key name to symbol */
            new_combo->k.sym = xkb_keysym_from_name(key, 0);
            if (new_combo->k.sym == XKB_KEY_NoSymbol) {
                LOG_CONTEXTUAL_ERR("not a valid XKB key name: %s", key);
                goto err;
            }
            break;

        case MOUSE_BINDING: {
            new_combo->m.count = 1;

            char *_count = strrchr(key, '-');
            if (_count != NULL) {
                *_count = '\0';
                _count++;

                errno = 0;
                char *end;
                unsigned long value = strtoul(_count, &end, 10);
                if (_count[0] == '\0' || *end != '\0' || errno != 0) {
                    if (errno != 0)
                        LOG_CONTEXTUAL_ERRNO("invalid click count: %s", _count);
                    else
                        LOG_CONTEXTUAL_ERR("invalid click count: %s", _count);
                    goto err;
                }

                new_combo->m.count = value;
            }

            new_combo->m.button = mouse_button_name_to_code(key);
            if (new_combo->m.button < 0) {
                LOG_CONTEXTUAL_ERR("invalid mouse button name: %s", key);
                goto err;
            }

            break;
        }
        }

    }

    if (idx == 0) {
        LOG_CONTEXTUAL_ERR(
            "empty binding not allowed (set to 'none' to unmap)");
        free(copy);
        return false;
    }

    remove_from_key_bindings_list(bindings, action, aux);

    bindings->arr = xrealloc(
        bindings->arr,
        (bindings->count + combo_count) * sizeof(bindings->arr[0]));

    memcpy(&bindings->arr[bindings->count],
           new_combos,
           combo_count * sizeof(bindings->arr[0]));
    bindings->count += combo_count;

    free(copy);
    return true;

err:
    for (size_t i = 0; i < used_combos; i++)
        free_key_binding(&new_combos[i]);
    free(copy);
    return false;
}

static bool
modifiers_equal(const config_modifier_list_t *mods1,
                const config_modifier_list_t *mods2)
{
    if (tll_length(*mods1) != tll_length(*mods2))
        return false;

    size_t count = 0;
    tll_foreach(*mods1, it1) {
        size_t skip = count;
        tll_foreach(*mods2, it2) {
            if (skip > 0) {
                skip--;
                continue;
            }

            if (strcmp(it1->item, it2->item) != 0)
                return false;
            break;
        }

        count++;
    }

    return true;
    /*
     * bool shift = mods1->shift == mods2->shift;
     * bool alt = mods1->alt == mods2->alt;
     * bool ctrl = mods1->ctrl == mods2->ctrl;
     * bool super = mods1->super == mods2->super;
     * return shift && alt && ctrl && super;
     */
}

UNITTEST
{
    config_modifier_list_t mods1 = tll_init();
    config_modifier_list_t mods2 = tll_init();

    tll_push_back(mods1, xstrdup("foo"));
    tll_push_back(mods1, xstrdup("bar"));

    tll_push_back(mods2, xstrdup("foo"));
    xassert(!modifiers_equal(&mods1, &mods2));

    tll_push_back(mods2, xstrdup("zoo"));
    xassert(!modifiers_equal(&mods1, &mods2));

    free(tll_pop_back(mods2));
    tll_push_back(mods2, xstrdup("bar"));
    xassert(modifiers_equal(&mods1, &mods2));

    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);
}

static bool
modifiers_disjoint(const config_modifier_list_t *mods1,
                   const config_modifier_list_t *mods2)
{
    size_t count = 0;
    tll_foreach(*mods1, it1) {
        /*
         * Both sets are sorted. Thus, if we're still here in
         * iteration 2..N, then we can skip the first x items in set
         * #2; we've already checked them against the previous items
         * in set #1.
         */
        size_t skip = count;
        tll_foreach(*mods2, it2) {

            if (skip > 0) {
                --skip;
                continue;
            }

            int r = strcmp(it1->item, it2->item);
            if (r == 0)
                return false;
            if (r < 0)
                break;

            ++count;
        }
    }
    return true;
}

UNITTEST
{
    config_modifier_list_t mods1 = tll_init();
    config_modifier_list_t mods2 = tll_init();

    /* Both empty counts as disjoint */
    xassert(modifiers_disjoint(&mods1, &mods2));

    /* Second set being empty means it's disjoint with the first, non-empty set */
    tll_push_back(mods1, xstrdup("foo"));
    tll_push_back(mods1, xstrdup("bar"));
    tll_sort(mods1, strcmp);
    tll_sort(mods2, strcmp);
    xassert(modifiers_disjoint(&mods1, &mods2));
    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);

    /* "foo" in both sets -> not disjoint */
    tll_push_back(mods1, xstrdup("foo"));
    tll_push_back(mods1, xstrdup("bar"));
    tll_push_back(mods2, xstrdup("foo"));
    tll_sort(mods1, strcmp);
    tll_sort(mods2, strcmp);
    xassert(!modifiers_disjoint(&mods1, &mods2));
    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);

    /* "bar in both sets -> not disjoint */
    tll_push_back(mods1, xstrdup("foo"));
    tll_push_back(mods1, xstrdup("bar"));
    tll_push_back(mods2, xstrdup("bar"));
    tll_sort(mods1, strcmp);
    tll_sort(mods2, strcmp);
    xassert(!modifiers_disjoint(&mods1, &mods2));
    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);

    /* "foo" and "bar" in both sets -> not disjoint */
    tll_push_back(mods1, xstrdup("foo"));
    tll_push_back(mods1, xstrdup("bar"));
    tll_push_back(mods2, xstrdup("foo"));
    tll_push_back(mods2, xstrdup("bar"));
    tll_sort(mods1, strcmp);
    tll_sort(mods2, strcmp);
    xassert(!modifiers_disjoint(&mods1, &mods2));
    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);

    /*
     * Disjoint, with set #2 sorting most of it's items before the
     * items in set #1. This tests the count/skip optimization in
     * modifiers_disjoint().
     */
    tll_push_back(mods1, xstrdup("ddd"));
    tll_push_back(mods1, xstrdup("eee"));
    tll_push_back(mods1, xstrdup("fff"));
    tll_push_back(mods2, xstrdup("aaa"));
    tll_push_back(mods2, xstrdup("bbb"));
    tll_push_back(mods2, xstrdup("ccc"));
    tll_push_back(mods2, xstrdup("ggg"));
    tll_sort(mods1, strcmp);
    tll_sort(mods2, strcmp);
    xassert(modifiers_disjoint(&mods1, &mods2));
    tll_free_and_free(mods1, free);
    tll_free_and_free(mods2, free);
}

static char * NOINLINE
modifiers_to_str(const config_modifier_list_t *mods, bool strip_last_plus)
{
    size_t len = tll_length(*mods);  /* '+' separator */
    tll_foreach(*mods, it)
        len += strlen(it->item);

    char *ret = xmalloc(len + 1);
    size_t idx = 0;
    tll_foreach(*mods, it) {
        idx += snprintf(&ret[idx], len - idx, "%s", it->item);
        ret[idx++] = '+';
    }

    if (strip_last_plus)
        idx--;

    ret[idx] = '\0';
    return ret;
}

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
static ssize_t NOINLINE
pipe_argv_from_value(struct context *ctx, struct argv *argv)
{
    argv->args = NULL;

    if (ctx->value[0] != '[')
        return 0;

    const char *pipe_cmd_end = strrchr(ctx->value, ']');
    if (pipe_cmd_end == NULL) {
        LOG_CONTEXTUAL_ERR("unclosed '['");
        return -1;
    }

    size_t pipe_len = pipe_cmd_end - ctx->value - 1;
    char *cmd = xstrndup(&ctx->value[1], pipe_len);

    if (!tokenize_cmdline(cmd, &argv->args)) {
        LOG_CONTEXTUAL_ERR("syntax error in command line");
        free(cmd);
        return -1;
    }

    ssize_t remove_len = pipe_cmd_end + 1 - ctx->value;
    ctx->value = pipe_cmd_end + 1;
    while (isspace(*ctx->value)) {
        ctx->value++;
        remove_len++;
    }

    free(cmd);
    return remove_len;
}

static ssize_t NOINLINE
regex_name_from_value(struct context *ctx, char **regex_name)
{
    *regex_name = NULL;

    if (ctx->value[0] != '[')
        return 0;

    const char *regex_end = strrchr(ctx->value, ']');
    if (regex_end == NULL) {
        LOG_CONTEXTUAL_ERR("unclosed '['");
        return -1;
    }

    size_t regex_len = regex_end - ctx->value - 1;
    *regex_name = xstrndup(&ctx->value[1], regex_len);

    ssize_t remove_len = regex_end + 1 - ctx->value;
    ctx->value = regex_end + 1;
    while (isspace(*ctx->value)) {
        ctx->value++;
        remove_len++;
    }

    return remove_len;
}


static bool NOINLINE
parse_key_binding_section(struct context *ctx,
                          int action_count,
                          const char *const action_map[static action_count],
                          struct config_key_binding_list *bindings)
{
    for (int action = 0; action < action_count; action++) {
        if (action_map[action] == NULL)
            continue;

        if (!streq(ctx->key, action_map[action]))
            continue;

        struct binding_aux aux = {.type = BINDING_AUX_NONE, .master_copy = true};

        /* TODO: this is ugly... */
        if (action_map == binding_action_map &&
            action >= BIND_ACTION_PIPE_SCROLLBACK &&
            action <= BIND_ACTION_PIPE_COMMAND_OUTPUT)
        {
            ssize_t pipe_remove_len = pipe_argv_from_value(ctx, &aux.pipe);
            if (pipe_remove_len <= 0)
                return false;

            aux.type = BINDING_AUX_PIPE;
            aux.master_copy = true;
        } else if (action_map == binding_action_map &&
                   action >= BIND_ACTION_REGEX_LAUNCH &&
                   action <= BIND_ACTION_REGEX_COPY)
        {
            char *regex_name = NULL;
            ssize_t regex_remove_len = regex_name_from_value(ctx, &regex_name);
            if (regex_remove_len <= 0)
                return false;

            aux.type = BINDING_AUX_REGEX;
            aux.master_copy = true;
            aux.regex_name = regex_name;
        }

        if (!value_to_key_combos(ctx, action, &aux, bindings, KEY_BINDING)) {
            free_binding_aux(&aux);
            return false;
        }

        return true;
    }

    LOG_CONTEXTUAL_ERR("not a valid action: %s", ctx->key);
    return false;
}

UNITTEST
{
    enum test_actions {
        TEST_ACTION_NONE,
        TEST_ACTION_FOO,
        TEST_ACTION_BAR,
        TEST_ACTION_COUNT,
    };

    const char *const map[] = {
        [TEST_ACTION_NONE] = NULL,
        [TEST_ACTION_FOO] = "foo",
        [TEST_ACTION_BAR] = "bar",
    };

    struct config conf = {0};
    struct config_key_binding_list bindings = {0};

    struct context ctx = {
        .conf = &conf,
        .section = "",
        .key = "foo",
        .value = "Escape",
        .path = "",
    };

    /*
     * ADD foo=Escape
     *
     * This verifies we can bind a single key combo to an action.
     */
    xassert(parse_key_binding_section(&ctx, ALEN(map), map, &bindings));
    xassert(bindings.count == 1);
    xassert(bindings.arr[0].action == TEST_ACTION_FOO);
    xassert(bindings.arr[0].k.sym == XKB_KEY_Escape);

    /*
     * ADD bar=Control+g Control+Shift+x
     *
     * This verifies we can bind multiple key combos to an action.
     */
    ctx.key = "bar";
    ctx.value = "Control+g Control+Shift+x";
    xassert(parse_key_binding_section(&ctx, ALEN(map), map, &bindings));
    xassert(bindings.count == 3);
    xassert(bindings.arr[0].action == TEST_ACTION_FOO);
    xassert(bindings.arr[1].action == TEST_ACTION_BAR);
    xassert(bindings.arr[1].k.sym == XKB_KEY_g);
    xassert(tll_length(bindings.arr[1].modifiers) == 1);
    xassert(strcmp(tll_front(bindings.arr[1].modifiers), XKB_MOD_NAME_CTRL) == 0);
    xassert(bindings.arr[2].action == TEST_ACTION_BAR);
    xassert(bindings.arr[2].k.sym == XKB_KEY_x);
    xassert(tll_length(bindings.arr[2].modifiers) == 2);
    xassert(strcmp(tll_front(bindings.arr[2].modifiers), XKB_MOD_NAME_CTRL) == 0);
    xassert(strcmp(tll_back(bindings.arr[2].modifiers), XKB_MOD_NAME_SHIFT) == 0);

    /*
     * REPLACE foo with foo=Mod+v Shift+q
     *
     * This verifies we can update a single-combo action with multiple
     * key combos.
     */
    ctx.key = "foo";
    ctx.value = "Mod1+v Shift+q";
    xassert(parse_key_binding_section(&ctx, ALEN(map), map, &bindings));
    xassert(bindings.count == 4);
    xassert(bindings.arr[0].action == TEST_ACTION_BAR);
    xassert(bindings.arr[1].action == TEST_ACTION_BAR);
    xassert(bindings.arr[2].action == TEST_ACTION_FOO);
    xassert(bindings.arr[2].k.sym == XKB_KEY_v);
    xassert(tll_length(bindings.arr[2].modifiers) == 1);
    xassert(strcmp(tll_front(bindings.arr[2].modifiers), XKB_MOD_NAME_ALT) == 0);
    xassert(bindings.arr[3].action == TEST_ACTION_FOO);
    xassert(bindings.arr[3].k.sym == XKB_KEY_q);
    xassert(tll_length(bindings.arr[3].modifiers) == 1);
    xassert(strcmp(tll_front(bindings.arr[3].modifiers), XKB_MOD_NAME_SHIFT) == 0);

    /*
     * REMOVE bar
     */
    ctx.key = "bar";
    ctx.value = "none";
    xassert(parse_key_binding_section(&ctx, ALEN(map), map, &bindings));
    xassert(bindings.count == 2);
    xassert(bindings.arr[0].action == TEST_ACTION_FOO);
    xassert(bindings.arr[1].action == TEST_ACTION_FOO);

    /*
     * REMOVE foo
     */
    ctx.key = "foo";
    ctx.value = "none";
    xassert(parse_key_binding_section(&ctx, ALEN(map), map, &bindings));
    xassert(bindings.count == 0);

    free(bindings.arr);
}

bool
parse_section_key_bindings(struct context *ctx)
{
    return parse_key_binding_section(
        ctx,
        BIND_ACTION_KEY_COUNT, binding_action_map,
        &ctx->conf->bindings.key);
}

bool
parse_section_search_bindings(struct context *ctx)
{
    return parse_key_binding_section(
        ctx,
        BIND_ACTION_SEARCH_COUNT, search_binding_action_map,
        &ctx->conf->bindings.search);
}

bool
parse_section_url_bindings(struct context *ctx)
{
    return parse_key_binding_section(
        ctx,
        BIND_ACTION_URL_COUNT, url_binding_action_map,
        &ctx->conf->bindings.url);
}

static bool NOINLINE
resolve_key_binding_collisions(struct config *conf, const char *section_name,
                               const char *const action_map[],
                               struct config_key_binding_list *bindings,
                               enum key_binding_type type)
{
    bool ret = true;

    for (size_t i = 1; i < bindings->count; i++) {
        enum {COLLISION_NONE,
            COLLISION_OVERRIDE,
            COLLISION_BINDING} collision_type = COLLISION_NONE;
        const struct config_key_binding *collision_binding = NULL;

        struct config_key_binding *binding1 = &bindings->arr[i];
        xassert(binding1->action != BIND_ACTION_NONE);

        const config_modifier_list_t *mods1 = &binding1->modifiers;

        /* Does our modifiers collide with the selection override mods? */
        if (type == MOUSE_BINDING &&
            !modifiers_disjoint(
                mods1, &conf->mouse.selection_override_modifiers))
        {
            collision_type = COLLISION_OVERRIDE;
        }

        /* Does our binding collide with another binding? */
        for (ssize_t j = i - 1;
             collision_type == COLLISION_NONE && j >= 0;
             j--)
        {
            const struct config_key_binding *binding2 = &bindings->arr[j];
            xassert(binding2->action != BIND_ACTION_NONE);

            if (binding2->action == binding1->action &&
                binding_aux_equal(&binding1->aux, &binding2->aux))
            {
                continue;
            }

            const config_modifier_list_t *mods2 = &binding2->modifiers;

            bool mods_equal = modifiers_equal(mods1, mods2);
            bool sym_equal;

            switch (type) {
            case KEY_BINDING:
                sym_equal = binding1->k.sym == binding2->k.sym;
                break;

            case MOUSE_BINDING:
                sym_equal = (binding1->m.button == binding2->m.button &&
                             binding1->m.count == binding2->m.count);
                break;

            default:
                BUG("unhandled key binding type");
            }

            if (!mods_equal || !sym_equal)
                continue;

            collision_binding = binding2;
            collision_type = COLLISION_BINDING;
            break;
        }

        if (collision_type != COLLISION_NONE) {
            char *modifier_names = modifiers_to_str(mods1, false);
            char sym_name[64];

            switch (type){
            case KEY_BINDING:
                xkb_keysym_get_name(binding1->k.sym, sym_name, sizeof(sym_name));
                break;

            case MOUSE_BINDING: {
                const char *button_name =
                    mouse_button_code_to_name(binding1->m.button);

                if (binding1->m.count > 1) {
                    snprintf(sym_name, sizeof(sym_name), "%s-%d",
                             button_name, binding1->m.count);
                } else
                    strcpy(sym_name, button_name);
                break;
            }
            }

            switch (collision_type) {
            case COLLISION_NONE:
                break;

            case COLLISION_BINDING: {
                bool has_pipe = collision_binding->aux.type == BINDING_AUX_PIPE;
                LOG_AND_NOTIFY_ERR(
                    "%s:%d: [%s].%s: %s%s already mapped to '%s%s%s%s'",
                    binding1->path, binding1->lineno, section_name,
                    action_map[binding1->action],
                    modifier_names, sym_name,
                    action_map[collision_binding->action],
                    has_pipe ? " [" : "",
                    has_pipe ? collision_binding->aux.pipe.args[0] : "",
                    has_pipe ? "]" : "");
                ret = false;
                break;
            }

            case COLLISION_OVERRIDE: {
                char *override_names = modifiers_to_str(
                    &conf->mouse.selection_override_modifiers, true);

                LOG_AND_NOTIFY_ERR(
                    "%s:%d: [%s].%s: %s%s: "
                    "modifiers conflict with 'selection-override-modifiers=%s'",
                    binding1->path != NULL ? binding1->path : "(default)",
                    binding1->lineno, section_name,
                    action_map[binding1->action],
                    modifier_names, sym_name, override_names);
                ret = false;
                free(override_names);
                break;
            }
            }

            free(modifier_names);

            if (binding1->aux.master_copy && i + 1 < bindings->count) {
                struct config_key_binding *next = &bindings->arr[i + 1];

                if (next->action == binding1->action &&
                    binding_aux_equal(&binding1->aux, &next->aux))
                {
                    /* Transfer ownership to next binding */
                    next->aux.master_copy = true;
                    binding1->aux.master_copy = false;
                }
            }

            free_key_binding(binding1);

            /* Remove the most recent binding */
            size_t move_count = bindings->count - (i + 1);
            memmove(&bindings->arr[i], &bindings->arr[i + 1],
                    move_count * sizeof(bindings->arr[0]));
            bindings->count--;

            i--;
        }
    }

    return ret;
}

bool
parse_section_mouse_bindings(struct context *ctx)
{
    struct config *conf = ctx->conf;
    const char *key = ctx->key;
    const char *value = ctx->value;

    if (streq(key, "selection-override-modifiers")) {
        parse_modifiers(
            ctx->value, strlen(value),
            &conf->mouse.selection_override_modifiers);
        return true;
    }

    struct binding_aux aux;

    ssize_t pipe_remove_len = pipe_argv_from_value(ctx, &aux.pipe);
    if (pipe_remove_len < 0)
        return false;

    aux.type = pipe_remove_len == 0 ? BINDING_AUX_NONE : BINDING_AUX_PIPE;
    aux.master_copy = true;

    for (enum bind_action_normal action = 0;
         action < BIND_ACTION_COUNT;
         action++)
    {
        if (binding_action_map[action] == NULL)
            continue;

        if (!streq(key, binding_action_map[action]))
            continue;

        if (!value_to_key_combos(
                ctx, action, &aux, &conf->bindings.mouse, MOUSE_BINDING))
        {
            free_binding_aux(&aux);
            return false;
        }

        return true;
    }

    LOG_CONTEXTUAL_ERR("not a valid option: %s", key);
    free_binding_aux(&aux);
    return false;
}

bool
parse_section_text_bindings(struct context *ctx)
{
    struct config *conf = ctx->conf;
    const char *key = ctx->key;

    const size_t key_len = strlen(key);

    uint8_t *data = xmalloc(key_len + 1);
    size_t data_len = 0;
    bool esc = false;

    for (size_t i = 0; i < key_len; i++) {
        if (key[i] == '\\') {
            if (i + 1 >= key_len) {
                ctx->value = "";
                LOG_CONTEXTUAL_ERR("trailing backslash");
                goto err;
            }

            esc = true;
        }

        else if (esc) {
            if (key[i] != 'x') {
                ctx->value = "";
                LOG_CONTEXTUAL_ERR("invalid escaped character: %c", key[i]);
                goto err;
            }
            if (i + 2 >= key_len) {
                ctx->value = "";
                LOG_CONTEXTUAL_ERR("\\x sequence too short");
                goto err;
            }

            const uint8_t nib1 = hex2nibble(key[i + 1]);
            const uint8_t nib2 = hex2nibble(key[i + 2]);

            if (nib1 >= HEX_DIGIT_INVALID || nib2 >= HEX_DIGIT_INVALID) {
                ctx->value = "";
                LOG_CONTEXTUAL_ERR("invalid \\x sequence: \\x%c%c",
                                   key[i + 1], key[i + 2]);
                goto err;
            }

            data[data_len++] = nib1 << 4 | nib2;
            esc = false;
            i += 2;
        }

        else
            data[data_len++] = key[i];
    }

    struct binding_aux aux = {
        .type = BINDING_AUX_TEXT,
        .text = {
            .data = data,  /* data is now owned by value_to_key_combos() */
            .len = data_len,
        },
    };

    if (!value_to_key_combos(ctx, BIND_ACTION_TEXT_BINDING, &aux,
                             &conf->bindings.key, KEY_BINDING))
    {
        /* Do *not* free(data) - it is handled by value_to_key_combos() */
        return false;
    }

    return true;

err:
    free(data);
    return false;
}

/* parse_section_environment: ported to config.zig */
/* parse_section_tweak: ported to config.zig */

/* parse_section_touch: ported to config.zig */
/* enum section, section_info[], str_to_section(), parse_key_value() and
 * parse_config_file(): ported to config.zig */

static char *
get_server_socket_path(void)
{
    const char *xdg_runtime = getenv("XDG_RUNTIME_DIR");
    if (xdg_runtime == NULL)
        return xstrdup("/tmp/foot.sock");

    const char *wayland_display = getenv("WAYLAND_DISPLAY");
    if (wayland_display == NULL) {
        return xstrjoin(xdg_runtime, "/foot.sock");
    }

    return xasprintf("%s/foot-%s.sock", xdg_runtime, wayland_display);
}

static config_modifier_list_t
m(const char *text)
{
    config_modifier_list_t ret = tll_init();
    parse_modifiers(text, strlen(text), &ret);
    return ret;
}

static void
add_default_key_bindings(struct config *conf)
{
    const struct config_key_binding bindings[] = {
        {BIND_ACTION_SCROLLBACK_UP_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Prior}}},
        {BIND_ACTION_SCROLLBACK_UP_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_KP_Prior}}},
        {BIND_ACTION_SCROLLBACK_DOWN_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Next}}},
        {BIND_ACTION_SCROLLBACK_DOWN_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_KP_Next}}},
        {BIND_ACTION_CLIPBOARD_COPY, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_c}}},
        {BIND_ACTION_CLIPBOARD_COPY, m("none"), {{XKB_KEY_XF86Copy}}},
        {BIND_ACTION_CLIPBOARD_PASTE, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_v}}},
        {BIND_ACTION_CLIPBOARD_PASTE, m("none"), {{XKB_KEY_XF86Paste}}},
        {BIND_ACTION_PRIMARY_PASTE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Insert}}},
        {BIND_ACTION_SEARCH_START, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_r}}},
        {BIND_ACTION_FONT_SIZE_UP, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_plus}}},
        {BIND_ACTION_FONT_SIZE_UP, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_equal}}},
        {BIND_ACTION_FONT_SIZE_UP, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_KP_Add}}},
        {BIND_ACTION_FONT_SIZE_DOWN, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_minus}}},
        {BIND_ACTION_FONT_SIZE_DOWN, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_KP_Subtract}}},
        {BIND_ACTION_FONT_SIZE_RESET, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_0}}},
        {BIND_ACTION_FONT_SIZE_RESET, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_KP_0}}},
        {BIND_ACTION_SPAWN_TERMINAL, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_n}}},
        {BIND_ACTION_SHOW_URLS_LAUNCH, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_o}}},
        {BIND_ACTION_UNICODE_INPUT, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_u}}},
        {BIND_ACTION_PROMPT_PREV, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_z}}},
        {BIND_ACTION_PROMPT_NEXT, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_x}}},
    };

    conf->bindings.key.count = ALEN(bindings);
    conf->bindings.key.arr = xmemdup(bindings, sizeof(bindings));
}


static void
add_default_search_bindings(struct config *conf)
{
    const struct config_key_binding bindings[] = {
        {BIND_ACTION_SEARCH_SCROLLBACK_UP_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Prior}}},
        {BIND_ACTION_SEARCH_SCROLLBACK_UP_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_KP_Prior}}},
        {BIND_ACTION_SEARCH_SCROLLBACK_DOWN_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Next}}},
        {BIND_ACTION_SEARCH_SCROLLBACK_DOWN_PAGE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_KP_Next}}},
        {BIND_ACTION_SEARCH_CANCEL, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_c}}},
        {BIND_ACTION_SEARCH_CANCEL, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_g}}},
        {BIND_ACTION_SEARCH_CANCEL, m("none"), {{XKB_KEY_Escape}}},
        {BIND_ACTION_SEARCH_COMMIT, m("none"), {{XKB_KEY_Return}}},
        {BIND_ACTION_SEARCH_COMMIT, m("none"), {{XKB_KEY_KP_Enter}}},
        {BIND_ACTION_SEARCH_FIND_PREV, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_r}}},
        {BIND_ACTION_SEARCH_FIND_NEXT, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_s}}},
        {BIND_ACTION_SEARCH_EDIT_LEFT, m("none"), {{XKB_KEY_Left}}},
        {BIND_ACTION_SEARCH_EDIT_LEFT, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_b}}},
        {BIND_ACTION_SEARCH_EDIT_LEFT_WORD, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_Left}}},
        {BIND_ACTION_SEARCH_EDIT_LEFT_WORD, m(XKB_MOD_NAME_ALT), {{XKB_KEY_b}}},
        {BIND_ACTION_SEARCH_EDIT_RIGHT, m("none"), {{XKB_KEY_Right}}},
        {BIND_ACTION_SEARCH_EDIT_RIGHT, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_f}}},
        {BIND_ACTION_SEARCH_EDIT_RIGHT_WORD, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_Right}}},
        {BIND_ACTION_SEARCH_EDIT_RIGHT_WORD, m(XKB_MOD_NAME_ALT), {{XKB_KEY_f}}},
        {BIND_ACTION_SEARCH_EDIT_HOME, m("none"), {{XKB_KEY_Home}}},
        {BIND_ACTION_SEARCH_EDIT_HOME, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_a}}},
        {BIND_ACTION_SEARCH_EDIT_END, m("none"), {{XKB_KEY_End}}},
        {BIND_ACTION_SEARCH_EDIT_END, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_e}}},
        {BIND_ACTION_SEARCH_DELETE_PREV, m("none"), {{XKB_KEY_BackSpace}}},
        {BIND_ACTION_SEARCH_DELETE_PREV_WORD, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_BackSpace}}},
        {BIND_ACTION_SEARCH_DELETE_PREV_WORD, m(XKB_MOD_NAME_ALT), {{XKB_KEY_BackSpace}}},
        {BIND_ACTION_SEARCH_DELETE_NEXT, m("none"), {{XKB_KEY_Delete}}},
        {BIND_ACTION_SEARCH_DELETE_NEXT_WORD, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_Delete}}},
        {BIND_ACTION_SEARCH_DELETE_NEXT_WORD, m(XKB_MOD_NAME_ALT), {{XKB_KEY_d}}},
        {BIND_ACTION_SEARCH_DELETE_TO_START, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_u}}},
        {BIND_ACTION_SEARCH_DELETE_TO_END, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_k}}},
        {BIND_ACTION_SEARCH_EXTEND_CHAR, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Right}}},
        {BIND_ACTION_SEARCH_EXTEND_WORD, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_Right}}},
        {BIND_ACTION_SEARCH_EXTEND_WORD, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_w}}},
        {BIND_ACTION_SEARCH_EXTEND_WORD_WS, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_w}}},
        {BIND_ACTION_SEARCH_EXTEND_LINE_DOWN, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Down}}},
        {BIND_ACTION_SEARCH_EXTEND_BACKWARD_CHAR, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Left}}},
        {BIND_ACTION_SEARCH_EXTEND_BACKWARD_WORD, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_Left}}},
        {BIND_ACTION_SEARCH_EXTEND_LINE_UP, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Up}}},
        {BIND_ACTION_SEARCH_CLIPBOARD_PASTE, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_v}}},
        {BIND_ACTION_SEARCH_CLIPBOARD_PASTE, m(XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT), {{XKB_KEY_v}}},
        {BIND_ACTION_SEARCH_CLIPBOARD_PASTE, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_y}}},
        {BIND_ACTION_SEARCH_CLIPBOARD_PASTE, m("none"), {{XKB_KEY_XF86Paste}}},
        {BIND_ACTION_SEARCH_PRIMARY_PASTE, m(XKB_MOD_NAME_SHIFT), {{XKB_KEY_Insert}}},
    };

    conf->bindings.search.count = ALEN(bindings);
    conf->bindings.search.arr = xmemdup(bindings, sizeof(bindings));
}

static void
add_default_url_bindings(struct config *conf)
{
    const struct config_key_binding bindings[] = {
        {BIND_ACTION_URL_CANCEL, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_c}}},
        {BIND_ACTION_URL_CANCEL, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_g}}},
        {BIND_ACTION_URL_CANCEL, m(XKB_MOD_NAME_CTRL), {{XKB_KEY_d}}},
        {BIND_ACTION_URL_CANCEL, m("none"), {{XKB_KEY_Escape}}},
        {BIND_ACTION_URL_TOGGLE_URL_ON_JUMP_LABEL, m("none"), {{XKB_KEY_t}}},
    };

    conf->bindings.url.count = ALEN(bindings);
    conf->bindings.url.arr = xmemdup(bindings, sizeof(bindings));
}

static void
add_default_mouse_bindings(struct config *conf)
{
    const struct config_key_binding bindings[] = {
        {BIND_ACTION_SCROLLBACK_UP_MOUSE, m("none"), {.m = {BTN_WHEEL_BACK, 1}}},
        {BIND_ACTION_SCROLLBACK_DOWN_MOUSE, m("none"), {.m = {BTN_WHEEL_FORWARD, 1}}},
        {BIND_ACTION_PRIMARY_PASTE, m("none"), {.m = {BTN_MIDDLE, 1}}},
        {BIND_ACTION_SELECT_BEGIN, m("none"), {.m = {BTN_LEFT, 1}}},
        {BIND_ACTION_SELECT_BEGIN_BLOCK, m(XKB_MOD_NAME_CTRL), {.m = {BTN_LEFT, 1}}},
        {BIND_ACTION_SELECT_EXTEND, m("none"), {.m = {BTN_RIGHT, 1}}},
        {BIND_ACTION_SELECT_EXTEND_CHAR_WISE, m(XKB_MOD_NAME_CTRL), {.m = {BTN_RIGHT, 1}}},
        {BIND_ACTION_SELECT_WORD, m("none"), {.m = {BTN_LEFT, 2}}},
        {BIND_ACTION_SELECT_WORD_WS, m(XKB_MOD_NAME_CTRL), {.m = {BTN_LEFT, 2}}},
        {BIND_ACTION_SELECT_QUOTE, m("none"), {.m = {BTN_LEFT, 3}}},
        {BIND_ACTION_SELECT_ROW, m("none"), {.m = {BTN_LEFT, 4}}},
        {BIND_ACTION_FONT_SIZE_UP, m("Control"), {.m = {BTN_WHEEL_BACK, 1}}},
        {BIND_ACTION_FONT_SIZE_DOWN, m("Control"), {.m = {BTN_WHEEL_FORWARD, 1}}},
    };

    conf->bindings.mouse.count = ALEN(bindings);
    conf->bindings.mouse.arr = xmemdup(bindings, sizeof(bindings));
}

static void NOINLINE
config_font_list_clone(struct config_font_list *dst,
                       const struct config_font_list *src)
{
    dst->count = src->count;
    dst->arr = xmalloc(dst->count * sizeof(dst->arr[0]));

    for (size_t j = 0; j < dst->count; j++) {
        dst->arr[j].pt_size = src->arr[j].pt_size;
        dst->arr[j].px_size = src->arr[j].px_size;
        dst->arr[j].pattern = xstrdup(src->arr[j].pattern);
    }
}

bool
config_load(struct config *conf, const char *conf_path,
            user_notifications_t *initial_user_notifications,
            config_override_t *overrides, bool errors_are_fatal,
            bool as_server)
{
    bool ret = true;
    enum fcft_capabilities fcft_caps = fcft_capabilities();

    *conf = (struct config) {
        .conf_path = (conf_path ? xstrdup(conf_path) : NULL),
        .term = xstrdup(FOOT_DEFAULT_TERM),
        .shell = get_shell(),
        .title = xstrdup("foot"),
        .app_id = (as_server ? xstrdup("footclient") : xstrdup("foot")),
        .toplevel_tag = xstrdup(""),
        .word_delimiters = xc32dup(U",│`|:\"'()[]{}<>"),
        .size = {
            .type = CONF_SIZE_PX,
            .width = 700,
            .height = 500,
        },
        .pad_left = 0,
        .pad_top = 0,
        .pad_right = 0,
        .pad_bottom = 0,
        .center_when = CENTER_MAXIMIZED_AND_FULLSCREEN,
        .resize_by_cells = true,
        .resize_keep_grid = true,
        .resize_delay_ms = 100,
        .dim = { .amount = 1.5 },
        .bold_in_bright = {
            .enabled = false,
            .palette_based = false,
            .amount = 1.3,
        },
        .startup_mode = STARTUP_WINDOWED,
        .fonts = {{0}},
        .font_size_adjustment = {.percent = 0., .pt_or_px = {.pt = 0.5, .px = 0}},
        .line_height = {.pt = 0, .px = -1},
        .letter_spacing = {.pt = 0, .px = 0},
        .horizontal_letter_offset = {.pt = 0, .px = 0},
        .vertical_letter_offset = {.pt = 0, .px = 0},
        .use_custom_underline_offset = false,
        .box_drawings_uses_font_glyphs = false,
        .underline_thickness = {.pt = 0., .px = -1},
        .strikeout_thickness = {.pt = 0., .px = -1},
        .dpi_aware = false,
        .gamma_correct = false,
        .uppercase_regex_insert = true,
        .security = {
            .osc52 = OSC52_ENABLED,
        },
        .bell = {
            .urgent = false,
            .notify = false,
            .flash = false,
            .system_bell = true,
            .command = {
                .argv = {.args = NULL},
            },
            .command_focused = false,
        },
        .url = {
            .label_letters = xc32dup(U"sadfjklewcmpgh"),
            .osc8_underline = OSC8_UNDERLINE_URL_MODE,
            .style = UNDERLINE_DOTTED,
        },
        .custom_regexes = tll_init(),
        .can_shape_grapheme = fcft_caps & FCFT_CAPABILITY_GRAPHEME_SHAPING,
        .scrollback = {
            .lines = 1000,
            .indicator = {
                .position = SCROLLBACK_INDICATOR_POSITION_RELATIVE,
                .format = SCROLLBACK_INDICATOR_FORMAT_TEXT,
                .text = xc32dup(U""),
            },
            .multiplier = 3.,
        },
        .colors_dark = {
            .fg = default_foreground,
            .bg = default_background,
            .flash = 0x7f7f00,
            .flash_alpha = 0x7fff,
            .alpha = 0xffff,
            .alpha_mode = ALPHA_MODE_DEFAULT,
            .dim_blend_towards = DIM_BLEND_TOWARDS_BLACK,
            .selection_fg = 0x80000000,  /* Use default bg */
            .selection_bg = 0x80000000,  /* Use default fg */
            .cursor = {
                .text = 0,
                .cursor = 0,
            },
            .use_custom = {
                .jump_label = false,
                .scrollback_indicator = false,
                .url = false,
            },
            .blur = false,
        },
        .initial_color_theme = COLOR_THEME_DARK,
        .cursor = {
            .style = CURSOR_BLOCK,
            .unfocused_style = CURSOR_UNFOCUSED_HOLLOW,
            .blink = {
                .enabled = false,
                .rate_ms = 500,
            },
            .beam_thickness = {.pt = 1.5},
            .underline_thickness = {.pt = 0., .px = -1},
        },
        .mouse = {
            .hide_when_typing = false,
            .alternate_scroll_mode = true,
            .selection_override_modifiers = tll_init(),
        },
        .csd = {
            .preferred = CONF_CSD_PREFER_SERVER,
            .font = {0},
            .hide_when_maximized = false,
            .double_click_to_maximize = true,
            .title_height = 26,
            .border_width = 5,
            .border_width_visible = 0,
            .button_width = 26,
        },

        .render_worker_count = sysconf(_SC_NPROCESSORS_ONLN),
        .server_socket_path = get_server_socket_path(),
        .presentation_timings = false,
        .selection_target = SELECTION_TARGET_PRIMARY,
        .hold_at_exit = false,
        .desktop_notifications = {
            .command = {
                .argv = {.args = NULL},
            },
            .command_action_arg = {
                .argv = {.args = NULL},
            },
            .close = {
                .argv = {.args = NULL},
            },
            .inhibit_when_focused = true,
        },

        .tweak = {
            .fcft_filter = FCFT_SCALING_FILTER_LANCZOS3,
            .overflowing_glyphs = true,
#if defined(FOOT_GRAPHEME_CLUSTERING) && FOOT_GRAPHEME_CLUSTERING
            .grapheme_shaping = fcft_caps & FCFT_CAPABILITY_GRAPHEME_SHAPING,
#endif
            .grapheme_width_method = GRAPHEME_WIDTH_DOUBLE,
            .delayed_render_lower_ns = 500000,         /* 0.5ms */
            .delayed_render_upper_ns = 16666666 / 2,   /* half a frame period (60Hz) */
            .max_shm_pool_size = 512 * 1024 * 1024,
            .render_timer = RENDER_TIMER_NONE,
            .damage_whole_window = false,
            .box_drawing_base_thickness = 0.04,
            .box_drawing_solid_shades = true,
            .font_monospace_warn = true,
            .sixel = true,
            .surface_bit_depth = SHM_BITS_AUTO,
            .min_stride_alignment = 256,
            .preapply_damage = true,
        },

        .touch = {
            .long_press_delay = 400,
        },

        .env_vars = tll_init(),
#if defined(UTMP_DEFAULT_HELPER_PATH)
        .utmp_helper_path = ((strlen(UTMP_DEFAULT_HELPER_PATH) > 0 &&
                              access(UTMP_DEFAULT_HELPER_PATH, X_OK) == 0)
                             ? xstrdup(UTMP_DEFAULT_HELPER_PATH)
                             : NULL),
#endif
        .notifications = tll_init(),
    };

    memcpy(conf->colors_dark.table, default_color_table, sizeof(default_color_table));
    memcpy(conf->colors_dark.sixel, default_sixel_colors, sizeof(default_sixel_colors));
    memcpy(&conf->colors_light, &conf->colors_dark, sizeof(conf->colors_dark));
    conf->colors_light.dim_blend_towards = DIM_BLEND_TOWARDS_WHITE;

    parse_modifiers(XKB_MOD_NAME_SHIFT, 5, &conf->mouse.selection_override_modifiers);

    tokenize_cmdline(
        "notify-send --wait --app-name ${app-id} --icon ${app-id} --category ${category} --urgency ${urgency} --expire-time ${expire-time} --hint STRING:image-path:${icon} --hint BOOLEAN:suppress-sound:${muted} --hint STRING:sound-name:${sound-name} --replace-id ${replace-id} ${action-argument} --print-id -- ${title} ${body}",
        &conf->desktop_notifications.command.argv.args);
    tokenize_cmdline("--action ${action-name}=${action-label}", &conf->desktop_notifications.command_action_arg.argv.args);
    tokenize_cmdline("xdg-open ${url}", &conf->url.launch.argv.args);

    {

        int r = regcomp(&conf->url.preg, default_url_regex_string, REG_EXTENDED);
        xassert(r == 0);
        conf->url.regex = xstrdup(default_url_regex_string);
        xassert(conf->url.preg.re_nsub >= 1);
    }

    tll_foreach(*initial_user_notifications, it) {
        tll_push_back(conf->notifications, it->item);
        tll_remove(*initial_user_notifications, it);
    }

    add_default_key_bindings(conf);
    add_default_search_bindings(conf);
    add_default_url_bindings(conf);
    add_default_mouse_bindings(conf);

    struct config_file conf_file = {.path = NULL, .fd = -1};
    if (conf_path != NULL) {
        int fd = open(conf_path, O_RDONLY);
        if (fd < 0) {
            LOG_AND_NOTIFY_ERRNO("%s: failed to open", conf_path);
            ret = !errors_are_fatal;
        } else {
            conf_file.path = xstrdup(conf_path);
            conf_file.fd = fd;
        }
    } else {
        conf_file = open_config();
        if (conf_file.fd < 0) {
            LOG_WARN("no configuration found, using defaults");
            ret = !errors_are_fatal;
        }
    }

    if (conf_file.path && conf_file.fd >= 0) {
        LOG_INFO("loading configuration from %s", conf_file.path);

        FILE *f = fdopen(conf_file.fd, "r");
        if (f == NULL) {
            LOG_AND_NOTIFY_ERRNO("%s: failed to open", conf_file.path);
            ret = !errors_are_fatal;
        } else {
            if (!parse_config_file(f, conf, conf_file.path, errors_are_fatal))
                ret = !errors_are_fatal;

            fclose(f);
            conf_file.fd = -1;
        }
    }

    if (!config_override_apply(conf, overrides, errors_are_fatal))
        ret = !errors_are_fatal;

    if (ret && conf->fonts[0].count == 0) {
        struct config_font font;
        if (!config_font_parse("monospace", &font)) {
            LOG_ERR("failed to load font 'monospace' - no fonts installed?");
            ret = false;
        } else {
            conf->fonts[0].count = 1;
            conf->fonts[0].arr = xmalloc(sizeof(font));
            conf->fonts[0].arr[0] = font;
        }
    }

    if (ret && conf->csd.font.count == 0)
        config_font_list_clone(&conf->csd.font, &conf->fonts[0]);

#if defined(_DEBUG)
    for (size_t i = 0; i < conf->bindings.key.count; i++)
        xassert(conf->bindings.key.arr[i].action != BIND_ACTION_NONE);
    for (size_t i = 0; i < conf->bindings.search.count; i++)
        xassert(conf->bindings.search.arr[i].action != BIND_ACTION_SEARCH_NONE);
    for (size_t i = 0; i < conf->bindings.url.count; i++)
        xassert(conf->bindings.url.arr[i].action != BIND_ACTION_URL_NONE);
#endif

    free(conf_file.path);
    if (conf_file.fd >= 0)
        close(conf_file.fd);

    return ret;
}

/* Reachable from config.zig: the override loop is ported, but the collision
 * resolution below still needs the C binding lookup tables. */
bool
config_bindings_finalize(struct config *conf)
{
    return
        resolve_key_binding_collisions(
            conf, "key-bindings",
            binding_action_map, &conf->bindings.key, KEY_BINDING) &&
        resolve_key_binding_collisions(
            conf, "search-bindings",
            search_binding_action_map, &conf->bindings.search, KEY_BINDING) &&
        resolve_key_binding_collisions(
            conf, "url-bindings",
            url_binding_action_map, &conf->bindings.url, KEY_BINDING) &&
        resolve_key_binding_collisions(
            conf, "mouse-bindings",
            binding_action_map, &conf->bindings.mouse, MOUSE_BINDING);
}

static void NOINLINE
key_binding_list_clone(struct config_key_binding_list *dst,
                       const struct config_key_binding_list *src)
{
    struct argv *last_master_argv = NULL;
    uint8_t *last_master_text_data = NULL;
    size_t last_master_text_len = 0;
    char *last_master_regex_name = NULL;

    dst->count = src->count;
    dst->arr = xmalloc(src->count * sizeof(dst->arr[0]));

    for (size_t i = 0; i < src->count; i++) {
        const struct config_key_binding *old = &src->arr[i];
        struct config_key_binding *new = &dst->arr[i];

        *new = *old;
        memset(&new->modifiers, 0, sizeof(new->modifiers));
        tll_foreach(old->modifiers, it)
            tll_push_back(new->modifiers, xstrdup(it->item));

        switch (old->aux.type) {
        case BINDING_AUX_NONE:
            last_master_argv = NULL;
            last_master_text_data = NULL;
            last_master_text_len = 0;
            break;

        case BINDING_AUX_PIPE:
            if (old->aux.master_copy) {
                clone_argv(&new->aux.pipe, &old->aux.pipe);
                last_master_argv = &new->aux.pipe;
            } else {
                xassert(last_master_argv != NULL);
                new->aux.pipe = *last_master_argv;
            }
            last_master_text_data = NULL;
            last_master_text_len = 0;
            break;

        case BINDING_AUX_TEXT:
            if (old->aux.master_copy) {
                const size_t len = old->aux.text.len;
                new->aux.text.len = len;
                new->aux.text.data = xmemdup(old->aux.text.data, len);

                last_master_text_len = len;
                last_master_text_data = new->aux.text.data;
            } else {
                xassert(last_master_text_data != NULL);
                new->aux.text.len = last_master_text_len;
                new->aux.text.data = last_master_text_data;
            }
            last_master_argv = NULL;
            break;

        case BINDING_AUX_REGEX:
            if (old->aux.master_copy) {
                new->aux.regex_name = xstrdup(old->aux.regex_name);
                last_master_regex_name = new->aux.regex_name;
            } else {
                xassert(last_master_regex_name != NULL);
                new->aux.regex_name = last_master_regex_name;
            }
            break;
        }
    }
}

struct config *
config_clone(const struct config *old)
{
    struct config *conf = xmalloc(sizeof(*conf));
    *conf = *old;

    conf->conf_path = (old->conf_path ? xstrdup(old->conf_path) : NULL);
    conf->term = xstrdup(old->term);
    conf->shell = xstrdup(old->shell);
    conf->title = xstrdup(old->title);
    conf->app_id = xstrdup(old->app_id);
    conf->toplevel_tag = xstrdup(old->toplevel_tag);
    conf->word_delimiters = xc32dup(old->word_delimiters);
    conf->scrollback.indicator.text = xc32dup(old->scrollback.indicator.text);
    conf->server_socket_path = xstrdup(old->server_socket_path);
    spawn_template_clone(&conf->bell.command, &old->bell.command);
    spawn_template_clone(&conf->desktop_notifications.command,
                         &old->desktop_notifications.command);
    spawn_template_clone(&conf->desktop_notifications.command_action_arg,
                         &old->desktop_notifications.command_action_arg);
    spawn_template_clone(&conf->desktop_notifications.close,
                         &old->desktop_notifications.close);

    for (size_t i = 0; i < ALEN(conf->fonts); i++)
        config_font_list_clone(&conf->fonts[i], &old->fonts[i]);
    config_font_list_clone(&conf->csd.font, &old->csd.font);

    conf->url.label_letters = xc32dup(old->url.label_letters);
    spawn_template_clone(&conf->url.launch, &old->url.launch);
    conf->url.regex = xstrdup(old->url.regex);
    regcomp(&conf->url.preg, conf->url.regex, REG_EXTENDED);

    memset(&conf->custom_regexes, 0, sizeof(conf->custom_regexes));
    tll_foreach(old->custom_regexes, it) {
        const struct custom_regex *old_regex = &it->item;

        tll_push_back(conf->custom_regexes,
                      ((struct custom_regex){.name = xstrdup(old_regex->name),
                                             .regex = xstrdup(old_regex->regex)}));


        struct custom_regex *new_regex = &tll_back(conf->custom_regexes);
        regcomp(&new_regex->preg, new_regex->regex, REG_EXTENDED);
        spawn_template_clone(&new_regex->launch, &old_regex->launch);
    }

    key_binding_list_clone(&conf->bindings.key, &old->bindings.key);
    key_binding_list_clone(&conf->bindings.search, &old->bindings.search);
    key_binding_list_clone(&conf->bindings.url, &old->bindings.url);
    key_binding_list_clone(&conf->bindings.mouse, &old->bindings.mouse);

    conf->env_vars.length = 0;
    conf->env_vars.head = conf->env_vars.tail = NULL;

    memset(&conf->mouse.selection_override_modifiers, 0, sizeof(conf->mouse.selection_override_modifiers));
    tll_foreach(old->mouse.selection_override_modifiers, it)
        tll_push_back(conf->mouse.selection_override_modifiers, xstrdup(it->item));

    tll_foreach(old->env_vars, it) {
        struct env_var copy = {
            .name = xstrdup(it->item.name),
            .value = xstrdup(it->item.value),
        };
        tll_push_back(conf->env_vars, copy);
    }

    conf->utmp_helper_path =
        old->utmp_helper_path != NULL ? xstrdup(old->utmp_helper_path) : NULL;

    conf->notifications.length = 0;
    conf->notifications.head = conf->notifications.tail = 0;
    tll_foreach(old->notifications, it) {
        char *text = xstrdup(it->item.text);
        user_notification_add(&conf->notifications, it->item.kind, text);
    }

    return conf;
}

UNITTEST
{
    struct config original;
    user_notifications_t nots = tll_init();
    config_override_t overrides = tll_init();

    fcft_init(FCFT_LOG_COLORIZE_NEVER, false, FCFT_LOG_CLASS_NONE);

    bool ret = config_load(&original, "/dev/null", &nots, &overrides, false, false);
    xassert(ret);

    //struct config *clone = config_clone(&original);
    //xassert(clone != NULL);
    //xassert(clone != &original);

    config_free(&original);
    //config_free(clone);
    //free(clone);

    fcft_fini();

    tll_free(overrides);
    tll_free(nots);
}

void
config_free(struct config *conf)
{
    free(conf->conf_path);
    free(conf->term);
    free(conf->shell);
    free(conf->title);
    free(conf->app_id);
    free(conf->toplevel_tag);
    free(conf->word_delimiters);
    spawn_template_free(&conf->bell.command);
    free(conf->scrollback.indicator.text);
    spawn_template_free(&conf->desktop_notifications.command);
    spawn_template_free(&conf->desktop_notifications.command_action_arg);
    spawn_template_free(&conf->desktop_notifications.close);
    for (size_t i = 0; i < ALEN(conf->fonts); i++)
        config_font_list_destroy(&conf->fonts[i]);
    free(conf->server_socket_path);

    config_font_list_destroy(&conf->csd.font);

    free(conf->url.label_letters);
    spawn_template_free(&conf->url.launch);
    regfree(&conf->url.preg);
    free(conf->url.regex);

    tll_foreach(conf->custom_regexes, it) {
        struct custom_regex *regex = &it->item;
        free(regex->name);
        free(regex->regex);
        regfree(&regex->preg);
        spawn_template_free(&regex->launch);
        tll_remove(conf->custom_regexes, it);
    }

    free_key_binding_list(&conf->bindings.key);
    free_key_binding_list(&conf->bindings.search);
    free_key_binding_list(&conf->bindings.url);
    free_key_binding_list(&conf->bindings.mouse);
    tll_free_and_free(conf->mouse.selection_override_modifiers, free);

    tll_foreach(conf->env_vars, it) {
        free(it->item.name);
        free(it->item.value);
        tll_remove(conf->env_vars, it);
    }

    free(conf->utmp_helper_path);
    user_notifications_free(&conf->notifications);
}

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


static void UNUSED
unittest_check_url_match(const char *url, const char *expected_match,
                         regmatch_t match)
{
    const size_t mlen = match.rm_eo - match.rm_so;
    const size_t start = &url[match.rm_so] - url;
    //const size_t end = start + mlen;

    if (mlen != strlen(expected_match) ||
        memcmp(&url[start], expected_match, mlen) != 0)
    {
        printf("url: %s\n"
               "  expected match: %s\n"
               "  match:          %.*s\n",
               url, expected_match, (int)mlen, &url[start]);
        BUG("URL regex failure");
    }
}

UNITTEST
{
    regex_t re;
    int r = regcomp(&re, default_url_regex_string, REG_EXTENDED);
    xassert(r == 0);
    xassert(re.re_nsub >= 1);

    const struct {
        const char *url;
        const char *expected_match;
    } test_cases[] = {
        {"https://www.foobar.com/[a](b)\"c\"'d'efg.html?foo=bar&bar=foo",
         "https://www.foobar.com/[a](b)\"c\"'d'efg.html?foo=bar&bar=foo"},

        /* Trailing quotes are not matched */
        {"https://quote-at-the-end'",
         "https://quote-at-the-end"},

        {"https://quote-at-the-end\"",
         "https://quote-at-the-end"},

        /* That includes quoted URLs too */
        {"'https://quote-at-the-end''",
         "https://quote-at-the-end"},

        {"\"https://quote-at-the-end\"\"",
         "https://quote-at-the-end"},

        /* Allow '-quotes in the middle */
        {"https://unbalanced'not-at-the-end",
         "https://unbalanced'not-at-the-end"},

        /* But not "-quotes */
        {"https://unbalanced\"not-at-the-end",
         "https://unbalanced"},

        /* "Balanced" quotes are allowed, at the end */
        {"https://balanced-'quote'",
         "https://balanced-'quote'"},

        /* ... and in the middle */
        {"https://balanced-'quote'-in-the-middle",
         "https://balanced-'quote'-in-the-middle"},

        /* Balanced "-quotes too */
        {"https://balanced-\"quote\"",
         "https://balanced-\"quote\""},

        {"https://balanced-\"quote\"-in-the-middle",
         "https://balanced-\"quote\"-in-the-middle"},

        /* Quoted URLs should match the URL part, not the quotes */
        {"'https://quoted-url'",
         "https://quoted-url"},

        /* Same with "-quotes */
        {"\"https://quoted-url\"",
         "https://quoted-url"},

        {"\"https://quoted-url-with-'-inside\"",
         "https://quoted-url-with-'-inside"},

        {"'https://abc' foobar",
         "https://abc"},

        {"https://foo[bar",
         "https://foo"},

        {"https://foo[]bar",
         "https://foo"},

        {"https://foo[abc]",
         "https://foo[abc]"},

        {"https://foo[abc]bar",
         "https://foo[abc]bar"},

        {"https://foo(bar",
         "https://foo"},

        {"https://foo()bar",
         "https://foo"},

        {"https://foo(abc)",
         "https://foo(abc)"},

        {"https://foo(abc)bar",
         "https://foo(abc)bar"},

        {"https://foo{bar",
         "https://foo"},

        {"https://foo{}bar",
         "https://foo"},

        {"https://foo{abc}bar",
         "https://foo"},
    };

    for (size_t i = 0; i < ALEN(test_cases); i++) {
        const char *const url = test_cases[i].url;
        const char *const expected_match = test_cases[i].expected_match;

#if 0
        printf("url:      %s\n", url);
        printf("expecede: %s\n", expected_match);
#endif

        regmatch_t matches[re.re_nsub + 1];
        int r UNUSED = regexec(&re, url, re.re_nsub + 1, matches, 0);
        assert(r == 0);
        unittest_check_url_match(url, expected_match, matches[1]);
    }

    regfree(&re);
}
