///|
priv struct BlowfishState4 {
  p : FixedArray[UInt32]
  s : FixedArray[UInt32]
}

///|
fn bc_new_blowfish_state4() -> BlowfishState4 {
  let p = FixedArray::make(72, 0U)
  let s = FixedArray::make(4096, 0U)
  for l in 0..<4 {
    for i in 0..<18 {
      p[l * 18 + i] = init_p[i]
    }
    for i in 0..<1024 {
      s[l * 1024 + i] = init_s[i]
    }
  }
  { p, s }
}

///|
fn bc_f4(s : FixedArray[UInt32], base : Int32, x : UInt32) -> UInt32 {
  (
    (
      s.unsafe_get(base + (x >> 24).reinterpret_as_int()) +
      s.unsafe_get(base + 0x100 + ((x >> 16) & 0xffU).reinterpret_as_int())
    ) ^
    s.unsafe_get(base + 0x200 + ((x >> 8) & 0xffU).reinterpret_as_int())
  ) +
  s.unsafe_get(base + 0x300 + (x & 0xffU).reinterpret_as_int())
}

///|
fn bc_encrypt4(st : BlowfishState4, io : FixedArray[UInt32]) -> Unit {
  let p = st.p
  let s = st.s
  let mut x0 = io.unsafe_get(0)
  let mut y0 = io.unsafe_get(1)
  let mut x1 = io.unsafe_get(2)
  let mut y1 = io.unsafe_get(3)
  let mut x2 = io.unsafe_get(4)
  let mut y2 = io.unsafe_get(5)
  let mut x3 = io.unsafe_get(6)
  let mut y3 = io.unsafe_get(7)
  let mut k = 0
  while k < 16 {
    x0 = x0 ^ p.unsafe_get(k)
    x1 = x1 ^ p.unsafe_get(18 + k)
    x2 = x2 ^ p.unsafe_get(36 + k)
    x3 = x3 ^ p.unsafe_get(54 + k)
    y0 = y0 ^ bc_f4(s, 0, x0) ^ p.unsafe_get(k + 1)
    y1 = y1 ^ bc_f4(s, 1024, x1) ^ p.unsafe_get(19 + k)
    y2 = y2 ^ bc_f4(s, 2048, x2) ^ p.unsafe_get(37 + k)
    y3 = y3 ^ bc_f4(s, 3072, x3) ^ p.unsafe_get(55 + k)
    x0 = x0 ^ bc_f4(s, 0, y0)
    x1 = x1 ^ bc_f4(s, 1024, y1)
    x2 = x2 ^ bc_f4(s, 2048, y2)
    x3 = x3 ^ bc_f4(s, 3072, y3)
    k += 2
  }
  io.unsafe_set(0, y0 ^ p.unsafe_get(17))
  io.unsafe_set(1, x0 ^ p.unsafe_get(16))
  io.unsafe_set(2, y1 ^ p.unsafe_get(35))
  io.unsafe_set(3, x1 ^ p.unsafe_get(34))
  io.unsafe_set(4, y2 ^ p.unsafe_get(53))
  io.unsafe_set(5, x2 ^ p.unsafe_get(52))
  io.unsafe_set(6, y3 ^ p.unsafe_get(71))
  io.unsafe_set(7, x3 ^ p.unsafe_get(70))
}

///|
fn bc_store4(
  dst : FixedArray[UInt32],
  stride : Int32,
  i : Int32,
  io : FixedArray[UInt32],
) -> Unit {
  for l in 0..<4 {
    dst.unsafe_set(l * stride + i, io.unsafe_get(2 * l))
    dst.unsafe_set(l * stride + i + 1, io.unsafe_get(2 * l + 1))
  }
}

