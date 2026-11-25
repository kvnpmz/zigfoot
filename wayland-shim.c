/* C shim for the wayland port.
 *
 * Only the generated-protocol listener tables and their add_listener() calls
 * live here: both are generated-static-inline/C-type knowledge that Zig does
 * not mirror. The callbacks the tables reference are the Zig exports declared
 * in wayland.h. The FDM callbacks and their registration forwarders are in
 * wayland.zig.
 */

#include "wayland.h"

#include "ime.h"
#include "input.h"
#include "selection.h"

/* selection.zig (D5d-b2): the data-source / data-offer listener tables. The
 * callbacks are Zig exports (selection.h); only the generated table layout
 * is C knowledge. */
const struct wl_data_source_listener data_source_listener = {
    .target = &selection_data_source_target,
    .send = &selection_data_source_send,
    .cancelled = &selection_data_source_cancelled,
    .dnd_drop_performed = &selection_data_source_dnd_drop_performed,
    .dnd_finished = &selection_data_source_dnd_finished,
    .action = &selection_data_source_action,
};

const struct zwp_primary_selection_source_v1_listener
    primary_selection_source_listener = {
    .send = &selection_primary_source_send,
    .cancelled = &selection_primary_source_cancelled,
};

static const struct wl_data_offer_listener data_offer_listener = {
    .offer = &selection_offer,
    .source_actions = &selection_offer_source_actions,
    .action = &selection_offer_action,
};

static const struct zwp_primary_selection_offer_v1_listener
    primary_selection_offer_listener = {
    .offer = &selection_primary_offer,
};

const struct wl_data_device_listener data_device_listener = {
    .data_offer = &selection_data_device_data_offer,
    .enter = &selection_data_device_enter,
    .leave = &selection_data_device_leave,
    .motion = &selection_data_device_motion,
    .drop = &selection_data_device_drop,
    .selection = &selection_data_device_selection,
};

const struct zwp_primary_selection_device_v1_listener
    primary_selection_device_listener = {
    .data_offer = &selection_primary_device_data_offer,
    .selection = &selection_primary_device_selection,
};

void wayland_shim_add_data_device_listener(
    struct wl_data_device *dev, struct seat *seat)
{
    wl_data_device_add_listener(dev, &data_device_listener, seat);
}

void wayland_shim_add_primary_selection_device_listener(
    struct zwp_primary_selection_device_v1 *dev, struct seat *seat)
{
    zwp_primary_selection_device_v1_add_listener(
        dev, &primary_selection_device_listener, seat);
}

void wayland_shim_add_data_source_listener(
    struct wl_data_source *source, struct seat *seat)
{
    wl_data_source_add_listener(source, &data_source_listener, seat);
}

void wayland_shim_add_primary_source_listener(
    struct zwp_primary_selection_source_v1 *source, struct seat *seat)
{
    zwp_primary_selection_source_v1_add_listener(
        source, &primary_selection_source_listener, seat);
}

void wayland_shim_add_data_offer_listener(
    struct wl_data_offer *offer, struct seat *seat)
{
    wl_data_offer_add_listener(offer, &data_offer_listener, seat);
}

void wayland_shim_add_primary_offer_listener(
    struct zwp_primary_selection_offer_v1 *offer, struct seat *seat)
{
    zwp_primary_selection_offer_v1_add_listener(
        offer, &primary_selection_offer_listener, seat);
}

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
const struct zwp_text_input_v3_listener text_input_listener = {
    .enter = &ime_enter,
    .leave = &ime_leave,
    .preedit_string = &ime_preedit_string,
    .commit_string = &ime_commit_string,
    .delete_surrounding_text = &ime_delete_surrounding_text,
    .done = &ime_done,
};
#endif

void wayland_shim_add_text_input_listener(
    struct zwp_text_input_v3 *ti, struct seat *seat)
{
    zwp_text_input_v3_add_listener(ti, &text_input_listener, seat);
}

static const struct wl_shm_listener shm_listener = {
    .format = &shm_format,
};

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = &xdg_wm_base_ping,
};

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_handle_capabilities,
    .name = seat_handle_name,
};

static const struct wl_output_listener output_listener = {
    .geometry = &output_geometry,
    .mode = &output_mode,
    .done = &output_done,
    .scale = &output_scale,
#if defined(WL_OUTPUT_NAME_SINCE_VERSION)
    .name = &output_name,
#endif
#if defined(WL_OUTPUT_DESCRIPTION_SINCE_VERSION)
    .description = &output_description,
#endif
};

static const struct zxdg_output_v1_listener xdg_output_listener = {
    .logical_position = xdg_output_handle_logical_position,
    .logical_size = xdg_output_handle_logical_size,
    .done = xdg_output_handle_done,
    .name = xdg_output_handle_name,
    .description = xdg_output_handle_description,
};

static const struct wp_presentation_listener presentation_listener = {
    .clock_id = &clock_id,
};

static const struct wp_color_manager_v1_listener color_manager_listener = {
    .supported_intent = &color_manager_supported_intent,
    .supported_feature = &color_manager_supported_feature,
    .supported_primaries_named = &color_manager_supported_primaries_named,
    .supported_tf_named = &color_manager_supported_tf_named,
    .done = &color_manager_done,
};

