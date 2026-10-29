// Article handlers: list, feed, CRUD and favorites.

///|
fn article_row_raw(out : JsonOut, r : @client.Row, full~ : Bool) -> Unit raise {
  out.obj_start()
  out.key("slug")
  out.str_raw(r.get_raw(1))
  out.key("title")
  out.str_raw(r.get_raw(2))
  out.key("description")
  out.str_raw(r.get_raw(3))
  let base = if full {
    out.key("body")
    out.str_raw(r.get_raw(4))
    5
  } else {
    4
  }
  out.key("createdAt")
  out.str_raw(r.get_raw(base))
  out.key("updatedAt")
  out.str_raw(r.get_raw(base + 1))
  out.key("tagList")
  out.text_array(r.get_raw(base + 2))
  out.key("favorited")
  out.bool(r.get(base + 4))
  out.key("favoritesCount")
  out.int64(r.get(base + 3))
  out.key("author")
  out.obj_start()
  out.key("username")
  out.str_raw(r.get_raw(base + 5))
  out.key("bio")
  out.str_raw(r.get_raw(base + 6))
  out.key("image")
  out.str_raw(r.get_raw(base + 7))
  out.key("following")
  out.bool(r.get(base + 8))
  out.obj_end()
  out.obj_end()
}

///|
/// Article JSON from an ARTICLE_FULL_SELECT row, or a 404 response when no
/// row matches.
fn article_resp(status : Int32, row : @client.Row?) -> Resp raise {
  match row {
    None => err_resp(404, "article not found")
    Some(r) => {
      let out = JsonOut::new()
      out.obj_start()
      out.key("article")
      article_row_raw(out, r, full=true)
      out.obj_end()
      raw_json_resp(status, out.to_bytes())
    }
  }
}

///|
async fn article_by_slug_resp(
  app : App,
  viewer : Int64,
  status : Int32,
  slug : String,
) -> Resp {
  let rows = app.pool.batched_query(
    "article",
    article_by_slug_batched,
    [viewer],
    [slug],
  )
  article_resp(status, rows.get(0))
}

///|
async fn article_by_id_resp(
  app : App,
  viewer : Int64,
  status : Int32,
  id : Int64,
) -> Resp {
  article_resp(status, app.pool.query_opt(article_by_id, params=[viewer, id]))
}

///|
/// Shared list writer over the batched list statements: every request gets
/// at least one row carrying its capped count (NULL article columns when the
/// page is empty).
async fn write_list(
  app : App,
  kind : String,
  sql : String,
  viewer : Int64,
  limit : Int64,
  offset : Int64,
  key : String?,
) -> Resp {
  let texts = match key {
    Some(k) => [k]
    None => []
  }
  let rows = app.pool.batched_query(kind, sql, [viewer, limit, offset], texts)
  let out = JsonOut::new()
  out.obj_start()
  out.key("articles")
  out.arr_start()
  for r in rows {
    // A batched empty page is one row with NULL article columns.
    if r.get_raw(0) is Some(_) {
      article_row_raw(out, r, full=false)
    }
  }
  out.arr_end()
  let n : Int64 = match rows.get(0) {
    Some(r) => r.get(13)
    None => raise @client.ClientError::Protocol("list: missing count row")
  }
  out.key("articlesCount")
  out.int64(n)
  out.obj_end()
  raw_json_resp(200, out.to_bytes())
}

///|
/// GET /api/articles — first non-empty filter among tag, author, favorited.
async fn list_articles(
  app : App,
  req : @http.Request,
  params : Map[String, String],
) -> Resp {
  let viewer = match optional_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  guard limit_offset(params) is Some((limit, offset)) else {
    return err_resp(422, "limit must be 1-100 and offset >= 0")
  }
  let tag = params.get("tag")
  let author = params.get("author")
  let favorited = params.get("favorited")
  if tag is Some(t) && t != "" {
    write_list(app, "list_tag", list_tag_batched, viewer, limit, offset, Some(t))
  } else if author is Some(u) && u != "" {
    write_list(
      app,
      "list_author",
      list_author_batched,
      viewer,
      limit,
      offset,
      Some(u),
    )
  } else if favorited is Some(f) && f != "" {
    write_list(
      app,
      "list_favorite",
      list_favorite_batched,
      viewer,
      limit,
      offset,
      Some(f),
    )
  } else {
    write_list(app, "list_all", list_all_batched, viewer, limit, offset, None)
  }
}

