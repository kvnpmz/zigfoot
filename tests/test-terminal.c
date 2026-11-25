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
#include "render.h"
#include "shm.h"
#include "slave.h"
#include "log.h"
#include "box-drawing.h"
#include "foot-features.h"
#include "quirks.h"
#include <pixman.h>
#include <presentation-time.h>
#include <sys/time.h>
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
#include <pthread.h>
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

/* Ported to render.zig; exposed for the harness only. */
unsigned render_presentation_frame_count(int64_t total_us, float refresh);
int render_url_format_label(char32_t *label, const char32_t *key,
                            const char32_t *url, bool show_url,
                            size_t entered_key_len, int max_cols);
void render_dirty_overflowing_glyphs(struct terminal *term);
/* Ported to input.zig (D4a). */
const struct key_data *keymap_lookup(struct terminal *term,
                                         xkb_keysym_t sym,
                                         enum modifier mods);
const struct key_data *keymap_data_for_sym(xkb_keysym_t sym,
                                           size_t *count);
struct kbd_ctx;
bool legacy_kbd_protocol(struct seat *seat, struct terminal *term,
                          const struct kbd_ctx *ctx);
bool kitty_kbd_protocol(struct seat *seat, struct terminal *term,
                        const struct kbd_ctx *ctx);
void mouse_coord_pixel_to_cell(struct seat *seat, const struct terminal *term,
                               int x, int y);
void mouse_button_state_reset(struct seat *seat);
bool touch_is_active(const struct seat *seat);
double mouse_scroll_multiplier(const struct terminal *term,
                               const struct seat *seat);
bool keysym_is_modifier(xkb_keysym_t keysym);
void modifier_string(xkb_mod_mask_t mods, size_t sz,
                     char mod_str[static sz], const struct seat *seat);
bool start_repeater(struct seat *seat, uint32_t key);
bool stop_repeater(struct seat *seat, uint32_t key);
void keyboard_modifiers(void *data, struct wl_keyboard *wl_keyboard,
                        uint32_t serial, uint32_t mods_depressed,
                        uint32_t mods_latched, uint32_t mods_locked,
                        uint32_t group);
void keyboard_enter(void *data, struct wl_keyboard *wl_keyboard,
                    uint32_t serial, struct wl_surface *surface,
                    struct wl_array *keys);
void keyboard_leave(void *data, struct wl_keyboard *wl_keyboard,
                    uint32_t serial, struct wl_surface *surface);
bool render_xcursor_set(struct seat *seat, struct terminal *term,
                       enum cursor_shape shape);
void render_buffer_release_callback(struct buffer *buf, void *data);
bool render_resize(struct terminal *term, int width, int height,
                   uint8_t opts);
void set_size_from_grid(struct terminal *term, int *width,
                        int *height, int cols, int rows);
size_t render_search_box_glyph_offset(
    size_t glyph_offset, size_t visible_cells, size_t total_cells,
    size_t cursor_cell_idx);
void presented(void *data, struct wp_presentation_feedback *feedback,
               uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec,
               uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo,
               uint32_t flags);

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


static void
test_wayland_misc(void)
{
    struct wayland wayl = {0};
    struct config conf = {0};
    struct terminal term = {0};
    struct wl_window win = {0};

    term.wl = &wayl;
    term.conf = &conf;
    win.term = &term;

    conf.gamma_correct = false;
    check(!wayl_do_linear_blending(&wayl, &conf),
          "linear blending needs gamma-correct");

    conf.gamma_correct = true;
    check(!wayl_do_linear_blending(&wayl, &conf),
          "linear blending needs an image description");

    wayl.color_management.img_description = (struct wp_image_description_v1 *)&wayl;
    check(wayl_do_linear_blending(&wayl, &conf),
          "linear blending is on with both prerequisites");

    /* A pending urgency token short-circuits before talking to the compositor */
    win.urgency_token_is_pending = true;
    check(wayl_win_set_urgent(&win), "a pending urgency token is not requested twice");
    check(win.urgency_token_is_pending, "the pending flag stays set");
    win.urgency_token_is_pending = false;

    wayl.system_bell = NULL;
    check(!wayl_win_ring_bell(&win), "no system bell protocol means no bell");

    /* Destroying a sub-surface with nothing in it must be a no-op */
    struct wayl_sub_surface empty = {0};
    wayl_win_subsurface_destroy(&empty);
    check(empty.surface.surf == NULL && empty.sub == NULL,
          "destroying an empty sub-surface is a no-op");
    wayl_win_subsurface_destroy(NULL);

    /* Cursor theme reload short-circuits when nothing changed */
    struct seat s2 = {0};
    void *fake_theme = &s2;
    s2.pointer.theme = (struct wl_cursor_theme *)fake_theme;
    s2.pointer.scale = 2.0f;
    check(wayl_reload_xcursor_theme(&s2, 2.0f),
          "an unchanged cursor theme is reused");
    check((void *)s2.pointer.theme == fake_theme, "the existing theme is kept");

    struct seat s3 = {0};
    s3.pointer.shape_device = (struct wp_cursor_shape_device_v1 *)fake_theme;
    check(wayl_reload_xcursor_theme(&s3, 1.5f),
          "server-side cursors skip the client theme load");

    /* CSD teardown drops the font and every surface */
    struct terminal cterm = {0};
    struct config cconf = {0};
    struct wl_window cwin = {0};
    struct buffer_chain csd_chain = {0};

    cterm.conf = &cconf;
    cterm.window = &cwin;
    cwin.term = &cterm;
    cterm.render.chains.csd = &csd_chain;

    const char *csd_pattern = "monospace";
    cwin.csd.font = fcft_from_name(1, &csd_pattern, "pixelsize=12");
    check(cwin.csd.font != NULL, "a CSD font loads for the teardown test");
    csd_destroy(&cwin);
    check(cwin.csd.font == NULL, "csd_destroy() releases the CSD font");
    check(cwin.csd.surface[CSD_SURF_TITLE].surface.surf == NULL,
          "csd_destroy() clears the CSD surfaces");

    /* csd_reload_font() does nothing without CSDs, or when they are hidden */
    cwin.csd_mode = CSD_NO;
    csd_reload_font(&cwin, -1.0f);
    check(cwin.csd.font == NULL, "no CSD font is loaded when CSDs are off");

    cwin.csd_mode = CSD_YES;
    cwin.is_fullscreen = true;
    csd_reload_font(&cwin, -1.0f);
    check(cwin.csd.font == NULL, "no CSD font is loaded while fullscreen");

    /* monitor_destroy() frees every string and tolerates absent globals */
    struct monitor mon2 = {0};
    mon2.make = xstrdup("make");
    mon2.model = xstrdup("model");
    mon2.name = xstrdup("NAME-1");
    mon2.description = xstrdup("desc");
    monitor_destroy(&mon2);
    check(true, "monitor_destroy() frees the strings and survives no wl objects");

    /* update_term_for_output_change() walks on_outputs; a shut-down terminal
     * is skipped, which is what keeps the harness out of the render code. */
    struct wayland wl2 = {0};
    struct terminal t2 = {0};
    struct config c2 = {0};
    struct wl_window w2 = {0};

    t2.conf = &c2;
    t2.wl = &wl2;
    mon2.wayl = &wl2;
    t2.window = &w2;
    t2.shutdown.in_progress = true;
    w2.term = &t2;
    tll_push_back(w2.on_outputs, &mon2);
    tll_push_back(wl2.terms, &t2);

    output_done(&mon2, NULL);
    check(true, "output_done() skips terminals that are shutting down");

    tll_free(w2.on_outputs);
    tll_free(wl2.terms);

    wayl_win_destroy(NULL);
    check(true, "wayl_win_destroy(NULL) is a no-op");

    /* seat_destroy() walks the mouse-button list and every wl object */
    struct key_binding_manager *mgr = key_binding_manager_new();
    struct wayland wl4 = {0};
    struct seat s4 = {0};

    wl4.key_binding_manager = mgr;
    s4.wayl = &wl4;
    s4.name = xstrdup("seat0");
    s4.clipboard.text = xstrdup("clipboard");
    s4.kbd.repeat.fd = -1;

    struct button_tracker tracker = {0};
    tll_push_back(s4.mouse.buttons, tracker);
    check(tll_length(s4.mouse.buttons) == 1, "the seat has one tracked button");

    seat_destroy(&s4);
    check(tll_length(s4.mouse.buttons) == 0, "seat_destroy() empties the button list");

    struct seat s5 = {0};
    s5.kbd.repeat.fd = -1;
    tll_push_back(s5.mouse.buttons, tracker);
    seat_destroy(NULL);
    check(tll_length(s5.mouse.buttons) == 1, "seat_destroy(NULL) leaves other seats alone");
    tll_free(s5.mouse.buttons);
}


static void
test_configure(void)
{
    struct wl_window win = {0};
    struct wl_array array;

    /* xdg_toplevel.configure stores the state; nothing is applied yet */
    wl_array_init(&array);
    uint32_t *state = wl_array_add(&array, sizeof(uint32_t));
    *state = XDG_TOPLEVEL_STATE_MAXIMIZED;
    state = wl_array_add(&array, sizeof(uint32_t));
    *state = XDG_TOPLEVEL_STATE_ACTIVATED;
    state = wl_array_add(&array, sizeof(uint32_t));
    *state = XDG_TOPLEVEL_STATE_TILED_LEFT;
    state = wl_array_add(&array, sizeof(uint32_t));
    *state = XDG_TOPLEVEL_STATE_CONSTRAINED_BOTTOM;

    xdg_toplevel_configure(&win, NULL, 800, 600, &array);
    wl_array_release(&array);

    check(win.configure.width == 800 && win.configure.height == 600,
          "toplevel configure stores the size");
    check(win.configure.is_maximized, "toplevel configure sees maximized");
    check(win.configure.is_activated, "toplevel configure sees activated");
    check(win.configure.is_tiled_left, "toplevel configure sees tiled:left");
    check(win.configure.is_constrained_bottom,
          "toplevel configure sees constrained:bottom");
    check(!win.configure.is_fullscreen,
          "toplevel configure leaves unseen states false");
    check(!win.configure.is_resizing, "toplevel configure clears resizing");

    /* A second configure replaces the flags instead of accumulating them */
    wl_array_init(&array);
    state = wl_array_add(&array, sizeof(uint32_t));
    *state = XDG_TOPLEVEL_STATE_FULLSCREEN;
    xdg_toplevel_configure(&win, NULL, 1024, 768, &array);
    wl_array_release(&array);

    check(win.configure.is_fullscreen, "a new configure sets fullscreen");
    check(!win.configure.is_maximized, "a new configure clears maximized");
    check(win.configure.width == 1024, "a new configure updates the size");

    /* An empty state array clears everything */
    wl_array_init(&array);
    xdg_toplevel_configure(&win, NULL, 0, 0, &array);
    wl_array_release(&array);
    check(!win.configure.is_fullscreen && win.configure.width == 0,
          "an empty configure resets size and states");

    /* WM capabilities */
    win.wm_capabilities.maximize = true;
    win.wm_capabilities.minimize = true;

    wl_array_init(&array);
    uint32_t *cap = wl_array_add(&array, sizeof(uint32_t));
    *cap = XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE;
    xdg_toplevel_wm_capabilities(&win, NULL, &array);
    wl_array_release(&array);

    check(win.wm_capabilities.maximize, "wm_capabilities sees maximize");
    check(!win.wm_capabilities.minimize, "wm_capabilities clears unlisted caps");

    wl_array_init(&array);
    cap = wl_array_add(&array, sizeof(uint32_t));
    *cap = XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE;
    cap = wl_array_add(&array, sizeof(uint32_t));
    *cap = XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN;
    xdg_toplevel_wm_capabilities(&win, NULL, &array);
    wl_array_release(&array);

    check(win.wm_capabilities.minimize, "wm_capabilities sees minimize");
    check(!win.wm_capabilities.maximize, "wm_capabilities clears maximize");
}


static void
test_surface_listener(void)
{
    check(verify_iface_version("wl_seat", 5, 3), "a new enough interface is accepted");
    check(!verify_iface_version("wl_seat", 2, 3), "an old interface is rejected");

    struct wl_window win = {0};
    struct wayland wayl = {0};
    struct terminal term = {0};

    term.wl = &wayl;
    term.window = &win;
    win.term = &term;

    /* An output we do not know about is not added to the window */
    surface_leave(&win, NULL, NULL);
    surface_enter(&win, NULL, (struct wl_output *)&wayl);
    check(tll_length(win.on_outputs) == 0,
          "an unknown output is neither mapped nor unmapped");

    /* The same preferred scale is a no-op (no update_term_for_output_change) */
    win.preferred_buffer_scale = 2;
    surface_preferred_buffer_scale(&win, NULL, 2);
    check(win.preferred_buffer_scale == 2, "an unchanged preferred scale is ignored");

    surface_preferred_buffer_transform(&win, NULL, 1);
    check(true, "preferred_buffer_transform is a no-op");
}


