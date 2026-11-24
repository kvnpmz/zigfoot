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
#include "extract.h"
#include "fdm.h"
#include "wayland.h"
#include "xmalloc.h"

#include <stdio.h>
#include <fcntl.h>
#include <termios.h>
#include <linux/input-event-codes.h>
#include "input.h"
#include <sys/timerfd.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/* Ported to terminal.zig; internal helpers, not part of terminal.h. */
void print_insert(struct terminal *term, int width);
void erase_cell_range(struct terminal *term, struct row *row, int start, int end);
void vt_tab_stops_push_back(struct terminal *term, int value);
void cmd_scrollback_up(struct terminal *term, int rows);
void cmd_scrollback_down(struct terminal *term, int rows);
void begin_receive_clipboard(
    struct terminal *term, bool no_strip, int read_fd,
    enum data_offer_mime_type mime_type,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);
void erase_line(struct terminal *term, struct row *row);
void print_linewrap(struct terminal *term);
void csi_sgr(struct terminal *term);
bool term_set_fonts(
    struct terminal *term, struct fcft_font *fonts[static 4], bool resize_grid);
bool reload_fonts(struct terminal *term, bool resize_grid);
bool load_fonts_from_conf(struct terminal *term);

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

/*
 * Give the terminal a real pty so term_to_slave() output can be captured:
 * term->ptmx is the master, and we read the escapes back from the slave.
 */
static int
term_capture_begin(struct terminal *term)
{
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    xassert(master >= 0);
    xassert(grantpt(master) == 0);
    xassert(unlockpt(master) == 0);

    /* Canonical mode would line-buffer the input queue and hide our
     * escape sequences; foot puts the pty in raw mode, so do the same. */
    struct termios tio;
    xassert(tcgetattr(master, &tio) == 0);
    cfmakeraw(&tio);
    xassert(tcsetattr(master, TCSANOW, &tio) == 0);

    const char *slave_name = ptsname(master);
    xassert(slave_name != NULL);

    int slave = open(slave_name, O_RDWR | O_NOCTTY | O_NONBLOCK);
    xassert(slave >= 0);

    term->ptmx = master;
    return slave;
}

static void
term_capture_end(struct terminal *term, int slave)
{
    close(slave);
    close(term->ptmx);
    term->ptmx = -1;
}

