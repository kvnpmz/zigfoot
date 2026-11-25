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
#include "shm.h"
#include "slave.h"
#include "log.h"
#include "box-drawing.h"
#include "foot-features.h"
#include "quirks.h"
#include <pixman.h>
#include "user-notification.h"
#include "debug.h"
#include "unicode-mode.h"
#include "xmalloc.h"

#include <stdio.h>
#include <fcntl.h>
#include <termios.h>
#include <linux/input-event-codes.h>
#include "input.h"
#include "key-binding.h"
#include "search.h"
#include <sys/timerfd.h>
#include <sys/epoll.h>
#include <semaphore.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <poll.h>
#include <signal.h>
#include <locale.h>
#include <termios.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

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
void fdm_client_terminated(struct reaper *reaper, pid_t pid, int status, void *data);
bool add_utmp_record(const struct config *conf, struct reaper *reaper, int ptmx);
bool del_utmp_record(const struct config *conf, struct reaper *reaper, int ptmx);
bool fdm_delayed_render(struct fdm *fdm, int fd, int events, void *data);
bool initialize_render_workers(struct terminal *term);
float get_font_dpi(const struct terminal *term);
bool buffer_unref_no_remove_from_chain(struct buffer_private *buf);
enum fcft_subpixel get_font_subpixel(const struct terminal *term);

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

    /* A selection that reaches into the history is cancelled... */
    term->normal.offset = 14; /* screen covers rows 14,15,0,1,2 */
    term->selection.coords.start = (struct coord){.row = 15};
    term->selection.coords.end = (struct coord){.row = 19};
    term->selection.kind = SELECTION_CHAR_WISE;
    populate(term);
    term_erase_scrollback(term);
    check(term->selection.coords.start.row < 0 &&
          term->selection.coords.end.row < 0 &&
          term->selection.kind == SELECTION_NONE,
          "erase_scrollback cancels a selection that touches the history");

    /* ...one that stays on screen is not. */
    term->selection.coords.start = (struct coord){.row = 15};
    term->selection.coords.end = (struct coord){.row = 16};
    term->selection.kind = SELECTION_CHAR_WISE;
    populate(term);
    term_erase_scrollback(term);
    check(term->selection.coords.start.row == 15 &&
          term->selection.coords.end.row == 16 &&
          term->selection.kind == SELECTION_CHAR_WISE,
          "erase_scrollback keeps a selection that is fully on screen");
    term->selection.coords.start = (struct coord){-1, -1};
    term->selection.coords.end = (struct coord){-1, -1};
    term->selection.kind = SELECTION_NONE;

    /* Sixels in the history are destroyed, sixels on screen are kept. */
    struct sixel six = {.rows = 5, .pos = {.row = 15}};
    tll_push_back(term->normal.sixel_images, six);
    populate(term);
    term_erase_scrollback(term);
    check(tll_length(term->normal.sixel_images) == 0,
          "erase_scrollback destroys sixels in the history");

    six.rows = 3;
    tll_push_back(term->normal.sixel_images, six);
    populate(term);
    term_erase_scrollback(term);
    check(tll_length(term->normal.sixel_images) == 1,
          "erase_scrollback keeps sixels that are on screen");
    tll_free(term->normal.sixel_images);

    term_free(term);
}

/* The generated emoji variation-sequence table is a static array in a header,
 * so this check lives here now that terminal.c (which included it) is gone. */
static void
test_emoji_vs_table(void)
{
#include "emoji-variation-sequences.h"
#if defined(FOOT_GRAPHEME_CLUSTERING)
    int64_t last_end = -1;
    bool ok = true;
    for (size_t i = 0; i < sizeof(emoji_vs) / sizeof(emoji_vs[0]); i++) {
        const struct emoji_vs *vs = &emoji_vs[i];
        if (!(vs->start <= vs->end && vs->start > last_end &&
              (vs->vs15 || vs->vs16)))
            ok = false;
        last_end = vs->end;
    }
    check(ok, "the emoji variation-sequence table is sorted and well-formed");
#endif
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

    /* DPI/scale change path: no outputs, so DPI falls back to 96. */
    conf.dpi_aware = false;
    term->scale = 1.0f;
    term->font_dpi = 0.0f;
    check(term_font_dpi_changed(term, 0.5f),
          "term_font_dpi_changed reloads on a scale change");
    check(term->font_dpi == 96.0f,
          "DPI falls back to 96 with no outputs");

    for (size_t i = 0; i < 4; i++)
        fcft_destroy(term->fonts[i]);
    term_free(term);
}

/* DPI/subpixel/scale policy: real monitor structs, no compositor. */
static void
test_dpi_and_scale(void)
{
    struct terminal *term = term_new();
    struct wayland wl = {0};
    struct wl_window win = {0};
    term->wl = &wl;
    term->window = &win;

    /* Opaque background: subpixel rendering is allowed. */
    term->colors.alpha = 0xffff;

    struct monitor mon = {0};
    mon.scale = 2;
    mon.dpi.physical = 120.0f;
    mon.dpi.scaled = 96.0f;
    mon.subpixel = WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB;
    tll_push_back(wl.monitors, mon);

    /* No fractional-scaling protocol: use the scaled DPI. */
    check(get_font_dpi(term) == 96.0f, "DPI uses monitor's scaled DPI");
    check(get_font_subpixel(term) == FCFT_SUBPIXEL_HORIZONTAL_RGB,
          "subpixel mode comes from the first monitor");

    /* Fractional scaling: use the physical DPI. */
    wl.fractional_scale_manager = (void *)1;
    wl.viewporter = (void *)1;
    win.scale = 1.5f;
    check(term_fractional_scaling(term), "fractional scaling detected");
    check(get_font_dpi(term) == 120.0f, "DPI uses monitor's physical DPI");

    /* An output we are mapped on wins over wl->monitors. */
    struct monitor mapped = {0};
    mapped.scale = 3;
    mapped.dpi.physical = 144.0f;
    mapped.subpixel = WL_OUTPUT_SUBPIXEL_VERTICAL_BGR;
    tll_push_back(win.on_outputs, &mapped);
    check(get_font_dpi(term) == 144.0f, "mapped output DPI wins");
    check(get_font_subpixel(term) == FCFT_SUBPIXEL_VERTICAL_BGR,
          "mapped output subpixel wins");

    /* Transparent background forces grayscale antialiasing. */
    term->colors.alpha = 0x8000;
    check(get_font_subpixel(term) == FCFT_SUBPIXEL_NONE,
          "transparent background disables subpixel");

    /* Scale order: fractional > preferred > mapped > last known > first. */
    term->scale = 1.0f;
    check(term_update_scale(term), "scale changes");
    check(term->scale == 1.5f, "fractional window scale wins");

    wl.fractional_scale_manager = NULL;
    wl.viewporter = NULL;
    win.preferred_buffer_scale = 3;
    check(term_update_scale(term), "preferred scale changes the scale");
    check(term->scale == 3.0f, "preferred buffer scale wins");

    win.preferred_buffer_scale = 0;
    tll_free(win.on_outputs);
    term->scale_before_unmap = 1.25f;
    check(term_update_scale(term), "falls back to last known scale");
    check(term->scale == 1.25f, "last known scale wins");

    term->scale_before_unmap = 0.0f;
    check(term_update_scale(term), "falls back to first monitor");
    check(term->scale == 2.0f, "first monitor scale wins");

    tll_free(wl.monitors);
    term_free(term);
}

/* The fontSize shortcuts: per-step pixel/point/percent adjustments, and reset. */
static void
test_font_size_adjustments(void)
{
    struct config conf = {0};
    struct config_font cfg_font = {
        .pattern = "monospace", .pt_size = 8.0f, .px_size = 0};
    conf.fonts[0] = (struct config_font_list){.count = 1, .arr = &cfg_font};
    conf.line_height = (struct pt_or_px){.px = -1, .pt = 0};

    struct terminal *term = term_new();
    term->conf = &conf;
    term->scale = 1.0f;
    struct wl_window win = {0};
    term->window = &win;

    struct config_font cur = {.pattern = NULL, .pt_size = 8.0f, .px_size = 0};
    struct config_font empty[3] = {0};
    term->font_sizes[0] = &cur;
    term->font_sizes[1] = &empty[0];
    term->font_sizes[2] = &empty[1];
    term->font_sizes[3] = &empty[2];

    check(load_fonts_from_conf(term), "font-size test starts from the config");
    const int initial_width = term->cell_width;

    /* One pixel per step. */
    conf.font_size_adjustment =
        (struct font_size_adjustment){.pt_or_px = {.px = 1, .pt = 0}, .percent = 0};
    check(term_font_size_increase(term), "font-size increase succeeds");
    check(cur.px_size > 0, "increase switches to a pixel size");
    check(cur.px_size == 11, "pixel increase adds one pixel to 8pt at 96dpi");
    check(term->cell_width > initial_width, "increase widens the cell");

    check(term_font_size_decrease(term), "font-size decrease succeeds");
    check(cur.px_size == 10, "pixel decrease removes one pixel");

    /* Percent steps. */
    check(term_font_size_reset(term), "reset before percent test");
    conf.font_size_adjustment =
        (struct font_size_adjustment){.pt_or_px = {0, 0}, .percent = 0.1f};
    check(term_font_size_increase(term), "percent increase succeeds");
    check(fabsf(cur.pt_size - 8.8f) < 0.001f, "percent increase scales the pt size");
    check(term_font_size_decrease(term), "percent decrease succeeds");
    check(fabsf(cur.pt_size - 8.0f) < 0.001f, "percent decrease restores the size");

    /* Point steps. */
    check(term_font_size_reset(term), "reset before point test");
    conf.font_size_adjustment =
        (struct font_size_adjustment){.pt_or_px = {.px = 0, .pt = 2.0f}, .percent = 0};
    check(term_font_size_increase(term), "point increase succeeds");
    check(fabsf(cur.pt_size - 10.0f) < 0.001f, "point increase adds points");

    check(term_font_size_reset(term), "final reset succeeds");
    check(fabsf(cur.pt_size - 8.0f) < 0.001f && cur.px_size == 0,
          "reset restores the configured size");
    check(term->cell_width == initial_width, "reset restores the cell width");

    for (size_t i = 0; i < 4; i++)
        fcft_destroy(term->fonts[i]);
    term_free(term);
}

