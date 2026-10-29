/// Vendored from hackwaly/bcrypt 0.1.0 (Apache-2.0). Private names are prefixed bc_.

///|
let magic_cipher_data : Bytes = b"OrpheanBeholderScryDoubt"

///|
/// bcrypt digest (24 bytes). Calls `pw_yield` every 16 EksBlowfish rounds so a
/// cost-10 hash does not hold the event loop for its whole duration.
async fn bc_bcrypt_hash_raw(
  password : BytesView,
  salt : BytesView,
  pwhash_cost : Int32,
) -> Bytes {
  let key = bc_bcrypt_key(password)
  let key_words = bc_stream_words(key[:], 18)
  let salt_key_words = bc_stream_words(salt, 18)
  let salt_words = bc_stream_words(salt, 4)
  let state = bc_new_blowfish_state()
  bc_blowfish_expand_key(state, salt_words, key_words)
  let rounds = 1 << pwhash_cost
  for i in 0..<rounds {
    bc_blowfish_expand_zero_key(state, key_words)
    bc_blowfish_expand_zero_key(state, salt_key_words)
    if (i & 15) == 15 {
      pw_yield()
    }
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
fn bc_bcrypt_key(password : BytesView) -> Bytes {
  let n = if password.length() > 72 { 72 } else { password.length() }
  Bytes::makei(n + 1, fn(i) { if i < n { password[i] } else { (0).to_byte() } })
}
