///|
/// Native pool facade over the shared pure PostgreSQL protocol core.
pub struct PoolConfig {
  size : Int32
  batch : Int32
  batch_wait_ms : Int32
}

///|
pub suberror ConfigError {
  Invalid(String)
}

///|
pub fn ConfigError::message(self : ConfigError) -> String {
  match self {
    Invalid(msg) => msg
  }
}

///|
pub fn PoolConfig::PoolConfig(
  size : Int32,
  batch~ : Int32 = 1,
  batch_wait_ms~ : Int32 = 0,
) -> PoolConfig raise ConfigError {
  if size < 1 || size > 95 || batch < 1 || batch > 95 || size + batch > 95 {
    raise ConfigError::Invalid("invalid pool size")
  }
  if batch_wait_ms < 0 || batch_wait_ms > 50 {
    raise ConfigError::Invalid("invalid batch wait")
  }
  { size, batch, batch_wait_ms }
}

///|
pub struct Config {
  host : String
  port : Int32
  user : String
  password : String?
  dbname : String
  pool_size : Int32
  batch_size : Int32
  batch_wait_ms : Int32
}

///|
pub fn Config::new(
  host : String,
  port : Int32,
  user : String,
  password : String?,
  dbname : String,
  pool_size : Int32,
  batch_size~ : Int32 = 1,
  batch_wait_ms~ : Int32 = 0,
) -> Config {
  { host, port, user, password, dbname, pool_size, batch_size, batch_wait_ms }
}

///|
pub fn Config::Config(
  targets : Array[ConnectionTarget],
  user~ : String,
  dbname~ : String,
  password? : String,
  pool~ : PoolConfig,
) -> Config raise ConfigError {
  if targets.length() == 0 {
    raise ConfigError::Invalid("missing connection target")
  }
  {
    host: targets[0].host,
    port: targets[0].port,
    user,
    password,
    dbname,
    pool_size: pool.size,
    batch_size: pool.batch,
    batch_wait_ms: pool.batch_wait_ms,
  }
}

///|
pub struct ConnectionTarget {
  host : String
  port : Int32
}

///|
pub fn ConnectionTarget::ConnectionTarget(
  host~ : String,
  port~ : Int32,
) -> ConnectionTarget {
  { host, port, }
}

///|
pub struct Executor {
  priv pool : Pool
}

///|
/// Runs the batch workers: one per batch connection for each batch kind,
/// started when the kind is first used. Each worker takes the next waiting
/// request, acquires a batch connection (more requests queue meanwhile), then
/// sends everything queued (up to 32) as one statement.
pub async fn Executor::run(self : Executor) -> Unit {
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while true {
        @async.sleep(5000)
        let st = self.pool.stats
        println(
          "pool stats: batches=\{st[0]} members=\{st[1]} reconnects=\{st[2]} failed=\{st[3]} waiting=\{st[4]} conns=\{self.pool.general.conns.length()}+\{self.pool.batch.conns.length()}",
        )
      }
    })
    while true {
      let g = self.pool.announce.get()
      for _ in 0..<self.pool.cfg.batch_size {
        group.spawn_bg(async fn() { self.pool.batch_worker(g) })
      }
    }
  })
}

///|
pub struct Transaction {
  conn : @client.Conn
  mut valid : Bool
}

///|
priv struct Lane {
  conns : Array[@client.Conn]
  leased : Array[Bool]
  sema : @async.Semaphore
}

///|
fn Lane::new(size : Int32) -> Lane {
  { conns: [], leased: [], sema: @async.Semaphore::Semaphore(size) }
}

///|
pub struct Pool {
  cfg : Config
  priv general : Lane
  priv batch : Lane
  batches : Array[BatchGroup]
  announce : @aqueue.Queue[BatchGroup]
  // diagnostics: batches, members, reconnects, failed batches, waiting members
  stats : Array[Int32]
}

