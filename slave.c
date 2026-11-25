#include "slave.h"

/* Zig 0.16 has no execvpeZ(). Keep the configure-time glibc call and the
 * portable PATH-search fallback here. The fallback must use the caller's
 * envp, so std.posix.execvpeZ()/execvp() is not a substitute. */

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "xmalloc.h"

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
#endif

int slave_shim_execvpe(
    const char *file, char *const argv[], char *const envp[])
{
#if defined(EXECVPE)
    return execvpe(file, argv, envp);
#else
    char *path = find_file_in_path(file);
    int ret = execve(path, argv, envp);
    free(path);
    return ret;
#endif
}
