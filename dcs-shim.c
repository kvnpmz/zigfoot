/* Zig shim for the dcs port.
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
#include <stddef.h>
#include "terminal.h"
#include "foot-terminfo.h"

/* foot-terminfo.h declares `static const char terminfo_capabilities[]` —
 * each TU that includes it gets its own copy. dcs.zig can't `extern` a
 * static, so we provide accessors here. */
const char *dcs_terminfo_capabilities(void) {
    return terminfo_capabilities;
}

size_t dcs_terminfo_capabilities_size(void) {
    return sizeof(terminfo_capabilities);
}

