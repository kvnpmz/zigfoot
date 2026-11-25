/* Zig shim for the terminal port.
 *
 * This file only holds what the Zig code cannot express yet:
 *
 *   1. C-only compile-time knowledge: object-like macros, sizeof/offsetof,
 *      #ifdef'd feature tests, and static inline wrappers around libc or
 *      wayland-client (wl_subsurface_set_sync(), c32width(), ...).
 *   2. Struct mirrors that have not landed yet: field reads of a struct that
 *      terminal_types.zig does not mirror. Delete these as soon as the struct
 *      is mirrored and pinned by the ABI probe (Track B).
 *   3. C-only types and varargs: regex_t, FILE, va_list forwarding.
 *
 * A function that no longer satisfies one of these must be deleted; the audit
 * rule and the current exemptions are documented in MIGRATION_PLAN.md 12.9.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "terminal.h"
#include "url-mode.h"
#include "grid.h"
#include "wayland.h"
#include "shm.h"

/* ── struct seat kbd state (unicode-mode) ─────────────────────────── */

/* struct seat is wayland.h's business; unicode-mode.zig only reads one flag
 * and sets one keysym. */


/* MB_CUR_MAX is a C macro (it expands to a thread-local lookup). */
size_t terminal_shim_mb_cur_max(void) {
    return MB_CUR_MAX;
}


/* urls_mode_is_active() is static inline in url-mode.h. */
bool terminal_shim_urls_mode_active(const struct terminal *term) {
    return urls_mode_is_active(term);
}

/* The null checks are defensive: in foot itself `window` is always set, but
 * the headless harness runs these paths without a wayland window. */


/* quirks.zig: the CSD subsurfaces the weston workaround walks. */




void quirk_shim_subsurface_set_desync(struct wl_subsurface *sub) {
    wl_subsurface_set_desync(sub);
}

void quirk_shim_subsurface_set_sync(struct wl_subsurface *sub) {
    wl_subsurface_set_sync(sub);
}

struct row *terminal_shim_grid_row_in_view(struct grid *grid, int row) {
    return grid_row_in_view(grid, row);
}

void terminal_shim_wl_surface_commit(struct wl_surface *surf) {
    wl_surface_commit(surf);
}

#include "grid.h"

struct row *terminal_shim_grid_row_and_alloc(struct grid *grid, int row_no) {
    return grid_row_and_alloc(grid, row_no);
}

int terminal_shim_grid_row_absolute(struct grid *grid, int row_no) {
    return grid_row_absolute(grid, row_no);
}

extern void erase_line(struct terminal *term, struct row *row);

void terminal_shim_erase_line(struct terminal *term, struct row *row) {
    erase_line(term, row);
}

struct row *terminal_shim_grid_row(struct grid *grid, int row_no) {
    return grid_row(grid, row_no);
}

void terminal_shim_term_reset_grapheme_state(struct terminal *term) {
    term_reset_grapheme_state(term);
}


/* ── term_process_and_print_non_ascii() support ──────────────────── */

#include <stdlib.h>

#include "emoji-variation-sequences.h"

uint32_t
terminal_shim_precompose(struct terminal *term, uint32_t base, uint32_t wc,
                         bool *base_from_primary,
                         bool *comb_from_primary,
                         bool *pre_from_primary)
{
    if (term->fonts[0] == NULL) {
        *base_from_primary = false;
        *comb_from_primary = false;
        *pre_from_primary = false;
        return (uint32_t)-1;
    }

    return fcft_precompose(
        term->fonts[0], base, wc,
        base_from_primary, comb_from_primary, pre_from_primary);
}

#if defined(FOOT_GRAPHEME_CLUSTERING)
static int
emoji_vs_compare(const void *_key, const void *_entry)
{
    const struct emoji_vs *key = _key;
    const struct emoji_vs *entry = _entry;

    uint32_t cp = key->start;

    if (cp < entry->start)
        return -1;
    else if (cp > entry->end)
        return 1;
    else
        return 0;
}
#endif

/*
 * Returns the forced grapheme width for a VS-15 (1) / VS-16 (2)
 * variation selector sequence, or -1 if the base character isn't in the
 * table (or isn't followed by a supported variation selector).
 */
int
terminal_shim_emoji_vs_width(uint32_t cp, uint32_t wc)
{
#if defined(FOOT_GRAPHEME_CLUSTERING)
    const struct emoji_vs *vs =
        bsearch(
            &(struct emoji_vs){.start = cp},
            emoji_vs, sizeof(emoji_vs) / sizeof(emoji_vs[0]),
            sizeof(struct emoji_vs),
            &emoji_vs_compare);

    if (vs != NULL) {
        if (wc == 0xfe0e && vs->vs15)
            return 1;
        if (wc == 0xfe0f && vs->vs16)
            return 2;
    }
#else
    (void)cp;
    (void)wc;
#endif

    return -1;
}


