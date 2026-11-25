#include "wayland.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/timerfd.h>
#include <sys/epoll.h>

#include <cursor-shape-v1.h>
#include <wayland-client.h>
#include <wayland-cursor.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <xkbcommon/xkbcommon-compose.h>

#include <tllist.h>

#define LOG_MODULE "wayland"
#define LOG_ENABLE_DBG 0
#include "log.h"

#include "config.h"
#include "terminal.h"
#include "ime.h"
#include "input.h"
#include "render.h"
#include "selection.h"
#include "shm.h"
#include "shm-formats.h"
#include "util.h"
#include "xmalloc.h"

/* wayland.zig: the data-device / primary-selection / text-input listener
 * tables are defined in selection.c and ime.c, so seat setup attaches them
 * through these. */
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

void wayland_shim_add_text_input_listener(
    struct zwp_text_input_v3 *ti, struct seat *seat)
{
    zwp_text_input_v3_add_listener(ti, &text_input_listener, seat);
}

static const struct wl_shm_listener shm_listener = {
    .format = &shm_format,
};

static void
xdg_wm_base_ping(void *data, struct xdg_wm_base *shell, uint32_t serial)
{
    LOG_DBG("wm base ping");
    xdg_wm_base_pong(shell, serial);
}

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

static void
color_manager_create_image_description(struct wayland *wayl)
{
    if (!wayl->color_management.have_feat_parametric)
        return;

    if (!wayl->color_management.have_primaries_srgb)
        return;

    if (!wayl->color_management.have_tf_ext_linear)
        return;

    struct wp_image_description_creator_params_v1 *params =
        wp_color_manager_v1_create_parametric_creator(wayl->color_management.manager);

    wp_image_description_creator_params_v1_set_tf_named(
        params, WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR);

    wp_image_description_creator_params_v1_set_primaries_named(
        params, WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);

    wayl->color_management.img_description =
        wp_image_description_creator_params_v1_create(params);
}

static void
color_manager_supported_intent(void *data,
                               struct wp_color_manager_v1 *wp_color_manager_v1,
                               uint32_t render_intent)
{
    struct wayland *wayl = data;
    if (render_intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL)
        wayl->color_management.have_intent_perceptual = true;
}

static void
color_manager_supported_feature(void *data,
                                struct wp_color_manager_v1 *wp_color_manager_v1,
                                uint32_t feature)
{
    struct wayland *wayl = data;

    if (feature == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC)
        wayl->color_management.have_feat_parametric = true;
}

static void
color_manager_supported_tf_named(void *data,
                                 struct wp_color_manager_v1 *wp_color_manager_v1,
                                 uint32_t tf)
{
    struct wayland *wayl = data;
    if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_EXT_LINEAR)
        wayl->color_management.have_tf_ext_linear = true;
}

static void
color_manager_supported_primaries_named(void *data,
                                        struct wp_color_manager_v1 *wp_color_manager_v1,
                                        uint32_t primaries)
{
    struct wayland *wayl = data;
    if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB)
        wayl->color_management.have_primaries_srgb = true;
}

static void
color_manager_done(void *data,
                   struct wp_color_manager_v1 *wp_color_manager_v1)
{
    struct wayland *wayl = data;
    color_manager_create_image_description(wayl);
}

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

static bool
fdm_repeat(struct fdm *fdm, int fd, int events, void *data)
{
    if (events & EPOLLHUP)
        return false;

    struct seat *seat = data;
    uint64_t expiration_count;
    ssize_t ret = read(
        seat->kbd.repeat.fd, &expiration_count, sizeof(expiration_count));

    if (ret < 0) {
        if (errno == EAGAIN)
            return true;

        LOG_ERRNO("failed to read repeat key from repeat timer fd");
        return false;
    }

    seat->kbd.repeat.dont_re_repeat = true;
    for (size_t i = 0; i < expiration_count; i++)
        input_repeat(seat, seat->kbd.repeat.key);
    seat->kbd.repeat.dont_re_repeat = false;
    return true;
}

