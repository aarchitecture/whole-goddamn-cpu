#ifndef PG_INTERNAL_H
#define PG_INTERNAL_H

#include <libpq-fe.h>
#include <stdbool.h>
#include <stdint.h>

#include "config.h"
#include "core/loop.h"
#include "pg/pg.h"

/* one queued write or read. write: params is an owned array of borrowed strings
 * (caller's arena/json tree). read: key borrowed the same way, rest copied at
 * submit */
typedef struct pg_pending {
    bool solo;                  // don't join a write group
    pg_stmt stmt;
    int nparams;
    const char **params;
    void *ctx;
    pg_cb cb;
    uint64_t seq;               // read arrival order, all kinds
    long long viewer;
    int limit;
    long long offset;
    const char *key;
    struct pg_pending *next;
} pg_pending;

typedef struct pg_read_queue {
    pg_pending *head;
    pg_pending *tail;
    int count;
} pg_read_queue;

typedef enum pg_conn_role {
    PG_CONN_READ = 0,
    PG_CONN_WRITE,
} pg_conn_role;

/* reconnect setup phases: dead conn, non-blocking connect, session init,
 * prepared statements */
typedef enum pg_setup {
    PG_SETUP_NONE = 0,
    PG_SETUP_CONNECT,
    PG_SETUP_INIT,
    PG_SETUP_PREPARE,
} pg_setup;

/* one execution of a single kind, detached from the queue while in flight */
typedef struct pg_read_batch {
    pg_read_kind kind;
    int n;
    pg_pending **reqs;
} pg_read_batch;

typedef struct pg_conn {
    PGconn *raw;
    pg_pool *pool;
    loop_fd *ev;
    pg_conn_role role;
    int index;
    pg_pending *head;
    pg_pending *tail;
    int queued;                 // writes not yet delivered
    int64_t write_deadline_ms;  // idle write lane commits its queue then
    bool dead;
    bool busy;                  // one execution or pipeline group in flight
    pg_setup setup;             // reconnect phase while dead
    int64_t retry_at_ms;        // next reconnect attempt
    int retry_backoff_ms;       // doubles on failure, capped, reset on success

    pg_read_batch batch;

    /* write group: BEGIN + group_sent writes + COMMIT, framed by
     * PQpipelineSync; group_results holds the write results */
    bool in_pipeline;
    int group_sent;
    int group_got;
    int group_total;
    bool group_failed;
    PGresult **group_results;
} pg_conn;

struct pg_pool {
    loop *loop;
    int read_conns;
    int write_conns;
    int read_live;
    int write_live;
    int read_batch;
    int read_window_ms;
    int64_t read_deadline_ms;
    int write_group;
    int write_window_ms;
    int rr;
    char *url;
    pg_conn *conns;

    pg_read_queue queues[PG_READ_COUNT];
    int queued_reads;
    uint64_t read_seq;

    /* work from dead conns is answered PG_ERROR here; the eventfd keeps
     * callbacks async even with no conns left */
    pg_pending *failed_head;
    pg_pending *failed_tail;
    int fail_fd;
    loop_fd *fail_ev;
};

void pg_conn_open(pg_conn *cn, const char *url, int index);
void pg_conn_retry(pg_conn *cn);
void pg_conn_pump(pg_conn *cn);
void pg_conn_dispatch_read(pg_conn *cn);
void pg_pool_dispatch_reads(pg_pool *pool);
void pg_pool_fail_queued_reads(pg_pool *pool);
int  pg_read_batch_cap(const pg_pool *pool, pg_read_kind kind);
void pg_pool_defer_failure(pg_pool *pool, pg_pending *head);
void pg_pending_free(pg_pending *p);
int64_t pg_mono_ms(void);

/* stack-built around a PGresult, for one callback */
struct pg_result {
    PGresult *raw;
    int first_row;
    int rows;
    int col_offset;
};

#endif