/* Read whatever term_to_slave() wrote, as a NUL-terminated string. */
static void
term_capture_read(int slave, char *buf, size_t size)
{
    size_t len = 0;
    while (len + 1 < size) {
        ssize_t n = read(slave, buf + len, size - len - 1);
        if (n <= 0)
            break;
        len += (size_t)n;
    }
    buf[len] = '\0';
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

/* Mouse reporting: the escape sequences must match foot's C output byte for
 * byte, so these read them back out of a real pty. */
static void
test_mouse_reporting(void)
{
    struct terminal *term = term_new();
    term->kbd_focus = true;

    int slave = term_capture_begin(term);
    char buf[256];

    /* SGR, button press/release */
    term->mouse_tracking = MOUSE_CLICK;
    term->mouse_reporting = MOUSE_SGR;

    term_mouse_down(term, BTN_LEFT, 2, 3, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<0;4;3M", "SGR button press");

    term_mouse_up(term, BTN_LEFT, 2, 3, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<0;4;3m", "SGR button release");

    /* Modifiers only apply while the terminal has keyboard focus */
    term_mouse_down(term, BTN_LEFT, 0, 0, 0, 0, true, true, true);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<28;1;1M", "SGR with shift+alt+ctrl");

    term->kbd_focus = false;
    term_mouse_down(term, BTN_LEFT, 0, 0, 0, 0, true, true, true);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<0;1;1M", "modifiers ignored without focus");
    term->kbd_focus = true;

    /* Scroll wheel: BTN_WHEEL_FORWARD maps to X button 5, encoded 65 */
    term_mouse_down(term, BTN_WHEEL_FORWARD, 0, 0, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<65;1;1M", "SGR wheel-up");

    /* No release events for the vertical wheel */
    term_mouse_up(term, BTN_WHEEL_FORWARD, 0, 0, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "wheel-up has no release event");

    /* X10 style: ESC [ M <button+32> <col+32+1> <row+32+1> */
    term->mouse_reporting = MOUSE_NORMAL;
    term_mouse_down(term, BTN_MIDDLE, 0, 1, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[M\041\042\041", "X10/normal button press");

    term_mouse_up(term, BTN_MIDDLE, 0, 1, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[M\043\042\041", "X10/normal button release");

    /* urxvt */
    term->mouse_reporting = MOUSE_URXVT;
    term_mouse_down(term, BTN_RIGHT, 4, 5, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[34;6;5M", "urxvt button press");

    /* SGR in pixels uses the pixel coordinates, clamped at 0 */
    term->mouse_reporting = MOUSE_SGR_PIXELS;
    term_mouse_down(term, BTN_LEFT, 4, 5, 40, 50, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<0;51;41M", "SGR-pixels button press");

    /* utf8 reporting is unimplemented and must stay silent */
    term->mouse_reporting = MOUSE_UTF8;
    term_mouse_down(term, BTN_LEFT, 0, 0, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "utf8 reporting is silent");

    /* Motion: MOUSE_CLICK never reports, MOUSE_DRAG needs a button */
    term->mouse_reporting = MOUSE_SGR;
    term->mouse_tracking = MOUSE_CLICK;
    term_mouse_motion(term, BTN_LEFT, 1, 1, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "no motion reports in MOUSE_CLICK");

    term->mouse_tracking = MOUSE_DRAG;
    term_mouse_motion(term, 0, 1, 1, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "no motion without a button in MOUSE_DRAG");

    term_mouse_motion(term, BTN_LEFT, 1, 1, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<32;2;2M", "drag motion with button");

    term->mouse_tracking = MOUSE_MOTION;
    term_mouse_motion(term, 0, 1, 2, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[<35;3;2M", "motion with button released");

    /* Tracking disabled: nothing is reported */
    term->mouse_tracking = MOUSE_NONE;
    term_mouse_down(term, BTN_LEFT, 0, 0, 0, 0, false, false, false);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "no reports when tracking is off");

    term_capture_end(term, slave);
    term_free(term);
}

/* print_insert(): shifts the rest of the row right */
static void
test_print_insert(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;
    term->normal.view = 11;
    term->normal.cursor.point.row = 0;
    term->normal.cursor.point.col = 1;
    term->normal.cur_row = term->normal.rows[11];

    term->insert_mode = true;

    struct row *r = term->normal.rows[11];
    for (int c = 0; c < COLS; c++) {
        r->cells[c].wc = 'a' + c;
        r->cells[c].attrs.clean = true;
    }

    print_insert(term, 2);
    /* cursor at col 1, width 2, 5 columns: cells[3..5] <- cells[1..3] */
    check(r->cells[0].wc == 'a' && r->cells[1].wc == 'b' &&
          r->cells[2].wc == 'c' && r->cells[3].wc == 'b' &&
          r->cells[4].wc == 'c',
          "print_insert shifts cells right");
    check(!r->cells[3].attrs.clean && !r->cells[4].attrs.clean,
          "print_insert marks shifted cells dirty");
    check(r->cells[1].attrs.clean, "print_insert leaves cells before the cursor alone");

    /* Without insert mode it is a no-op */
    term->insert_mode = false;
    for (int c = 0; c < COLS; c++)
        r->cells[c].wc = 'a' + c;
    print_insert(term, 2);
    check(r->cells[1].wc == 'b', "print_insert is a no-op outside insert mode");

    term_free(term);
}

/* ── cmd_scrollback_up/down ─────────────────────────────────────────────── */

static void
test_scrollback_commands(void)
{
    struct terminal *term = term_new();
    term->normal.offset = 11;   /* screen: rows 11..15 */
    term->normal.view = 11;

    /* Scroll up three rows */
    cmd_scrollback_up(term, 3);
    check(term->normal.view == 8, "scrollback_up moves the view back");
    check(term->normal.scroll_damage.length > 0, "scrollback_up damages the view");

    /* Clamped at the top of the scrollback (row 0) */
    cmd_scrollback_up(term, 100);
    check(term->normal.view == 0, "scrollback_up clamps at the scrollback start");

    /* Already at the start: no-op */
    cmd_scrollback_up(term, 1);
    check(term->normal.view == 0, "scrollback_up at the start is a no-op");

    /* And back down */
    cmd_scrollback_down(term, 4);
    check(term->normal.view == 4, "scrollback_down moves the view forward");

    /* Clamped at the screen (offset) */
    cmd_scrollback_down(term, 100);
    check(term->normal.view == 11, "scrollback_down clamps at the screen start");

    cmd_scrollback_down(term, 1);
    check(term->normal.view == 11, "scrollback_down at the screen start is a no-op");

    /* The alternate screen never scrolls back */
    term->normal.view = 5;
    term->grid = &term->alt;
    cmd_scrollback_up(term, 1);
    check(term->normal.view == 5, "scrollback_up is disabled on the alt grid");

    term_free(term);
}

/* ── extract.c (now extract.zig) directly ───────────────────────────────── */

/* Run extract_* over [start,end) of one row and return the text. */
static char *
extract_row(struct terminal *term, struct row *r, int col_start, int col_end,
            enum selection_kind kind, bool strip_trailing_empty, size_t *len)
{
    struct extraction_context *ctx = extract_begin(kind, strip_trailing_empty);
    xassert(ctx != NULL);

    for (int c = col_start; c < col_end; c++)
        extract_one(term, r, &r->cells[c], c, ctx);

    char *text = NULL;
    size_t n = 0;
    xassert(extract_finish(ctx, &text, &n));
    *len = n;
    return text;
}

static void
test_extract_kinds(void)
{
    struct terminal *term = term_new();
    struct row *r = term->normal.rows[0];

    r->cells[0].wc = 'a';
    r->cells[1].wc = 'b';
    r->cells[2].wc = 'c';
    r->cells[3].wc = 'd';
    r->cells[4].wc = 'e';

    size_t len = 0;
    char *text;

    /* Char-wise, trailing empty stripped: no trailing newline */
    text = extract_row(term, r, 0, COLS, SELECTION_CHAR_WISE, true, &len);
    check_text(text, "abcde", "extract: char-wise selection");
    check(len == 5, "extract: length excludes the NUL");
    free(text);

    /* Line-wise: a trailing newline is added */
    text = extract_row(term, r, 0, COLS, SELECTION_LINE_WISE, true, &len);
    check_text(text, "abcde\n", "extract: line-wise selection ends with a newline");
    check(len == 6, "extract: line-wise length includes the newline");
    free(text);

    /* Block-wise, not stripping: trailing empties become spaces */
    r->cells[3].wc = 0;
    r->cells[4].wc = 0;
    text = extract_row(term, r, 0, COLS, SELECTION_BLOCK, false, &len);
    check_text(text, "abc  ", "extract: block selection keeps trailing spaces");
    free(text);

    /* An empty selection still yields an empty string */
    r->cells[0].wc = 0;
    r->cells[1].wc = 0;
    r->cells[2].wc = 0;
    text = extract_row(term, r, 0, 3, SELECTION_CHAR_WISE, true, &len);
    check_text(text, "", "extract: empty selection is an empty string");
    check(len == 0, "extract: empty selection has zero length");
    free(text);

    term_free(term);
}

static void
test_extract_tabs(void)
{
    struct terminal *term = term_new();
    struct row *r = term->normal.rows[1];

    /* A tab cell is emitted literally; the padding spaces up to the next tab
     * stop are swallowed (tab_spaces_left), so the text keeps one "\t". */
    vt_tab_stops_push_back(term, 0);
    vt_tab_stops_push_back(term, 4);

    r->cells[0].wc = '\t';
    r->cells[1].wc = ' ';
    r->cells[2].wc = ' ';
    r->cells[3].wc = 'x';

    size_t len = 0;
    char *text = extract_row(term, r, 0, COLS, SELECTION_CHAR_WISE, true, &len);
    check_text(text, "\tx", "extract: tab is literal, padding spaces are swallowed");
    check(len == 2, "extract: swallowed spaces do not count towards length");
    free(text);

    /* With no tab stop ahead, tab_spaces_left is 0 and spaces are kept */
    term->normal.rows[2]->cells[3].wc = '\t';
    term->normal.rows[2]->cells[4].wc = 'q';
    text = extract_row(term, term->normal.rows[2], 3, COLS, SELECTION_CHAR_WISE, true, &len);
    check_text(text, "\tq", "extract: tab at the last column stays literal");
    free(text);

    term_free(term);
}

/* ── clipboard receive pipeline ─────────────────────────────────────────── */

struct collector {
    char buf[4096];
    size_t len;
    bool done;
};

static void
collect_cb(char *data, size_t size, void *user)
{
    struct collector *c = user;
    xassert(c->len + size < sizeof(c->buf));
    memcpy(c->buf + c->len, data, size);
    c->len += size;
    c->buf[c->len] = '\0';
}

static void
collect_done(void *user)
{
    struct collector *c = user;
    c->done = true;
}

/*
 * Feed `input` through begin_receive_clipboard(), pumping the fdm until the
 * done callback fires, and return what the callback produced.
 */
static void
receive(struct collector *c, bool no_strip, bool bracketed,
        enum data_offer_mime_type mime_type, const char *input)
{
    struct terminal *term = term_new();
    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);
    term->fdm = fdm;
    term->bracketed_paste = bracketed;

    int fds[2];
    xassert(pipe(fds) == 0);
    xassert(write(fds[1], input, strlen(input)) == (ssize_t)strlen(input));
    close(fds[1]);   /* so the reader sees EOF */

    memset(c, 0, sizeof(*c));
    begin_receive_clipboard(term, no_strip, fds[0], mime_type,
                            collect_cb, collect_done, c);

    while (!c->done)
        fdm_poll(fdm);

    fdm_destroy(fdm);
    term_free(term);
}

static void
test_receive_paste_normalisation(void)
{
    struct collector c;

    /* Non-bracketed: \r\n -> \r and \n -> \r */
    receive(&c, false, false, DATA_OFFER_MIME_TEXT_PLAIN, "a\r\nb\nc");
    check_text(c.buf, "a\rb\rc", "non-bracketed paste normalises newlines");

    /* Bracketed: newlines are preserved */
    receive(&c, false, true, DATA_OFFER_MIME_TEXT_PLAIN, "a\r\nb\nc");
    check_text(c.buf, "a\r\nb\nc", "bracketed paste preserves newlines");

    /* no-strip (e.g. OSC 52 with no-strip set) leaves everything alone */
    receive(&c, true, false, DATA_OFFER_MIME_TEXT_PLAIN, "a\r\nb\nc");
    check_text(c.buf, "a\r\nb\nc", "no_strip disables normalisation");

    /* C0 controls are stripped, formatting ones (\t \r \n) kept */
    receive(&c, false, false, DATA_OFFER_MIME_TEXT_PLAIN, "a\001b\033c\td");
    check_text(c.buf, "abc\td", "non-formatting C0 controls are stripped");

    receive(&c, false, false, DATA_OFFER_MIME_TEXT_PLAIN, "a\010b\177c");
    check_text(c.buf, "abc", "BS and DEL are stripped when not bracketed");

    receive(&c, false, true, DATA_OFFER_MIME_TEXT_PLAIN, "a\010b");
    check_text(c.buf, "a\010b", "BS survives a bracketed paste");
}

static void
test_receive_uri_list(void)
{
    struct collector c;
    struct terminal *unused;

    /* quote_paths is true when the grid is the normal one, which the harness
     * always is: local file paths come out single-quoted, space separated. */
    receive(&c, false, false, DATA_OFFER_MIME_URI_LIST,
            "file:///tmp/foo\nfile://localhost/tmp/bar\n");
    check_text(c.buf, "'/tmp/foo' '/tmp/bar'", "uri-list: local paths are quoted");

    /* Embedded single quotes are escaped */
    receive(&c, false, false, DATA_OFFER_MIME_URI_LIST, "file:///tmp/a'b\n");
    check_text(c.buf, "'/tmp/a\\'b'", "uri-list: embedded quotes are escaped");

    /* Remote URIs are passed through untouched */
    receive(&c, false, false, DATA_OFFER_MIME_URI_LIST, "https://example.com/x\n");
    check_text(c.buf, "https://example.com/x", "uri-list: non-file URIs pass through");

    /* The final URI has no trailing newline; the finish callback flushes it */
    receive(&c, false, false, DATA_OFFER_MIME_URI_LIST,
            "file:///tmp/one\nfile:///tmp/two");
    check_text(c.buf, "'/tmp/one' '/tmp/two'", "uri-list: unterminated last URI is flushed");

    /* Not on the alternate screen: quote_paths stays true either way here */
    (void)unused;
}

/*
 * Same, but the data arrives in two reads. This is the case the URI buffer
 * exists for: a line boundary may fall inside a read() or between two.
 */
static void
receive_split(struct collector *c, const char *part1, const char *part2,
              bool silent_after_part1)
{
    struct terminal *term = term_new();
    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);
    term->fdm = fdm;

    int fds[2];
    xassert(pipe(fds) == 0);

    memset(c, 0, sizeof(*c));
    begin_receive_clipboard(term, false, fds[0], DATA_OFFER_MIME_URI_LIST,
                            collect_cb, collect_done, c);

    xassert(write(fds[1], part1, strlen(part1)) == (ssize_t)strlen(part1));
    fdm_poll(fdm);   /* consume part1; an incomplete line must be buffered */
    if (silent_after_part1) {
        check(c->len == 0, "split URI: no callback while the line is incomplete");
    }

    xassert(write(fds[1], part2, strlen(part2)) == (ssize_t)strlen(part2));
    close(fds[1]);

    while (!c->done)
        fdm_poll(fdm);

    fdm_destroy(fdm);
    term_free(term);
}

static void
test_receive_uri_split_reads(void)
{
    struct collector c;

    /* Boundary in the middle of the first URI */
    receive_split(&c, "file:///tmp/fo", "o\nfile:///tmp/bar", true);
    check_text(c.buf, "'/tmp/foo' '/tmp/bar'", "uri-list: partial line spans two reads");

    /* Boundary exactly on the newline, and two URIs in the second read */
    receive_split(&c, "file:///tmp/one\n", "file:///tmp/two\nfile:///tmp/three", false);
    check_text(c.buf, "'/tmp/one' '/tmp/two' '/tmp/three'",
               "uri-list: multiple URIs across reads");
}

static void
test_receive_timeout(void)
{
    /* A pipe that never gets data nor EOF: the 2s timer must fire and call
     * done() so we don't leak the context. */
    struct terminal *term = term_new();
    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);
    term->fdm = fdm;

    struct collector c;
    memset(&c, 0, sizeof(c));

    int fds[2];
    xassert(pipe(fds) == 0);

    begin_receive_clipboard(term, false, fds[0], DATA_OFFER_MIME_TEXT_PLAIN,
                            collect_cb, collect_done, &c);
    while (!c.done)
        fdm_poll(fdm);

    check(c.len == 0, "timeout: no data was collected");
    check(c.done, "timeout: done callback was called");

    close(fds[1]);
    fdm_destroy(fdm);
    term_free(term);
}

/* erase_cell_range()/erase_line(): blanking cells, honouring the current bg */
static void
test_erase_cell_range(void)
{
    struct terminal *term = term_new();
    struct row *r = term->normal.rows[0];

    for (int c = 0; c < COLS; c++)
        r->cells[c].wc = 'a' + c;

    /* Default background: plain memset of the range */
    term->vt.attrs.bg_src = COLOR_DEFAULT;
    erase_cell_range(term, r, 1, 3);
    check(r->dirty, "erase_cell_range marks the row dirty");
    check(r->cells[0].wc == 'a' && r->cells[4].wc == 'e',
          "erase_cell_range leaves cells outside the range alone");
    check(r->cells[1].wc == 0 && r->cells[2].wc == 0 && r->cells[3].wc == 0,
          "erase_cell_range blanks the range");

    /* Non-default background: cells keep the bg colour */
    for (int c = 0; c < COLS; c++)
        r->cells[c].wc = 'a' + c;
    term->vt.attrs.bg_src = COLOR_BASE256;
    term->vt.attrs.bg = 42;
    erase_cell_range(term, r, 0, 1);
    check(r->cells[0].wc == 0 && r->cells[1].wc == 0,
          "erase_cell_range blanks cells with a custom bg");
    check(r->cells[0].attrs.bg_src == COLOR_BASE256 &&
          r->cells[0].attrs.bg == 42,
          "erase_cell_range keeps the background colour");
    check(r->cells[2].wc == 'c', "erase_cell_range stops at the end column");

    /* erase_line() blanks the whole row and resets shell integration */
    term->vt.attrs.bg_src = COLOR_DEFAULT;
    r->linebreak = false;
    r->shell_integration.cmd_start = 3;
    r->shell_integration.cmd_end = 4;
    r->shell_integration.prompt_marker = true;
    erase_line(term, r);
    check(r->cells[0].wc == 0 && r->cells[COLS - 1].wc == 0,
          "erase_line blanks the entire row");
    check(r->linebreak, "erase_line sets the hard linebreak");
    check(r->shell_integration.cmd_start == -1 &&
          r->shell_integration.cmd_end == -1 &&
          !r->shell_integration.prompt_marker,
          "erase_line clears the shell-integration markers");

    term->vt.attrs.bg_src = COLOR_DEFAULT;
    term_free(term);
}

/* term_bell(): only the flash action is observable without a window */
static void
test_bell(void)
{
    struct terminal *term = term_new();
    struct config conf = {0};
    term->conf = &conf;
    term->bell_action_enabled = false;

    /* Disabled entirely: nothing happens even with every action enabled */
    conf.bell.flash = true;
    term_bell(term);
    check(!term->flash.active, "bell is a no-op when bell-action is disabled");

    term->bell_action_enabled = true;
    conf.bell.flash = false;
    term_bell(term);
    check(!term->flash.active, "bell without any action does not flash");

    term->flash.fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    conf.bell.flash = true;
    term_bell(term);
    check(term->flash.active, "bell flashes when configured to");

    close(term->flash.fd);
    term_free(term);
}

/* term_kbd_focus_in(): focus reports and urgency clearing */
static void
test_kbd_focus_in(void)
{
    struct terminal *term = term_new();
    term->focus_events = true;
    term->render.urgency = true;

    int slave = term_capture_begin(term);
    char buf[64];

    term_kbd_focus_in(term);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[I", "focus-in reports focus");
    check(term->kbd_focus, "focus-in sets kbd_focus");
    check(!term->render.urgency, "focus-in clears the urgency flag");

    /* Already focused: nothing must be emitted */
    term_kbd_focus_in(term);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "focus-in is idempotent");

    /* Without focus-events reporting, no escape sequence */
    term->kbd_focus = false;
    term->focus_events = false;
    term_kbd_focus_in(term);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "", "focus-in respects focus-events=false");

    term_capture_end(term, slave);
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

/* csi_sgr(): `term->vt.underline.style` is read by render.c as an
 * `enum underline_style`, so the stored numbers must be the C ones
 * (NONE=0, SINGLE=1, DOUBLE=2, CURLY=3, ...), not a private encoding. */
static void
test_sgr_underline(void)
{
    struct terminal *term = term_new();

    term->vt.params.idx = 1;
    term->vt.params.v[0].value = 4;
    term->vt.params.v[0].sub.idx = 0;
    csi_sgr(term);
    check(term->vt.attrs.underline, "4: enables underline");
    check(term->vt.underline.style == UNDERLINE_SINGLE,
          "4: stores UNDERLINE_SINGLE");
    check(!term->bits_affecting_ascii_printer.underline_style,
          "4: plain underline does not set the fancy-style bit");

    term->vt.params.v[0].sub.idx = 1;
    term->vt.params.v[0].sub.value[0] = 3;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_CURLY,
          "4:3 stores UNDERLINE_CURLY");
    check(term->bits_affecting_ascii_printer.underline_style,
          "4:3 sets the fancy-style bit");

    term->vt.params.v[0].sub.value[0] = 0;
    csi_sgr(term);
    check(!term->vt.attrs.underline, "4:0 disables underline");
    check(term->vt.underline.style == UNDERLINE_NONE,
          "4:0 stores UNDERLINE_NONE");
    check(!term->bits_affecting_ascii_printer.underline_style,
          "4:0 clears the fancy-style bit");

    term->vt.params.v[0].sub.value[0] = 99;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_NONE,
          "an unknown 4:n style falls back to UNDERLINE_NONE");

    term->vt.params.v[0].value = 21;
    term->vt.params.v[0].sub.idx = 0;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_DOUBLE,
          "21 stores UNDERLINE_DOUBLE");

    term->vt.params.v[0].value = 4;
    term->vt.params.v[0].sub.idx = 1;
    term->vt.params.v[0].sub.value[0] = 5;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_DASHED,
          "4:5 stores UNDERLINE_DASHED");

    term->vt.params.v[0].value = 24;
    term->vt.params.v[0].sub.idx = 0;
    csi_sgr(term);
    check(!term->vt.attrs.underline && term->vt.underline.style == UNDERLINE_NONE,
          "24 clears the underline");

    /* 0 (SGR reset) must clear everything, including the style. */
    term->vt.params.v[0].value = 4;
    term->vt.params.v[0].sub.idx = 1;
    term->vt.params.v[0].sub.value[0] = 2;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_DOUBLE, "4:2 stores UNDERLINE_DOUBLE");
    term->vt.params.v[0].value = 0;
    term->vt.params.v[0].sub.idx = 0;
    csi_sgr(term);
    check(term->vt.underline.style == UNDERLINE_NONE,
          "SGR 0 resets the underline style to UNDERLINE_NONE");

    term_free(term);
}

/* term_set_fonts(): needs four real fonts, a config and font_sizes, but no
 * window as long as resize_grid is false. */
static void
test_set_fonts(void)
{
    struct config conf = {0};
    struct config_font cfg_font = {.pt_size = 8.0f, .px_size = 0};
    conf.fonts[0] = (struct config_font_list){.count = 1, .arr = &cfg_font};
    conf.line_height = (struct pt_or_px){.px = -1, .pt = 0};

    struct terminal *term = term_new();
    term->conf = &conf;
    term->scale = 1.0f;

    struct config_font cur_font = {.pt_size = 8.0f, .px_size = 0};
    term->font_sizes[0] = &cur_font;

    const char *name = "monospace";
    struct fcft_font *fonts[4];
    for (size_t i = 0; i < 4; i++)
        fonts[i] = fcft_from_name(1, &name, ":size=8");

    if (fonts[0] == NULL) {
        printf("skip: no monospace font available\n");
        term_free(term);
        return;
    }

    check(term_set_fonts(term, fonts, false), "term_set_fonts loads fonts");
    check(term->cell_width > 0, "cell width is positive");
    check(term->cell_height > 0, "cell height is positive");
    check(term->font_baseline > 0 && term->font_baseline <= term->cell_height,
          "font baseline lies within the cell");

    const int font_height = term->fonts[0]->ascent + term->fonts[0]->descent;
    check(term->cell_height >= font_height, "auto cell height covers the font");

    /* A custom line height replaces the font-derived height. */
    conf.line_height = (struct pt_or_px){.px = 20, .pt = 0};
    for (size_t i = 0; i < 4; i++)
        fonts[i] = fcft_from_name(1, &name, ":size=8");
    check(term_set_fonts(term, fonts, false), "term_set_fonts with custom line height");
    check(term->cell_height == 20, "custom line height sets cell height");

    for (size_t i = 0; i < 4; i++)
        fcft_destroy(term->fonts[i]);
    term_free(term);
}

/* reload_fonts()/load_fonts_from_conf(): the runtime font path used by the
 * font-size shortcuts and DPI changes. */
static void
test_reload_fonts(void)
{
    struct config conf = {0};
    struct config_font cfg_font = {
        .pattern = "monospace", .pt_size = 8.0f, .px_size = 0};
    conf.fonts[0] = (struct config_font_list){.count = 1, .arr = &cfg_font};
    conf.line_height = (struct pt_or_px){.px = -1, .pt = 0};

    struct terminal *term = term_new();
    term->conf = &conf;
    term->scale = 1.0f;

    struct config_font cur = {.pattern = NULL, .pt_size = 8.0f, .px_size = 0};
    /* reload_fonts() walks all four lists; real init xmalloc(0)s the empty
     * ones, so give them a non-NULL backing here too. */
    /* load_fonts_from_conf() asks for a resize; render_resize() returns
     * early while the window is not configured, so a zeroed window is
     * enough to exercise the font path headlessly. */
    struct wl_window win = {0};
    term->window = &win;

    struct config_font empty[3] = {0};
    term->font_sizes[0] = &cur;
    term->font_sizes[1] = &empty[0];
    term->font_sizes[2] = &empty[1];
    term->font_sizes[3] = &empty[2];

    check(reload_fonts(term, false), "reload_fonts loads the configured face");
    check(term->cell_width > 0, "reload_fonts sets a cell width");
    const int initial_width = term->cell_width;

    /* Runtime font-size change: the same path as the fontSize shortcuts. */
    cur.pt_size = 16.0f;
    check(reload_fonts(term, false), "reload_fonts after a font-size change");
    check(term->cell_width > initial_width, "a larger font widens the cell");

    /* Reset restores the configured size. */
    check(load_fonts_from_conf(term), "load_fonts_from_conf resets font sizes");
    check(term->cell_width == initial_width,
          "reset restores the original cell width");
    check(term->font_sizes[0][0].pt_size == 8.0f,
          "reset restores the configured pt size");

    for (size_t i = 0; i < 4; i++)
        fcft_destroy(term->fonts[i]);
    term_free(term);
}

int
main(void)
{
    /* fcft_from_name() requires fcft_init() before any font test. */
    if (!fcft_init(FCFT_LOG_COLORIZE_AUTO, false, FCFT_LOG_CLASS_ERROR)) {
        fprintf(stderr, "fcft_init() failed\n");
        return 1;
    }

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
    test_scrollback_commands();
    test_extract_kinds();
    test_extract_tabs();
    test_receive_paste_normalisation();
    test_receive_uri_list();
    test_receive_uri_split_reads();
    test_receive_timeout();
    test_erase_cell_range();
    test_bell();
    test_kbd_focus_in();
    test_mouse_reporting();
    test_print_insert();
    test_theme_apply();
    test_theme_get();
    test_term_icon();
    test_sgr_underline();
    test_set_fonts();
    test_reload_fonts();

    fcft_fini();

    if (failures > 0) {
        fprintf(stderr, "%d harness check(s) failed\n", failures);
        return 1;
    }

    printf("terminal harness: all checks passed\n");
    return 0;
}
