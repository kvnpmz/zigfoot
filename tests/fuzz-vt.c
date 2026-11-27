/*
 * Standalone VT/input fuzz harness.  This file deliberately has its own
 * main(); it is not part of the normal test suite or build.
 *
 * The terminal fixture follows tests/test-terminal.c:term_new(), with a real
 * pty and an initialized alternate grid so DEC private modes are safe.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "terminal.h"
#include "vt.h"
#include "grid.h"
#include "xmalloc.h"
#include "config.h"
#include "wayland.h"
#include "input.h"
#include "ime.h"
#include "key-binding.h"
#include "selection.h"
#include "server.h"
#include "fdm.h"
#include "client-protocol.h"
#include <sys/epoll.h>
#include <sys/socket.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>

#define ROWS 5
#define COLS 5
#define GRID_ROWS 16
#define FUZZ_INPUT_MAX 4096

/* Headless UI boundaries.  Some snapshots reference these normally-inline
 * protocol destructors from selection code; no fuzz path creates a source. */
void __wrap_zwp_primary_selection_source_v1_destroy(void *proxy)
{
    (void)proxy;
}

void __wrap_wl_data_source_destroy(void *proxy)
{
    (void)proxy;
}

void __wrap_render_shim_xdg_toplevel_set_title(void *toplevel, const char *title)
{
    (void)toplevel;
    (void)title;
}

void __wrap_wayland_shim_xdg_toplevel_set_app_id(void *toplevel, const char *app_id)
{
    (void)toplevel;
    (void)app_id;
}

static uint64_t rng_state;
static unsigned char current_input[FUZZ_INPUT_MAX];
static size_t current_len;
static unsigned current_iteration;
static char fail_header[160];
static size_t fail_header_len;
static int fail_fd = -1;

static void
write_fuzz_bytes(int fd)
{
    size_t sent = 0;
    while (sent < current_len) {
        ssize_t count = write(fd, current_input + sent, current_len - sent);
        if (count > 0)
            sent += (size_t)count;
        else if (count < 0 && errno == EINTR)
            continue;
        else
            break;
    }
}

void __wrap_wayland_shim_data_offer_receive(void *offer, const char *mime, int32_t fd)
{
    (void)offer;
    (void)mime;
    write_fuzz_bytes(fd);
}

void __wrap_wayland_shim_primary_offer_receive(void *offer, const char *mime, int32_t fd)
{
    (void)offer;
    (void)mime;
    write_fuzz_bytes(fd);
}

void __wrap_wayland_shim_add_data_offer_listener(void *offer, void *seat)
{
    (void)offer;
    (void)seat;
}

void __wrap_wayland_shim_add_primary_offer_listener(void *offer, void *seat)
{
    (void)offer;
    (void)seat;
}

void __wrap_wayland_shim_data_offer_destroy(void *offer) { (void)offer; }
void __wrap_wayland_shim_primary_selection_offer_destroy(void *offer) { (void)offer; }
void __wrap_wayland_shim_data_offer_accept(void *offer, uint32_t serial, const char *mime)
{
    (void)offer;
    (void)serial;
    (void)mime;
}
void __wrap_wayland_shim_data_offer_set_actions(void *offer, uint32_t actions, uint32_t preferred)
{
    (void)offer;
    (void)actions;
    (void)preferred;
}
void __wrap_wayland_shim_data_offer_finish(void *offer) { (void)offer; }

static uint64_t
next_random(void)
{
    uint64_t x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return x * UINT64_C(2685821657736338717);
}

static void
crash_handler(int sig)
{
    if (fail_fd < 0)
        return;
    (void)write(STDERR_FILENO, fail_header, fail_header_len);
    (void)write(fail_fd, current_input, current_len);
    _exit(128 + sig);
}

static void
install_crash_handler(void)
{
    const int signals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE};
    struct sigaction sa = {0};
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
        (void)sigaction(signals[i], &sa, NULL);
}

