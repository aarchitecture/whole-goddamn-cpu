#include "core/conn.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "config.h"
#include "core/server.h"
#include "util.h"

static void conn_on_event(void *user, loop_fd *self, unsigned events);
static bool conn_read(srv_conn *c);
static bool conn_parse(srv_conn *c);
static bool conn_flush(srv_conn *c);

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void conn_link(srv_conn *c) {
    srv_worker *w = c->worker;
    c->next = w->conns;
    if (w->conns) w->conns->prev = c;
    w->conns = c;
}

static void conn_unlink(srv_conn *c) {
    srv_worker *w = c->worker;
    if (c->prev) c->prev->next = c->next;
    else w->conns = c->next;
    if (c->next) c->next->prev = c->prev;
}

srv_conn *conn_create(srv_worker *worker, int fd, const conn_hooks *hooks) {
    srv_conn *c = xcalloc(1, sizeof *c);
    c->fd = fd;
    c->worker = worker;
    c->hooks = hooks;
    c->state = CONN_OPEN;
    c->last_active_ms = now_ms();
    buf_init(&c->in);
    buf_init(&c->out);

    c->ev = loop_add(worker->loop, fd, LOOP_IN, conn_on_event, c);
    if (!c->ev) {
        buf_free(&c->in);
        buf_free(&c->out);
        free(c);
        close(fd);
        return NULL;
    }
    conn_link(c);
    return c;
}

void conn_close(srv_conn *c) {
    srv_worker *w = c->worker;
    if (c->request && c->hooks && c->hooks->on_abandon)
        c->hooks->on_abandon(c);
    c->request = NULL;
    if (c->ev) loop_remove(w->loop, c->ev);
    c->ev = NULL;
    close(c->fd);
    buf_free(&c->in);
    buf_free(&c->out);
    conn_unlink(c);
    free(c);
}

static int conn_timed_out(const srv_conn *c, int64_t now) {
    return now - c->last_active_ms > IDLE_TIMEOUT_MS;
}

void conn_sweep(srv_worker *w) {
    int64_t now = now_ms();
    for (srv_conn *c = w->conns; c;) {
        srv_conn *next = c->next;
        if (c->state == CONN_OPEN && conn_timed_out(c, now)) conn_close(c);
        c = next;
    }
}

int conn_close_one_idle(srv_worker *w) {
    for (srv_conn *c = w->conns; c; c = c->next) {
        if (c->state != CONN_OPEN) continue;
        conn_close(c);
        return 1;
    }
    return 0;
}

static void conn_on_event(void *user, loop_fd *self, unsigned events) {
    (void)self;
    srv_conn *c = user;
    c->last_active_ms = now_ms();

    if (events & LOOP_ERR) {
        conn_close(c);
        return;
    }
    if (events & LOOP_OUT) {
        if (!conn_flush(c)) return;
    }
    if (events & LOOP_IN) (void)conn_read(c);
}