/* shm buffer lifetime: refcounts, deferred release, and fd/mmap teardown. */
static void
test_shm_lifetime(void)
{
    struct buffer_chain *chain = xcalloc(1, sizeof(*chain));

    /* 1. Last unref of an idle buffer destroys it and closes the pool fd. */
    int fd = memfd_create("foot-shm-test", MFD_CLOEXEC);
    check(fd >= 0, "shm test memfd created");
    if (fd < 0) {
        free(chain);
        return;
    }
    xassert(ftruncate(fd, 4096) == 0);
    void *map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    check(map != MAP_FAILED, "shm test mapping created");

    struct buffer_pool *pool = xcalloc(1, sizeof(*pool));
    pool->fd = fd;
    pool->real_mmapped = map;
    pool->mmap_size = 4096;
    pool->ref_count = 1;

    struct buffer_private *buf = xcalloc(1, sizeof(*buf));
    buf->chain = chain;
    buf->ref_count = 1;
    buf->busy = false;
    buf->pool = pool;

    shm_addref(&buf->public);
    check(buf->ref_count == 2, "shm_addref bumps the refcount");
    check(!buffer_unref_no_remove_from_chain(buf),
          "unref above zero keeps the buffer");
    check(buf->ref_count == 1, "refcount decremented");
    check(buffer_unref_no_remove_from_chain(buf),
          "last unref reports removal");
    check(fcntl(fd, F_GETFD) == -1 && errno == EBADF,
          "destroy closes the pool fd");

    /* 2. A busy buffer is deferred until shm_fini(). */
    int fd2 = memfd_create("foot-shm-test-2", MFD_CLOEXEC);
    xassert(fd2 >= 0);
    xassert(ftruncate(fd2, 4096) == 0);
    void *map2 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd2, 0);
    xassert(map2 != MAP_FAILED);

    struct buffer_pool *pool2 = xcalloc(1, sizeof(*pool2));
    pool2->fd = fd2;
    pool2->real_mmapped = map2;
    pool2->mmap_size = 4096;
    pool2->ref_count = 1;

    struct buffer_private *busy = xcalloc(1, sizeof(*busy));
    busy->chain = chain;
    busy->ref_count = 1;
    busy->busy = true;
    busy->pool = pool2;

    check(buffer_unref_no_remove_from_chain(busy),
          "unref of a busy buffer reports removal");
    check(fcntl(fd2, F_GETFD) != -1, "busy buffer is not destroyed yet");
    shm_fini();
    check(fcntl(fd2, F_GETFD) == -1 && errno == EBADF,
          "shm_fini destroys deferred buffers");

    /* 3. shm_unref removes the buffer from its chain and destroys it. */
    int fd3 = memfd_create("foot-shm-test-3", MFD_CLOEXEC);
    xassert(fd3 >= 0);
    xassert(ftruncate(fd3, 4096) == 0);
    void *map3 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd3, 0);
    xassert(map3 != MAP_FAILED);

    struct buffer_pool *pool3 = xcalloc(1, sizeof(*pool3));
    pool3->fd = fd3;
    pool3->real_mmapped = map3;
    pool3->mmap_size = 4096;
    pool3->ref_count = 1;

    struct buffer_private *chained = xcalloc(1, sizeof(*chained));
    chained->chain = chain;
    chained->ref_count = 1;
    chained->pool = pool3;
    tll_push_back(chain->bufs, chained);

    shm_unref(&chained->public);
    check(tll_length(chain->bufs) == 0,
          "shm_unref removes the buffer from the chain");
    check(fcntl(fd3, F_GETFD) == -1 && errno == EBADF,
          "shm_unref destroys the unreferenced buffer");

    /* 4. shm_did_not_use_buf() clears the compositor-busy flag. */
    int fd4 = memfd_create("foot-shm-test-4", MFD_CLOEXEC);
    xassert(fd4 >= 0);
    xassert(ftruncate(fd4, 4096) == 0);
    void *map4 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd4, 0);
    xassert(map4 != MAP_FAILED);

    struct buffer_pool *pool4 = xcalloc(1, sizeof(*pool4));
    pool4->fd = fd4;
    pool4->real_mmapped = map4;
    pool4->mmap_size = 4096;
    pool4->ref_count = 1;

    struct buffer_private *unused = xcalloc(1, sizeof(*unused));
    unused->chain = chain;
    unused->ref_count = 1;
    unused->busy = true;
    unused->pool = pool4;

    shm_did_not_use_buf(&unused->public);
    check(!unused->busy, "shm_did_not_use_buf clears busy");
    check(buffer_unref_no_remove_from_chain(unused),
          "unused buffer destroyed immediately");
    check(fcntl(fd4, F_GETFD) == -1 && errno == EBADF,
          "unused buffer closed its pool fd");

    free(chain);
}

/* shm_get_buffer()/shm_get_many(): allocation and cache behaviour.
 * chain->shm == NULL uses shm.c's headless sentinels, so this runs without a
 * compositor while still using real memfd/mmap and pixman images. */
static void
test_shm_cache(void)
{
    struct buffer_chain chain = {0};
    chain.shm = NULL;
    chain.pix_instances = 1;
    chain.pixman_fmt = PIXMAN_a8r8g8b8;
    chain.shm_format = WL_SHM_FORMAT_ARGB8888;
    chain.scrollable = false;

    struct buffer *a = shm_get_buffer(&chain, 8, 4);
    check(a != NULL, "shm_get_buffer allocates");
    check(a && a->width == 8 && a->height == 4,
          "buffer has the requested size");
    check(a && a->age == 1234, "new buffer is tagged for a full repaint");
    check(a && a->data != NULL, "buffer has backing memory");
    check(a && a->pix_instances == 1 && a->pix && a->pix[0] != NULL,
          "pixman image created for the buffer");
    check(tll_length(chain.bufs) == 1, "buffer is inserted into the chain");

    struct buffer *b = shm_get_buffer(&chain, 8, 4);
    check(b != NULL && b != a, "a busy buffer forces a new allocation");
    check(a->age == 1235, "the busy buffer's age increments");
    check(tll_length(chain.bufs) == 2, "the second buffer joins the chain");

    /* Release both, then ask again: one is reused, not allocated. */
    shm_did_not_use_buf(a);
    shm_did_not_use_buf(b);
    struct buffer *reused = shm_get_buffer(&chain, 8, 4);
    check(reused == a || reused == b, "a released buffer is reused");
    check(reused && ((struct buffer_private *)reused)->busy,
          "the reused buffer is marked busy");
    check(tll_length(chain.bufs) == 1,
          "reuse keeps one buffer and drops the older candidate");

    /* A size mismatch purges the cached buffers. */
    shm_did_not_use_buf(reused);
    struct buffer *big = shm_get_buffer(&chain, 16, 4);
    check(big != NULL && big->width == 16, "a size mismatch allocates");
    check(tll_length(chain.bufs) == 1, "mismatched buffers are purged");

    /* shm_get_many(): immediate-purge buffers, not chain-cached. */
    int widths[2] = {4, 4};
    int heights[2] = {2, 2};
    struct buffer *many[2] = {0};
    shm_get_many(&chain, 2, widths, heights, many);
    check(many[0] != NULL && many[1] != NULL && many[0] != many[1],
          "shm_get_many allocates distinct buffers");
    check(many[0]->age == 1234, "shm_get_many buffers are full-repaint");
    check(tll_length(chain.bufs) == 1,
          "shm_get_many buffers are not chain-cached");

    /* destroy the immediate-purge buffers */
    shm_fini();

    /* shm_purge() unrefs the chain; the busy buffer is deferred, then freed
     * by a second shm_fini(). */
    shm_purge(&chain);
    check(tll_length(chain.bufs) == 0, "shm_purge empties the chain");
    shm_fini();
}

/* shm_chain_new()/free()/bit_depth(): format selection and teardown. */
static void
test_shm_chain(void)
{
    struct buffer_chain *chain =
        shm_chain_new(NULL, false, 1, SHM_BITS_8, NULL, NULL);
    check(chain != NULL, "shm_chain_new allocates");
    check(shm_chain_bit_depth(chain) == SHM_BITS_8,
          "8-bit chain by default");

    struct buffer *buf = shm_get_buffer(chain, 4, 2);
    check(buf != NULL, "8-bit chain allocates buffers");
    shm_did_not_use_buf(buf);
    shm_chain_free(chain);

    /* 10-bit request without compositor support falls back to 8-bit. */
    chain = shm_chain_new(NULL, false, 1, SHM_BITS_10, NULL, NULL);
    check(shm_chain_bit_depth(chain) == SHM_BITS_8,
          "10-bit request falls back without support");
    shm_chain_free(chain);

    /* With ARGB2101010 advertised, the chain becomes 10-bit. */
    struct wayland wl = {0};
    wl.shm_have_argb2101010 = true;
    chain = shm_chain_new(&wl, false, 1, SHM_BITS_10, NULL, NULL);
    check(shm_chain_bit_depth(chain) == SHM_BITS_10,
          "10-bit chain selected when ARGB2101010 is advertised");
    shm_chain_free(chain);

    /* 16-bit selection (present when built with 16-bit pixman support). */
    struct wayland wl16 = {0};
    wl16.shm_have_abgr161616 = true;
    chain = shm_chain_new(&wl16, false, 1, SHM_BITS_16, NULL, NULL);
    check(shm_chain_bit_depth(chain) == SHM_BITS_16 ||
          shm_chain_bit_depth(chain) == SHM_BITS_8,
          "16-bit chain selection is build-dependent");

    if (shm_chain_bit_depth(chain) == SHM_BITS_16) {
        struct buffer *b16 = shm_get_buffer(chain, 2, 2);
        check(b16 != NULL, "16-bit chain allocates buffers");
        shm_addref(b16);
        shm_unref(b16);
        shm_did_not_use_buf(b16);
        shm_unref(b16);
    }
    shm_chain_free(chain);
}


/* shm_scroll(): offset rotation and keep-row moves. Requires punch-hole
 * support on the backing file; skipped otherwise. */
