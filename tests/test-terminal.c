/*
 * Headless terminal harness.
 *
 * Builds a `struct terminal` by hand (no wayland, no fdm, no config, no pty)
 * so the pieces of terminal.c that have been ported to Zig can be exercised
 * directly. This is the growth point for the rest of phase 1: each new chunk
 * should add cases here.
 *
 * The grid is filled with synthetic cells, so the harness also gives the
 * text-extraction functions (term_*_to_text) something to assert against.
 */

#include "terminal.h"
#include "grid.h"
#include "config.h"
#include "xmalloc.h"

#include <stdio.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#define SCROLLBACK_ROWS 16
#define TERM_ROWS 5
#define COLS 5

static int failures;

static void
check(bool cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    } else {
        printf("ok: %s\n", what);
    }
}

static void
check_text(const char *text, const char *expected, const char *what)
{
    if (text == NULL || strcmp(text, expected) != 0) {
        fprintf(stderr, "FAIL: %s\n  expected: <%s>\n  got:      <%s>\n",
                what, expected, text != NULL ? text : "(null)");
        failures++;
    } else {
        printf("ok: %s\n", what);
    }
}

static struct row *
row_new(const char *content)
{
    struct row *r = xcalloc(1, sizeof(*r));
    xassert(r != NULL);
    r->cells = xcalloc(COLS, sizeof(r->cells[0]));
    xassert(r->cells != NULL);
    r->linebreak = true;
    r->shell_integration.cmd_start = -1;
    r->shell_integration.cmd_end = -1;

    for (int c = 0; c < COLS; c++) {
        r->cells[c].wc = 0;
        r->cells[c].attrs.fg_src = COLOR_DEFAULT;
        r->cells[c].attrs.bg_src = COLOR_DEFAULT;
    }

    if (content != NULL) {
        for (int c = 0; c < COLS && content[c] != '\0'; c++)
            r->cells[c].wc = (unsigned char)content[c];
    }

    return r;
}

static void
populate(struct terminal *term)
{
    for (int i = 0; i < SCROLLBACK_ROWS; i++) {
        if (term->normal.rows[i] == NULL) {
            char content[COLS + 1];
            snprintf(content, sizeof(content), "%d", i);
            term->normal.rows[i] = row_new(content);
        }
    }
}

static struct terminal *
term_new(void)
{
    struct terminal *term = xcalloc(1, sizeof(*term));
    xassert(term != NULL);

    term->rows = TERM_ROWS;
    term->cols = COLS;
    term->normal.rows = xcalloc(SCROLLBACK_ROWS, sizeof(term->normal.rows[0]));
    xassert(term->normal.rows != NULL);
    term->normal.num_rows = SCROLLBACK_ROWS;
    term->normal.num_cols = COLS;
    term->grid = &term->normal;

    term->selection.coords.start = (struct coord){-1, -1};
    term->selection.coords.end = (struct coord){-1, -1};
    term->selection.kind = SELECTION_NONE;
    term->selection.auto_scroll.fd = -1;

    /* term_to_slave() short-circuits on ptmx < 0, so escape-sequence
     * generating helpers can be exercised without a pty. */
    term->ptmx = -1;

    populate(term);
    return term;
}

static void
term_free(struct terminal *term)
{
    tll_free(term->normal.scroll_damage);
    tll_free(term->normal.sixel_images);
    for (int i = 0; i < term->normal.num_rows; i++)
        grid_row_free(term->normal.rows[i]);
    free(term->normal.rows);
    free(term);
}

/* term_view_to_text(): the screen, and nothing else */
static void
test_view_to_text(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;  /* screen is rows 11..15 */
    term->normal.view = 11;

    char *text = NULL;
    size_t len = 0;
    check(term_view_to_text(term, &text, &len), "view_to_text returns true");
    check_text(text, "11\n12\n13\n14\n15", "view_to_text extracts the screen rows");
    check(len == strlen("11\n12\n13\n14\n15"), "view_to_text length matches");
    free(text);
    term_free(term);
}

/* term_scrollback_to_text(): scrollback and screen, oldest first */
static void
test_scrollback_to_text(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;

    char *text = NULL;
    size_t len = 0;
    check(term_scrollback_to_text(term, &text, &len), "scrollback_to_text returns true");
    check_text(text,
               "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15",
               "scrollback_to_text extracts scrollback + screen");
    free(text);
    term_free(term);
}

/* Unused scrollback rows are NULL; the scan must find the used ones. */
static void
test_scrollback_partially_used(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;

    /* Scrollback is filled bottom-up: the rows furthest away from the
     * screen are the last ones to be used, so rows 0..7 may still be NULL. */
    for (int i = 0; i < 8; i++) {
        grid_row_free(term->normal.rows[i]);
        term->normal.rows[i] = NULL;
    }

    char *text = NULL;
    size_t len = 0;
    check(term_scrollback_to_text(term, &text, &len), "partially used scrollback returns true");
    check_text(text, "8\n9\n10\n11\n12\n13\n14\n15",
               "partially used scrollback skips NULL rows");
    free(text);
    term_free(term);
}

