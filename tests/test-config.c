#if !defined(_DEBUG)
 #define _DEBUG
#endif
#undef NDEBUG

#include "../log.h"

#include <fontconfig/fontconfig.h>

/* These used to come in transitively through config.c; they are declared here
 * now that config.c is gone and the parser is entirely Zig. */
#include "../char32.h"
#include "../xmalloc.h"
#include "../debug.h"
#include "../macros.h"
#include "../util.h"
#include <string.h>
#include <uchar.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/input-event-codes.h>

#include "../input.h"
#include "../key-binding.h"

extern bool parse_section_main(struct context *ctx);
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
extern bool parse_config_file(
    FILE *f, struct config *conf, const char *path, bool errors_are_fatal);
extern bool parse_section_url(struct context *ctx);
extern void free_key_binding_list(struct config_key_binding_list *bindings);
extern bool parse_section_regex(struct context *ctx);
extern size_t config_button_map_len(void);
extern int config_button_map_code(size_t idx);
extern const char *config_button_map_name(size_t idx);

/* Ported to config.zig (C2k): the action tables moved there. */
extern bool parse_section_key_bindings(struct context *ctx);
extern bool parse_section_search_bindings(struct context *ctx);
extern bool parse_section_url_bindings(struct context *ctx);
extern bool parse_section_mouse_bindings(struct context *ctx);
extern bool parse_section_text_bindings(struct context *ctx);
extern bool config_resolve_key_binding_collisions(
    struct config *conf, const char *section_name, int kind,
    struct config_key_binding_list *bindings, enum key_binding_type type);
extern size_t config_action_map_count(int kind);
extern const char *config_action_map_name(int kind, int action);

/* Ported to config.zig (C2m): the default URL regex, and the tables it
 * replaces. The regex' own UNITTEST moved here with it. */
extern const char *config_default_url_regex_string(void);

/* Ported to config.zig (C2o): the font helpers. */
extern struct config_font_list value_to_fonts(struct context *ctx);
extern bool config_font_parse(const char *pattern, struct config_font *font);
extern void config_font_list_destroy(struct config_font_list *font_list);
extern bool check_if_font_is_monospaced(
    const char *pattern, user_notifications_t *notifications);

enum { MAP_KIND_KEY, MAP_KIND_SEARCH, MAP_KIND_URL };

#define ALEN(v) (sizeof(v) / sizeof((v)[0]))

/*
 * Stubs
 */

void
user_notification_add_fmt(user_notifications_t *notifications,
                          enum user_notification_kind kind,
                          const char *fmt, ...)
{
}

static void
test_invalid_key(struct context *ctx, bool (*parse_fun)(struct context *ctx),
                 const char *key)
{
    ctx->key = key;
    ctx->value = "value for invalid key";

    if (parse_fun(ctx)) {
        BUG("[%s].%s: did not fail to parse as expected"
            "(key should be invalid)", ctx->section, ctx->key);
    }
}

static void
test_string(struct context *ctx, bool (*parse_fun)(struct context *ctx),
             const char *key, char *const *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        const char *value;
        bool invalid;
    } input[] = {
        {"a string", "a string"},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (!streq(*ptr, input[i].value)) {
                BUG("[%s].%s=%s: set value (%s) not the expected one (%s)",
                    ctx->section, ctx->key, ctx->value,
                    *ptr, input[i].value);
            }
        }
    }
}

static void
test_c32string(struct context *ctx, bool (*parse_fun)(struct context *ctx),
               const char *key, char32_t *const *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        const char32_t *value;
        bool invalid;
    } input[] = {
        {"a string", U"a string"},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (c32cmp(*ptr, input[i].value) != 0) {
                BUG("[%s].%s=%s: set value (%ls) not the expected one (%ls)",
                    ctx->section, ctx->key, ctx->value,
                    (const wchar_t *)*ptr,
                    (const wchar_t *)input[i].value);
            }
        }
    }
}

static void
test_boolean(struct context *ctx, bool (*parse_fun)(struct context *ctx),
             const char *key, const bool *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        bool value;
        bool invalid;
    } input[] = {
        {"1", true}, {"0", false},
        {"on", true}, {"off", false},
        {"true", true}, {"false", false},
        {"unittest-invalid-boolean-value", false, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (*ptr != input[i].value) {
                BUG("[%s].%s=%s: set value (%s) not the expected one (%s)",
                    ctx->section, ctx->key, ctx->value,
                    *ptr ? "true" : "false",
                    input[i].value ? "true" : "false");
            }
        }
    }
}

static void
test_uint16(struct context *ctx, bool (*parse_fun)(struct context *ctx),
            const char *key, const uint16_t *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        uint16_t value;
        bool invalid;
    } input[] = {
        {"0", 0}, {"65535", 65535}, {"65536", 0, true},
        {"abc", 0, true}, {"true", 0, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (*ptr != input[i].value) {
                BUG("[%s].%s=%s: set value (%hu) not the expected one (%hu)",
                    ctx->section, ctx->key, ctx->value,
                    *ptr, input[i].value);
            }
        }
    }
}

static void
test_uint32(struct context *ctx, bool (*parse_fun)(struct context *ctx),
            const char *key, const uint32_t *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        uint32_t value;
        bool invalid;
    } input[] = {
        {"0", 0}, {"65536", 65536}, {"4294967295", 4294967295},
         {"4294967296", 0, true}, {"abc", 0, true}, {"true", 0, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (*ptr != input[i].value) {
                BUG("[%s].%s=%s: set value (%u) not the expected one (%u)",
                    ctx->section, ctx->key, ctx->value,
                    *ptr, input[i].value);
            }
        }
    }
}

static void
test_float(struct context *ctx, bool (*parse_fun)(struct context *ctx),
            const char *key, const float *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        float value;
        bool invalid;
    } input[] = {
        {"0", 0}, {"0.1", 0.1}, {"1e10", 1e10}, {"-10.7", -10.7},
        {"abc", 0, true}, {"true", 0, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (*ptr != input[i].value) {
                BUG("[%s].%s=%s: set value (%f) not the expected one (%f)",
                    ctx->section, ctx->key, ctx->value,
                    *ptr, input[i].value);
            }
        }
    }
}

static void
test_pt_or_px(struct context *ctx, bool (*parse_fun)(struct context *ctx),
              const char *key, const struct pt_or_px *ptr)
{
    ctx->key = key;

    static const struct {
        const char *option_string;
        struct pt_or_px value;
        bool invalid;
    } input[] = {
        {"12", {.pt = 12}}, {"12px", {.px = 12}},
        {"unittest-invalid-pt-or-px-value", {0}, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;

        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }
            if (memcmp(ptr, &input[i].value, sizeof(*ptr)) != 0) {
                BUG("[%s].%s=%s: "
                    "set value (pt=%f, px=%d) not the expected one (pt=%f, px=%d)",
                    ctx->section, ctx->key, ctx->value,
                    ptr->pt, ptr->px,
                    input[i].value.pt, input[i].value.px);
            }
        }
    }
}

static void
test_spawn_template(struct context *ctx, bool (*parse_fun)(struct context *ctx),
                    const char *key, const struct config_spawn_template *ptr)
{
    static const char *const args[] = {
        "command", "arg1", "arg2", "arg3 has spaces"};

    ctx->key = key;
    ctx->value = "command arg1 arg2 \"arg3 has spaces\"";

    if (!parse_fun(ctx))
        BUG("[%s].%s=%s: failed to parse", ctx->section, ctx->key, ctx->value);

    if (ptr->argv.args == NULL)
        BUG("[%s].%s=%s: argv is NULL", ctx->section, ctx->key, ctx->value);

    for (size_t i = 0; i < ALEN(args); i++) {
        if (ptr->argv.args[i] == NULL || !streq(ptr->argv.args[i], args[i])) {
            BUG("[%s].%s=%s: set value not the expected one: "
                "mismatch of arg #%zu: expected=\"%s\", got=\"%s\"",
                ctx->section, ctx->key, ctx->value, i,
                args[i], ptr->argv.args[i]);
        }
    }

    if (ptr->argv.args[ALEN(args)] != NULL) {
        BUG("[%s].%s=%s: set value not the expected one: "
            "expected NULL terminator at arg #%zu, got=\"%s\"",
            ctx->section, ctx->key, ctx->value,
            ALEN(args), ptr->argv.args[ALEN(args)]);
    }

    /* Trigger parse failure */
    ctx->value = "command with \"unterminated quote";
    if (parse_fun(ctx)) {
        BUG("[%s].%s=%s: did not fail to parse as expected",
            ctx->section, ctx->key, ctx->value);
    }
}

static void
test_enum(struct context *ctx, bool (*parse_fun)(struct context *ctx),
          const char *key, size_t count, const char *enum_strings[static count],
          int enum_values[static count], int *ptr)
{
    ctx->key = key;

    for (size_t i = 0; i < count; i++) {
        ctx->value = enum_strings[i];
        if (!parse_fun(ctx)) {
            BUG("[%s].%s=%s: failed to parse",
                ctx->section, ctx->key, ctx->value);
        }

        if (*ptr != enum_values[i]) {
            BUG("[%s].%s=%s: set value not the expected one: expected %d, got %d",
                ctx->section, ctx->key, ctx->value, enum_values[i], *ptr);
        }
    }

    ctx->value = "invalid-enum-value";
    if (parse_fun(ctx)) {
        BUG("[%s].%s=%s: did not fail to parse as expected",
            ctx->section, ctx->key, ctx->value);
    }
}