static void
test_shm_scroll(void)
{
    const off_t default_max_pool_size = 512 * 1024 * 1024;
    const int width = 8, height = 6;

    struct buffer_chain *chain =
        shm_chain_new(NULL, true, 1, SHM_BITS_8, NULL, NULL);
    check(chain != NULL, "scrollable chain allocates");

    struct buffer *buf = shm_get_buffer(chain, width, height);
    check(buf != NULL, "scrollable chain allocates a buffer");
    if (buf == NULL) {
        shm_chain_free(chain);
        return;
    }

    if (!shm_can_scroll(buf)) {
        printf("skip: fallocate(FALLOC_FL_PUNCH_HOLE) not supported\n");
        shm_did_not_use_buf(buf);
        shm_unref(buf);
        shm_chain_free(chain);
        return;
    }

    struct buffer_private *priv = (struct buffer_private *)buf;
    const int stride = buf->stride;

    /* Fill each row with a distinct byte so the moves are observable. */
    for (int r = 0; r < height; r++)
        memset((uint8_t *)buf->data + r * stride, 0x10 + r, stride);

    const off_t offset = priv->offset;

    /* Forward one row, keeping the top two rows in place. */
    check(shm_scroll(buf, 1, 0, 2, 0, 0), "scroll forward succeeds");
    check(priv->offset == offset + stride,
          "forward scroll advances the offset by one row");
    check(buf->data == (uint8_t *)priv->pool->real_mmapped + priv->offset,
          "buffer data follows the new offset");
    /* The buffer was relocated one row forward, so new row 0 aliases old
     * row 1. The keep-rows memmove must have written old row 0 into that
     * spot; without it the byte would be 0x11. */
    check(((uint8_t *)buf->data)[0] == 0x10,
          "forward scroll moves the top region down one row");
    check(buf->pix != NULL && buf->pix[0] != NULL && buf->wl_buf != NULL,
          "forward scroll re-instantiates pixman+wl_buffer");

    /* Reverse one row, keeping the bottom two rows in place. */
    for (int r = 0; r < height; r++)
        memset((uint8_t *)buf->data + r * stride, 0x20 + r, stride);

    const off_t offset2 = priv->offset;
    check(shm_scroll(buf, -1, 0, 0, 0, 2), "scroll reverse succeeds");
    check(priv->offset == offset2 - stride,
          "reverse scroll rewinds the offset by one row");
    check(buf->data == (uint8_t *)priv->pool->real_mmapped + priv->offset,
          "reverse scroll re-points the buffer data");
    /* The bottom_keep_rows memmove copies rows h-3..h-2 down to h-2..h-1,
     * so after the relocation new row h-2 holds old row h-3 (0x23 for six
     * rows; without the memmove it would be 0x24). */
    /* The keep-rows memmove copies rows h-2..h-1 down onto h-3..h-2; after
     * the relocation new row h-2 aliases old row h-3, which must hold the
     * original bottom-row byte 0x24 (0x20 + h - 2). */
    check(((uint8_t *)buf->data)[(height - 2) * stride] == 0x20 + (height - 2),
          "reverse scroll moves the bottom region up one row");
    check(buf->pix != NULL && buf->wl_buf != NULL,
          "reverse scroll re-instantiates pixman+wl_buffer");

    shm_did_not_use_buf(buf);
    shm_unref(buf);
    shm_chain_free(chain);

    /* A small pool forces the memfd offset to wrap around. */
    shm_set_max_pool_size(4096);
    chain = shm_chain_new(NULL, true, 1, SHM_BITS_8, NULL, NULL);
    buf = shm_get_buffer(chain, width, height);
    priv = (struct buffer_private *)buf;

    if (buf != NULL && shm_can_scroll(buf)) {
        int wrapped = 0;
        int ok = 1;
        off_t prev = priv->offset;

        for (int i = 0; i < 200; i++) {
            if (!shm_scroll(buf, 1, 0, 0, 0, 0)) {
                ok = 0;
                break;
            }
            if (priv->offset < prev)
                wrapped = 1;
            if (priv->offset + (off_t)priv->size > 4096) {
                ok = 0;
                break;
            }
            prev = priv->offset;
        }

        check(ok, "scrolling stays within the pool");
        check(wrapped, "forward scroll wraps around the pool");
    } else {
        check(false, "small scrollable pool allocates");
    }

    shm_did_not_use_buf(buf);
    shm_unref(buf);
    shm_chain_free(chain);
    shm_set_max_pool_size(default_max_pool_size);

    /* A non-scrollable buffer never scrolls. */
    chain = shm_chain_new(NULL, false, 1, SHM_BITS_8, NULL, NULL);
    buf = shm_get_buffer(chain, width, height);
    check(!shm_can_scroll(buf), "non-scrollable buffers report no scroll");
    check(!shm_scroll(buf, 1, 0, 0, 0, 0), "non-scrollable buffers refuse to scroll");
    shm_did_not_use_buf(buf);
    shm_unref(buf);
    shm_chain_free(chain);
}


/* Read from a pty master until EOF/EIO or the deadline. */
static size_t
read_pty(int fd, char *buf, size_t cap)
{
    size_t len = 0;
    while (len < cap - 1) {
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        if (poll(&pfd, 1, 2000) <= 0)
            break;

        ssize_t n = read(fd, buf + len, cap - len - 1);
        if (n <= 0)
            break;
        len += n;
    }
    buf[len] = '\0';
    return len;
}

static int
open_ptmx(void)
{
    return open("/dev/ptmx", O_RDWR | O_NOCTTY);
}

/* slave_spawn(): fork/exec of the child, its environment and the
 * user-notification banner. Runs for real against a pty. */
static void
test_slave_spawn(void)
{
    static char out[4096];
    int status;
    pid_t pid;

    /* 1. argv mode: TERM/COLORTERM/PWD are set, terminal-identifying
     *    variables from the parent's environment are removed, and extra
     *    env vars from the config are applied (empty value = unset). */
    int ptmx = open_ptmx();
    if (ptmx < 0) {
        printf("skip: cannot open /dev/ptmx\n");
        return;
    }

    env_var_list_t extra = tll_init();
    tll_push_back(extra, ((struct env_var){"FOOT_TEST_EXTRA", "extra-value"}));
    tll_push_back(extra, ((struct env_var){"KITTY_PID", ""}));

    user_notifications_t notifications = tll_init();

    char *argv[] = {
        "/bin/sh", "-c",
        "printf '%s|%s|%s|%s|%s' \"$TERM\" \"$COLORTERM\" \"$PWD\" "
        "\"$FOOT_TEST_EXTRA\" \"${KITTY_PID-unset}\"",
        NULL,
    };
    char *envp[] = {
        "PATH=/usr/bin:/bin",
        "TERM=inherited-term",
        "KITTY_PID=1234",
        "KITTY_WINDOW_ID=99",
        NULL,
    };

    pid = slave_spawn(
        ptmx, 3, "/tmp", argv, (const char *const *)envp, &extra,
        "foot-extra", "/bin/sh", false, &notifications);

    check(pid > 0, "slave_spawn forks a child");

    const char *expect = "foot-extra|truecolor|/tmp|extra-value|unset";
    size_t len = pid > 0 ? read_pty(ptmx, out, sizeof(out)) : 0;
    check(len > 0 && strstr(out, expect) != NULL,
          "child environment is prepared (TERM/COLORTERM/PWD/del_from_env)");

    if (pid > 0 && waitpid(pid, &status, 0) == pid)
        check(WIFEXITED(status), "child exits normally");
    close(ptmx);
    tll_free(extra);
    tll_free(notifications);

    /* 2. User notifications are written to the pty before exec:
     *    errors first, then warnings, then deprecations. */
    ptmx = open_ptmx();
    extra = (env_var_list_t){0};
    notifications = (user_notifications_t){0};

    user_notification_add(&notifications, USER_NOTIFICATION_DEPRECATED,
                          strdup("deprecated-message"));
    user_notification_add(&notifications, USER_NOTIFICATION_WARNING,
                          strdup("warning-message"));
    user_notification_add(&notifications, USER_NOTIFICATION_ERROR,
                          strdup("error-message"));

    char *argv2[] = {"/bin/sh", "-c", "printf 'shell-output'", NULL};
    pid = slave_spawn(
        ptmx, 3, "/tmp", argv2, (const char *const *)envp, &extra,
        "foot", "/bin/sh", false, &notifications);

    check(pid > 0, "slave_spawn forks a child for notifications");

    len = pid > 0 ? read_pty(ptmx, out, sizeof(out)) : 0;
    const char *err_at = strstr(out, "error-message");
    const char *warn_at = strstr(out, "warning-message");
    const char *depr_at = strstr(out, "deprecated-message");
    check(err_at && warn_at && depr_at,
          "all user notifications are emitted");
    check(err_at && warn_at && depr_at &&
          err_at < warn_at && warn_at < depr_at,
          "notifications are ordered error, warning, deprecated");
    check(strstr(out, "\033[31;1merror\033[39;22m: foot: ") != NULL,
          "notifications use the coloured prefix");
    check(strstr(out, "shell-output") != NULL,
          "the shell runs after the notifications");

    if (pid > 0)
        waitpid(pid, &status, 0);
    close(ptmx);
    tll_free(extra);
    user_notifications_free(&notifications);

    /* 3. Login shell: argv[0] is prefixed with '-', and the executable is
     *    still resolved from the un-prefixed path. */
    ptmx = open_ptmx();
    extra = (env_var_list_t){0};
    notifications = (user_notifications_t){0};

    char *argv3[] = {"/bin/sh", "-c", "printf '%s' \"$0\"", NULL};
    pid = slave_spawn(
        ptmx, 3, "/tmp", argv3, (const char *const *)envp, &extra,
        "foot", "/bin/sh", true, &notifications);

    check(pid > 0, "slave_spawn forks a login shell");
    len = pid > 0 ? read_pty(ptmx, out, sizeof(out)) : 0;
    check(len > 0 && out[0] == '-',
          "login shell argv[0] gets a leading dash");

    if (pid > 0)
        waitpid(pid, &status, 0);
    close(ptmx);
    tll_free(extra);
    tll_free(notifications);

    /* 4. A non-existent command fails without leaving a zombie behind. */
    ptmx = open_ptmx();
    extra = (env_var_list_t){0};
    notifications = (user_notifications_t){0};

    char *argv4[] = {"/nonexistent/foot-harness-no-such-binary", NULL};
    pid = slave_spawn(
        ptmx, 1, "/tmp", argv4, (const char *const *)envp, &extra,
        "foot", "/bin/sh", false, &notifications);

    check(pid == -1, "slave_spawn reports a failed exec");
    close(ptmx);
    tll_free(extra);
    tll_free(notifications);

    /* 5. A bad working directory fails before exec. */
    ptmx = open_ptmx();
    extra = (env_var_list_t){0};
    notifications = (user_notifications_t){0};

    char *argv5[] = {"/bin/sh", "-c", "exit 0", NULL};
    pid = slave_spawn(
        ptmx, 3, "/nonexistent/foot-harness-cwd", argv5,
        (const char *const *)envp, &extra, "foot", "/bin/sh", false,
        &notifications);

    check(pid == -1, "slave_spawn reports a failed chdir");
    close(ptmx);
    tll_free(extra);
    tll_free(notifications);
}


/* Capture whatever a logging call writes to stderr. */
struct log_capture {
    int saved_fd;
    int cap_fd;
};

static bool
log_capture_begin(struct log_capture *cap)
{
    fflush(stderr);

    cap->saved_fd = dup(STDERR_FILENO);
    cap->cap_fd = memfd_create("foot-harness-log", 0);
    if (cap->saved_fd < 0 || cap->cap_fd < 0)
        return false;

    return dup2(cap->cap_fd, STDERR_FILENO) >= 0;
}

