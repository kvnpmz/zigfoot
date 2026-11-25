#pragma once
#include <stdbool.h>

#include <sys/types.h>

#include "config.h"
#include "user-notification.h"

/* slave.c's platform glue. The constants and the IUTF8 adjustment are
 * Zig now (slave.zig); the struct stays here so the harness can check it. */
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

const struct slave_constants *slave_shim_constants(void);
int slave_shim_set_iutf8(int pts);
const char *slave_shim_terminfo_path(void);
bool slave_shim_reset_signals(void);
int slave_shim_execvpe(
    const char *file, char *const argv[], char *const envp[]);

pid_t slave_spawn(
    int ptmx, int argc, const char *cwd, char *const *argv, const char *const *envp,
    const env_var_list_t *extra_env_vars, const char *term_env,
    const char *conf_shell, bool login_shell,
    const user_notifications_t *notifications);