static void
test_color(struct context *ctx, bool (*parse_fun)(struct context *ctx),
           const char *key, bool alpha_allowed, uint32_t *ptr)
{
    ctx->key = key;

    const struct {
        const char *option_string;
        uint32_t color;
        bool invalid;
    } input[] = {
        {"000000", 0},
        {"999999", 0x999999},
        {"ffffff", 0xffffff},
        {"ffffffff", 0xffffffff, !alpha_allowed},
        {"aabbccdd", 0xaabbccdd, !alpha_allowed},
        {"00", 0, true},
        {"0000", 0, true},
        {"00000", 0, true},
        {"000000000", 0, true},
        {"unittest-invalid-color", 0, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;
        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }

            uint32_t color = input[i].color;
            if (alpha_allowed && strlen(input[i].option_string) == 6)
                color |= 0xff000000;

            if (*ptr != color) {
                BUG("[%s].%s=%s: expected 0x%08x, got 0x%08x",
                    ctx->section, ctx->key, ctx->value,
                    color, *ptr);
            }
        }
    }
}

static void
test_two_colors(struct context *ctx, bool (*parse_fun)(struct context *ctx),
                const char *key, bool alpha_allowed,
                uint32_t *ptr1, uint32_t *ptr2)
{
    ctx->key = key;

    const struct {
        const char *option_string;
        uint32_t color1;
        uint32_t color2;
        bool invalid;
    } input[] = {
        {"000000 000000", 0, 0},

        /* No alpha */
        {"999999 888888", 0x999999, 0x888888},
        {"ffffff aaaaaa", 0xffffff, 0xaaaaaa},

        /* Both colors have alpha component */
        {"ffffffff 00000000", 0xffffffff, 0x00000000, !alpha_allowed},
        {"aabbccdd, ee112233", 0xaabbccdd, 0xee112233, !alpha_allowed},

        /* Only one color has alpha component */
        {"ffffffff 112233", 0xffffffff, 0x112233, !alpha_allowed},
        {"ffffff ff112233", 0x00ffffff, 0xff112233, !alpha_allowed},

        {"unittest-invalid-color", 0, 0, true},
    };

    for (size_t i = 0; i < ALEN(input); i++) {
        ctx->value = input[i].option_string;
        if (input[i].invalid) {
            if (parse_fun(ctx)) {
                BUG("[%s].%s=%s: did not fail to parse as expected",
                    ctx->section, ctx->key, ctx->value);
            }
        } else {
            if (!parse_fun(ctx)) {
                BUG("[%s].%s=%s: failed to parse",
                    ctx->section, ctx->key, ctx->value);
            }

            if (*ptr1 != input[i].color1) {
                BUG("[%s].%s=%s: expected 0x%08x, got 0x%08x",
                    ctx->section, ctx->key, ctx->value,
                    input[i].color1, *ptr1);
            }

            if (*ptr2 != input[i].color2) {
                BUG("[%s].%s=%s: expected 0x%08x, got 0x%08x",
                    ctx->section, ctx->key, ctx->value,
                    input[i].color2, *ptr2);
            }
        }
    }
}

static void
test_section_main(void)
{
    struct config conf = {0};
    struct context ctx = {.conf = &conf, .section = "main", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_main, "invalid-key");

    test_string(&ctx, &parse_section_main, "shell", &conf.shell);
    test_string(&ctx, &parse_section_main, "term", &conf.term);
    test_string(&ctx, &parse_section_main, "app-id", &conf.app_id);
    test_string(&ctx, &parse_section_main, "toplevel-tag", &conf.toplevel_tag);
    test_string(&ctx, &parse_section_main, "utmp-helper", &conf.utmp_helper_path);

    test_c32string(&ctx, &parse_section_main, "word-delimiters", &conf.word_delimiters);

    test_boolean(&ctx, &parse_section_main, "login-shell", &conf.login_shell);
    test_boolean(&ctx, &parse_section_main, "box-drawings-uses-font-glyphs", &conf.box_drawings_uses_font_glyphs);
    test_boolean(&ctx, &parse_section_main, "locked-title", &conf.locked_title);
    test_boolean(&ctx, &parse_section_main, "dpi-aware", &conf.dpi_aware);
    test_boolean(&ctx, &parse_section_main, "gamma-correct-blending", &conf.gamma_correct);
    test_boolean(&ctx, &parse_section_main, "uppercase-regex-insert", &conf.uppercase_regex_insert);

    test_pt_or_px(&ctx, &parse_section_main, "font-size-adjustment", &conf.font_size_adjustment.pt_or_px);  /* TODO: test ‘N%’ values too */
    test_pt_or_px(&ctx, &parse_section_main, "line-height", &conf.line_height);
    test_pt_or_px(&ctx, &parse_section_main, "letter-spacing", &conf.letter_spacing);
    test_pt_or_px(&ctx, &parse_section_main, "horizontal-letter-offset", &conf.horizontal_letter_offset);
    test_pt_or_px(&ctx, &parse_section_main, "vertical-letter-offset", &conf.vertical_letter_offset);
    test_pt_or_px(&ctx, &parse_section_main, "underline-thickness", &conf.underline_thickness);
    test_pt_or_px(&ctx, &parse_section_main, "strikeout-thickness", &conf.strikeout_thickness);

    test_uint16(&ctx, &parse_section_main, "resize-delay-ms", &conf.resize_delay_ms);
    test_uint16(&ctx, &parse_section_main, "workers", &conf.render_worker_count);

    test_enum(&ctx, &parse_section_main, "selection-target",
              4,
              (const char *[]){"none", "primary", "clipboard", "both"},
              (int []){SELECTION_TARGET_NONE,
                       SELECTION_TARGET_PRIMARY,
                       SELECTION_TARGET_CLIPBOARD,
                       SELECTION_TARGET_BOTH},
              (int *)&conf.selection_target);

    test_enum(
        &ctx, &parse_section_main, "initial-window-mode",
        3,
        (const char *[]){"windowed", "maximized", "fullscreen"},
        (int []){STARTUP_WINDOWED, STARTUP_MAXIMIZED, STARTUP_FULLSCREEN},
        (int *)&conf.startup_mode);

    test_enum(
        &ctx, &parse_section_main, "initial-color-theme",
        2,
        (const char *[]){"dark", "light", "1", "2"},
        (int []){COLOR_THEME_DARK, COLOR_THEME_LIGHT,
                 COLOR_THEME_DARK, COLOR_THEME_LIGHT},
        (int *)&conf.initial_color_theme);

    /* TODO: font (custom) */
    /* TODO: include (custom) */
    /* TODO: bold-text-in-bright (enum/boolean) */
    /* TODO: pad (geometry + optional string)*/
    /* TODO: initial-window-size-pixels (geometry) */
    /* TODO: initial-window-size-chars (geometry) */

    config_free(&conf);
}

static void
test_section_security(void)
{
    struct config conf = {0};
    struct context ctx = {.conf = &conf, .section = "security", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_security, "invalid-key");
    test_enum(
        &ctx, &parse_section_security, "osc52", 4,
        (const char*[]){"disabled", "copy-enabled", "paste-enabled", "enabled"},
        (int []){OSC52_DISABLED, OSC52_COPY_ENABLED, OSC52_PASTE_ENABLED, OSC52_ENABLED},
        (int *)&conf.security.osc52);

    config_free(&conf);
}

static void
test_section_bell(void)
{
    struct config conf = {0};
    struct context ctx = {.conf = &conf, .section = "bell", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_bell, "invalid-key");

    test_boolean(&ctx, &parse_section_bell, "urgent", &conf.bell.urgent);
    test_boolean(&ctx, &parse_section_bell, "notify", &conf.bell.notify);
    test_boolean(&ctx, &parse_section_bell, "system", &conf.bell.system_bell);
    test_boolean(&ctx, &parse_section_bell, "command-focused",
                 &conf.bell.command_focused);
    test_spawn_template(&ctx, &parse_section_bell, "command",
                        &conf.bell.command);

    config_free(&conf);
}

static void
test_section_desktop_notifications(void)
{
    struct config conf = {0};
    struct context ctx = {.conf = &conf, .section = "desktop-notifications", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_desktop_notifications, "invalid-key");

    test_boolean(&ctx, &parse_section_desktop_notifications, "inhibit-when-focused", &conf.desktop_notifications.inhibit_when_focused);
    test_spawn_template(&ctx, &parse_section_desktop_notifications, "command", &conf.desktop_notifications.command);
    test_spawn_template(&ctx, &parse_section_desktop_notifications, "command-action-argument", &conf.desktop_notifications.command_action_arg);
    test_spawn_template(&ctx, &parse_section_desktop_notifications, "close", &conf.desktop_notifications.close);

    config_free(&conf);
}

static void
test_section_scrollback(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "scrollback", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_scrollback, "invalid-key");

    test_uint32(&ctx, &parse_section_scrollback, "lines",
                &conf.scrollback.lines);
    test_float(&ctx, parse_section_scrollback, "multiplier", &conf.scrollback.multiplier);

    test_enum(
        &ctx, &parse_section_scrollback, "indicator-position",
        3,
        (const char *[]){"none", "fixed", "relative"},
        (int []){SCROLLBACK_INDICATOR_POSITION_NONE,
            SCROLLBACK_INDICATOR_POSITION_FIXED,
            SCROLLBACK_INDICATOR_POSITION_RELATIVE},
        (int *)&conf.scrollback.indicator.position);

    /* TODO: indicator-format (enum, sort-of) */

    config_free(&conf);
}