static size_t
log_capture_end(struct log_capture *cap, char *buf, size_t cap_len)
{
    fflush(stderr);
    dup2(cap->saved_fd, STDERR_FILENO);
    close(cap->saved_fd);

    if (lseek(cap->cap_fd, 0, SEEK_SET) < 0) {
        close(cap->cap_fd);
        buf[0] = '\0';
        return 0;
    }

    size_t len = 0;
    for (;;) {
        ssize_t n = read(cap->cap_fd, buf + len, cap_len - len - 1);
        if (n <= 0)
            break;
        len += n;
    }
    buf[len] = '\0';
    close(cap->cap_fd);
    return len;
}

/* terminal.zig: the IME wrappers fan out to every seat whose keyboard focus
 * is this terminal. Two seats, one focused and one not, pin that down - and
 * ime.c's ime_enable()/ime_reset_preedit() both return early on a seat with
 * no text-input manager and no preedit, so no compositor is needed. */
static void
test_cursor_shape(void)
{
    struct terminal *term = term_new();
    struct wayland wl = {0};
    struct wl_window win = {0};
    static struct config conf; /* too large for the stack */
    memset(&conf, 0, sizeof(conf));

    term->wl = &wl;
    term->window = &win;
    term->conf = &conf;
    term->scale = 1.0f;
    term->width = 100;
    term->height = 50;

    conf.csd.title_height = 20;
    conf.csd.border_width = 1;

    struct seat seat = {0};
    seat.wayl = &wl;
    seat.mouse_focus = term;

    wl.key_binding_manager = key_binding_manager_new();

    /* term_mouse_grabbed() */
    term->mouse_tracking = MOUSE_NONE;
    check(term_mouse_grabbed(term, &seat),
          "mouse tracking off reports the mouse as grabbed");

    term->mouse_tracking = MOUSE_CLICK;
    check(!term_mouse_grabbed(term, &seat),
          "mouse tracking without a grab modifier is not grabbed");

    /* xcursor_for_csd_border(): corners first, then the border sides. */
    term->active_surface = TERM_SURF_BORDER_LEFT;
    check(xcursor_for_csd_border(term, 0, 5) == CURSOR_SHAPE_TOP_LEFT_CORNER,
          "left border, near the top, is the top-left corner");
    check(xcursor_for_csd_border(term, 0, 60) == CURSOR_SHAPE_LEFT_SIDE,
          "left border, below the title bar, is the left side");
    win.is_constrained_left = true;
    check(xcursor_for_csd_border(term, 0, 60) == CURSOR_SHAPE_LEFT_PTR,
          "a constrained left border falls back to the pointer");
    win.is_constrained_left = false;

    term->active_surface = TERM_SURF_BORDER_RIGHT;
    check(xcursor_for_csd_border(term, 0, 5) == CURSOR_SHAPE_TOP_RIGHT_CORNER,
          "right border, near the top, is the top-right corner");
    check(xcursor_for_csd_border(term, 0, 60) == CURSOR_SHAPE_RIGHT_SIDE,
          "right border, below the title bar, is the right side");

    term->active_surface = TERM_SURF_BORDER_TOP;
    check(xcursor_for_csd_border(term, 5, 0) == CURSOR_SHAPE_TOP_LEFT_CORNER,
          "top border, left end, is the top-left corner");
    check(xcursor_for_csd_border(term, 95, 0) == CURSOR_SHAPE_TOP_RIGHT_CORNER,
          "top border, right end, is the top-right corner");
    check(xcursor_for_csd_border(term, 50, 0) == CURSOR_SHAPE_TOP_SIDE,
          "top border, middle, is the top side");
    win.is_constrained_top = true;
    check(xcursor_for_csd_border(term, 50, 0) == CURSOR_SHAPE_LEFT_PTR,
          "a constrained top border falls back to the pointer");
    check(xcursor_for_csd_border(term, 5, 0) == CURSOR_SHAPE_LEFT_PTR,
          "a constrained top border has no corners either");
    win.is_constrained_top = false;

    term->active_surface = TERM_SURF_BORDER_BOTTOM;
    check(xcursor_for_csd_border(term, 5, 0) == CURSOR_SHAPE_BOTTOM_LEFT_CORNER,
          "bottom border, left end, is the bottom-left corner");
    check(xcursor_for_csd_border(term, 95, 0) == CURSOR_SHAPE_BOTTOM_RIGHT_CORNER,
          "bottom border, right end, is the bottom-right corner");
    check(xcursor_for_csd_border(term, 50, 0) == CURSOR_SHAPE_BOTTOM_SIDE,
          "bottom border, middle, is the bottom side");

    /* term_xcursor_update(): a terminal that isn't on any surface asks for no
     * cursor at all. The seats are visited, but left alone. */
    term->active_surface = TERM_SURF_NONE;
    struct seat s0 = {0};
    struct seat s1 = {0};
    s0.pointer.shape = CURSOR_SHAPE_HIDDEN; /* sentinel */
    s1.pointer.shape = CURSOR_SHAPE_HIDDEN;
    tll_push_back(wl.seats, s0);
    tll_push_back(wl.seats, s1);
    term_xcursor_update(term);
    check(tll_front(wl.seats).pointer.shape == CURSOR_SHAPE_HIDDEN &&
          tll_back(wl.seats).pointer.shape == CURSOR_SHAPE_HIDDEN,
          "TERM_SURF_NONE leaves every seat's cursor untouched");
    tll_free(wl.seats);

    key_binding_manager_destroy(wl.key_binding_manager);

    term->window = NULL;
    term->wl = NULL;
    term->conf = NULL;
    term_free(term);
}

static void
test_delayed_render(void)
{
    struct terminal *term = term_new();

    int lower = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    int upper = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    xassert(lower >= 0 && upper >= 0);

    term->delayed_render_timer.lower_fd = lower;
    term->delayed_render_timer.upper_fd = upper;
    term->delayed_render_timer.is_armed = true;

    check(!fdm_delayed_render(NULL, lower, EPOLLHUP, term),
          "EPOLLHUP tears the delayed render timer down");

    check(fdm_delayed_render(NULL, lower, EPOLLIN, term),
          "an unexpired delayed-render timer is a no-op");
    check(term->delayed_render_timer.is_armed,
          "a no-op delayed render leaves the timers armed");

    check(fdm_delayed_render(NULL, -1, EPOLLIN, term),
          "a foreign fd is a no-op");

    close(lower);
    close(upper);
    term->delayed_render_timer.is_armed = false;
    term->delayed_render_timer.lower_fd = -1;
    term->delayed_render_timer.upper_fd = -1;
    term_free(term);
}

static void
test_render_workers(void)
{
    struct terminal *term = term_new();

    term->render.workers.count = 1;
    check(initialize_render_workers(term), "one render worker starts");

    check(term->render.workers.threads != NULL,
          "the worker thread array is allocated");

    /* The worker is blocked in sem_wait() on the start semaphore, so a
     * trywait on it must not succeed. */
    check(sem_trywait(&term->render.workers.start) == -1 && errno == EAGAIN,
          "the render worker is waiting for work");

    /* term_destroy() posts -2 to the queue, which makes the worker return,
     * and then joins it. */
    check(term_destroy(term) == 0, "destroying the terminal joins the worker");
}

static void
test_utmp(void)
{
    struct terminal *term = term_new();
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    term->conf = &conf;

    check(add_utmp_record(&conf, NULL, -1),
          "no pty means no utmp add record");
    check(del_utmp_record(&conf, NULL, -1),
          "no pty means no utmp del record");

    check(add_utmp_record(&conf, NULL, 0),
          "no utmp helper means no utmp add record");
    check(del_utmp_record(&conf, NULL, 0),
          "no utmp helper means no utmp del record");

    term->conf = NULL;
    term_free(term);
}

static void
test_kbd_focus_out(void)
{
    struct terminal *term = term_new();
    struct wayland wl = {0};
    term->wl = &wl;

    term_kbd_focus_out(term);
    check(!term->kbd_focus, "focus-out on an unfocused terminal is a no-op");

    term->kbd_focus = true;
    struct seat focused = {0};
    focused.wayl = &wl;
    focused.kbd_focus = term;
    tll_push_back(wl.seats, focused);
    term_kbd_focus_out(term);
    check(term->kbd_focus,
          "focus-out keeps the focus while a seat is focused on us");
    tll_free(wl.seats);

    int slave = term_capture_begin(term);
    term->focus_events = true;
    term_kbd_focus_out(term);
    char buf[8];
    term_capture_read(slave, buf, sizeof(buf));
    check(!term->kbd_focus, "focus-out clears the keyboard focus");
    check(strcmp(buf, "\033[O") == 0,
          "focus-out reports the escape when focus events are on");
    term->focus_events = false;
    term_capture_end(term, slave);

    term->wl = NULL;
    term_free(term);
}

static void
test_surface_kind(void)
{
    struct terminal *term = term_new();
    struct wl_window win = {0};
    term->window = &win;

    /* Every surface gets its own address: the unset ones are NULL in C
     * too, and NULL matches the first NULL surface in the CSD array. */
    char surf[CSD_SURF_COUNT + 1];
    win.surface.surf = (struct wl_surface *)&surf[0];
    for (int i = 0; i < CSD_SURF_COUNT; i++)
        win.csd.surface[i].surface.surf = (struct wl_surface *)&surf[i + 1];
    struct wl_surface *grid_surf = (struct wl_surface *)&surf[0];
    struct wl_surface *title_surf = (struct wl_surface *)&surf[1 + CSD_SURF_TITLE];
    struct wl_surface *close_surf = (struct wl_surface *)&surf[1 + CSD_SURF_CLOSE];

    check(term_surface_kind(term, grid_surf) == TERM_SURF_GRID,
          "the window surface is the grid");
    check(term_surface_kind(term, title_surf) == TERM_SURF_TITLE,
          "the title CSD surface is the title");
    check(term_surface_kind(term, close_surf) == TERM_SURF_BUTTON_CLOSE,
          "the close CSD surface is the close button");
    check(term_surface_kind(term, NULL) == TERM_SURF_NONE,
          "an unknown surface has no kind");

    term->window = NULL;
    term_free(term);
}