static void
test_small_listeners(void)
{
    struct wayland wayl = {0};

    shm_format(&wayl, NULL, WL_SHM_FORMAT_ARGB2101010);
    shm_format(&wayl, NULL, WL_SHM_FORMAT_ABGR16161616);
    shm_format(&wayl, NULL, WL_SHM_FORMAT_XRGB8888);
    check(wayl.shm_have_argb2101010, "shm_format() records ARGB2101010");
    check(wayl.shm_have_abgr161616, "shm_format() records ABGR16161616");
    check(!wayl.shm_have_abgr2101010, "shm_format() ignores unseen formats");

    struct seat seat = {0};
    seat_handle_name(&seat, NULL, "seat0");
    check_text(seat.name, "seat0", "seat_handle_name() stores the name");
    seat_handle_name(&seat, NULL, "seat1");
    check_text(seat.name, "seat1", "seat_handle_name() replaces the name");
    free(seat.name);

    /* Decoration mode maps onto the pending CSD mode */
    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};

    term.conf = &conf;
    win.term = &term;
    conf.csd.preferred = CONF_CSD_PREFER_CLIENT;

    xdg_toplevel_decoration_configure(&win, NULL,
                                      ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    check(win.configure.csd_mode == CSD_NO, "server-side decoration mode disables CSDs");

    xdg_toplevel_decoration_configure(&win, NULL,
                                      ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    check(win.configure.csd_mode == CSD_YES, "client-side decoration mode enables CSDs");

    /* Background blur capability */
    ext_background_capabilities(&wayl, NULL, 1);
    check(wayl.have_background_blur, "the blur capability is recorded");
    ext_background_capabilities(&wayl, NULL, 0);
    check(!wayl.have_background_blur, "an empty capability set clears blur");

    /* Fractional scale: the same value is a no-op */
    win.scale = 1.5f;
    fractional_scale_preferred_scale(&win, NULL, 180);
    check(win.scale == 1.5f, "an unchanged fractional scale is ignored");
}


static void
test_wayl_init_failure(void)
{
    struct fdm *fdm = fdm_init();
    struct key_binding_manager *kbm = key_binding_manager_new();

    /* Point at a socket that does not exist so the connect fails and the
     * whole wayl_init() error path (which ends in wayl_destroy()) runs. */
    const char *old_display = getenv("WAYLAND_DISPLAY");
    char *saved = old_display != NULL ? strdup(old_display) : NULL;
    setenv("WAYLAND_DISPLAY", "wayland-does-not-exist", 1);

    struct wayland *wayl = wayl_init(fdm, kbm, false);
    check(wayl == NULL, "wayl_init() fails without a compositor");

    if (saved != NULL) {
        setenv("WAYLAND_DISPLAY", saved, 1);
        free(saved);
    } else
        unsetenv("WAYLAND_DISPLAY");

    wayl_destroy(NULL);
    check(true, "wayl_destroy(NULL) is a no-op");

    key_binding_manager_destroy(kbm);
    fdm_destroy(fdm);
}


static void
test_seat_capabilities(void)
{
    struct seat seat = {0};

    /* No capabilities: nothing is created, touch is inhibited */
    seat_handle_capabilities(&seat, NULL, 0);
    check(seat.wl_keyboard == NULL && seat.wl_pointer == NULL &&
          seat.wl_touch == NULL,
          "no capabilities creates no wl objects");
    check(seat.touch.state == TOUCH_STATE_INHIBITED,
          "no touch capability inhibits touch");

    /* Idempotent */
    seat_handle_capabilities(&seat, NULL, 0);
    check(seat.touch.state == TOUCH_STATE_INHIBITED,
          "repeating the empty capability set is harmless");
}


static void
test_handle_global(void)
{
    struct wayland wayl = {0};

    /* Unknown interfaces are ignored */
    handle_global(&wayl, NULL, 1, "wl_does_not_exist", 1);
    check(wayl.compositor == NULL && wayl.shm == NULL && wayl.shell == NULL,
          "an unknown global is ignored");

    /* Too old versions are rejected before binding */
    handle_global(&wayl, NULL, 1, "wl_compositor", 3);
    check(wayl.compositor == NULL, "a too-old compositor is rejected");

    handle_global(&wayl, NULL, 2, "wl_shm", 0);
    check(wayl.shm == NULL, "a too-old shm is rejected");

    handle_global(&wayl, NULL, 3, "wl_seat", 4);
    check(tll_length(wayl.seats) == 0, "a too-old seat is rejected");

    handle_global(&wayl, NULL, 4, "wl_output", 1);
    check(tll_length(wayl.monitors) == 0, "a too-old output is rejected");
}


static void
test_global_remove(void)
{
    struct wayland wayl = {0};

    /* Unknown global: nothing is touched, no fixes ack */
    handle_global_remove(&wayl, NULL, 0xdead);
    check(tll_length(wayl.monitors) == 0 && tll_length(wayl.seats) == 0,
          "removing an unknown global changes nothing");

    /* A monitor is looked up by wl_name and destroyed. (No wl_output proxy
     * here, so monitor_destroy() only has the strings to free.) */
    struct monitor mon = {0};
    mon.wayl = &wayl;
    mon.wl_name = 42;
    mon.name = xstrdup("DP-1");
    tll_push_back(wayl.monitors, mon);

    handle_global_remove(&wayl, NULL, 42);
    check(tll_length(wayl.monitors) == 0, "the removed monitor is dropped");

    /* A seat is looked up by wl_name and destroyed */
    wayl.key_binding_manager = key_binding_manager_new();
    struct seat seat = {0};
    seat.wayl = &wayl;
    seat.wl_name = 7;
    seat.kbd.repeat.fd = -1;
    tll_push_back(wayl.seats, seat);

    handle_global_remove(&wayl, NULL, 7);
    check(tll_length(wayl.seats) == 0, "the removed seat is dropped");
}

static uint32_t
pix_pixel(pixman_image_t *pix, int x, int y)
{
    const uint32_t *data = pixman_image_get_data(pix);
    const int stride = pixman_image_get_stride(pix) / 4;
    return data[y * stride + x];
}

/* D3a: the drawing primitives in render.zig */
static void
test_render_primitives(void)
{
    /* 8-bit channel expansion, linear vs sRGB */
    pixman_color_t lin = color_hex_to_pixman(0x00112233, false);
    check(lin.red == 0x1111 && lin.green == 0x2222 && lin.blue == 0x3333 &&
          lin.alpha == 0xffff,
          "color_hex_to_pixman expands the channels and fills alpha");

    pixman_color_t srgb = color_hex_to_pixman(0x00808080, true);
    pixman_color_t plain = color_hex_to_pixman(0x00808080, false);
    check(srgb.red < plain.red && srgb.green < plain.green,
          "the sRGB path goes through the decode table");

    pixman_color_t half = color_hex_to_pixman_with_alpha(0xffffffff, 0x8000, false);
    check(half.alpha == 0x8000 && half.red > 0x7f00 && half.red < 0x8100,
          "color_hex_to_pixman_with_alpha premultiplies by alpha");

    /* Blending */
    check(color_blend_towards(0x00102030, 0x00ffffff, 0) == 0x00102030,
          "blend towards with amount 0 is a no-op");
    uint32_t darker = color_blend_towards(0x00ff0000, 0x00000000, 0.5f);
    check((darker >> 16 & 0xff) < 0xff && (darker >> 16 & 0xff) > 0,
          "blend towards black dims a channel but keeps the hue");

    struct terminal term = {0};
    struct config conf = {0};
    term.conf = &conf;
    term.colors.active_theme = COLOR_THEME_DARK;
    conf.colors_dark.dim_blend_towards = DIM_BLEND_TOWARDS_BLACK;
    conf.dim.amount = 0.5f;

    uint32_t dimmed = color_dim(&term, 0x00ffffff);
    check(dimmed != 0x00ffffff && (dimmed >> 16 & 0xff) < 0xff,
          "color_dim() blends towards black by default");
    conf.colors_dark.dim_blend_towards = DIM_BLEND_TOWARDS_WHITE;
    check(color_dim(&term, 0x00000000) > 0,
          "color_dim() blends towards white for the light theme");

    /* custom dim: regular -> dim, bright -> regular */
    conf.colors_dark.use_custom.dim = 1;
    conf.colors_dark.dim[0] = 0x00123456;
    term.colors.table[0] = 0x00aaaaaa;
    term.colors.table[8] = 0x00bbbbbb;
    check(color_dim(&term, 0x00aaaaaa) == 0x00123456,
          "custom dim maps a regular color to its dim variant");
    check(color_dim(&term, 0x00bbbbbb) == 0x00aaaaaa,
          "custom dim maps a bright color to its regular variant");
    conf.colors_dark.use_custom.dim = 0;

    /* bold-in-bright */
    term.colors.table[1] = 0x00111111;
    term.colors.table[9] = 0x00222222;
    conf.bold_in_bright.palette_based = true;
    check(color_brighten(&term, 0x00111111) == 0x00222222,
          "palette-based bold-in-bright maps 0-7 to 8-15");
    check(color_brighten(&term, 0x00333333) == 0x00333333,
          "palette-based bold-in-bright leaves other colors alone");
    conf.bold_in_bright.palette_based = false;
    conf.bold_in_bright.amount = 0.5f;
    check(color_brighten(&term, 0x00000000) != 0,
          "amount-based bold-in-bright blends towards white");

    /* ── pixel tests on a real pixman image ───────────────────────── */
    enum { W = 64, H = 64 };
    uint32_t buf[W * H] = {0};
    pixman_image_t *pix =
        pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, buf, W * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    const pixman_color_t red = {.red = 0xffff, .green = 0, .blue = 0, .alpha = 0xffff};
    const pixman_color_t white = {.red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff};

    term.cell_width = 10;
    term.cell_height = 20;
    term.scale = 1.0f;

    draw_hollow_block(&term, pix, &white, 0, 0, 3);
    check(pix_pixel(pix, 0, 0) == 0xffffffff && pix_pixel(pix, 29, 0) == 0xffffffff,
          "hollow block paints the top and right borders");
    check(pix_pixel(pix, 15, 10) == 0,
          "hollow block leaves the middle empty");
    check(pix_pixel(pix, 0, 19) == 0xffffffff,
          "hollow block paints the bottom border");

    memset(buf, 0, sizeof(buf));
    conf.use_custom_underline_offset = true;
    conf.underline_offset.px = 5;
    conf.underline_thickness.px = 2;
    term.font_baseline = 10;
    draw_underline(&term, pix, NULL, &white, 0, 0, 3);
    check(pix_pixel(pix, 5, 15) == 0xffffffff && pix_pixel(pix, 5, 16) == 0xffffffff,
          "underline paints a band at the custom offset");
    check(pix_pixel(pix, 5, 14) == 0 && pix_pixel(pix, 5, 17) == 0,
          "underline thickness is respected");
    check(pix_pixel(pix, 29, 15) == 0xffffffff && pix_pixel(pix, 30, 15) == 0,
          "underline spans exactly the requested columns");

    const char *fontname = "monospace";
    struct fcft_font *font = fcft_from_name(1, &fontname, ":size=8");
    if (font == NULL)
        printf("skip: no font for the strikeout/beam checks\n");

    if (font != NULL) {
        memset(buf, 0, sizeof(buf));
        conf.strikeout_thickness.px = 2;
        draw_strikeout(&term, pix, font, &white, 0, 0, 3);
        int struck = 0;
        for (int y = 0; y < H; y++)
            struck += pix_pixel(pix, 0, y) != 0;
        check(struck == 2, "custom strikeout thickness wins over the font's");

        memset(buf, 0, sizeof(buf));
        conf.cursor.beam_thickness.px = 2;
        draw_beam_cursor(&term, pix, font, &white, 4, 2);
        int beam = 0;
        for (int x = 0; x < W; x++)
            beam += pix_pixel(pix, x, 10) != 0;
        check(beam == 2, "the beam cursor is beam_thickness pixels wide");
    }

    /* Block cursor: cursor_bg/fg unset -> fg, swapping against bg */
    memset(buf, 0, sizeof(buf));
    struct cell cell = {0};
    term.colors.cursor_bg = 0;
    term.colors.cursor_fg = 0;
    term.cursor_style = CURSOR_BLOCK;
    term.cursor_blink.state = CURSOR_BLINK_OFF;
    term.kbd_focus = true;
    pixman_color_t fg = red;
    pixman_color_t bg = {.red = 0, .green = 0, .blue = 0, .alpha = 0xffff};
    draw_cursor(&term, &cell, NULL, pix, &fg, &bg, 0, 0, 2);
    check(pix_pixel(pix, 5, 5) == 0xffff0000,
          "a block cursor fills the cell with the foreground color");
    check(fg.red == 0 && fg.alpha == 0xffff,
          "the text color becomes the background while the cursor is drawn");

    /* Unfocused + hollow: only a border, no fill */
    memset(buf, 0, sizeof(buf));
    term.kbd_focus = false;
    conf.cursor.unfocused_style = CURSOR_UNFOCUSED_HOLLOW;
    fg = red;
    draw_cursor(&term, &cell, NULL, pix, &fg, &bg, 0, 0, 2);
    check(pix_pixel(pix, 0, 0) == 0xffff0000 && pix_pixel(pix, 10, 10) == 0,
          "an unfocused hollow cursor is an outline");

    pixman_image_unref(pix);
    if (font != NULL)
        fcft_destroy(font);
}

/* D3b: cursor dirtying and the refresh flags */
static void
test_render_refresh(void)
{
    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};
    struct grid grid = {0};

    term.conf = &conf;
    term.window = &win;
    term.grid = &grid;

    struct row *rows[2] = {
        grid_row_alloc(4, true),
        grid_row_alloc(4, true),
    };
    grid.num_rows = 2;
    grid.num_cols = 4;
    grid.offset = 0;
    grid.view = 0;
    grid.rows = rows;

    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 4; c++)
            rows[r]->cells[c].attrs.clean = true;

    grid.cursor.point.row = 1;
    grid.cursor.point.col = 2;
    term.hide_cursor = false;
    dirty_cursor(&term);
    check(!rows[1]->cells[2].attrs.clean && rows[1]->dirty,
          "dirty_cursor() dirties the cell under the cursor");
    check(rows[1]->cells[1].attrs.clean,
          "dirty_cursor() leaves the neighbouring cells alone");

    term.hide_cursor = true;
    rows[1]->dirty = false;
    dirty_cursor(&term);
    check(!rows[1]->dirty, "dirty_cursor() does nothing while the cursor is hidden");
    term.hide_cursor = false;

    /* dirty_old_cursor() both dirties the old position and remembers the
     * new one. */
    rows[0]->dirty = false;
    rows[0]->cells[1].attrs.clean = true;
    term.render.last_cursor.row = rows[0];
    term.render.last_cursor.col = 1;
    term.render.last_cursor.hidden = false;

    dirty_old_cursor(&term);
    check(!rows[0]->cells[1].attrs.clean && rows[0]->dirty,
          "dirty_old_cursor() dirties the previous cursor cell");
    check(term.render.last_cursor.row == rows[1] &&
          term.render.last_cursor.col == 2,
          "dirty_old_cursor() records the new cursor position");
    check(!term.render.last_cursor.hidden,
          "dirty_old_cursor() records the cursor visibility");

    /* Refresh flags */
    term.render.refresh.grid = false;
    render_refresh(&term);
    check(term.render.refresh.grid, "render_refresh() requests a grid repaint");

    win.csd_mode = CSD_NO;
    term.render.refresh.csd = false;
    render_refresh_csd(&term);
    check(!term.render.refresh.csd, "no CSDs -> no CSD repaint");
    win.csd_mode = CSD_YES;
    render_refresh_csd(&term);
    check(term.render.refresh.csd, "CSDs -> CSD repaint requested");

    term.is_searching = false;
    render_refresh_search(&term);
    check(!term.render.refresh.search, "not searching -> no search repaint");

    /* The title/app-id updaters are rate limited; a real timerfd lets us
     * drive the "too soon" branch without a wayland window. */
    int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    if (tfd >= 0) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        memcpy(&term.render.title.last_update, &now, sizeof(now));
        memcpy(&term.render.app_id.last_update, &now, sizeof(now));
        memcpy(&term.render.icon.last_update, &now, sizeof(now));
        term.render.title.timer_fd = tfd;
        term.render.app_id.timer_fd = tfd;
        term.render.icon.timer_fd = tfd;
        win.csd_mode = CSD_YES;
        term.render.refresh.csd = false;

        /* Would dereference term.window->xdg_toplevel if not rate limited. */
        render_refresh_title(&term);
        render_refresh_app_id(&term);
        check(1, "the title/app-id updaters are rate limited");
        check(term.render.refresh.csd,
              "render_refresh_title() also refreshes the CSDs");

        /* The timer must have been armed with the remaining interval. */
        struct itimerspec its;
        check(timerfd_gettime(tfd, &its) == 0 && its.it_value.tv_nsec > 0,
              "the rate limiter arms the update timer");
        close(tfd);
    }

    free(rows[0]);
    free(rows[1]);
}