static void
test_section_url(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "url", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_url, "invalid-key");

    test_spawn_template(&ctx, &parse_section_url, "launch", &conf.url.launch);
    test_enum(&ctx, &parse_section_url, "osc8-underline",
              2,
              (const char *[]){"url-mode", "always"},
              (int []){OSC8_UNDERLINE_URL_MODE, OSC8_UNDERLINE_ALWAYS},
              (int *)&conf.url.osc8_underline);
    test_enum(&ctx, &parse_section_url, "style",
              6, (const char *[]){"none", "single", "double", "curly", "dotted", "dashed"},
              (int []){UNDERLINE_NONE, UNDERLINE_SINGLE, UNDERLINE_DOUBLE, UNDERLINE_CURLY, UNDERLINE_DOTTED, UNDERLINE_DASHED},
              (int *)&conf.url.style);
    test_c32string(&ctx, &parse_section_url, "label-letters", &conf.url.label_letters);

    config_free(&conf);
}

static void
test_section_cursor(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "cursor", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_cursor, "invalid-key");

    test_enum(
        &ctx, &parse_section_cursor, "style",
        3,
        (const char *[]){"block", "beam", "underline"},
        (int []){CURSOR_BLOCK, CURSOR_BEAM, CURSOR_UNDERLINE},
        (int *)&conf.cursor.style);
    test_enum(
        &ctx, &parse_section_cursor, "unfocused-style",
        3,
        (const char *[]){"unchanged", "hollow", "none"},
        (int []){CURSOR_UNFOCUSED_UNCHANGED, CURSOR_UNFOCUSED_HOLLOW, CURSOR_UNFOCUSED_NONE},
        (int *)&conf.cursor.unfocused_style);
    test_boolean(&ctx, &parse_section_cursor, "blink", &conf.cursor.blink.enabled);
    test_uint32(&ctx, &parse_section_cursor, "blink-rate", &conf.cursor.blink.rate_ms);
    test_pt_or_px(&ctx, &parse_section_cursor, "beam-thickness",
                  &conf.cursor.beam_thickness);
    test_pt_or_px(&ctx, &parse_section_cursor, "underline-thickness",
                  &conf.cursor.underline_thickness);

    /* TODO: color (two RRGGBB values) */

    config_free(&conf);
}

static void
test_section_mouse(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "mouse", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_mouse, "invalid-key");

    test_boolean(&ctx, &parse_section_mouse, "hide-when-typing",
                 &conf.mouse.hide_when_typing);
    test_boolean(&ctx, &parse_section_mouse, "alternate-scroll-mode",
                 &conf.mouse.alternate_scroll_mode);

    config_free(&conf);
}

static void
test_section_touch(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "touch", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_touch, "invalid-key");

    test_uint32(&ctx, &parse_section_touch, "long-press-delay",
                &conf.touch.long_press_delay);

    config_free(&conf);
}

static void
test_section_colors_dark(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "colors-dark", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_colors_dark, "invalid-key");

    test_color(&ctx, &parse_section_colors_dark, "foreground", false, &conf.colors_dark.fg);
    test_color(&ctx, &parse_section_colors_dark, "background", false, &conf.colors_dark.bg);
    test_color(&ctx, &parse_section_colors_dark, "regular0", false, &conf.colors_dark.table[0]);
    test_color(&ctx, &parse_section_colors_dark, "regular1", false, &conf.colors_dark.table[1]);
    test_color(&ctx, &parse_section_colors_dark, "regular2", false, &conf.colors_dark.table[2]);
    test_color(&ctx, &parse_section_colors_dark, "regular3", false, &conf.colors_dark.table[3]);
    test_color(&ctx, &parse_section_colors_dark, "regular4", false, &conf.colors_dark.table[4]);
    test_color(&ctx, &parse_section_colors_dark, "regular5", false, &conf.colors_dark.table[5]);
    test_color(&ctx, &parse_section_colors_dark, "regular6", false, &conf.colors_dark.table[6]);
    test_color(&ctx, &parse_section_colors_dark, "regular7", false, &conf.colors_dark.table[7]);
    test_color(&ctx, &parse_section_colors_dark, "bright0", false, &conf.colors_dark.table[8]);
    test_color(&ctx, &parse_section_colors_dark, "bright1", false, &conf.colors_dark.table[9]);
    test_color(&ctx, &parse_section_colors_dark, "bright2", false, &conf.colors_dark.table[10]);
    test_color(&ctx, &parse_section_colors_dark, "bright3", false, &conf.colors_dark.table[11]);
    test_color(&ctx, &parse_section_colors_dark, "bright4", false, &conf.colors_dark.table[12]);
    test_color(&ctx, &parse_section_colors_dark, "bright5", false, &conf.colors_dark.table[13]);
    test_color(&ctx, &parse_section_colors_dark, "bright6", false, &conf.colors_dark.table[14]);
    test_color(&ctx, &parse_section_colors_dark, "bright7", false, &conf.colors_dark.table[15]);
    test_color(&ctx, &parse_section_colors_dark, "dim0", false, &conf.colors_dark.dim[0]);
    test_color(&ctx, &parse_section_colors_dark, "dim1", false, &conf.colors_dark.dim[1]);
    test_color(&ctx, &parse_section_colors_dark, "dim2", false, &conf.colors_dark.dim[2]);
    test_color(&ctx, &parse_section_colors_dark, "dim3", false, &conf.colors_dark.dim[3]);
    test_color(&ctx, &parse_section_colors_dark, "dim4", false, &conf.colors_dark.dim[4]);
    test_color(&ctx, &parse_section_colors_dark, "dim5", false, &conf.colors_dark.dim[5]);
    test_color(&ctx, &parse_section_colors_dark, "dim6", false, &conf.colors_dark.dim[6]);
    test_color(&ctx, &parse_section_colors_dark, "dim7", false, &conf.colors_dark.dim[7]);
    test_color(&ctx, &parse_section_colors_dark, "selection-foreground", false, &conf.colors_dark.selection_fg);
    test_color(&ctx, &parse_section_colors_dark, "selection-background", false, &conf.colors_dark.selection_bg);
    test_color(&ctx, &parse_section_colors_dark, "urls", false, &conf.colors_dark.url);
    test_two_colors(&ctx, &parse_section_colors_dark, "jump-labels", false,
                    &conf.colors_dark.jump_label.fg,
                    &conf.colors_dark.jump_label.bg);
    test_two_colors(&ctx, &parse_section_colors_dark, "scrollback-indicator", false,
                    &conf.colors_dark.scrollback_indicator.fg,
                    &conf.colors_dark.scrollback_indicator.bg);
    test_two_colors(&ctx, &parse_section_colors_dark, "search-box-no-match", false,
                    &conf.colors_dark.search_box.no_match.fg,
                    &conf.colors_dark.search_box.no_match.bg);
    test_two_colors(&ctx, &parse_section_colors_dark, "search-box-match", false,
                    &conf.colors_dark.search_box.match.fg,
                    &conf.colors_dark.search_box.match.bg);

    test_two_colors(&ctx, &parse_section_colors_dark, "cursor", false,
                    &conf.colors_dark.cursor.text,
                    &conf.colors_dark.cursor.cursor);

    test_enum(&ctx, &parse_section_colors_dark, "alpha-mode", 3,
              (const char *[]){"default", "matching", "all"},
              (int []){ALPHA_MODE_DEFAULT, ALPHA_MODE_MATCHING, ALPHA_MODE_ALL},
              (int *)&conf.colors_dark.alpha_mode);

    test_enum(&ctx, &parse_section_colors_dark, "dim-blend-towards", 2,
              (const char *[]){"black", "white"},
              (int []){DIM_BLEND_TOWARDS_BLACK, DIM_BLEND_TOWARDS_WHITE},
              (int *)&conf.colors_dark.dim_blend_towards);

    for (size_t i = 0; i < 255; i++) {
        char key_name[4];
        sprintf(key_name, "%zu", i);
        test_color(&ctx, &parse_section_colors_dark, key_name, false,
                   &conf.colors_dark.table[i]);
    }

    test_boolean(&ctx, &parse_section_colors_dark, "blur", &conf.colors_dark.blur);

    test_invalid_key(&ctx, &parse_section_colors_dark, "256");

    /* TODO: alpha (float in range 0-1, converted to uint16_t) */

    config_free(&conf);
}

