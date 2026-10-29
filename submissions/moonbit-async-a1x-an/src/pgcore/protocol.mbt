///|
pub struct Config {
  host : String
  port : Int32
  user : String
  password : String?
  dbname : String
}

///|
pub fn Config::new(
  host : String,
  port : Int32,
  user : String,
  password : String?,
  dbname : String,
) -> Config {
  { host, port, user, password, dbname, }
}

///|
fn u8s(s : String) -> Bytes {
  @proto.utf8_encode(s)
}

///|
pub struct PgIo {
  send : async (Bytes) -> Unit
  recv : async () -> FixedArray[Byte]?
  close : async () -> Unit
  is_open : () -> Bool
  rand : (Int32) -> Bytes?
}

///|
pub fn PgIo::new(
  send : async (Bytes) -> Unit,
  recv : async () -> FixedArray[Byte]?,
  close : async () -> Unit,
  is_open : () -> Bool,
  rand : (Int32) -> Bytes?,
) -> PgIo {
  { send, recv, close, is_open, rand, }
}

///|
pub struct Conn {
  io : PgIo
  frames : FrameBuffer
  /// Connection-local LRU cache, capacity 100. Entries are cached once
  /// ParseComplete arrives; names are never reused on this connection.
  statements : Array[CachedStatement]
  mut statement_tick : UInt64
  mut next_statement : Int32
  mut closed : Bool
  mut broken : Bool
  mut in_flight : Bool
  mut txn_status : Int32 // 'I' idle, 'T' in-transaction, 'E' error
}

///|
pub fn Conn::new(io : PgIo) -> Conn {
  {
    io,
    frames: FrameBuffer::new(),
    statements: [],
    statement_tick: 0UL,
    next_statement: 1,
    closed: false,
    broken: false,
    in_flight: false,
    txn_status: 73,
  }
}

///|
pub fn Conn::is_open(self : Conn) -> Bool {
  (self.io.is_open)()
}

///|
pub fn Conn::safe_to_reuse(self : Conn) -> Bool {
  !self.broken &&
  !self.closed &&
  !self.in_flight &&
  self.txn_status == 73 &&
  (self.io.is_open)()
}

///|
pub fn Conn::is_broken(self : Conn) -> Bool {
  self.broken
}

///|
pub fn Conn::in_flight(self : Conn) -> Bool {
  self.in_flight
}

///|
pub fn Conn::txn_status(self : Conn) -> Int32 {
  self.txn_status
}

///|
pub struct CachedStatement {
  key : String
  name : String
  mut row_oids : Array[@proto.Oid]
  mut described : Bool
  mut last_used : UInt64
}

///|
async fn read_frame(conn : Conn) -> @backend.Message raise ClientError {
  errdefer {
    conn.broken = true
  }
  for ;; {
    let frame = conn.frames.next_frame()
    match frame {
      Some(f) =>
        match (@backend.Message::parse(f[:]) catch { _ => None }) {
          Some(pm) => return pm.message
          None => {
            conn.broken = true
            raise ClientError::Protocol("parse fail")
          }
        }
      None => {
        let chunk = (conn.io.recv)() catch {
          _ => {
            conn.broken = true
            raise ClientError::Io("recv failed")
          }
        }
        match chunk {
          Some(bytes) => conn.frames.push(bytes)
          None => {
            conn.broken = true
            raise ClientError::Io("eof mid-frame")
          }
        }
      }
    }
  }
}

///|
fn parse_err(
  body : @backend.ErrorResponseBody,
) -> (String?, String) raise ClientError {
  let mut code : String? = None
  let mut msg = ""
  let it = body.fields()
  while true {
    match
      (it.next() catch {
        _ => raise ClientError::Protocol("malformed error fields")
      }) {
      Some(f) => {
        let v = @utf8.decode(f.value_bytes()) catch {
          _ => raise ClientError::Protocol("malformed error text")
        }
        if f.type_ == 67 {
          code = Some(v)
        } // 'C' sqlstate
        if f.type_ == 77 {
          msg = v
        } // 'M' message
      }
      None => break
    }
  }
  (code, msg)
}

