///|
/// Pure codec layer for the WASI 0.3 PG facade - mirrors the subset of the
/// pinned moonbit-community/postgres@0.1.3 client API used by the unchanged
/// business files. TEXT bind parameters, BINARY result decoding.
/// This package is platform-independent (native+wasm targets).

///|
pub(all) enum SslMode {
  Disable
}

///|
/// Backend error payload exposed to callers as `Database(d) => d.code`.
pub struct DatabaseError {
  code : String?
  message : String
}

///|
pub fn DatabaseError::new(code : String?, message : String) -> DatabaseError {
  { code, message, }
}

///|
pub(all) suberror ClientError {
  Database(DatabaseError)
  Decode(String)
  Protocol(String)
  Io(String)
}

///|
pub struct Type {
  oid : @proto.Oid
}

///|
pub fn Type::int8() -> Type {
  { oid: 20U, }
}

///|
pub fn Type::text() -> Type {
  { oid: 25U, }
}

///|
pub fn Type::from_oid(oid : @proto.Oid) -> Type {
  { oid, }
}

///|
pub fn Type::oid(self : Type) -> @proto.Oid {
  self.oid
}

///|
/// Buffered backend-frame bytes shared by all queries on one connection.
pub struct FrameBuffer {
  priv mut data : FixedArray[Byte]
  priv mut start : Int32
  priv mut len : Int32
}

///|
/// Create an empty receive buffer.
pub fn FrameBuffer::new() -> FrameBuffer {
  { data: FixedArray::make(4096, 0), start: 0, len: 0, }
}

///|
/// Append a received chunk, compacting consumed bytes and growing
/// geometrically so fragmented frames remain amortized linear.
pub fn FrameBuffer::push(self : FrameBuffer, chunk : FixedArray[Byte]) -> Unit {
  let needed = self.len + chunk.length()
  if self.start + needed > self.data.length() {
    if needed <= self.data.length() {
      self.data.blit_to(
        self.data,
        src_offset=self.start,
        dst_offset=0,
        len=self.len,
      )
      self.start = 0
    } else {
      let mut capacity = self.data.length()
      while capacity < needed {
        capacity = capacity * 2
      }
      let next : FixedArray[Byte] = FixedArray::make(capacity, b'\x00')
      self.data.blit_to(next, src_offset=self.start, dst_offset=0, len=self.len)
      self.data = next
      self.start = 0
    }
  }
  chunk.blit_to(
    self.data,
    src_offset=0,
    dst_offset=self.start + self.len,
    len=chunk.length(),
  )
  self.len = needed
}

///|
/// Return the next complete backend frame, retaining incomplete bytes.
/// The declared length includes its four-byte length field.
pub fn FrameBuffer::next_frame(self : FrameBuffer) -> Bytes? raise ClientError {
  if self.len < 5 {
    return None
  }
  let h = self.start
  let declared = (self.data[h + 1].to_int() << 24) |
    (self.data[h + 2].to_int() << 16) |
    (self.data[h + 3].to_int() << 8) |
    self.data[h + 4].to_int()
  if declared < 4 || declared > 16777216 {
    raise ClientError::Protocol("frame length " + declared.to_string())
  }
  let total = declared + 1
  if self.len < total {
    return None
  }
  let frame : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  self.data.blit_to(frame, src_offset=self.start, dst_offset=0, len=total)
  self.start += total
  self.len -= total
  if self.len == 0 {
    self.start = 0
  }
  Some(frame.unsafe_reinterpret_as_bytes())
}

///|
/// Number of unread bytes currently retained.
pub fn FrameBuffer::buffered(self : FrameBuffer) -> Int32 {
  self.len
}

///|
/// One result row: column OIDs + nullable raw cells (binary format).
pub struct Row {
  priv oids : Array[@proto.Oid]
  priv cells : Array[Bytes?]
}

///|
/// Public checked constructor used by the transport layer.
pub fn Row::from_parts(
  oids : Array[@proto.Oid],
  cells : Array[Bytes?],
) -> Row raise ClientError {
  if oids.length() != cells.length() {
    raise ClientError::Decode("oid/cell count mismatch")
  }
  { oids, cells, }
}

///|
/// Row.get: bounds-checked; NULL cells dispatch through FromSql so
/// Option[T] returns None for SQL NULL.
pub fn[T : FromSql] Row::get(self : Row, i : Int32) -> T raise ClientError {
  if i < 0 || i >= self.cells.length() {
    raise ClientError::Decode("column index out of range")
  }
  FromSql::from_sql(self.oids[i], self.cells[i])
}

///|
/// Return the stored nullable binary cell for direct UTF-8 JSON emission.
pub fn Row::len(self : Row) -> Int32 {
  self.cells.length()
}

///|
pub fn Row::get_raw(self : Row, i : Int32) -> Bytes? {
  if i < 0 || i >= self.cells.length() {
    return None
  }
  self.cells[i]
}

///|
pub(open) trait ToSql {
  /// Write the TEXT-format parameter value; IsNull::Yes encodes SQL NULL.
  fn to_sql(Self, @buffer.Buffer) -> @proto.IsNull raise @proto.ProtocolError
}

///|
/// Decode one BINARY-format cell. `cell` is None for SQL NULL; scalar impls
/// reject it, Option[T] returns None.
pub(open) trait FromSql {
  fn from_sql(@proto.Oid, Bytes?) -> Self raise ClientError
}

///|
fn err_decode(msg : String) -> ClientError {
  ClientError::Decode(msg)
}

