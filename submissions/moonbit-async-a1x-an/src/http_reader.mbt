///|
priv struct ConnReader {
  tcp : @socket.Tcp
  mut buf : FixedArray[Byte]
  mut start : Int
  mut end : Int
}

///|
priv enum ReadResult {
  ReqOk(@http.Request, Bytes)
  ReqBad(Int, String)
}

///|
let max_request_head : Int = 16384

///|
let max_request_body : Int = 1048576

///|
fn ConnReader::new(tcp : @socket.Tcp) -> ConnReader {
  { tcp, buf: FixedArray::make(2048, b'\x00'), start: 0, end: 0 }
}

///|
async fn ConnReader::fill(self : ConnReader) -> Bool {
  if self.start == self.end {
    self.start = 0
    self.end = 0
  } else if self.end == self.buf.length() && self.start > 0 {
    let n = self.end - self.start
    self.buf.blit_to(self.buf, src_offset=self.start, dst_offset=0, len=n)
    self.start = 0
    self.end = n
  }
  if self.end == self.buf.length() {
    let next : FixedArray[Byte] = FixedArray::make(self.buf.length() * 2, b'\x00')
    self.buf.blit_to(next, src_offset=0, dst_offset=0, len=self.end)
    self.buf = next
  }
  let n = self.tcp.read(self.buf, offset=self.end, max_len=self.buf.length() - self.end)
  if n == 0 {
    return false
  }
  self.end += n
  true
}

///|
fn lower_eq(buf : FixedArray[Byte], from : Int, to : Int, name : Bytes) -> Bool {
  if to - from != name.length() {
    return false
  }
  for i in 0..<name.length() {
    let c = buf[from + i]
    let c = if c >= b'A' && c <= b'Z' { (c.to_int() + 32).to_byte() } else { c }
    if c != name[i] {
      return false
    }
  }
  true
}

///|
fn method_of(buf : FixedArray[Byte], from : Int, to : Int) -> @http.Method {
  let n = to - from
  let same = fn(s : Bytes) {
    if s.length() != n {
      return false
    }
    for i in 0..<n {
      if buf[from + i] != s[i] {
        return false
      }
    }
    true
  }
  if same(b"GET") {
    Get
  } else if same(b"POST") {
    Post
  } else if same(b"PUT") {
    Put
  } else if same(b"DELETE") {
    Delete
  } else if same(b"HEAD") {
    Head
  } else {
    Other
  }
}

///|
async fn ConnReader::next(self : ConnReader) -> ReadResult? raise {
  let mut rel = 0
  let mut head_end = -1
  while head_end < 0 {
    let mut i = self.start + rel
    while i + 3 < self.end {
      if self.buf[i] == b'\r' &&
        self.buf[i + 1] == b'\n' &&
        self.buf[i + 2] == b'\r' &&
        self.buf[i + 3] == b'\n' {
        head_end = i
        break
      }
      i += 1
    }
    if head_end >= 0 {
      break
    }
    if self.end - self.start >= max_request_head {
      return Some(ReqBad(400, "request header too large"))
    }
    rel = if i > self.start { i - self.start } else { 0 }
    if !self.fill() {
      return None
    }
  }
  let buf = self.buf
  let view = buf.unsafe_reinterpret_as_bytes()
  let mut line_end = self.start
  while !(buf[line_end] == b'\r' && buf[line_end + 1] == b'\n') {
    line_end += 1
  }
  let mut sp1 = self.start
  while sp1 < line_end && buf[sp1] != b' ' {
    sp1 += 1
  }
  let mut sp2 = sp1 + 1
  while sp2 < line_end && buf[sp2] != b' ' {
    sp2 += 1
  }
  if sp1 >= line_end ||
    sp2 >= line_end ||
    sp2 == sp1 + 1 ||
    !(line_end - sp2 - 1 == 8 && lower_eq(buf, sp2 + 1, sp2 + 8, b"http/1.")) {
    return Some(ReqBad(400, "malformed request line"))
  }
  let meth = method_of(buf, self.start, sp1)
  let path = @utf8.decode(view[sp1 + 1:sp2]) catch {
    _ => return Some(ReqBad(400, "malformed request target"))
  }
  let headers : @http.Headers = Map([])
  let mut content_length = 0
  let mut chunked = false
  let mut ls = line_end + 2
  while ls < head_end + 2 {
    let mut le = ls
    while !(buf[le] == b'\r' && buf[le + 1] == b'\n') {
      le += 1
    }
    let mut colon = ls
    while colon < le && buf[colon] != b':' {
      colon += 1
    }
    if colon == ls || colon >= le {
      return Some(ReqBad(400, "malformed header"))
    }
    let mut vs = colon + 1
    while vs < le && (buf[vs] == b' ' || buf[vs] == b'\t') {
      vs += 1
    }
    let mut ve = le
    while ve > vs && (buf[ve - 1] == b' ' || buf[ve - 1] == b'\t') {
      ve -= 1
    }
    if lower_eq(buf, ls, colon, b"content-length") {
      if ve == vs || ve - vs > 9 {
        return Some(ReqBad(400, "bad content-length"))
      }
      let mut n = 0
      for j in vs..<ve {
        let c = buf[j]
        if c < b'0' || c > b'9' {
          return Some(ReqBad(400, "bad content-length"))
        }
        n = n * 10 + c.to_int() - 48
      }
      content_length = n
    } else if lower_eq(buf, ls, colon, b"transfer-encoding") {
      chunked = true
    } else if lower_eq(buf, ls, colon, b"authorization") ||
      lower_eq(buf, ls, colon, b"connection") {
      let name = if buf[ls] == b'a' || buf[ls] == b'A' {
        "authorization"
      } else {
        "connection"
      }
      if !headers.contains(name) {
        let value = @utf8.decode(view[vs:ve]) catch {
          _ => return Some(ReqBad(400, "malformed header"))
        }
        headers[name] = value
      }
    }
    ls = le + 2
  }
  self.start = head_end + 4
  if chunked {
    return Some(ReqBad(411, "a Content-Length request body is required"))
  }
  if content_length > max_request_body {
    return Some(ReqBad(413, "payload too large"))
  }
  while self.end - self.start < content_length {
    if !self.fill() {
      return None
    }
  }
  let body = if content_length == 0 {
    b""
  } else {
    self.buf.unsafe_reinterpret_as_bytes()[self.start:self.start +
      content_length].to_owned()
  }
  self.start += content_length
  Some(ReqOk(@http.Request::new(meth, path, headers), body))
}
