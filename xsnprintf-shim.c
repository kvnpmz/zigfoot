/* Zig shim for the xsnprintf port.
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

#include <stddef.h>
#include <stdarg.h>

extern size_t xvsnprintf(char *restrict str, size_t size, const char *restrict format, va_list ap);

size_t xsnprintf(char *restrict str, size_t size, const char *restrict format, ...) {
    va_list ap;
    va_start(ap, format);
    size_t rc = xvsnprintf(str, size, format, ap);
    va_end(ap);
    return rc;
}
