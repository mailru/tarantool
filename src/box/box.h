#ifndef INCLUDES_TARANTOOL_BOX_H
#define INCLUDES_TARANTOOL_BOX_H
/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "trivia/util.h"
#include "iproto_constants.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

/*
 * Box - data storage (spaces, indexes) and query
 * processor (INSERT, UPDATE, DELETE, SELECT, Lua)
 * subsystem of Tarantool.
 */

struct port;

/** To be called at program start. */
void box_load_cfg();
/** To be called at program end. */
void box_free(void);

/** A pthread_atfork() callback for box */
void
box_atfork();

/**
 * The main entry point to the
 * Box: callbacks into the request processor.
 * These are function pointers since they can
 * change when entering/leaving read-only mode
 * (master->slave propagation).
 */
typedef void (*box_process_func)(struct request *request, struct port *port);
/** For read-write operations. */
extern box_process_func box_process;

void
box_set_ro(bool ro);

bool
box_is_ro(void);

/** Non zero if snapshot is in progress. */
extern int snapshot_pid;
/** Incremented with each next snapshot. */
extern uint32_t snapshot_version;

/**
 * Iterate over all spaces and save them to the
 * snapshot file.
 */
int box_snapshot(void);

/**
 * Spit out some basic module status (master/slave, etc.
 */
const char *box_status(void);

void
box_process_auth(struct request *request);

void
box_process_join(int fd, struct xrow_header *header);

void
box_process_subscribe(int fd, struct xrow_header *header);

/**
 * Check Lua configuration before initialization or
 * in case of a configuration change.
 */
void
box_check_config();

void box_set_listen(const char *uri);
void box_set_replication_source(const char *source);
void box_set_wal_mode(const char *mode);
void box_set_log_level(int level);
void box_set_io_collect_interval(double interval);
void box_set_snap_io_rate_limit(double limit);
void box_set_too_long_threshold(double threshold);
void box_set_readahead(int readahead);

extern struct recovery_state *recovery;

#if defined(__cplusplus)
}
#endif /* defined(__cplusplus) */

#endif /* INCLUDES_TARANTOOL_BOX_H */