static struct row *
row_new(const char *content)
{
    struct row *row = xcalloc(1, sizeof(*row));
    xassert(row != NULL);
    row->cells = xcalloc(COLS, sizeof(row->cells[0]));
    xassert(row->cells != NULL);
    row->linebreak = true;
    row->shell_integration.cmd_start = -1;
    row->shell_integration.cmd_end = -1;
    for (int col = 0; col < COLS; col++) {
        row->cells[col].wc = 0;
        row->cells[col].attrs.fg_src = COLOR_DEFAULT;
        row->cells[col].attrs.bg_src = COLOR_DEFAULT;
    }
    if (content != NULL) {
        for (int col = 0; col < COLS && content[col] != '\0'; col++)
            row->cells[col].wc = (unsigned char)content[col];
    }
    return row;
}

static void
grid_init(struct grid *grid, bool populate)
{
    grid->rows = xcalloc(GRID_ROWS, sizeof(grid->rows[0]));
    xassert(grid->rows != NULL);
    grid->num_rows = GRID_ROWS;
    grid->num_cols = COLS;
    for (int row = 0; row < GRID_ROWS; row++) {
        char text[COLS + 1];
        if (populate)
            (void)snprintf(text, sizeof(text), "%d", row);
        grid->rows[row] = row_new(populate ? text : NULL);
    }
    grid->cur_row = grid->rows[0];
}

struct fixture {
    struct terminal *term;
    int master;
    int slave;
    int title_timer;
    int app_id_timer;
    int icon_timer;
    struct seat seat;
    struct wayland wayl;
    struct wl_window window;
    struct config conf;
    struct key_binding_manager *bindings;
};

static void
fixture_init(struct fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->master = -1;
    f->slave = -1;
    f->title_timer = -1;
    f->app_id_timer = -1;
    f->icon_timer = -1;
    f->term = xcalloc(1, sizeof(*f->term));
    xassert(f->term != NULL);

    f->term->rows = ROWS;
    f->term->cols = COLS;
    f->term->grid = &f->term->normal;
    grid_init(&f->term->normal, true);
    grid_init(&f->term->alt, false);
    f->term->scroll_region.end = ROWS;
    f->term->auto_margin = true;
    f->term->num_lock_modifier = true;
    f->term->charsets.selected = G0;
    for (size_t i = 0; i < 4; i++)
        f->term->charsets.set[i] = CHARSET_ASCII;
    f->term->selection.coords.start = (struct coord){-1, -1};
    f->term->selection.coords.end = (struct coord){-1, -1};
    f->term->selection.kind = SELECTION_NONE;
    f->term->selection.auto_scroll.fd = -1;
    f->term->cell_width = 1;
    f->term->cell_height = 1;
    f->term->scale = 1.0f;
    term_update_ascii_printer(f->term);

    f->master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK);
    xassert(f->master >= 0);
    xassert(grantpt(f->master) == 0);
    xassert(unlockpt(f->master) == 0);
    const char *slave_name = ptsname(f->master);
    xassert(slave_name != NULL);
    f->slave = open(slave_name, O_RDWR | O_NOCTTY | O_NONBLOCK);
    xassert(f->slave >= 0);
    f->term->ptmx = f->master;

    f->term->conf = &f->conf;
    f->conf.app_id = "foot";
    f->term->wl = &f->wayl;
    f->term->window = &f->window;
    f->window.term = f->term;
    f->title_timer = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    f->app_id_timer = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    f->icon_timer = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    xassert(f->title_timer >= 0 && f->app_id_timer >= 0 && f->icon_timer >= 0);
    f->term->render.title.timer_fd = f->title_timer;
    f->term->render.app_id.timer_fd = f->app_id_timer;
    f->term->render.icon.timer_fd = f->icon_timer;
    f->seat.wayl = &f->wayl;
    f->seat.kbd.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    xassert(f->seat.kbd.xkb != NULL);
    struct xkb_rule_names names = {.rules = "evdev", .model = "pc105",
                                   .layout = "us"};
    f->seat.kbd.xkb_keymap = xkb_keymap_new_from_names(
        f->seat.kbd.xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    xassert(f->seat.kbd.xkb_keymap != NULL);
    f->seat.kbd.xkb_state = xkb_state_new(f->seat.kbd.xkb_keymap);
    xassert(f->seat.kbd.xkb_state != NULL);
    f->seat.kbd.mod_shift = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Shift");
    f->seat.kbd.mod_alt = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Mod1");
    f->seat.kbd.mod_ctrl = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Control");
    f->seat.kbd.mod_super = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Mod4");
    f->seat.kbd.mod_caps = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Lock");
    f->seat.kbd.mod_num = xkb_keymap_mod_get_index(f->seat.kbd.xkb_keymap, "Mod2");
    f->seat.kbd.legacy_significant = UINT32_MAX;
    f->seat.kbd.kitty_significant = UINT32_MAX;
    f->seat.kbd.repeat.fd = -1;

    tll_push_back(f->wayl.terms, f->term);
    f->bindings = key_binding_manager_new();
    xassert(f->bindings != NULL);
    key_binding_new_for_seat(f->bindings, &f->seat);
    xassert(key_binding_for(f->bindings, &f->conf, &f->seat) != NULL);
}