/* ── custom glyph freeing (terminal.zig) ─────────────────────────── */

/* fcft_glyph's layout is fcft's business; terminal.zig only needs pix. */
pixman_image_t *terminal_shim_fcft_glyph_pix(const struct fcft_glyph *glyph) {
    return glyph->pix;
}

/* ── font metrics (terminal.zig) ─────────────────────────────────── */

/* struct fcft_font is fcft's business; terminal.zig only reads these four
 * values, so hand them over as a plain struct instead of mirroring it. */
struct terminal_font_metrics {
    int height;
    int descent;
    int ascent;
    int max_advance_x;
};

struct terminal_font_metrics
terminal_shim_fcft_font_metrics(const struct fcft_font *font)
{
    return (struct terminal_font_metrics){
        .height = font->height,
        .descent = font->descent,
        .ascent = font->ascent,
        .max_advance_x = font->max_advance.x,
    };
}

int terminal_shim_fcft_glyph_advance_x(const struct fcft_glyph *glyph) {
    return glyph->advance.x;
}

const char *terminal_shim_fcft_font_name(const struct fcft_font *font) {
    return font->name;
}

bool terminal_shim_fcft_font_antialias(const struct fcft_font *font) {
    return font->antialias;
}

int terminal_shim_fcft_font_ascent(const struct fcft_font *font) {
    return font->ascent;
}

int terminal_shim_fcft_font_descent(const struct fcft_font *font) {
    return font->descent;
}

int terminal_shim_fcft_font_underline_position(const struct fcft_font *font) {
    return font->underline.position;
}

int terminal_shim_fcft_font_underline_thickness(const struct fcft_font *font) {
    return font->underline.thickness;
}

int terminal_shim_fcft_font_strikeout_position(const struct fcft_font *font) {
    return font->strikeout.position;
}

int terminal_shim_fcft_font_strikeout_thickness(const struct fcft_font *font) {
    return font->strikeout.thickness;
}

/* ── render.zig (D3a) ──────────────────────────────────────────────── */

/*
 * The curly underline is composited from two trapezoids. pixman_trapezoid_t
 * is a library type we would rather not mirror, so the geometry comes in
 * from Zig and the composite happens here.
 */
void render_shim_curly_underline(
    pixman_image_t *pix, const pixman_color_t *color,
    int x, int top, int bot, int half_x, int full_x, int th)
{
#define I(x) pixman_int_to_fixed(x)

    /* characters sit on top of the curlies */
    const pixman_trapezoid_t traps[] = {
        {
            I(top), I(bot),
            {{I(x), I(bot - th)}, {I(half_x), I(top - th)}},
            {{I(x), I(bot + th)}, {I(half_x), I(top + th)}},
        },
        {
            I(top), I(bot),
            {{I(half_x), I(top + th)}, {I(full_x), I(bot + th)}},
            {{I(half_x), I(top - th)}, {I(full_x), I(bot - th)}},
        },
    };

#undef I

    pixman_image_t *fill = pixman_image_create_solid_fill(color);
    pixman_composite_trapezoids(
        PIXMAN_OP_OVER, fill, pix, PIXMAN_a8, 0, 0, 0, 0,
        sizeof(traps) / sizeof(traps[0]), traps);
    pixman_image_unref(fill);
}

/* ── font loading (terminal.zig) ─────────────────────────────────── */

/* Headless harness has no wayland object; foot itself always does. */
bool terminal_shim_linear_blending(const struct terminal *term) {
    return term->wl != NULL && wayl_do_linear_blending(term->wl, term->conf);
}

/* Likewise: the harness has no buffer chains. */
bool terminal_shim_grid_is_high_bit_depth(const struct terminal *term) {
    return term->render.chains.grid != NULL &&
           shm_chain_bit_depth(term->render.chains.grid) >= SHM_BITS_10;
}

/* struct fcft_font_options is fcft's business; set only the three fields
 * reload_fonts() needs. The high-res format choice keeps the
 * HAVE_PIXMAN_RGBA_16 build option on the C side. */
void
terminal_shim_fcft_font_options_configure(
    struct fcft_font_options *options,
    enum fcft_scaling_filter scaling_filter,
    bool srgb_decode,
    bool high_res_color)
{
    options->scaling_filter = scaling_filter;
    options->color_glyphs.format = PIXMAN_a8r8g8b8;
    options->color_glyphs.srgb_decode = srgb_decode;

    if (high_res_color) {
        /*
         * Use a high-res buffer type for emojis. We don't want to use
         * an a2r10g0b10 type of surface, since we need more than 2
         * bits for alpha.
         */
#if defined(HAVE_PIXMAN_RGBA_16)
        options->color_glyphs.format = PIXMAN_a16b16g16r16;
#else
        options->color_glyphs.format = PIXMAN_rgba_float;
#endif
    }
}

