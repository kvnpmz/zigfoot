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

/* Terminal.conf is opaque to Zig until config.h is ported. */
bool dcs_tweak_sixel_enabled(const struct terminal *term) {
    return term->conf->tweak.sixel;
}
