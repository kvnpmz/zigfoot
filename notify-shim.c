#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "notify.h"
#include "terminal.h"
#include "util.h"
#include "xmalloc.h"

char *notify_xstrjoin(const char *a, const char *b) {
    return xstrjoin(a, b);
}