/* term_command_output_to_text(): FTCS marks on a partial last row */
static void
test_command_output_partial_row(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;

    grid_row_free(term->normal.rows[12]);
    term->normal.rows[12] = row_new("ABCDE");
    term->normal.rows[12]->shell_integration.cmd_start = 1;

    grid_row_free(term->normal.rows[13]);
    term->normal.rows[13] = row_new("FGHIJ");

    grid_row_free(term->normal.rows[14]);
    term->normal.rows[14] = row_new("KLMNO");
    term->normal.rows[14]->shell_integration.cmd_end = 4;

    char *text = NULL;
    size_t len = 0;
    check(term_command_output_to_text(term, &text, &len),
          "command_output_to_text finds the command region");
    check_text(text, "BCDE\nFGHIJ\nKLMN",
               "command_output_to_text honours start/end columns");
    free(text);
    term_free(term);
}

/* end_col == 0: the *whole* previous line belongs to the output, so a
 * trailing newline is appended when that line has a hard linebreak. */
static void
test_command_output_whole_line(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;

    grid_row_free(term->normal.rows[12]);
    term->normal.rows[12] = row_new("ABCDE");
    term->normal.rows[12]->shell_integration.cmd_start = 1;

    grid_row_free(term->normal.rows[13]);
    term->normal.rows[13] = row_new("FGHIJ");

    grid_row_free(term->normal.rows[14]);
    term->normal.rows[14] = row_new("KLMNO");
    term->normal.rows[14]->shell_integration.cmd_end = 0;

    char *text = NULL;
    size_t len = 0;
    check(term_command_output_to_text(term, &text, &len),
          "command_output_to_text (end_col 0) returns true");
    check_text(text, "BCDE\nFGHIJ\n",
               "command_output_to_text appends the missing newline");
    free(text);
    term_free(term);
}

/* No FTCS marks at all */
static void
test_command_output_absent(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;

    char *text = NULL;
    size_t len = 0;
    check(!term_command_output_to_text(term, &text, &len),
          "command_output_to_text returns false without markers");
    check(text == NULL, "command_output_to_text leaves text untouched");
    term_free(term);
}

/* term_erase_scrollback(): rows not on screen are freed, view is reset to
 * offset, and a selection touching the scrollback is cancelled. */
static void
test_erase_scrollback(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 3;

    term->selection.coords.start = (struct coord){.row = 0};
    term->selection.coords.end = (struct coord){.row = 1};
    term->selection.kind = SELECTION_CHAR_WISE;

    term_erase_scrollback(term);

    bool all_ok = true;
    for (int i = 0; i < SCROLLBACK_ROWS; i++) {
        bool on_screen = i >= 11 && i < 11 + TERM_ROWS;
        if (on_screen != (term->normal.rows[i] != NULL))
            all_ok = false;
    }
    check(all_ok, "erase_scrollback keeps exactly the screen rows");
    check(term->normal.view == term->normal.offset, "erase_scrollback resets the view");
    check(term->selection.kind == SELECTION_NONE, "erase_scrollback cancels the selection");

    char *text = NULL;
    size_t len = 0;
    check(term_scrollback_to_text(term, &text, &len), "text after erase returns true");
    check_text(text, "11\n12\n13\n14\n15", "text after erase is the screen only");
    free(text);
    term_free(term);
}

/* term_theme_apply(): copies the theme into the terminal's colour table */
static void
test_theme_apply(void)
{
    struct terminal *term = term_new();

    struct color_theme theme = {0};
    theme.fg = 0x11223344;
    theme.bg = 0x55667788;
    theme.alpha = 0xdead;
    theme.cursor.text = 0x00ff00;
    theme.cursor.cursor = 0x0000ff;
    theme.use_custom.cursor = true;
    theme.selection_fg = 0xaaaaaaaa;
    theme.selection_bg = 0xbbbbbbbb;
    for (int i = 0; i < 256; i++)
        theme.table[i] = 0x1000 + i;

    term_theme_apply(term, &theme);

    check(term->colors.fg == theme.fg, "theme_apply copies fg");
    check(term->colors.bg == theme.bg, "theme_apply copies bg");
    check(term->colors.alpha == theme.alpha, "theme_apply copies alpha");
    check(term->colors.cursor_fg == (0x80000000u | theme.cursor.text),
          "theme_apply sets the custom-cursor bit on cursor_fg");
    check(term->colors.cursor_bg == (0x80000000u | theme.cursor.cursor),
          "theme_apply sets the custom-cursor bit on cursor_bg");
    check(term->colors.selection_fg == theme.selection_fg, "theme_apply copies selection_fg");
    check(term->colors.selection_bg == theme.selection_bg, "theme_apply copies selection_bg");
    check(term->colors.table[0] == theme.table[0] &&
          term->colors.table[255] == theme.table[255],
          "theme_apply copies the 256-entry colour table");

    /* Without use_custom.cursor the high bit stays clear */
    theme.use_custom.cursor = false;
    term_theme_apply(term, &theme);
    check(term->colors.cursor_fg == theme.cursor.text,
          "theme_apply leaves the cursor colour unprefixed when not custom");

    term_free(term);
}