static void
test_section_colors_light(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "colors-light", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_colors_light, "invalid-key");

    test_color(&ctx, &parse_section_colors_light, "foreground", false, &conf.colors_light.fg);
    test_color(&ctx, &parse_section_colors_light, "background", false, &conf.colors_light.bg);
    test_color(&ctx, &parse_section_colors_light, "regular0", false, &conf.colors_light.table[0]);
    test_color(&ctx, &parse_section_colors_light, "regular1", false, &conf.colors_light.table[1]);
    test_color(&ctx, &parse_section_colors_light, "regular2", false, &conf.colors_light.table[2]);
    test_color(&ctx, &parse_section_colors_light, "regular3", false, &conf.colors_light.table[3]);
    test_color(&ctx, &parse_section_colors_light, "regular4", false, &conf.colors_light.table[4]);
    test_color(&ctx, &parse_section_colors_light, "regular5", false, &conf.colors_light.table[5]);
    test_color(&ctx, &parse_section_colors_light, "regular6", false, &conf.colors_light.table[6]);
    test_color(&ctx, &parse_section_colors_light, "regular7", false, &conf.colors_light.table[7]);
    test_color(&ctx, &parse_section_colors_light, "bright0", false, &conf.colors_light.table[8]);
    test_color(&ctx, &parse_section_colors_light, "bright1", false, &conf.colors_light.table[9]);
    test_color(&ctx, &parse_section_colors_light, "bright2", false, &conf.colors_light.table[10]);
    test_color(&ctx, &parse_section_colors_light, "bright3", false, &conf.colors_light.table[11]);
    test_color(&ctx, &parse_section_colors_light, "bright4", false, &conf.colors_light.table[12]);
    test_color(&ctx, &parse_section_colors_light, "bright5", false, &conf.colors_light.table[13]);
    test_color(&ctx, &parse_section_colors_light, "bright6", false, &conf.colors_light.table[14]);
    test_color(&ctx, &parse_section_colors_light, "bright7", false, &conf.colors_light.table[15]);
    test_color(&ctx, &parse_section_colors_light, "dim0", false, &conf.colors_light.dim[0]);
    test_color(&ctx, &parse_section_colors_light, "dim1", false, &conf.colors_light.dim[1]);
    test_color(&ctx, &parse_section_colors_light, "dim2", false, &conf.colors_light.dim[2]);
    test_color(&ctx, &parse_section_colors_light, "dim3", false, &conf.colors_light.dim[3]);
    test_color(&ctx, &parse_section_colors_light, "dim4", false, &conf.colors_light.dim[4]);
    test_color(&ctx, &parse_section_colors_light, "dim5", false, &conf.colors_light.dim[5]);
    test_color(&ctx, &parse_section_colors_light, "dim6", false, &conf.colors_light.dim[6]);
    test_color(&ctx, &parse_section_colors_light, "dim7", false, &conf.colors_light.dim[7]);
    test_color(&ctx, &parse_section_colors_light, "selection-foreground", false, &conf.colors_light.selection_fg);
    test_color(&ctx, &parse_section_colors_light, "selection-background", false, &conf.colors_light.selection_bg);
    test_color(&ctx, &parse_section_colors_light, "urls", false, &conf.colors_light.url);
    test_two_colors(&ctx, &parse_section_colors_light, "jump-labels", false,
                    &conf.colors_light.jump_label.fg,
                    &conf.colors_light.jump_label.bg);
    test_two_colors(&ctx, &parse_section_colors_light, "scrollback-indicator", false,
                    &conf.colors_light.scrollback_indicator.fg,
                    &conf.colors_light.scrollback_indicator.bg);
    test_two_colors(&ctx, &parse_section_colors_light, "search-box-no-match", false,
                    &conf.colors_light.search_box.no_match.fg,
                    &conf.colors_light.search_box.no_match.bg);
    test_two_colors(&ctx, &parse_section_colors_light, "search-box-match", false,
                    &conf.colors_light.search_box.match.fg,
                    &conf.colors_light.search_box.match.bg);

    test_two_colors(&ctx, &parse_section_colors_light, "cursor", false,
                    &conf.colors_light.cursor.text,
                    &conf.colors_light.cursor.cursor);

    test_enum(&ctx, &parse_section_colors_light, "alpha-mode", 3,
              (const char *[]){"default", "matching", "all"},
              (int []){ALPHA_MODE_DEFAULT, ALPHA_MODE_MATCHING, ALPHA_MODE_ALL},
              (int *)&conf.colors_light.alpha_mode);

    test_enum(&ctx, &parse_section_colors_light, "dim-blend-towards", 2,
              (const char *[]){"black", "white"},
              (int []){DIM_BLEND_TOWARDS_BLACK, DIM_BLEND_TOWARDS_WHITE},
              (int *)&conf.colors_light.dim_blend_towards);

    for (size_t i = 0; i < 255; i++) {
        char key_name[4];
        sprintf(key_name, "%zu", i);
        test_color(&ctx, &parse_section_colors_light, key_name, false,
                   &conf.colors_light.table[i]);
    }

    test_boolean(&ctx, &parse_section_colors_light, "blur", &conf.colors_light.blur);

    test_invalid_key(&ctx, &parse_section_colors_light, "256");

    /* TODO: alpha (float in range 0-1, converted to uint16_t) */

    config_free(&conf);
}

static void
test_section_csd(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "csd", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_csd, "invalid-key");

    test_enum(
        &ctx, &parse_section_csd, "preferred",
        3,
        (const char *[]){"none", "client", "server"},
        (int []){CONF_CSD_PREFER_NONE,
                 CONF_CSD_PREFER_CLIENT,
                 CONF_CSD_PREFER_SERVER},
        (int *)&conf.csd.preferred);
    test_uint16(&ctx, &parse_section_csd, "size", &conf.csd.title_height);
    test_color(&ctx, &parse_section_csd, "color", true, &conf.csd.color.title);
    test_uint16(&ctx, &parse_section_csd, "border-width",
                &conf.csd.border_width_visible);
    test_color(&ctx, &parse_section_csd, "border-color", true,
               &conf.csd.color.border);
    test_uint16(&ctx, &parse_section_csd, "button-width",
                &conf.csd.button_width);
    test_color(&ctx, &parse_section_csd, "button-color", true,
               &conf.csd.color.buttons);
    test_color(&ctx, &parse_section_csd, "button-minimize-color", true,
               &conf.csd.color.minimize);
    test_color(&ctx, &parse_section_csd, "button-maximize-color", true,
               &conf.csd.color.maximize);
    test_color(&ctx, &parse_section_csd, "button-close-color", true,
               &conf.csd.color.quit);
    test_boolean(&ctx, &parse_section_csd, "hide-when-maximized",
                 &conf.csd.hide_when_maximized);
    test_boolean(&ctx, &parse_section_csd, "double-click-to-maximize",
                 &conf.csd.double_click_to_maximize);

    /* TODO: verify the ‘set’ bit is actually set for colors */
    /* TODO: font */

    config_free(&conf);
}

static bool
have_modifier(const config_modifier_list_t *mods, const char *mod)
{
    tll_foreach(*mods, it) {
        if (strcmp(it->item, mod) == 0)
            return true;
    }

    return false;
}

static void
test_key_binding(struct context *ctx, bool (*parse_fun)(struct context *ctx),
                 int action, int max_action, int map_kind,
                 struct config_key_binding_list *bindings,
                 enum key_binding_type type, bool need_argv, bool need_section_id)
{
    xassert(config_action_map_name(map_kind, action) != NULL);
    xassert(bindings->count == 0);

    const char *key = config_action_map_name(map_kind, action);

    /* “Randomize” which modifiers to enable */
    const bool ctrl = action % 2;
    const bool alt = action % 3;
    const bool shift = action % 4;
    const bool super = action % 5;
    const bool argv = need_argv;
    const bool section_id = need_section_id;

    xassert(!(argv && section_id));

    static const char *const args[] = {
        "command", "arg1", "arg2", "arg3 has spaces"};

    /* Generate the modifier part of the ‘value’ */
    char modifier_string[32];
    sprintf(modifier_string, "%s%s%s%s",
            ctrl ? XKB_MOD_NAME_CTRL "+" : "",
            alt ? XKB_MOD_NAME_ALT "+" : "",
            shift ? XKB_MOD_NAME_SHIFT "+" : "",
            super ? XKB_MOD_NAME_LOGO "+" : "");

    /* Use a unique symbol for this action (key bindings) */
    const xkb_keysym_t sym = XKB_KEY_a + action;

    /* Mouse button (mouse bindings) */
    const int button_idx = action % config_button_map_len();
    const int button = config_button_map_code(button_idx);
    const int click_count = action % 3 + 1;

    /* Finally, generate the ‘value’ (e.g. “Control+shift+x”) */
    char value[128] = {0};

    ctx->key = key;
    ctx->value = value;

    /* First, try setting the empty string */
    if (parse_fun(ctx)) {
        BUG("[%s].%s=<empty>: did not fail to parse as expected",
            ctx->section, ctx->key);
    }

    switch (type) {
    case KEY_BINDING: {
        char sym_name[16];
        xkb_keysym_get_name(sym, sym_name, sizeof(sym_name));

        snprintf(value, sizeof(value), "%s%s%s",
                 argv ? "[command arg1 arg2 \"arg3 has spaces\"] " : section_id ? "[foobar]" : "",
                 modifier_string, sym_name);
        break;
    }

    case MOUSE_BINDING: {
        const char *const button_name = config_button_map_name(button_idx);
        int chars = snprintf(
            value, sizeof(value), "%s%s%s",
            argv ? "[command arg1 arg2 \"arg3 has spaces\"] " : section_id ? "[foobar]" : "",
            modifier_string, button_name);

        xassert(click_count > 0);
        if (click_count > 1)
            snprintf(&value[chars], sizeof(value) - chars, "-%d", click_count);
        break;
    }
    }

    if (!parse_fun(ctx)) {
        BUG("[%s].%s=%s failed to parse",
            ctx->section, ctx->key, ctx->value);
    }

    const struct config_key_binding *binding =
        &bindings->arr[bindings->count - 1];

