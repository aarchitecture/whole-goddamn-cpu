#include "api/api.h"

#include <stdlib.h>

#include "api/handlers.h"
#include "api/render.h"

typedef struct favorite_state {
    api_request *r;
    long long article_id;
} favorite_state;

static void favorite_read(void *ctx, pg_status status,
                          const pg_result *res) {
    api_request *r = ctx;
    if (!req_release(r) || r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        article_view view;
        article_view_load(&view, res, 0, true);
        buf_clear(&r->out);
        BUF_LIT(&r->out, "{\"article\":");
        render_article(&r->out, &view);
        buf_putc(&r->out, '}');
        req_respond(r, 200);
        return;
    }
    req_fail(r, status == PG_ERROR ? 500 : 404, "article not found");
}

static void favorite_written(void *ctx, pg_status status,
                             const pg_result *res) {
    favorite_state *state = ctx;
    api_request *r = state->r;
    if (!req_release(r) || r->dead) return;

    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }
    if (pg_result_rows(res) < 1) {
        req_fail(r, 404, "article not found");
        return;
    }
    state->article_id = strtoll(pg_result_value(res, 0, 0), NULL, 10);

    // write committed: read-back sees new count
    const pg_read read = {
        .viewer = r->viewer,
        .offset = state->article_id,
    };
    req_hold(r);
    pg_read_submit(r->worker->pg, PG_READ_ARTICLE_ID, &read, r, favorite_read);
}

static void favorite_begin(api_request *r, bool add) {
    favorite_state *state = req_calloc(r, sizeof *state);
    state->r = r;

    const char *params[2] = { req_ll(r, r->viewer), r->seg[0] };
    req_hold(r);
    pg_submit(r->worker->pg,
              add ? PG_STMT_FAVORITES_INSERT : PG_STMT_FAVORITES_DELETE,
              2, params, state, favorite_written);
}

void handle_favorite_add(api_request *r) {
    favorite_begin(r, true);
}

void handle_favorite_remove(api_request *r) {
    favorite_begin(r, false);
}
