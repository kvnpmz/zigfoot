#include "config.h"

/*
 * config.c: the parser is config.zig (the value-parsing helpers, the
 * [section] parsers, config_load()/clone()/free(), the bindings and the
 * collision resolution). What is left here is the one piece Zig cannot
 * meaningfully do: regex_t. glibc and musl disagree on its layout, so Zig
 * keeps it opaque and this file compiles/validates it.
 */

#include <stddef.h>
#include <regex.h>

#include "macros.h"

/* Compile + validate a regex for config.zig. Returns 0 on success, -1 on
 * regcomp() failure (err_buf holds regerror() text), -2 when the pattern
 * has no marked subexpressions (the regex is already freed). */
int
config_regex_compile(const char *regex, regex_t *preg,
                     char *err_buf, size_t err_buf_len)
{
    int r = regcomp(preg, regex, REG_EXTENDED);
    if (r != 0) {
        regerror(r, preg, err_buf, err_buf_len);
        return -1;
    }

    if (preg->re_nsub == 0) {
        regfree(preg);
        return -2;
    }

    return 0;
}