static void
drain_pty(int fd)
{
    unsigned char buf[1024];
    for (;;) {
        ssize_t count = read(fd, buf, sizeof(buf));
        if (count > 0)
            continue;
        if (count < 0 && errno == EINTR)
            continue;
        break;
    }
}

static void
fixture_destroy(struct fixture *f)
{
    if (f->bindings != NULL) {
        key_binding_unload_keymap(f->bindings, &f->seat);
        key_binding_remove_seat(f->bindings, &f->seat);
        key_binding_manager_destroy(f->bindings);
    }
    tll_free(f->wayl.terms);
    ime_reset_pending(&f->seat);
    ime_reset_preedit(&f->seat);
    if (f->seat.kbd.xkb_state != NULL)
        xkb_state_unref(f->seat.kbd.xkb_state);
    if (f->seat.kbd.xkb_keymap != NULL)
        xkb_keymap_unref(f->seat.kbd.xkb_keymap);
    if (f->seat.kbd.xkb != NULL)
        xkb_context_unref(f->seat.kbd.xkb);
    if (f->term != NULL) {
        free(f->term->vt.osc.data);
        free(f->term->vt.dcs.data);
        free(f->term->vt.osc8.uri);
        tll_free(f->term->tab_stops);
        tll_free(f->term->normal.scroll_damage);
        tll_free(f->term->alt.scroll_damage);
        grid_free(&f->term->normal);
        grid_free(&f->term->alt);
        free(f->term);
    }
    if (f->slave >= 0)
        close(f->slave);
    if (f->master >= 0)
        close(f->master);
    if (f->title_timer >= 0)
        close(f->title_timer);
    if (f->app_id_timer >= 0)
        close(f->app_id_timer);
    if (f->icon_timer >= 0)
        close(f->icon_timer);
}

