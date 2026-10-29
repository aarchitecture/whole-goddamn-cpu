/// Vendored from hackwaly/bcrypt 0.1.0 (Apache-2.0). Private names are prefixed bc_.
/// The hot path is rewritten for speed: flat FixedArray state, the F function
/// inlined, no tuple returns, and key/salt word streams computed once per hash.

///|
priv struct BlowfishState {
  p : FixedArray[UInt32] // 18 subkeys
  s : FixedArray[UInt32] // four 256-entry S-boxes, flat
}

///|
fn bc_new_blowfish_state() -> BlowfishState {
  let p = FixedArray::make(18, 0U)
  for i in 0..<18 {
    p[i] = init_p[i]
  }
  let s = FixedArray::make(1024, 0U)
  for i in 0..<1024 {
    s[i] = init_s[i]
  }
  { p, s, }
}

///|
/// Encrypt (l0, r0) and store the result at dst[i], dst[i + 1].
/// unsafe_get is in range: S indices are a byte value plus 0/0x100/0x200/0x300
/// (< 1024) and P indices are below 18.
fn bc_encrypt_into(
  st : BlowfishState,
  l0 : UInt32,
  r0 : UInt32,
  dst : FixedArray[UInt32],
  i : Int32,
) -> Unit {
  let p = st.p
  let s = st.s
  let mut x = l0
  let mut y = r0
  let mut k = 0
  while k < 16 {
    x = x ^ p.unsafe_get(k)
    y = y ^
      (
        (
          (
            s.unsafe_get((x >> 24).reinterpret_as_int()) +
            s.unsafe_get(0x100 + ((x >> 16) & 0xffU).reinterpret_as_int())
          ) ^
          s.unsafe_get(0x200 + ((x >> 8) & 0xffU).reinterpret_as_int())
        ) +
        s.unsafe_get(0x300 + (x & 0xffU).reinterpret_as_int())
      )
    y = y ^ p.unsafe_get(k + 1)
    x = x ^
      (
        (
          (
            s.unsafe_get((y >> 24).reinterpret_as_int()) +
            s.unsafe_get(0x100 + ((y >> 16) & 0xffU).reinterpret_as_int())
          ) ^
          s.unsafe_get(0x200 + ((y >> 8) & 0xffU).reinterpret_as_int())
        ) +
        s.unsafe_get(0x300 + (y & 0xffU).reinterpret_as_int())
      )
    k += 2
  }
  // Two rounds per iteration leave no pending swap; apply the final swap and
  // output whitening of the reference implementation. Both words are computed
  // before storing because dst may be P itself (the block written at 16/17).
  let out_l = y ^ p.unsafe_get(17)
  let out_r = x ^ p.unsafe_get(16)
  dst.unsafe_set(i, out_l)
  dst.unsafe_set(i + 1, out_r)
}

///|
/// `n` big-endian words read cyclically from `data`, continuing across words
/// (the reference stream_to_word).
fn bc_stream_words(data : BytesView, n : Int32) -> FixedArray[UInt32] {
  let out = FixedArray::make(n, 0U)
  let mut off = 0
  for w in 0..<n {
    let mut word = 0U
    for _ in 0..<4 {
      word = (word << 8) | data[off].to_uint()
      off += 1
      if off == data.length() {
        off = 0
      }
    }
    out[w] = word
  }
  out
}

///|
/// EksBlowfish ExpandKey(state, salt, key): `key_words` are the 18 key stream
/// words; `salt_words` the four salt words, consumed two per block
/// continuously across the P and S fills.
fn bc_blowfish_expand_key(
  st : BlowfishState,
  salt_words : FixedArray[UInt32],
  key_words : FixedArray[UInt32],
) -> Unit {
  let p = st.p
  let s = st.s
  for i in 0..<18 {
    p[i] = p[i] ^ key_words[i]
  }
  let mut l = 0U
  let mut r = 0U
  for i in 0..<9 {
    let o = (i & 1) * 2
    l = l ^ salt_words[o]
    r = r ^ salt_words[o + 1]
    bc_encrypt_into(st, l, r, p, i * 2)
    l = p[i * 2]
    r = p[i * 2 + 1]
  }
  for i in 0..<512 {
    let o = ((9 + i) & 1) * 2
    l = l ^ salt_words[o]
    r = r ^ salt_words[o + 1]
    bc_encrypt_into(st, l, r, s, i * 2)
    l = s.unsafe_get(i * 2)
    r = s.unsafe_get(i * 2 + 1)
  }
}

///|
/// ExpandKey(state, 0, key) with the 18 precomputed key stream words.
fn bc_blowfish_expand_zero_key(
  st : BlowfishState,
  key_words : FixedArray[UInt32],
) -> Unit {
  let p = st.p
  let s = st.s
  for i in 0..<18 {
    p[i] = p[i] ^ key_words[i]
  }
  let mut l = 0U
  let mut r = 0U
  for i in 0..<9 {
    bc_encrypt_into(st, l, r, p, i * 2)
    l = p[i * 2]
    r = p[i * 2 + 1]
  }
  for i in 0..<512 {
    bc_encrypt_into(st, l, r, s, i * 2)
    l = s.unsafe_get(i * 2)
    r = s.unsafe_get(i * 2 + 1)
  }
}
