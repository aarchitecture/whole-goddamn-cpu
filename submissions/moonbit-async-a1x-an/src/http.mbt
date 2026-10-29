// HTTP/1.1 keep-alive serving on top of @socket.TcpServer, plus request
// routing.

///|
struct App {
  pool : @pgpool.Pool
  key : @jwt.Keyed
}

///|
async fn pw_yield() -> Unit {
  @async.pause()
}

///|
struct Resp {
  code : Int32
  body : Json?
  raw : Bytes?
}

///|
fn json_resp(code : Int32, body : Json) -> Resp {
  { code, body: Some(body), raw: None, }
}

///|
fn raw_json_resp(code : Int32, body : Bytes) -> Resp {
  { code, body: None, raw: Some(body), }
}

///|
fn err_resp(code : Int32, msg : String) -> Resp {
  let inner : Map[String, Json] = Map([])
  inner["body"] = Json::array([Json::string(msg)])
  let outer : Map[String, Json] = Map([])
  outer["errors"] = Json::object(inner)
  json_resp(code, Json::object(outer))
}

///|
fn no_content() -> Resp {
  { code: 204, body: None, raw: None, }
}

///|
fn reason(code : Int32) -> String {
  match code {
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    411 => "Length Required"
    413 => "Payload Too Large"
    422 => "Unprocessable Entity"
    _ => "Internal Server Error"
  }
}

///|
fn is_unique_violation(e : Error) -> Bool {
  match e {
    @client.ClientError::Database(d) => d.code == Some("23505")
    _ => false
  }
}

///|
/// Inspect the Authorization header. Returns (user_id, token, present);
/// user_id 0 means no valid token.
fn auth(app : App, req : @http.Request) -> (Int64, String, Bool) {
  match req.headers.get("authorization") {
    None => (0, "", false)
    Some(h) =>
      match h.strip_prefix("Token ") {
        Some(tok) =>
          (verify_token(app.key, tok), tok.to_owned(), true)
        None => (0, "", true)
      }
  }
}

///|
/// Write a JSON response (UTF-8 byte Content-Length) or an empty 204.
fn response_bytes(code : Int32, head_only : Bool, close : Bool, body : Bytes) -> Bytes {
  let head =
    "HTTP/1.1 \{code} \{reason(code)}\r\n" +
    "Content-Type: application/json\r\n" +
    (if close { "Connection: close\r\n" } else { "" }) +
    "Content-Length: \{body.length()}\r\n\r\n"
  let out = @buffer.Buffer(size_hint=head.length() + body.length())
  out.write_string_utf8(head)
  if !head_only && body.length() > 0 { out.write_bytesview(body[:]) }
  out.to_bytes()
}

///|
async fn send_resp(
  tcp : @socket.Tcp,
  head_only : Bool,
  close : Bool,
  resp : Resp,
) -> Unit {
  let body = match resp.raw {
    Some(bytes) => bytes
    None =>
      match resp.body {
        Some(j) => @utf8.encode(j.stringify())
        None => b""
      }
  }
  tcp.write(response_bytes(resp.code, head_only, close, body))
}

///|
/// Keep-alive loop for one TCP connection: sequential requests per
/// connection, idle read timeout 75 s, honors `Connection: close`.
async fn serve_conn(app : App, tcp : @socket.Tcp) -> Unit {
  defer tcp.close()
  let reader = ConnReader::new(tcp)
  let last = Ref(@env.now())
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        let now = @env.now()
        let idle = if now > last.val { (now - last.val).to_int() } else { 0 }
        if idle >= 75000 {
          raise IdleTimeout
        }
        @async.sleep(75000 - idle)
      }
    })
    for ;; {
      let next = reader.next() catch { _ => None }
      match next {
        None => break
        Some(ReqBad(code, msg)) => {
          send_resp(tcp, false, true, err_resp(code, msg)) catch {
            _ => ()
          }
          break
        }
        Some(ReqOk(req, body)) => {
          last.val = @env.now()
          let close = match req.headers.get("connection") {
            Some(v) => v.to_lower() == "close"
            None => false
          }
          let conn = @http.ServerConnection::new(fn() { body })
          let resp = dispatch(app, req, conn) catch {
            e => {
              println("handler error on \{req.path}: \{e}")
              err_resp(500, "internal error")
            }
          }
          send_resp(tcp, req.meth is Head, close, resp) catch {
            _ => break
          }
          last.val = @env.now()
          if close {
            break
          }
        }
      }
    }
  }) catch {
    _ => ()
  }
}

///|
suberror IdleTimeout

///|
async fn dispatch(
  app : App,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Resp {
  match split_target(req.path) {
    None => return err_resp(404, "not found")
    Some((segs, params)) =>
      match (req.meth, segs) {
        (Post, ["api", "users"]) => register(app, conn)
        (Post, ["api", "users", "login"]) => login(app, conn)
        (Get | Head, ["api", "user"]) => current_user(app, req)
        (Put, ["api", "user"]) => update_user(app, req, conn)
        (Get | Head, ["api", "profiles", username]) =>
          get_profile(app, req, username)
        (Post, ["api", "profiles", username, "follow"]) =>
          follow(app, req, username, true)
        (Delete, ["api", "profiles", username, "follow"]) =>
          follow(app, req, username, false)
        (Get | Head, ["api", "articles"]) => list_articles(app, req, params)
        (Get | Head, ["api", "articles", "feed"]) => feed(app, req, params)
        (Post, ["api", "articles"]) => create_article(app, req, conn)
        (Get | Head, ["api", "articles", slug]) => get_article(app, req, slug)
        (Put, ["api", "articles", slug]) => update_article(app, req, conn, slug)
        (Delete, ["api", "articles", slug]) => delete_article(app, req, slug)
        (Post, ["api", "articles", slug, "favorite"]) =>
          favorite(app, req, slug, true)
        (Delete, ["api", "articles", slug, "favorite"]) =>
          favorite(app, req, slug, false)
        (Get | Head, ["api", "articles", slug, "comments"]) =>
          list_comments(app, req, slug)
        (Post, ["api", "articles", slug, "comments"]) =>
          create_comment(app, req, conn, slug)
        (Delete, ["api", "articles", slug, "comments", id]) =>
          delete_comment(app, req, slug, id)
        (Get | Head, ["api", "tags"]) => list_tags(app)
        _ => err_resp(404, "not found")
      }
  }
}
