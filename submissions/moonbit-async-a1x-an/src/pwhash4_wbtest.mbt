///|
async test "four-lane bcrypt matches the single-lane digest" {
  let passwords : Array[Bytes] = [
    b"password123", b"", b"\xff\x00\x01 long-ish password with spaces", b"x",
  ]
  let salts : Array[Bytes] = [
    b"0123456789abcdef", b"fedcba9876543210", b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
    b"saltsaltsaltsalt",
  ]
  let four = bc_bcrypt_hash_raw4(
    passwords.map(fn(p) { p[:] }),
    salts.map(fn(s) { s[:] }),
    5,
  )
  for l in 0..<4 {
    let one = bc_bcrypt_hash_raw(passwords[l][:], salts[l][:], 5)
    assert_eq(four[l], one)
    assert_eq(bc_bcrypt_hash_raw_sync(passwords[l][:], salts[l][:], 5), one)
  }
}

///|
async test "four-lane bcrypt timing at cost 10" {
  let passwords : Array[Bytes] = [b"password123", b"a", b"bb", b"ccc"]
  let salt = b"0123456789abcdef"
  let t0 = @env.now()
  for l in 0..<4 {
    let key = bc_bcrypt_key(passwords[l][:])
    let key_words = bc_stream_words(key[:], 18)
    let salt_key_words = bc_stream_words(salt[:], 18)
    let state = bc_new_blowfish_state()
    bc_blowfish_expand_key(state, bc_stream_words(salt[:], 4), key_words)
    for _ in 0..<1024 {
      bc_blowfish_expand_zero_key(state, key_words)
      bc_blowfish_expand_zero_key(state, salt_key_words)
    }
  }
  let t1 = @env.now()
  ignore(
    bc_bcrypt_hash_raw4(
      passwords.map(fn(p) { p[:] }),
      [salt[:], salt[:], salt[:], salt[:]],
      10,
    ),
  )
  let t2 = @env.now()
  println("bcrypt cost 10: 4 x single \{t1 - t0} ms, one 4-lane \{t2 - t1} ms")
}
