#include "csi.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(_DEBUG)
 #include <stdio.h>
#endif

#include <sys/timerfd.h>

#define LOG_MODULE "csi"
#define LOG_ENABLE_DBG 0
#include "log.h"
#include "char32.h"
#include "config.h"
#include "debug.h"
#include "grid.h"
#include "selection.h"
#include "sixel.h"
#include "util.h"
#include "version.h"
#include "vt.h"
#include "xmalloc.h"
#include "xsnprintf.h"

/* Ported to csi.zig (chunk A) */
void sgr_reset(struct terminal *term);
void csi_sgr(struct terminal *term);

/* Ported to csi.zig (chunk B) */
void xtsave(struct terminal *term, unsigned param);
void xtrestore(struct terminal *term, unsigned param);

/* Ported to csi.zig (chunk C1) */
void decset_decrst(struct terminal *term, unsigned param, bool enable);
void decset(struct terminal *term, unsigned param);
void decrst(struct terminal *term, unsigned param);

/* Ported to csi.zig (chunk D) */
bool params_to_rectangular_area(const struct terminal *term, int first_idx, int *top, int *left, int *bottom, int *right);


/* Ported to csi.zig (chunk E1) */
void csi_dispatch(struct terminal *term, uint8_t final);

/* Ported to csi.zig (chunk C2) — decrpm + decrqm */
enum decrpm_status {
    DECRPM_NOT_RECOGNIZED = 0,
    DECRPM_SET = 1,
    DECRPM_RESET = 2,
    DECRPM_PERMANENTLY_SET = 3,
    DECRPM_PERMANENTLY_RESET = 4,
};
extern enum decrpm_status decrqm(const struct terminal *term, unsigned param);

#define UNHANDLED()        LOG_DBG("unhandled: %s", csi_as_string(term, final, -1))
#define UNHANDLED_SGR(idx) LOG_DBG("unhandled: %s", csi_as_string(term, 'm', idx))

/*
 * These values represent the current state of a DEC private mode,
 * as returned in the DECRPM reply to a DECRQM query.
 */
