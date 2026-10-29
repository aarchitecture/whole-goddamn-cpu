// HS256 JWT issuing/verification via mooncred + mooncrypt, and bcrypt
// password hashing with an OS-CSPRNG salt.

///|
let token_ttl : Int64 = 30 * 24 * 3600

///|
fn now_seconds() -> Int64 {
  @env.now().reinterpret_as_int64() / 1000
}

///|
fn jwt_key(secret : String) -> @jwt.Keyed {
  let key = @utf8.encode(secret)
  @jwt.mac(fn() { @hmac.Hmac::new(key[:], fn() { @sha2.Hasher::new() }) })
}

///|
fn issue_token(key : @jwt.Keyed, id : Int64) -> String {
  let now = now_seconds()
  let claims : Map[String, Json] = Map([])
  claims["sub"] = Json::string(id.to_string())
  claims["iat"] = Json::number(now.to_double(), repr=now.to_string())
  claims["exp"] = Json::number(
    (now + token_ttl).to_double(),
    repr=(now + token_ttl).to_string(),
  )
  @jwt.sign(claims, HS256, key)
}

///|
/// Verify signature, alg (HS256 only), expiry and required claims; returns the
/// subject as a positive Int64 or 0 on any failure. No verification cache.
fn verify_token(key : @jwt.Keyed, token : StringView) -> Int64 {
  let claims = @jwt.verify(
    token,
    HS256,
    key,
    now=At(now_seconds()),
    expiry=true,
    policy=@jwt.Policy::new(required=["exp", "sub"]),
  ) catch {
    _ => return 0
  }
  match claims.get("sub") {
    Some(j) =>
      match j {
        String(s) =>
          match parse_uint(s[:]) {
            Some(id) if id > 0 => id
            _ => 0
          }
        _ => 0
      }
    None => 0
  }
}

///|
/// bcrypt cost-10 hash with a 16-byte CSPRNG salt (@env.rand uses OS
/// getentropy on native and WASI random_get under moonrun). Returns None
/// when the UTF-8 password exceeds 72 bytes (bcrypt limit).
async fn hash_password(pw : String) -> String? {
  let pw = @utf8.encode(pw)
  if pw.length() > 72 {
    return None
  }
  match @env.rand(16) {
    Some(salt) =>
      match pwhash_hash_password(pw, salt, 10) {
        Ok(h) => Some(h)
        Err(_) => None
      }
    None => None
  }
}

///|
/// Verify a plaintext password against a stored bcrypt hash. `$2a`, `$2b`
/// and `$2y` are all accepted: they diverge only on passwords longer than
/// 72 bytes, which are rejected here first. The stored hash is never
/// rewritten and results are never cached.
async fn check_password(pw : String, hash : String) -> Bool {
  let pw = @utf8.encode(pw)
  if pw.length() > 72 {
    return false
  }
  match pwhash_verify(pw, hash) {
    Ok(b) => b
    Err(_) => false
  }
}