static void
test_shutdown(void)
{
    struct terminal *term = term_new();
    static struct config conf;
    memset(&conf, 0, sizeof(conf));
    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);

    term->conf = &conf;
    term->fdm = fdm;
    term->slave = 0; /* no client application: nothing to terminate */
    term->ptmx = -1;
    term->selection.auto_scroll.fd = -1;
    term->render.app_sync_updates.timer_fd = -1;
    term->render.app_id.timer_fd = -1;
    term->render.icon.timer_fd = -1;
    term->render.title.timer_fd = -1;
    term->delayed_render_timer.lower_fd = -1;
    term->delayed_render_timer.upper_fd = -1;
    term->blink.fd = -1;
    term->flash.fd = -1;
    term->cursor_blink.fd = -1;
    term->shutdown.terminate_timeout_fd = -1;

    check(term_shutdown(term), "term_shutdown() starts the shutdown");
    check(term->shutdown.in_progress, "shutdown is in progress");
    check(term->shutdown.client_has_terminated,
          "a terminal without a client counts as terminated");
    check(term->ptmx == -1, "shutdown releases the pty");
    check(term->delayed_render_timer.lower_fd == -1 &&
          term->delayed_render_timer.upper_fd == -1,
          "shutdown closes the delayed-render timers");
    check(term_shutdown(term), "a second term_shutdown() is a no-op");

    /* fdm_client_terminated() records the status and asks whether the
     * shutdown is complete - here the window is still mapped, so it is not. */
    struct terminal *term2 = term_new();
    struct wl_window win = {0};
    conf.hold_at_exit = true;
    term2->conf = &conf;
    term2->window = &win;
    term2->shutdown.in_progress = true;
    term2->shutdown.terminate_timeout_fd = -1;
    fdm_client_terminated(NULL, 1234, 7, term2);
    check(term2->shutdown.client_has_terminated,
          "a dead slave marks the client as terminated");
    check(term2->shutdown.exit_status == 7,
          "the slave's exit status is recorded");

    term2->window = NULL;
    term_free(term2);
    fdm_destroy(fdm);
    term_free(term);
}

static void
test_destroy(void)
{
    /* A bare terminal (no window, no wayland client, no slave) tears itself
     * down. */
    struct terminal *term = term_new();
    check(term_destroy(term) == 0, "destroying a bare terminal succeeds");

    check(term_destroy(NULL) == 0, "destroying NULL is a no-op");
}

static void
test_term_reset(void)
{
    struct terminal *term = term_new();
    static struct config conf;
    memset(&conf, 0, sizeof(conf));
    /* term_reset()'s hard path allocates rows in both grids; the harness's
     * term_new() only sets up the normal one. */
    term->alt.num_rows = SCROLLBACK_ROWS;
    term->alt.num_cols = COLS;
    term->alt.rows = xcalloc(SCROLLBACK_ROWS, sizeof(term->alt.rows[0]));
    xassert(term->alt.rows != NULL);

    conf.title = "foot";
    conf.initial_color_theme = COLOR_THEME_DARK;
    term->conf = &conf;
    term->blink.fd = -1;

    /* Both the title and the app-id refresh go straight into a wayland
     * request unless it is within 8.3 ms of the previous update; stamp the
     * timers so they take the (harmless) timerfd path instead. */
    struct wl_window win = {0};
    term->window = &win;
    clock_gettime(CLOCK_MONOTONIC, &term->render.title.last_update);
    clock_gettime(CLOCK_MONOTONIC, &term->render.app_id.last_update);

    /* Soft reset: modes only. */
    term->reverse = true;
    term->mouse_tracking = MOUSE_DRAG;
    term->charsets.selected = G1;
    term->focus_events = true;
    term->insert_mode = true;
    term->vt.state = 42;
    term->colors.active_theme = COLOR_THEME_LIGHT;

    term_reset(term, false);

    check(!term->reverse, "soft reset clears reverse video");
    check(term->mouse_tracking == MOUSE_NONE, "soft reset disables mouse tracking");
    check(term->charsets.selected == G0, "soft reset selects G0");
    check(!term->focus_events, "soft reset disables focus events");
    check(!term->insert_mode, "soft reset disables insert mode");
    check(term->vt.state == 0, "soft reset returns the VT parser to ground");
    check(term->colors.active_theme == COLOR_THEME_LIGHT,
          "soft reset keeps the colour theme");
    check(strcmp(term->vt.osc8.uri == NULL ? "" : term->vt.osc8.uri, "") == 0,
          "soft reset drops any pending OSC 8 URI");

    /* Hard reset: everything, including the grid and the theme. */
    term->grid = &term->alt;
    term->origin = ORIGIN_RELATIVE;
    term->colors.active_theme = COLOR_THEME_LIGHT;
    term->cursor_blink.decset = true;

    term_reset(term, true);

    check(term->grid == &term->normal, "hard reset returns to the normal grid");
    check(term->origin == ORIGIN_ABSOLUTE, "hard reset clears origin mode");
    check(term->colors.active_theme == COLOR_THEME_DARK,
          "hard reset reapplies the initial colour theme");
    check(!term->cursor_blink.decset, "hard reset clears DECSET 12");
    check(term->normal.cur_row == term->normal.rows[0] &&
          term->alt.cur_row == term->alt.rows[0],
          "hard reset points both grids at their first row");
    check(term->scroll_region.start == 0 && term->scroll_region.end == term->rows,
          "hard reset restores the full scroll region");

    term->window = NULL;
    term->conf = NULL;
    check(term_destroy(term) == 0, "a reset terminal still destroys cleanly");
}

static void
test_term_init_failure(void)
{
    static struct config conf;
    memset(&conf, 0, sizeof(conf));
    struct wayland wl = {0};

    /* The pty is opened before anything else is touched, so a bogus path
     * exercises term_init()'s first error path (and its close_fds cleanup). */
    struct terminal *term = term_init(
        &conf, NULL, NULL, &wl, "foot", "/tmp", NULL, "/nonexistent/pty",
        0, NULL, NULL, 0, NULL, NULL, NULL);
    check(term == NULL, "a terminal whose pty cannot be opened is not created");
}

static void
test_ime(void)
{
    struct wayland wl = {0};
    struct terminal *term = term_new();
    term->wl = &wl;

    struct seat focused = {0};
    focused.wayl = &wl;
    focused.kbd_focus = term;
    focused.ime_focus = term;
    tll_push_back(wl.seats, focused);

    struct seat elsewhere = {0};
    elsewhere.wayl = &wl;
    tll_push_back(wl.seats, elsewhere);

    struct seat *s0 = &tll_front(wl.seats);
    struct seat *s1 = &tll_back(wl.seats);

    check(!term_ime_is_enabled(term), "IME starts disabled");
    term_ime_enable(term);
    check(term_ime_is_enabled(term), "term_ime_enable enables IME");
    term_ime_enable(term);
    check(term_ime_is_enabled(term), "enabling twice is harmless");
    term_ime_disable(term);
    check(!term_ime_is_enabled(term), "term_ime_disable disables IME");

    term_ime_set_cursor_rect(term, 7, 9, 1, 2);
    check(s0->ime.cursor_rect.pending.x == 7 &&
          s0->ime.cursor_rect.pending.y == 9 &&
          s0->ime.cursor_rect.pending.width == 1 &&
          s0->ime.cursor_rect.pending.height == 2,
          "cursor rect goes to the focused seat");
    check(s1->ime.cursor_rect.pending.width == 0 &&
          s1->ime.cursor_rect.pending.height == 0,
          "cursor rect skips seats focused elsewhere");

    check(term_ime_reset(term), "term_ime_reset reports the focused seat");
    s0->kbd_focus = NULL;
    check(!term_ime_reset(term),
          "term_ime_reset is false once no seat is focused");

    tll_free(wl.seats);
    term_free(term);
}

/* quirks.zig: the weston CSD-subsurface workaround. The subsurfaces are
 * poison pointers, so any path that reaches wl_subsurface_set_{de,}sync()
 * crashes instead of silently passing. */
static void
test_quirks(void)
{
    struct terminal *term = term_new();
    struct wl_window *win = xcalloc(1, sizeof(*win));
    term->window = win;

    win->csd_mode = CSD_YES;
    win->is_fullscreen = false;
    for (int i = 0; i < CSD_SURF_COUNT; i++)
        win->csd.surface[i].sub = (struct wl_subsurface *)0x1;

    /* Not weston: both entry points must return before touching anything. */
    unsetenv("WESTON_CONFIG_FILE");
    quirk_weston_csd_on(term);
    quirk_weston_csd_off(term);
    check(true, "weston quirk is inert without WESTON_CONFIG_FILE");

    /* is_weston() caches its answer on the first call, so prime it inside a
     * child: on "weston", a non-CSD window and a fullscreen window must both
     * stay inert too (the guards run before the first desync). */
    for (int variant = 0; variant < 2; variant++) {
        pid_t pid = fork();
        if (pid == 0) {
            setenv("WESTON_CONFIG_FILE", "/dev/null", 1);
            win->csd_mode = variant == 0 ? CSD_NO : CSD_YES;
            win->is_fullscreen = variant == 1;
            quirk_weston_csd_on(term);
            quirk_weston_csd_off(term);
            _exit(0);
        }

        int status = 0;
        waitpid(pid, &status, 0);
        check(WIFEXITED(status) && WEXITSTATUS(status) == 0,
              variant == 0
              ? "non-CSD window is not desynced on weston"
              : "fullscreen window is not desynced on weston");
    }

    free(win);
    term_free(term);
}

/* foot-features.zig: the --version feature line, now assembled at comptime
 * from build options instead of #ifdefs. Check the shape it must keep: the
 * "version: " prefix, then the six feature tokens in their fixed order, each
 * either enabled or disabled. */
static void
test_version_and_features(void)
{
    static const char *const order[] = {
        "pgo", "ime", "graphemes", "toplevel-tag", "blur", "assertions",
    };

    check(strncmp(version_and_features, "version: ", 9) == 0,
          "version string starts with \"version: \"");

    const char *p = version_and_features;
    bool ordered = true;
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
        const char *hit = strstr(p, order[i]);
        if (hit == NULL || (hit[-1] != '+' && hit[-1] != '-'))
            ordered = false;
        else
            p = hit;
    }
    check(ordered, "version string lists the features in order");

    /* Nothing may follow the last token. */
    check(p[strlen(order[5])] == '\0',
          "version string ends after the last feature");
}

/* log.c: level filtering, formatting, errno suffix, colour and the level
 * name helpers. */