///|
fn bc_expand_key4(
  st : BlowfishState4,
  salt_words : FixedArray[UInt32],
  key_words : FixedArray[UInt32],
  io : FixedArray[UInt32],
) -> Unit {
  for i in 0..<72 {
    st.p[i] = st.p[i] ^ key_words[i]
  }
  io.fill(0U)
  for i in 0..<9 {
    let o = (i & 1) * 2
    for l in 0..<4 {
      io[2 * l] = io[2 * l] ^ salt_words[l * 4 + o]
      io[2 * l + 1] = io[2 * l + 1] ^ salt_words[l * 4 + o + 1]
    }
    bc_encrypt4(st, io)
    bc_store4(st.p, 18, i * 2, io)
  }
  for i in 0..<512 {
    let o = ((9 + i) & 1) * 2
    for l in 0..<4 {
      io[2 * l] = io[2 * l] ^ salt_words[l * 4 + o]
      io[2 * l + 1] = io[2 * l + 1] ^ salt_words[l * 4 + o + 1]
    }
    bc_encrypt4(st, io)
    bc_store4(st.s, 1024, i * 2, io)
  }
}

///|
fn bc_expand_zero_key4(
  st : BlowfishState4,
  key_words : FixedArray[UInt32],
  io : FixedArray[UInt32],
) -> Unit {
  let p = st.p
  for i in 0..<72 {
    p.unsafe_set(i, p.unsafe_get(i) ^ key_words.unsafe_get(i))
  }
  io.fill(0U)
  for i in 0..<9 {
    bc_encrypt4(st, io)
    bc_store4(p, 18, i * 2, io)
  }
  let s = st.s
  for i in 0..<512 {
    bc_encrypt4(st, io)
    bc_store4(s, 1024, i * 2, io)
  }
}

///|
fn bc_bcrypt_hash_raw_sync(
  password : BytesView,
  salt : BytesView,
  cost : Int32,
) -> Bytes {
  let key = bc_bcrypt_key(password)
  let key_words = bc_stream_words(key[:], 18)
  let salt_key_words = bc_stream_words(salt, 18)
  let state = bc_new_blowfish_state()
  bc_blowfish_expand_key(state, bc_stream_words(salt, 4), key_words)
  for _ in 0..<(1 << cost) {
    bc_blowfish_expand_zero_key(state, key_words)
    bc_blowfish_expand_zero_key(state, salt_key_words)
  }
  let cdata = bc_stream_words(magic_cipher_data[:], 6)
  for _ in 0..<64 {
    for j in 0..<3 {
      bc_encrypt_into(state, cdata[j * 2], cdata[j * 2 + 1], cdata, j * 2)
    }
  }
  Bytes::makei(24, fn(i) { (cdata[i >> 2] >> (24 - 8 * (i & 3))).to_byte() })
}

///|
fn bc_bcrypt_hash_raw4(
  passwords : Array[BytesView],
  salts : Array[BytesView],
  cost : Int32,
) -> Array[Bytes] {
  let key_words = FixedArray::make(72, 0U)
  let salt_key_words = FixedArray::make(72, 0U)
  let salt_words = FixedArray::make(16, 0U)
  for l in 0..<4 {
    let key = bc_bcrypt_key(passwords[l])
    let kw = bc_stream_words(key[:], 18)
    let skw = bc_stream_words(salts[l], 18)
    let sw = bc_stream_words(salts[l], 4)
    for i in 0..<18 {
      key_words[l * 18 + i] = kw[i]
      salt_key_words[l * 18 + i] = skw[i]
    }
    for i in 0..<4 {
      salt_words[l * 4 + i] = sw[i]
    }
  }
  let st = bc_new_blowfish_state4()
  let io = FixedArray::make(8, 0U)
  bc_expand_key4(st, salt_words, key_words, io)
  for _ in 0..<(1 << cost) {
    bc_expand_zero_key4(st, key_words, io)
    bc_expand_zero_key4(st, salt_key_words, io)
  }
  let c = bc_stream_words(magic_cipher_data[:], 6)
  let cd = FixedArray::make(24, 0U)
  for l in 0..<4 {
    for j in 0..<6 {
      cd[l * 6 + j] = c[j]
    }
  }
  for _ in 0..<64 {
    for j in 0..<3 {
      for l in 0..<4 {
        io[2 * l] = cd[l * 6 + j * 2]
        io[2 * l + 1] = cd[l * 6 + j * 2 + 1]
      }
      bc_encrypt4(st, io)
      bc_store4(cd, 6, j * 2, io)
    }
  }
  Array::makei(4, fn(l) {
    Bytes::makei(24, fn(i) {
      (cd[l * 6 + (i >> 2)] >> (24 - 8 * (i & 3))).to_byte()
    })
  })
}