/* term_theme_get(): dark/light selection through the conf shim */
static void
test_theme_get(void)
{
    struct terminal *term = term_new();
    struct config conf = {0};
    conf.colors_dark.fg = 0xd4d4d4;
    conf.colors_light.fg = 0x181818;
    term->conf = &conf;

    term->colors.active_theme = COLOR_THEME_DARK;
    const struct color_theme *dark = term_theme_get(term);
    check(dark->fg == 0xd4d4d4, "theme_get returns colors_dark for the dark theme");

    term->colors.active_theme = COLOR_THEME_LIGHT;
    const struct color_theme *light = term_theme_get(term);
    check(light->fg == 0x181818, "theme_get returns colors_light for the light theme");

    term_free(term);
}

/* term_icon(): falls back to conf->app_id, and maps footclient -> foot */
static void
test_term_icon(void)
{
    struct terminal *term = term_new();
    struct config conf = {0};
    conf.app_id = "org.example.term";
    term->conf = &conf;

    check(strcmp(term_icon(term), "org.example.term") == 0,
          "term_icon falls back to the configured app-id");

    term->app_id = xstrdup("footclient");
    check(strcmp(term_icon(term), "foot") == 0,
          "term_icon maps footclient to foot");

    free(term->app_id);
    term->app_id = xstrdup("org.example.custom");
    check(strcmp(term_icon(term), "org.example.custom") == 0,
          "term_icon prefers the runtime app-id");
    free(term->app_id);
    term->app_id = NULL;

    term_free(term);
}

/* term_osc8_*(): id/URI state and the ascii-printer bits */
static void
test_osc8(void)
{
    struct terminal *term = term_new();

    check(term->vt.osc8.uri == NULL, "osc8 starts closed");

    term_osc8_open(term, 42, "https://example.com/");
    check(term->vt.osc8.id == 42, "osc8_open stores the id");
    check(term->vt.osc8.uri != NULL &&
          strcmp(term->vt.osc8.uri, "https://example.com/") == 0,
          "osc8_open stores the uri");
    check(term->bits_affecting_ascii_printer.osc8, "osc8_open sets the ascii-printer bit");

    /* Opening again must replace, not leak/duplicate */
    term_osc8_open(term, 43, "https://second.example/");
    check(term->vt.osc8.id == 43, "osc8_open replaces the id");
    check(strcmp(term->vt.osc8.uri, "https://second.example/") == 0,
          "osc8_open replaces the uri");

    term_osc8_close(term);
    check(term->vt.osc8.uri == NULL, "osc8_close clears the uri");
    check(term->vt.osc8.id == 0, "osc8_close clears the id");
    check(!term->bits_affecting_ascii_printer.osc8, "osc8_close clears the ascii-printer bit");

    term_free(term);
}

/* size notifications: always reports once on enable, then only while enabled */
static void
test_size_notifications(void)
{
    struct terminal *term = term_new();
    term->width = 800;
    term->height = 600;
    term->ptmx = -1;

    check(!term->size_notifications, "size notifications start disabled");

    term_disable_size_notifications(term);
    check(!term->size_notifications, "disabling twice is a no-op");

    term_enable_size_notifications(term);
    check(term->size_notifications, "enable_size_notifications sets the flag");

    term_send_size_notification(term);   /* must not crash without a pty */
    term_disable_size_notifications(term);
    check(!term->size_notifications, "disable_size_notifications clears the flag");

    /* Sending while disabled is a no-op */
    term_send_size_notification(term);
    check(!term->size_notifications, "send while disabled leaves the flag alone");

    term_free(term);
}

/* term_flash(): arms the timer and marks the terminal as flashing */
static void
test_flash(void)
{
    struct terminal *term = term_new();
    term->flash.fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    check(term->flash.fd >= 0, "flash timer created");

    check(!term->flash.active, "flash starts inactive");
    term_flash(term, 100);
    check(term->flash.active, "term_flash marks the terminal as flashing");

    close(term->flash.fd);
    term_free(term);
}

int
main(void)
{
    test_view_to_text();
    test_scrollback_to_text();
    test_scrollback_partially_used();
    test_command_output_partial_row();
    test_command_output_whole_line();
    test_command_output_absent();
    test_erase_scrollback();
    test_osc8();
    test_size_notifications();
    test_flash();
    test_theme_apply();
    test_theme_get();
    test_term_icon();

    if (failures > 0) {
        fprintf(stderr, "%d harness check(s) failed\n", failures);
        return 1;
    }

    printf("terminal harness: all checks passed\n");
    return 0;
}