/* D3c: margin and urgency painting on a real buffer */
static void
test_render_margin(void)
{
    enum { W = 64, H = 64 };
    uint32_t pixels[W * H] = {0};
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, pixels, W * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    pixman_image_t *pix_arr[1] = {pix};
    pixman_region32_t dirty;
    pixman_region32_init(&dirty);

    struct buffer buf = {0};
    buf.width = W;
    buf.height = H;
    buf.stride = W * 4;
    buf.pix = pix_arr;
    buf.pix_instances = 1;
    buf.dirty = &dirty;

    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};
    term.conf = &conf;
    term.window = &win;
    term.wl = NULL;

    term.width = W;
    term.height = H;
    term.margins.top = term.margins.bottom = 4;
    term.margins.left = term.margins.right = 4;
    term.colors.bg = 0x00112233;
    term.colors.fg = 0x00445566;
    term.colors.alpha = 0xffff;
    term.cell_height = 8;

    render_margin(&term, &buf, 0, 7, false);
    check(pix_pixel(pix, 0, 0) == 0xff112233,
          "render_margin() fills the top margin with the background");
    check(pix_pixel(pix, 32, 32) == 0,
          "render_margin() leaves the cell grid untouched");
    check(pix_pixel(pix, 0, 32) == 0xff112233 && pix_pixel(pix, 63, 32) == 0xff112233,
          "render_margin() fills the side margins");
    check(pixman_region32_not_empty(&dirty),
          "render_margin() adds the margins to the buffer damage");

    /* reversed terminal swaps fg/bg */
    memset(pixels, 0, sizeof(pixels));
    term.reverse = true;
    render_margin(&term, &buf, 0, 7, false);
    check(pix_pixel(pix, 0, 0) == 0xff445566,
          "a reversed terminal uses the foreground for the margins");
    term.reverse = false;

    /* urgency: border painted in the "red" palette entry */
    memset(pixels, 0, sizeof(pixels));
    term.colors.table[1] = 0x00ff0000;
    term.render.urgency = true;
    render_margin(&term, &buf, 0, 7, false);
    check(pix_pixel(pix, 0, 0) == 0xffff0000,
          "the urgency hint paints the margin red");
    term.render.urgency = false;

    /* fullscreen drops the background alpha */
    memset(pixels, 0, sizeof(pixels));
    win.is_fullscreen = true;
    term.colors.alpha = 0x8000;
    render_margin(&term, &buf, 0, 7, false);
    check(pix_pixel(pix, 0, 0) == 0xff112233,
          "fullscreen margins stay opaque even with a translucent background");
    win.is_fullscreen = false;
    term.colors.alpha = 0xffff;

    pixman_region32_fini(&dirty);
    pixman_image_unref(pix);
}

/* D3d: CSD geometry */
static void
test_csd_data(void)
{
    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};

    term.conf = &conf;
    term.window = &win;
    win.term = &term;
    term.scale = 1.0f;
    term.width = 100;
    term.height = 50;
    win.csd_mode = CSD_YES;
    win.wm_capabilities.maximize = true;
    win.wm_capabilities.minimize = true;
    conf.csd.border_width = 1;
    conf.csd.title_height = 20;
    conf.csd.button_width = 10;

    struct csd_data title = get_csd_data(&term, CSD_SURF_TITLE);
    check(title.x == 0 && title.y == -20 && title.width == 100 &&
          title.height == 20, "the CSD titlebar spans the window width");

    struct csd_data left = get_csd_data(&term, CSD_SURF_LEFT);
    struct csd_data right = get_csd_data(&term, CSD_SURF_RIGHT);
    check(left.x == -1 && left.y == -20 && left.width == 1 && left.height == 70,
          "the left border starts left of the surface");
    check(right.x == 100 && right.width == 1 && right.height == 70,
          "the right border starts right of the surface");

    struct csd_data top = get_csd_data(&term, CSD_SURF_TOP);
    struct csd_data bottom = get_csd_data(&term, CSD_SURF_BOTTOM);
    check(top.x == -1 && top.y == -21 && top.width == 102 && top.height == 1,
          "the top border overlaps the titlebar corner");
    check(bottom.x == -1 && bottom.y == 50 && bottom.width == 102,
          "the bottom border sits below the surface");

    struct csd_data minimize = get_csd_data(&term, CSD_SURF_MINIMIZE);
    struct csd_data maximize = get_csd_data(&term, CSD_SURF_MAXIMIZE);
    struct csd_data close_btn = get_csd_data(&term, CSD_SURF_CLOSE);
    check(close_btn.x == 90 && close_btn.width == 10 && close_btn.height == 20,
          "the close button is the right-most one");
    check(maximize.x == 80 && maximize.width == 10,
          "the maximize button sits left of close");
    check(minimize.x == 70 && minimize.width == 10,
          "the minimize button sits left of maximize");

    /* Without the wm capability the button gets no width. */
    win.wm_capabilities.maximize = false;
    struct csd_data no_max = get_csd_data(&term, CSD_SURF_MAXIMIZE);
    check(no_max.width == 0 && no_max.x == 90,
          "no maximize capability -> a zero-width maximize button");
    win.wm_capabilities.maximize = true;

    /* Maximized hides the borders, not the titlebar. */
    win.is_maximized = true;
    check(get_csd_data(&term, CSD_SURF_LEFT).width == 0 &&
          get_csd_data(&term, CSD_SURF_TITLE).height == 20,
          "maximized drops the borders but keeps the titlebar");

    /* Narrow window: only the close button fits. */
    win.is_maximized = false;
    term.width = 15;
    check(get_csd_data(&term, CSD_SURF_CLOSE).x == 5 &&
          get_csd_data(&term, CSD_SURF_MAXIMIZE).width == 0,
          "a narrow window drops the buttons that do not fit");
}

/* D3d: render_csd_part() fills the whole CSD buffer */
static void
test_render_csd_part(void)
{
    enum { W = 16, H = 8 };
    uint32_t pixels[W * H] = {0};
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, pixels, W * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    pixman_image_t *pix_arr[1] = {pix};
    struct buffer buf = {0};
    buf.width = W;
    buf.height = H;
    buf.pix = pix_arr;
    buf.pix_instances = 1;

    struct terminal term = {0};
    struct wl_window win = {0};
    term.window = &win;
    win.csd_mode = CSD_YES;

    pixman_color_t color = {.red = 0, .green = 0xffff, .blue = 0, .alpha = 0xffff};
    render_csd_part(&term, NULL, &buf, W, H, &color);
    check(pix_pixel(pix, 0, 0) == 0xff00ff00 && pix_pixel(pix, W - 1, H - 1) == 0xff00ff00,
          "render_csd_part() fills the whole buffer");

    pixman_image_unref(pix);
}

/* D3e: render_cell() end-to-end on a real pixman image */
static uint32_t
pixman_color_to_argb(pixman_color_t c)
{
    return (uint32_t)(c.alpha >> 8) << 24 | (uint32_t)(c.red >> 8) << 16 |
        (uint32_t)(c.green >> 8) << 8 | (uint32_t)(c.blue >> 8);
}

static size_t
count_argb(pixman_image_t *pix, int w, int h, uint32_t argb)
{
    size_t n = 0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            n += pix_pixel(pix, x, y) == argb;
    return n;
}

static size_t
count_not_argb(pixman_image_t *pix, int w, int h, uint32_t argb)
{
    size_t n = 0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            n += pix_pixel(pix, x, y) != argb;
    return n;
}

static void
test_render_cell(void)
{
    struct config testconf = {0};
    struct terminal *term = term_with_fonts(&testconf);
    if (term == NULL) {
        printf("skip: no monospace font available\n");
        return;
    }

    enum { W = 80, H = 40 };
    uint32_t pixels[W * H] = {0};
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, pixels, W * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        term_with_fonts_free(term);
        return;
    }

    struct config *conf = &testconf;

    term->cols = 8;
    term->rows = 2;
    term->cell_width = 10;
    term->cell_height = 20;
    term->margins.top = term->margins.bottom = 0;
    term->margins.left = term->margins.right = 0;
    term->width = W;
    term->height = H;

    /* Non-default bg so "painted" is distinguishable from "untouched". */
    term->colors.bg = 0x000000ff;
    term->colors.fg = 0x00ffffff;
    term->colors.alpha = 0xffff;
    term->colors.selection_fg = 0;
    term->colors.selection_bg = 0;
    term->blink.fd = 5; /* no timer arming in the harness */
    conf->box_drawings_uses_font_glyphs = false;

    const uint32_t bg_argb =
        pixman_color_to_argb(color_hex_to_pixman(term->colors.bg, false));
    const uint32_t fg_argb =
        pixman_color_to_argb(color_hex_to_pixman(term->colors.fg, false));

    struct row *row = grid_row_alloc(term->cols, true);
    row->dirty = true;
    for (int c = 0; c < term->cols; c++)
        row->cells[c].attrs.clean = 0;

    /* ── empty cell: only the background ─────────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    check(render_cell(term, pix, NULL, row, 0, 0, false) == 1,
          "render_cell() returns one column for an ASCII cell");
    check(pix_pixel(pix, 5, 10) == bg_argb,
          "render_cell() fills the cell background");
    check(pix_pixel(pix, 15, 10) == 0,
          "render_cell() stays inside its cell");

    check(render_cell(term, pix, NULL, row, 0, 0, false) == 0,
          "a clean cell is skipped");

    /* ── a glyph ─────────────────────────────────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    row->cells[1].wc = 'A';
    row->cells[1].attrs.clean = 0;
    render_cell(term, pix, NULL, row, 0, 1, false);
    check(count_not_argb(pix, W, H, bg_argb) > 0,
          "render_cell() paints the glyph in the foreground color");
    check(pix_pixel(pix, 15, 10) == bg_argb,
          "the glyph never bleeds into the background area");

    /* ── conceal ─────────────────────────────────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    row->cells[2].wc = 'B';
    row->cells[2].attrs.clean = 0;
    row->cells[2].attrs.conceal = 1;
    render_cell(term, pix, NULL, row, 0, 2, false);
    check(count_argb(pix, W, H, fg_argb) == 0,
          "a concealed cell paints no glyph");

    /* ── box drawing goes through the custom glyph cache ─────────── */
    memset(pixels, 0, sizeof(pixels));
    row->cells[3].wc = 0x2500; /* light horizontal */
    row->cells[3].attrs.clean = 0;
    render_cell(term, pix, NULL, row, 0, 3, false);
    check(term->custom_glyphs.box_drawing != NULL,
          "box-drawing instantiates the custom glyph cache");
    check(count_not_argb(pix, W, H, bg_argb) > 0,
          "box drawing is rendered from the cache");

    /* ── underline ───────────────────────────────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    conf->use_custom_underline_offset = true;
    conf->underline_offset.px = 5;
    conf->underline_thickness.px = 2;
    term->font_baseline = 10;
    row->cells[4].wc = ' ';
    row->cells[4].attrs.clean = 0;
    row->cells[4].attrs.underline = 1;
    render_cell(term, pix, NULL, row, 0, 4, false);
    check(pix_pixel(pix, 45, 15) == fg_argb && pix_pixel(pix, 45, 16) == fg_argb,
          "render_cell() underlines in the foreground color");
    check(pix_pixel(pix, 45, 13) == bg_argb,
          "the underline is at the configured offset only");

    /* ── selection uses the selection colors ─────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    term->colors.selection_bg = 0x0000ff00; /* custom: top byte clear */
    term->colors.selection_fg = 0x00000000;
    row->cells[5].attrs.clean = 0;
    row->cells[5].attrs.selected = 1;
    render_cell(term, pix, NULL, row, 0, 5, false);
    check(pix_pixel(pix, 55, 10) == 0xff00ff00,
          "a selected cell uses the selection background");
    term->colors.selection_bg = 0;
    term->colors.selection_fg = 0;

    /* ── cursor ──────────────────────────────────────────────────── */
    memset(pixels, 0, sizeof(pixels));
    term->kbd_focus = true;
    term->cursor_style = CURSOR_BLOCK;
    term->cursor_blink.state = CURSOR_BLINK_OFF;
    row->cells[6].attrs.clean = 0;
    render_cell(term, pix, NULL, row, 1, 6, true);
    check(pix_pixel(pix, 65, 25) == fg_argb,
          "a focused block cursor is painted in the foreground color");
    term->kbd_focus = false;

    pixman_image_unref(pix);
    grid_row_free(row);
    term_with_fonts_free(term);
}

