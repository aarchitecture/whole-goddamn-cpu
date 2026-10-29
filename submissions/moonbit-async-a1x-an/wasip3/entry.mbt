///|
/// WASI http/handler entry adapter for the full Conduit API. Maps a WASI
/// request to the facade, lazily consumes the body, dispatches through the
/// unchanged business handlers, and serializes Resp as JSON.

///|
const MAX_BODY : Int = 1048576

///|
async fn pw_yield() -> Unit { () }

///|
async fn bc_digest(password : BytesView, salt : BytesView, cost : Int) -> Bytes {
  bc_bcrypt_hash_raw(password, salt, cost)
}

///|
suberror BodyTooLarge

///|
let app_ref : Ref[App?] = Ref(None)

///|
let ready : Ref[Bool] = Ref(false)

///|
fn to_bytes(s : String) -> FixedArray[Byte] {
  let b = @utf8.encode(s)
  FixedArray::makei(b.length(), fn(i) { b[i] })
}

///|
fn bytes_to_fixed(b : Bytes) -> FixedArray[Byte] {
  FixedArray::makei(b.length(), fn(i) { b[i] })
}

///|
/// Synchronous app construction: parse config, create pool (lazy connect),
/// publish BEFORE the first await so an init failure never orphans a pool.
fn get_app() -> App raise {
  match app_ref.val {
    Some(a) => a
    None => {
      let db_url = match @env.get_env_var("DATABASE_URL") {
        Some(v) if v != "" => v
        _ => raise ConfigError::Bad("DATABASE_URL is required")
      }
      let secret = match @env.get_env_var("JWT_SECRET") {
        Some(v) if v != "" => v
        _ => raise ConfigError::Bad("JWT_SECRET is required")
      }
      let db = parse_database_url(db_url)
      let cfg = @pgpool.Config::new(db.host, db.port, db.user, db.password, db.dbname)
      let a : App = { pool: @pgpool.Pool::new(cfg), key: jwt_key(secret) }
      app_ref.val = Some(a)
      a
    }
  }
}

///|
/// One-time per-instance health: single SELECT 1; ready only after success.
async fn initialize(app : App) -> Unit raise {
  if !ready.val {
    ignore(app.pool.query_one("SELECT 1 AS n"))
    ready.val = true
  }
}

///|
/// Read at most MAX_BODY bytes, plus one byte to detect overflow.
async fn read_body(stream : @async-core.Stream[Byte]) -> Bytes raise {
  let out : Array[Byte] = []
  let mut done = false
  let mut over = false
  while !done && !over {
    match stream.read(65536) {
      Some(chunk) => {
        let room = MAX_BODY + 1 - out.length()
        let n = if chunk.length() < room { chunk.length() } else { room }
        for i in 0..<n { out.push(chunk[i]) }
        if out.length() > MAX_BODY { over = true }
      }
      None => done = true
    }
  }
  if over {
    raise BodyTooLarge::BodyTooLarge
  }
  Bytes::makei(out.length(), fn(i) { out[i] })
}

///|
fn body_connection(
  request : @types.Request,
  consumed : Ref[Bool],
  group : @async-core.TaskGroup[Unit],
) -> @http.ServerConnection {
  @http.ServerConnection::new(async fn() -> Bytes raise {
    let (stream, trailers) = @types.Request::consume_body(
      request, @async-core.Future::ready(Ok(())),
    )
    consumed.val = true
    let stream_open = Ref(true)
    let trailers_open = Ref(true)
    group.add_defer(async fn() nocancel {
      @async-core.protect_from_cancel(async fn() {
        if stream_open.val {
          stream.drop()
          stream_open.val = false
        }
        if trailers_open.val {
          trailers.drop()
          trailers_open.val = false
        }
      })
    })
    let bytes = try Ok(read_body(stream)) catch { e => Err(e) }
    @async-core.protect_from_cancel(async fn() {
      stream.drop()
      stream_open.val = false
    })
    match bytes {
      Err(e) => {
        // In particular, overflow must not wait for trailers or client EOF.
        @async-core.protect_from_cancel(async fn() {
          trailers.drop()
          trailers_open.val = false
        })
        raise e
      }
      Ok(body) => {
        let complete = match trailers.get() {
          Ok(Some(fields)) => {
            fields.drop()
            true
          }
          Ok(None) => true
          Err(_) => false
        }
        @async-core.protect_from_cancel(async fn() {
          trailers.drop()
          trailers_open.val = false
        })
        if !complete { raise @types.ErrorCode::InternalError(None) }
        body
      }
    }
  })
}

