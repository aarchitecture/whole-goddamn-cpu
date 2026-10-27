#include "api/api.h"

#include <string.h>

#include "util.h"

void req_hold(api_request *r) {
    CHECK(r->refs > 0, "request hold after release");
    r->refs++;
}

bool req_release(api_request *r) {
    CHECK(r->refs > 0, "request release underflow");
    if (--r->refs > 0) return true;

    json_free(r->body);
    arena_reset(&r->arena);
    buf_free(&r->out);
    free(r);
    return false;
}

void *req_alloc(api_request *r, size_t n) {
    return arena_alloc(&r->arena, n);
}

void *req_calloc(api_request *r, size_t n) {
    return arena_calloc(&r->arena, n);
}

char *req_str(api_request *r, const char *s) {
    return arena_strdup(&r->arena, s);
}

char *req_strn(api_request *r, const char *s, size_t n) {
    return arena_str(&r->arena, s, n);
}

const char *req_ll(api_request *r, long long value) {
    return arena_printf(&r->arena, "%lld", value);
}

void req_respond(api_request *r, int status) {
    CHECK(!r->dead, "response on an abandoned request");
    CHECK(!r->responded, "double response");
    CHECK(r->refs == 1, "response with %d outstanding references", r->refs);

    srv_conn *c = r->conn;
    r->responded = true;
    c->request = NULL;
    conn_respond(c, status, r->out.data, r->out.len);
    req_release(r);
}

void req_respond_empty(api_request *r, int status) {
    CHECK(!r->dead, "response on an abandoned request");
    CHECK(!r->responded, "double response");
    CHECK(r->refs == 1, "response with %d outstanding references", r->refs);

    srv_conn *c = r->conn;
    r->responded = true;
    c->request = NULL;
    conn_respond_empty(c, status);
    req_release(r);
}

void req_fail(api_request *r, int status, const char *message) {
    CHECK(!r->responded, "failure after response");
    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"errors\":{\"body\":[");
    json_quote(&r->out, message);
    BUF_LIT(&r->out, "]}}");
    req_respond(r, status);
}

void req_db_fail(api_request *r) {
    req_fail(r, 500, "database unavailable");
}

void api_abandon(srv_conn *c) {
    api_request *r = c->request;
    if (!r) return;
    c->request = NULL;
    r->dead = true;
    (void)req_release(r);
}