    if (argv) {
        if (binding->aux.pipe.args == NULL) {
            BUG("[%s].%s=%s: pipe argv is NULL",
                ctx->section, ctx->key, ctx->value);
        }

        for (size_t i = 0; i < ALEN(args); i++) {
            if (binding->aux.pipe.args[i] == NULL ||
                !streq(binding->aux.pipe.args[i], args[i]))
            {
                BUG("[%s].%s=%s: pipe argv not the expected one: "
                    "mismatch of arg #%zu: expected=\"%s\", got=\"%s\"",
                    ctx->section, ctx->key, ctx->value, i,
                    args[i], binding->aux.pipe.args[i]);
            }
        }

        if (binding->aux.pipe.args[ALEN(args)] != NULL) {
            BUG("[%s].%s=%s: pipe argv not the expected one: "
                "expected NULL terminator at arg #%zu, got=\"%s\"",
                ctx->section, ctx->key, ctx->value,
                ALEN(args), binding->aux.pipe.args[ALEN(args)]);
        }
    } else if (section_id) {
        if (binding->aux.regex_name == NULL) {
            BUG("[%s].%s=%s: regex name is NULL",
                ctx->section, ctx->key, ctx->value);
        }

        if (!streq(binding->aux.regex_name, "foobar")) {
            BUG("[%s].%s=%s: regex name not the expected one: "
                "expected=\"%s\", got=\"%s\"",
                ctx->section, ctx->key, ctx->value,
                "foobar", binding->aux.regex_name);
        }
    } else {
        if (binding->aux.pipe.args != NULL) {
            BUG("[%s].%s=%s: pipe argv not NULL",
                ctx->section, ctx->key, ctx->value);
        }
    }

    if (binding->action != action) {
        BUG("[%s].%s=%s: action mismatch: %d != %d",
            ctx->section, ctx->key, ctx->value, binding->action, action);
    }

    bool have_ctrl = have_modifier(&binding->modifiers, XKB_MOD_NAME_CTRL);
    bool have_alt = have_modifier(&binding->modifiers, XKB_MOD_NAME_ALT);
    bool have_shift = have_modifier(&binding->modifiers, XKB_MOD_NAME_SHIFT);
    bool have_super = have_modifier(&binding->modifiers, XKB_MOD_NAME_LOGO);

    if (have_ctrl != ctrl || have_alt != alt ||
        have_shift != shift || have_super != super)
    {
        BUG("[%s].%s=%s: modifier mismatch:\n"
            "  have:     ctrl=%d, alt=%d, shift=%d, super=%d\n"
            "  expected: ctrl=%d, alt=%d, shift=%d, super=%d",
            ctx->section, ctx->key, ctx->value,
            have_ctrl, have_alt, have_shift, have_super,
            ctrl, alt, shift, super);
    }

    switch (type) {
    case KEY_BINDING:
        if (binding->k.sym != sym) {
            BUG("[%s].%s=%s: key symbol mismatch: %d != %d",
                ctx->section, ctx->key, ctx->value, binding->k.sym, sym);
        }
        break;

    case MOUSE_BINDING:;
        if (binding->m.button != button) {
            BUG("[%s].%s=%s: mouse button mismatch: %d != %d",
                ctx->section, ctx->key, ctx->value, binding->m.button, button);
        }

        if (binding->m.count != click_count) {
            BUG("[%s].%s=%s: mouse button click count mismatch: %d != %d",
                ctx->section, ctx->key, ctx->value,
                binding->m.count, click_count);
        }
        break;
    }


    free_key_binding_list(bindings);
}

enum collision_test_mode {
    FAIL_DIFFERENT_ACTION,
    FAIL_DIFFERENT_ARGV,
    FAIL_MOUSE_OVERRIDE,
    SUCCEED_SAME_ACTION_AND_ARGV,
};

static void
_test_binding_collisions(struct context *ctx,
                         int max_action, int map_kind,
                         enum key_binding_type type,
                         enum collision_test_mode test_mode)
{
    struct config_key_binding *bindings_array =
        xcalloc(2, sizeof(bindings_array[0]));

    struct config_key_binding_list bindings = {
        .count = 2,
        .arr = bindings_array,
    };

    /* First, verify we get a collision when trying to assign the same
     * key combo to multiple actions */
    bindings.arr[0] = (struct config_key_binding){
        .action = (test_mode == FAIL_DIFFERENT_ACTION
                   ? max_action - 1 : max_action),
        .modifiers = tll_init(),
        .path = "unittest",
    };
    tll_push_back(bindings.arr[0].modifiers, xstrdup(XKB_MOD_NAME_CTRL));

    bindings.arr[1] = (struct config_key_binding){
        .action = max_action,
        .modifiers = tll_init(),
        .path = "unittest",
    };
    tll_push_back(bindings.arr[1].modifiers, xstrdup(XKB_MOD_NAME_CTRL));

    switch (type) {
    case KEY_BINDING:
        bindings.arr[0].k.sym = XKB_KEY_a;
        bindings.arr[1].k.sym = XKB_KEY_a;
        break;

    case MOUSE_BINDING:
        bindings.arr[0].m.button = BTN_LEFT;
        bindings.arr[0].m.count = 1;
        bindings.arr[1].m.button = BTN_LEFT;
        bindings.arr[1].m.count = 1;
        break;
    }

    switch (test_mode) {
    case FAIL_DIFFERENT_ACTION:
        break;

    case FAIL_MOUSE_OVERRIDE:
        tll_free_and_free(ctx->conf->mouse.selection_override_modifiers, free);
        tll_push_back(ctx->conf->mouse.selection_override_modifiers, xstrdup(XKB_MOD_NAME_CTRL));
        break;

    case FAIL_DIFFERENT_ARGV:
    case SUCCEED_SAME_ACTION_AND_ARGV:
        bindings.arr[0].aux.type = BINDING_AUX_PIPE;
        bindings.arr[0].aux.master_copy = true;
        bindings.arr[0].aux.pipe.args = xcalloc(
            4, sizeof(bindings.arr[0].aux.pipe.args[0]));
        bindings.arr[0].aux.pipe.args[0] = xstrdup("/usr/bin/foobar");
        bindings.arr[0].aux.pipe.args[1] = xstrdup("hello");
        bindings.arr[0].aux.pipe.args[2] = xstrdup("world");

        bindings.arr[1].aux.type = BINDING_AUX_PIPE;
        bindings.arr[1].aux.master_copy = true;
        bindings.arr[1].aux.pipe.args = xcalloc(
            4, sizeof(bindings.arr[1].aux.pipe.args[0]));
        bindings.arr[1].aux.pipe.args[0] = xstrdup("/usr/bin/foobar");
        bindings.arr[1].aux.pipe.args[1] = xstrdup("hello");

        if (test_mode == SUCCEED_SAME_ACTION_AND_ARGV)
            bindings.arr[1].aux.pipe.args[2] = xstrdup("world");
        break;
    }

    bool expected_result =
        test_mode == SUCCEED_SAME_ACTION_AND_ARGV ? true : false;

    if (config_resolve_key_binding_collisions(
            ctx->conf, ctx->section, map_kind, &bindings, type) != expected_result)
    {
        BUG("[%s].%s vs. %s: %s",
            ctx->section,
            config_action_map_name(map_kind, max_action - 1),
            config_action_map_name(map_kind, max_action),
            (expected_result == true
             ? "invalid key combo collision detected"
             : "key combo collision not detected"));
    }

    if (expected_result == false) {
        if (bindings.count != 1)
            BUG("[%s]: colliding binding not removed", ctx->section);

        if (bindings.arr[0].action !=
            (test_mode == FAIL_DIFFERENT_ACTION ? max_action - 1 : max_action))
        {
            BUG("[%s]: wrong binding removed", ctx->section);
        }
    }

    free_key_binding_list(&bindings);
}

static void
test_binding_collisions(struct context *ctx,
                         int max_action, int map_kind,
                        enum key_binding_type type)
{
    _test_binding_collisions(ctx, max_action, map_kind, type, FAIL_DIFFERENT_ACTION);
    _test_binding_collisions(ctx, max_action, map_kind, type, FAIL_DIFFERENT_ARGV);
    _test_binding_collisions(ctx, max_action, map_kind, type, SUCCEED_SAME_ACTION_AND_ARGV);

    if (type == MOUSE_BINDING) {
        _test_binding_collisions(
            ctx, max_action, map_kind, type, FAIL_MOUSE_OVERRIDE);
    }
}

static void
test_section_key_bindings(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "key-bindings", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_key_bindings, "invalid-key");

    for (int action = 0; action < BIND_ACTION_KEY_COUNT; action++) {
        if (config_action_map_name(MAP_KIND_KEY, action) == NULL)
            continue;

        test_key_binding(
            &ctx, &parse_section_key_bindings,
            action, BIND_ACTION_KEY_COUNT - 1,
            MAP_KIND_KEY, &conf.bindings.key, KEY_BINDING,
            action >= BIND_ACTION_PIPE_SCROLLBACK && action <= BIND_ACTION_PIPE_COMMAND_OUTPUT,
            action >= BIND_ACTION_REGEX_LAUNCH && action <= BIND_ACTION_REGEX_COPY);
    }

    config_free(&conf);
}

/* Ported from the config.c UNITTEST that went away with the C
 * parse_key_binding_section(): add, multi-combo, replace and unmap. */
