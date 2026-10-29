// Users, auth, profiles and tags handlers.

///|
fn opt_json(s : String?) -> Json {
  match s {
    Some(v) => Json::string(v)
    None => Json::null()
  }
}

///|
fn user_json(
  username : String,
  email : String,
  bio : String?,
  image : String?,
  token : String,
) -> Json {
  let u : Map[String, Json] = Map([])
  u["email"] = Json::string(email)
  u["token"] = Json::string(token)
  u["username"] = Json::string(username)
  u["bio"] = opt_json(bio)
  u["image"] = opt_json(image)
  Json::object(u)
}

///|
fn wrap_user(u : Json) -> Json {
  let w : Map[String, Json] = Map([])
  w["user"] = u
  Json::object(w)
}

///|
fn profile_json(
  username : String,
  bio : String?,
  image : String?,
  following : Bool,
) -> Json {
  let p : Map[String, Json] = Map([])
  p["username"] = Json::string(username)
  p["bio"] = opt_json(bio)
  p["image"] = opt_json(image)
  p["following"] = Json::boolean(following)
  Json::object(p)
}

///|
fn wrap_profile(p : Json) -> Json {
  let w : Map[String, Json] = Map([])
  w["profile"] = p
  Json::object(w)
}

///|
/// POST /api/users
async fn register(app : App, conn : @http.ServerConnection) -> Resp {
  let body = conn.read_all().text()
  match read_wrapper(body, "user") {
    None => return err_resp(422, "invalid body")
    Some(m) => {
      let username = req_string(m, "username")
      let email = req_string(m, "email")
      let password = req_string(m, "password")
      match (username, email, password) {
        (Some(u), Some(e), Some(p)) => {
          guard hash_password(p) is Some(hash) else {
            return err_resp(422, "password is too long")
          }
          let row = app.pool.query_opt(
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
            params=[u, e, hash],
          ) catch {
            e =>
              if is_unique_violation(e) {
                return err_resp(422, "username or email is already taken")
              } else {
                raise e
              }
          }
          match row {
            Some(r) => {
              let id : Int64 = r.get(0)
              let u = user_json(
                r.get(1),
                r.get(2),
                r.get(3),
                r.get(4),
                issue_token(app.key, id),
              )
              json_resp(201, wrap_user(u))
            }
            None => err_resp(500, "internal error")
          }
        }
        _ => err_resp(422, "username, email and password are required")
      }
    }
  }
}

///|
/// POST /api/users/login
async fn login(app : App, conn : @http.ServerConnection) -> Resp {
  let body = conn.read_all().text()
  match read_wrapper(body, "user") {
    None => return err_resp(422, "invalid body")
    Some(m) => {
      let email = req_string(m, "email")
      let password = req_string(m, "password")
      match (email, password) {
        (Some(email), Some(password)) => {
          let row = app.pool.query_opt(
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
            params=[email],
          )
          match row {
            None => err_resp(401, "invalid email or password")
            Some(r) => {
              let hash : String = r.get(5)
              if !check_password(password, hash) {
                return err_resp(401, "invalid email or password")
              }
              let id : Int64 = r.get(0)
              let u = user_json(
                r.get(1),
                r.get(2),
                r.get(3),
                r.get(4),
                issue_token(app.key, id),
              )
              json_resp(200, wrap_user(u))
            }
          }
        }
        _ => err_resp(422, "email and password are required")
      }
    }
  }
}

///|
/// Required-auth wrapper: 401 unless a valid token is presented.
fn require_auth(
  app : App,
  req : @http.Request,
) -> Result[(Int64, String), Resp] {
  let (id, token, _) = auth(app, req)
  if id == 0 {
    Err(err_resp(401, "unauthorized"))
  } else {
    Ok((id, token))
  }
}

///|
/// Optional-auth wrapper: anonymous without a header, 401 on a present but
/// invalid token.
fn optional_auth(app : App, req : @http.Request) -> Result[Int64, Resp] {
  let (id, _, present) = auth(app, req)
  if present && id == 0 {
    Err(err_resp(401, "unauthorized"))
  } else {
    Ok(id)
  }
}

