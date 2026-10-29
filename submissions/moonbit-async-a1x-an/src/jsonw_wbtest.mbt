///|
fn JsonOut::str(self : JsonOut, s : String) -> Unit {
  self.prefix()
  self.escape_bytes(@utf8.encode(s)[:])
}

///|
fn jsonw_bytes(f : (JsonOut) -> Unit) -> Bytes {
  let out = JsonOut::new()
  f(out)
  out.to_bytes()
}

///|
test "json writer exact nested object" {
  let bytes = jsonw_bytes(fn(out) {
    out.obj_start()
    out.key("a")
    out.arr_start()
    out.int64(1L)
    out.int64(2L)
    out.arr_end()
    out.key("b")
    out.obj_start()
    out.key("c")
    out.null()
    out.key("d")
    out.bool(true)
    out.obj_end()
    out.key("e")
    out.str("x")
    out.obj_end()
  })
  assert_eq(
    @utf8.decode(bytes),
    "{\"a\":[1,2],\"b\":{\"c\":null,\"d\":true},\"e\":\"x\"}",
  )
}

///|
test "json writer escaping and unicode" {
  let s = "\"\\\n\t\u{1}\u{03BB}\u{1F600}"
  let bytes = jsonw_bytes(fn(out) { out.str(s) })
  assert_eq(@utf8.decode(bytes), "\"\\\"\\\\\\n\\t\\u0001λ😀\"")
  let parsed = @json.parse(@utf8.decode(bytes))
  assert_eq(parsed.stringify(), "\"\\\"\\\\\\n\\t\\u0001λ😀\"")
}

///|
test "json writer escapes inside plain runs" {
  let s = "\"ab\\c\u{1}d\n\nλ😀e\t"
  let bytes = jsonw_bytes(fn(out) { out.str(s) })
  assert_eq(@utf8.decode(bytes), "\"\\\"ab\\\\c\\u0001d\\n\\nλ😀e\\t\"")
}

///|
test "json writer raw text" {
  let bytes = @utf8.encode("quote\"")
  let out = JsonOut::new()
  out.str_raw(Some(bytes))
  assert_eq(@utf8.decode(out.to_bytes()), "\"quote\\\"\"")
}

///|
test "json writer key fast and fallback paths" {
  let fast = jsonw_bytes(fn(out) {
    out.obj_start()
    out.key("asciiKey")
    out.int64(1L)
    out.obj_end()
  })
  assert_eq(@utf8.decode(fast), "{\"asciiKey\":1}")
  let fallback = jsonw_bytes(fn(out) {
    out.obj_start()
    out.key("é\"")
    out.null()
    out.obj_end()
  })
  assert_eq(@utf8.decode(fallback), "{\"é\\\"\":null}")
}

///|
test "json writer int64 boundaries" {
  let out = JsonOut::new()
  out.arr_start()
  out.int64(0L)
  out.int64(-1L)
  out.int64(1234567890123L)
  out.int64(9223372036854775807L)
  out.int64(-9223372036854775808L)
  out.arr_end()
  assert_eq(
    @utf8.decode(out.to_bytes()),
    "[0,-1,1234567890123,9223372036854775807,-9223372036854775808]",
  )
}

///|
fn jsonw_text_array_cell(
  ndim : Int32,
  oid : Int32,
  values : Array[Bytes?],
) -> Bytes {
  let b = @buffer.Buffer()
  b.write_int_be(ndim)
  b.write_int_be(if values.iter().any(fn(x) { x is None }) { 1 } else { 0 })
  b.write_uint_be(oid.reinterpret_as_uint())
  if ndim == 1 {
    b.write_int_be(values.length())
    b.write_int_be(1)
    for value in values {
      match value {
        Some(v) => {
          b.write_int_be(v.length())
          b.write_bytes(v)
        }
        None => b.write_int_be(-1)
      }
    }
  }
  b.to_bytes()
}

///|
test "json writer text arrays" {
  let empty = JsonOut::new()
  empty.text_array(Some(jsonw_text_array_cell(0, 25, [])))
  assert_eq(@utf8.decode(empty.to_bytes()), "[]")
  let out = JsonOut::new()
  out.text_array(
    Some(
      jsonw_text_array_cell(1, 25, [
        Some(@utf8.encode("a")),
        Some(@utf8.encode("quote\"")),
      ]),
    ),
  )
  assert_eq(@utf8.decode(out.to_bytes()), "[\"a\",\"quote\\\"\"]")
  let none = JsonOut::new()
  none.text_array(None)
  assert_eq(@utf8.decode(none.to_bytes()), "null")
}

///|
test "json writer rejects malformed text arrays" {
  let cases = [
    jsonw_text_array_cell(1, 25, [None]),
    jsonw_text_array_cell(1, 23, [Some(@utf8.encode("x"))]),
    jsonw_text_array_cell(2, 25, []),
  ]
  for cell in cases {
    let raised = try {
      let out = JsonOut::new()
      out.text_array(Some(cell))
      false
    } catch {
      _ => true
    }
    assert_eq(raised, true)
  }
}
