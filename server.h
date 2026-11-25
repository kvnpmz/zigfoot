#pragma once

#include <stdint.h>

#include <tllist.h>

#include "fdm.h"
#include "config.h"
#include "reaper.h"
#include "wayland.h"

struct client;
struct terminal_instance;

/* Internal, but shared with server.zig and pinned by the ABI probe. */
struct server {
    struct config *conf;
    struct fdm *fdm;
    struct reaper *reaper;
    struct wayland *wayl;

    int fd;
    const char *sock_path;

    tll(struct client *) clients;
    tll(struct terminal_instance *) terminals;
};

struct client {
    struct server *server;
    int fd;

    struct {
        uint8_t *data;
        size_t left;
        size_t idx;
    } buffer;

    struct terminal_instance *instance;
};

struct terminal_instance {
    struct terminal *terminal;
    struct server *server;
    struct client *client;
    struct config *conf;
};

struct server *server_init(struct config *conf, struct fdm *fdm,
                           struct reaper *reaper, struct wayland *wayl);
void server_destroy(struct server *server);

void server_global_theme_switch_to_dark(struct server *server);
void server_global_theme_switch_to_light(struct server *server);

/* Ported to server.zig; exposed for the headless harness. */
bool prepare_socket(int fd);
int server_try_connect(const char *sock_path);
bool fdm_client(struct fdm *fdm, int fd, int events, void *data);
bool fdm_server(struct fdm *fdm, int fd, int events, void *data);
void term_shutdown_handler(void *data, int exit_code);