///|
/// GET /api/user
async fn current_user(app : App, req : @http.Request) -> Resp {
  let (viewer, token) = match require_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  let row = app.pool.query_opt(
    "SELECT id, username, email, bio, image FROM users WHERE id = $1",
    params=[viewer],
  )
  match row {
    None => err_resp(401, "unauthorized")
    Some(r) =>
      json_resp(
        200,
        wrap_user(user_json(r.get(1), r.get(2), r.get(3), r.get(4), token)),
      )
  }
}

///|
/// PUT /api/user
async fn update_user(
  app : App,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Resp {
  let (viewer, token) = match require_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  let body = conn.read_all().text()
  match read_wrapper(body, "user") {
    None => return err_resp(422, "invalid body")
    Some(m) => {
      let email = opt_string(m, "email", non_empty=true)
      let username = opt_string(m, "username", non_empty=true)
      let password = opt_string(m, "password", non_empty=true)
      let bio = opt_string(m, "bio", non_empty=false)
      let image = opt_string(m, "image", non_empty=false)
      if email is Err(_) ||
        username is Err(_) ||
        password is Err(_) ||
        bio is Err(_) ||
        image is Err(_) {
        return err_resp(422, "invalid user fields")
      }
      let hash : String? = match password.unwrap() {
        Some(p) =>
          match hash_password(p) {
            Some(h) => Some(h)
            None => return err_resp(422, "password is too long")
          }
        None => None
      }
      let row = app.pool.query_opt(
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
        params=[
          viewer,
          email.unwrap(),
          username.unwrap(),
          hash,
          bio.unwrap(),
          image.unwrap(),
        ],
      ) catch {
        e =>
          if is_unique_violation(e) {
            return err_resp(422, "username or email is already taken")
          } else {
            raise e
          }
      }
      match row {
        None => err_resp(401, "unauthorized")
        Some(r) =>
          json_resp(
            200,
            wrap_user(user_json(r.get(1), r.get(2), r.get(3), r.get(4), token)),
          )
      }
    }
  }
}

///|
/// GET /api/profiles/:username
async fn get_profile(app : App, req : @http.Request, username : String) -> Resp {
  let viewer = match optional_auth(app, req) {
    Err(resp) => return resp
    Ok(v) => v
  }
  let rows = app.pool.batched_query(
    "profile",
    profile_batched,
    [viewer],
    [username],
  )
  match rows.get(0) {
    None => err_resp(404, "profile not found")
    Some(r) => {
      let out = JsonOut::new()
      out.obj_start()
      out.key("profile")
      out.obj_start()
      out.key("username")
      out.str_raw(r.get_raw(1))
      out.key("bio")
      out.str_raw(r.get_raw(2))
      out.key("image")
      out.str_raw(r.get_raw(3))
      out.key("following")
      out.bool(r.get(4))
      out.obj_end()
      out.obj_end()
      raw_json_resp(200, out.to_bytes())
    }
  }
}

///|
/// POST/DELETE /api/profiles/:username/follow
async fn follow(
  app : App,
  req : @http.Request,
  username : String,
  follow : Bool,
) -> Resp {
  let viewer = match require_auth(app, req) {
    Err(resp) => return resp
    Ok((v, _)) => v
  }
  let row = app.pool.query_opt(
    "SELECT id, username, bio, image FROM users WHERE username = $1",
    params=[username],
  )
  match row {
    None => err_resp(404, "profile not found")
    Some(r) => {
      let id : Int64 = r.get(0)
      if follow {
        ignore(
          app.pool.execute(
            "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            params=[viewer, id],
          ),
        )
      } else {
        ignore(
          app.pool.execute(
            "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2",
            params=[viewer, id],
          ),
        )
      }
      json_resp(
        200,
        wrap_profile(profile_json(r.get(1), r.get(2), r.get(3), follow)),
      )
    }
  }
}

///|
/// GET /api/tags
async fn list_tags(app : App) -> Resp {
  let rows = app.pool.batched_query("tags", tags_batched, [0L], [])
  if rows.length() > 0 {
    let out = JsonOut::new()
    out.obj_start()
    out.key("tags")
    out.text_array(rows[0].get_raw(0))
    out.obj_end()
    return raw_json_resp(200, out.to_bytes())
  }
  raw_json_resp(200, @utf8.encode("{\"tags\":[]}"))
}