///|
pub fn map_error(e : Error) -> ClientError {
  match e {
    ClientError::Database(d) => ClientError::Database(d)
    ClientError::Decode(s) => ClientError::Decode(s)
    ClientError::Protocol(s) => ClientError::Protocol(s)
    ClientError::Io(s) => ClientError::Io(s)
    _ => ClientError::Io("operation canceled or deadline exceeded")
  }
}

///|
async fn send_packet(conn : Conn, packet : Bytes) -> Unit raise ClientError {
  if !(conn.io.is_open)() {
    conn.broken = true
    raise ClientError::Io("send stream closed")
  }
  (conn.io.send)(packet) catch {
    _ => raise ClientError::Io("send failed")
  }
}

///|
fn statement_key(sql : String, type_oids : Array[@proto.Oid]) -> String {
  let mut key = sql + "\u{0}"
  for oid in type_oids {
    key += oid.to_string() + ","
  }
  key
}

///|
fn cache_lookup(conn : Conn, key : String) -> CachedStatement? {
  for i in 0..<conn.statements.length() {
    if conn.statements[i].key == key {
      conn.statement_tick += 1UL
      conn.statements[i].last_used = conn.statement_tick
      return Some(conn.statements[i])
    }
  }
  None
}

///|
fn cache_remove(conn : Conn, name : String) -> Unit {
  for i in 0..<conn.statements.length() {
    if conn.statements[i].name == name {
      ignore(conn.statements.remove(i))
      return
    }
  }
}

///|
fn cache_set_row_oids(
  conn : Conn,
  name : String,
  row_oids : Array[@proto.Oid],
) -> Unit {
  for i in 0..<conn.statements.length() {
    if conn.statements[i].name == name {
      conn.statements[i].row_oids = row_oids.copy()
      conn.statements[i].described = true
      return
    }
  }
}

///|
fn cache_insert(
  conn : Conn,
  key : String,
  name : String,
  row_oids : Array[@proto.Oid],
) -> Unit {
  conn.statement_tick += 1UL
  conn.statements.push({
    key,
    name,
    row_oids,
    described: false,
    last_used: conn.statement_tick,
  })
}

///|
fn cache_evict_lru(conn : Conn) -> String? {
  if conn.statements.length() < 100 {
    return None
  }
  let mut index = 0
  for i in 1..<conn.statements.length() {
    if conn.statements[i].last_used < conn.statements[index].last_used {
      index = i
    }
  }
  Some(conn.statements.remove(index).name)
}

