///|
/// DB-only probe handler for the generated wasi:http/handler stub.
/// GET /health -> 200 {"status":"ok"}
/// GET /db     -> run the fixed read-only hard assertions against PROBE_PG_*;
///                200 {"status":"ok","pid":..} only when every assertion
///                holds, else 500 {"status":"fail"} with no secret values.
/// Copied into gen/interface/wasi/http/handler by build.sh.

///|
fn to_bytes(s : String) -> FixedArray[Byte] {
  let b = @utf8.encode(s)
  FixedArray::makei(b.length(), fn(i) { b[i] })
}

///|
async fn respond(
  group : @async-core.TaskGroup[Unit],
  status : UInt,
  body : FixedArray[Byte],
) -> @types.Response {
  let fields = match @types.Fields::from_list([
    ("content-type", to_bytes("application/json")),
    ("content-length", to_bytes(body.length().to_string())),
  ]) {
    Ok(f) => f
    Err(_) => @types.Fields::fields()
  }
  let (stream, sink) = @async-core.Stream::new(capacity=262144)
  ignore(sink.write_all(body[:]))
  ignore(sink.close())
  let (resp, fut) = @types.Response::new(
    fields, Some(stream), @async-core.Future::ready(Ok(None)),
  )
  ignore(resp.set_status_code(status))
  group.spawn_bg(fn() { ignore(fut.get()) }, no_wait=true, allow_failure=true)
  group.add_defer(async fn() nocancel {
    @async-core.protect_from_cancel(async fn() { fut.drop() })
  })
  resp
}

///|
suberror ProbeError {
  Config
  Assert
} derive(Show)

///|
fn cfg() -> @pgpool.Config raise {
  fn env(n : String, d : String) -> String {
    match @platform.get_env_var(n) {
      Some(v) => v
      None => d
    }
  }
  let port_str = @platform.get_env_var("PROBE_PG_PORT")
  let port = match port_str {
    None => 5432
    Some(s) =>
      match (try Some(@string.parse_int(s)) catch { _ => None }) {
        Some(p) => if p >= 1 && p <= 65535 { p } else { raise ProbeError::Config }
        None => raise ProbeError::Config
      }
  }
  @pgpool.Config::new(
    env("PROBE_PG_HOST", "127.0.0.1"),
    port,
    env("PROBE_PG_USER", "postgres"),
    @platform.get_env_var("PROBE_PG_PASSWORD"),
    env("PROBE_PG_DB", "postgres"),
  )
}

///|
let pool : Ref[@pgpool.Pool?] = Ref(None)

///|
let step : Ref[Int] = Ref(0)

///|
fn shared_pool() -> @pgpool.Pool raise {
  match pool.val {
    Some(p) => p
    None => {
      let p = @pgpool.Pool::new(cfg())
      pool.val = Some(p)
      p
    }
  }
}

///|
fn fail(cond : Bool) -> Unit raise ProbeError {
  if !cond { raise ProbeError::Assert }
}

