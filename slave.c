#include "slave.h"

/*
 * slave.c: the spawn/exec logic is ported to slave.zig. What remains here is
 * the platform glue that Zig cannot express portably or without duplicating
 * configure-time knowledge:
 *
 *  - restoring the signal mask and SIG_DFL handlers (sigset_t/sigaction),
 *  - the configured terminfo path (a compile-time define),
 *  - execvpe() (EXECVPE is a configure-time feature, and the non-glibc
 *    fallback has to call execve() on the resolved path).
 *
 * The open/fcntl/ioctl/confstr constants and the IUTF8 adjustment are Zig
 * now (slave.zig, E1a).
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
