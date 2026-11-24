const std = @import("std");
const types = @import("terminal_types.zig");

//
// user-notification.c ported to Zig: the printf-style variant of
// user_notification_add(), plus the ownership-taking helper config.zig's
// loggers need. The non-variadic helpers stay as static inlines in
// user-notification.h (C callers use them directly).
//

extern fn vasprintf(strp: *?[*:0]u8, fmt: [*:0]const u8, ap: *std.builtin.VaList) c_int;

fn mallocOrAbort(size: usize) *anyopaque {
    return std.c.malloc(size) orelse @panic("out of memory");
}

/// Append a notification whose text is already heap allocated; ownership of
/// `text` is transferred to the list (mirrors user_notification_add()).
export fn user_notification_add_owned(
    notifications: *types.UserNotifications,
    kind: c_int,
    text: [*:0]u8,
) callconv(.c) void {
    const node: *types.UserNotificationNode = @ptrCast(@alignCast(
        mallocOrAbort(@sizeOf(types.UserNotificationNode))));

    const tail: ?*types.UserNotificationNode = if (notifications.tail) |t|
        @ptrCast(@alignCast(t))
    else
        null;

    node.* = .{
        .item = .{ .kind = @enumFromInt(kind), .text = text },
        .prev = tail,
        .next = null,
    };

    if (tail) |t| t.next = node else notifications.head = node;
    notifications.tail = node;
    notifications.length += 1;
}

export fn user_notification_add_fmt(
    notifications: *types.UserNotifications,
    kind: c_int,
    fmt: [*:0]const u8,
    ...
) callconv(.c) void {
    var va = @cVaStart();
    var text: ?[*:0]u8 = null;
    const n = vasprintf(&text, fmt, &va);
    @cVaEnd(&va);

    // xvasprintf() aborts on OOM
    if (n < 0 or text == null)
        std.c.abort();

    user_notification_add_owned(notifications, kind, text.?);
}
