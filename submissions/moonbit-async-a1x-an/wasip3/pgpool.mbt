///|
/// WASI 0.3 PostgreSQL pool facade - mirrors the subset of the pinned
/// moonbit-community/postgres@0.1.3 pgpool API used by the unchanged business
/// files. One physical connection per Pool; callers serialize via
/// semaphore(1). Extended query protocol with a per-connection prepared
/// statement cache (Parse+Describe on misses, Bind+Execute on hits), TEXT
/// bind parameters, BINARY result formats. Wire bytes
/// come only from the pinned protocol/message/{frontend,backend} packages.
/// All group/deadline plumbing is INTERNAL - public signatures match the
/// native facade: Pool::query_one(sql, params~), with_transaction(cb).

///|
pub struct Config {
  host : String
  port : Int
  user : String
  password : String?
  dbname : String
}

///|
/// Transaction handle: exposes query methods bound to the ALREADY LEASED
/// connection; never touches the Pool or semaphore again. `scope` flips to
/// false when with_transaction returns, invalidating escaped handles.
pub struct Transaction {
  priv conn : @pgcore.Conn
  priv mut valid : Bool
}

///|
fn wasi_pg_io(
  sock : @sockets.TcpSocket,
  packets : @async-core.Stream[Bytes],
  out : @async-core.Sink[Bytes],
  recv : @async-core.Stream[Byte],
  send_done : @async-core.Future[Result[Unit, @sockets.ErrorCode]],
  recv_done : @async-core.Future[Result[Unit, @sockets.ErrorCode]],
  rand : (Int) -> Bytes?,
) -> @pgcore.PgIo {
  @pgcore.PgIo::new(
    async fn(packet : Bytes) {
      let ok = out.write_all([packet][:])
      if !ok { raise @pgcore.ClientError::Io("send stream closed") }
    },
    async fn() {
      recv.read(4096)
    },
    async fn() {
      ignore((try Some(sock.drop()) catch { _ => None }))
      ignore((try out.close() catch { _ => () }))
      ignore((try recv.drop() catch { _ => () }))
      ignore((try send_done.drop() catch { _ => () }))
      ignore((try recv_done.drop() catch { _ => () }))
    },
    () => out.is_open(),
    rand,
  )
}

///|
priv struct IntArrayParam { values : Array[Int64] }

impl @pgcore.ToSql for IntArrayParam with to_sql(self, buf) {
  buf.write_byte(123)
  let mut first = true
  for value in self.values {
    if !first { buf.write_byte(44) }
    first = false
    buf.write_byte(34)
    buf.write_bytesview(@proto.utf8_encode(value.to_string())[:])
    buf.write_byte(34)
  }
  buf.write_byte(125)
  @proto.IsNull::No
}

pub struct Pool {
  priv cfg : Config
  priv mut conn : @pgcore.Conn?
  priv sema : @async-core.Semaphore
}

///|
/// Public constructor for externally-created configs (record literal is
/// read-only across packages).
pub fn Config::new(
  host : String,
  port : Int,
  user : String,
  password : String?,
  dbname : String,
) -> Config {
  { host, port, user, password, dbname }
}

///|
/// Create a fresh pool for this config. Global ownership is the CALLER's job.
pub fn Pool::new(cfg : Config) -> Pool {
  { cfg, conn: None, sema: @async-core.Semaphore::Semaphore(1) }
}

///|
fn u8s(s : String) -> Bytes { @proto.utf8_encode(s) }

///|
fn deadline_ns() -> UInt64 { 5_000_000_000UL }

///|
fn arr(b : Bytes) -> Array[Byte] { Array::makei(b.length(), fn(i) { b[i] }) }

///|
/// Run op under a local task group with a monotonic-clock watchdog that
/// cancels it after the 5000ms deadline.
async fn[T] with_deadline(
  op : async () -> T raise,
) -> T raise {
  @async-core.with_task_group(async fn(lg) -> T raise {
    let t = lg.spawn(async fn() -> T raise { op() }, allow_failure=true)
    ignore(lg.spawn(async fn() -> Unit {
      @monotonic.wait_for(deadline_ns())
      t.cancel()
    }, no_wait=true, allow_failure=true))
    t.wait()
  })
}

///|
/// Read one backend frame from the persistent receive buffer. Socket chunks
/// may contain multiple frames or partial frames; unread bytes remain for the
/// next query. Declared lengths are guarded before body allocation.
async fn resolve_ipv4(host : String) -> (Byte, Byte, Byte, Byte)? raise @pgcore.ClientError {
  let parts = host.split(".")
  let nums : Array[Byte] = []
  let mut numeric = true
  for p in parts {
    match (try Some(@string.parse_int(p)) catch { _ => None }) {
      Some(n) => if n >= 0 && n <= 255 { nums.push(n.to_byte()) } else { numeric = false }
      None => { numeric = false }
    }
  }
  if numeric && nums.length() == 4 {
    return Some((nums[0], nums[1], nums[2], nums[3]))
  }
  match (try @name_lookup.resolve_addresses(host) catch {
    _ => raise @pgcore.ClientError::Io("resolve failed")
  }) {
    Ok(list) =>
      for a in list {
        match a {
          @sockets.IpAddress::Ipv4(v4) => return Some(v4)
          _ => ()
        }
      }
    Err(_) => ()
  }
  None
}