/* util.h's thrd_err_as_string() is a static inline switch, which Zig cannot
 * call; the render-worker error paths log through this. */
#include "util.h"
#include "char32.h"
#include "input.h"
const char *terminal_shim_thrd_err_as_string(int thrd_err)
{
    return thrd_err_as_string(thrd_err);
}

/* sys/wait.h's status macros cannot be expressed in Zig; keep the platform's
 * own encoding instead of hard-coding the Linux one. */
#include <sys/wait.h>
#include <fcntl.h>
int terminal_shim_wifexited(int status)
{
    return WIFEXITED(status);
}
int terminal_shim_wexitstatus(int status)
{
    return WEXITSTATUS(status);
}
int terminal_shim_wifsignaled(int status)
{
    return WIFSIGNALED(status);
}
int terminal_shim_wtermsig(int status)
{
    return WTERMSIG(status);
}

/* xdg-shell's xdg_toplevel_set_maximized()/set_fullscreen() are static
 * inlines in the generated protocol header. */
void terminal_shim_xdg_toplevel_set_maximized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_set_maximized(toplevel);
}
void terminal_shim_xdg_toplevel_set_fullscreen(struct xdg_toplevel *toplevel,
                                               struct wl_output *output)
{
    xdg_toplevel_set_fullscreen(toplevel, output);
}
/* char32.h's comparison and predicate helpers are static inlines. */
int terminal_shim_c32ncmp(const char32_t *s1, const char32_t *s2, size_t n)
{
    return c32ncmp(s1, s2, n);
}
int terminal_shim_c32ncasecmp(const char32_t *s1, const char32_t *s2, size_t n)
{
    return c32ncasecmp(s1, s2, n);
}
bool terminal_shim_isc32print(char32_t c32)
{
    return isc32print(c32);
}
bool terminal_shim_isc32space(char32_t c32)
{
    return isc32space(c32);
}

bool terminal_shim_hasc32upper(const char32_t *s)
{
    return hasc32upper(s);
}

/* Generated-protocol static inlines (wayland.zig cannot see them). */
/* wayland.zig: window creation (D2i). */
void wayland_shim_region_add(
    struct wl_region *region, int32_t x, int32_t y, int32_t w, int32_t h)
{
    wl_region_add(region, x, y, w, h);
}

void wayland_shim_surface_set_opaque_region(
    struct wl_surface *surf, struct wl_region *region)
{
    wl_surface_set_opaque_region(surf, region);
}

void wayland_shim_set_blur_region(
    struct ext_background_effect_surface_v1 *effect, struct wl_region *region)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_surface_v1_set_blur_region(effect, region);
#else
    (void)effect;
    (void)region;
#endif
}

void *wayland_shim_activation_get_token(struct xdg_activation_v1 *activation)
{
    return xdg_activation_v1_get_activation_token(activation);
}

void wayland_shim_activation_token_set_serial(
    struct xdg_activation_token_v1 *token, uint32_t serial,
    struct wl_seat *seat)
{
    xdg_activation_token_v1_set_serial(token, serial, seat);
}

void wayland_shim_activation_token_set_surface(
    struct xdg_activation_token_v1 *token, struct wl_surface *surf)
{
    xdg_activation_token_v1_set_surface(token, surf);
}

void wayland_shim_activation_token_commit(
    struct xdg_activation_token_v1 *token)
{
    xdg_activation_token_v1_commit(token);
}

/* wayland.zig: seat setup/teardown (D2k). */
void *wayland_shim_data_device_manager_get_device(
    struct wl_data_device_manager *m, struct wl_seat *seat)
{
    return wl_data_device_manager_get_data_device(m, seat);
}

void *wayland_shim_primary_selection_device_manager_get_device(
    struct zwp_primary_selection_device_manager_v1 *m, struct wl_seat *seat)
{
    return zwp_primary_selection_device_manager_v1_get_device(m, seat);
}

void *wayland_shim_text_input_manager_get_text_input(
    struct zwp_text_input_manager_v3 *m, struct wl_seat *seat)
{
    return zwp_text_input_manager_v3_get_text_input(m, seat);
}

void wayland_shim_data_source_destroy(struct wl_data_source *src)
{
    wl_data_source_destroy(src);
}

void wayland_shim_data_offer_destroy(struct wl_data_offer *offer)
{
    wl_data_offer_destroy(offer);
}

void wayland_shim_data_device_release(struct wl_data_device *dev)
{
    wl_data_device_release(dev);
}

void wayland_shim_primary_selection_source_destroy(
    struct zwp_primary_selection_source_v1 *src)
{
    zwp_primary_selection_source_v1_destroy(src);
}

void wayland_shim_primary_selection_offer_destroy(
    struct zwp_primary_selection_offer_v1 *offer)
{
    zwp_primary_selection_offer_v1_destroy(offer);
}

void wayland_shim_primary_selection_device_destroy(
    struct zwp_primary_selection_device_v1 *dev)
{
    zwp_primary_selection_device_v1_destroy(dev);
}

