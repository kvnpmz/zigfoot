/*
 * Regression tests for the hand-written shims that every session depends on.
 *
 * Everything here is plain C and headless: no wayland connection, no pty and
 * no config file. The shim bodies and Zig exports are linked straight out of
 * libfootlib (the same way test-terminal.c and test-regex.c link it), so these
 * checks cover the real memfd/fallocate/seal paths and the real regexec() span
 * copy (now in url-mode.zig).
 *
 * The URL regex is required to have a marked subexpression, but the shim is
 * also checked with an ungrouped pattern: it must report an empty group 1
 * rather than read past its single regmatch_t allocation.
 */

#include "shm.h"

#include <regex.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#if defined(__linux__) && defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ == 8
 #include <linux/falloc.h>
#endif

/* Not declared in a public header: shm.zig calls these via extern, and the
 * shim definitions are the authoritative signatures. */
int shm_shim_create_backing_file(void);
bool shm_shim_probe_punch_hole(int fd);
void *shm_shim_mmap_pool(int fd, size_t size);
void shm_shim_seal_pool(int fd);

/* url-mode.zig exports this with an opaque regex_t pointer; C's regex_t *
 * is ABI-identical, so the declaration here stays valid. */
bool url_shim_regex_match(
    const regex_t *preg, const char *str,
    size_t *so0, size_t *eo0, size_t *so1, size_t *eo1);

static int failures;

#define check(cond, what)                                               \
    do {                                                                \
        if (cond) {                                                     \
            printf("ok: %s\n", (what));                                 \
        } else {                                                        \
            fprintf(stderr, "FAIL: %s\n", (what));                      \
            failures++;                                                 \
        }                                                               \
    } while (0)

#define BUFLEN 16
static const char payload[BUFLEN] = "0123456789abcdef";

static void
case_backing_file(void)
{
    int fd = shm_shim_create_backing_file();
    check(fd >= 0, "backing file: create returns a valid fd");
    if (fd < 0)
        return;

    struct stat st;
    check(fstat(fd, &st) == 0 && st.st_size == 0,
          "backing file: freshly created file is empty");

    int seals = fcntl(fd, F_GET_SEALS);
    if (seals < 0 && errno == EINVAL) {
        /* mkostemp() fallback (or a non-sealable fs): nothing to pin. */
        printf("ok: (skipped)\n");
    } else {
        check(seals >= 0 && !(seals & F_SEAL_SEAL),
              "backing file: fresh fd is not born sealed");
    }

    check(write(fd, payload, BUFLEN) == BUFLEN,
          "backing file: fd is writable");
    char buf[BUFLEN] = {0};
    check(lseek(fd, 0, SEEK_SET) == 0 && read(fd, buf, sizeof(buf)) == BUFLEN &&
          memcmp(buf, payload, BUFLEN) == 0,
          "backing file: written bytes read back unchanged");
    check(close(fd) == 0, "backing file: fd closes cleanly");
}

static void
case_punch_hole(void)
{
    int fd = shm_shim_create_backing_file();
    check(fd >= 0, "punch hole: probe gets a real fd");
    if (fd < 0)
        return;

    bool first = shm_shim_probe_punch_hole(fd);
    bool second = shm_shim_probe_punch_hole(fd);
    check(first == second, "punch hole: probe is deterministic across calls");

#if defined(FALLOC_FL_PUNCH_HOLE) && \
    defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ == 8
    char name[] = "/tmp/foot-shims-punch-XXXXXX";
    int tmp = mkstemp(name);
    check(tmp >= 0, "punch hole: independent tmpfile created");
    if (tmp >= 0) {
        unlink(name);
        check(write(tmp, payload, BUFLEN) == BUFLEN,
              "punch hole: independent tmpfile has data");
        bool independent = fallocate(
            tmp, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, 0, 1) == 0;
        check(first == independent,
              "punch hole: probe matches a direct fallocate() attempt");
        close(tmp);
    }
#else
    check(!first, "punch hole: unsupported platforms report false");
#endif

    check(!shm_shim_probe_punch_hole(-1),
          "punch hole: bad fd returns false without crashing");
    close(fd);
}