///|
/// TCP connect + persistent I/O + startup auth. trust / cleartext /
/// SCRAM-SHA-256 (fresh WASI CSPRNG nonce); MD5 rejected. TLS unsupported.
/// Partially acquired resources are cleaned up on any failure.
async fn connect(
  cfg : Config,
  owner : Ref[@pgcore.Conn?],
) -> @pgcore.Conn raise @pgcore.ClientError {
  if cfg.port < 1 || cfg.port > 65535 {
    raise @pgcore.ClientError::Protocol("invalid database port")
  }
  @async-core.with_task_group(async fn(group) -> @pgcore.Conn raise {
    let sock = match @sockets.TcpSocket::create(@sockets.IpAddressFamily::IPV4) {
      Ok(s) => s
      Err(_) => raise @pgcore.ClientError::Io("tcp-socket create")
    }
    let partial : Ref[@pgcore.Conn?] = Ref(None)
    let transferred = Ref(false)
    group.add_defer(async fn() nocancel {
      @async-core.protect_from_cancel(async fn() {
        if !transferred.val {
          match partial.val {
            Some(conn) => @pgcore.Conn::discard(conn)
            None => sock.drop()
          }
        }
      })
    })
    let ip = match resolve_ipv4(cfg.host) {
      Some(a) => a
      None => raise @pgcore.ClientError::Io("cannot resolve host")
    }
    match sock.connect(@sockets.IpSocketAddress::Ipv4(
      @sockets.Ipv4SocketAddress::{
        port: cfg.port.reinterpret_as_uint(),
        address: ip,
      },
    )) {
      Ok(_) => ()
      Err(_) => raise @pgcore.ClientError::Io("connect refused")
    }
    let (packets, out) : (
      @async-core.Stream[Bytes],
      @async-core.Sink[Bytes],
    ) = @async-core.Stream::new(capacity=4)
    // One canonical socket write per packet avoids the Nagle + delayed-ACK
    // stall; WASI sockets expose no TCP_NODELAY control.
    let send_stream = @async-core.Stream::produce(async fn(
      sink : @async-core.Sink[Byte],
    ) -> Unit {
      while true {
        match packets.read(1) {
          Some(batch) =>
            for packet in batch {
              let ok = try sink.write_all_bytes(packet[:]) catch { _ => false }
              if !ok {
                packets.drop()
                return
              }
            }
          None => return
        }
      }
    })
    let send_done = sock.send(send_stream)
    let (recv, recv_done) = sock.receive()
    let conn = @pgcore.Conn::new(wasi_pg_io(sock, packets, out, recv, send_done, recv_done, @platform.rand))
    partial.val = Some(conn)
    // The caller owns the connection even if cancellation wins the return race.
    owner.val = Some(conn)
    @pgcore.startup_auth(
      conn,
      @pgcore.Config::new(
        cfg.host,
        cfg.port,
        cfg.user,
        cfg.password,
        cfg.dbname,
      ),
    )
    transferred.val = true
    conn
  }) catch {
    e => raise @pgcore.map_error(e)
  }
}

///|
///|
/// Own the permit and connection before entering any cancellable operation.
async fn[T] with_connection(
  pool : Pool,
  body : async (@pgcore.Conn) -> T raise,
) -> T raise {
  @async-core.with_task_group(async fn(group) -> T raise {
    let acquired = Ref(false)
    let owner : Ref[@pgcore.Conn?] = Ref(None)
    group.add_defer(async fn() nocancel {
      let cancelled = @async-core.is_being_cancelled()
      @async-core.protect_from_cancel(async fn() {
        match owner.val {
          Some(conn) =>
            if cancelled || !conn.safe_to_reuse() {
              @pgcore.Conn::discard(conn)
              pool.conn = None
            }
          None => ()
        }
        if acquired.val {
          acquired.val = false
          pool.sema.release()
        }
      })
    })
    with_deadline(async fn() {
      pool.sema.acquire()
      acquired.val = true
    })
    let cached = match pool.conn {
      Some(conn) => {
        owner.val = Some(conn)
        if conn.safe_to_reuse() {
          Some(conn)
        } else {
          @async-core.protect_from_cancel(async fn() { @pgcore.Conn::discard(conn) })
          pool.conn = None
          owner.val = None
          None
        }
      }
      None => None
    }
    let conn = match cached {
      Some(conn) => conn
      None => {
        let conn = with_deadline(async fn() { connect(pool.cfg, owner) })
        pool.conn = Some(conn)
        conn
      }
    }
    body(conn)
  })
}

///|
/// Extended query: in_flight set before first bytes; read through
/// ReadyForQuery (storing I/T/E) BEFORE surfacing a saved SQL error. Any
/// incomplete protocol state or cancellation discards the connection.
async fn do_query(
  pool : Pool,
  sql : String,
  params : Array[&@pgcore.ToSql],
  type_oids : Array[@proto.Oid],
) -> (Array[@pgcore.Row], UInt64) raise @pgcore.ClientError {
  with_connection(pool, async fn(conn) {
    with_deadline(async fn() {
      @pgcore.run_frames(conn, sql, params, type_oids)
    })
  }) catch {
    e => raise @pgcore.map_error(e)
  }
}