void wayland_shim_cursor_shape_device_destroy(
    struct wp_cursor_shape_device_v1 *dev)
{
    wp_cursor_shape_device_v1_destroy(dev);
}

void wayland_shim_keyboard_release(struct wl_keyboard *kbd)
{
    wl_keyboard_release(kbd);
}

void wayland_shim_pointer_release(struct wl_pointer *pointer)
{
    wl_pointer_release(pointer);
}

void wayland_shim_touch_release(struct wl_touch *touch)
{
    wl_touch_release(touch);
}

void wayland_shim_text_input_destroy(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_destroy(ti);
}

void wayland_shim_seat_release(struct wl_seat *seat)
{
    wl_seat_release(seat);
}

void wayland_shim_ack_configure(struct xdg_surface *xdg_surface, uint32_t serial)
{
    xdg_surface_ack_configure(xdg_surface, serial);
}

/* wayland.zig: wayl_init()/wayl_destroy() (D2k5). */
struct wl_registry *wayland_shim_display_get_registry(
    struct wl_display *display)
{
    return wl_display_get_registry(display);
}

/* wayland.zig: seat capabilities (D2k6). */
struct wl_keyboard *wayland_shim_seat_get_keyboard(struct wl_seat *seat)
{
    return wl_seat_get_keyboard(seat);
}

struct wl_pointer *wayland_shim_seat_get_pointer(struct wl_seat *seat)
{
    return wl_seat_get_pointer(seat);
}

struct wl_touch *wayland_shim_seat_get_touch(struct wl_seat *seat)
{
    return wl_seat_get_touch(seat);
}

struct wp_cursor_shape_device_v1 *wayland_shim_cursor_shape_get_pointer(
    struct wp_cursor_shape_manager_v1 *manager, struct wl_pointer *pointer)
{
    return wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
}

void wayland_shim_add_keyboard_listener(
    struct wl_keyboard *kbd, struct seat *seat)
{
    wl_keyboard_add_listener(kbd, &keyboard_listener, seat);
}

void wayland_shim_add_pointer_listener(
    struct wl_pointer *pointer, struct seat *seat)
{
    wl_pointer_add_listener(pointer, &pointer_listener, seat);
}

void wayland_shim_add_touch_listener(struct wl_touch *touch, struct seat *seat)
{
    wl_touch_add_listener(touch, &touch_listener, seat);
}

/* wayland.zig: registry globals (D2k7). The interface objects and the
 * listener tables are all static or generated C, so the names are matched
 * and the bind performed here, keyed by an integer the Zig side switches on. */
enum wayland_iface {
    WAYLAND_IFACE_NONE = 0,
    WAYLAND_IFACE_COMPOSITOR,
    WAYLAND_IFACE_SUBCOMPOSITOR,
    WAYLAND_IFACE_SHM,
    WAYLAND_IFACE_XDG_WM_BASE,
    WAYLAND_IFACE_XDG_DECORATION,
    WAYLAND_IFACE_SEAT,
    WAYLAND_IFACE_XDG_OUTPUT_MANAGER,
    WAYLAND_IFACE_OUTPUT,
    WAYLAND_IFACE_DATA_DEVICE_MANAGER,
    WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER,
    WAYLAND_IFACE_PRESENTATION,
    WAYLAND_IFACE_XDG_ACTIVATION,
    WAYLAND_IFACE_VIEWPORTER,
    WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER,
    WAYLAND_IFACE_CURSOR_SHAPE_MANAGER,
    WAYLAND_IFACE_SINGLE_PIXEL_MANAGER,
    WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER,
    WAYLAND_IFACE_SYSTEM_BELL,
    WAYLAND_IFACE_COLOR_MANAGER,
    WAYLAND_IFACE_FIXES,
    WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER,
    WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER,
    WAYLAND_IFACE_TEXT_INPUT_MANAGER,
};