static const char *const corpus[] = {
    "\033[31;1mred\033[0m",
    "\033[1;2;3;4;5;7;8;9;38;2;255;0;0;48;5;123mX\033[0m",
    "\033[2;4r\033[5;1H\033[2J\033[99;99H",
    "\033[?1049hALT\033[?1049l",
    "\033[?7hwrap\033[?7lnowrap",
    "A\033[2D\033[1C\033[2K\033[1G",
    "e\314\201\342\200\214\346\274\242\360\237\230\200",
    "\300\257\355\240\200\364\220\200\377",
    "\033]8;;https://example.invalid/a?x=1\033\\link\033]8;;\033\\",
    "\033]52;c;SGVsbG8=\007",
    "\033]0;title\007",
    "\033P0;0q\"1;1#0@~-\033\\",
    "\033P0;0q#0;2;0;0;0~~~~",
    "\033Pqunterminated sixel ~~~~",
    "\033[>4;2m\033[=u\033[?u",
    "\033[999999999999999999999999999999999999999999999999999999999999A",
    "\033[;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;m",
    "\033[",
    "\033]8;;https://unterminated.invalid/",
    "trailing\033",
    "\033[?1000;1002;1003;1006;1016h\033[?1000l",
    "\033[3 a\033[?25l\033[?25h\033[?2004h\033[?2004l",
    "\033]777;notify;summary;body\033\\",
    "\033_apc\033\\\033X sos\033\\\033^ pm\033\\",
    "clip\r\n\001board\nfile:///tmp/a b\r\nhttps://example.invalid/\n",
    "\033]52;p;AAECAwQFBgcICQ==\007",
    /* XTGETTCAP: known, unknown, and final-capability regressions. */
    "\033P+q544e\033\\",
    "\033P+q544e;436f\033\\",
    "\033P+q524742\033\\",
    "\033P+q544e;\033\\",
    "\033P+q;\033\\",
    /* Checked-arithmetic regressions: these must be ignored, not abort. */
    "\033]4;4294967296;?\007",
    "\033]104;4294967296\007",
    "\033]10;rgb:fffffffff/0/0\007",
    "\033]11;#fffff0000000000\007",
    "\033]99;w=-2147483649;x\007",
    "\033[$1;1;4;1;1;2147483647;1;1$v"
};

static const unsigned char ipc_corpus[] = {
    0, 0, 0, 0, 4, 12, 0, 0, 0,
    0, 0, 0, 0, 4, 11, 0, 0, 0,
    1, 0, 0, 0, 255
};

#define CORPUS_COUNT (sizeof(corpus) / sizeof(corpus[0]))

static void
append_bytes(unsigned char *dst, size_t *len, const char *src, size_t count)
{
    if (count > FUZZ_INPUT_MAX - *len)
        count = FUZZ_INPUT_MAX - *len;
    memcpy(dst + *len, src, count);
    *len += count;
}

static void
mutate_input(void)
{
    size_t len = 0;
    unsigned pieces = 1 + (unsigned)(next_random() % 3);
    for (unsigned i = 0; i < pieces; i++) {
        if (next_random() % 13 == 0)
            append_bytes(current_input, &len, (const char *)ipc_corpus, sizeof(ipc_corpus));
        else {
            const char *piece = corpus[next_random() % CORPUS_COUNT];
            append_bytes(current_input, &len, piece, strlen(piece));
        }
    }

    unsigned mutations = 2 + (unsigned)(next_random() % 12);
    for (unsigned n = 0; n < mutations && len > 0; n++) {
        size_t pos = (size_t)(next_random() % len);
        switch (next_random() % 7) {
        case 0:
            current_input[pos] = (unsigned char)next_random();
            break;
        case 1:
            current_input[pos] ^= (unsigned char)(1u << (next_random() % 8));
            break;
        case 2:
            memmove(current_input + pos, current_input + pos + 1, len - pos - 1);
            len--;
            break;
        case 3:
            if (len < FUZZ_INPUT_MAX)
                append_bytes(current_input, &len, (const char *)current_input + pos, 1);
            break;
        case 4: {
            const char *piece = corpus[next_random() % CORPUS_COUNT];
            append_bytes(current_input, &len, piece, strlen(piece));
            break;
        }
        case 5:
            if (len < FUZZ_INPUT_MAX) {
                memmove(current_input + pos + 1, current_input + pos, len - pos);
                current_input[pos] = (unsigned char)next_random();
                len++;
            }
            break;
        case 6:
            current_input[pos] = "\033\007\010\012\015\037\177"[next_random() % 7];
            break;
        }
    }
    current_len = len;
}