static void
test_key_binding_sequences(void)
{
    struct config conf = {0};
    struct config_key_binding_list *bindings = &conf.bindings.key;
    struct context ctx = {
        .conf = &conf, .section = "key-bindings", .path = "unittest"};

    /* ADD noop=Escape */
    ctx.key = "noop";
    ctx.value = "Escape";
    xassert(parse_section_key_bindings(&ctx));
    xassert(bindings->count == 1);
    xassert(bindings->arr[0].action == BIND_ACTION_NOOP);
    xassert(bindings->arr[0].k.sym == XKB_KEY_Escape);

    /* ADD quit=Control+g Control+Shift+x */
    ctx.key = "quit";
    ctx.value = "Control+g Control+Shift+x";
    xassert(parse_section_key_bindings(&ctx));
    xassert(bindings->count == 3);
    xassert(bindings->arr[1].action == BIND_ACTION_QUIT);
    xassert(bindings->arr[1].k.sym == XKB_KEY_g);
    xassert(tll_length(bindings->arr[1].modifiers) == 1);
    xassert(strcmp(tll_front(bindings->arr[1].modifiers), XKB_MOD_NAME_CTRL) == 0);
    xassert(bindings->arr[2].action == BIND_ACTION_QUIT);
    xassert(bindings->arr[2].k.sym == XKB_KEY_x);
    xassert(tll_length(bindings->arr[2].modifiers) == 2);
    xassert(strcmp(tll_front(bindings->arr[2].modifiers), XKB_MOD_NAME_CTRL) == 0);
    xassert(strcmp(tll_back(bindings->arr[2].modifiers), XKB_MOD_NAME_SHIFT) == 0);

    /* REPLACE noop with two combos */
    ctx.key = "noop";
    ctx.value = "Mod1+v Shift+q";
    xassert(parse_section_key_bindings(&ctx));
    xassert(bindings->count == 4);
    xassert(bindings->arr[2].action == BIND_ACTION_NOOP);
    xassert(bindings->arr[2].k.sym == XKB_KEY_v);
    xassert(bindings->arr[3].action == BIND_ACTION_NOOP);
    xassert(bindings->arr[3].k.sym == XKB_KEY_q);

    /* REMOVE quit (only that action) */
    ctx.key = "quit";
    ctx.value = "none";
    xassert(parse_section_key_bindings(&ctx));
    xassert(bindings->count == 2);
    xassert(bindings->arr[0].action == BIND_ACTION_NOOP);
    xassert(bindings->arr[1].action == BIND_ACTION_NOOP);

    /* REMOVE noop */
    ctx.key = "noop";
    ctx.value = "none";
    xassert(parse_section_key_bindings(&ctx));
    xassert(bindings->count == 0);

    config_free(&conf);
}

static void
test_section_key_bindings_collisions(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "key-bindings", .path = "unittest"};

    test_binding_collisions(
        &ctx, BIND_ACTION_KEY_COUNT - 1, MAP_KIND_KEY, KEY_BINDING);

    config_free(&conf);
}

static void
test_section_search_bindings(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "search-bindings", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_search_bindings, "invalid-key");

    for (int action = 0; action < BIND_ACTION_SEARCH_COUNT; action++) {
        if (config_action_map_name(MAP_KIND_SEARCH, action) == NULL)
            continue;

        test_key_binding(
            &ctx, &parse_section_search_bindings,
            action, BIND_ACTION_SEARCH_COUNT - 1,
            MAP_KIND_SEARCH, &conf.bindings.search, KEY_BINDING,
            false, false);
    }

    config_free(&conf);
}

static void
test_section_search_bindings_collisions(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "search-bindings", .path = "unittest"};

    test_binding_collisions(
        &ctx,
        BIND_ACTION_SEARCH_COUNT - 1, MAP_KIND_SEARCH, KEY_BINDING);

    config_free(&conf);
}

static void
test_section_url_bindings(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "rul-bindings", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_url_bindings, "invalid-key");

    for (int action = 0; action < BIND_ACTION_URL_COUNT; action++) {
        if (config_action_map_name(MAP_KIND_URL, action) == NULL)
            continue;

        test_key_binding(
            &ctx, &parse_section_url_bindings,
            action, BIND_ACTION_URL_COUNT - 1,
            MAP_KIND_URL, &conf.bindings.url, KEY_BINDING,
            false, false);
    }

    config_free(&conf);
}

static void
test_section_url_bindings_collisions(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "url-bindings", .path = "unittest"};

    test_binding_collisions(
        &ctx,
        BIND_ACTION_URL_COUNT - 1, MAP_KIND_URL, KEY_BINDING);

    config_free(&conf);
}

static void
test_section_mouse_bindings(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "mouse-bindings", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_mouse_bindings, "invalid-key");

    for (int action = 0; action < BIND_ACTION_COUNT; action++) {
        if (config_action_map_name(MAP_KIND_KEY, action) == NULL)
            continue;

        test_key_binding(
            &ctx, &parse_section_mouse_bindings,
            action, BIND_ACTION_COUNT - 1,
            MAP_KIND_KEY, &conf.bindings.mouse, MOUSE_BINDING,
            false, false);
    }

    config_free(&conf);
}

static void
test_section_mouse_bindings_collisions(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "mouse-bindings", .path = "unittest"};

    test_binding_collisions(
        &ctx,
        BIND_ACTION_COUNT - 1, MAP_KIND_KEY, MOUSE_BINDING);

    config_free(&conf);
}

static void
test_section_text_bindings(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "text-bindings", .path = "unittest"};

    ctx.key = "abcd";
    ctx.value = XKB_MOD_NAME_CTRL "+" XKB_MOD_NAME_SHIFT "+x";
    xassert(parse_section_text_bindings(&ctx));

    ctx.key = "\\x07";
    xassert(parse_section_text_bindings(&ctx));

    ctx.key = "\\x1g";
    xassert(!parse_section_text_bindings(&ctx));

    ctx.key = "\\x1";
    xassert(!parse_section_text_bindings(&ctx));

    ctx.key = "\\x";
    xassert(!parse_section_text_bindings(&ctx));

    ctx.key = "\\";
    xassert(!parse_section_text_bindings(&ctx));

    ctx.key = "\\y";
    xassert(!parse_section_text_bindings(&ctx));

#if 0
    /* Invalid modifier and key names are detected later, when a
     * layout is applied */
    ctx.key = "abcd";
    ctx.value = "InvalidMod+y";
    xassert(!parse_section_text_bindings(&ctx));
#endif
    config_free(&conf);
}

static void
test_section_environment(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "environment", .path = "unittest"};

    /* A single variable */
    ctx.key = "FOO";
    ctx.value = "bar";
    xassert(parse_section_environment(&ctx));
    xassert(tll_length(conf.env_vars) == 1);
    xassert(streq(tll_front(conf.env_vars).name, "FOO"));
    xassert(streq(tll_front(conf.env_vars).value, "bar"));

    /* Add a second variable */
    ctx.key = "BAR";
    ctx.value = "123";
    xassert(parse_section_environment(&ctx));
    xassert(tll_length(conf.env_vars) == 2);
    xassert(streq(tll_back(conf.env_vars).name, "BAR"));
    xassert(streq(tll_back(conf.env_vars).value, "123"));

    /* Replace the *value* of the first variable */
    ctx.key = "FOO";
    ctx.value = "456";
    xassert(parse_section_environment(&ctx));
    xassert(tll_length(conf.env_vars) == 2);
    xassert(streq(tll_front(conf.env_vars).name, "FOO"));
    xassert(streq(tll_front(conf.env_vars).value, "456"));
    xassert(streq(tll_back(conf.env_vars).name, "BAR"));
    xassert(streq(tll_back(conf.env_vars).value, "123"));

    config_free(&conf);
}

static void
test_section_tweak(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "tweak", .path = "unittest"};

    test_invalid_key(&ctx, &parse_section_tweak, "invalid-key");

    test_enum(
        &ctx, &parse_section_tweak, "scaling-filter",
        5,
        (const char *[]){"none", "nearest", "bilinear", "cubic", "lanczos3"},
        (int []){FCFT_SCALING_FILTER_NONE,
                 FCFT_SCALING_FILTER_NEAREST,
                 FCFT_SCALING_FILTER_BILINEAR,
                 FCFT_SCALING_FILTER_CUBIC,
                 FCFT_SCALING_FILTER_LANCZOS3},
        (int *)&conf.tweak.fcft_filter);

    test_boolean(&ctx, &parse_section_tweak, "overflowing-glyphs",
                 &conf.tweak.overflowing_glyphs);

    test_enum(
        &ctx, &parse_section_tweak, "render-timer",
        4,
        (const char *[]){"none", "osd", "log", "both"},
        (int []){RENDER_TIMER_NONE,
                 RENDER_TIMER_OSD,
                 RENDER_TIMER_LOG,
                 RENDER_TIMER_BOTH},
        (int *)&conf.tweak.render_timer);

    test_float(&ctx, &parse_section_tweak, "box-drawing-base-thickness",
                &conf.tweak.box_drawing_base_thickness);
    test_boolean(&ctx, &parse_section_tweak, "box-drawing-solid-shades",
        &conf.tweak.box_drawing_solid_shades);

#if 0  /* Must be less than 16ms */
    test_uint32(&ctx, &parse_section_tweak, "delayed-render-lower",
                &conf.tweak.delayed_render_lower_ns);
    test_uint32(&ctx, &parse_section_tweak, "delayed-render-upper",
                &conf.tweak.delayed_render_upper_ns);
#endif
    test_boolean(&ctx, &parse_section_tweak, "damage-whole-window",
                 &conf.tweak.damage_whole_window);

#if defined(FOOT_GRAPHEME_CLUSTERING)
    test_boolean(&ctx, &parse_section_tweak, "grapheme-shaping",
                 &conf.tweak.grapheme_shaping);
#else
    /* TODO: the setting still exists, but is always forced to ‘false’. */