static void
handle_global(void *data, struct wl_registry *registry,
              uint32_t name, const char *interface, uint32_t version)
{
    LOG_DBG("global: 0x%08x, interface=%s, version=%u", name, interface, version);
    struct wayland *wayl = data;

    if (streq(interface, wl_compositor_interface.name)) {
        const uint32_t required = 4;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined (WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION)
        const uint32_t preferred = WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif
        wayl->compositor = wl_registry_bind(
            wayl->registry, name, &wl_compositor_interface, min(version, preferred));
    }

    else if (streq(interface, wl_subcompositor_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->sub_compositor = wl_registry_bind(
            wayl->registry, name, &wl_subcompositor_interface, required);
    }

    else if (streq(interface, wl_shm_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined(WL_SHM_RELEASE_SINCE_VERSION)
        const uint32_t preferred = WL_SHM_RELEASE_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        wayl->shm = wl_registry_bind(
            wayl->registry, name, &wl_shm_interface, min(version, preferred));
        wl_shm_add_listener(wayl->shm, &shm_listener, wayl);
#if defined(WL_SHM_RELEASE_SINCE_VERSION)
        wayl->use_shm_release = version >= WL_SHM_RELEASE_SINCE_VERSION;
#else
        wayl->use_shm_release = false;
#endif
    }

    else if (streq(interface, xdg_wm_base_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        /*
         * We *require* version 1, but _can_ use version 2, 5 or 7, if
         * available.
         *
         * Version 2 adds 'tiled' window states. We use this
         * information to restore the window size when window is
         * un-tiled.
         *
         * Version 5 adds 'wm_capabilities'. We use this information
         * to draw window decorations.
         *
         * Version 7 adds 'constrained' window states. We use this
         * information to determine whether to allow window resize
         * (via CSDs) or not.
         */
#if defined(XDG_TOPLEVEL_STATE_CONSTRAINED_LEFT_SINCE_VERSION)
        const uint32_t preferred = XDG_TOPLEVEL_STATE_CONSTRAINED_LEFT_SINCE_VERSION;
#elif defined(XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION)
        const uint32_t preferred = XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION;
#elif defined(XDG_TOPLEVEL_STATE_TILED_LEFT_SINCE_VERSION)
        const uint32_t preferred = XDG_TOPLEVEL_STATE_TILED_LEFT_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        wayl->shell = wl_registry_bind(
            wayl->registry, name, &xdg_wm_base_interface, min(version, preferred));
        xdg_wm_base_add_listener(wayl->shell, &xdg_wm_base_listener, wayl);
    }

    else if (streq(interface, zxdg_decoration_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->xdg_decoration_manager = wl_registry_bind(
            wayl->registry, name, &zxdg_decoration_manager_v1_interface, required);
    }

    else if (streq(interface, wl_seat_interface.name)) {
        const uint32_t required = 5;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined(WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
        const uint32_t preferred = WL_POINTER_AXIS_VALUE120_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        int repeat_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        if (repeat_fd == -1) {
            LOG_ERRNO("failed to create keyboard repeat timer FD");
            return;
        }

        struct wl_seat *wl_seat = wl_registry_bind(
            wayl->registry, name, &wl_seat_interface, min(version, preferred));

        tll_push_back(wayl->seats, ((struct seat){
                    .wayl = wayl,
                    .wl_seat = wl_seat,
                    .wl_name = name,
                    .kbd = {
                        .repeat = {
                            .fd = repeat_fd,
                        },
                    }}));

        struct seat *seat = &tll_back(wayl->seats);

        if (!fdm_add(wayl->fdm, repeat_fd, EPOLLIN, &fdm_repeat, seat)) {
            close(repeat_fd);
            seat->kbd.repeat.fd = -1;
            seat_destroy(seat);
            return;
        }

        seat->kbd.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        if (seat->kbd.xkb != NULL) {
            seat->kbd.xkb_compose_table = xkb_compose_table_new_from_locale(
                seat->kbd.xkb, setlocale(LC_CTYPE, NULL), XKB_COMPOSE_COMPILE_NO_FLAGS);

            if (seat->kbd.xkb_compose_table != NULL) {
                seat->kbd.xkb_compose_state = xkb_compose_state_new(
                    seat->kbd.xkb_compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
            } else {
                LOG_WARN("failed to instantiate compose table; dead keys (compose) will not work");
            }
        }

        seat_add_data_device(seat);
        seat_add_primary_selection(seat);
        seat_add_text_input(seat);
        seat_add_key_bindings(seat);
        wl_seat_add_listener(wl_seat, &seat_listener, seat);
    }

    else if (streq(interface, zxdg_output_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->xdg_output_manager = wl_registry_bind(
            wayl->registry, name, &zxdg_output_manager_v1_interface,
            min(version, 2));

        tll_foreach(wayl->monitors, it) {
            struct monitor *mon = &it->item;
            mon->xdg = zxdg_output_manager_v1_get_xdg_output(
                wayl->xdg_output_manager, mon->output);
            zxdg_output_v1_add_listener(mon->xdg, &xdg_output_listener, mon);
        }
    }

    else if (streq(interface, wl_output_interface.name)) {
        const uint32_t required = 2;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined(WL_OUTPUT_NAME_SINCE_VERSION)
        const uint32_t preferred = WL_OUTPUT_NAME_SINCE_VERSION;
#elif defined(WL_OUTPUT_RELEASE_SINCE_VERSION)
        const uint32_t preferred = WL_OUTPUT_RELEASE_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        struct wl_output *output = wl_registry_bind(
            wayl->registry, name, &wl_output_interface, min(version, preferred));

        tll_push_back(
            wayl->monitors,
            ((struct monitor){.wayl = wayl, .output = output, .wl_name = name,
             .scale = 1,
             .use_output_release = version >= WL_OUTPUT_RELEASE_SINCE_VERSION}));

        struct monitor *mon = &tll_back(wayl->monitors);
        wl_output_add_listener(output, &output_listener, mon);

        if (wayl->xdg_output_manager != NULL) {
            mon->xdg = zxdg_output_manager_v1_get_xdg_output(
                wayl->xdg_output_manager, mon->output);
            zxdg_output_v1_add_listener(mon->xdg, &xdg_output_listener, mon);
        }
    }

    else if (streq(interface, wl_data_device_manager_interface.name)) {
        const uint32_t required = 3;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->data_device_manager = wl_registry_bind(
            wayl->registry, name, &wl_data_device_manager_interface, required);

        tll_foreach(wayl->seats, it)
            seat_add_data_device(&it->item);
    }

    else if (streq(interface, zwp_primary_selection_device_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->primary_selection_device_manager = wl_registry_bind(
            wayl->registry, name,
            &zwp_primary_selection_device_manager_v1_interface, required);

        tll_foreach(wayl->seats, it)
            seat_add_primary_selection(&it->item);
    }

    else if (streq(interface, wp_presentation_interface.name)) {
        if (wayl->presentation_timings) {
            const uint32_t required = 1;
            if (!verify_iface_version(interface, version, required))
                return;

            wayl->presentation = wl_registry_bind(
                wayl->registry, name, &wp_presentation_interface, required);
            wp_presentation_add_listener(
                wayl->presentation, &presentation_listener, wayl);
        }
    }

    else if (streq(interface, xdg_activation_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->xdg_activation = wl_registry_bind(
            wayl->registry, name, &xdg_activation_v1_interface, required);
    }

    else if (streq(interface, wp_viewporter_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->viewporter = wl_registry_bind(
            wayl->registry, name, &wp_viewporter_interface, required);
    }

    else if (streq(interface, wp_fractional_scale_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->fractional_scale_manager = wl_registry_bind(
            wayl->registry, name,
            &wp_fractional_scale_manager_v1_interface, required);
    }

    else if (streq(interface, wp_cursor_shape_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined(WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DND_ASK_SINCE_VERSION)  /* 1.42 */
        const uint32_t preferred = WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DND_ASK_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        wayl->shape_manager_version = min(version, preferred);
        wayl->cursor_shape_manager = wl_registry_bind(
            wayl->registry, name, &wp_cursor_shape_manager_v1_interface,
            wayl->shape_manager_version);
    }

    else if (streq(interface, wp_single_pixel_buffer_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->single_pixel_manager = wl_registry_bind(
            wayl->registry, name,
            &wp_single_pixel_buffer_manager_v1_interface, required);
    }

    else if (streq(interface, xdg_toplevel_icon_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->toplevel_icon_manager = wl_registry_bind(
            wayl->registry, name, &xdg_toplevel_icon_manager_v1_interface, required);
    }

    else if (streq(interface, xdg_system_bell_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->system_bell = wl_registry_bind(
            wayl->registry, name, &xdg_system_bell_v1_interface, required);
    }

    else if (streq(interface, wp_color_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->color_management.manager = wl_registry_bind(
            wayl->registry, name, &wp_color_manager_v1_interface, required);

        wp_color_manager_v1_add_listener(
            wayl->color_management.manager, &color_manager_listener, wayl);
    }

#if defined(WL_FIXES_INTERFACE)
    else if (streq(interface, wl_fixes_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

#if defined(WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION)
        const uint32_t preferred = WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION;
#else
        const uint32_t preferred = required;
#endif

        wayl->fixes_version = min(version, preferred);
        wayl->fixes = wl_registry_bind(
            wayl->registry, name, &wl_fixes_interface, wayl->fixes_version);
    }
#endif

#if defined(HAVE_XDG_TOPLEVEL_TAG)
    else if (streq(interface, xdg_toplevel_tag_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->toplevel_tag_manager = wl_registry_bind(
            wayl->registry, name, &xdg_toplevel_tag_manager_v1_interface, required);
    }
#endif
#if defined(HAVE_EXT_BACKGROUND_EFFECT)
    else if (streq(interface, ext_background_effect_manager_v1_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->background_effect_manager = wl_registry_bind(
            wayl->registry, name,
            &ext_background_effect_manager_v1_interface, required);

        ext_background_effect_manager_v1_add_listener(
            wayl->background_effect_manager, &background_manager_listener, wayl);
    }
#endif

#if defined(FOOT_IME_ENABLED) && FOOT_IME_ENABLED
    else if (streq(interface, zwp_text_input_manager_v3_interface.name)) {
        const uint32_t required = 1;
        if (!verify_iface_version(interface, version, required))
            return;

        wayl->text_input_manager = wl_registry_bind(
            wayl->registry, name, &zwp_text_input_manager_v3_interface, required);

        tll_foreach(wayl->seats, it)
            seat_add_text_input(&it->item);
    }
#endif

}


static void
handle_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    LOG_DBG("global removed: 0x%08x", name);

    struct wayland *wayl = data;

    /* Check if this is an output */
    tll_foreach(wayl->monitors, it) {
        struct monitor *mon = &it->item;

        if (mon->wl_name != name)
            continue;

        LOG_INFO("monitor unplugged or disabled: %s", mon->name);

        /*
         * Update all terminals that are mapped here. On Sway 1.4,
         * surfaces are *not* unmapped before the output is removed
         */

        tll_foreach(wayl->terms, t) {
            tll_foreach(t->item->window->on_outputs, o) {
                if (o->item->output == mon->output) {
                    surface_leave(t->item->window, NULL, mon->output);
                    break;
                }
            }
        }

        monitor_destroy(mon);
        tll_remove(wayl->monitors, it);
        goto ack_remove;
    }

    /* A seat? */
    tll_foreach(wayl->seats, it) {
        struct seat *seat = &it->item;

        if (seat->wl_name != name)
            continue;

        LOG_INFO("seat destroyed: %s", seat->name);

        if (seat->kbd_focus != NULL) {
            LOG_WARN("compositor destroyed seat '%s' "
                     "without sending a keyboard leave event",
                     seat->name);

            if (seat->wl_keyboard != NULL)
                keyboard_listener.leave(
                    seat, seat->wl_keyboard, -1, seat->kbd_focus->window->surface.surf);
        }

        if (seat->mouse_focus != NULL) {
            LOG_WARN("compositor destroyed seat '%s' "
                     "without sending a pointer leave event",
                     seat->name);

            if (seat->wl_pointer != NULL)
                pointer_listener.leave(
                    seat, seat->wl_pointer, -1, seat->mouse_focus->window->surface.surf);
        }

        seat_destroy(seat);
        tll_remove(wayl->seats, it);
        goto ack_remove;
    }

    LOG_WARN("unknown global removed: 0x%08x", name);

ack_remove:
    ;
#if defined(WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION)
    if (wayl->fixes != NULL &&
        wayl->fixes_version >= WL_FIXES_ACK_GLOBAL_REMOVE_SINCE_VERSION)
    {
        wl_fixes_ack_global_remove(wayl->fixes, wayl->registry, name);
    }
#endif
}

static const struct wl_registry_listener registry_listener = {
    .global = &handle_global,
    .global_remove = &handle_global_remove,
};

static void
fdm_hook(struct fdm *fdm, void *data)
{
    struct wayland *wayl = data;
    wayl_flush(wayl);
}

static bool
fdm_wayl(struct fdm *fdm, int fd, int events, void *data)
{
    struct wayland *wayl = data;
    int event_count = 0;

    if (events & EPOLLIN) {
        if (wl_display_read_events(wayl->display) < 0) {
            LOG_ERRNO("failed to read events from the Wayland socket");
            return false;
        }

        wl_display_dispatch_pending(wayl->display);

        while (wl_display_prepare_read(wayl->display) != 0) {
            if (wl_display_dispatch_pending(wayl->display) < 0) {
                LOG_ERRNO("failed to dispatch pending Wayland events");
                return false;
            }
        }
    }

    if (events & EPOLLHUP) {
        LOG_WARN("disconnected from Wayland");
        /*
         * Do *not* call wl_display_cancel_read() here.
         *
         * Doing so causes later calls to wayl_roundtrip() (called
         * from term_destroy() -> wayl_win_destroy()) to hang
         * indefinitely.
         *
         * https://codeberg.org/dnkl/foot/issues/651
         */
        return false;
    }

    return event_count != -1;
}

/* wayland.zig: fdm_hook, the registry listener and fdm_wayl are still
 * static here, so wayl_init()/wayl_destroy() reach them through these. */
bool wayland_shim_hook_add(struct fdm *fdm, struct wayland *wayl)
{
    return fdm_hook_add(fdm, &fdm_hook, wayl, FDM_HOOK_PRIORITY_LOW);
}

bool wayland_shim_hook_del(struct fdm *fdm)
{
    return fdm_hook_del(fdm, &fdm_hook, FDM_HOOK_PRIORITY_LOW);
}

void wayland_shim_add_registry_listener(
    struct wl_registry *registry, struct wayland *wayl)
{
    wl_registry_add_listener(registry, &registry_listener, wayl);
}

bool wayland_shim_fdm_add(struct fdm *fdm, struct wayland *wayl)
{
    return fdm_add(fdm, wayl->fd, EPOLLIN, &fdm_wayl, wayl);
}

static const struct wp_fractional_scale_v1_listener fractional_scale_listener = {
    .preferred_scale = &fractional_scale_preferred_scale,
};

/* wayland.zig: the listener tables are still static here, so window
 * creation attaches them through these. */
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


static const struct
xdg_activation_token_v1_listener activation_token_listener = {
    .done = &activation_token_v1_done,
};

void wayland_shim_add_activation_token_listener(
    struct xdg_activation_token_v1 *token,
    struct xdg_activation_token_context *ctx)
{
    xdg_activation_token_v1_add_listener(
        token, &activation_token_listener, ctx);
}