static void
exercise_input(struct fixture *f)
{
    static const xkb_keysym_t symbols[] = {
        XKB_KEY_a, XKB_KEY_A, XKB_KEY_Return, XKB_KEY_BackSpace,
        XKB_KEY_Tab, XKB_KEY_Escape, XKB_KEY_Up, XKB_KEY_Shift_L,
        XKB_KEY_ISO_Left_Tab, XKB_KEY_KP_Enter, 0x1f600, 0x10ffff
    };
    struct kbd_ctx ctx = {0};
    uint32_t utf32[2] = {0, 0};
    unsigned char utf8[32];
    size_t count = current_len < sizeof(utf8) ? current_len : sizeof(utf8);
    memcpy(utf8, current_input, count);
    memset(utf8 + count, 0, sizeof(utf8) - count);
    ctx.sym = symbols[next_random() % (sizeof(symbols) / sizeof(symbols[0]))];
    ctx.key = 9 + (xkb_keycode_t)(next_random() % 200);
    ctx.utf8.buf = utf8;
    ctx.utf8.count = count;
    ctx.utf32 = utf32;
    utf32[0] = xkb_keysym_to_utf32(ctx.sym);
    ctx.key_state = (next_random() & 1) ? WL_KEYBOARD_KEY_STATE_PRESSED
                                       : WL_KEYBOARD_KEY_STATE_RELEASED;
    ctx.compose_status = (enum xkb_compose_status)(next_random() % 6);
    ctx.mods = (xkb_mod_mask_t)next_random();
    ctx.consumed = (xkb_mod_mask_t)next_random();

    f->seat.kbd.shift = next_random() & 1;
    f->seat.kbd.alt = next_random() & 1;
    f->seat.kbd.ctrl = next_random() & 1;
    f->seat.kbd.super = next_random() & 1;
    f->seat.kbd.repeat.dont_re_repeat = next_random() & 1;
    f->term->cursor_keys_mode = (enum cursor_keys)(next_random() % 3);
    f->term->keypad_keys_mode = (enum keypad_keys)(next_random() % 3);
    f->term->modify_other_keys_2 = next_random() & 1;
    f->term->num_lock_modifier = next_random() & 1;
    f->term->meta.esc_prefix = next_random() & 1;
    f->term->meta.eight_bit = next_random() & 1;
    f->term->grid->kitty_kbd.flags[next_random() % 8] =
        (enum kitty_kbd_flags)(next_random() % 32);
    f->term->grid->kitty_kbd.idx = (uint8_t)(next_random() % 8);

    (void)keymap_data_for_sym(ctx.sym, &(size_t){0});
    (void)keymap_lookup(f->term, ctx.sym, (int)(next_random() % 128));
    (void)legacy_kbd_protocol(&f->seat, f->term, &ctx);
    (void)kitty_kbd_protocol(&f->seat, f->term, &ctx);
    char mods[64];
    modifier_string((xkb_mod_mask_t)next_random(), sizeof(mods), mods, &f->seat);

    /* The pending IME callbacks only own duplicated strings.  Exercise both
     * normal and empty input, including invalid UTF-8 (the VT is responsible
     * for interpreting whatever reaches it). */
    unsigned char text[64];
    size_t text_len = next_random() % sizeof(text);
    if (current_len > 0) {
        for (size_t i = 0; i < text_len; i++)
            text[i] = current_input[next_random() % current_len];
    }
    text[text_len] = 0;
    ime_preedit_string(&f->seat, NULL, (const char *)text,
                       (int32_t)next_random(), (int32_t)next_random());
    ime_commit_string(&f->seat, NULL, (const char *)text);
    ime_delete_surrounding_text(&f->seat, NULL, (uint32_t)next_random(),
                                (uint32_t)next_random());
    ime_reset_pending(&f->seat);
    ime_reset_preedit(&f->seat);
}

struct receive_state {
    size_t bytes;
    unsigned calls;
    bool done;
};

static void
receive_cb(char *data, size_t size, void *user)
{
    struct receive_state *state = user;
    state->bytes += size;
    state->calls++;
}

static void
receive_done(void *user)
{
    ((struct receive_state *)user)->done = true;
}

