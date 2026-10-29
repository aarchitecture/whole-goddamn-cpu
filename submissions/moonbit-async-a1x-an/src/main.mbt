// Conduit server entry point: config from env, private pgpool per process,
// one SO_REUSEPORT listener per worker (start.sh forks N copies of this
// binary on the same HOST:PORT).

///|
struct DbUrl {
  host : String
  port : Int32
  user : String
  password : String?
  dbname : String
}

///|
suberror ConfigError {
  Bad(String)
}

///|
impl Show for ConfigError with fn output(self, logger) {
  match self {
    Bad(msg) => logger.write_string(msg)
  }
}

///|
fn env_or(name : String, fallback : String) -> String {
  match @env.get_env_var(name) {
    Some(v) if v != "" => v
    _ => fallback
  }
}

///|
/// Parse postgres://user[:password]@host[:port]/dbname[?params] with
/// percent-decoding of userinfo and dbname.
fn parse_database_url(url : String) -> DbUrl raise ConfigError {
  let rest = match url.find("://") {
    Some(i) => {
      let scheme = url[:i].to_owned()
      if scheme != "postgres" && scheme != "postgresql" {
        raise ConfigError::Bad("DATABASE_URL: unsupported scheme")
      }
      url[i + 3:].to_owned()
    }
    None => url
  }
  let (authority, path) = match rest.find("/") {
    Some(i) => (rest[:i].to_owned(), rest[i + 1:].to_owned())
    None => (rest, "")
  }
  let dbname_raw = match path.find("?") {
    Some(i) => path[:i].to_owned()
    None => path
  }
  let (userinfo, hostport) = match authority.rev_find("@") {
    Some(i) => (authority[:i].to_owned(), authority[i + 1:].to_owned())
    None => ("", authority)
  }
  let (user, password) = match userinfo.find(":") {
    Some(i) => {
      let u = percent_decode(userinfo[:i].to_owned(), plus_space=false)
      let pw = percent_decode(userinfo[i + 1:].to_owned(), plus_space=false)
      guard pw is Some(_) || userinfo[i + 1:].length() == 0 else {
        raise ConfigError::Bad("DATABASE_URL: malformed password encoding")
      }
      (u, pw)
    }
    None => (percent_decode(userinfo, plus_space=false), None)
  }
  guard user is Some(user) && user != "" else {
    raise ConfigError::Bad("DATABASE_URL: bad or missing user")
  }
  let (host, port) = match hostport.rev_find(":") {
    Some(i) => {
      let p = hostport[i + 1:]
      match parse_uint(p) {
        Some(n) if n > 0 && n <= 65535 => (hostport[:i].to_owned(), n.to_int())
        _ => raise ConfigError::Bad("DATABASE_URL: bad port")
      }
    }
    None => (hostport, 5432)
  }
  guard host != "" else { raise ConfigError::Bad("DATABASE_URL: missing host") }
  let dbname = match percent_decode(dbname_raw, plus_space=false) {
    Some(d) if d != "" => d
    _ =>
      match path.find("?") {
        // no path at all: fall back to the user name like libpq
        _ if dbname_raw == "" => user
        _ => raise ConfigError::Bad("DATABASE_URL: bad dbname")
      }
  }
  { host, port, user, password, dbname, }
}

///|
async fn main {
  match @env.get_env_var("CONDUIT_BCRYPTD_PORT_FILE") {
    Some(port_file) if port_file != "" => {
      let wait_ms = match parse_uint(env_or("BCRYPT_WAIT_MS", "200")[:]) {
        Some(n) if n <= 1000 => n.to_int()
        _ => abort("BCRYPT_WAIT_MS must be in 0..1000")
      }
      run_bcryptd(port_file, wait_ms)
      return
    }
    _ => ()
  }
  let db_url = match @env.get_env_var("DATABASE_URL") {
    Some(v) if v != "" => v
    _ => abort("DATABASE_URL is required")
  }
  let secret = match @env.get_env_var("JWT_SECRET") {
    Some(v) if v != "" => v
    _ => abort("JWT_SECRET is required")
  }
  let host = env_or("HOST", "127.0.0.1")
  let port = match parse_uint(env_or("PORT", "3000")[:]) {
    Some(p) if p > 0 && p <= 65535 => p.to_int()
    _ => abort("PORT must be 1-65535")
  }
  let pool_size = match parse_uint(env_or("DB_POOL_SIZE", "2")[:]) {
    Some(n) if n >= 1 && n <= 95 => n.to_int()
    _ => abort("DB_POOL_SIZE must be in 1..95")
  }
  let batch_size = match parse_uint(env_or("DB_BATCH_CONNS", "1")[:]) {
    Some(n) if n >= 1 && n <= 95 && n.to_int() + pool_size <= 95 => n.to_int()
    _ => abort("DB_BATCH_CONNS must be in 1..95 with DB_POOL_SIZE + DB_BATCH_CONNS <= 95")
  }
  let db = parse_database_url(db_url) catch {
    e => abort("invalid DATABASE_URL: \{e}")
  }
  let batch_wait_ms = match parse_uint(env_or("DB_BATCH_WAIT_MS", "4")[:]) {
    Some(n) if n <= 50 => n.to_int()
    _ => abort("DB_BATCH_WAIT_MS must be in 0..50")
  }
  let pool_cfg = @pgpool.PoolConfig::PoolConfig(
    pool_size,
    batch=batch_size,
    batch_wait_ms~,
  ) catch {
    e => abort("invalid pool config: \{e.message()}")
  }
  let cfg = @pgpool.Config::Config(
    [@pgpool.ConnectionTarget::ConnectionTarget(host=db.host, port=db.port)],
    user=db.user,
    dbname=db.dbname,
    password?=db.password,
    pool=pool_cfg,
  ) catch {
    e => abort("invalid database config: \{e.message()}")
  }
  let (pool, executor) = @pgpool.Pool::create(cfg)
  let app : App = { pool, key: jwt_key(secret), }
  let addr = @socket.Addr::parse("\{host}:\{port}") catch {
    e => abort("bad listen address \{host}:\{port}: \{e}")
  }
  @async.with_task_group(group => {
    // Executor failure is fatal: let it propagate through the task group.
    group.spawn_bg(() => executor.run())
    match @env.get_env_var("CONDUIT_BCRYPTD_ADDR") {
      Some(a) if a != "" => bcrypt_connect(group, a)
      _ => ()
    }
    pool.ready()
    // Real health check before accepting traffic.
    ignore(pool.query_one("SELECT 1"))
    let server = @socket.TcpServer(addr, reuse_port_lb=true)
    println(
      "conduit (moonbit) listening on http://\{addr}, pool \{pool_size} + \{batch_size} batch, batch wait \{batch_wait_ms} ms",
    )
    for ;; {
      let (tcp, _) = server.accept()
      group.spawn_bg(allow_failure=true, () => serve_conn(app, tcp))
    }
  })
}