///|
pub enum BatchReply {
  Rows(Array[@client.Row])
  Fail(@client.ClientError)
}

///|
pub struct BatchMember {
  priv ints : Array[Int64]
  priv texts : Array[String]
  priv reply : @aqueue.Queue[BatchReply]
  // set when a failed batch re-queued this member; it then runs on its own
  priv mut retried : Bool
}

///|
/// Requests of one kind waiting to go to PostgreSQL together as one statement.
pub struct BatchGroup {
  priv key : String
  priv sql : String
  priv queue : @aqueue.Queue[BatchMember]
}

///|
priv struct IntArrayParam {
  values : Array[Int64]
}

///|
impl @client.ToSql for IntArrayParam with fn to_sql(self, buf) {
  buf.write_byte(123)
  let mut first = true
  for value in self.values {
    if !first {
      buf.write_byte(44)
    }
    first = false
    buf.write_byte(34)
    buf.write_bytesview(@proto.utf8_encode(value.to_string())[:])
    buf.write_byte(34)
  }
  buf.write_byte(125)
  @proto.IsNull::No
}

///|
pub fn Pool::create(cfg : Config) -> (Pool, Executor) {
  let pool : Pool = {
    cfg,
    general: Lane::new(cfg.pool_size),
    batch: Lane::new(cfg.batch_size),
    batches: [],
    announce: @aqueue.Queue::Queue(kind=Unbounded),
    stats: [0, 0, 0, 0, 0],
  }
  (pool, { pool, })
}

///|
pub fn Pool::ready(_self : Pool) -> Unit {
  ()
}

///|
async fn Pool::connect(self : Pool) -> @client.Conn {
  let tcp = @socket.Tcp::connect_to_host(self.cfg.host, port=self.cfg.port)
  let io = @client.PgIo::new(
    async fn(packet : Bytes) {
      let mut offset = 0
      while offset < packet.length() {
        let n = tcp.write_once(packet, offset~, len=packet.length() - offset)
        if n <= 0 {
          raise @client.ClientError::Io("native socket write")
        }
        offset += n
      }
    },
    async fn() {
      match tcp.read_some(max_len=65536) {
        Some(b) => Some(b.to_fixedarray())
        None => None
      }
    },
    fn() { tcp.close() },
    () => true,
    @env.rand,
  )
  let conn = @client.Conn::new(io)
  @client.startup_auth(
    conn,
    @client.Config::new(
      self.cfg.host,
      self.cfg.port,
      self.cfg.user,
      self.cfg.password,
      self.cfg.dbname,
    ),
  )
  // Batched statements join per-request LATERAL subqueries; Memoize could
  // hand one request a row looked up for another, so it stays off.
  conn
}

///|
async fn Pool::acquire_slot(self : Pool, lane : Lane) -> (Int32, @client.Conn) {
  lane.sema.acquire()
  // Slots are never removed: indices held by concurrent leases stay valid. A
  // broken connection is replaced in place when its slot is leased next.
  for i in 0..<lane.conns.length() {
    if !lane.leased[i] {
      lane.leased[i] = true
      if lane.conns[i].safe_to_reuse() {
        return (i, lane.conns[i])
      }
      // Close the broken connection (and its server backend) before replacing it.
      lane.conns[i].discard()
      self.stats[2] = self.stats[2] + 1
      errdefer {
        lane.leased[i] = false
        lane.sema.release()
      }
      let conn = self.connect()
      lane.conns[i] = conn
      return (i, conn)
    }
  }
  errdefer lane.sema.release()
  let conn = self.connect()
  lane.conns.push(conn)
  lane.leased.push(true)
  (lane.conns.length() - 1, conn)
}

///|
async fn[T] Pool::with_lane(
  self : Pool,
  lane : Lane,
  f : async (@client.Conn) -> T,
) -> T {
  let (index, conn) = self.acquire_slot(lane)
  let result = Ok(f(conn)) catch { e => Err(e) }
  lane.leased[index] = false
  lane.sema.release()
  match result {
    Ok(value) => value
    Err(e) => raise e
  }
}