///|
pub async fn startup_auth(conn : Conn, cfg : Config) -> Unit raise ClientError {
  let params : Array[(BytesView, BytesView)] = [
    (u8s("user")[:], u8s(cfg.user)[:]),
    (u8s("database")[:], u8s(cfg.dbname)[:]),
    (u8s("client_encoding")[:], u8s("UTF8")[:]),
    // Generic plans are ~2x cheaper for list statements; disable Memoize
    // because batched LATERAL rows are per-request. JIT and parallel
    // workers only add startup cost to these short statements.
    (u8s("plan_cache_mode")[:], u8s("force_generic_plan")[:]),
    (u8s("enable_memoize")[:], u8s("off")[:]),
    (u8s("jit")[:], u8s("off")[:]),
    (u8s("max_parallel_workers_per_gather")[:], u8s("0")[:]),
  ]
  let ob = @buffer.Buffer()
  @frontend.startup_message(params.iter(), ob) catch {
    _ => raise ClientError::Protocol("startup frame")
  }
  send_packet(conn, ob.to_bytes())
  let mut scram : @authentication.ScramSha256? = None
  while true {
    let m = read_frame(conn)
    match m {
      @backend.Message::AuthenticationOk => ()
      @backend.Message::AuthenticationCleartextPassword => {
        let pb = @buffer.Buffer()
        match cfg.password {
          Some(p) =>
            @frontend.password_message(u8s(p)[:], pb) catch {
              _ => raise ClientError::Protocol("password frame")
            }
          None => raise ClientError::Protocol("cleartext, no password")
        }
        send_packet(conn, pb.to_bytes())
      }
      @backend.Message::AuthenticationSasl(body) => {
        let mut ok256 = false
        let mechs = body.mechanisms()
        while true {
          match
            (mechs.next() catch {
              _ => raise ClientError::Protocol("sasl mechs")
            }) {
            Some(mech) => if mech == b"SCRAM-SHA-256" { ok256 = true }
            None => break
          }
        }
        if !ok256 {
          raise ClientError::Protocol("no SCRAM-SHA-256")
        }
        let pw = match cfg.password {
          Some(p) => p
          None => raise ClientError::Protocol("sasl, no password")
        }
        let nonce = match (conn.io.rand)(18) {
          Some(n) => n
          None => raise ClientError::Protocol("csprng unavailable")
        }
        scram = Some(
          @authentication.ScramSha256::new(
            u8s(pw)[:],
            @authentication.ChannelBinding::unsupported(),
            nonce[:],
          ) catch {
            _ => raise ClientError::Protocol("scram init")
          },
        )
        let s = scram.unwrap()
        let sb = @buffer.Buffer()
        @frontend.sasl_initial_response(
          u8s("SCRAM-SHA-256")[:],
          s.message()[:],
          sb,
        ) catch {
          _ => raise ClientError::Protocol("sasl frame")
        }
        send_packet(conn, sb.to_bytes())
      }
      @backend.Message::AuthenticationSaslContinue(body) =>
        match scram {
          Some(s) => {
            // update() returns Unit and appends the client-final message
            // to s.message(), mirroring the pinned startup.mbt flow.
            s.update(body.data()) catch {
              _ => raise ClientError::Protocol("sasl update")
            }
            let sb = @buffer.Buffer()
            @frontend.sasl_response(s.message()[:], sb) catch {
              _ => raise ClientError::Protocol("sasl response frame")
            }
            send_packet(conn, sb.to_bytes())
          }
          None => raise ClientError::Protocol("unexpected sasl continue")
        }
      @backend.Message::AuthenticationSaslFinal(body) =>
        match scram {
          Some(s) =>
            s.finish(body.data()) catch {
              _ => raise ClientError::Protocol("sasl finish")
            }
          None => raise ClientError::Protocol("unexpected sasl final")
        }
      @backend.Message::AuthenticationMd5Password(_) =>
        raise ClientError::Protocol("MD5 auth rejected")
      @backend.Message::ErrorResponse(body) => {
        let (code, msg) = parse_err(body)
        raise ClientError::Database(DatabaseError::new(code, msg))
      }
      @backend.Message::ReadyForQuery(_) => break
      _ => () // ParameterStatus/BackendKeyData/NoticeResponse
    }
  }
}

///|
/// Teardown: set broken, drop the socket FIRST to break host waits, then
/// close/reject/drop all stream+future endpoints. Idempotent.
pub async fn Conn::discard(c : Conn) -> Unit noraise {
  if c.closed {
    return
  }
  c.closed = true
  c.broken = true
  ignore((c.io.close)() catch { _ => () })
}