static void
test_log(void)
{
    struct log_capture cap;
    char buf[8192];

    /* Level filtering + format arguments + file:line prefix. */
    log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_WARNING);

    if (!log_capture_begin(&cap)) {
        printf("skip: cannot capture stderr\n");
        log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);
        return;
    }
    log_msg(LOG_CLASS_INFO, "harness", "file.c", 123, "info %d %s", 42, "arg");
    log_capture_end(&cap, buf, sizeof(buf));
    check(buf[0] == '\0', "messages below the log level are dropped");

    if (!log_capture_begin(&cap)) {
        log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);
        return;
    }
    log_msg(LOG_CLASS_WARNING, "harness", "file.c", 123, "warn %d %s", 42, "arg");
    log_capture_end(&cap, buf, sizeof(buf));
    check(strcmp(buf, "warn: file.c:123: warn 42 arg\n") == 0,
          "messages are formatted with the file:line prefix");

    /* errno suffix, both implicit and provided. */
    log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_DEBUG);

    if (!log_capture_begin(&cap)) {
        log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);
        return;
    }
    errno = ENOENT;
    log_errno(LOG_CLASS_ERROR, "harness", "file.c", 7, "open failed");
    log_capture_end(&cap, buf, sizeof(buf));
    check(strstr(buf, " err: file.c:7: open failed: ") != NULL &&
          strstr(buf, strerror(ENOENT)) != NULL,
          "log_errno appends the current errno string");

    if (!log_capture_begin(&cap)) {
        log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);
        return;
    }
    log_errno_provided(LOG_CLASS_ERROR, "harness", "file.c", 8, EACCES,
                       "exec failed %d", 3);
    log_capture_end(&cap, buf, sizeof(buf));
    check(strstr(buf, "exec failed 3: ") != NULL &&
          strstr(buf, strerror(EACCES)) != NULL,
          "log_errno_provided uses the given errno");

    /* Colour output. */
    log_init(LOG_COLORIZE_ALWAYS, false, LOG_FACILITY_USER, LOG_CLASS_DEBUG);

    if (!log_capture_begin(&cap)) {
        log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);
        return;
    }
    log_msg(LOG_CLASS_ERROR, "harness", "file.c", 1, "coloured");
    log_capture_end(&cap, buf, sizeof(buf));
    check(strstr(buf, "\033[31m") != NULL && strstr(buf, "\033[0m") != NULL &&
          strstr(buf, "\033[2m") != NULL,
          "colourised output uses the level colour and dim file prefix");

    /* A syslog-only sink must not write to stderr below its level either. */
    log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_NONE);
    if (log_capture_begin(&cap)) {
        log_msg(LOG_CLASS_ERROR, "harness", "file.c", 1, "suppressed");
        log_capture_end(&cap, buf, sizeof(buf));
        check(buf[0] == '\0', "LOG_CLASS_NONE suppresses all messages");
    }

    log_init(LOG_COLORIZE_NEVER, false, LOG_FACILITY_USER, LOG_CLASS_ERROR);

    /* Level name helpers. */
    check(log_level_from_string("none") == LOG_CLASS_NONE,
          "log level names parse");
    check(log_level_from_string("warning") == LOG_CLASS_WARNING,
          "log level names parse (warning)");
    check(log_level_from_string("") == -1, "an empty level name is invalid");
    check(log_level_from_string("bogus") == -1, "an unknown level name is invalid");
#if defined(_DEBUG)
    check(log_level_from_string("debug") == LOG_CLASS_DEBUG,
          "debug is a valid level in debug builds");
#else
    check(log_level_from_string("debug") == -1,
          "debug is hidden in non-debug builds");
#endif

    const char *hint = log_level_string_hint();
    check(strstr(hint, "'none'") != NULL && strstr(hint, "'error'") != NULL,
          "the level hint lists the valid names");
    check(log_level_string_hint() == hint,
          "the level hint is built once");
}


/* Run `fn()` in a forked child with stderr redirected to a memfd, and
 * return the captured output (in a static buffer) plus the wait status. */
static char child_stderr[8192];

static size_t
capture_child_stderr(void (*fn)(void), int *status)
{
    fflush(stderr);

    int cap = memfd_create("foot-harness-debug", 0);
    check(cap >= 0, "memfd for stderr capture");

    pid_t pid = fork();
    if (pid == 0) {
        dup2(cap, STDERR_FILENO);
        fn();
        _exit(0);
    }

    waitpid(pid, status, 0);

    ssize_t n = -1;
    if (lseek(cap, 0, SEEK_SET) >= 0)
        n = read(cap, child_stderr, sizeof(child_stderr) - 1);
    close(cap);

    size_t len = n > 0 ? (size_t)n : 0;
    child_stderr[len] = '\0';
    return len;
}

static void
call_bug(void)
{
    bug("file.c", 42, "my_func", "value=%d/%s", 7, "x");
}

static void
call_fatal_error(void)
{
    fatal_error("fatal.c", 7, "boom", ENOENT);
}

/* user-notification.c and debug.c: the printf-style notification helper and
 * the two abort paths. */
static void
test_debug(void)
{
    /* user_notification_add_fmt() formats and appends a notification. */
    user_notifications_t notes = tll_init();
    user_notification_add_fmt(&notes, USER_NOTIFICATION_WARNING,
                              "value=%d/%s", 42, "x");
    user_notification_add_fmt(&notes, USER_NOTIFICATION_ERROR, "second");

    check(tll_length(notes) == 2, "user_notification_add_fmt appends");
    check(tll_length(notes) == 2 &&
          strcmp(tll_front(notes).text, "value=42/x") == 0,
          "user_notification_add_fmt formats its arguments");
    check(tll_length(notes) == 2 &&
          tll_front(notes).kind == USER_NOTIFICATION_WARNING,
          "user_notification_add_fmt keeps the kind");
    check(tll_length(notes) == 2 &&
          strcmp(tll_back(notes).text, "second") == 0,
          "user_notification_add_fmt appends at the back");
    user_notifications_free(&notes);


    /* bug() reports the formatted message and aborts. */
    int status = 0;
    size_t len = capture_child_stderr(call_bug, &status);

    check(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
          "bug() aborts");
    check(len > 0 && strstr(child_stderr, "file.c:42: BUG in my_func(): value=7/x") != NULL,
          "bug() reports the formatted BUG message");

    /* fatal_error() reports strerror() and aborts. */
    len = capture_child_stderr(call_fatal_error, &status);

    check(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
          "fatal_error aborts");
    check(len > 0 && strstr(child_stderr, "fatal.c:7: boom: ") != NULL &&
          strstr(child_stderr, strerror(ENOENT)) != NULL,
          "fatal_error reports strerror()");
}


/* unicode-mode.c: Ctrl+Shift+u hex input, exercised against a real pty so
 * that the generated UTF-8 really goes through term_to_slave(). */
static void
test_unicode_mode(void)
{
    int ptmx = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (ptmx < 0 || grantpt(ptmx) < 0 || unlockpt(ptmx) < 0) {
        printf("skip: cannot allocate a pty\n");
        return;
    }

    const char *pts_name = ptsname(ptmx);
    int pts = pts_name != NULL ? open(pts_name, O_RDWR | O_NOCTTY) : -1;
    if (pts < 0) {
        printf("skip: cannot open the pty slave\n");
        close(ptmx);
        return;
    }

    /* Raw mode: the default canonical line discipline would hold the
     * generated bytes back until a newline arrives. */
    struct termios tio;
    if (tcgetattr(pts, &tio) == 0) {
        cfmakeraw(&tio);
        tcsetattr(pts, TCSANOW, &tio);
    }

    struct terminal *term = term_new();
    term->ptmx = ptmx;

    struct seat seat = {0};

    /* Activate resets the state. */
    unicode_mode_activate(term);
    check(term->unicode_mode.active, "unicode mode activates");
    check(term->unicode_mode.count == 0 && term->unicode_mode.character == 0,
          "unicode mode starts empty");

    /* Six hex digits are accumulated, extra digits are ignored. */
    unicode_mode_input(&seat, term, XKB_KEY_1);
    unicode_mode_input(&seat, term, XKB_KEY_f);
    unicode_mode_input(&seat, term, XKB_KEY_6);
    unicode_mode_input(&seat, term, XKB_KEY_0);
    check(term->unicode_mode.character == 0x1f60 && term->unicode_mode.count == 4,
          "hex digits are accumulated");

    unicode_mode_input(&seat, term, XKB_KEY_0);
    unicode_mode_input(&seat, term, XKB_KEY_0);
    unicode_mode_input(&seat, term, XKB_KEY_0);
    check(term->unicode_mode.count == 6,
          "at most six digits are accepted");

    /* Backspace shifts a digit out. */
    unicode_mode_input(&seat, term, XKB_KEY_BackSpace);
    check(term->unicode_mode.count == 5, "backspace drops a digit");

    /* Escape, q and Ctrl+<c/d/g> cancel the mode. */
    seat.kbd.ctrl = true;
    unicode_mode_input(&seat, term, XKB_KEY_q);
    check(!term->unicode_mode.active, "q cancels unicode mode");
    check(seat.kbd.last_shortcut_sym == XKB_KEY_q,
          "cancelling records the shortcut sym");

    unicode_mode_activate(term);
    seat.kbd.ctrl = true;
    unicode_mode_input(&seat, term, XKB_KEY_c);
    check(!term->unicode_mode.active, "ctrl+c cancels unicode mode");

    /* Return commits: U+1F600 must reach the pty as UTF-8. */
    seat.kbd.ctrl = false;
    unicode_mode_activate(term);
    unicode_mode_input(&seat, term, XKB_KEY_1);
    unicode_mode_input(&seat, term, XKB_KEY_f);
    unicode_mode_input(&seat, term, XKB_KEY_6);
    unicode_mode_input(&seat, term, XKB_KEY_0);
    unicode_mode_input(&seat, term, XKB_KEY_0);
    unicode_mode_input(&seat, term, XKB_KEY_Return);
    check(!term->unicode_mode.active,
          "Return commits and deactivates unicode mode");
    check(seat.kbd.last_shortcut_sym == XKB_KEY_Return,
          "committing records the shortcut sym");

    char out[64];
    size_t len = read_pty(pts, out, sizeof(out));
    check(len == 4 && (unsigned char)out[0] == 0xf0 &&
          (unsigned char)out[1] == 0x9f && (unsigned char)out[2] == 0x98 &&
          (unsigned char)out[3] == 0x80,
          "the selected codepoint is written to the pty as UTF-8");

    /* Non-hex keys are ignored while the mode is active. */
    unicode_mode_activate(term);
    unicode_mode_input(&seat, term, 0x1008ff00); /* XF86AudioMute */
    check(term->unicode_mode.count == 0,
          "non-hex keys are ignored");

    unicode_mode_deactivate(term);
    check(!term->unicode_mode.active, "unicode mode deactivates");

    close(pts);
    close(ptmx);

    /* unicode_mode_updated(NULL) is a no-op (C allows the NULL). */
    unicode_mode_updated(NULL);
    check(true, "unicode_mode_updated(NULL) is a no-op");
}