/* D3f: scroll damage */
static void
test_grid_render_scroll(void)
{
    /* 8 rows of 4 bytes, one byte per "pixel" so memmove is visible. */
    enum { ROWS = 8, STRIDE = 4 };
    uint8_t data[ROWS * STRIDE];
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < STRIDE; c++)
            data[r * STRIDE + c] = (uint8_t)(r + 1);

    pixman_region32_t dirty;
    pixman_region32_init(&dirty);

    /* shm_can_scroll()/shm_scroll() read the private part of the buffer;
     * a zeroed blob keeps `scrollable` false so the memmove path runs. */
    union {
        struct buffer buf;
        uint8_t pad[512];
    } storage = {0};
    struct buffer *bufp = &storage.buf;
    bufp->width = STRIDE;
    bufp->height = ROWS;
    bufp->stride = STRIDE;
    bufp->data = data;
    bufp->dirty = &dirty;

    struct terminal term = {0};
    struct wl_window win = {0};
    term.window = &win;
    term.cell_height = 1;
    term.rows = ROWS;
    term.cols = STRIDE;
    term.width = STRIDE;
    term.height = ROWS;

    struct damage dmg = {0};
    dmg.type = DAMAGE_SCROLL;
    dmg.region.start = 1;
    dmg.region.end = 6;
    dmg.lines = 2;

    grid_render_scroll(&term, bufp, &dmg);
    /* Rows 1..3 should now hold what used to be rows 3..5. */
    check(data[1 * STRIDE] == 4 && data[2 * STRIDE] == 5 && data[3 * STRIDE] == 6,
          "grid_render_scroll() moves the region up by the damage line count");
    check(data[0 * STRIDE] == 1 && data[4 * STRIDE] == 5,
          "grid_render_scroll() leaves rows outside the region alone");
    check(pixman_region32_not_empty(&dirty),
          "grid_render_scroll() adds the scrolled area to the damage");

    /* Reverse: rows 3..5 should become rows 1..3. */
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < STRIDE; c++)
            data[r * STRIDE + c] = (uint8_t)(r + 1);
    pixman_region32_fini(&dirty);
    pixman_region32_init(&dirty);

    grid_render_scroll_reverse(&term, bufp, &dmg);
    check(data[3 * STRIDE] == 2 && data[4 * STRIDE] == 3 && data[5 * STRIDE] == 4,
          "grid_render_scroll_reverse() moves the region down");
    check(data[0 * STRIDE] == 1,
          "grid_render_scroll_reverse() leaves the rows above alone");

    /* A scroll of the whole region is a no-op. */
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < STRIDE; c++)
            data[r * STRIDE + c] = (uint8_t)(r + 1);
    struct damage all = dmg;
    all.lines = (uint16_t)(all.region.end - all.region.start);
    grid_render_scroll(&term, bufp, &all);
    check(data[1 * STRIDE] == 2,
          "scrolling the entire region is a no-op (it is fully repainted)");

    pixman_region32_fini(&dirty);
}

/* D3g: sixel compositing */
static void
test_render_sixel(void)
{
    enum { SW = 40, SH = 40, SROWS = 8, SCOLS = 4 };
    uint32_t pixels[SW * SH] = {0};
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, SW, SH, pixels, SW * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    /* A 20x20 solid red sixel image */
    uint32_t img_pixels[20 * 20];
    for (size_t i = 0; i < 20 * 20; i++)
        img_pixels[i] = 0xffff0000;
    pixman_image_t *img = pixman_image_create_bits(PIXMAN_a8r8g8b8, 20, 20, img_pixels, 20 * 4);

    struct terminal term = {0};
    struct grid grid = {0};
    term.grid = &grid;
    term.cols = SCOLS;
    term.rows = 4;
    term.cell_width = 10;
    term.cell_height = 10;
    term.width = SW;
    term.height = SH;
    term.margins.top = term.margins.bottom = 0;
    term.margins.left = term.margins.right = 0;

    struct row *rows[SROWS];
    for (int r = 0; r < SROWS; r++) {
        rows[r] = grid_row_alloc(SCOLS, true);
        rows[r]->dirty = true;
        for (int c = 0; c < SCOLS; c++)
            rows[r]->cells[c].attrs.clean = 0;
    }
    grid.num_rows = SROWS;
    grid.num_cols = SCOLS;
    grid.offset = 0;
    grid.view = 0;
    grid.cursor.point.row = 0;
    grid.cursor.point.col = 0;
    grid.rows = rows;

    struct sixel six = {0};
    six.pos.row = 0;
    six.pos.col = 1;
    six.rows = 2;
    six.cols = 2;
    six.width = 20;
    six.height = 20;
    six.cell_width = 10;
    six.cell_height = 10;
    six.opaque = true;
    six.pix = img;
    tll_push_back(grid.sixel_images, six);

    /* The cursor sits outside the sixel; sixels dirty rows and clean cells. */
    struct coord cursor = {.row = 0, .col = 0};
    struct sixel *s = &tll_front(grid.sixel_images);

    render_sixel_images(&term, pix, NULL, &cursor);
    check(pix_pixel(pix, 10, 0) == 0xffff0000 && pix_pixel(pix, 29, 19) == 0xffff0000,
          "sixel images are composited at their cell position");
    check(pix_pixel(pix, 5, 5) == 0,
          "sixel images do not spill outside their cells");
    check(s->pos.col == 1 && s->width == 20,
          "sixel rendering leaves the image geometry alone");
    check(rows[0]->cells[1].attrs.clean && rows[1]->cells[2].attrs.clean,
          "an opaque sixel marks the cells it covers clean");
    check(rows[0]->dirty && rows[1]->dirty,
          "an opaque sixel keeps its rows dirty for the damage rect");

    /* Transparent sixels render the cells underneath instead. */
    memset(pixels, 0, sizeof(pixels));
    s->opaque = false;
    for (int r = 0; r < 2; r++)
        for (int c = 1; c < 3; c++)
            rows[r]->cells[c].attrs.clean = 0;
    struct wl_window win = {0};
    struct config conf = {0};
    term.window = &win;
    term.conf = &conf;
    term.colors.bg = 0;
    term.colors.fg = 0xffffffff;
    term.colors.alpha = 0xffff;
    term.blink.fd = 5;
    term.wl = NULL;
    struct fcft_font *dummy = NULL;
    (void)dummy;

    /* render_row() needs fonts; only check the clean-bit behaviour here. */
    s->opaque = true;
    for (int r = 0; r < 2; r++)
        for (int c = 1; c < 3; c++)
            rows[r]->cells[c].attrs.clean = 0;
    render_sixel_images(&term, pix, NULL, &cursor);
    check(rows[0]->cells[1].attrs.clean && rows[0]->cells[2].attrs.clean,
          "re-rendering an opaque sixel re-cleans its cells");

    /* A sixel outside the viewport is skipped. */
    memset(pixels, 0, sizeof(pixels));
    for (int r = 0; r < 2; r++)
        for (int c = 1; c < 3; c++)
            rows[r]->cells[c].attrs.clean = 0;
    s->pos.row = 6; /* viewport is rows 0..3 */
    s->rows = 1;
    render_sixel_images(&term, pix, NULL, &cursor);
    check(!rows[0]->cells[1].attrs.clean,
          "a sixel outside the viewport is not rendered");
    s->pos.row = 0;
    s->rows = 2;

    tll_free(grid.sixel_images);
    for (int r = 0; r < SROWS; r++)
        grid_row_free(rows[r]);
    pixman_image_unref(img);
    pixman_image_unref(pix);
}

/* D3h: CSD button painters */
static void
test_csd_buttons(void)
{
    enum { BW = 36, BH = 36 };
    uint32_t pixels[BW * BH];
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, BW, BH, pixels, BW * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    pixman_image_t *pix_arr[1] = {pix};
    struct buffer buf = {0};
    buf.width = BW;
    buf.height = BH;
    buf.pix = pix_arr;
    buf.pix_instances = 1;

    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};
    struct wayland wl = {0};
    term.conf = &conf;
    term.window = &win;
    term.wl = &wl;
    term.scale = 1.0f;
    conf.colors_dark.bg = 0x00ffffff;
    conf.csd.color.buttons_set = 0;

    const uint32_t fg =
        pixman_color_to_argb(color_hex_to_pixman(conf.colors_dark.bg, false));

    /* minimize: a single horizontal bar in the lower half */
    memset(pixels, 0, sizeof(pixels));
    render_csd_button_minimize(&term, &buf);
    check(count_argb(pix, BW, BH, fg) > 0,
          "the minimize button paints a bar");

    int bar_rows = 0, bar_top = -1;
    for (int y = 0; y < BH; y++) {
        bool row_has_ink = false;
        for (int x = 0; x < BW; x++)
            row_has_ink |= pix_pixel(pix, x, y) == fg;
        if (row_has_ink) {
            if (bar_top < 0)
                bar_top = y;
            bar_rows++;
        }
    }
    check(bar_rows == 1 && bar_top > BH / 2,
          "the minimize glyph is a single row below the center");

    /* maximize window: a hollow square */
    memset(pixels, 0, sizeof(pixels));
    win.is_maximized = false;
    render_csd_button_maximize(&term, &buf);
    size_t window_px = count_argb(pix, BW, BH, fg);
    check(pix_pixel(pix, BW / 2, BH / 3) == fg,
          "the maximize button draws the top edge of the square");
    check(pix_pixel(pix, BW / 2, BH / 2) != fg,
          "the maximize square is hollow");

    /* maximize maximized: two nested squares, so more ink */
    memset(pixels, 0, sizeof(pixels));
    win.is_maximized = true;
    render_csd_button_maximize(&term, &buf);
    size_t maximized_px = count_argb(pix, BW, BH, fg);
    check(maximized_px != window_px &&
          pix_pixel(pix, BW / 3, BH / 3) != fg,
          "the maximized variant insets the square by one pixel");
    win.is_maximized = false;

    /* close: an X, i.e. ink in both diagonals' corners but not the centre */
    memset(pixels, 0, sizeof(pixels));
    render_csd_button_close(&term, &buf);
    size_t close_px = count_argb(pix, BW, BH, fg);
    check(close_px > 0, "the close button paints something");
    check(close_px < window_px,
          "the close X is thinner than the maximise square outline");
    check(pix_pixel(pix, 1, 1) == 0,
          "the close button stays inside its square");

    /* configured button color wins over the background */
    conf.csd.color.buttons_set = 1;
    conf.csd.color.buttons = 0xff00ff00; /* green, alpha in the top byte */
    memset(pixels, 0, sizeof(pixels));
    render_csd_button_minimize(&term, &buf);
    check(count_argb(pix, BW, BH, 0xff00ff00) > 0,
          "a configured button color is used");
    conf.csd.color.buttons_set = 0;

    /* any_pointer_is_on_button() */
    term.cols = 4;
    term.rows = 2;
    term.cell_width = 10;
    term.cell_height = 10;
    term.width = 100;
    term.height = 50;
    win.csd_mode = CSD_YES;
    win.term = &term;
    conf.csd.border_width = 0;
    conf.csd.title_height = 20;
    conf.csd.button_width = 10;

    struct seat seat = {0};
    seat.wayl = &wl;
    seat.mouse.x = 5;
    seat.mouse.y = 5;
    tll_push_back(wl.seats, seat);

    check(any_pointer_is_on_button(&term, CSD_SURF_CLOSE),
          "the pointer is on the close button");
    wl.seats.head->item.mouse.x = -1;
    check(!any_pointer_is_on_button(&term, CSD_SURF_CLOSE),
          "a pointer outside the window is not on any button");
    tll_free(wl.seats);

    pixman_image_unref(pix);
}

