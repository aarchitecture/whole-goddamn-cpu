///|
/// Deterministic pseudo-random bytes (LCG) for equivalence tests.
fn pw_test_bytes(state : Ref[UInt32], n : Int32) -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<n {
    state.val = state.val * 1103515245U + 12345U
    out.push((state.val >> 16).to_byte())
  }
  Bytes::from_array(out[:])
}

///|
async test "pwhash matches hackwaly/bcrypt at cost 4" {
  let st = Ref(20261025U)
  for c in 0..<200 {
    let pw = pw_test_bytes(st, c % 73)
    let salt = pw_test_bytes(st, 16)
    guard pwhash_hash_password(pw, salt, 4) is Ok(new_h) else {
      fail("new hash")
    }
    guard @bcrypt.hash_password(pw, salt, 4) is Ok(old_h) else {
      fail("old hash")
    }
    assert_eq(new_h, old_h)
    assert_true(pwhash_verify(pw, old_h) is Ok(true))
    assert_true(@bcrypt.verify(pw, new_h) is Ok(true))
    let changed = if pw.length() > 0 {
      Bytes::makei(pw.length(), fn(i) {
        if i == 0 {
          (pw[0].to_int() ^ 1).to_byte()
        } else {
          pw[i]
        }
      })
    } else {
      b"x"
    }
    assert_true(pwhash_verify(changed, new_h) is Ok(false))
  }
}

///|
async test "pwhash verifies the seed hash at cost 10" {
  let h = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
  let tail = h[4:].to_owned()
  assert_true(pwhash_verify(b"password123", h) is Ok(true))
  assert_true(pwhash_verify(b"password123", "$2b$" + tail) is Ok(true))
  assert_true(pwhash_verify(b"password123", "$2y$" + tail) is Ok(true))
  assert_true(pwhash_verify(b"password124", h) is Ok(false))
  assert_true(check_password("password123", h))
  assert_false(check_password("password124", h))
}

///|
async test "pwhash rejects malformed hashes" {
  let tail = "ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
  for
    h in [
      "",
      "$2x$10$" + tail,
      "$2b$32$" + tail,
      "$2b$03$" + tail,
      "$2b$10$" + tail[:40].to_owned(),
      "$2b$10$" + tail + "Q",
      "$2b$10$!" + tail[1:].to_owned(),
      "$2b10$" + tail,
    ] {
    assert_false(check_password("password123", h))
  }
}
