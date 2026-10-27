#include "pg/pg_internal.h"

#include <string.h>
#include <time.h>

#include "core/wake.h"
#include "util.h"

int64_t pg_mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void fail_ready(void *user, loop_fd *self, unsigned events) {
    (void)self;
    if (!(events & LOOP_IN)) return;
    pg_pool *pool = user;
    wake_drain(pool->fail_fd);

    pg_pending *list = pool->failed_head;
    pool->failed_head = pool->failed_tail = NULL;

    /* callbacks may submit again; they land on the drained queue and run next
     * turn */
    while (list) {
        pg_pending *p = list;
        list = list->next;
        p->cb(p->ctx, PG_ERROR, NULL);
        pg_pending_free(p);
    }
}

void pg_pool_defer_failure(pg_pool *pool, pg_pending *head) {
    if (!head) return;
    pg_pending *tail = head;
    while (tail->next) tail = tail->next;

    if (pool->failed_tail) pool->failed_tail->next = head;
    else pool->failed_head = head;
    pool->failed_tail = tail;
    wake_fire(pool->fail_fd);
}

void pg_pending_free(pg_pending *p) {
    if (!p) return;
    free(p->params);
    free(p);
}

void pg_pool_open(pg_pool **out, const char *url, int read_conns,
                  int write_conns, int read_batch, int read_window_ms,
                  int write_group, int write_window_ms, loop *l) {
    CHECK(read_conns >= 1, "pg: at least one read connection is required");
    CHECK(write_conns >= 1, "pg: at least one write connection is required");
    CHECK(read_batch >= 1, "pg: read batch must be positive");
    CHECK(read_window_ms >= 0, "pg: read window must be non-negative");
    CHECK(write_group >= 1 && write_group <= PG_WRITE_GROUP_MAX,
          "pg: write group must be 1..%d", PG_WRITE_GROUP_MAX);
    CHECK(write_window_ms >= 0, "pg: write window must be non-negative");

    pg_pool *pool = xcalloc(1, sizeof *pool);
    pool->loop = l;
    pool->url = xmalloc(strlen(url) + 1);
    strcpy(pool->url, url);
    pool->read_conns = read_conns;
    pool->write_conns = write_conns;
    pool->read_live = read_conns;
    pool->write_live = write_conns;
    pool->read_batch = read_batch;
    pool->read_window_ms = read_window_ms;
    pool->write_group = write_group;
    pool->write_window_ms = write_window_ms;
    pool->conns = xcalloc((size_t)(read_conns + write_conns),
                          sizeof *pool->conns);

    pool->fail_fd = wake_new();
    CHECK(pool->fail_fd >= 0, "pg: failure eventfd creation failed");
    pool->fail_ev = loop_add(l, pool->fail_fd, LOOP_IN, fail_ready, pool);
    CHECK(pool->fail_ev != NULL, "pg: loop_add(failure eventfd) failed");

    for (int i = 0; i < read_conns + write_conns; i++) {
        pg_conn *cn = &pool->conns[i];
        cn->pool = pool;
        cn->role = i < read_conns ? PG_CONN_READ : PG_CONN_WRITE;
        cn->group_results =
            xcalloc((size_t)write_group, sizeof *cn->group_results);
        cn->retry_backoff_ms = PG_RECONNECT_BACKOFF_MIN;
        pg_conn_open(cn, url, i);
    }
    *out = pool;
}

static void read_push(pg_read_queue *q, pg_pending *p) {
    p->next = NULL;
    if (q->tail) q->tail->next = p;
    else q->head = p;
    q->tail = p;
    q->count++;
}

static pg_pending *read_pop(pg_read_queue *q) {
    pg_pending *p = q->head;
    CHECK(p != NULL, "pg: read queue underrun");
    q->head = p->next;
    if (!q->head) q->tail = NULL;
    p->next = NULL;
    q->count--;
    return p;
}

static pg_conn *pool_pick_write(pg_pool *pool) {
    pg_conn *best = NULL;
    int best_index = -1;
    int total = pool->read_conns + pool->write_conns;
    for (int i = 0; i < total; i++) {
        int index = (pool->rr + i) % total;
        pg_conn *candidate = &pool->conns[index];
        if (candidate->role != PG_CONN_WRITE || candidate->dead) continue;
        int load = candidate->queued + (candidate->busy ? 1 : 0);
        int best_load = best ? best->queued + (best->busy ? 1 : 0) : 0;
        if (!best || load < best_load) {
            best = candidate;
            best_index = index;
        }
    }
    if (best) pool->rr = (best_index + 1) % total;
    return best;
}

