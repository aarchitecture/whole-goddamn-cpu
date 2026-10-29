///|
/// Pure codec regressions (native+wasm, no SQL): NULL -> Option None,
/// scalar NULL reject, int32 overflow reject, non-text OID String reject,
/// array TEXT quoting (empty/brace/tab/newline/lowercase-null literal),
/// binary array NULL element + malformed payload + wrong outer OID reject.

///|
fn[T : ToSql] encode_param(v : T) -> Bytes raise {
  let buf = @buffer.Buffer()
  ignore(v.to_sql(buf))
  buf.to_bytes()
}

///|
/// Build a binary text[] cell: ndim=1, hasnull flag, elem oid 25.
fn text_arr_cell(elems : Array[Bytes?], hasnull : Int32) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_int_be(1)
  buf.write_int_be(hasnull)
  buf.write_uint_be(25U)
  buf.write_int_be(@proto.i32_from_usize(elems.length()) catch { _ => 0 })
  buf.write_int_be(1)
  for e in elems {
    match e {
      Some(b) => {
        buf.write_int_be(@proto.i32_from_usize(b.length()) catch { _ => 0 })
        buf.write_bytes(b)
      }
      None => buf.write_int_be(-1)
    }
  }
  buf.to_bytes()
}

///|
fn b8(v : BytesView) -> Bytes {
  v.to_owned()
}

///|
test "option none for null" {
  let v : String? = FromSql::from_sql(25U, None)
  assert_eq(v, None)
}

///|
test "scalar null rejected" {
  let r : Int64? = Some(FromSql::from_sql(23U, None)) catch { _ => None }
  assert_eq(r is None, true)
}

///|
test "int32 overflow rejected" {
  // int8 cell = 2^32 -> Int64 decodes fine, narrowing to Int must reject
  let cell = b8(b"\x00\x00\x00\x01\x00\x00\x00\x00"[:])
  let r : Int32? = Some(FromSql::from_sql(20U, Some(cell))) catch { _ => None }
  assert_eq(r is None, true)
}

///|
test "non-text oid string rejected" {
  let cell = b8(b"\x00\x00\x00\x2a"[:])
  let r : String? = Some(FromSql::from_sql(23U, Some(cell))) catch { _ => None }
  assert_eq(r is None, true)
}

///|
test "array param always-quoted escaping" {
  let s = encode_param([
    "", "comma,value", "brace{value}", "quote\"slash\\", "NULL", "null", "tab\there",
    "nl\nhere",
  ])
  let sv = @utf8.decode(s)
  assert_eq(
    sv, "{\"\",\"comma,value\",\"brace{value}\",\"quote\\\"slash\\\\\",\"NULL\",\"null\",\"tab\there\",\"nl\nhere\"}",
  )
}

///|
test "binary text[] decodes" {
  let cell = text_arr_cell([Some(b8(b"a"[:])), Some(b8(b"b,c"[:]))], 0)
  let v : Array[String] = FromSql::from_sql(1009U, Some(cell))
  assert_eq(v, ["a", "b,c"])
}

///|
test "binary array null element rejected" {
  let cell = text_arr_cell([Some(b8(b"a"[:])), None], 1)
  let r : Array[String]? = Some(FromSql::from_sql(1009U, Some(cell))) catch {
    _ => None
  }
  assert_eq(r is None, true)
}

///|
test "malformed binary array rejected" {
  let cell = b8(b"\x00\x00\x00\x02"[:])
  let r : Array[String]? = Some(FromSql::from_sql(1009U, Some(cell))) catch {
    _ => None
  }
  assert_eq(r is None, true)
}

///|
test "wrong outer array oid rejected" {
  let cell = text_arr_cell([Some(b8(b"a"[:]))], 0)
  let r : Array[String]? = Some(FromSql::from_sql(1003U, Some(cell))) catch {
    _ => None
  }
  assert_eq(r is None, true)
}

///|
fn test_frame(body : FixedArray[Byte], tag : Byte) -> FixedArray[Byte] {
  let out : FixedArray[Byte] = FixedArray::make(body.length() + 5, b'\x00')
  out[0] = tag
  let n = body.length() + 4
  out[1] = (n >> 24).to_byte()
  out[2] = (n >> 16).to_byte()
  out[3] = (n >> 8).to_byte()
  out[4] = n.to_byte()
  body.blit_to(out, src_offset=0, dst_offset=5, len=body.length())
  out
}

///|
fn owned_fixed(f : FixedArray[Byte]) -> Bytes {
  let b = @buffer.Buffer(size_hint=f.length())
  for x in f {
    b.write_byte(x)
  }
  b.to_bytes()
}

///|
test "frame buffer one complete frame" {
  let fb = FrameBuffer::new()
  let f = test_frame(b"payload".to_fixedarray(), 68)
  fb.push(f)
  assert_eq(fb.next_frame(), Some(owned_fixed(f)))
  assert_eq(fb.buffered(), 0)
  assert_eq(fb.next_frame(), None)
}