int wayland_shim_iface_id(const char *interface)
{
    if (streq(interface, wl_compositor_interface.name))
        return WAYLAND_IFACE_COMPOSITOR;
    if (streq(interface, wl_subcompositor_interface.name))
        return WAYLAND_IFACE_SUBCOMPOSITOR;
    if (streq(interface, wl_shm_interface.name))
        return WAYLAND_IFACE_SHM;
    if (streq(interface, xdg_wm_base_interface.name))
        return WAYLAND_IFACE_XDG_WM_BASE;
    if (streq(interface, zxdg_decoration_manager_v1_interface.name))
        return WAYLAND_IFACE_XDG_DECORATION;
    if (streq(interface, wl_seat_interface.name))
        return WAYLAND_IFACE_SEAT;
    if (streq(interface, zxdg_output_manager_v1_interface.name))
        return WAYLAND_IFACE_XDG_OUTPUT_MANAGER;
    if (streq(interface, wl_output_interface.name))
        return WAYLAND_IFACE_OUTPUT;
    if (streq(interface, wl_data_device_manager_interface.name))
        return WAYLAND_IFACE_DATA_DEVICE_MANAGER;
    if (streq(interface, zwp_primary_selection_device_manager_v1_interface.name))
        return WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER;
    if (streq(interface, wp_presentation_interface.name))
        return WAYLAND_IFACE_PRESENTATION;
    if (streq(interface, xdg_activation_v1_interface.name))
        return WAYLAND_IFACE_XDG_ACTIVATION;
    if (streq(interface, wp_viewporter_interface.name))
        return WAYLAND_IFACE_VIEWPORTER;
    if (streq(interface, wp_fractional_scale_manager_v1_interface.name))
        return WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER;
    if (streq(interface, wp_cursor_shape_manager_v1_interface.name))
        return WAYLAND_IFACE_CURSOR_SHAPE_MANAGER;
    if (streq(interface, wp_single_pixel_buffer_manager_v1_interface.name))
        return WAYLAND_IFACE_SINGLE_PIXEL_MANAGER;
    if (streq(interface, xdg_toplevel_icon_manager_v1_interface.name))
        return WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER;
    if (streq(interface, xdg_system_bell_v1_interface.name))
        return WAYLAND_IFACE_SYSTEM_BELL;
    if (streq(interface, wp_color_manager_v1_interface.name))
        return WAYLAND_IFACE_COLOR_MANAGER;
#if defined(WL_FIXES_INTERFACE)
    if (streq(interface, wl_fixes_interface.name))
        return WAYLAND_IFACE_FIXES;
#endif
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    if (streq(interface, xdg_toplevel_tag_manager_v1_interface.name))
        return WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER;
#endif
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    if (streq(interface, ext_background_effect_manager_v1_interface.name))
        return WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER;
#endif
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    if (streq(interface, zwp_text_input_manager_v3_interface.name))
        return WAYLAND_IFACE_TEXT_INPUT_MANAGER;
#endif
    return WAYLAND_IFACE_NONE;
}

void *wayland_shim_registry_bind(
    struct wl_registry *registry, uint32_t name, int which, uint32_t version)
{
    switch (which) {
    case WAYLAND_IFACE_COMPOSITOR:
        return wl_registry_bind(
            registry, name, &wl_compositor_interface, version);
    case WAYLAND_IFACE_SUBCOMPOSITOR:
        return wl_registry_bind(
            registry, name, &wl_subcompositor_interface, version);
    case WAYLAND_IFACE_SHM:
        return wl_registry_bind(registry, name, &wl_shm_interface, version);
    case WAYLAND_IFACE_XDG_WM_BASE:
        return wl_registry_bind(registry, name, &xdg_wm_base_interface, version);
    case WAYLAND_IFACE_XDG_DECORATION:
        return wl_registry_bind(
            registry, name, &zxdg_decoration_manager_v1_interface, version);
    case WAYLAND_IFACE_SEAT:
        return wl_registry_bind(registry, name, &wl_seat_interface, version);
    case WAYLAND_IFACE_XDG_OUTPUT_MANAGER:
        return wl_registry_bind(
            registry, name, &zxdg_output_manager_v1_interface, version);
    case WAYLAND_IFACE_OUTPUT:
        return wl_registry_bind(registry, name, &wl_output_interface, version);
    case WAYLAND_IFACE_DATA_DEVICE_MANAGER:
        return wl_registry_bind(
            registry, name, &wl_data_device_manager_interface, version);
    case WAYLAND_IFACE_PRIMARY_SELECTION_DEVICE_MANAGER:
        return wl_registry_bind(
            registry, name, &zwp_primary_selection_device_manager_v1_interface,
            version);
    case WAYLAND_IFACE_PRESENTATION:
        return wl_registry_bind(
            registry, name, &wp_presentation_interface, version);
    case WAYLAND_IFACE_XDG_ACTIVATION:
        return wl_registry_bind(
            registry, name, &xdg_activation_v1_interface, version);
    case WAYLAND_IFACE_VIEWPORTER:
        return wl_registry_bind(
            registry, name, &wp_viewporter_interface, version);
    case WAYLAND_IFACE_FRACTIONAL_SCALE_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_fractional_scale_manager_v1_interface, version);
    case WAYLAND_IFACE_CURSOR_SHAPE_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_cursor_shape_manager_v1_interface, version);
    case WAYLAND_IFACE_SINGLE_PIXEL_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_single_pixel_buffer_manager_v1_interface,
            version);
    case WAYLAND_IFACE_TOPLEVEL_ICON_MANAGER:
        return wl_registry_bind(
            registry, name, &xdg_toplevel_icon_manager_v1_interface, version);
    case WAYLAND_IFACE_SYSTEM_BELL:
        return wl_registry_bind(
            registry, name, &xdg_system_bell_v1_interface, version);
    case WAYLAND_IFACE_COLOR_MANAGER:
        return wl_registry_bind(
            registry, name, &wp_color_manager_v1_interface, version);