///|
/// Exact lead-authored SQL only; no other queries.
async fn assertions() -> Int64 raise {
  let p = shared_pool()
  step.val = 1
  // SELECT 1 AS n
  let r1 = p.query_one("SELECT 1 AS n") catch { e => raise e }
  fail((r1.get(0) : Int64) == 1L)
  // typed params, full 5-column row (repeated variants below)
  let tags = ["", "comma,value", "brace{value}", "quote\"slash\\", "NULL"]
  let tags2 = ["{", "}", "tab\there", "nl\nhere", "null"]
  let none_str : String? = None
  step.val = 2
  let r2 = try p.query_opt(
    "SELECT $1::bigint AS n,$2::text AS label,$3::boolean AS flag,$4::text[] AS tags,$5::text AS nullable",
    params=[9007199254740993L, "héllo€", true, tags, none_str],
  ) catch { _ => raise ProbeError::Assert }
  match r2 {
    Some(r) => {
      fail((r.get(0) : Int64) == 9007199254740993L)
      fail((r.get(1) : String) == "héllo€")
      fail((r.get(2) : Bool))
      fail((r.get(3) : Array[String]) == tags)
      fail((r.get(4) : String?) == None)
    }
    None => raise ProbeError::Assert
  }
  // second variant: SomeString nullable + empty array + false flag
  let some_str : String? = Some("nullable-value")
  let empty_tags : Array[String] = []
  step.val = 3
  let r3 = try p.query_opt(
    "SELECT $1::bigint AS n,$2::text AS label,$3::boolean AS flag,$4::text[] AS tags,$5::text AS nullable",
    params=[9007199254740993L, "label", false, empty_tags, some_str],
  ) catch { _ => raise ProbeError::Assert }
  match r3 {
    Some(r) => {
      fail((r.get(0) : Int64) == 9007199254740993L)
      fail((r.get(1) : String) == "label")
      fail(!(r.get(2) : Bool))
      fail((r.get(3) : Array[String]) == empty_tags)
      fail((r.get(4) : String?) == some_str)
    }
    None => raise ProbeError::Assert
  }
  let escaped = p.query_one(
    "SELECT $1::bigint AS n,$2::text AS label,$3::boolean AS flag,$4::text[] AS tags,$5::text AS nullable",
    params=[9007199254740993L, "escaped", false, tags2, none_str],
  )
  fail((escaped.get(3) : Array[String]) == tags2)
  // explicit typed param OIDs path
  step.val = 4
  let r4 = try p.query_typed_all(
    "SELECT $1::bigint AS n,$2::text AS label,$3::boolean AS flag,$4::text[] AS tags,$5::text AS nullable",
    [@client.Type::int8(), @client.Type::text(), @client.Type::text(), @client.Type::text(), @client.Type::text()],
    params=[9007199254740993L, "typed", true, tags, none_str],
  ) catch { _ => raise ProbeError::Assert }
  match r4.length() {
    1 => fail((r4[0].get(0) : Int64) == 9007199254740993L)
    _ => raise ProbeError::Assert
  }
  // zero-row opt -> None
  step.val = 5
  let rz = try p.query_opt("SELECT 1 AS n WHERE FALSE") catch { _ => raise ProbeError::Assert }
  fail(rz is None)
  // division error: SQLSTATE 22012 via Database(d).code
  step.val = 6
  let derr = try Some(p.query_one("SELECT 1 / 0")) catch {
    @client.ClientError::Database(d) => {
      fail(d.code == Some("22012"))
      None
    }
    _ => raise ProbeError::Assert
  }
  match derr {
    None => ()
    Some(_) => raise ProbeError::Assert
  }
  // connection still usable after the error
  step.val = 7
  let r5 = p.query_one("SELECT 1 AS n") catch { e => raise e }
  fail((r5.get(0) : Int64) == 1L)
  // division inside transaction -> rollback, SELECT 1 still works after
  step.val = 8
  let transaction_failed = try {
    p.with_transaction(async fn(tx) -> Unit raise {
      ignore(tx.query_one("SELECT 1 / 0"))
    })
    false
  } catch {
    @client.ClientError::Database(d) => d.code == Some("22012")
    _ => false
  }
  fail(transaction_failed)
  step.val = 9
  let r6 = p.query_one("SELECT 1 AS n") catch { e => raise e }
  fail((r6.get(0) : Int64) == 1L)
  // backend pid
  step.val = 10
  let rp = p.query_one("SELECT pg_backend_pid()") catch { e => raise e }
  (rp.get(0) : Int64)
}

///|
fn err_cat(e : Error) -> String {
  match e {
    @client.ClientError::Io(s) => "io:" + s
    @client.ClientError::Protocol(s) => "protocol:" + s
    @client.ClientError::Decode(s) => "decode:" + s
    @client.ClientError::Database(_) => "db"
    ProbeError::Assert => "assert"
    ProbeError::Config => "config"
    _ => "other"
  }
}

///|
pub async fn handle(
  request : @types.Request,
  background_group : @async-core.TaskGroup[Unit],
) -> Result[@types.Response, @types.ErrorCode] {
  let method = request.get_method()
  let path = match request.get_path_with_query() {
    Some(p) => p.split("?").next().unwrap_or("/")
    None => "/"
  }
  match (method, path) {
    (@types.Method::Get, "/health") => {
      request.drop()
      Ok(respond(background_group, 200, to_bytes("{\"status\":\"ok\"}")))
    }
    (@types.Method::Get, "/db") => {
      request.drop()
      match (try Ok(assertions()) catch { e => Err(e) }) {
        Ok(pid) => {
          let j = Json::object({ "status": Json::string("ok"), "pid": Json::number(pid.to_double()) })
          Ok(respond(background_group, 200, to_bytes(j.stringify())))
        }
        Err(e) => {
          let j = Json::object({
            "status": Json::string("fail"),
            "category": Json::string(err_cat(e)),
            "step": Json::number(step.val.to_double()),
          })
          Ok(respond(background_group, 500, to_bytes(j.stringify())))
        }
      }
    }
    _ => {
      request.drop()
      Ok(respond(background_group, 404, to_bytes("{\"error\":\"not found\"}")))
    }
  }
}