/* D3i: CSD border, button background and title */
static void
test_csd_paint(void)
{
    enum { BW = 40, BH = 40 };
    uint32_t pixels[BW * BH];
    pixman_image_t *pix = pixman_image_create_bits(PIXMAN_a8r8g8b8, BW, BH, pixels, BW * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        return;
    }

    pixman_region32_t dirty;
    pixman_region32_init(&dirty);
    pixman_image_t *pix_arr[1] = {pix};
    struct buffer buf = {0};
    buf.width = BW;
    buf.height = BH;
    buf.pix = pix_arr;
    buf.pix_instances = 1;
    buf.dirty = &dirty;

    struct terminal term = {0};
    struct config conf = {0};
    struct wl_window win = {0};
    struct wayland wl = {0};
    term.conf = &conf;
    term.window = &win;
    term.wl = &wl;
    win.term = &term;
    win.csd_mode = CSD_YES;
    term.scale = 1.0f;
    term.visual_focus = true;
    term.cols = 4;
    term.rows = 2;
    term.cell_width = 10;
    term.cell_height = 10;
    term.width = 100;
    term.height = 50;
    term.font_subpixel = FCFT_SUBPIXEL_NONE;
    conf.colors_dark.fg = 0x00ffffff;
    conf.colors_dark.bg = 0x00000000;
    conf.colors_dark.table[1] = 0x00ff0000; /* red, for close */
    conf.colors_dark.table[2] = 0x0000ff00; /* green */
    conf.colors_dark.table[4] = 0x000000ff; /* blue */
    conf.csd.border_width = 4;
    conf.csd.border_width_visible = 2;
    conf.csd.title_height = 20;

    struct csd_data info = {.x = 0, .y = 0, .width = BW, .height = BH};

    /* ── border: transparent fill + visible strip ────────────────── */
    memset(pixels, 0, sizeof(pixels));
    conf.csd.color.border_set = 1;
    conf.csd.color.border = 0xff0000ff;
    render_csd_border(&term, CSD_SURF_TOP, &info, &buf);
    /* bwidth=4, vwidth=2 -> x=2, y=height-2, w=36, h=2 */
    check(pix_pixel(pix, 2, BH - 2) == 0xff0000ff,
          "the top border's visible strip is painted");
    check(pix_pixel(pix, 2, 0) == 0,
          "the invisible part of the top border stays transparent");
    check(pix_pixel(pix, 0, BH - 2) == 0 && pix_pixel(pix, 39, BH - 2) == 0,
          "the border strip is inset by the invisible part");

    memset(pixels, 0, sizeof(pixels));
    render_csd_border(&term, CSD_SURF_LEFT, &info, &buf);
    check(pix_pixel(pix, 2, 5) == 0xff0000ff,
          "the left border's visible strip is painted");
    check(pix_pixel(pix, 0, 5) == 0,
          "the left border strip is inset as well");
    conf.csd.color.border_set = 0;

    /* ── button: transparent until the pointer hovers it ─────────── */
    memset(pixels, 0, sizeof(pixels));
    term.active_surface = TERM_SURF_NONE;
    render_csd_button(&term, CSD_SURF_MINIMIZE, &info, &buf);
    check(pix_pixel(pix, BW / 2, BH / 2) == 0,
          "an inactive CSD button is fully transparent");

    struct seat seat = {0};
    seat.wayl = &wl;
    seat.mouse.x = 1;
    seat.mouse.y = 1;
    tll_push_back(wl.seats, seat);
    term.active_surface = TERM_SURF_BUTTON_MINIMIZE;
    win.wm_capabilities.minimize = true;
    conf.csd.button_width = 10;

    struct csd_data btn = {.x = 90, .y = 0, .width = 10, .height = 20};
    memset(pixels, 0, sizeof(pixels));
    render_csd_button(&term, CSD_SURF_MINIMIZE, &btn, &buf);
    check(pix_pixel(pix, 5, 5) != 0,
          "an active CSD button gets a background and a glyph");
    tll_free(wl.seats);
    term.active_surface = TERM_SURF_NONE;
    conf.csd.button_width = 0;

    /* ── title: background + text ────────────────────────────────── */
    const char *fontname = "monospace";
    struct fcft_font *font = fcft_from_name(1, &fontname, ":size=8");
    if (font != NULL) {
        win.csd.surface[CSD_SURF_TITLE].surface.surf = NULL;
        win.csd.font = font;
        term.window_title = xstrdup("Hi");
        conf.csd.color.title_set = 1;
        conf.csd.color.title = 0xff112233;

        memset(pixels, 0, sizeof(pixels));
        struct csd_data title = {.x = 0, .y = -20, .width = BW, .height = BH};
        render_csd_title(&term, &title, &buf);
        check(count_argb(pix, BW, BH, 0xff112233) > 0,
              "the CSD title is painted with the configured background");
        check(count_not_argb(pix, BW, BH, 0xff112233) > 0,
              "the CSD title text is drawn on top");

        free(term.window_title);
        term.window_title = NULL;

        /* A zero-sized surface is a no-op. */
        memset(pixels, 0, sizeof(pixels));
        struct csd_data empty = {0};
        render_csd_title(&term, &empty, &buf);
        check(count_not_argb(pix, BW, BH, 0) == 0,
              "a zero-sized title surface is not painted");
        fcft_destroy(font);
        win.csd.font = NULL;
    }

    /* ── render_csd() bails out when fullscreen ──────────────────── */
    win.is_fullscreen = true;
    render_csd(&term);
    check(1, "render_csd() is a no-op when fullscreen");
    win.is_fullscreen = false;

    pixman_region32_fini(&dirty);
    pixman_image_unref(pix);
}

/* D3j: render_ime_preedit() - the pre-edit window, its clipping and the
 * restoration of the cells underneath it. No wayland surface is needed: the
 * damage shim ignores a NULL wl_surface. */
static void
test_render_ime_preedit(void)
{
    struct config testconf = {0};
    struct terminal *term = term_with_fonts(&testconf);
    if (term == NULL) {
        printf("skip: no monospace font available\n");
        return;
    }

    enum { W = 80, H = 40 };
    uint32_t pixels[W * H] = {0};
    pixman_image_t *pix = pixman_image_create_bits(
        PIXMAN_a8r8g8b8, W, H, pixels, W * 4);
    if (pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        term_with_fonts_free(term);
        return;
    }

    term->cols = COLS;
    term->cell_width = 10;
    term->cell_height = 20;
    term->margins.top = term->margins.bottom = 0;
    term->margins.left = term->margins.right = 0;
    term->width = COLS * term->cell_width;
    term->height = H;
    term->colors.bg = 0x000000ff;
    term->colors.fg = 0x00ffffff;
    term->colors.alpha = 0xffff;
    term->blink.fd = 5;
    term->normal.cursor.point = (struct coord){.col = 1, .row = 0};

    pixman_image_t *pixarr[1] = {pix};
    struct buffer buf = {
        .width = W,
        .height = H,
        .pix = pixarr,
        .pix_instances = 1,
    };

    struct seat seat = {0};
    seat.wayl = term->wl;
    seat.kbd_focus = term;
    tll_push_back(term->wl->seats, seat);
    struct seat *s = &tll_front(term->wl->seats);

    struct row *row = grid_row_in_view(term->grid, 0);
    struct cell before[COLS];
    memcpy(before, row->cells, sizeof(before));

    /* ── no pre-edit: a no-op ──────────────────────────────────────── */
    render_ime_preedit(term, &buf);
    check(memcmp(before, row->cells, sizeof(before)) == 0,
          "no pre-edit leaves the row untouched");
    check(s->ime.cursor_rect.pending.width == 0,
          "no pre-edit leaves the IME cursor rect alone");

    /* ── the seat doesn't have keyboard focus: still a no-op ──────── */
    struct cell two[2] = {{0}};
    two[0].wc = 'X';
    two[1].wc = 'Y';
    s->ime.preedit.cells = two;
    s->ime.preedit.count = 2;
    s->ime.preedit.cursor.start = 2;
    s->ime.preedit.cursor.end = 2;
    s->ime.preedit.cursor.hidden = false;

    s->kbd_focus = NULL;
    render_ime_preedit(term, &buf);
    check(memcmp(before, row->cells, sizeof(before)) == 0,
          "an unfocused seat draws nothing");
    s->kbd_focus = term;

    /* ── a two-cell pre-edit, cursor at the end ───────────────────── */
    render_ime_preedit(term, &buf);

    bool same = true;
    for (int i = 0; i < COLS; i++)
        same = same && before[i].wc == row->cells[i].wc;
    check(same, "the grid row is restored after the pre-edit is drawn");
    check(row->cells[1].attrs.clean == 0 &&
          row->cells[2].attrs.clean == 0 &&
          row->cells[3].attrs.clean == 0,
          "the pre-edit span (plus the extra cell) is left dirty");
    check(row->dirty, "drawing a pre-edit dirties the row");

    check(s->ime.cursor_rect.pending.width == 1,
          "a collapsed pre-edit cursor is one column wide");
    check(s->ime.cursor_rect.pending.height == term->cell_height,
          "the IME cursor rect is one cell tall");
    check(s->ime.cursor_rect.pending.x ==
              term->margins.left + (1 + 2) * term->cell_width,
          "the IME cursor rect follows the end of the pre-edit string");

    /* ── a pre-edit longer than the row: window it, don't overflow ── */
    struct cell ten[10] = {{0}};
    for (int i = 0; i < 10; i++)
        ten[i].wc = 'Z';
    s->ime.preedit.cells = ten;
    s->ime.preedit.count = 10;
    s->ime.preedit.cursor.start = 10;
    s->ime.preedit.cursor.end = 10;

    render_ime_preedit(term, &buf);
    check(s->ime.cursor_rect.pending.x + s->ime.cursor_rect.pending.width <=
              term->width,
          "an overlong pre-edit keeps the IME cursor inside the window");
    check(s->ime.cursor_rect.pending.x ==
              term->margins.left + 4 * term->cell_width,
          "the overlong pre-edit window ends at the last column");

    /* The window must not start in the middle of a spacer. */
    ten[6].wc = CELL_SPACER;
    render_ime_preedit(term, &buf);
    check(s->ime.cursor_rect.pending.x ==
              term->margins.left + 3 * term->cell_width,
          "the pre-edit window skips a leading spacer");

    /* ── cursor hidden: the rect is left alone ────────────────────── */
    s->ime.preedit.cursor.hidden = true;
    s->ime.cursor_rect.pending.width = 1234;
    render_ime_preedit(term, &buf);
    check(s->ime.cursor_rect.pending.width == 1234,
          "a hidden pre-edit cursor does not move the IME rect");

    /* ── the cell under the cursor is a spacer: start one cell left ─ */
    s->ime.preedit.cursor.hidden = false;
    s->ime.preedit.cells = two;
    s->ime.preedit.count = 2;
    s->ime.preedit.cursor.start = 2;
    s->ime.preedit.cursor.end = 2;

    row->cells[1].wc = CELL_SPACER;
    render_ime_preedit(term, &buf);
    check(s->ime.cursor_rect.pending.x ==
              term->margins.left + 2 * term->cell_width,
          "a double-width character at the cursor shifts the pre-edit left");
    check(row->cells[1].wc == CELL_SPACER,
          "the spacer cell is restored, not overwritten");
    row->cells[1].wc = before[1].wc;

    tll_free(term->wl->seats);
    pixman_image_unref(pix);
    term_with_fonts_free(term);
}

/* D3j: render_overlay()'s style selection and the unmap path. The overlay
 * sub-surface has no wl_surface here, which the shims tolerate. */
static void
test_render_overlay(void)
{
    struct terminal *term = term_new();
    struct wl_window win = {0};
    term->window = &win;

    term->render.last_overlay_style = OVERLAY_NONE;
    term->render.last_overlay_buf = NULL;
    render_overlay(term);
    check(term->render.last_overlay_style == OVERLAY_NONE,
          "no overlay style is a no-op");

    term->render.last_overlay_style = OVERLAY_FLASH;
    term->render.last_overlay_buf = (void *)0x1;
    render_overlay(term);
    check(term->render.last_overlay_style == OVERLAY_NONE,
          "the overlay style is reset when the overlay goes away");
    check(term->render.last_overlay_buf == NULL,
          "the stale overlay buffer is dropped when the overlay goes away");

    term->window = NULL;
    term_free(term);
}



/* D3k1: the renderer object and the presentation frame bucket */
static void
test_render_init(void)
{
    struct fdm *fdm = fdm_init();
    if (fdm == NULL) {
        printf("skip: fdm_init() failed\n");
        return;
    }

    struct wayland wl = {0};
    struct renderer *renderer = render_init(fdm, &wl);
    check(renderer != NULL, "render_init() registers the refresh hook");

    render_destroy(renderer);
    check(1, "render_destroy() removes the hook");

    render_destroy(NULL); /* must be a no-op */
    fdm_destroy(fdm);

    /* One 60 Hz frame is 16666.7 µs. */
    check(render_presentation_frame_count(0, 60.0f) == 0,
          "no elapsed time is zero frames");
    check(render_presentation_frame_count(20000, 60.0f) == 1,
          "20 ms at 60 Hz is one frame");
    check(render_presentation_frame_count(40000, 60.0f) == 2,
          "40 ms at 60 Hz is two frames");
    check(render_presentation_frame_count(8000, 120.0f) == 0,
          "8 ms at 120 Hz is less than one frame");
    check(render_presentation_frame_count(9000, 120.0f) == 1,
          "9 ms at 120 Hz is one frame");
    check(render_presentation_frame_count(40000, 0.0f) == 0,
          "an unknown refresh rate cannot produce frames");
}