static const struct wl_surface_listener surface_listener = {
    .enter = &surface_enter,
    .leave = &surface_leave,
#if defined(WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION)
    .preferred_buffer_scale = &surface_preferred_buffer_scale,
    .preferred_buffer_transform = &surface_preferred_buffer_transform,
#endif
};

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
    .configure = &xdg_toplevel_configure,
    /*.close = */&xdg_toplevel_close,  /* epoll-shim defines a macro 'close'... */
#if defined(XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION)
    .configure_bounds = &xdg_toplevel_configure_bounds,
#endif
#if defined(XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION)
    .wm_capabilities = xdg_toplevel_wm_capabilities,
#endif
};

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = &xdg_surface_configure,
};

static const struct zxdg_toplevel_decoration_v1_listener xdg_toplevel_decoration_listener = {
    .configure = &xdg_toplevel_decoration_configure,
};

#if defined(HAVE_EXT_BACKGROUND_EFFECT)
static const struct ext_background_effect_manager_v1_listener background_manager_listener = {
    .capabilities = &ext_background_capabilities,
};
#endif  /* HAVE_EXT_BACKGROUND_EFFECT */

static const struct wl_registry_listener registry_listener = {
    .global = &handle_global,
    .global_remove = &handle_global_remove,
};

void wayland_shim_add_registry_listener(
    struct wl_registry *registry, struct wayland *wayl)
{
    wl_registry_add_listener(registry, &registry_listener, wayl);
}

void wayland_shim_add_shm_listener(struct wl_shm *shm, struct wayland *wayl)
{
    wl_shm_add_listener(shm, &shm_listener, wayl);
}

void wayland_shim_add_wm_base_listener(
    struct xdg_wm_base *shell, struct wayland *wayl)
{
    xdg_wm_base_add_listener(shell, &xdg_wm_base_listener, wayl);
}

void wayland_shim_add_seat_listener(struct wl_seat *wl_seat, struct seat *seat)
{
    wl_seat_add_listener(wl_seat, &seat_listener, seat);
}

void wayland_shim_keyboard_leave(
    struct seat *seat, struct wl_keyboard *kbd, struct wl_surface *surface)
{
    keyboard_listener.leave(seat, kbd, -1, surface);
}

void wayland_shim_pointer_leave(
    struct seat *seat, struct wl_pointer *pointer, struct wl_surface *surface)
{
    pointer_listener.leave(seat, pointer, -1, surface);
}

void wayland_shim_add_output_listener(
    struct wl_output *output, struct monitor *mon)
{
    wl_output_add_listener(output, &output_listener, mon);
}

void wayland_shim_add_xdg_output_monitor_listener(
    struct zxdg_output_v1 *xdg, struct monitor *mon)
{
    zxdg_output_v1_add_listener(xdg, &xdg_output_listener, mon);
}

void wayland_shim_add_presentation_listener(
    struct wp_presentation *presentation, struct wayland *wayl)
{
    wp_presentation_add_listener(presentation, &presentation_listener, wayl);
}

void wayland_shim_add_color_manager_listener(
    struct wp_color_manager_v1 *manager, struct wayland *wayl)
{
    wp_color_manager_v1_add_listener(manager, &color_manager_listener, wayl);
}

void wayland_shim_add_background_manager_listener(
    struct ext_background_effect_manager_v1 *manager, struct wayland *wayl)
{
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    ext_background_effect_manager_v1_add_listener(
        manager, &background_manager_listener, wayl);
#else
    (void)manager;
    (void)wayl;
#endif
}

static const struct wp_fractional_scale_v1_listener fractional_scale_listener = {
    .preferred_scale = &fractional_scale_preferred_scale,
};

void wayland_shim_add_surface_listener(
    struct wl_surface *surf, struct wl_window *win)
{
    wl_surface_add_listener(surf, &surface_listener, win);
}

void wayland_shim_add_fractional_scale_listener(
    struct wp_fractional_scale_v1 *scale, struct wl_window *win)
{
    wp_fractional_scale_v1_add_listener(scale, &fractional_scale_listener, win);
}

void wayland_shim_add_xdg_surface_listener(
    struct xdg_surface *xdg_surface, struct wl_window *win)
{
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, win);
}

void wayland_shim_add_xdg_toplevel_listener(
    struct xdg_toplevel *toplevel, struct wl_window *win)
{
    xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener, win);
}

void wayland_shim_add_decoration_listener(
    struct zxdg_toplevel_decoration_v1 *decoration, struct wl_window *win)
{
    zxdg_toplevel_decoration_v1_add_listener(
        decoration, &xdg_toplevel_decoration_listener, win);
}

static const struct xdg_activation_token_v1_listener activation_token_listener = {
    .done = &activation_token_v1_done,
};

void wayland_shim_add_activation_token_listener(
    struct xdg_activation_token_v1 *token,
    struct xdg_activation_token_context *ctx)
{
    xdg_activation_token_v1_add_listener(
        token, &activation_token_listener, ctx);
}