///|
test "frame buffer two frames in one chunk" {
  let a = test_frame(b"one".to_fixedarray(), 65)
  let b = test_frame(b"two".to_fixedarray(), 66)
  let all : FixedArray[Byte] = FixedArray::make(a.length() + b.length(), 0)
  a.blit_to(all, len=a.length())
  b.blit_to(all, dst_offset=a.length(), len=b.length())
  let fb = FrameBuffer::new()
  fb.push(all)
  assert_eq(fb.next_frame(), Some(owned_fixed(a)))
  assert_eq(fb.next_frame(), Some(owned_fixed(b)))
  assert_eq(fb.next_frame(), None)
}

///|
test "frame buffer split at every boundary" {
  let f = test_frame(b"1234567".to_fixedarray(), 67)
  for k in 1..<f.length() {
    let fb = FrameBuffer::new()
    let first : FixedArray[Byte] = FixedArray::make(k, 0)
    let rest : FixedArray[Byte] = FixedArray::make(f.length() - k, 0)
    f.blit_to(first, len=k)
    f.blit_to(rest, src_offset=k, len=f.length() - k)
    fb.push(first)
    assert_eq(fb.next_frame(), None)
    fb.push(rest)
    assert_eq(fb.next_frame(), Some(owned_fixed(f)))
    assert_eq(fb.next_frame(), None)
  }
}

///|
test "frame buffer frame plus partial next" {
  let a = test_frame(b"one".to_fixedarray(), 65)
  let b = test_frame(b"two".to_fixedarray(), 66)
  let first : FixedArray[Byte] = FixedArray::make(a.length() + 3, 0)
  a.blit_to(first, len=a.length())
  b.blit_to(first, src_offset=0, dst_offset=a.length(), len=3)
  let rest : FixedArray[Byte] = FixedArray::make(b.length() - 3, 0)
  b.blit_to(rest, src_offset=3, len=b.length() - 3)
  let fb = FrameBuffer::new()
  fb.push(first)
  assert_eq(fb.next_frame(), Some(owned_fixed(a)))
  assert_eq(fb.next_frame(), None)
  fb.push(rest)
  assert_eq(fb.next_frame(), Some(owned_fixed(b)))
}

///|
test "frame buffer rejects short declared length early" {
  let fb = FrameBuffer::new()
  fb.push(b"\x44\x00\x00\x00\x03".to_fixedarray())
  let raised = try {
    ignore(fb.next_frame())
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}

///|
test "frame buffer rejects oversized declared length early" {
  let fb = FrameBuffer::new()
  fb.push(b"\x44\x01\x00\x00\x01".to_fixedarray())
  let raised = try {
    ignore(fb.next_frame())
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}

///|
test "frame buffer accepts empty body" {
  let fb = FrameBuffer::new()
  let f : FixedArray[Byte] = b"\x44\x00\x00\x00\x04".to_fixedarray()
  fb.push(f)
  assert_eq(fb.next_frame(), Some(owned_fixed(f)))
  assert_eq(fb.buffered(), 0)
}

///|
test "frame buffer handles one thousand frames" {
  let all : FixedArray[Byte] = FixedArray::make(1000 * 8, 0)
  for i in 0..<1000 {
    let off = i * 8
    all[off] = 90
    all[off + 1] = 0
    all[off + 2] = 0
    all[off + 3] = 0
    all[off + 4] = 7
    all[off + 5] = (i >> 16).to_byte()
    all[off + 6] = (i >> 8).to_byte()
    all[off + 7] = i.to_byte()
  }
  let fb = FrameBuffer::new()
  let mut pos = 0
  while pos < all.length() {
    let n = if all.length() - pos < 4096 { all.length() - pos } else { 4096 }
    let chunk : FixedArray[Byte] = FixedArray::make(n, 0)
    all.blit_to(chunk, src_offset=pos, len=n)
    fb.push(chunk)
    pos += n
    while true {
      match fb.next_frame() {
        Some(f) => assert_eq(f.length(), 8)
        None => break
      }
    }
  }
  assert_eq(fb.buffered(), 0)
  assert_eq(fb.next_frame(), None)
}

///|
test "frame bytes survive buffer growth" {
  let f = FrameBuffer::new()
  f.push([
    b'Z', b'\x00', b'\x00', b'\x00', b'\x09', b'a', b'b', b'c', b'd', b'e', b'Q',
    b'\x00', b'\x00',
  ])
  let first = f.next_frame()
  f.push(FixedArray::make(4090, b'x'))
  f.push(FixedArray::make(20000, b'y'))
  assert_eq(first, Some(b"Z\x00\x00\x00\x09abcde"))
  assert_eq(f.buffered(), 3 + 4090 + 20000)
}
