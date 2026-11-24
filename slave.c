#include "slave.h"

/*
 * slave.c: the spawn/exec logic is ported to slave.zig. What remains here is
 * the platform glue that Zig cannot express portably or without duplicating
 * configure-time knowledge:
 *
 *  - the numeric open/fcntl/ioctl/confstr constants (O_*, F_*, TIOCSCTTY,
 *    _CS_PATH), which differ per platform and are macros in C,
 *  - the IUTF8 termios adjustment (struct termios layout),
 *  - restoring the signal mask and SIG_DFL handlers (sigset_t/sigaction),
 *  - execvpe() (EXECVPE is a configure-time feature, and the non-glibc
 *    fallback has to call execve() on the resolved path).
 */

#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include <sys/ioctl.h>

#include "debug.h"
#include "macros.h"
#include "util.h"

struct slave_constants {
    int o_rdwr;
    int o_cloexec;
    int o_nonblock;
    int f_getfl;
    int f_setfl;
    int f_getfd;
    int f_setfd;
    int fd_cloexec;
    int f_ok;
    int stdin_fileno;
    int stdout_fileno;
    int stderr_fileno;
    int cs_path;
    unsigned long tiocsctty;
};

static const struct slave_constants constants = {
    .o_rdwr = O_RDWR,
    .o_cloexec = O_CLOEXEC,
    .o_nonblock = O_NONBLOCK,
    .f_getfl = F_GETFL,
    .f_setfl = F_SETFL,
    .f_getfd = F_GETFD,
    .f_setfd = F_SETFD,
    .fd_cloexec = FD_CLOEXEC,
    .f_ok = F_OK,
    .stdin_fileno = STDIN_FILENO,
    .stdout_fileno = STDOUT_FILENO,
    .stderr_fileno = STDERR_FILENO,
    .cs_path = _CS_PATH,
    .tiocsctty = TIOCSCTTY,
};

const struct slave_constants *slave_shim_constants(void) {
    return &constants;
}

int slave_shim_set_iutf8(int pts) {
#ifdef IUTF8
    struct termios flags;
    if (tcgetattr(pts, &flags) < 0)
        return 1;

    flags.c_iflag |= IUTF8;
    if (tcsetattr(pts, TCSANOW, &flags) < 0)
        return 2;
#else
    (void)pts;
#endif
    return 0;
}

const char *slave_shim_terminfo_path(void) {
#if defined(FOOT_TERMINFO_PATH)
    return FOOT_TERMINFO_PATH;
#else
    return NULL;
#endif
}

bool slave_shim_reset_signals(void) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);

    sigset_t mask;
    sigemptyset(&mask);

    return !(sigprocmask(SIG_SETMASK, &mask, NULL) < 0 ||
             sigaction(SIGHUP, &dfl, NULL) < 0 ||
             sigaction(SIGPIPE, &dfl, NULL) < 0);
}

#if !defined(EXECVPE)
static char *
find_file_in_path(const char *file)
{
    if (strchr(file, '/') != NULL)
        return xstrdup(file);

    const char *env_path = getenv("PATH");
    char *path_list = NULL;

    if (env_path != NULL && env_path[0] != '\0')
        path_list = xstrdup(env_path);
    else {
        size_t sc_path_len = confstr(_CS_PATH, NULL, 0);
        if (sc_path_len > 0) {
            path_list = xmalloc(sc_path_len);
            confstr(_CS_PATH, path_list, sc_path_len);
        } else
            return xstrdup(file);
    }

    for (const char *path = strtok(path_list, ":");
         path != NULL;
         path = strtok(NULL, ":"))
    {
        char *full = xstrjoin3(path, "/", file);
        if (access(full, F_OK) == 0) {
            free(path_list);
            return full;
        }

        free(full);
    }

    free(path_list);
    return xstrdup(file);
}
#endif /* !EXECVPE */

int slave_shim_execvpe(
    const char *file, char *const argv[], char *const envp[])
{
#if defined(EXECVPE)
    return execvpe(file, argv, envp);
#else
    char *path = find_file_in_path(file);
    int ret = execve(path, argv, envp);

    /*
     * Getting here is an error
     */
    free(path);
    return ret;
#endif
}