void pg_submit(pg_pool *pool, pg_stmt stmt, int nparams,
               const char *const *params, void *ctx, pg_cb cb) {
    CHECK(stmt >= 0 && stmt < PG_STMT_COUNT, "pg_submit: bad statement %d", stmt);
    CHECK(nparams == PG_STMT_PARAM_COUNT[stmt],
          "pg_submit: statement %d takes %u parameters, got %d", (int)stmt,
          (unsigned)PG_STMT_PARAM_COUNT[stmt], nparams);
    CHECK(nparams == 0 || params != NULL, "pg_submit: missing parameters");
    CHECK(cb != NULL, "pg_submit: callback is required");

    pg_pending *p = xcalloc(1, sizeof *p);
    p->stmt = stmt;
    p->nparams = nparams;
    p->ctx = ctx;
    p->cb = cb;
    p->solo = PG_STMT_SOLO[stmt] != 0;
    if (nparams > 0) {
        p->params = xmalloc((size_t)nparams * sizeof *p->params);
        memcpy(p->params, params, (size_t)nparams * sizeof *p->params);
    }

    pg_conn *cn = pool_pick_write(pool);
    if (!cn) {
        pg_pool_defer_failure(pool, p);
        return;
    }

    if (cn->tail) cn->tail->next = p;
    else cn->head = p;
    cn->tail = p;
    cn->queued++;

    /* one commit can carry several writes: a lone write waits briefly for
     * siblings, a deep queue sends now */
    if (cn->queued >= PG_WRITE_IMMEDIATE || pool->write_window_ms == 0) {
        cn->write_deadline_ms = 0;
        pg_conn_pump(cn);
    } else if (cn->write_deadline_ms == 0) {
        cn->write_deadline_ms = pg_mono_ms() + pool->write_window_ms;
    }
}

void pg_read_submit(pg_pool *pool, pg_read_kind kind, const pg_read *read,
                    void *ctx, pg_cb cb) {
    CHECK(kind >= 0 && kind < PG_READ_COUNT, "pg_read_submit: bad kind %d", kind);
    CHECK(cb != NULL, "pg_read_submit: callback is required");
    CHECK(kind == PG_READ_TAGS || read != NULL,
          "pg_read_submit: missing read arguments");

    pg_pending *p = xcalloc(1, sizeof *p);
    p->ctx = ctx;
    p->cb = cb;
    p->seq = ++pool->read_seq;
    if (read) {
        p->viewer = read->viewer;
        p->limit = read->limit;
        p->offset = read->offset;
        p->key = read->key ? read->key : "";
    } else {
        p->key = "";
    }

    if (pool->read_live == 0) {
        pg_pool_defer_failure(pool, p);
        return;
    }

    read_push(&pool->queues[kind], p);
    pool->queued_reads++;
    if (pool->read_deadline_ms == 0)
        pool->read_deadline_ms = pg_mono_ms() + pool->read_window_ms;
    pg_pool_dispatch_reads(pool);
}

void pg_pool_dispatch_reads(pg_pool *pool) {
    if (pool->queued_reads == 0) {
        pool->read_deadline_ms = 0;
        return;
    }

    int64_t now = pg_mono_ms();
    if (pool->read_deadline_ms == 0)
        pool->read_deadline_ms = now + pool->read_window_ms;

    /* full batch sends at once; otherwise the window accumulates to amortise
     * one execution */
    bool full = pool->queued_reads >= pool->read_batch;
    if (!full && now < pool->read_deadline_ms) return;

    for (int i = 0; i < pool->read_conns; i++) {
        pg_conn *cn = &pool->conns[i];
        if (cn->dead || cn->busy) continue;
        pg_conn_dispatch_read(cn);
        if (pool->queued_reads == 0) break;
    }

    if (pool->queued_reads == 0) pool->read_deadline_ms = 0;
    else pool->read_deadline_ms = now + pool->read_window_ms;
}

void pg_pool_tick(pg_pool *pool) {
    /* lost conns reconnect with backoff before any dispatch */
    int64_t now = pg_mono_ms();
    int total = pool->read_conns + pool->write_conns;
    for (int i = 0; i < total; i++) {
        pg_conn *cn = &pool->conns[i];
        if (!cn->dead || cn->setup != PG_SETUP_NONE) continue;
        if (cn->retry_at_ms == 0 || now < cn->retry_at_ms) continue;
        pg_conn_retry(cn);
    }

    if (pool->queued_reads) pg_pool_dispatch_reads(pool);

    /* send a write queued behind a busy lane as soon as the lane frees */
    for (int i = pool->read_conns; i < total; i++) {
        pg_conn *cn = &pool->conns[i];
        if (cn->dead || cn->busy) continue;
        if (!cn->head) {
            cn->write_deadline_ms = 0;
            continue;
        }
        if (cn->write_deadline_ms == 0)
            cn->write_deadline_ms = now + pool->write_window_ms;
        if (cn->queued >= PG_WRITE_IMMEDIATE || now >= cn->write_deadline_ms) {
            cn->write_deadline_ms = 0;
            pg_conn_pump(cn);
        }
    }
}

void pg_pool_fail_queued_reads(pg_pool *pool) {
    pg_pending *head = NULL;
    pg_pending *tail = NULL;
    for (int i = 0; i < PG_READ_COUNT; i++) {
        pg_read_queue *q = &pool->queues[i];
        while (q->head) {
            pg_pending *p = read_pop(q);
            if (tail) tail->next = p;
            else head = p;
            tail = p;
        }
    }
    pool->queued_reads = 0;
    if (head) pg_pool_defer_failure(pool, head);
}

int pg_read_batch_cap(const pg_pool *pool, pg_read_kind kind) {
    if (kind == PG_READ_TAGS) return PG_READ_TAG_BATCH;
    return pool->read_batch;
}
