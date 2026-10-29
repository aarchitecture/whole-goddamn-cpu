///|
/// Small UTF-8 JSON writer used by hot read-only responses.
struct JsonOut {
  buf : @buffer.Buffer
  first : Array[Bool]
  mut after_key : Bool
}

///|
suberror JsonOutError {
  Decode(String)
}

///|
impl Show for JsonOutError with fn output(self, logger) {
  match self {
    Decode(msg) => logger.write_string("JsonOutError: " + msg)
  }
}

///|
fn JsonOut::new(size_hint~ : Int32 = 1024) -> JsonOut {
  { buf: @buffer.Buffer(size_hint~), first: [true], after_key: false, }
}

///|
fn JsonOut::prefix(self : JsonOut) -> Unit {
  if self.after_key {
    self.after_key = false
  } else {
    let i = self.first.length() - 1
    if !self.first[i] {
      self.buf.write_byte(44)
    }
    self.first[i] = false
  }
}

///|
fn JsonOut::escape_bytes(self : JsonOut, bytes : BytesView) -> Unit {
  self.buf.write_byte(34)
  let mut run = 0
  for i in 0..<bytes.length() {
    let n = bytes[i].to_int()
    if n >= 32 && n != 34 && n != 92 {
      continue
    }
    if i > run {
      self.buf.write_bytesview(bytes[run:i])
    }
    match n {
      34 => self.buf.write_bytesview(b"\\\"")
      92 => self.buf.write_bytesview(b"\\\\")
      8 => self.buf.write_bytesview(b"\\b")
      12 => self.buf.write_bytesview(b"\\f")
      10 => self.buf.write_bytesview(b"\\n")
      13 => self.buf.write_bytesview(b"\\r")
      9 => self.buf.write_bytesview(b"\\t")
      _ => {
        let hex = "0123456789ABCDEF"
        self.buf.write_bytesview(b"\\u00")
        self.buf.write_byte(hex[n >> 4].to_byte())
        self.buf.write_byte(hex[n & 15].to_byte())
      }
    }
    run = i + 1
  }
  if bytes.length() > run {
    self.buf.write_bytesview(bytes[run:])
  }
  self.buf.write_byte(34)
}

///|
fn JsonOut::obj_start(self : JsonOut) -> Unit {
  self.prefix()
  self.buf.write_byte(123)
  self.first.push(true)
}

///|
fn JsonOut::obj_end(self : JsonOut) -> Unit {
  self.buf.write_byte(125)
  ignore(self.first.pop())
}

///|
fn JsonOut::arr_start(self : JsonOut) -> Unit {
  self.prefix()
  self.buf.write_byte(91)
  self.first.push(true)
}

///|
fn JsonOut::arr_end(self : JsonOut) -> Unit {
  self.buf.write_byte(93)
  ignore(self.first.pop())
}

///|
fn JsonOut::key(self : JsonOut, k : String) -> Unit {
  self.prefix()
  let mut fast = true
  for c in k {
    let n = c.to_int()
    if n >= 128 || n < 32 || n == 34 || n == 92 {
      fast = false
    }
  }
  if fast {
    self.buf.write_byte(34)
    for c in k {
      self.buf.write_byte(c.to_int().to_byte())
    }
    self.buf.write_bytesview(b"\":")
  } else {
    self.escape_bytes(@utf8.encode(k)[:])
    self.buf.write_byte(58)
  }
  self.after_key = true
}

///|
fn JsonOut::str_raw(self : JsonOut, cell : Bytes?) -> Unit {
  match cell {
    Some(bytes) => {
      self.prefix()
      self.escape_bytes(bytes[:])
    }
    None => self.null()
  }
}

///|
fn JsonOut::text_array(self : JsonOut, cell : Bytes?) -> Unit raise {
  match cell {
    None => self.null()
    Some(bytes) => {
      let view = bytes[:]
      guard view.length() >= 12 else {
        raise JsonOutError::Decode("array header")
      }
      let ndim = (view[0].to_int() << 24) |
        (view[1].to_int() << 16) |
        (view[2].to_int() << 8) |
        view[3].to_int()
      if ndim == 0 {
        self.arr_start()
        self.arr_end()
        return
      }
      guard ndim == 1 && view.length() >= 20 else {
        raise JsonOutError::Decode("text array dimensions")
      }
      let oid = (view[8].to_int() << 24) |
        (view[9].to_int() << 16) |
        (view[10].to_int() << 8) |
        view[11].to_int()
      guard oid == 25 || oid == 1043 else {
        raise JsonOutError::Decode("text array element oid")
      }
      let count = (view[12].to_int() << 24) |
        (view[13].to_int() << 16) |
        (view[14].to_int() << 8) |
        view[15].to_int()
      self.arr_start()
      let mut pos = 20
      for i in 0..<count {
        guard pos + 4 <= view.length() else {
          raise JsonOutError::Decode("text array element length")
        }
        let len = (view[pos].to_int() << 24) |
          (view[pos + 1].to_int() << 16) |
          (view[pos + 2].to_int() << 8) |
          view[pos + 3].to_int()
        pos += 4
        guard len >= 0 && pos + len <= view.length() else {
          raise JsonOutError::Decode("text array element")
        }
        if i > 0 {
          self.buf.write_byte(44)
        }
        self.escape_bytes(view[pos:pos + len])
        pos += len
      }
      self.arr_end()
    }
  }
}

///|
fn JsonOut::int64(self : JsonOut, n : Int64) -> Unit {
  self.prefix()
  if n == -9223372036854775808L {
    self.buf.write_bytesview(b"-9223372036854775808")
    return
  }
  let mut value = n
  if value < 0L {
    self.buf.write_byte(45)
    value = -value
  }
  let digits : Array[Byte] = []
  if value == 0L {
    digits.push(48)
  } else {
    while value > 0L {
      digits.push((value % 10L).to_int().to_byte() + 48)
      value /= 10L
    }
  }
  let mut i = digits.length() - 1
  while i >= 0 {
    self.buf.write_byte(digits[i])
    i -= 1
  }
}

///|
fn JsonOut::bool(self : JsonOut, b : Bool) -> Unit {
  self.prefix()
  self.buf.write_bytesview(if b { b"true" } else { b"false" })
}

///|
fn JsonOut::null(self : JsonOut) -> Unit {
  self.prefix()
  self.buf.write_bytesview(b"null")
}

///|
fn JsonOut::to_bytes(self : JsonOut) -> Bytes {
  self.buf.to_bytes()
}