/* D3k1: presented() end-to-end. grid_render() allocates the context, so the
 * harness rebuilds the same three-member layout (term + two timevals) and
 * hands it over; the function frees it (except on the early-return paths). */
struct presentation_ctx_test {
    struct terminal *term;
    struct timeval input;
    struct timeval commit;
};

static struct presentation_ctx_test *
presentation_ctx_new(struct terminal *term, time_t input_sec, time_t commit_sec)
{
    struct presentation_ctx_test *ctx = xmalloc(sizeof(*ctx));
    ctx->term = term;
    ctx->input = (struct timeval){.tv_sec = input_sec, .tv_usec = 0};
    ctx->commit = (struct timeval){.tv_sec = commit_sec, .tv_usec = 0};
    return ctx;
}

static void
test_presentation_feedback(void)
{
    struct terminal *term = term_new();
    struct wl_window win = {0};
    struct monitor mon = {0};

    mon.refresh = 60.0f;
    term->window = &win;
    tll_push_back(win.on_outputs, &mon);

    /* 20 ms after the commit: one 60 Hz frame (the warning bucket). */
    presented(presentation_ctx_new(term, 0, 10), NULL,
              0, 10, 20 * 1000 * 1000, 0, 0, 0, 0);
    check(1, "presented() measures a commit-to-presented delay");

    /* 1 ms after the commit: less than a frame (the info bucket). */
    presented(presentation_ctx_new(term, 0, 10), NULL,
              0, 10, 1000 * 1000, 0, 0, 0, 0);
    check(1, "presented() handles a sub-frame delay");

    /* An input timestamp makes the message include the input-to-presented
     * leg, and skips the commit comparison. */
    presented(presentation_ctx_new(term, 5, 6), NULL,
              0, 7, 500 * 1000, 0, 0, 0, 0);
    check(1, "presented() includes the input leg when there is one");

    /* Older than the commit: dropped before the free. Keep the context on
     * the stack - it is deliberately not freed on this path. */
    struct presentation_ctx_test early =
        {.term = term, .input = {0}, .commit = {.tv_sec = 10, .tv_usec = 0}};
    presented(&early, NULL, 0, 5, 0, 0, 0, 0, 0);
    check(1, "presented() drops a timestamp older than the commit");

    tll_free(win.on_outputs);
    term->window = NULL;
    term_free(term);
}


/* D3k2a: reapply_old_damage() and force_full_repaint() */
static void
test_reapply_old_damage(void)
{
    struct terminal *term = term_new();
    struct wl_window win = {0};
    struct wayland wl = {0};
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    enum { W = 8, H = 16 };
    uint32_t old_pixels[W * H];
    uint32_t new_pixels[W * H];
    for (int i = 0; i < W * H; i++)
        old_pixels[i] = 0xff000000u | (uint32_t)i;

    pixman_image_t *old_pix =
        pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, old_pixels, W * 4);
    pixman_image_t *new_pix =
        pixman_image_create_bits(PIXMAN_a8r8g8b8, W, H, new_pixels, W * 4);
    if (old_pix == NULL || new_pix == NULL) {
        printf("skip: pixman_image_create_bits() failed\n");
        term_free(term);
        return;
    }

    term->window = &win;
    term->wl = &wl;
    term->conf = &conf;
    term->scale = 1.0f;
    term->cols = 2;
    term->rows = 2;
    term->cell_width = W / 2;
    term->cell_height = H / 2;
    term->width = W;
    term->height = H;
    term->margins.top = term->margins.bottom = 0;
    term->margins.left = term->margins.right = 0;
    term->colors.bg = 0x000000ff;
    term->colors.fg = 0x00ffffff;
    term->colors.alpha = 0xffff;

    pixman_region32_t old_dirty;
    pixman_region32_t new_dirty;
    pixman_region32_init_rect(&old_dirty, 0, 0, W, H);
    pixman_region32_init(&new_dirty);

    pixman_image_t *old_pixarr[1] = {old_pix};
    pixman_image_t *new_pixarr[1] = {new_pix};

    struct buffer old_buf = {
        .width = W, .height = H, .stride = W * 4, .data = old_pixels,
        .pix = old_pixarr, .pix_instances = 1, .dirty = &old_dirty,
    };
    struct buffer new_buf = {
        .width = W, .height = H, .stride = W * 4, .data = new_pixels,
        .pix = new_pixarr, .pix_instances = 1, .dirty = &new_dirty,
    };

    /* A buffer older than the previous frame is a straight memcpy. */
    memset(new_pixels, 0, sizeof(new_pixels));
    new_buf.age = 2;
    reapply_old_damage(term, &new_buf, &old_buf);
    check(memcmp(new_pixels, old_pixels, sizeof(new_pixels)) == 0,
          "a two-frames-old buffer is copied wholesale");

    /* With no dirty rows, the old frame's damage is composited. */
    for (int r = 0; r < term->rows; r++)
        grid_row_in_view(term->grid, r)->dirty = false;

    memset(new_pixels, 0, sizeof(new_pixels));
    new_buf.age = 0;
    reapply_old_damage(term, &new_buf, &old_buf);
    check(new_pixels[0] == old_pixels[0] &&
          new_pixels[W * H - 1] == old_pixels[W * H - 1],
          "an undamaged frame is copied from the old buffer");

    /* force_full_repaint(): drops the pending scroll damage and re-dirties */
    tll_push_back(term->grid->scroll_damage, ((struct damage){0}));
    grid_row_in_view(term->grid, 0)->cells[0].attrs.clean = 1;

    force_full_repaint(term, &new_buf);
    check(tll_length(term->grid->scroll_damage) == 0,
          "force_full_repaint() drops the pending scroll damage");
    check(grid_row_in_view(term->grid, 0)->cells[0].attrs.clean == 0,
          "force_full_repaint() re-dirties the view");

    pixman_region32_fini(&old_dirty);
    pixman_region32_fini(&new_dirty);
    pixman_image_unref(old_pix);
    pixman_image_unref(new_pix);
    term->window = NULL;
    term->wl = NULL;
    term_free(term);
}


/* D3k2b: the scrollback indicator's early-outs (the painting paths need a
 * compositor; smoke.sh runs them with render-timer=osd). */
static void
test_scrollback_indicator(void)
{
    struct terminal *term = term_new();
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    term->conf = &conf;
    term->window = NULL; /* must not be touched while the indicator is off */

    render_scrollback_position(term);
    check(1, "the scrollback indicator is a no-op when disabled");

    struct wl_window win = {0};
    term->window = &win;
    conf.scrollback.indicator.position = SCROLLBACK_INDICATOR_POSITION_FIXED;
    term->grid->view = term->grid->offset;

    render_scrollback_position(term);
    check(win.scrollback_indicator.surface.surf == NULL,
          "no indicator is created while the viewport is at the bottom");

    term->window = NULL;
    term_free(term);
}


/* D3k3: the search box's horizontal windowing (the paint path needs a
 * compositor; this is the arithmetic that decides what is visible). */
static void
test_search_box_offset(void)
{
    check(render_search_box_glyph_offset(10, 20, 100, 15) == 10,
          "a cursor inside the visible window keeps the offset");

    check(render_search_box_glyph_offset(10, 20, 100, 5) == 5,
          "a cursor left of the window pulls the offset back");

    check(render_search_box_glyph_offset(0, 20, 100, 30) == 10,
          "a cursor right of the window pushes the offset forward");

    check(render_search_box_glyph_offset(90, 20, 100, 95) == 80,
          "free space at the end pulls the offset back");

    check(render_search_box_glyph_offset(0, 20, 5, 3) == 0,
          "a string shorter than the window keeps offset 0");
}


/* D3k4: the jump-label text (the label sub-surfaces need a compositor) */
static void
test_url_label(void)
{
    char32_t label[32];
    const char32_t key[] = {'a', 'b', 'c', 0};
    const char32_t url[] = {'h', 't', 't', 'p', 0};

    int cols = render_url_format_label(label, key, url, true, 0, 80);
    check(label[0] == 'A' && label[1] == 'B' && label[2] == 'C' &&
          label[3] == ':' && label[4] == ' ' && label[5] == 'h',
          "the label is the upper-cased key, ': ', then the URL");
    check(cols == 9, "the label's width is the whole string when it fits");

    cols = render_url_format_label(label, key, url, true, 2, 80);
    check(label[0] == ' ' && label[1] == ' ' && label[2] == 'C',
          "already-entered key characters are blanked");
    check(cols == 9, "blanked characters still occupy cells");

    cols = render_url_format_label(label, key, NULL, false, 0, 2);
    check(cols == 2, "a label wider than the window is clamped to max_cols");
    check(label[1] == 0x2026, "the truncated label ends in an ellipsis");
    check(label[2] == 0, "the truncated label is NUL-terminated");

    check(render_url_format_label(label, key, NULL, false, 0, 0) == 0,
          "max_cols 0 renders nothing");
}



/*
 * The render worker thread (render.zig, D3l1).
 *
 * The worker loops on `sem_wait(start)`, pops one queue entry per iteration
 * and dispatches on it: -1 means "frame done", -2 means "quit", -3 is the
 * pre-applied-damage composite and anything else is a row to render. Rows
 * need a real font/pixman buffer, so the harness drives the two control
 * codes: they cover the loop, the queue, the mutex and the done semaphore
 * without needing a compositor.
 */
static void *
worker_thunk(void *arg)
{
    return (void *)(intptr_t)render_worker_thread(arg);
}

static void
test_render_worker_thread(void)
{
    struct terminal *term = term_new();
    struct buffer buf = {0};
    buf.pix_instances = 1;

    term->render.workers.count = 1;
    term->render.workers.buf = &buf;
    /* The queue is already empty: term_new() zeroes the whole struct. */

    xassert(sem_init(&term->render.workers.start, 0, 0) == 0);
    xassert(sem_init(&term->render.workers.done, 0, 0) == 0);
    xassert(mtx_init(&term->render.workers.lock, mtx_plain) == thrd_success);

    struct render_worker_context *ctx = xmalloc(sizeof(*ctx));
    xassert(ctx != NULL);
    ctx->my_id = 0;
    ctx->term = term;

    pthread_t thr;
    xassert(pthread_create(&thr, NULL, &worker_thunk, ctx) == 0);

    /* -1: signal frame-done and keep waiting */
    xassert(tll_length(term->render.workers.queue) == 0);
    tll_push_back(term->render.workers.queue, -1);
    xassert(sem_post(&term->render.workers.start) == 0);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    bool done = sem_timedwait(&term->render.workers.done, &deadline) == 0;
    check(done, "the worker posts 'done' for a frame-done request");
    check(tll_length(term->render.workers.queue) == 0,
          "the worker drains the queue it was signalled for");

    /* -2: quit */
    tll_push_back(term->render.workers.queue, -2);
    xassert(sem_post(&term->render.workers.start) == 0);

    void *ret = (void *)1;
    xassert(pthread_join(thr, &ret) == 0);
    check((intptr_t)ret == 0, "the worker returns 0 when asked to quit");

    tll_free(term->render.workers.queue);
    mtx_destroy(&term->render.workers.lock);
    sem_destroy(&term->render.workers.start);
    sem_destroy(&term->render.workers.done);
    term_free(term);
}

/* render_wait_for_preapply_damage() (render.zig, D3l1). */
static int preapply_waiter_returned;

