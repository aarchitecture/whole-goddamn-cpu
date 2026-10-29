///|
async fn reader_pair(
  chunks : Array[Bytes],
  check : async (ConnReader) -> Unit,
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group(g => {
    g.spawn_bg(() => {
      let c = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
      for chunk in chunks {
        c.write(chunk)
        @async.sleep(10)
      }
      c.close()
    })
    let (tcp, _) = server.accept()
    check(ConnReader::new(tcp))
    tcp.close()
    server.close()
  })
}

///|
async test "http reader: pipelined requests, split body, header case" {
  reader_pair(
    [
      b"GET /api/tags?x=1 HTTP/1.1\r\nHost: a\r\nAUTHORIZATION:  Token abc \r\n\r\nPOST /api/users HTTP/1.1\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhel",
      b"lo",
    ],
    async fn(r) {
      match r.next() {
        Some(ReqOk(req, body)) => {
          assert_true(req.meth is Get)
          assert_eq(req.path, "/api/tags?x=1")
          assert_eq(req.headers.get("authorization"), Some("Token abc"))
          assert_eq(body, b"")
        }
        _ => fail("first request")
      }
      match r.next() {
        Some(ReqOk(req, body)) => {
          assert_true(req.meth is Post)
          assert_eq(req.headers.get("connection"), Some("close"))
          assert_eq(body, b"hello")
        }
        _ => fail("second request")
      }
      assert_true(r.next() is None)
    },
  )
}

///|
async test "http reader: head split across reads, chunked and bad requests" {
  reader_pair([b"DELETE /a HTTP/1.1\r\nCont", b"ent-Length: 0\r\n\r\n"], async fn(r) {
    match r.next() {
      Some(ReqOk(req, _)) => assert_true(req.meth is Delete)
      _ => fail("split head")
    }
  })
  reader_pair(
    [b"POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"],
    async fn(r) { assert_true(r.next() is Some(ReqBad(411, _))) },
  )
  reader_pair([b"GARBAGE\r\n\r\n"], async fn(r) {
    assert_true(r.next() is Some(ReqBad(400, _)))
  })
}
