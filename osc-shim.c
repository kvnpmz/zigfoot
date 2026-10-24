#include <stddef.h>
#include "terminal.h"

char **osc_term_cwd_ptr(struct terminal *term) {
    return &term->cwd;
}