#if defined(WL_FIXES_INTERFACE)
    case WAYLAND_IFACE_FIXES:
        return wl_registry_bind(registry, name, &wl_fixes_interface, version);
#endif
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    case WAYLAND_IFACE_TOPLEVEL_TAG_MANAGER:
        return wl_registry_bind(
            registry, name, &xdg_toplevel_tag_manager_v1_interface, version);
#endif
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    case WAYLAND_IFACE_BACKGROUND_EFFECT_MANAGER:
        return wl_registry_bind(
            registry, name, &ext_background_effect_manager_v1_interface,
            version);
#endif
#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    case WAYLAND_IFACE_TEXT_INPUT_MANAGER:
        return wl_registry_bind(
            registry, name, &zwp_text_input_manager_v3_interface, version);
#endif
    }
    return NULL;
}

void *wayland_shim_get_xdg_output(struct zxdg_output_manager_v1 *manager,
                                  struct wl_output *output)
{
    return zxdg_output_manager_v1_get_xdg_output(manager, output);
}

bool wayland_shim_fdm_add_repeat(struct fdm *fdm, struct seat *seat);

/* wayland.zig: colour management (D2k8). */
void *wayland_shim_color_create_parametric_creator(
    struct wp_color_manager_v1 *manager)
{
    return wp_color_manager_v1_create_parametric_creator(manager);
}

void wayland_shim_color_params_set_tf_named(
    struct wp_image_description_creator_params_v1 *params, uint32_t tf)
{
    wp_image_description_creator_params_v1_set_tf_named(params, tf);
}

void wayland_shim_color_params_set_primaries_named(
    struct wp_image_description_creator_params_v1 *params, uint32_t primaries)
{
    wp_image_description_creator_params_v1_set_primaries_named(params, primaries);
}

void *wayland_shim_color_params_create(
    struct wp_image_description_creator_params_v1 *params)
{
    return wp_image_description_creator_params_v1_create(params);
}

void wayland_shim_wm_base_pong(struct xdg_wm_base *shell, uint32_t serial)
{
    xdg_wm_base_pong(shell, serial);
}

void wayland_shim_fixes_ack_global_remove(
    struct wl_fixes *fixes, struct wl_registry *registry, uint32_t name)
{
#if defined(WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION)
    wl_fixes_ack_global_remove(fixes, registry, name);
#else
    (void)fixes;
    (void)registry;
    (void)name;
#endif
}


int wayland_shim_fcntl_getfl(int fd)
{
    return fcntl(fd, F_GETFL);
}

int wayland_shim_fcntl_setfl(int fd, int flags)
{
    return fcntl(fd, F_SETFL, flags);
}

void wayland_shim_text_input_manager_destroy(struct zwp_text_input_manager_v3 *m)
{
    zwp_text_input_manager_v3_destroy(m);
}

void wayland_shim_toplevel_tag_manager_destroy(
    struct xdg_toplevel_tag_manager_v1 *m)
{
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    xdg_toplevel_tag_manager_v1_destroy(m);
#else
    (void)m;
#endif
}

void wayland_shim_background_effect_manager_destroy(
    struct ext_background_effect_manager_v1 *m)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_manager_v1_destroy(m);
#else
    (void)m;
#endif
}

void wayland_shim_image_description_destroy(
    struct wp_image_description_v1 *desc)
{
    wp_image_description_v1_destroy(desc);
}

void wayland_shim_color_manager_destroy(struct wp_color_manager_v1 *m)
{
    wp_color_manager_v1_destroy(m);
}

void wayland_shim_system_bell_destroy(struct xdg_system_bell_v1 *bell)
{
    xdg_system_bell_v1_destroy(bell);
}

void wayland_shim_toplevel_icon_manager_destroy(
    struct xdg_toplevel_icon_manager_v1 *m)
{
    xdg_toplevel_icon_manager_v1_destroy(m);
}

void wayland_shim_single_pixel_manager_destroy(
    struct wp_single_pixel_buffer_manager_v1 *m)
{
    wp_single_pixel_buffer_manager_v1_destroy(m);
}

void wayland_shim_fractional_scale_manager_destroy(
    struct wp_fractional_scale_manager_v1 *m)
{
    wp_fractional_scale_manager_v1_destroy(m);
}

void wayland_shim_viewporter_destroy(struct wp_viewporter *viewporter)
{
    wp_viewporter_destroy(viewporter);
}

void wayland_shim_cursor_shape_manager_destroy(
    struct wp_cursor_shape_manager_v1 *m)
{
    wp_cursor_shape_manager_v1_destroy(m);
}

void wayland_shim_activation_destroy(struct xdg_activation_v1 *activation)
{
    xdg_activation_v1_destroy(activation);
}