///|
async fn[T] Pool::with_conn(self : Pool, f : async (@client.Conn) -> T) -> T {
  self.with_lane(self.general, f)
}

///|
async fn Pool::do_query(
  self : Pool,
  sql : String,
  params : Array[&@client.ToSql],
  oids : Array[@client.Type],
) -> (Array[@client.Row], UInt64) raise @client.ClientError {
  self.with_conn(async fn(conn) {
    @async.with_timeout(5000, () => {
      @client.run_frames(conn, sql, params, oids.map(fn(t) { t.oid() }))
    }) catch {
      e => raise @client.map_error(e)
    }
  }) catch {
    e => raise @client.map_error(e)
  }
}

///|
pub async fn Pool::query_all(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> Array[@client.Row] raise @client.ClientError {
  self.do_query(sql, params, []).0
}

///|
pub async fn Pool::query_typed_all(
  self : Pool,
  sql : String,
  types : Array[@client.Type],
  params~ : Array[&@client.ToSql] = [],
) -> Array[@client.Row] raise @client.ClientError {
  self.do_query(sql, params, types).0
}

///|
pub async fn Pool::query_opt(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> @client.Row? raise @client.ClientError {
  let rows = self.query_all(sql, params~)
  match rows.length() {
    0 => None
    1 => Some(rows[0])
    _ => raise @client.ClientError::Protocol("query_opt: >1 row")
  }
}

///|
pub async fn Pool::query_one(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> @client.Row raise @client.ClientError {
  match self.query_opt(sql, params~) {
    Some(r) => r
    None => raise @client.ClientError::Protocol("query_one: expected 1 row")
  }
}

///|
pub async fn Pool::execute(
  self : Pool,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> UInt64 raise @client.ClientError {
  self.do_query(sql, params, []).1
}

///|
/// Run `sql` for this request together with other waiting requests of the same
/// `key`. The statement takes one int8[] per position of `ints`, then one
/// text[] per position of `texts`, and must return the request's 1-based
/// ordinal as its last column; only this request's rows come back, in order.
pub async fn Pool::batched_query(
  self : Pool,
  key : String,
  sql : String,
  ints : Array[Int64],
  texts : Array[String],
) -> Array[@client.Row] raise @client.ClientError {
  let mut found : BatchGroup? = None
  for g in self.batches {
    if g.key == key {
      found = Some(g)
    }
  }
  let g = match found {
    Some(g) => g
    None => {
      let n : BatchGroup = {
        key,
        sql,
        queue: @aqueue.Queue::Queue(kind=Unbounded),
      }
      self.batches.push(n)
      ignore(self.announce.try_put(n) catch { _ => false })
      n
    }
  }
  let reply : @aqueue.Queue[BatchReply] = @aqueue.Queue::Queue(kind=Unbounded)
  self.stats[4] = self.stats[4] + 1
  let reply_value = try {
    g.queue.put({ ints, texts, reply, retried: false, })
    reply.get()
  } catch {
    e => {
      self.stats[4] = self.stats[4] - 1
      raise @client.map_error(e)
    }
  }
  self.stats[4] = self.stats[4] - 1
  match reply_value {
    Rows(rows) => rows
    Fail(e) => raise e
  }
}

///|
fn batch_params(
  batch : Array[BatchMember],
) -> (Array[&@client.ToSql], Array[UInt32]) {
  let params : Array[&@client.ToSql] = []
  let oids : Array[UInt32] = []
  for c in 0..<batch[0].ints.length() {
    params.push(IntArrayParam::{ values: batch.map(fn(m) { m.ints[c] }), })
    oids.push(1016U)
  }
  for c in 0..<batch[0].texts.length() {
    params.push(batch.map(fn(m) { m.texts[c] }))
    oids.push(1009U)
  }
  (params, oids)
}

///|
fn send_reply(m : BatchMember, r : BatchReply) -> Unit {
  ignore(m.reply.try_put(r) catch { _ => false })
}

///|
async fn Pool::batch_worker(self : Pool, g : BatchGroup) -> Unit {
  while true {
    let first = g.queue.get() catch { _ => return }
    if self.cfg.batch_wait_ms > 0 && !first.retried {
      @async.sleep(self.cfg.batch_wait_ms)
    }
    let batch = [first]
    let result = try {
      let (rows, _) = self.with_lane(self.batch, async fn(conn) {
        while !first.retried && batch.length() < 32 {
          match (g.queue.try_get() catch { _ => None }) {
            Some(m) => batch.push(m)
            None => break
          }
        }
        let (params, oids) = batch_params(batch)
        @async.with_timeout(5000, () => {
          @client.run_frames(conn, g.sql, params, oids)
        })
      })
      let per : Array[Array[@client.Row]] = Array::makei(batch.length(), fn(_) {
        []
      })
      for row in rows {
        let i : Int64 = row.get(row.len() - 1)
        let k = i.to_int() - 1
        if k >= 0 && k < per.length() {
          per[k].push(row)
        }
      }
      Ok(per)
    } catch {
      e => Err(@client.map_error(e))
    }
    self.stats[0] = self.stats[0] + 1
    self.stats[1] = self.stats[1] + batch.length()
    match result {
      Ok(per) =>
        for k in 0..<batch.length() {
          send_reply(batch[k], Rows(per[k]))
        }
      Err(e) => {
        self.stats[3] = self.stats[3] + 1
        println("batch failed (\{batch.length()} members): \{(e : Error)}")
        // Reads only: give every member one more try, alone, before failing it,
        // so one slow batch does not fail all of its requests.
        for m in batch {
          if m.retried || batch.length() == 1 {
            send_reply(m, Fail(e))
          } else {
            m.retried = true
            if !(g.queue.try_put(m) catch { _ => false }) {
              send_reply(m, Fail(e))
            }
          }
        }
      }
    }
  }
}

///|
async fn tx_query(
  tx : Transaction,
  sql : String,
  params : Array[&@client.ToSql],
) -> (Array[@client.Row], UInt64) raise @client.ClientError {
  if !tx.valid {
    raise @client.ClientError::Protocol("escaped transaction")
  }
  @async.with_timeout(5000, () => @client.run_frames(tx.conn, sql, params, [])) catch {
    e => raise @client.map_error(e)
  }
}

///|
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> @client.Row raise @client.ClientError {
  let rows = tx_query(self, sql, params).0
  if rows.length() == 1 {
    rows[0]
  } else {
    raise @client.ClientError::Protocol("query_one: expected 1 row")
  }
}

///|
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> @client.Row? raise @client.ClientError {
  let rows = tx_query(self, sql, params).0
  if rows.length() == 0 {
    None
  } else if rows.length() == 1 {
    Some(rows[0])
  } else {
    raise @client.ClientError::Protocol("query_opt: >1 row")
  }
}

///|
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params~ : Array[&@client.ToSql] = [],
) -> UInt64 raise @client.ClientError {
  tx_query(self, sql, params).1
}

///|
pub async fn[T] Pool::with_transaction(
  self : Pool,
  cb : async (Transaction) -> T raise Error,
) -> T raise Error {
  self.with_conn(async fn(conn) -> T {
    ignore(@client.run_frames(conn, "BEGIN", [], []))
    let tx : Transaction = { conn, valid: true, }
    let value = cb(tx) catch {
      e => {
        tx.valid = false
        ignore(@client.run_frames(conn, "ROLLBACK", [], []))
        raise e
      }
    }
    ignore(@client.run_frames(conn, "COMMIT", [], []))
    tx.valid = false
    value
  })
}