///|
pub async fn Pool::query_all(
  self : Pool,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> Array[@pgcore.Row] raise @pgcore.ClientError {
  (do_query(self, sql, params, [])).0
}

///|
pub async fn Pool::query_typed_all(
  self : Pool,
  sql : String,
  types : Array[@pgcore.Type],
  params~ : Array[&@pgcore.ToSql] = [],
) -> Array[@pgcore.Row] raise @pgcore.ClientError {
  (do_query(self, sql, params, types.map(fn(t) { t.oid() }))).0
}

///|
pub async fn Pool::query_opt(
  self : Pool,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> @pgcore.Row? raise @pgcore.ClientError {
  let rows = self.query_all(sql, params~)
  match rows.length() {
    0 => None
    1 => Some(rows[0])
    _ => raise @pgcore.ClientError::Protocol("query_opt: >1 row")
  }
}

///|
pub async fn Pool::query_one(
  self : Pool,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> @pgcore.Row raise @pgcore.ClientError {
  match self.query_opt(sql, params~) {
    Some(r) => r
    None => raise @pgcore.ClientError::Protocol("query_one: expected 1 row")
  }
}

///|
/// Returns the affected row count from CommandComplete.
pub async fn Pool::execute(
  self : Pool,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> UInt64 raise @pgcore.ClientError {
  (do_query(self, sql, params, [])).1
}

///|
pub async fn Pool::batched_query(
  self : Pool,
  key : String,
  sql : String,
  ints : Array[Int64],
  texts : Array[String],
) -> Array[@pgcore.Row] raise @pgcore.ClientError {
  // One request per instance, so every batch has one element: one 1-element
  // int8[] per position of `ints`, then one 1-element text[] per `texts`.
  ignore(key)
  let params : Array[&@pgcore.ToSql] = []
  let types : Array[@pgcore.Type] = []
  for v in ints {
    params.push(IntArrayParam::{ values: [v] })
    types.push(@pgcore.Type::from_oid(1016U))
  }
  for t in texts {
    params.push([t])
    types.push(@pgcore.Type::from_oid(1009U))
  }
  self.query_typed_all(sql, types, params~)
}

///|
async fn tx_query(
  tx : Transaction,
  sql : String,
  params : Array[&@pgcore.ToSql],
) -> (Array[@pgcore.Row], UInt64) raise @pgcore.ClientError {
  if !tx.valid {
    raise @pgcore.ClientError::Protocol("escaped transaction")
  }
  with_deadline(async fn() {
    @pgcore.run_frames(tx.conn, sql, params, [])
  }) catch {
    e => raise @pgcore.map_error(e)
  }
}

///|
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> @pgcore.Row raise @pgcore.ClientError {
  let (rows, _) = tx_query(self, sql, params)
  match rows.length() {
    1 => rows[0]
    _ => raise @pgcore.ClientError::Protocol("query_one: expected 1 row")
  }
}

///|
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> @pgcore.Row? raise @pgcore.ClientError {
  let (rows, _) = tx_query(self, sql, params)
  match rows.length() {
    0 => None
    1 => Some(rows[0])
    _ => raise @pgcore.ClientError::Protocol("query_opt: >1 row")
  }
}

///|
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params~ : Array[&@pgcore.ToSql] = [],
) -> UInt64 raise @pgcore.ClientError {
  (tx_query(self, sql, params)).1
}

///|
/// One lease for the whole callback: BEGIN, cb(tx), COMMIT. On callback
/// exception/cancel: protected bounded ROLLBACK if the protocol is still
/// synchronized, else discard. BEGIN/COMMIT failures propagate; success is
/// never reported after a failed commit. The lease defer fires exactly once.
pub async fn[T] Pool::with_transaction(
  self : Pool,
  cb : async (Transaction) -> T raise Error,
) -> T raise Error {
  with_connection(self, async fn(conn) -> T raise {
    @async-core.with_task_group(async fn(group) -> T raise {
      let tx : Transaction = { conn, valid: true }
      group.add_defer(async fn() nocancel {
        tx.valid = false
        @async-core.protect_from_cancel(async fn() {
          if !conn.is_broken() && !conn.in_flight() &&
            (conn.txn_status() == 84 || conn.txn_status() == 69) {
            with_deadline(async fn() {
              ignore(@pgcore.run_frames(conn, "ROLLBACK", [], []))
            }) catch {
              _ => @pgcore.Conn::discard(conn)
            }
          }
        })
      })
      ignore(with_deadline(async fn() {
        @pgcore.run_frames(conn, "BEGIN", [], [])
      }))
      let value = cb(tx)
      if conn.txn_status() != 84 {
        raise @pgcore.ClientError::Protocol("transaction is not committable")
      }
      ignore(with_deadline(async fn() {
        @pgcore.run_frames(conn, "COMMIT", [], [])
      }))
      value
    })
  })
}