static void *
preapply_waiter_thunk(void *arg)
{
    render_wait_for_preapply_damage(arg);
    __atomic_store_n(&preapply_waiter_returned, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void
test_render_wait_for_preapply_damage(void)
{
    struct terminal *term = term_new();
    struct buffer buf = {0};

    /* Not configured for pre-applied damage: no-op even with a frame. */
    term->render.preapply_last_frame_damage = false;
    term->render.workers.preapplied_damage.buf = &buf;
    render_wait_for_preapply_damage(term);
    check(term->render.workers.preapplied_damage.buf == &buf,
          "a disabled pre-apply path does not touch the pending frame");

    /* Enabled, but nothing in flight. */
    term->render.preapply_last_frame_damage = true;
    term->render.workers.preapplied_damage.buf = NULL;
    render_wait_for_preapply_damage(term);
    check(term->render.workers.preapplied_damage.buf == NULL,
          "an empty pre-apply slot returns immediately");

    /* Enabled with a frame in flight: blocks until the worker clears it. */
    xassert(mtx_init(&term->render.workers.preapplied_damage.lock,
                     mtx_plain) == thrd_success);
    xassert(cnd_init(&term->render.workers.preapplied_damage.cond) ==
            thrd_success);
    term->render.workers.preapplied_damage.buf = &buf;

    preapply_waiter_returned = 0;
    pthread_t thr;
    xassert(pthread_create(&thr, NULL, &preapply_waiter_thunk, term) == 0);

    struct timespec delay = {.tv_sec = 0, .tv_nsec = 50 * 1000 * 1000};
    nanosleep(&delay, NULL);
    check(!__atomic_load_n(&preapply_waiter_returned, __ATOMIC_SEQ_CST),
          "waits while a frame is being pre-applied");

    mtx_lock(&term->render.workers.preapplied_damage.lock);
    term->render.workers.preapplied_damage.buf = NULL;
    cnd_signal(&term->render.workers.preapplied_damage.cond);
    mtx_unlock(&term->render.workers.preapplied_damage.lock);

    xassert(pthread_join(thr, NULL) == 0);
    check(__atomic_load_n(&preapply_waiter_returned, __ATOMIC_SEQ_CST),
          "wakes up once the worker clears the pre-applied frame");

    cnd_destroy(&term->render.workers.preapplied_damage.cond);
    mtx_destroy(&term->render.workers.preapplied_damage.lock);
    term_free(term);
}


/*
 * The overflowing-glyph pre-pass of grid_render() (render.zig, D3l2).
 *
 * Cells belonging to the same overflowing glyph run must be re-rendered as a
 * unit: one dirty cell in the middle of a run dirties the whole run. The
 * `confined` bit marks the last cell of such a run, which is where the scan
 * stops in both directions.
 */
static void
row_reset_clean(struct row *row, bool clean)
{
    for (int c = 0; c < COLS; c++) {
        row->cells[c].attrs.clean = clean;
        row->cells[c].attrs.confined = false;
    }
}

static bool
row_cells_clean(struct row *row, int from, int to, bool expected)
{
    for (int c = from; c <= to; c++) {
        if (row->cells[c].attrs.clean != expected)
            return false;
    }
    return true;
}

static void
test_overflowing_glyphs(void)
{
    struct terminal *term = term_new();
    struct row *row = grid_row_in_view(term->grid, 0);

    /* With no confined cell anywhere the whole rest of the row is dirtied. */
    row_reset_clean(row, true);
    row->dirty = true;
    row->cells[2].attrs.clean = false;

    render_dirty_overflowing_glyphs(term);
    check(row_cells_clean(row, 0, COLS - 1, false),
          "a run without a confined cell dirties the whole row");

    /* A confined cell stops the back-fill: it is the start of the run. */
    row_reset_clean(row, true);
    row->cells[0].attrs.confined = true;
    row->cells[3].attrs.clean = false;

    render_dirty_overflowing_glyphs(term);
    check(row->cells[0].attrs.clean,
          "the back-fill stops at a confined cell");
    check(row_cells_clean(row, 1, 4, false),
          "everything after the confined cell is re-rendered");

    /* The forward sweep stops after the end of the run. */
    row_reset_clean(row, true);
    row->cells[1].attrs.clean = false;
    row->cells[2].attrs.confined = true;   /* end of the run */

    render_dirty_overflowing_glyphs(term);
    check(row_cells_clean(row, 0, 2, false),
          "the run containing the dirty cell is dirtied end to end");
    check(row_cells_clean(row, 3, 4, true),
          "the forward sweep stops after the confined cell");

    /* ... and the outer loop resumes past it: a second run further right is
     * still found, and its back-fill reaches back over the clean cell. */
    row_reset_clean(row, true);
    row->cells[1].attrs.clean = false;
    row->cells[2].attrs.confined = true;
    row->cells[4].attrs.clean = false;

    render_dirty_overflowing_glyphs(term);
    check(!row->cells[4].attrs.clean,
          "the scan resumes after a run it already handled");
    check(!row->cells[3].attrs.clean,
          "the back-fill of the second run reaches back over clean cells");

    /* Clean rows are left alone entirely. */
    row_reset_clean(row, true);
    row->dirty = false;

    render_dirty_overflowing_glyphs(term);
    check(row_cells_clean(row, 0, COLS - 1, true),
          "a clean row is not touched");

    term_free(term);
}

/*
 * set_size_from_grid() (render.zig, D3l3a): the window size a grid needs.
 */
static void
test_set_size_from_grid(void)
{
    struct terminal *term = term_new();
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    term->conf = &conf;
    term->cell_width = 10;
    term->cell_height = 20;
    term->scale = 1.0f;

    int w = -1, h = -1;
    set_size_from_grid(term, &w, &h, 80, 24);
    check(w == 800 && h == 480,
          "a 80x24 grid is 800x480 at scale 1 without padding");

    conf.pad_left = 3;
    conf.pad_right = 5;
    conf.pad_top = 2;
    conf.pad_bottom = 4;
    set_size_from_grid(term, &w, &h, 80, 24);
    check(w == 808 && h == 486,
          "padding is added on all four sides");
    conf.pad_left = conf.pad_right = conf.pad_top = conf.pad_bottom = 0;

    term->scale = 1.5f;
    set_size_from_grid(term, &w, &h, 80, 24);
    check(w == 800 && h == 480,
          "a size that is already a multiple of the scale is unchanged");

    /* One of the out-params may be NULL, and 0x0 is legal. */
    h = -1;
    set_size_from_grid(term, NULL, &h, 0, 0);
    check(h == 0, "a zero-sized grid needs no pixels");

    term->conf = NULL;
    term_free(term);
}

/*
 * render_resize()'s decision points (render.zig, D3l3b). The resize itself
 * needs a configured window and real grids, so the harness covers the
 * early-outs and the "nothing changed" path.
 */
static void
test_render_resize_early_outs(void)
{
    struct terminal *term = term_new();
    struct wl_window win = {0};
    struct wayland wl = {0};
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    term->window = &win;
    term->wl = &wl;
    term->conf = &conf;
    term->scale = 1.0f;
    term->width = 800;
    term->height = 480;
    term->cols = 80;
    term->rows = 24;
    term->cell_width = 10;
    term->cell_height = 20;

    check(!render_resize(term, 800, 480, 0),
          "an unconfigured window is not resized");

    win.is_configured = true;
    term->cell_width = 0;
    term->cell_height = 0;
    check(!render_resize(term, 800, 480, 0),
          "a terminal without a font size is not resized");

    term->cell_width = 10;
    term->cell_height = 20;
    term->shutdown.in_progress = true;
    check(!render_resize(term, 800, 480, 0),
          "a shutting-down terminal is not resized");

    term->shutdown.in_progress = false;
    check(!render_resize(term, 800, 480, 0),
          "the same size and scale is not a resize");

    term->window = NULL;
    term->wl = NULL;
    term->conf = NULL;
    term_free(term);
}

/*
 * Cursor requests and the buffer-release pre-apply hook (render.zig, D3l4).
 * Both have early-outs that need no compositor.
 */
static void
test_xcursor_set_early_outs(void)
{
    struct terminal *term = term_new();
    struct terminal *other = term_new();
    struct wayland wl = {0};
    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    seat.wayl = &wl;

    check(!render_xcursor_set(&seat, term, CURSOR_SHAPE_LEFT_PTR),
          "no cursor theme and no cursor-shape-v1 means no cursor");

    seat.pointer.theme = (void *)0x1;
    seat.mouse_focus = NULL;
    check(render_xcursor_set(&seat, term, CURSOR_SHAPE_LEFT_PTR),
          "a seat without mouse focus accepts the request");
    check(seat.pointer.shape == CURSOR_SHAPE_NONE,
          "the shape is reset when there is no mouse focus");

    seat.mouse_focus = term;
    seat.pointer.shape = CURSOR_SHAPE_LEFT_PTR;
    check(render_xcursor_set(&seat, term, CURSOR_SHAPE_LEFT_PTR),
          "requesting the current shape is a no-op");
    check(!seat.pointer.xcursor_pending,
          "and does not schedule a cursor update");

    seat.mouse_focus = other;
    check(render_xcursor_set(&seat, term, CURSOR_SHAPE_TEXT),
          "a terminal without mouse focus accepts the request");
    check(seat.pointer.shape == CURSOR_SHAPE_LEFT_PTR,
          "and leaves the seat's shape alone");

    term_free(term);
    term_free(other);
}

static void
test_buffer_release_early_outs(void)
{
    struct terminal *term = term_new();
    struct buffer buf = {0};

    /* Pre-applied damage disabled: nothing happens. */
    term->render.preapply_last_frame_damage = false;
    buf.age = 1;
    render_buffer_release_callback(&buf, term);
    check(term->render.workers.preapplied_damage.buf == NULL,
          "released buffers are ignored while pre-applied damage is off");

    /* Only a buffer that is exactly one frame old is a candidate. */
    term->render.preapply_last_frame_damage = true;
    buf.age = 0;
    render_buffer_release_callback(&buf, term);
    check(term->render.workers.preapplied_damage.buf == NULL,
          "a fresh buffer is not pre-applied");

    term->render.preapply_last_frame_damage = false;
    term_free(term);
}

/*
 * Keyboard setup (input.zig, D4a): the key-repeat timer and the enter/leave
 * bookkeeping. Installing a real keymap needs a compositor, so that part is
 * covered by the smoke launches instead.
 */
static void
test_keyboard_setup(void)
{
    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    struct wayland wl = {0};
    seat.wayl = &wl;
    seat.name = "test-seat";

    seat.kbd.repeat.fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    xassert(seat.kbd.repeat.fd >= 0);
    seat.kbd.repeat.rate = 25;
    seat.kbd.repeat.delay = 500;

    seat.kbd.repeat.dont_re_repeat = true;
    check(start_repeater(&seat, 0x20),
          "dont-re-repeat short-circuits the repeat timer");
    check(seat.kbd.repeat.key != 0x20,
          "a short-circuited start does not claim the key");

    seat.kbd.repeat.dont_re_repeat = false;
    seat.kbd.repeat.rate = 0;
    check(start_repeater(&seat, 0x20),
          "a zero repeat rate short-circuits the repeat timer");

    seat.kbd.repeat.rate = 25;
    check(start_repeater(&seat, 0x41) && seat.kbd.repeat.key == 0x41,
          "a valid repeat request arms the timer and claims the key");

    check(stop_repeater(&seat, 0x42),
          "stopping a key that is not repeating is a no-op");

    /* Enter with a NULL surface is a no-op (seen on Hyprland). */
    seat.kbd_focus = NULL;
    keyboard_enter(&seat, NULL, 1, NULL, NULL);
    check(seat.kbd_focus == NULL,
          "keyboard_enter() ignores a NULL surface");

    /* Leave without a focus still clears the modifier state (Sway bug). */
    seat.kbd.shift = true;
    seat.kbd.alt = true;
    seat.kbd.ctrl = true;
    seat.kbd.super = true;
    keyboard_leave(&seat, NULL, 1, NULL);
    check(!seat.kbd.shift && !seat.kbd.alt && !seat.kbd.ctrl && !seat.kbd.super,
          "keyboard_leave() clears the modifier state");
    check(seat.kbd_focus == NULL,
          "keyboard_leave() leaves no focus behind");

    close(seat.kbd.repeat.fd);
}

/*
 * Modifier helpers (input.zig, D4b1).
 */
static void
test_modifier_helpers(void)
{
    /* Modifier keysyms: Shift_L..Hyper_R, the ISO_* locks, Mode_switch and
     * Num_Lock - and nothing else. */
    check(keysym_is_modifier(XKB_KEY_Shift_L), "Shift_L is a modifier");
    check(keysym_is_modifier(XKB_KEY_Hyper_R), "Hyper_R is a modifier");
    check(keysym_is_modifier(XKB_KEY_ISO_Level3_Shift),
          "the ISO_Level* keys are modifiers");
    check(!keysym_is_modifier(XKB_KEY_Return), "Return is not a modifier");
    check(!keysym_is_modifier(XKB_KEY_a), "a letter is not a modifier");

    /* modifier_string() needs an xkb keymap to name the modifiers. */
    struct xkb_context *xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *km = xkb_ctx != NULL
        ? xkb_keymap_new_from_names(xkb_ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS)
        : NULL;

    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    char buf[64];

    if (km != NULL) {
        seat.kbd.xkb_keymap = km;
        const xkb_mod_index_t shift =
            xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);

        memset(buf, 'x', sizeof(buf));
        modifier_string(1u << shift, sizeof(buf), buf, &seat);
        check_text(buf, "Shift", "a single modifier is rendered by name");

        modifier_string(0, sizeof(buf), buf, &seat);
        check_text(buf, "<none>", "an empty mask renders as <none>");

        xkb_keymap_unref(km);
    } else {
        printf("skip: no xkb keymap available\n");
    }

    seat.kbd.xkb_keymap = NULL;
    modifier_string(0, sizeof(buf), buf, &seat);
    check_text(buf, "<none>",
               "no keymap still renders <none> instead of crashing");

    buf[0] = 'x';
    modifier_string(1, 0, buf, &seat);
    check(buf[0] == 'x', "a zero-sized buffer is not written to");

    if (xkb_ctx != NULL)
        xkb_context_unref(xkb_ctx);
}

/*
 * The VT key tables and keymap_lookup() (input.zig, D4b2).
 *
 * The expected sequences are the ones keymap.h documented in its own
 * UNITTEST blocks, so these double as a parity check for the translation.
 */
static void
test_keymap_lookup(void)
{
    struct terminal term;
    memset(&term, 0, sizeof(term));
    term.cursor_keys_mode = CURSOR_KEYS_NORMAL;
    term.keypad_keys_mode = KEYPAD_DONTCARE;

    const struct key_data *info =
        keymap_lookup(&term, XKB_KEY_Escape, MOD_SHIFT);
    check(info != NULL && strcmp(info->seq, "\033[27;2;27~") == 0,
          "Shift+Escape is CSI 27;2;27~");

    info = keymap_lookup(&term, XKB_KEY_Return, MOD_ALT);
    check(info != NULL && strcmp(info->seq, "\033\r") == 0,
          "Alt+Return is ESC CR");

    term.modify_other_keys_2 = true;
    info = keymap_lookup(&term, XKB_KEY_Return, MOD_ALT);
    check(info != NULL && strcmp(info->seq, "\033[27;3;13~") == 0,
          "modifyOtherKeys=2 turns Alt+Return into CSI 27;3;13~");
    term.modify_other_keys_2 = false;

    info = keymap_lookup(&term, XKB_KEY_ISO_Left_Tab, MOD_SHIFT | MOD_CTRL);
    check(info != NULL && strcmp(info->seq, "\033[27;6;9~") == 0,
          "Shift+Ctrl+ISO_Left_Tab is CSI 27;6;9~");

    /* Cursor-key mode selects a different entry for the same keysym. */
    info = keymap_lookup(&term, XKB_KEY_Up, MOD_ANY);
    check(info != NULL && strcmp(info->seq, "\033[A") == 0,
          "Up in normal cursor-key mode is CSI A");

    term.cursor_keys_mode = CURSOR_KEYS_APPLICATION;
    info = keymap_lookup(&term, XKB_KEY_Up, MOD_ANY);
    check(info != NULL && strcmp(info->seq, "\033OA") == 0,
          "Up in application cursor-key mode is SS3 A");

    size_t count = 0;
    check(keymap_data_for_sym(XKB_KEY_Escape, &count) != NULL && count > 0,
          "Escape has a key table");
    check(keymap_data_for_sym(0, &count) == NULL,
          "an unknown keysym has no key table");
}

/*
 * The two keyboard-protocol encoders (input.zig, D4b2b).
 *
 * Both are pure functions of a struct kbd_ctx, so they can be driven directly
 * and their output read back from a real pty.
 */
static void
kbd_ctx_init(struct kbd_ctx *ctx, xkb_keysym_t sym, const char *utf8,
             uint32_t *utf32, bool pressed)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->sym = sym;
    ctx->key = 38;  /* 'a' on evdev */
    ctx->utf8.buf = (const uint8_t *)utf8;
    ctx->utf8.count = strlen(utf8);
    ctx->utf32 = utf32;
    ctx->compose_status = XKB_COMPOSE_NOTHING;
    ctx->key_state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED
                             : WL_KEYBOARD_KEY_STATE_RELEASED;
}

