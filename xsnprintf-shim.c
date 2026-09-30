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
