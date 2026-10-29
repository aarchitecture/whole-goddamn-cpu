// Comment handlers.

///|
let comment_ts_created : String = "to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at"

///|
let comment_ts_updated : String = "to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at"

///|
fn comment_json(
  id : Int64,
  created : String,
  updated : String,
  body : String,
  username : String,
  bio : String?,
  image : String?,
  following : Bool,
) -> Json {
  let c : Map[String, Json] = Map([])
  c["id"] = Json::number(id.to_double(), repr=id.to_string())
  c["createdAt"] = Json::string(created)
  c["updatedAt"] = Json::string(updated)
  c["body"] = Json::string(body)
  c["author"] = profile_json(username, bio, image, following)
  Json::object(c)
}

///|
fn comment_raw(out : JsonOut, r : @client.Row) -> Unit raise {
  out.obj_start()
  out.key("id")
  out.int64(r.get(1))
  out.key("createdAt")
  out.str_raw(r.get_raw(3))
  out.key("updatedAt")
  out.str_raw(r.get_raw(4))
  out.key("body")
  out.str_raw(r.get_raw(2))
  out.key("author")
  out.obj_start()
  out.key("username")
  out.str_raw(r.get_raw(5))
  out.key("bio")
  out.str_raw(r.get_raw(6))
  out.key("image")
  out.str_raw(r.get_raw(7))
  out.key("following")
  out.bool(r.get(8))
  out.obj_end()
  out.obj_end()
}

///|
/// GET /api/articles/:slug/comments — newest 100.
async fn list_comments(app : App, req : @http.Request, slug : String) -> Resp {
  let viewer = match optional_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  let rows = app.pool.batched_query(
    "comments",
    comments_by_slug_batched,
    [viewer],
    [slug],
  )
  if rows.length() == 0 {
    return err_resp(404, "article not found")
  }
  let out = JsonOut::new()
  out.obj_start()
  out.key("comments")
  out.arr_start()
  for r in rows {
    match (r.get(1) : Int64?) {
      Some(_) => comment_raw(out, r)
      None => ()
    }
  }
  out.arr_end()
  out.obj_end()
  raw_json_resp(200, out.to_bytes())
}

///|
/// POST /api/articles/:slug/comments
async fn create_comment(
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
  match read_wrapper(body, "comment") {
    None => return err_resp(422, "invalid body")
    Some(m) =>
      match req_string(m, "body") {
        None => err_resp(422, "body is required")
        Some(cbody) => {
          let id = match article_id(app, slug) {
            Err(resp) => return resp
            Ok(id) => id
          }
          let row = app.pool.query_one(
            "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at, author_id) " +
            "SELECT c.id, c.body, " +
            comment_ts_created +
            ", " +
            comment_ts_updated +
            ", u.username, u.bio, u.image " +
            "FROM c JOIN users u ON u.id = c.author_id",
            params=[id, viewer, cbody],
          )
          let w : Map[String, Json] = Map([])
          w["comment"] = comment_json(
            row.get(0),
            row.get(2),
            row.get(3),
            row.get(1),
            row.get(4),
            row.get(5),
            row.get(6),
            false,
          )
          json_resp(201, Json::object(w))
        }
      }
  }
}

///|
/// DELETE /api/articles/:slug/comments/:id
async fn delete_comment(
  app : App,
  req : @http.Request,
  slug : String,
  id_str : String,
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  guard parse_uint(id_str[:]) is Some(id) else {
    return err_resp(404, "comment not found")
  }
  let row = app.pool.query_opt(
    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
    params=[id, slug],
  )
  match row {
    None => err_resp(404, "comment not found")
    Some(r) => {
      let author_id : Int64 = r.get(0)
      if author_id != viewer {
        return err_resp(403, "not the author")
      }
      ignore(
        app.pool.execute("DELETE FROM comments WHERE id = $1", params=[id]),
      )
      no_content()
    }
  }
}