void wayland_shim_output_manager_destroy(struct zxdg_output_manager_v1 *m)
{
    zxdg_output_manager_v1_destroy(m);
}

void wayland_shim_wm_base_destroy(struct xdg_wm_base *shell)
{
    xdg_wm_base_destroy(shell);
}

void wayland_shim_decoration_manager_destroy(
    struct zxdg_decoration_manager_v1 *m)
{
    zxdg_decoration_manager_v1_destroy(m);
}

void wayland_shim_presentation_destroy(struct wp_presentation *presentation)
{
    wp_presentation_destroy(presentation);
}

void wayland_shim_data_device_manager_destroy(
    struct wl_data_device_manager *m)
{
    wl_data_device_manager_destroy(m);
}

void wayland_shim_primary_selection_device_manager_destroy(
    struct zwp_primary_selection_device_manager_v1 *m)
{
    zwp_primary_selection_device_manager_v1_destroy(m);
}

void wayland_shim_shm_destroy(struct wl_shm *shm, bool use_release)
{
#if defined(WL_SHM_RELEASE_SINCE_VERSION)
    if (use_release) {
        wl_shm_release(shm);
        return;
    }
#else
    (void)use_release;
#endif
    wl_shm_destroy(shm);
}

void wayland_shim_subcompositor_destroy(struct wl_subcompositor *sub_compositor)
{
    wl_subcompositor_destroy(sub_compositor);
}

void wayland_shim_compositor_destroy(struct wl_compositor *compositor)
{
    wl_compositor_destroy(compositor);
}

void wayland_shim_fixes_destroy(struct wl_fixes *fixes)
{
#if defined(WL_FIXES_INTERFACE)
    wl_fixes_destroy(fixes);
#else
    (void)fixes;
#endif
}

void wayland_shim_registry_destroy(struct wl_registry *registry)
{
    wl_registry_destroy(registry);
}


void *wayland_shim_fractional_scale_get(struct wp_fractional_scale_manager_v1 *m,
                                        struct wl_surface *surf)
{
    return wp_fractional_scale_manager_v1_get_fractional_scale(m, surf);
}

void *wayland_shim_background_effect_get(
    struct ext_background_effect_manager_v1 *m, struct wl_surface *surf)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    return ext_background_effect_manager_v1_get_background_effect(m, surf);
#else
    (void)m;
    (void)surf;
    return NULL;
#endif
}

void *wayland_shim_xdg_wm_base_get_xdg_surface(
    struct xdg_wm_base *shell, struct wl_surface *surf)
{
    return xdg_wm_base_get_xdg_surface(shell, surf);
}

void *wayland_shim_xdg_surface_get_toplevel(struct xdg_surface *xdg_surface)
{
    return xdg_surface_get_toplevel(xdg_surface);
}

void wayland_shim_xdg_toplevel_set_app_id(
    struct xdg_toplevel *toplevel, const char *app_id)
{
    xdg_toplevel_set_app_id(toplevel, app_id);
}

void wayland_shim_toplevel_tag_set(
    struct xdg_toplevel_tag_manager_v1 *m, struct xdg_toplevel *toplevel,
    const char *tag)
{
#if defined(HAVE_XDG_TOPLEVEL_TAG)
    xdg_toplevel_tag_manager_v1_set_toplevel_tag(m, toplevel, tag);
    /* TODO: the description is recommended to be the tag, but translated */
    xdg_toplevel_tag_manager_v1_set_toplevel_description(m, toplevel, tag);
#else
    (void)m;
    (void)toplevel;
    (void)tag;
#endif
}

void wayland_shim_toplevel_icon_set(
    struct xdg_toplevel_icon_manager_v1 *m, struct xdg_toplevel *toplevel,
    const char *name)
{
    struct xdg_toplevel_icon_v1 *icon =
        xdg_toplevel_icon_manager_v1_create_icon(m);
    xdg_toplevel_icon_v1_set_name(icon, name);
    xdg_toplevel_icon_manager_v1_set_icon(m, toplevel, icon);
    xdg_toplevel_icon_v1_destroy(icon);
}

void *wayland_shim_decoration_get(
    struct zxdg_decoration_manager_v1 *m, struct xdg_toplevel *toplevel)
{
    return zxdg_decoration_manager_v1_get_toplevel_decoration(m, toplevel);
}

void wayland_shim_decoration_set_mode(void *decoration, uint32_t mode)
{
    zxdg_toplevel_decoration_v1_set_mode(decoration, mode);
}

void wayland_shim_surface_attach(
    struct wl_surface *surf, struct wl_buffer *buffer, int32_t x, int32_t y)
{
    wl_surface_attach(surf, buffer, x, y);
}

void wayland_shim_surface_commit(struct wl_surface *surf)
{
    wl_surface_commit(surf);
}