///|
/// GET /api/articles/feed
async fn feed(
  app : App,
  req : @http.Request,
  params : Map[String, String],
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  guard limit_offset(params) is Some((limit, offset)) else {
    return err_resp(422, "limit must be 1-100 and offset >= 0")
  }
  write_list(app, "feed", list_feed_batched, viewer, limit, offset, None)
}

///|
/// GET /api/articles/:slug
async fn get_article(app : App, req : @http.Request, slug : String) -> Resp {
  let viewer = match optional_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  article_by_slug_resp(app, viewer, 200, slug)
}

///|
/// POST /api/articles — insert + tags in a single transaction, then fetch.
async fn create_article(
  app : App,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  let body = conn.read_all().text()
  match read_wrapper(body, "article") {
    None => return err_resp(422, "invalid body")
    Some(m) => {
      let title = req_string(m, "title")
      let description = req_string(m, "description")
      let abody = req_string(m, "body")
      match (title, description, abody) {
        (Some(title), Some(description), Some(abody)) => {
          let tags = match opt_tag_list(m) {
            Ok(t) => t
            Err(_) =>
              return err_resp(
                422, "tagList must be an array of non-empty strings",
              )
          }
          let id = app.pool.with_transaction(tx => {
            let row = tx.query_one(insert_article, params=[
              viewer, title, description, abody,
            ])
            let id : Int64 = row.get(0)
            if tags.length() > 0 {
              ignore(tx.execute(insert_tags, params=[tags]))
              ignore(tx.execute(insert_article_tags, params=[id, tags]))
            }
            id
          })
          article_by_id_resp(app, viewer, 201, id)
        }
        _ => err_resp(422, "title, description and body are required")
      }
    }
  }
}

///|
/// Look up an owned article by slug: 404 if missing, 403 if not the author.
async fn own_article(
  app : App,
  viewer : Int64,
  slug : String,
) -> Result[Int64, Resp] {
  let row = app.pool.query_opt(
    "SELECT id, author_id FROM articles WHERE slug = $1",
    params=[slug],
  )
  match row {
    None => Err(err_resp(404, "article not found"))
    Some(r) => {
      let id : Int64 = r.get(0)
      let author_id : Int64 = r.get(1)
      if author_id != viewer {
        Err(err_resp(403, "not the author"))
      } else {
        Ok(id)
      }
    }
  }
}

///|
/// PUT /api/articles/:slug
async fn update_article(
  app : App,
  req : @http.Request,
  conn : @http.ServerConnection,
  slug : String,
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  let body = conn.read_all().text()
  match read_wrapper(body, "article") {
    None => return err_resp(422, "invalid body")
    Some(m) => {
      let title = opt_string(m, "title", non_empty=true)
      let description = opt_string(m, "description", non_empty=true)
      let abody = opt_string(m, "body", non_empty=true)
      if title is Err(_) || description is Err(_) || abody is Err(_) {
        return err_resp(
          422, "title, description and body must be non-empty strings",
        )
      }
      let id = match own_article(app, viewer, slug) {
        Err(resp) => return resp
        Ok(id) => id
      }
      ignore(
        app.pool.execute(update_article_sql, params=[
          id,
          title.unwrap(),
          description.unwrap(),
          abody.unwrap(),
        ]),
      )
      article_by_id_resp(app, viewer, 200, id)
    }
  }
}

///|
/// DELETE /api/articles/:slug
async fn delete_article(app : App, req : @http.Request, slug : String) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  let id = match own_article(app, viewer, slug) {
    Err(resp) => return resp
    Ok(id) => id
  }
  ignore(app.pool.execute("DELETE FROM articles WHERE id = $1", params=[id]))
  no_content()
}

///|
/// Shared "article id by slug" lookup.
async fn article_id(app : App, slug : String) -> Result[Int64, Resp] {
  match
    app.pool.query_opt("SELECT id FROM articles WHERE slug = $1", params=[slug]) {
    None => Err(err_resp(404, "article not found"))
    Some(r) => Ok(r.get(0))
  }
}

///|
/// POST/DELETE /api/articles/:slug/favorite
async fn favorite(
  app : App,
  req : @http.Request,
  slug : String,
  fav : Bool,
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  if fav {
    ignore(
      app.pool.execute(
        "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING",
        params=[viewer, slug],
      ),
    )
  } else {
    ignore(
      app.pool.execute(
        "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
        params=[viewer, slug],
      ),
    )
  }
  article_by_slug_resp(app, viewer, 200, slug)
}