/* A terminal with a real font loaded, for tests that need cell metrics. */
static struct terminal *
term_with_fonts(struct config *conf_out)
{
    struct config_font *cfg_font = xcalloc(1, sizeof(*cfg_font));
    cfg_font->pt_size = 8.0f;

    conf_out->fonts[0] = (struct config_font_list){.count = 1, .arr = cfg_font};
    conf_out->line_height = (struct pt_or_px){.px = -1, .pt = 0};

    struct terminal *term = term_new();
    term->conf = conf_out;
    term->scale = 1.0f;

    struct config_font *cur_font = xcalloc(1, sizeof(*cur_font));
    cur_font->pt_size = 8.0f;
    term->font_sizes[0] = cur_font;
    for (size_t i = 1; i < 4; i++)
        term->font_sizes[i] = xcalloc(0, 1);

    const char *name = "monospace";
    struct fcft_font *fonts[4];
    for (size_t i = 0; i < 4; i++)
        fonts[i] = fcft_from_name(1, &name, ":size=8");

    if (fonts[0] == NULL) {
        for (size_t i = 0; i < 4; i++) {
            if (fonts[i] != NULL)
                fcft_destroy(fonts[i]);
        }
        term_free(term);
        return NULL;
    }

    if (!term_set_fonts(term, fonts, false)) {
        term_free(term);
        return NULL;
    }

    struct wl_window *win = xcalloc(1, sizeof(*win));
    term->window = win;
    struct wayland *wl = xcalloc(1, sizeof(*wl));
    term->wl = wl;

    return term;
}

static void
term_with_fonts_free(struct terminal *term)
{
    for (size_t i = 0; i < 4; i++) {
        if (term->fonts[i] != NULL)
            fcft_destroy(term->fonts[i]);
    }
    free(term->window);
    free(term->wl);
    term_free(term);
}

/* Number of set pixels in a rendered glyph (handles a8 and a1 formats). */
static size_t
glyph_pixels(const struct fcft_glyph *glyph)
{
    const uint8_t *data = (const uint8_t *)pixman_image_get_data(glyph->pix);
    const int stride = pixman_image_get_stride(glyph->pix);
    size_t n = 0;

    switch ((int)pixman_image_get_format(glyph->pix)) {
    case PIXMAN_a8:
        for (int y = 0; y < glyph->height; y++) {
            for (int x = 0; x < glyph->width; x++) {
                if (data[y * stride + x] != 0)
                    n++;
            }
        }
        break;

    case PIXMAN_a1:
        for (int y = 0; y < glyph->height; y++) {
            for (int x = 0; x < glyph->width; x++) {
                if (data[y * stride + x / 8] & (0x80 >> (x % 8)))
                    n++;
            }
        }
        break;
    }

    return n;
}

/* Number of non-zero coverage bytes in a rendered box-drawing glyph. */
static size_t
glyph_nonzero(const struct fcft_glyph *glyph)
{
    const uint8_t *data = (const uint8_t *)pixman_image_get_data(glyph->pix);
    const int stride = pixman_image_get_stride(glyph->pix);
    size_t n = 0;

    for (int y = 0; y < glyph->height; y++) {
        for (int x = 0; x < glyph->width; x++) {
            if (data[y * stride + x] != 0)
                n++;
        }
    }
    return n;
}

/* Fill row/column occupancy bits for a rendered glyph. */
static void
glyph_occupancy(const struct fcft_glyph *glyph, bool *rows, bool *cols)
{
    const uint8_t *data = (const uint8_t *)pixman_image_get_data(glyph->pix);
    const int stride = pixman_image_get_stride(glyph->pix);

    for (int y = 0; y < glyph->height; y++) {
        rows[y] = false;
        for (int x = 0; x < glyph->width; x++) {
            if (data[y * stride + x] != 0)
                rows[y] = true;
        }
    }

    for (int x = 0; x < glyph->width; x++) {
        cols[x] = false;
        for (int y = 0; y < glyph->height; y++) {
            if (data[y * stride + x] != 0)
                cols[x] = true;
        }
    }
}

/* FNV-1a over the rendered bitmap, for manual differential checks:
 * FOOT_BOX_DUMP=1 ./tests/test-terminal prints one line per codepoint. */
static uint64_t
glyph_hash(const struct fcft_glyph *glyph)
{
    const uint8_t *data = (const uint8_t *)pixman_image_get_data(glyph->pix);
    const int stride = pixman_image_get_stride(glyph->pix);

    uint64_t h = 1469598103934665603ull;
    for (int y = 0; y < glyph->height; y++) {
        for (int x = 0; x < stride; x++) {
            h ^= data[y * stride + x];
            h *= 1099511628211ull;
        }
    }
    return h;
}

static void
box_dump(struct terminal *term)
{
    static const struct {
        char32_t first, last;
    } ranges[] = {
        {0x2500, 0x259f},
        {0x1fb00, 0x1fb8b},
        {0x1cc00, 0x1cde5},
    };

    for (size_t r = 0; r < sizeof(ranges) / sizeof(ranges[0]); r++) {
        for (char32_t cp = ranges[r].first; cp <= ranges[r].last; cp++) {
            struct fcft_glyph *g = box_drawing(term, cp);
            if (g == NULL)
                continue;
            printf("BOX 0x%05x %d %d %016llx\n", (unsigned)cp, g->width,
                   g->height, (unsigned long long)glyph_hash(g));

            const char *want = getenv("FOOT_BOX_PIXELS");
            if (want != NULL && strtoul(want, NULL, 0) == cp) {
                const uint8_t *data =
                    (const uint8_t *)pixman_image_get_data(g->pix);
                const int stride = pixman_image_get_stride(g->pix);
                printf("PIX fmt=%#" PRIx32 " stride=%d\n",
                       (uint32_t)pixman_image_get_format(g->pix), stride);
                for (int y = 0; y < g->height; y++) {
                    printf("ROW %2d:", y);
                    for (int x = 0; x < stride; x++)
                        printf(" %02x", data[y * stride + x]);
                    printf("\n");
                }
            }
            free(g);
        }
    }
}

/* Structural invariants of box-drawing.c's rendering. Font-independent:
 * nothing here assumes a particular cell size, only proportions. */
static void
test_box_drawing(void)
{
    struct config conf = {0};
    struct terminal *term = term_with_fonts(&conf);

    if (term == NULL) {
        printf("skip: no monospace font available\n");
        return;
    }

    const int width = term->cell_width;
    const int height = term->cell_height;

    if (getenv("FOOT_BOX_DUMP") != NULL) {
        box_dump(term);
        term_with_fonts_free(term);
        return;
    }

    if (pixman_image_get_format(box_drawing(term, 0x2500)->pix) != PIXMAN_a8) {
        printf("skip: box drawing renders without an alpha channel\n");
        term_with_fonts_free(term);
        return;
    }

    /* 0x2500 light horizontal: a contiguous band of rows, each completely
     * filled, spanning the full cell width. */
    struct fcft_glyph *g = box_drawing(term, 0x2500);
    check(g != NULL && g->width == width && g->height == height,
          "box_drawing fills the cell");

    bool rows[256] = {0}, cols[256] = {0};
    glyph_occupancy(g, rows, cols);
    check(cols[0] && cols[width - 1],
          "light horizontal spans the full cell width");

    int first = -1, last = -1, bands = 0;
    for (int y = 0; y < height; y++) {
        if (rows[y]) {
            if (first < 0)
                first = y;
            if (last >= 0 && y != last + 1)
                bands++;
            last = y;
        }
    }
    check(first >= 0 && last >= 0 && bands == 0,
          "light horizontal is a single contiguous band");
    check(last - first + 1 >= 1 && last - first + 1 <= height / 3,
          "light horizontal is at most a third of the cell tall");
    check(glyph_nonzero(g) == (size_t)width * (last - first + 1),
          "light horizontal fills its band completely");

    size_t light_px = glyph_nonzero(g);
    free(g);

    /* 0x2501 heavy horizontal is thicker than the light one. */
    g = box_drawing(term, 0x2501);
    size_t heavy_px = glyph_nonzero(g);
    free(g);
    check(heavy_px > light_px && heavy_px <= (size_t)width * height,
          "heavy horizontal is thicker than light");

    /* 0x2502 light vertical: symmetric invariant in the other axis. */
    g = box_drawing(term, 0x2502);
    glyph_occupancy(g, rows, cols);
    check(rows[0] && rows[height - 1],
          "light vertical spans the full cell height");
    check(glyph_nonzero(g) % (size_t)height == 0,
          "light vertical fills whole columns");
    free(g);

    /* 0x2588 full block covers everything; 0x2580 the upper half. */
    g = box_drawing(term, 0x2588);
    check(glyph_nonzero(g) == (size_t)width * height, "full block fills the cell");
    free(g);

    g = box_drawing(term, 0x2580);
    check(glyph_nonzero(g) >= (size_t)width * (height / 2) &&
          glyph_nonzero(g) <= (size_t)width * (height / 2 + 1),
          "upper half block covers half the cell");
    free(g);

    /* Shades get progressively darker. */
    size_t shade[3];
    const char32_t shade_cp[3] = {0x2591, 0x2592, 0x2593};
    for (int i = 0; i < 3; i++) {
        g = box_drawing(term, shade_cp[i]);
        shade[i] = glyph_pixels(g);
        free(g);
    }
    check(shade[0] < shade[1] && shade[1] < shade[2],
          "shade blocks get darker in order");
    check(shade[0] > 0 && shade[2] < (size_t)width * height,
          "shades are strictly between empty and solid");

    /* With box-drawing-solid-shades, the dithered a1 pattern is replaced by
     * a flat fill at 25%/50%/75% coverage: the buffer must have been switched
     * to a8 and every pixel must hold the same value. */
    struct config solid_conf = {0};
    solid_conf.tweak.box_drawing_solid_shades = true;
    struct terminal *solid = term_with_fonts(&solid_conf);
    if (solid != NULL) {
        static const uint8_t want[3] = {0x40, 0x80, 0xc0};

        for (int i = 0; i < 3; i++) {
            struct fcft_glyph *sg = box_drawing(solid, shade_cp[i]);
            const uint8_t *sd =
                (const uint8_t *)pixman_image_get_data(sg->pix);
            const int sstride = pixman_image_get_stride(sg->pix);

            bool flat = pixman_image_get_format(sg->pix) == PIXMAN_a8;
            for (int y = 0; y < sg->height && flat; y++) {
                for (int x = 0; x < sg->width; x++) {
                    if (sd[y * sstride + x] != want[i])
                        flat = false;
                }
            }

            check(flat, "solid shades fill the cell uniformly");
            free(sg);
        }

        term_with_fonts_free(solid);
    }

    /* Quadrants cover a quarter of the cell, in the right corner. */
    g = box_drawing(term, 0x2596); /* lower left */
    const uint8_t *qdata = (const uint8_t *)pixman_image_get_data(g->pix);
    const int qstride = pixman_image_get_stride(g->pix);
    size_t qn = glyph_nonzero(g);
    check(qn > (size_t)width * height / 8 && qn < (size_t)width * height / 2,
          "lower-left quadrant covers roughly a quarter");
    check(qdata[0] == 0 && qdata[(height - 1) * qstride] != 0,
          "lower-left quadrant is in the lower-left corner");
    free(g);

    /* Legacy computing / octant codepoints do not render empty. */
    const char32_t extra[] = {0x1fb00, 0x1fb3c, 0x1fb70, 0x1fb82, 0x1cd00};
    for (size_t i = 0; i < sizeof(extra) / sizeof(extra[0]); i++) {
        g = box_drawing(term, extra[i]);
        check(g != NULL && glyph_nonzero(g) > 0,
              "extended block codepoints render");
        if (g != NULL)
            free(g);
    }

    term_with_fonts_free(term);
}