void *wayland_shim_surface_get_user_data(struct wl_surface *surf)
{
    return wl_surface_get_user_data(surf);
}

void wayland_shim_wl_callback_destroy(struct wl_callback *callback)
{
    wl_callback_destroy(callback);
}

void wayland_shim_xdg_surface_destroy(struct xdg_surface *xdg_surface)
{
    xdg_surface_destroy(xdg_surface);
}

void wayland_shim_xdg_toplevel_destroy(struct xdg_toplevel *xdg_toplevel)
{
    xdg_toplevel_destroy(xdg_toplevel);
}

void wayland_shim_xdg_toplevel_decoration_destroy(
    struct zxdg_toplevel_decoration_v1 *decoration)
{
    zxdg_toplevel_decoration_v1_destroy(decoration);
}

void wayland_shim_fractional_scale_destroy(
    struct wp_fractional_scale_v1 *scale)
{
    wp_fractional_scale_v1_destroy(scale);
}

void wayland_shim_destroy_background_effect(
    struct ext_background_effect_surface_v1 *effect)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_surface_v1_destroy(effect);
#else
    (void)effect;
#endif
}

void wayland_shim_xdg_activation_token_destroy(
    struct xdg_activation_token_v1 *token)
{
    xdg_activation_token_v1_destroy(token);
}

void wayland_shim_zxdg_output_destroy(struct zxdg_output_v1 *xdg_output)
{
    zxdg_output_v1_destroy(xdg_output);
}

void wayland_shim_wl_output_destroy(struct wl_output *output)
{
    wl_output_destroy(output);
}

void wayland_shim_wl_output_release(struct wl_output *output)
{
    wl_output_release(output);
}

struct wl_surface *wayland_shim_compositor_create_surface(
    struct wl_compositor *compositor)
{
    return wl_compositor_create_surface(compositor);
}

struct wl_region *wayland_shim_compositor_create_region(
    struct wl_compositor *compositor)
{
    return wl_compositor_create_region(compositor);
}

struct wl_subsurface *wayland_shim_subcompositor_get_subsurface(
    struct wl_subcompositor *subcompositor, struct wl_surface *surface,
    struct wl_surface *parent)
{
    return wl_subcompositor_get_subsurface(subcompositor, surface, parent);
}

struct wp_viewport *wayland_shim_viewporter_get_viewport(
    struct wp_viewporter *viewporter, struct wl_surface *surface)
{
    return wp_viewporter_get_viewport(viewporter, surface);
}

struct wp_color_management_surface_v1 *wayland_shim_color_manager_get_surface(
    struct wp_color_manager_v1 *manager, struct wl_surface *surface)
{
    return wp_color_manager_v1_get_surface(manager, surface);
}

void wayland_shim_color_management_set_image_description(
    struct wp_color_management_surface_v1 *cm_surface,
    struct wp_image_description_v1 *img, uint32_t intent)
{
    wp_color_management_surface_v1_set_image_description(
        cm_surface, img, intent);
}

void wayland_shim_color_management_surface_destroy(
    struct wp_color_management_surface_v1 *cm_surface)
{
    wp_color_management_surface_v1_destroy(cm_surface);
}

void wayland_shim_surface_destroy(struct wl_surface *surf)
{
    wl_surface_destroy(surf);
}

void wayland_shim_surface_set_user_data(struct wl_surface *surf, void *data)
{
    wl_surface_set_user_data(surf, data);
}

void wayland_shim_surface_set_input_region(
    struct wl_surface *surf, struct wl_region *region)
{
    wl_surface_set_input_region(surf, region);
}

void wayland_shim_region_destroy(struct wl_region *region)
{
    wl_region_destroy(region);
}

void wayland_shim_subsurface_destroy(struct wl_subsurface *sub)
{
    wl_subsurface_destroy(sub);
}

void wayland_shim_viewport_destroy(struct wp_viewport *viewport)
{
    wp_viewport_destroy(viewport);
}

void wayland_shim_xdg_system_bell_ring(
    struct xdg_system_bell_v1 *bell, struct wl_surface *surface)
{
    xdg_system_bell_v1_ring(bell, surface);
}

void wayland_shim_xdg_activation_activate(
    struct xdg_activation_v1 *activation, const char *token,
    struct wl_surface *surface)
{
    xdg_activation_v1_activate(activation, token, surface);
}

void wayland_shim_surface_set_buffer_scale(struct wl_surface *surf, int32_t scale)
{
    wl_surface_set_buffer_scale(surf, scale);
}

void wayland_shim_viewport_set_destination(
    struct wp_viewport *viewport, int32_t width, int32_t height)
{
    wp_viewport_set_destination(viewport, width, height);
}

/* grid.h's grid_row_absolute_in_view() is a static inline. */
int terminal_shim_grid_row_absolute_in_view(const struct grid *grid, int row_no)
{
    return grid_row_absolute_in_view(grid, row_no);
}