///|
/// Map a pinned codec ProtocolError into ClientError.
fn[T] pe(f : () -> T raise @proto.ProtocolError) -> T raise ClientError {
  f() catch {
    _ => raise err_decode("protocol codec")
  }
}

///|
pub impl ToSql for String with fn to_sql(self, buf) {
  buf.write_bytesview(@proto.utf8_encode(self)[:])
  @proto.IsNull::No
}

///|
pub impl ToSql for Int64 with fn to_sql(self, buf) {
  buf.write_bytesview(@proto.utf8_encode(self.to_string())[:])
  @proto.IsNull::No
}

///|
pub impl ToSql for Int32 with fn to_sql(self, buf) {
  buf.write_bytesview(@proto.utf8_encode(self.to_string())[:])
  @proto.IsNull::No
}

///|
pub impl ToSql for Bool with fn to_sql(self, buf) {
  buf.write_bytesview(@proto.utf8_encode(if self { "t" } else { "f" })[:])
  @proto.IsNull::No
}

///|
/// PG text[] TEXT parameter: every element is ALWAYS double-quoted; only
/// quote/backslash are escaped inside the quotes. Correct for empty strings,
/// braces, whitespace, and literal NULL in any case.
pub impl ToSql for Array[String] with fn to_sql(self, buf) {
  buf.write_byte(123) // '{'
  let mut first = true
  for e in self {
    if !first {
      buf.write_byte(44)
    } // ','
    first = false
    buf.write_byte(34) // '"'
    for c in e {
      if c.to_int() == 34 || c.to_int() == 92 {
        buf.write_byte(92) // backslash escape
      }
      buf.write_bytesview(@proto.utf8_encode(c.to_string())[:])
    }
    buf.write_byte(34) // '"'
  }
  buf.write_byte(125) // '}'
  @proto.IsNull::No
}

///|

///|
pub impl[T : ToSql] ToSql for T? with fn to_sql(self, buf) {
  match self {
    Some(v) => v.to_sql(buf)
    None => @proto.IsNull::Yes
  }
}

///|
pub impl FromSql for Int64 with fn from_sql(oid, cell) {
  let c = match cell {
    Some(c) => c
    None => raise err_decode("unexpected NULL int64")
  }
  match oid {
    20U => pe(() => @types.int8_from_sql(c))
    23U => pe(() => @types.int4_from_sql(c).to_int64())
    21U => pe(() => @types.int2_from_sql(c).to_int64())
    _ => raise err_decode("int64 from oid " + oid.to_string())
  }
}

///|
/// Int narrows through Int64 with an explicit range check before to_int.
pub impl FromSql for Int32 with fn from_sql(oid, cell) {
  let v : Int64 = FromSql::from_sql(oid, cell)
  if v < -2147483648L || v > 2147483647L {
    raise err_decode("int32 overflow")
  }
  v.to_int()
}

///|
pub impl FromSql for Bool with fn from_sql(oid, cell) {
  let c = match cell {
    Some(c) => c
    None => raise err_decode("unexpected NULL bool")
  }
  if oid == 16U {
    pe(() => @types.bool_from_sql(c))
  } else {
    raise err_decode("bool from oid " + oid.to_string())
  }
}

///|
/// Only real text-family OIDs decode to String; other binary formats
/// (e.g. int4 bytes) are rejected instead of mangled through utf8.
pub impl FromSql for String with fn from_sql(oid, cell) {
  let c = match cell {
    Some(c) => c
    None => raise err_decode("unexpected NULL text")
  }
  match oid {
    25U | 1043U | 1042U | 19U | 18U =>
      match (Some(@utf8.decode(c[:])) catch { _ => None }) {
        Some(s) => s
        None => raise err_decode("invalid utf8 text cell")
      }
    _ => raise err_decode("string from oid " + oid.to_string())
  }
}

///|
/// Binary text[]/varchar[] decoding via the pinned PgArray parser.
/// Validates element OID (25/1043), ndim 0 or 1, and rejects NULL elements
/// for the non-nullable Array[String] view.
pub impl FromSql for Array[String] with fn from_sql(oid, cell) {
  // outer column OID must be text[]/varchar[] before parsing the payload
  if oid != 1009U && oid != 1015U {
    raise err_decode("text[] column oid " + oid.to_string())
  }
  let c = match cell {
    Some(c) => c
    None => raise err_decode("unexpected NULL array")
  }
  let arr = pe(() => @types.array_from_sql(c))
  if arr.element_type != 25U && arr.element_type != 1043U {
    raise err_decode("text[] element oid " + arr.element_type.to_string())
  }
  if arr.dimensions != 0 && arr.dimensions != 1 {
    raise err_decode("text[] ndim " + arr.dimensions.to_string())
  }
  if arr.has_nulls {
    raise err_decode("text[] contains NULL elements")
  }
  let out : Array[String] = []
  let vals = arr.values()
  while true {
    match (vals.next() catch { _ => raise err_decode("array values") }) {
      Some(Some(b)) =>
        match (Some(@utf8.decode(b[:])) catch { _ => None }) {
          Some(s) => out.push(s)
          None => raise err_decode("bad utf8 array element")
        }
      Some(None) => raise err_decode("NULL array element")
      None => break
    }
  }
  out
}

///|
/// Option[T]: NULL -> None; non-NULL delegates to the inner decoder.
pub impl[T : FromSql] FromSql for T? with fn from_sql(oid, cell) {
  match cell {
    None => None
    Some(c) => Some(FromSql::from_sql(oid, Some(c)))
  }
}