#endif

    test_enum(
        &ctx, &parse_section_tweak, "grapheme-width-method",
        3,
        (const char *[]){"wcswidth", "double-width", "max"},
        (int []){GRAPHEME_WIDTH_WCSWIDTH,
                 GRAPHEME_WIDTH_DOUBLE,
                 GRAPHEME_WIDTH_MAX},
        (int *)&conf.tweak.grapheme_width_method);

    test_boolean(&ctx, &parse_section_tweak, "font-monospace-warn",
                 &conf.tweak.font_monospace_warn);

    test_float(&ctx, &parse_section_tweak, "bold-text-in-bright-amount",
               &conf.bold_in_bright.amount);

    test_uint32(&ctx, &parse_section_tweak, "min-stride-alignment",
                &conf.tweak.min_stride_alignment);

#if 0 /* Must be equal to, or less than INT32_MAX */
    test_uint32(&ctx, &parse_section_tweak, "max-shm-pool-size-mb",
                &conf.tweak.max_shm_pool_size);
#endif

    config_free(&conf);
}

/*
 * The default URL regex (C2m).
 *
 * This used to be a UNITTEST in config.c; it followed the string into
 * config.zig, where the UNITTEST framework does not reach, so it lives here
 * with the rest of the oracle.
 */

static void
check_url_match(const char *url, const char *expected_match, regmatch_t match)
{
    const size_t mlen = match.rm_eo - match.rm_so;
    const size_t start = &url[match.rm_so] - url;

    if (mlen != strlen(expected_match) ||
        memcmp(&url[start], expected_match, mlen) != 0)
    {
        BUG("url: %s\n"
            "  expected match: %s\n"
            "  match:          %.*s",
            url, expected_match, (int)mlen, &url[start]);
    }
}

static void
test_default_url_regex(void)
{
    const char *regex = config_default_url_regex_string();
    regex_t re;
    int r = regcomp(&re, regex, REG_EXTENDED);
    xassert(r == 0);
    xassert(re.re_nsub >= 1);

    static const struct {
        const char *url;
        const char *expected_match;
    } test_cases[] = {
        {"https://www.foobar.com/[a](b)\"c\"'d'efg.html?foo=bar&bar=foo",
         "https://www.foobar.com/[a](b)\"c\"'d'efg.html?foo=bar&bar=foo"},

        /* Trailing quotes are not matched */
        {"https://quote-at-the-end'", "https://quote-at-the-end"},
        {"https://quote-at-the-end\"", "https://quote-at-the-end"},

        /* That includes quoted URLs too */
        {"'https://quote-at-the-end''", "https://quote-at-the-end"},
        {"\"https://quote-at-the-end\"\"", "https://quote-at-the-end"},

        /* Allow '-quotes in the middle */
        {"https://unbalanced'not-at-the-end",
         "https://unbalanced'not-at-the-end"},

        /* But not "-quotes */
        {"https://unbalanced\"not-at-the-end", "https://unbalanced"},

        /* "Balanced" quotes are allowed, at the end... */
        {"https://balanced-'quote'", "https://balanced-'quote'"},

        /* ... and in the middle */
        {"https://balanced-'quote'-in-the-middle",
         "https://balanced-'quote'-in-the-middle"},

        /* Balanced "-quotes too */
        {"https://balanced-\"quote\"", "https://balanced-\"quote\""},
        {"https://balanced-\"quote\"-in-the-middle",
         "https://balanced-\"quote\"-in-the-middle"},

        /* Quoted URLs should match the URL part, not the quotes */
        {"'https://quoted-url'", "https://quoted-url"},
        {"\"https://quoted-url\"", "https://quoted-url"},
        {"\"https://quoted-url-with-'-inside\"",
         "https://quoted-url-with-'-inside"},

        {"'https://abc' foobar", "https://abc"},

        {"https://foo[bar", "https://foo"},
        {"https://foo[]bar", "https://foo"},
        {"https://foo[abc]", "https://foo[abc]"},
        {"https://foo[abc]bar", "https://foo[abc]bar"},

        {"https://foo(bar", "https://foo"},
        {"https://foo()bar", "https://foo"},
        {"https://foo(abc)", "https://foo(abc)"},
        {"https://foo(abc)bar", "https://foo(abc)bar"},

        {"https://foo{bar", "https://foo"},
        {"https://foo{}bar", "https://foo"},
        {"https://foo{abc}bar", "https://foo"},
    };

    for (size_t i = 0; i < ALEN(test_cases); i++) {
        const char *const url = test_cases[i].url;
        const char *const expected_match = test_cases[i].expected_match;

        regmatch_t matches[8] = {0};
        int m = regexec(&re, url, ALEN(matches), matches, 0);
        xassert(m == 0);
        check_url_match(url, expected_match, matches[1]);
    }

    regfree(&re);
}

/*
 * config_load() / config_clone() / config_free() (C2m, C2n).
 *
 * This is the old UNITTEST from config.c, widened: the clone used to be
 * commented out there, and every default config_load() assigns is now
 * checked, since the assignments were re-typed by hand.
 */

static void
test_config_load(void)
{
    struct config original;
    user_notifications_t nots = tll_init();
    config_override_t overrides = tll_init();

    xassert(config_load(&original, "/dev/null", &nots, &overrides, false, false));

    /* [main] defaults */
    xassert(strcmp(original.term, FOOT_DEFAULT_TERM) == 0);
    xassert(strcmp(original.title, "foot") == 0);
    xassert(strcmp(original.app_id, "foot") == 0);
    xassert(original.size.type == CONF_SIZE_PX);
    xassert(original.size.width == 700);
    xassert(original.size.height == 500);
    xassert(original.center_when == CENTER_MAXIMIZED_AND_FULLSCREEN);
    xassert(original.resize_by_cells);
    xassert(original.resize_keep_grid);
    xassert(original.resize_delay_ms == 100);
    xassert(original.startup_mode == STARTUP_WINDOWED);
    xassert(original.dpi_aware == false);
    xassert(original.uppercase_regex_insert);

    /* colours: the 256-entry table is the part most likely to be mistyped */
    xassert(original.colors_dark.fg == 0xffffff);
    xassert(original.colors_dark.bg == 0x242424);
    xassert(original.colors_dark.table[0] == 0x242424);
    xassert(original.colors_dark.table[16] == 0x000000);
    xassert(original.colors_dark.table[17] == 0x00005f);
    xassert(original.colors_dark.table[231] == 0xffffff);
    xassert(original.colors_dark.table[232] == 0x080808);
    xassert(original.colors_dark.sixel[1] == 0xff3333cc);
    xassert(original.colors_dark.dim_blend_towards == DIM_BLEND_TOWARDS_BLACK);
    xassert(original.colors_light.dim_blend_towards == DIM_BLEND_TOWARDS_WHITE);
    xassert(original.initial_color_theme == COLOR_THEME_DARK);

    /* [tweak]: lanchoz3, 256-byte stride alignment, half a 60Hz frame */
    xassert(original.tweak.fcft_filter == FCFT_SCALING_FILTER_LANCZOS3);
    xassert(original.tweak.min_stride_alignment == 256);
    xassert(original.tweak.delayed_render_upper_ns == 16666666 / 2);
    xassert(original.tweak.max_shm_pool_size == 512 * 1024 * 1024);
    xassert(original.tweak.sixel);
    xassert(original.touch.long_press_delay == 400);

    /* command lines tokenized from the built-in templates */
    xassert(original.url.launch.argv.args != NULL);
    xassert(strcmp(original.url.launch.argv.args[0], "xdg-open") == 0);
    xassert(original.desktop_notifications.command.argv.args != NULL);
    xassert(strcmp(original.desktop_notifications.command.argv.args[0],
                   "notify-send") == 0);
    xassert(original.url.regex != NULL);
    xassert(strcmp(original.url.regex, config_default_url_regex_string()) == 0);
    xassert(original.mouse.selection_override_modifiers.length == 1);

    /* defaults that depend on the environment / on other defaults */
    xassert(original.shell != NULL);
    xassert(original.fonts[0].count == 1);
    xassert(strcmp(original.fonts[0].arr[0].pattern, "monospace") == 0);
    xassert(original.csd.font.count == 1);
    xassert(original.bindings.key.count > 0);
    xassert(original.bindings.search.count > 0);
    xassert(original.bindings.url.count > 0);
    xassert(original.bindings.mouse.count > 0);

    /*
     * Binding aux ownership. A multi-combo pipe binding allocates the argv
     * once (master_copy) and the following combos alias it; config_clone()
     * must reproduce exactly that, or config_free() frees the same argv
     * twice. Same for a [regex] name.
     */
    struct context ctx = {
        .conf = &original, .section = "key-bindings", .path = "unittest"};
    const size_t n_key = original.bindings.key.count;

    ctx.key = "pipe-visible";
    ctx.value = "[sh -c echo hi] Mod1+v Mod1+b";
    xassert(parse_section_key_bindings(&ctx));

    ctx.key = "regex-launch";
    ctx.value = "[my-regex] Mod1+r Mod1+n";
    xassert(parse_section_key_bindings(&ctx));

    xassert(original.bindings.key.count == n_key + 4);
    xassert(original.bindings.key.arr[n_key].aux.master_copy);
    xassert(!original.bindings.key.arr[n_key + 1].aux.master_copy);
    xassert(original.bindings.key.arr[n_key + 2].aux.master_copy);
    xassert(!original.bindings.key.arr[n_key + 3].aux.master_copy);

    struct config *clone = config_clone(&original);
    xassert(clone != NULL);
    xassert(clone != &original);

    /* deep copy: every pointer must be a different allocation... */
    xassert(clone->term != original.term);
    xassert(clone->word_delimiters != original.word_delimiters);
    xassert(clone->url.regex != original.url.regex);
    xassert(clone->fonts[0].arr != original.fonts[0].arr);
    xassert(clone->bindings.key.arr != original.bindings.key.arr);
    xassert(clone->bindings.key.arr[0].modifiers.head !=
            original.bindings.key.arr[0].modifiers.head);
    /* ...holding the same values */
    xassert(strcmp(clone->term, original.term) == 0);
    xassert(clone->colors_dark.table[17] == original.colors_dark.table[17]);
    xassert(clone->bindings.key.count == original.bindings.key.count);
    xassert(clone->bindings.mouse.count == original.bindings.mouse.count);
    xassert(clone->fonts[0].count == original.fonts[0].count);
    xassert(clone->mouse.selection_override_modifiers.length == 1);
    xassert(clone->env_vars.length == original.env_vars.length);

    /* The master-copy alias must point *into the clone*. */
    xassert(clone->bindings.key.arr[n_key + 1].aux.pipe.args ==
            clone->bindings.key.arr[n_key].aux.pipe.args);
    xassert(clone->bindings.key.arr[n_key].aux.pipe.args !=
            original.bindings.key.arr[n_key].aux.pipe.args);
    xassert(clone->bindings.key.arr[n_key + 3].aux.regex_name ==
            clone->bindings.key.arr[n_key + 2].aux.regex_name);
    xassert(clone->bindings.key.arr[n_key + 2].aux.regex_name !=
            original.bindings.key.arr[n_key + 2].aux.regex_name);

    /* Both must be separately freeable (share nothing). */
    config_free(clone);
    free(clone);
    config_free(&original);

    tll_free(overrides);
    tll_free(nots);
}