///|
pub async fn run_frames(
  conn : Conn,
  sql : String,
  params : Array[&ToSql],
  type_oids : Array[@proto.Oid],
) -> (Array[Row], UInt64) raise ClientError {
  let key = statement_key(sql, type_oids)
  let cached = cache_lookup(conn, key)
  let hit = cached is Some(_)
  let name = match cached {
    Some(entry) => entry.name
    None => {
      let n = "s" + conn.next_statement.to_string()
      conn.next_statement += 1
      n
    }
  }
  let ob = @buffer.Buffer()
  let empty = b""
  if !hit {
    match cache_evict_lru(conn) {
      Some(evicted) =>
        @frontend.close(b'S', u8s(evicted)[:], ob) catch {
          _ => raise ClientError::Protocol("close frame")
        }
      None => ()
    }
    @frontend.parse(u8s(name)[:], u8s(sql)[:], type_oids.iter(), ob) catch {
      _ => raise ClientError::Protocol("parse frame")
    }
    @frontend.describe(b'S', u8s(name)[:], ob) catch {
      _ => raise ClientError::Protocol("describe frame")
    }
  }
  match cached {
    Some(entry) if !entry.described =>
      @frontend.describe(b'S', u8s(name)[:], ob) catch {
        _ => raise ClientError::Protocol("describe frame")
      }
    _ => ()
  }
  @frontend.bind(
    empty[:],
    u8s(name)[:],
    [0].iter(),
    params.iter(),
    (v, b) => v.to_sql(b),
    [1].iter(),
    ob,
  ) catch {
    _ => raise ClientError::Protocol("bind frame")
  }
  @frontend.execute(empty[:], 0, ob) catch {
    _ => raise ClientError::Protocol("execute frame")
  }
  @frontend.sync(ob)
  conn.in_flight = true
  if !(conn.io.is_open)() {
    conn.broken = true
    conn.in_flight = false
    raise ClientError::Io("send pipe closed")
  }
  send_packet(conn, ob.to_bytes())
  let oids : Array[@proto.Oid] = match cached {
    Some(entry) => entry.row_oids.copy()
    None => []
  }
  let rows : Array[Row] = []
  let mut affected : UInt64 = 0UL
  let mut dberr : ClientError? = None
  let mut cached_after_parse = hit
  while true {
    let m = read_frame(conn)
    match m {
      @backend.Message::CloseComplete => ()
      @backend.Message::ParseComplete =>
        if !hit && !cached_after_parse {
          cache_insert(conn, key, name, [])
          cached_after_parse = true
        }
      @backend.Message::RowDescription(body) => {
        let fs = body.fields()
        while true {
          match
            (fs.next() catch { _ => raise ClientError::Protocol("field") }) {
            Some(f) => oids.push(f.type_oid)
            None => break
          }
        }
        if !hit || (cached is Some(entry) && !entry.described) {
          cache_set_row_oids(conn, name, oids)
        }
      }
      @backend.Message::NoData =>
        if !hit || (cached is Some(entry) && !entry.described) {
          cache_set_row_oids(conn, name, [])
        }
      @backend.Message::DataRow(body) => {
        let buf = body.buffer()
        let ranges = body.ranges()
        let cells : Array[Bytes?] = []
        while true {
          match
            (ranges.next() catch {
              _ => raise ClientError::Protocol("datarow")
            }) {
            Some(Some(r)) => cells.push(Some(buf[r.start:r.end].to_owned()))
            Some(None) => cells.push(None)
            None => break
          }
        }
        rows.push(Row::from_parts(oids, cells))
      }
      @backend.Message::CommandComplete(body) => {
        // trailing integer of the tag is the affected row count
        let tag = body.tag_bytes()
        let mut n : UInt64 = 0UL
        let mut seen = false
        for b in tag {
          if b.to_int() >= 48 && b.to_int() <= 57 {
            n = n * 10UL + (b.to_int() - 48).to_uint64()
            seen = true
          }
        }
        if seen {
          affected = n
        }
      }
      @backend.Message::ErrorResponse(body) => {
        let (code, msg) = parse_err(body)
        match (hit, code) {
          (true, Some(c)) if c == "26000" || c == "0A000" =>
            cache_remove(conn, name)
          _ => ()
        }
        dberr = Some(ClientError::Database(DatabaseError::new(code, msg)))
      }
      @backend.Message::ReadyForQuery(r) => {
        // transaction status: 'I'=idle 'T'=transaction 'E'=error
        if r.status != 73 && r.status != 84 && r.status != 69 {
          conn.broken = true
          raise ClientError::Protocol("invalid transaction status")
        }
        conn.txn_status = r.status.to_int()
        conn.in_flight = false
        break
      }
      _ => ()
    }
  }
  match dberr {
    Some(e) => raise e
    None => (rows, affected)
  }
}

///|
