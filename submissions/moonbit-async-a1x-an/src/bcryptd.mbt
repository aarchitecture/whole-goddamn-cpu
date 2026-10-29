///|
priv struct BcryptJob {
  cost : Int32
  salt : Bytes
  password : Bytes
  done : @aqueue.Queue[Bytes]
}

///|
priv struct BcryptClient {
  tcp : @socket.Tcp
  lock : @async.Semaphore
  pending : @aqueue.Queue[@aqueue.Queue[Bytes]]
}

///|
let bcrypt_client : Ref[BcryptClient?] = Ref(None)

///|
fn[X] queue_put(q : @aqueue.Queue[X], x : X) -> Unit {
  ignore(q.try_put(x) catch { _ => false })
}

///|
async fn bc_digest(
  password : BytesView,
  salt : BytesView,
  cost : Int32,
) -> Bytes {
  match bcrypt_client.val {
    None => bc_bcrypt_hash_raw(password, salt, cost)
    Some(c) => {
      let n = if password.length() > 72 { 72 } else { password.length() }
      let req = Bytes::makei(18 + n, fn(i) {
        if i == 0 {
          cost.to_byte()
        } else if i < 17 {
          salt[i - 1]
        } else if i == 17 {
          n.to_byte()
        } else {
          password[i - 18]
        }
      })
      let reply : @aqueue.Queue[Bytes] = @aqueue.Queue::Queue(kind=Unbounded)
      c.lock.acquire()
      defer c.lock.release()
      queue_put(c.pending, reply)
      c.tcp.write(req)
      reply.get()
    }
  }
}

///|
async fn bcrypt_connect(group : @async.TaskGroup[Unit], addr : String) -> Unit {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse(addr))
  let c : BcryptClient = {
    tcp,
    lock: @async.Semaphore::Semaphore(1),
    pending: @aqueue.Queue::Queue(kind=Unbounded),
  }
  group.spawn_bg(() => {
    for ;; {
      let digest = tcp.read_exactly(24)
      queue_put(c.pending.get(), digest)
    }
  })
  bcrypt_client.val = Some(c)
}

///|
fn bcrypt_compute(batch : Array[BcryptJob]) -> Unit {
  let cost = batch[0].cost
  let lanes = batch.filter(fn(j) { j.cost == cost })
  for j in batch {
    if j.cost != cost {
      queue_put(j.done, bc_bcrypt_hash_raw_sync(j.password[:], j.salt[:], j.cost))
    }
  }
  if lanes.length() >= 2 {
    let pick = fn(l : Int32) { if l < lanes.length() { lanes[l] } else { lanes[0] } }
    let out = bc_bcrypt_hash_raw4(
      Array::makei(4, fn(l) { pick(l).password[:] }),
      Array::makei(4, fn(l) { pick(l).salt[:] }),
      cost,
    )
    for l in 0..<lanes.length() {
      queue_put(lanes[l].done, out[l])
    }
  } else {
    for j in lanes {
      queue_put(j.done, bc_bcrypt_hash_raw_sync(j.password[:], j.salt[:], cost))
    }
  }
}

///|
async fn bcrypt_runner(jobs : @aqueue.Queue[BcryptJob], wait_ms : Int32) -> Unit {
  for ;; {
    let batch = [jobs.get()]
    let t0 = @env.now()
    while batch.length() < 4 {
      let left = wait_ms - (@env.now() - t0).to_int()
      if left <= 0 {
        break
      }
      match @async.with_timeout_opt(left, () => jobs.get()) {
        Some(j) => batch.push(j)
        None => break
      }
    }
    bcrypt_compute(batch)
  }
}

///|
async fn bcryptd_conn(tcp : @socket.Tcp, jobs : @aqueue.Queue[BcryptJob]) -> Unit {
  defer tcp.close()
  let order : @aqueue.Queue[@aqueue.Queue[Bytes]] = @aqueue.Queue::Queue(
    kind=Unbounded,
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        let done = order.get()
        tcp.write(done.get())
      }
    })
    for ;; {
      let head = tcp.read_exactly(18)
      let cost = head[0].to_int()
      let n = head[17].to_int()
      if cost < min_cost || cost > max_cost || n > 72 {
        return
      }
      let password = if n > 0 { tcp.read_exactly(n) } else { b"" }
      let done : @aqueue.Queue[Bytes] = @aqueue.Queue::Queue(kind=Unbounded)
      queue_put(order, done)
      queue_put(jobs, { cost, salt: head[1:17].to_owned(), password, done })
    }
  })
}

///|
async fn run_bcryptd(port_file : String, wait_ms : Int32) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  @fs.write_file(port_file, server.addr.port().to_string())
  let jobs : @aqueue.Queue[BcryptJob] = @aqueue.Queue::Queue(kind=Unbounded)
  @async.with_task_group(group => {
    group.spawn_bg(() => bcrypt_runner(jobs, wait_ms))
    for ;; {
      let (tcp, _) = server.accept()
      group.spawn_bg(allow_failure=true, () => bcryptd_conn(tcp, jobs))
    }
  })
}