static bool conn_read(srv_conn *c) {
    char chunk[CONN_READ_CHUNK];
    for (;;) {
        ssize_t n = recv(c->fd, chunk, sizeof chunk, 0);
        if (n > 0) {
            buf_append(&c->in, chunk, (size_t)n);
            if ((size_t)n == sizeof chunk) continue;
            break;
        }
        if (n == 0) {
            conn_close(c);
            return false;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        conn_close(c);
        return false;
    }

    if (c->in.len - c->in_start > HTTP_MAX_BUFFER) {
        conn_close(c);
        return false;
    }
    if (c->state == CONN_OPEN) return conn_parse(c);
    return true;
}

static bool conn_reject(srv_conn *c, int status, const char *body,
                        size_t body_len) {
    c->close_after = true;
    c->request_len = c->in.len - c->in_start;
    c->state = CONN_REQUEST;
    conn_respond(c, status, body, body_len);
    return true;
}

static bool conn_parse(srv_conn *c) {
    if (c->state != CONN_OPEN) return true;

    const char *data = c->in.data + c->in_start;
    size_t avail = c->in.len - c->in_start;
    size_t header_len = 0;
    http_result rc = http_parse(data, avail, &header_len, &c->rq);
    if (rc == HTTP_INCOMPLETE) return true;
    if (rc == HTTP_INVALID) {
        static const char BODY[] =
            "{\"errors\":{\"body\":[\"malformed request\"]}}";
        return conn_reject(c, 400, BODY, sizeof BODY - 1);
    }

    /* cap declared body at what the process will buffer */
    if (c->rq.content_length > BODY_MAX) {
        conn_close(c);
        return false;
    }
    size_t body_len = (size_t)c->rq.content_length;
    size_t total = header_len + body_len;
    if (avail < total) return true;

    c->request_len = total;
    c->state = CONN_REQUEST;
    c->close_after = !c->rq.keep_alive;
    const char *body = body_len ? data + header_len : NULL;
    c->hooks->on_request(c, &c->rq, body, body_len);
    return true;
}

static bool conn_flush(srv_conn *c) {
    while (c->out.len > 0) {
        ssize_t n = send(c->fd, c->out.data, c->out.len, MSG_NOSIGNAL);
        if (n > 0) {
            buf_consume(&c->out, (size_t)n);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            loop_set_events(c->worker->loop, c->ev, LOOP_IN | LOOP_OUT);
            return true;
        }
        conn_close(c);
        return false;
    }

    if (c->state == CONN_RESPONSE) {
        c->in_start += c->request_len;
        c->request_len = 0;
        c->state = CONN_OPEN;

        if (c->in_start == c->in.len) {
            c->in.len = 0;
            c->in_start = 0;
        } else if (c->in_start >= IN_COMPACT_THRESHOLD ||
                   c->in_start * 2 >= c->in.len) {
            memmove(c->in.data, c->in.data + c->in_start,
                    c->in.len - c->in_start);
            c->in.len -= c->in_start;
            c->in_start = 0;
        }
    }

    if (c->close_after) {
        conn_close(c);
        return false;
    }

    /* drop idle conn bufs over IDLE_BUF_CAP: cheap to regrow */
    if (c->in.len == 0 && c->in.cap > IDLE_BUF_CAP) buf_free(&c->in);
    if (c->out.len == 0 && c->out.cap > IDLE_BUF_CAP) buf_free(&c->out);

    loop_set_events(c->worker->loop, c->ev, LOOP_IN);
    if (c->state == CONN_OPEN) return conn_parse(c);
    return true;
}

void conn_respond(srv_conn *c, int status, const char *body, size_t body_len) {
    CHECK(c->state == CONN_REQUEST, "response without an in-flight request");
    CHECK(c->out.len == 0, "response queued over an unflushed response");
    CHECK(body_len == 0 || body != NULL, "response body pointer");

    buf_printf(&c->out,
               "HTTP/1.1 %d %s\r\n"
               "Content-Type: application/json\r\n"
               "Content-Length: %zu\r\n"
               "Connection: %s\r\n"
               "\r\n",
               status, http_status_text(status), body_len,
               c->close_after ? "close" : "keep-alive");
    if (body_len) buf_append(&c->out, body, body_len);

    c->state = CONN_RESPONSE;
    loop_set_events(c->worker->loop, c->ev, LOOP_IN | LOOP_OUT);
}

void conn_respond_empty(srv_conn *c, int status) {
    CHECK(c->state == CONN_REQUEST, "response without an in-flight request");
    CHECK(c->out.len == 0, "response queued over an unflushed response");

    buf_printf(&c->out,
               "HTTP/1.1 %d %s\r\n"
               "Connection: %s\r\n"
               "\r\n",
               status, http_status_text(status),
               c->close_after ? "close" : "keep-alive");

    c->state = CONN_RESPONSE;
    loop_set_events(c->worker->loop, c->ev, LOOP_IN | LOOP_OUT);
}