static void
case_seal_pool(void)
{
    int fd = shm_shim_create_backing_file();
    check(fd >= 0, "seal: create returns a valid fd");
    if (fd < 0)
        return;

    /* F_SEAL_GROW forbids extending a sealed file, so give it a size first. */
    check(write(fd, payload, BUFLEN) == BUFLEN,
          "seal: fd has a non-zero size before sealing");

    shm_shim_seal_pool(fd);

    int seals = fcntl(fd, F_GET_SEALS);
    if (seals < 0 && errno == EINVAL) {
        printf("ok: (skipped)\n");
    } else {
        check(seals >= 0 && (seals & F_SEAL_SEAL),
              "seal: F_GET_SEALS reports F_SEAL_SEAL after sealing");
        check((seals & F_SEAL_SHRINK) && (seals & F_SEAL_GROW),
              "seal: shrink and grow are sealed too");
    }

    check(pwrite(fd, "Z", 1, 0) == 1,
          "seal: in-bounds writes still succeed after sealing");
    char first_byte = 0;
    check(pread(fd, &first_byte, 1, 0) == 1 && first_byte == 'Z',
          "seal: post-seal write is visible");

    shm_shim_seal_pool(fd);
    check(fcntl(fd, F_GET_SEALS) == seals,
          "seal: sealing an already-sealed fd does not abort");
    check(close(fd) == 0, "seal: fd closes cleanly");
}

static void
case_url_regex(void)
{
    /* The match sits in the middle: group 0 and group 1 spans are relative
     * to the string passed to the shim, not to a copy of the regex. */
    const char *hay = "see https://example.com now";
    regex_t re;
    size_t so0 = 123, eo0 = 123, so1 = 123, eo1 = 123;

    check(regcomp(&re, "https?://([a-z]+)\\.[a-z]+", REG_EXTENDED) == 0,
          "URL regex: capture pattern compiles");
    check(re.re_nsub == 1, "URL regex: one subexpression");

    check(url_shim_regex_match(&re, hay, &so0, &eo0, &so1, &eo1),
          "URL regex: mid-string match found");
    check(so0 == 4 && eo0 == 23 && eo0 - so0 == strlen("https://example.com"),
          "URL regex: group 0 offsets copied");
    check(eo0 - so0 == strlen("https://example.com") &&
          strncmp(hay + so0, "https://example.com", eo0 - so0) == 0,
          "URL regex: group 0 text is the whole URL");
    check(so1 == 12 && eo1 == 19 && eo1 - so1 == strlen("example"),
          "URL regex: group 1 offsets copied");
    check(strncmp(hay + so1, "example", eo1 - so1) == 0,
          "URL regex: group 1 text is the host label");
    regfree(&re);

    /* No match: the shim returns false and leaves the caller's spans alone. */
    check(regcomp(&re, "https?://([a-z]+)\\.[a-z]+", REG_EXTENDED) == 0,
          "URL regex: pattern recompiles for the no-match case");
    so0 = 111; eo0 = 222; so1 = 333; eo1 = 444;
    check(!url_shim_regex_match(&re, "nothing here", &so0, &eo0, &so1, &eo1),
          "URL regex: non-matching string returns no match");
    check(so0 == 111 && eo0 == 222 && so1 == 333 && eo1 == 444,
          "URL regex: no match leaves the output spans untouched");
    regfree(&re);

    /* No capture group: re_nsub == 0, so the shim allocates one regmatch_t.
     * It must report an empty group 1 rather than read matches[1]. */
    regex_t plain;
    so0 = 7; eo0 = 7; so1 = 7; eo1 = 7;
    check(regcomp(&plain, "example\\.com", REG_EXTENDED) == 0,
          "URL regex: ungrouped pattern compiles");
    check(plain.re_nsub == 0, "URL regex: ungrouped pattern has no subexpressions");
    bool plain_matched = url_shim_regex_match(
        &plain, hay, &so0, &eo0, &so1, &eo1);
    check(plain_matched, "URL regex: ungrouped pattern still matches");
    check(so0 == 12 && eo0 == 23,
          "URL regex: group 0 is correct without a capture group");
    check(so1 == 0 && eo1 == 0,
          "URL regex: absent group 1 is reported as an empty span");
    regfree(&plain);
}

static void
case_null_guards(void)
{
    int marker = 42;
    struct wl_shm_pool *pool = shm_shim_wl_shm_create_pool(NULL, -1, 4096);
    check(pool != NULL, "NULL guards: headless pool creation returns a sentinel");

    struct wl_buffer *buf = shm_shim_wl_shm_pool_create_buffer(
        pool, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
    check(buf != NULL, "NULL guards: headless buffer creation returns a sentinel");

    shm_shim_wl_buffer_add_listener(buf, &marker);
    shm_shim_wl_buffer_destroy(buf);
    shm_shim_wl_shm_pool_destroy(pool);
    check(marker == 42, "NULL guards: sentinel listener/destroy forwarders no-op");

    check(shm_shim_mmap_pool(-1, 4096) == MAP_FAILED,
          "NULL guards: bad mmap fd returns MAP_FAILED without crashing");
}

int
main(void)
{
    case_backing_file();
    case_punch_hole();
    case_seal_pool();
    case_url_regex();
    case_null_guards();

    if (failures != 0) {
        printf("%d shim check(s) failed\n", failures);
        return 1;
    }
    printf("all shim checks passed\n");
    return 0;
}
