#ifndef _GNU_SOURCE
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif

#include "slave.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHILD_RETURNED 99
#define CHILD_BAD_RETURN 98

struct child_result {
    bool marker;
    int err;
    int status;
};

static int failures;

static void report(const char *name, bool ok, const char *detail)
{
    printf("%s: %s", name, ok ? "PASS" : "FAIL");
    if (detail != NULL)
        printf(" (%s)", detail);
    printf("\n");
    if (!ok)
        failures++;
}

static void write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            _exit(CHILD_BAD_RETURN);
        p += n;
        len -= (size_t)n;
    }
}

static struct child_result run_case(const char *file, char *const argv[],
                                    char *const envp[], const char *chdir_to)
{
    int marker_pipe[2];
    int err_pipe[2];
    if (pipe2(marker_pipe, O_CLOEXEC) < 0 || pipe2(err_pipe, O_CLOEXEC) < 0) {
        perror("pipe2");
        exit(2);
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(2);
    }

    if (pid == 0) {
        close(marker_pipe[0]);
        close(err_pipe[0]);

        if (chdir_to != NULL && chdir(chdir_to) < 0) {
            int e = errno;
            write_all(err_pipe[1], &e, sizeof(e));
            _exit(CHILD_RETURNED);
        }

        char marker = 'M';
        write_all(marker_pipe[1], &marker, sizeof(marker));
        close(marker_pipe[1]);

        int rc = slave_execvpe(file, argv, envp);
        int e = rc == -1 ? errno : 0;
        write_all(err_pipe[1], &e, sizeof(e));
        _exit(rc == -1 ? CHILD_RETURNED : CHILD_BAD_RETURN);
    }

    close(marker_pipe[1]);
    close(err_pipe[1]);

    char marker = 0;
    ssize_t marker_ret;
    do {
        marker_ret = read(marker_pipe[0], &marker, 1);
    } while (marker_ret < 0 && errno == EINTR);

    int child_err = 0;
    ssize_t err_ret;
    do {
        err_ret = read(err_pipe[0], &child_err, sizeof(child_err));
    } while (err_ret < 0 && errno == EINTR);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0)
        perror("waitpid");

    close(marker_pipe[0]);
    close(err_pipe[0]);

    return (struct child_result){
        .marker = marker_ret == 1 && marker == 'M',
        .err = err_ret == (ssize_t)sizeof(child_err) ? child_err : 0,
        .status = status,
    };
}

static void make_file(const char *path, const char *data, mode_t mode)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        perror(path);
        exit(2);
    }
    write_all(fd, data, strlen(data));
    close(fd);
    if (chmod(path, mode) < 0) {
        perror(path);
        exit(2);
    }
}

static void make_symlink(const char *target, const char *path)
{
    if (symlink(target, path) < 0) {
        perror(path);
        exit(2);
    }
}

static void path_join(char *out, size_t size, const char *dir, const char *name)
{
    if (snprintf(out, size, "%s/%s", dir, name) >= (int)size) {
        fprintf(stderr, "path too long\n");
        exit(2);
    }
}

static bool exited_with(const struct child_result *r, int code)
{
    return r->marker && r->err == 0 && WIFEXITED(r->status) &&
        WEXITSTATUS(r->status) == code;
}

int main(void)
{
    char tmp[] = "/tmp/foot-execvpe-XXXXXX";
    if (mkdtemp(tmp) == NULL) {
        perror("mkdtemp");
        return 2;
    }

    char dir1[512], dir2[512];
    snprintf(dir1, sizeof(dir1), "%s/dir1", tmp);
    snprintf(dir2, sizeof(dir2), "%s/dir2", tmp);
    if (mkdir(dir1, 0700) < 0 || mkdir(dir2, 0700) < 0) {
        perror("mkdir");
        return 2;
    }

    struct child_result r;
    char detail[160];

    char *env_bin[] = { "PATH=/bin", NULL };
    char *argv_exit42[] = { "sh", "-c", "exit 42", NULL };
    r = run_case("sh", argv_exit42, env_bin, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("found in PATH", exited_with(&r, 42), detail);

    char *argv_missing[] = { "definitely-missing-execvpe-test", NULL };
    r = run_case(argv_missing[0], argv_missing, env_bin, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("missing command", r.marker && r.err == ENOENT, detail);

    char noexec[512];
    path_join(noexec, sizeof(noexec), tmp, "noexec");
    make_file(noexec, "not executable\n", 0644);
    char env_noexec[600];
    snprintf(env_noexec, sizeof(env_noexec), "PATH=%s", tmp);
    char *env_noexecv[] = { env_noexec, NULL };
    char *argv_noexec[] = { "noexec", NULL };
    r = run_case("noexec", argv_noexec, env_noexecv, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("non-executable only", r.marker && r.err == EACCES, detail);

    char first[512], later[512];
    path_join(first, sizeof(first), dir1, "later");
    path_join(later, sizeof(later), dir2, "later");
    make_file(first, "not executable\n", 0644);
    make_symlink("/bin/true", later);
    char env_later[2048];
    snprintf(env_later, sizeof(env_later), "PATH=%s:%s", dir1, dir2);
    char *env_laterv[] = { env_later, NULL };
    char *argv_later[] = { "later", NULL };
    r = run_case("later", argv_later, env_laterv, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("continues after EACCES", exited_with(&r, 0), detail);

    char script[512], script_out[512];
    path_join(script, sizeof(script), tmp, "shebangless");
    path_join(script_out, sizeof(script_out), tmp, "script.out");
    make_file(script, "echo shebangless > \"$OUT\"\n", 0755);
    char out_env[600];
    snprintf(out_env, sizeof(out_env), "OUT=%s", script_out);
    char path_env[600];
    snprintf(path_env, sizeof(path_env), "PATH=%s", tmp);
    char *env_scriptv[] = { path_env, out_env, NULL };
    char *argv_script[] = { "shebangless", NULL };
    r = run_case("shebangless", argv_script, env_scriptv, NULL);
    char contents[64] = {0};
    int out_fd = open(script_out, O_RDONLY);
    if (out_fd >= 0) {
        (void)read(out_fd, contents, sizeof(contents) - 1);
        close(out_fd);
    }
    contents[strcspn(contents, "\n")] = '\0';
    snprintf(detail, sizeof(detail), "status=%d errno=%d out=%s", r.status, r.err, contents);
    report("shebang-less script", exited_with(&r, 0) && strcmp(contents, "shebangless") == 0, detail);

    char *argv_slash[] = { "/definitely/not/here/sh", NULL };
    r = run_case(argv_slash[0], argv_slash, env_bin, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("slash disables search", r.marker && r.err == ENOENT, detail);

    char cwdcmd[512];
    path_join(cwdcmd, sizeof(cwdcmd), tmp, "cwdcmd");
    make_symlink("/bin/true", cwdcmd);
    char *env_empty[] = { "PATH=:", NULL };
    char *argv_cwd[] = { "cwdcmd", NULL };
    r = run_case("cwdcmd", argv_cwd, env_empty, tmp);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("empty PATH component", exited_with(&r, 0), detail);

    char *env_nopath[] = { "HOME=/tmp", NULL };
    char *argv_exit43[] = { "sh", "-c", "exit 43", NULL };
    r = run_case("sh", argv_exit43, env_nopath, NULL);
    snprintf(detail, sizeof(detail), "status=%d errno=%d", r.status, r.err);
    report("PATH unset uses CS_PATH", exited_with(&r, 43), detail);

    printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
