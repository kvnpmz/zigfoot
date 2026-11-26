#include <regex.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

int config_regex_compile_zig(
    const char *regex, void *preg, char *err_buf, size_t err_buf_len);

static int failures;

static void
check(int ok, const char *what)
{
    if (ok) {
        printf("ok: %s\n", what);
    } else {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void
case_group(void)
{
    regex_t re;
    regmatch_t matches[3];
    char err[128] = {0};

    memset(&re, 0xaa, sizeof(re));
    int r = config_regex_compile_zig("^(a)(b)$", &re, err, sizeof(err));
    check(r == 0, "^(a)(b)$ compiles");
    check(re.re_nsub >= 1, "grouped pattern has at least one subexpression");
    check(regexec(&re, "ab", 3, matches, 0) == 0, "regexec finds ab");
    check(matches[1].rm_so == 0 && matches[1].rm_eo == 1,
          "the first subexpression is a");
    regfree(&re);
}

static void
case_no_group(void)
{
    regex_t re;
    char err[128] = {0};

    memset(&re, 0xaa, sizeof(re));
    int r = config_regex_compile_zig("^abc$", &re, err, sizeof(err));
    check(r == -2, "ungrouped pattern returns -2");
    /* The implementation already called regfree(). Do not call it again. */
}

static void
case_invalid(void)
{
    regex_t re;
    char err[128] = {0};

    memset(&re, 0xaa, sizeof(re));
    int r = config_regex_compile_zig("[", &re, err, sizeof(err));
    check(r == -1, "invalid pattern returns -1");
    check(err[0] != '\0', "invalid pattern produces an error string");
}

static void
case_truncated_error(void)
{
    regex_t re;
    char err[8];

    memset(err, 0xaa, sizeof(err));
    memset(&re, 0xaa, sizeof(re));
    int r = config_regex_compile_zig("[", &re, err, sizeof(err));
    check(r == -1, "invalid pattern with a short error buffer returns -1");
    check(memchr(err, '\0', sizeof(err)) != NULL,
          "short error buffer is NUL-terminated");
}

static void
case_two_compiles(void)
{
    regex_t re;
    char err[128] = {0};

    memset(&re, 0xaa, sizeof(re));
    check(config_regex_compile_zig("^(x)$", &re, err, sizeof(err)) == 0,
          "first of two compiles succeeds");
    regfree(&re);

    memset(&re, 0xaa, sizeof(re));
    check(config_regex_compile_zig("^(y)$", &re, err, sizeof(err)) == 0,
          "second of two compiles succeeds");
    regfree(&re);
}

int
main(void)
{
    case_group();
    case_no_group();
    case_invalid();
    case_truncated_error();
    case_two_compiles();

    if (failures != 0) {
        printf("%d regex check(s) failed\n", failures);
        return 1;
    }
    return 0;
}

