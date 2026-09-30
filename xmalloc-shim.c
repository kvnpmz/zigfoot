#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

extern char *xvasprintf(const char *format, void *ap);

char *xasprintf(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    char *ret = xvasprintf(format, ap);
    va_end(ap);
    return ret;
}