static void
test_kbd_protocols(void)
{
    struct terminal *term = term_new();
    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    seat.kbd_focus = term;

    /* kitty_kbd_protocol() consults the xkb keymap for the base layout
     * symbol, so give the seat a real one. */
    struct xkb_context *xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *km = xkb_ctx != NULL
        ? xkb_keymap_new_from_names(xkb_ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS)
        : NULL;
    if (km != NULL) {
        seat.kbd.xkb = xkb_ctx;
        seat.kbd.xkb_keymap = km;
        seat.kbd.xkb_state = xkb_state_new(km);
        seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CTRL);
        seat.kbd.mod_shift = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);
        seat.kbd.kitty_significant = (1u << seat.kbd.mod_ctrl) |
                                     (1u << seat.kbd.mod_shift);
    }

    int slave = term_capture_begin(term);
    char buf[256];

    struct kbd_ctx ctx;
    uint32_t a_utf32[] = {'a', 0};

    /* ── legacy ─────────────────────────────────────────────────────── */
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, true);
    check(legacy_kbd_protocol(&seat, term, &ctx),
          "legacy: a plain 'a' is handled");
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "a", "legacy: a plain 'a' is sent as-is");

    /* Ctrl+a: xkb hands us the control character, and keysym 0x61 counts as
     * a control key (is_control_key() covers 0x40..0x7f), so the raw byte is
     * what gets sent. */
    seat.kbd.ctrl = true;
    uint32_t ctrl_a_utf32[] = {1, 0};
    kbd_ctx_init(&ctx, XKB_KEY_a, "\001", ctrl_a_utf32, true);
    legacy_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\001", "legacy: Ctrl+a sends the control character");

    /* A non-ASCII keysym with ctrl does go through the modifyOtherKeys CSI. */
    uint32_t eacute_utf32[] = {0xe9, 0};
    kbd_ctx_init(&ctx, 0xe9, "\303\251", eacute_utf32, true);
    legacy_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[27;5;233~",
               "legacy: Ctrl+eacute is CSI 27;5;233~");
    seat.kbd.ctrl = false;

    /* Alt+Return comes from the key table, not the CSI path. */
    uint32_t ret_utf32[] = {'\r', 0};
    seat.kbd.alt = true;
    kbd_ctx_init(&ctx, XKB_KEY_Return, "\r", ret_utf32, true);
    legacy_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033\r", "legacy: Alt+Return is ESC CR");
    seat.kbd.alt = false;

    /* Release events are not the legacy protocol's business. */
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, false);
    check(!legacy_kbd_protocol(&seat, term, &ctx),
          "legacy: a release event is not encoded");

    /* ── kitty ──────────────────────────────────────────────────────── */
    term->grid->kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE;
    term->grid->kitty_kbd.idx = 0;

    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, true);
    check(kitty_kbd_protocol(&seat, term, &ctx), "kitty: 'a' is handled");
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "a", "kitty: plain text stays plain text");

    /* report-all-keys-as-escapes turns it into a CSI u. */
    term->grid->kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE | KITTY_KBD_REPORT_ALL;
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, true);
    kitty_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[97u", "kitty: report-all encodes 'a' as CSI 97u");

    /* ... and adds the modifier parameter with ctrl held. */
    seat.kbd.ctrl = true;
    xkb_state_update_mask(seat.kbd.xkb_state,
                          1u << seat.kbd.mod_ctrl, 0, 0, 0, 0, 0);
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, true);
    kitty_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[97;5u", "kitty: Ctrl+a is CSI 97;5u");
    xkb_state_update_mask(seat.kbd.xkb_state, 0, 0, 0, 0, 0, 0);
    seat.kbd.ctrl = false;

    /* Release events are only reported with the report-events flag. */
    term->grid->kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE | KITTY_KBD_REPORT_ALL;
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, false);
    check(!kitty_kbd_protocol(&seat, term, &ctx),
          "kitty: a release without report-events is dropped");

    term->grid->kitty_kbd.flags[0] = KITTY_KBD_DISAMBIGUATE | KITTY_KBD_REPORT_ALL |
                                     KITTY_KBD_REPORT_EVENT;
    kbd_ctx_init(&ctx, XKB_KEY_a, "a", a_utf32, false);
    kitty_kbd_protocol(&seat, term, &ctx);
    term_capture_read(slave, buf, sizeof(buf));
    check_text(buf, "\033[97;1:3u", "kitty: a release is CSI 97;1:3u");

    term_capture_end(term, slave);

    if (seat.kbd.xkb_state != NULL)
        xkb_state_unref(seat.kbd.xkb_state);
    if (km != NULL)
        xkb_keymap_unref(km);
    if (xkb_ctx != NULL)
        xkb_context_unref(xkb_ctx);

    term_free(term);
}

/*
 * Pointer helpers (input.zig, D4d1).
 */
static void
test_pointer_helpers(void)
{
    struct terminal *term = term_new();
    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    static struct config conf;
    memset(&conf, 0, sizeof(conf));

    term->conf = &conf;
    term->width = 100;
    term->height = 60;
    term->margins.left = 4;
    term->margins.right = 2;
    term->margins.top = 3;
    term->margins.bottom = 1;
    term->cell_width = 10;
    term->cell_height = 20;
    term->cols = 9;   /* (100 - 4 - 2) / 10 */
    term->rows = 2;   /* (60 - 3 - 1) / 20 */

    mouse_coord_pixel_to_cell(&seat, term, 0, 0);
    check(seat.mouse.col == 0 && seat.mouse.row == 0,
          "a pointer in the top-left margin clamps to cell 0,0");

    mouse_coord_pixel_to_cell(&seat, term, 99, 59);
    check(seat.mouse.col == 8 && seat.mouse.row == 1,
          "a pointer in the bottom-right margin clamps to the last cell");

    mouse_coord_pixel_to_cell(&seat, term, 4 + 35, 3 + 45);
    check(seat.mouse.col == 3 && seat.mouse.row == 2,
          "pixels inside the grid map to cells, truncating fractions");

    /* Scroll multiplier */
    conf.scrollback.multiplier = 3.0;
    term->grid = &term->normal;
    check(mouse_scroll_multiplier(term, &seat) == 3.0,
          "the normal grid uses the configured scroll multiplier");

    term->grid = &term->alt;
    term->mouse_tracking = MOUSE_NONE;
    term->alt_scrolling = false;
    check(mouse_scroll_multiplier(term, &seat) == 1.0,
          "the alt grid without a grab ignores the multiplier");

    /* term_mouse_grabbed() falls back to "tracking == none" when the
     * terminal has no wayland connection, which is what the harness has. */
    term->mouse_tracking = MOUSE_NONE;
    term->alt_scrolling = true;
    check(mouse_scroll_multiplier(term, &seat) == 3.0,
          "the alt grid uses the multiplier when grabbed + alt-scrolling");

    term->alt_scrolling = false;
    check(mouse_scroll_multiplier(term, &seat) == 1.0,
          "the alt grid ignores the multiplier without alt-scrolling");

    /* Touch state */
    seat.wl_touch = NULL;
    seat.touch.state = TOUCH_STATE_HELD;
    check(!touch_is_active(&seat),
          "a seat without wl_touch never has an active touch");

    seat.wl_touch = (void *)0x1;
    check(touch_is_active(&seat), "a held touch is active");
    seat.touch.state = TOUCH_STATE_DRAGGING;
    check(touch_is_active(&seat), "a dragging touch is active");
    seat.touch.state = TOUCH_STATE_IDLE;
    check(!touch_is_active(&seat), "an idle touch is not active");
    seat.touch.state = TOUCH_STATE_INHIBITED;
    check(!touch_is_active(&seat), "an inhibited touch is not active");

    /* Button state */
    seat.mouse.count = 3;
    seat.mouse.last_released_button = BTN_LEFT;
    seat.mouse.last_time.tv_sec = 5;
    seat.mouse.last_time.tv_nsec = 7;
    mouse_button_state_reset(&seat);
    check(seat.mouse.count == 0 && seat.mouse.last_released_button == 0 &&
          seat.mouse.last_time.tv_sec == 0 && seat.mouse.last_time.tv_nsec == 0,
          "resetting the button state clears the click counters and timer");

    term->conf = NULL;
    term_free(term);
}

/*
 * keyboard_modifiers() (input.zig, D4b3): the xkb state update and the
 * cached shift/alt/ctrl/super flags, including the virtual-modifier masking.
 */
static void
test_keyboard_modifiers(void)
{
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *km = ctx != NULL
        ? xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS)
        : NULL;
    if (km == NULL) {
        printf("skip: no xkb keymap available\n");
        if (ctx != NULL)
            xkb_context_unref(ctx);
        return;
    }

    struct seat seat;
    memset(&seat, 0, sizeof(seat));
    seat.name = "modifier-test";
    seat.kbd.xkb = ctx;
    seat.kbd.xkb_keymap = km;
    seat.kbd.xkb_state = xkb_state_new(km);
    seat.kbd.mod_shift = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);
    seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CTRL);
    seat.kbd.mod_alt = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_ALT);
    seat.kbd.mod_super = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_LOGO);

    keyboard_modifiers(&seat, NULL, 1, 0, 0, 0, 0);
    check(!seat.kbd.shift && !seat.kbd.ctrl && !seat.kbd.alt && !seat.kbd.super,
          "no depressed modifiers clears all four flags");

    keyboard_modifiers(&seat, NULL, 2,
                       (1u << seat.kbd.mod_ctrl) | (1u << seat.kbd.mod_shift),
                       0, 0, 0);
    check(seat.kbd.ctrl && seat.kbd.shift,
          "ctrl+shift sets both cached flags");
    check(!seat.kbd.alt && !seat.kbd.super,
          "the other modifiers stay clear");

    /* Virtual modifiers (Mutter) are masked out before xkb sees them. */
    seat.kbd.virtual_modifiers = 1u << seat.kbd.mod_ctrl;
    keyboard_modifiers(&seat, NULL, 3, 1u << seat.kbd.mod_ctrl, 0, 0, 0);
    check(!seat.kbd.ctrl && !seat.kbd.shift,
          "a virtual modifier is ignored");

    xkb_state_unref(seat.kbd.xkb_state);
    xkb_keymap_unref(km);
    xkb_context_unref(ctx);
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
    test_render_primitives();
    test_render_refresh();
    test_render_margin();
    test_render_cell();
    test_render_ime_preedit();
    test_render_overlay();
    test_render_init();
    test_presentation_feedback();
    test_reapply_old_damage();
    test_render_worker_thread();
    test_render_wait_for_preapply_damage();
    test_overflowing_glyphs();
    test_set_size_from_grid();
    test_render_resize_early_outs();
    test_xcursor_set_early_outs();
    test_buffer_release_early_outs();
    test_keyboard_setup();
    test_modifier_helpers();
    test_keymap_lookup();
    test_kbd_protocols();
    test_pointer_helpers();
    test_keyboard_modifiers();
    test_scrollback_indicator();
    test_search_box_offset();
    test_url_label();
    test_grid_render_scroll();
    test_render_sixel();
    test_csd_buttons();
    test_csd_paint();
    test_csd_data();
    test_render_csd_part();
    test_configure();
    test_surface_listener();
    test_small_listeners();
    test_wayl_init_failure();
    test_seat_capabilities();
    test_handle_global();
    test_global_remove();
    test_wayland_misc();
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
