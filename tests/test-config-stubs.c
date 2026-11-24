/*
 * Stand-ins for two helpers that config.zig calls but that live outside the
 * config parser (user-notification.zig and terminal-shim.c). The config tests
 * link only the parser, so they provide these instead of the whole footlib.
 */

#include "../config.h"
#include "../user-notification.h"

#include <fcft/fcft.h>

void user_notification_add_owned(
    user_notifications_t *notifications, int kind, char *text)
{
    user_notification_add(notifications, (enum user_notification_kind)kind, text);
}

int
terminal_shim_fcft_glyph_advance_x(const struct fcft_glyph *glyph)
{
    return glyph->advance.x;
}

const char *
terminal_shim_fcft_font_name(const struct fcft_font *font)
{
    return font->name;
}