static void
test_search(void)
{
    struct terminal *term = term_new();

    /* search_begin() needs a real wayland surface, so initialise the query
     * buffer by hand the same way it does. */
    term->is_searching = true;
    term->search.sz = 64;
    term->search.buf = xmalloc(term->search.sz * sizeof(term->search.buf[0]));
    term->search.buf[0] = U'\0';
    term->search.match = (struct coord){-1, -1};

    struct row *old = term->normal.rows[3];
    term->normal.rows[3] = row_new("hello");
    grid_row_free(old);

    search_add_chars(term, "ll", 2);
    check(term->search.len == 2, "search_add_chars() appends to the query");
    check(term->search.buf[0] == U'l' && term->search.buf[1] == U'l' &&
          term->search.buf[2] == U'\0', "search_add_chars() writes the chars");

    search_find_next(term, SEARCH_FORWARD);
    check(term->search.match.row == 3 && term->search.match.col == 2,
          "search finds \"ll\" in row 3, col 2");
    check(term->search.match_len == 2, "the match is as long as the query");

    struct search_match_iterator iter = search_matches_new_iter(term);
    struct range r = search_matches_next(&iter);
    check(r.start.row == 3 && r.start.col == 2, "iterator: first match starts at 3,2");
    check(r.end.row == 3 && r.end.col == 3, "iterator: first match ends at 3,3");

    r = search_matches_next(&iter);
    check(r.start.row == -1 && r.end.row == -1, "iterator: no more matches");

    search_selection_cancelled(term);
    check(term->search.match.row == -1 && term->search.match_len == 0,
          "search_selection_cancelled() clears the match");

    /* Editing through search_input(): the search binding set is a plain
     * tll, so a one-entry list is enough to reach every action. */
    struct key_binding_set bindings = {0};
    struct seat seat = {0};
    xkb_keysym_t raw[1] = {XKB_KEY_Left};

    term->search.buf[0] = U'h';
    term->search.buf[1] = U'i';
    term->search.buf[2] = U'\0';
    term->search.len = 2;
    term->search.cursor = 2;

    struct key_binding kb = {0};
    kb.type = KEY_BINDING;
    kb.action = BIND_ACTION_SEARCH_EDIT_LEFT;
    kb.k.sym = XKB_KEY_Left;
    tll_push_back(bindings.search, kb);

    search_input(&seat, term, &bindings, 0, XKB_KEY_Left, 0, 0, raw, 1, 0);
    check(term->search.cursor == 1, "search_input(EDIT_LEFT) moves the cursor");
    check(seat.kbd.last_shortcut_sym == XKB_KEY_Left,
          "search_input() records the shortcut symbol");

    kb.action = BIND_ACTION_SEARCH_DELETE_PREV;
    tll_pop_back(bindings.search);
    tll_push_back(bindings.search, kb);
    search_input(&seat, term, &bindings, 0, XKB_KEY_Left, 0, 0, raw, 1, 0);
    check(term->search.len == 1 && term->search.cursor == 0,
          "search_input(DELETE_PREV) removes the char before the cursor");
    check(term->search.buf[0] == U'i' && term->search.buf[1] == U'\0',
          "search_input(DELETE_PREV) shifts the tail left");

    kb.action = BIND_ACTION_SEARCH_EDIT_END;
    tll_pop_back(bindings.search);
    tll_push_back(bindings.search, kb);
    search_input(&seat, term, &bindings, 0, XKB_KEY_Left, 0, 0, raw, 1, 0);
    check(term->search.cursor == 1, "search_input(EDIT_END) jumps to the end");

    kb.action = BIND_ACTION_SEARCH_DELETE_TO_START;
    tll_pop_back(bindings.search);
    tll_push_back(bindings.search, kb);
    search_input(&seat, term, &bindings, 0, XKB_KEY_Left, 0, 0, raw, 1, 0);
    check(term->search.len == 0 && term->search.cursor == 0,
          "search_input(DELETE_TO_START) empties the query");

    /* FIND_NEXT on an empty query resurrects the last query */
    term->search.last.buf = xmalloc(4 * sizeof(term->search.last.buf[0]));
    term->search.last.buf[0] = U'h';
    term->search.last.buf[1] = U'e';
    term->search.last.buf[2] = U'\0';
    term->search.last.len = 2;

    kb.action = BIND_ACTION_SEARCH_FIND_NEXT;
    tll_pop_back(bindings.search);
    tll_push_back(bindings.search, kb);
    search_input(&seat, term, &bindings, 0, XKB_KEY_Left, 0, 0, raw, 1, 0);
    check(term->search.len == 2 && term->search.last.buf == NULL,
          "search_input(FIND_NEXT) restores the last query");
    check(term->search.match.row == 3 && term->search.match.col == 0,
          "search_input(FIND_NEXT) finds \"he\" in row 3");

    tll_free(bindings.search);
    free(term->search.buf);
    term_free(term);
}


static void
test_output(void)
{
    struct wayland wayl = {0};
    struct monitor mon = {0};
    mon.wayl = &wayl;
    mon.scale = 1;

    /* 300mm x 200mm: 11.81" x 7.87", diagonal 14.19" */
    output_geometry(&mon, NULL, 0, 0, 300, 200,
                    WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB, "make", "model",
                    WL_OUTPUT_TRANSFORM_NORMAL);
    check_text(mon.make, "make", "output_geometry() stores make");
    check_text(mon.model, "model", "output_geometry() stores model");
    check(mon.subpixel == WL_OUTPUT_SUBPIXEL_HORIZONTAL_RGB,
          "output_geometry() stores the subpixel order");
    check(fabsf(mon.inch - 14.1f) < 0.2f, "output_geometry() computes the diagonal");

    output_mode(&mon, NULL, WL_OUTPUT_MODE_CURRENT, 2880, 1800, 60000);
    check(mon.dim.px_real.width == 2880 && mon.dim.px_real.height == 1800,
          "output_mode() stores the current mode");
    check(mon.refresh == 60.0f, "output_mode() converts refresh to Hz");
    check(mon.ppi.real.x >= 240 && mon.ppi.real.x <= 248,
          "output_mode() yields ~244 PPI");

    /* A non-current mode is ignored */
    output_mode(&mon, NULL, 0, 800, 600, 0);
    check(mon.dim.px_real.width == 2880, "output_mode() ignores non-current modes");

    output_scale(&mon, NULL, 2);
    check(mon.scale == 2, "output_scale() stores the scale");

    xdg_output_handle_logical_position(&mon, NULL, 10, 20);
    check(mon.x == 10 && mon.y == 20, "logical_position() stores the position");

    xdg_output_handle_logical_size(&mon, NULL, 1440, 900);
    check(mon.dim.px_scaled.width == 1440 && mon.dim.px_scaled.height == 900,
          "logical_size() stores the scaled size");
    check(mon.ppi.scaled.x >= 120 && mon.ppi.scaled.x <= 124,
          "logical_size() yields ~122 logical PPI");
    check(mon.dpi.physical >= 238 && mon.dpi.physical <= 242,
          "dpi.physical follows the diagonal");
    check(mon.dpi.scaled >= 236 && mon.dpi.scaled <= 244,
          "dpi.scaled applies the output scale");

    xdg_output_handle_name(&mon, NULL, "DP-1");
    check_text(mon.name, "DP-1", "xdg_output name is stored");
    output_name(&mon, NULL, "DP-2");
    check_text(mon.name, "DP-2", "wl_output name replaces the xdg one");
    output_name(&mon, NULL, NULL);
    check(mon.name == NULL, "a NULL name clears it");

    xdg_output_handle_description(&mon, NULL, "Dell U2720Q");
    check_text(mon.description, "Dell U2720Q", "description is stored");
    xdg_output_handle_description(&mon, NULL, "other");
    check_text(mon.description, "other", "description is replaced");

    clock_id(&wayl, NULL, 7);
    check(wayl.presentation_clock_id == 7, "clock_id() stores the clock id");

    free(mon.make);
    free(mon.model);
    free(mon.description);
}


static void
test_csd_visibility(void)
{
    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};

    win.term = &term;
    term.conf = &conf;
    win.csd_mode = CSD_YES;

    check(wayl_win_csd_titlebar_visible(&win), "CSDs: titlebar is visible");
    check(wayl_win_csd_borders_visible(&win), "CSDs: borders are visible");

    win.is_fullscreen = true;
    check(!wayl_win_csd_titlebar_visible(&win), "fullscreen hides the titlebar");
    check(!wayl_win_csd_borders_visible(&win), "fullscreen hides the borders");

    win.is_fullscreen = false;
    win.is_maximized = true;
    check(!wayl_win_csd_borders_visible(&win), "maximized hides the borders");
    check(wayl_win_csd_titlebar_visible(&win),
          "maximized keeps the titlebar unless configured otherwise");

    conf.csd.hide_when_maximized = true;
    check(!wayl_win_csd_titlebar_visible(&win),
          "hide-when-maximized hides the titlebar");

    win.is_maximized = false;
    win.csd_mode = CSD_NO;
    check(!wayl_win_csd_titlebar_visible(&win), "CSD_NO hides the titlebar");
    check(!wayl_win_csd_borders_visible(&win), "CSD_NO hides the borders");

    win.csd_mode = CSD_UNKNOWN;
    check(!wayl_win_csd_titlebar_visible(&win), "an unknown CSD mode hides the titlebar");
}

int
main(void)
{
    /* c32rtomb()/mbrtoc32() need a UTF-8 locale, like foot's main(). */
    setlocale(LC_ALL, "C.UTF-8");

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
    test_emoji_vs_table();
    test_search();
    test_output();
    test_csd_visibility();
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
    test_dpi_and_scale();
    test_font_size_adjustments();
    test_shm_lifetime();
    test_shm_cache();
    test_shm_chain();
    test_shm_scroll();
    test_slave_spawn();
    test_ime();
    test_cursor_shape();
    test_delayed_render();
    test_render_workers();
    test_utmp();
    test_kbd_focus_out();
    test_surface_kind();
    test_shutdown();
    test_destroy();
    test_term_reset();
    test_term_init_failure();
    test_quirks();
    test_version_and_features();
    test_log();
    test_debug();
    test_unicode_mode();
    test_box_drawing();

    fcft_fini();

    if (failures > 0) {
        fprintf(stderr, "%d harness check(s) failed\n", failures);
        return 1;
    }

    printf("terminal harness: all checks passed\n");
    return 0;
}
