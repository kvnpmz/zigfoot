#include "notify.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/epoll.h>
#include <sys/stat.h>
#include <fcntl.h>

#define LOG_MODULE "notify"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "config.h"
#include "spawn.h"
#include "terminal.h"
#include "util.h"
#include "wayland.h"
#include "xmalloc.h"
#include "xsnprintf.h"

void notify_free(struct terminal *term, struct notification *notif);
void notify_icon_free(struct notification_icon *icon);
bool write_icon_file(const void *data, size_t data_sz, int *fd, char **filename, char **symbolic_name);
bool to_integer(const char *line, size_t len, uint32_t *res);
void notify_icon_add(struct terminal *term, const char *id, const char *symbolic_name, const uint8_t *data, size_t data_sz);
void notify_icon_del(struct terminal *term, const char *id);
bool fdm_notify_stdout(struct fdm *fdm, int fd, int events, void *data);
bool expand_action_to_argv(struct terminal *term, const char *name, const char *label, size_t *argc, char ***argv);
void notify_close(struct terminal *term, const char *id);
void notif_done(struct reaper *reaper, pid_t pid, int status, void *data);
bool notify_notify(struct terminal *term, struct notification *notif);
void notify_close(struct terminal *term, const char *id);
bool fdm_notify_stdout(struct fdm *fdm, int fd, int events, void *data);
bool expand_action_to_argv(struct terminal *term, const char *name, const char *label, size_t *argc, char ***argv);

struct done_context {
    struct wayland *wayl;
    struct terminal *term;
};