static void
write_all(int fd, const void *data, size_t len)
{
    const unsigned char *bytes = data;
    while (len > 0) {
        ssize_t count = write(fd, bytes, len);
        if (count > 0) {
            bytes += count;
            len -= (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

void begin_receive_clipboard(
    struct terminal *term, bool no_strip, int read_fd, int mime_type,
    void (*cb)(char *data, size_t size, void *user),
    void (*done)(void *user), void *user);

static void
exercise_clipboard(struct fixture *f, unsigned mode)
{
    int fds[2];
    xassert(pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0);
    if (mode != 0) {
        size_t payload_len = current_len < 256 ? current_len : 256;
        write_all(fds[1], current_input, payload_len);
    }
    close(fds[1]);

    struct fdm *fdm = fdm_init();
    xassert(fdm != NULL);
    f->term->fdm = fdm;
    struct receive_state state = {0};
    void *offer = (void *)(uintptr_t)1;

    switch (mode) {
    case 0:
        begin_receive_clipboard(f->term, false, fds[0],
                                DATA_OFFER_MIME_URI_LIST, receive_cb, receive_done, &state);
        break;
    case 1:
        f->seat.clipboard.data_offer = offer;
        f->seat.clipboard.mime_type = DATA_OFFER_MIME_URI_LIST;
        f->term->bracketed_paste = next_random() & 1;
        selection_from_clipboard(&f->seat, f->term, (uint32_t)next_random());
        break;
    case 2:
        f->wayl.primary_selection_device_manager = offer;
        f->seat.primary.data_offer = offer;
        f->seat.primary.mime_type = (enum data_offer_mime_type)(1 + next_random() % 6);
        f->term->bracketed_paste = next_random() & 1;
        selection_from_primary(&f->seat, f->term);
        break;
    default:
        f->window.term = f->term;
        f->seat.clipboard.data_offer = offer;
        f->seat.clipboard.mime_type = DATA_OFFER_MIME_URI_LIST;
        f->seat.clipboard.window = &f->window;
        f->term->bracketed_paste = next_random() & 1;
        selection_data_device_drop(&f->seat, NULL);
        selection_data_device_leave(&f->seat, NULL);
        selection_data_device_motion(&f->seat, NULL, 0, 0, 0);
        break;
    }

    for (unsigned tries = 0; tries < 16; tries++) {
        bool finished = mode == 0 ? state.done : !f->term->is_sending_paste_data;
        if (finished)
            break;
        xassert(fdm_poll(fdm));
    }
    xassert(mode == 0 ? state.done : !f->term->is_sending_paste_data);
    f->term->fdm = NULL;
    fdm_destroy(fdm);
    f->seat.clipboard.data_offer = NULL;
    f->seat.clipboard.mime_type = DATA_OFFER_MIME_UNSET;
    f->seat.clipboard.window = NULL;
    f->seat.primary.data_offer = NULL;
    f->seat.primary.mime_type = DATA_OFFER_MIME_UNSET;
    f->wayl.primary_selection_device_manager = NULL;
    f->term->is_sending_paste_data = false;
}

static void
exercise_ipc(struct fixture *f)
{
    int fds[2];
    xassert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    struct server server = {0};
    struct client *client = xcalloc(1, sizeof(*client));
    client->server = &server;
    client->fd = fds[0];
    struct terminal_instance instance = {.terminal = f->term};
    client->instance = &instance;
    f->term->colors.active_theme = COLOR_THEME_DARK;

    struct client_ipc_hdr hdr = {.ipc_code = FOOT_IPC_SIGUSR,
                                 .size = sizeof(struct client_ipc_sigusr)};
    struct client_ipc_sigusr payload = {.signo = SIGUSR1};
    write_all(fds[1], &hdr, sizeof(hdr));
    write_all(fds[1], &payload, sizeof(payload));
    xassert(fdm_client(NULL, fds[0], EPOLLIN, client));
    free(client);
    close(fds[0]);
    close(fds[1]);

    fds[0] = fds[1] = -1;
    xassert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    client = xcalloc(1, sizeof(*client));
    client->server = &server;
    client->fd = fds[0];
    client->instance = &instance;
    write_all(fds[1], &hdr, 2);
    xassert(fdm_client(NULL, fds[0], EPOLLIN, client));
    free(client);
    close(fds[0]);
    close(fds[1]);

    fds[0] = fds[1] = -1;
    xassert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    client = xcalloc(1, sizeof(*client));
    client->server = &server;
    client->fd = fds[0];
    uint32_t total = UINT32_MAX;
    write_all(fds[1], &total, sizeof(total));
    xassert(fdm_client(NULL, fds[0], EPOLLIN, client));
    /* The server freed the client during shutdown. */
    close(fds[1]);
}

int
main(int argc, char **argv)
{
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s seed iterations [replay-input]\n", argv[0]);
        return 2;
    }
    errno = 0;
    unsigned long long seed_value = strtoull(argv[1], NULL, 0);
    unsigned long iterations = strtoull(argv[2], NULL, 0);
    if (errno != 0 || argv[1][0] == '\0' || argv[2][0] == '\0' ||
        iterations == 0 || iterations > 1000000) {
        fprintf(stderr, "invalid seed or iteration count\n");
        return 2;
    }
    rng_state = seed_value ^ UINT64_C(0x9e3779b97f4a7c15);
    if (rng_state == 0)
        rng_state = 1;

    const char *fail_path = getenv("FUZZ_VT_FAIL");
    if (fail_path != NULL) {
        fail_fd = open(fail_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fail_fd < 0) {
            perror("open failure artifact");
            return 2;
        }
    }
    install_crash_handler();

    bool replay = argc == 4;
    if (replay) {
        int fd = open(argv[3], O_RDONLY);
        if (fd < 0) {
            perror("open replay input");
            return 2;
        }
        current_len = 0;
        while (current_len < sizeof(current_input)) {
            ssize_t n = read(fd, current_input + current_len,
                             sizeof(current_input) - current_len);
            if (n > 0)
                current_len += (size_t)n;
            else if (n < 0 && errno == EINTR)
                continue;
            else
                break;
        }
        close(fd);
        if (current_len == 0) {
            fprintf(stderr, "empty replay input\n");
            return 2;
        }
        iterations = 1;
    }

    struct fixture fixture;
    fixture_init(&fixture);
    unsigned regression_mode = seed_value >= 117 && seed_value <= 120
        ? (unsigned)(seed_value - 116) : 0;
    for (current_iteration = 1; current_iteration <= iterations; current_iteration++) {
        if (!replay)
            mutate_input();
        int header_len = snprintf(fail_header, sizeof(fail_header),
                                  "seed=%llu iteration=%lu length=%zu\n",
                                  seed_value, iterations, current_len);
        if (header_len > 0)
            fail_header_len = (size_t)header_len;

        size_t pos = 0;
        while (pos < current_len) {
            size_t chunk = 1 + (size_t)(next_random() % 512);
            if (chunk > current_len - pos)
                chunk = current_len - pos;
            /* vt_from_slave() is the current name of the VT core entry point
             * historically called vt_parse(). */
            vt_from_slave(fixture.term, current_input + pos, chunk);
            pos += chunk;
        }
        drain_pty(fixture.slave);

        if (current_iteration % 11 == 0)
            exercise_input(&fixture);
        if (regression_mode >= 1 && regression_mode <= 3)
            exercise_clipboard(&fixture, regression_mode - 1);
        else if (regression_mode == 0 && current_iteration % 31 == 0)
            exercise_clipboard(&fixture, (unsigned)(next_random() % 4));
        if (regression_mode == 4 || current_iteration % 41 == 0)
            exercise_ipc(&fixture);
        if (current_iteration % 7 == 0) {
            key_binding_unload_keymap(fixture.bindings, &fixture.seat);
            key_binding_load_keymap(fixture.bindings, &fixture.seat);
            (void)key_binding_for(fixture.bindings, &fixture.conf, &fixture.seat);
        }
        if (current_iteration % 17 == 0) {
            char *text = NULL;
            size_t text_len = 0;
            if (term_view_to_text(fixture.term, &text, &text_len))
                free(text);
        }
    }
    fixture_destroy(&fixture);
    if (fail_fd >= 0)
        close(fail_fd);
    printf("seed=%llu iterations=%lu: ok\n", seed_value, iterations);
    return 0;
}