/*
 * The config-file *discovery* half of config_load(): open_config() moved to
 * config.zig in C2n, and with an explicit conf_path it is never called, so
 * it needs its own test.
 */

static void
test_config_load_from_xdg(void)
{
    char root[] = "/tmp/foot-config-unittest-XXXXXX";
    xassert(mkdtemp(root) != NULL);

    char dot_config[512];
    char foot_dir[512];
    char conf_path[512];
    char no_dirs[512];

    snprintf(dot_config, sizeof(dot_config), "%s/.config", root);
    snprintf(foot_dir, sizeof(foot_dir), "%s/.config/foot", root);
    snprintf(conf_path, sizeof(conf_path), "%s/.config/foot/foot.ini", root);
    snprintf(no_dirs, sizeof(no_dirs), "%s/nonexistent", root);

    xassert(mkdir(dot_config, 0700) == 0);
    xassert(mkdir(foot_dir, 0700) == 0);

    FILE *f = fopen(conf_path, "w");
    xassert(f != NULL);
    fputs("[main]\ntitle=xdg-title\n", f);
    fclose(f);

    char *old_home = getenv("HOME") ? strdup(getenv("HOME")) : NULL;
    char *old_xdg_home = getenv("XDG_CONFIG_HOME") ? strdup(getenv("XDG_CONFIG_HOME")) : NULL;
    char *old_xdg_dirs = getenv("XDG_CONFIG_DIRS") ? strdup(getenv("XDG_CONFIG_DIRS")) : NULL;

    user_notifications_t nots = tll_init();
    config_override_t overrides = tll_init();
    struct config conf;

    /* $HOME/.config/foot/foot.ini */
    unsetenv("XDG_CONFIG_HOME");
    unsetenv("XDG_CONFIG_DIRS");
    setenv("HOME", root, 1);

    xassert(config_load(&conf, NULL, &nots, &overrides, false, false));
    xassert(conf.title != NULL);
    xassert(strcmp(conf.title, "xdg-title") == 0);
    /* NB: upstream never copies the *discovered* path into conf_path --
     * only an explicit conf_path argument ends up there. */
    xassert(conf.conf_path == NULL);
    config_free(&conf);

    /* $XDG_CONFIG_HOME wins over $HOME */
    {
        char xdg[512];
        snprintf(xdg, sizeof(xdg), "%s/.config", root);
        setenv("XDG_CONFIG_HOME", xdg, 1);

        xassert(config_load(&conf, NULL, &nots, &overrides, false, false));
        xassert(strcmp(conf.title, "xdg-title") == 0);
        config_free(&conf);
        unsetenv("XDG_CONFIG_HOME");
    }

    /* No configuration anywhere: defaults, and only fatal if asked */
    xassert(unlink(conf_path) == 0);
    setenv("XDG_CONFIG_DIRS", no_dirs, 1);

    xassert(config_load(&conf, NULL, &nots, &overrides, false, false));
    xassert(strcmp(conf.title, "foot") == 0);
    xassert(conf.conf_path == NULL);
    config_free(&conf);

    xassert(!config_load(&conf, NULL, &nots, &overrides, true, false));
    /* The failing load still allocated the URL regex and the default
     * bindings; main() frees the config on that path too. */
    config_free(&conf);

    /* restore the environment */
    if (old_home) { setenv("HOME", old_home, 1); free(old_home); }
    else unsetenv("HOME");
    if (old_xdg_home) { setenv("XDG_CONFIG_HOME", old_xdg_home, 1); free(old_xdg_home); }
    else unsetenv("XDG_CONFIG_HOME");
    if (old_xdg_dirs) { setenv("XDG_CONFIG_DIRS", old_xdg_dirs, 1); free(old_xdg_dirs); }
    else unsetenv("XDG_CONFIG_DIRS");

    rmdir(foot_dir);
    rmdir(dot_config);
    rmdir(root);

    tll_free(overrides);
    tll_free(nots);
}

/*
 * Font helpers (C2o): value_to_fonts() -> config_font_parse() ->
 * config_font_list_destroy(), plus the fcft accessors used by
 * check_if_font_is_monospaced().
 */

static void
test_font_helpers(void)
{
    struct config conf = {0};
    struct context ctx = {
        .conf = &conf, .section = "main", .path = "unittest", .key = "font"};

    /* A comma separated list of patterns; the fontconfig size/pixelsize
     * options are stripped from the pattern and kept as numbers. */
    ctx.value = "monospace:size=10, serif:size=12";
    struct config_font_list fonts = value_to_fonts(&ctx);
    xassert(fonts.count == 2);
    xassert(strcmp(fonts.arr[0].pattern, "monospace") == 0);
    xassert(fonts.arr[0].pt_size == 10.0);
    xassert(fonts.arr[0].px_size == -1);
    xassert(strcmp(fonts.arr[1].pattern, "serif") == 0);
    xassert(fonts.arr[1].pt_size == 12.0);
    config_font_list_destroy(&fonts);
    xassert(fonts.count == 0);
    xassert(fonts.arr == NULL);

    /* Leading whitespace is trimmed, empty entries are skipped. Trailing
     * whitespace is *not* trimmed (upstream quirk: the family keeps it). */
    ctx.value = " monospace,  , serif";
    fonts = value_to_fonts(&ctx);
    xassert(fonts.count == 2);
    xassert(strcmp(fonts.arr[0].pattern, "monospace") == 0);
    xassert(strcmp(fonts.arr[1].pattern, "serif") == 0);
    config_font_list_destroy(&fonts);

    ctx.value = "monospace ,";
    fonts = value_to_fonts(&ctx);
    xassert(fonts.count == 1);
    xassert(strcmp(fonts.arr[0].pattern, "monospace ") == 0);
    config_font_list_destroy(&fonts);

    /* No size given: fontconfig's configured default, then foot's 8pt */
    ctx.value = "monospace";
    fonts = value_to_fonts(&ctx);
    xassert(fonts.count == 1);
    xassert(fonts.arr[0].pt_size == 8.0);
    xassert(fonts.arr[0].px_size == -1);
    config_font_list_destroy(&fonts);

    /* pixelsize= is kept as a pixel size, not converted to points */
    ctx.value = "monospace:pixelsize=15";
    fonts = value_to_fonts(&ctx);
    xassert(fonts.count == 1);
    xassert(fonts.arr[0].px_size == 15);
    xassert(fonts.arr[0].pt_size == -1.0);
    config_font_list_destroy(&fonts);

    /* check_if_font_is_monospaced() reads fcft_font.name and
     * fcft_glyph.advance.x through the C accessors. */
    fcft_init(FCFT_LOG_COLORIZE_NEVER, false, FCFT_LOG_CLASS_NONE);
    user_notifications_t nots = tll_init();
    xassert(check_if_font_is_monospaced("monospace:size=10", &nots));
    xassert(tll_length(nots) == 0);
    tll_free(nots);
    fcft_fini();
}

int
main(int argc, const char *const *argv)
{
    FcInit();
    log_init(LOG_COLORIZE_AUTO, false, 0, LOG_CLASS_ERROR);
    test_section_main();
    test_section_security();
    test_section_bell();
    test_section_desktop_notifications();
    test_section_scrollback();
    test_section_url();
    test_section_cursor();
    test_section_mouse();
    test_section_touch();
    test_section_colors_dark();
    test_section_colors_light();
    test_section_csd();
    test_section_key_bindings();
    test_key_binding_sequences();
    test_section_key_bindings_collisions();
    test_section_search_bindings();
    test_section_search_bindings_collisions();
    test_section_url_bindings();
    test_section_url_bindings_collisions();
    test_section_mouse_bindings();
    test_section_mouse_bindings_collisions();
    test_section_text_bindings();
    test_section_environment();
    test_section_tweak();
    test_default_url_regex();
    test_config_load();
    test_config_load_from_xdg();
    test_font_helpers();
    log_deinit();
    FcFini();
    return 0;
}