///|
/// Build the facade Request from the owned WASI request. Headers are
/// UTF-8-decoded and lowercased; the owned Fields resource is dropped.
fn facade_request(req : @types.Request) -> @http.Request raise {
  let meth = match req.get_method() {
    @types.Method::Get => @http.Method::Get
    @types.Method::Head => @http.Method::Head
    @types.Method::Post => @http.Method::Post
    @types.Method::Put => @http.Method::Put
    @types.Method::Delete => @http.Method::Delete
    _ => @http.Method::Other
  }
  let path = match req.get_path_with_query() {
    Some(p) => p
    None => "/"
  }
  let headers : @http.Headers = Map([])
  let fields = req.get_headers()
  defer fields.drop()
  for e in fields.copy_all() {
    let bytes = Bytes::makei(e.1.length(), fn(i) { e.1[i] })
    let val = @utf8.decode(bytes[:]) catch { _ => "" }
    headers[e.0.to_lower()] = val
  }
  @http.Request::new(meth, path, headers)
}

///|
async fn respond(
  group : @async-core.TaskGroup[Unit],
  code : Int,
  ctype : String,
  body : FixedArray[Byte],
  head_only : Bool,
) -> @types.Response {
  let fields = match @types.Fields::from_list([
    ("content-type", to_bytes(ctype)),
    ("content-length", to_bytes(body.length().to_string())),
  ]) {
    Ok(f) => f
    Err(_) => @types.Fields::fields()
  }
  let stream = if head_only || code == 204 {
    None
  } else {
    let (stream, sink) = @async-core.Stream::new(capacity=body.length() + 65536)
    ignore(sink.write_all(body[:]))
    ignore(sink.close())
    Some(stream)
  }
  let (resp, fut) = @types.Response::new(fields, stream, @async-core.Future::ready(Ok(None)))
  ignore(resp.set_status_code(code.to_uint()))
  group.spawn_bg(fn() { ignore(fut.get()) }, no_wait=true, allow_failure=true)
  group.add_defer(async fn() nocancel {
    @async-core.protect_from_cancel(async fn() { fut.drop() })
  })
  resp
}

///|
pub async fn handle(
  request : @types.Request,
  background_group : @async-core.TaskGroup[Unit],
) -> Result[@types.Response, @types.ErrorCode] {
  let consumed = Ref(false)
  background_group.add_defer(async fn() nocancel {
    if !consumed.val {
      @async-core.protect_from_cancel(async fn() { request.drop() })
    }
  })
  let head_only = request.get_method() is @types.Method::Head
  let resp = try {
    let req = facade_request(request)
    let conn = body_connection(request, consumed, background_group)
    let app = get_app()
    initialize(app)
    dispatch(app, req, conn)
  } catch {
    BodyTooLarge::BodyTooLarge => err_resp(413, "payload too large")
    _ => err_resp(500, "internal error")
  }
  let body : FixedArray[Byte] = match resp.raw {
    Some(bytes) => bytes_to_fixed(bytes)
    None =>
      match resp.body {
        Some(j) => to_bytes(j.stringify())
        None => to_bytes("")
      }
  }
  Ok(respond(background_group, resp.code, "application/json", body, head_only))
}
