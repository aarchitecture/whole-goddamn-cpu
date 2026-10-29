// Regression tests for the pure validation/auth helpers used by the
// production handlers. Fixed bcrypt salt only here; production uses the
// platform CSPRNG via @env.rand (OS getentropy / WASI random_get).

///|
fn qp(pairs : Array[(String, String)]) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  for p in pairs {
    if !m.contains(p.0) {
      m[p.0] = p.1
    }
  }
  m
}

///|
test "parse_uint accepts digits within int64" {
  assert_eq(parse_uint("0"[:]), Some(0L))
  assert_eq(parse_uint("20"[:]), Some(20L))
  assert_eq(parse_uint("9223372036854775807"[:]), Some(9223372036854775807L))
}

///|
test "parse_uint rejects empty, signs, non-ascii, overflow" {
  assert_eq(parse_uint(""[:]), None)
  assert_eq(parse_uint("+1"[:]), None)
  assert_eq(parse_uint("-1"[:]), None)
  assert_eq(parse_uint(" 1"[:]), None)
  assert_eq(parse_uint("1x"[:]), None)
  assert_eq(parse_uint("１２"[:]), None)
  assert_eq(parse_uint("9223372036854775808"[:]), None)
  assert_eq(parse_uint("99999999999999999999"[:]), None)
}

///|
test "limit_offset defaults and bounds" {
  assert_eq(limit_offset(qp([])), Some((20L, 0L)))
  assert_eq(limit_offset(qp([("limit", "1")])), Some((1L, 0L)))
  assert_eq(
    limit_offset(qp([("limit", "100"), ("offset", "5")])),
    Some((100L, 5L)),
  )
  assert_eq(limit_offset(qp([("limit", "0")])), None)
  assert_eq(limit_offset(qp([("limit", "101")])), None)
  assert_eq(limit_offset(qp([("limit", "")])), None)
  assert_eq(limit_offset(qp([("limit", "+1")])), None)
  assert_eq(limit_offset(qp([("limit", "-1")])), None)
  assert_eq(limit_offset(qp([("offset", "-1")])), None)
  assert_eq(limit_offset(qp([("offset", "")])), None)
}

///|
test "read_wrapper requires the wrapper object" {
  assert_true(read_wrapper("{}", "user") is None)
  assert_true(read_wrapper("{\"user\": 5}", "user") is None)
  assert_true(read_wrapper("not json", "user") is None)
  assert_true(read_wrapper("{\"user\": {\"a\": 1}}", "user") is Some(_))
}

///|
test "string fields: required, optional, null vs absent" {
  let m = read_wrapper("{\"user\": {\"a\": \"\", \"b\": null}}", "user").unwrap()
  assert_true(req_string(m, "a") is None)
  assert_true(req_string(m, "missing") is None)
  assert_true(opt_string(m, "a", non_empty=false) is Ok(Some("")))
  assert_true(opt_string(m, "b", non_empty=false) is Ok(None))
  assert_true(opt_string(m, "missing", non_empty=false) is Ok(None))
  let m2 = read_wrapper("{\"user\": {\"a\": 7}}", "user").unwrap()
  assert_true(opt_string(m2, "a", non_empty=false) is Err(_))
}

///|
test "opt_tag_list" {
  let m = read_wrapper("{\"article\": {}}", "article").unwrap()
  assert_true(opt_tag_list(m) is Ok([]))
  let m2 = read_wrapper("{\"article\": {\"tagList\": null}}", "article").unwrap()
  assert_true(opt_tag_list(m2) is Ok([]))
  let m3 = read_wrapper(
    "{\"article\": {\"tagList\": [\"x\", \"y\"]}}", "article",
  ).unwrap()
  assert_true(opt_tag_list(m3) is Ok(["x", "y"]))
  let m4 = read_wrapper("{\"article\": {\"tagList\": [\"\"]}}", "article").unwrap()
  assert_true(opt_tag_list(m4) is Err(_))
  let m5 = read_wrapper("{\"article\": {\"tagList\": [1]}}", "article").unwrap()
  assert_true(opt_tag_list(m5) is Err(_))
}

///|
async test "hash_password rejects utf8 passwords over 72 bytes" {
  let ok71 = hash_password("a".repeat(71))
  assert_true(ok71 is Some(_))
  assert_true(hash_password("a".repeat(73)) is None)
  // multi-byte characters count by utf8 length, not chars
  assert_true(hash_password("é".repeat(37)) is None) // 74 bytes
  assert_true(hash_password("é".repeat(36)) is Some(_)) // 72 bytes
}

///|
async test "bcrypt round trip with fixed salt" {
  let salt = b"0123456789abcdef"
  match @bcrypt.hash_password(b"hunter2", salt, 10) {
    Ok(h) => {
      assert_true(h.has_prefix("$2"))
      match @bcrypt.verify(b"hunter2", h) {
        Ok(v) => assert_true(v)
        Err(_) => assert_true(false)
      }
      match @bcrypt.verify(b"hunter3", h) {
        Ok(v) => assert_true(!v)
        Err(_) => assert_true(false)
      }
    }
    Err(_) => assert_true(false)
  }
}

///|
let test_key : @jwt.Keyed = jwt_key("test-secret")

///|
test "jwt valid token round trip" {
  let tok = issue_token(test_key, 42L)
  assert_eq(verify_token(test_key, tok[:]), 42L)
}

///|
test "jwt tampered signature rejected" {
  let tok = issue_token(test_key, 42L)
  let bad = tok + "x"
  assert_eq(verify_token(test_key, bad[:]), 0L)
  let bad2 = tok[:tok.length() - 4].to_owned() + "AAAA"
  assert_eq(verify_token(test_key, bad2[:]), 0L)
}

///|
fn sign_claims(claims : Map[String, Json]) -> String {
  @jwt.sign(claims, HS256, test_key)
}

///|
test "jwt expired rejected" {
  let claims : Map[String, Json] = Map([])
  claims["sub"] = Json::string("42")
  claims["exp"] = Json::number(1000.0, repr="1000")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
}

///|
test "jwt missing exp or sub rejected" {
  let claims : Map[String, Json] = Map([])
  claims["sub"] = Json::string("42")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
  let claims2 : Map[String, Json] = Map([])
  claims2["exp"] = Json::number(9999999999.0, repr="9999999999")
  assert_eq(verify_token(test_key, sign_claims(claims2)[:]), 0L)
}

///|
test "jwt bad sub rejected" {
  let claims : Map[String, Json] = Map([])
  claims["sub"] = Json::string("not-a-number")
  claims["exp"] = Json::number(9999999999.0, repr="9999999999")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
  claims["sub"] = Json::string("0")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
  claims["sub"] = Json::string("-1")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
}

///|
test "jwt wrong algorithm rejected" {
  let claims : Map[String, Json] = Map([])
  claims["sub"] = Json::string("42")
  claims["exp"] = Json::number(9999999999.0, repr="9999999999")
  // sign a valid HS384 token with the SAME secret; verification must still
  // reject it because only HS256 is accepted
  let hs384 = @jwt.mac(fn() {
    @hmac.Hmac::new(@utf8.encode("test-secret")[:], fn() {
      @sha2.Hasher::new(kind=@sha2.Kind::Sha384)
    })
  })
  let tok = @jwt.sign(claims, HS384, hs384)
  assert_eq(verify_token(test_key, tok[:]), 0L)
  // alg=none hand-forged: header {"alg":"none"} + claims + empty signature
  let forged = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiI0MiIsImV4cCI6OTk5OTk5OTk5OX0."
  assert_eq(verify_token(test_key, forged[:]), 0L)
}

///|
test "jwt wrong secret rejected" {
  let tok = issue_token(test_key, 42L)
  let other_key = jwt_key("other-secret")
  assert_eq(verify_token(other_key, tok[:]), 0L)
}

///|
test "jwt numeric and overflow sub rejected" {
  let claims : Map[String, Json] = Map([])
  claims["exp"] = Json::number(9999999999.0, repr="9999999999")
  claims["sub"] = Json::number(42.0, repr="42")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
  claims["sub"] = Json::string("99999999999999999999")
  assert_eq(verify_token(test_key, sign_claims(claims)[:]), 0L)
}

///|
test "percent_decode basic, plus and malformed" {
  assert_eq(
    percent_decode("hello%20world", plus_space=false),
    Some("hello world"),
  )
  assert_eq(percent_decode("a+b", plus_space=true), Some("a b"))
  assert_eq(percent_decode("a+b", plus_space=false), Some("a+b"))
  assert_eq(percent_decode("%E2%82%AC", plus_space=false), Some("€"))
  assert_eq(percent_decode("%zz", plus_space=false), None)
  assert_eq(percent_decode("%41", plus_space=false), Some("A"))
  assert_eq(percent_decode("abc%", plus_space=false), None)
  assert_eq(percent_decode("%4", plus_space=false), None)
}

///|
test "split_target decodes segments and first duplicate query wins" {
  match split_target("/api/articles?limit=5&limit=9&author=a+b") {
    Some((segs, params)) => {
      assert_eq(segs, ["api", "articles"])
      assert_eq(params.get("limit"), Some("5"))
      assert_eq(params.get("author"), Some("a b"))
    }
    None => assert_true(false)
  }
  match split_target("/api/articles/x%2Fy") {
    Some((segs, _)) => assert_eq(segs, ["api", "articles", "x/y"])
    None => assert_true(false)
  }
  assert_true(split_target("/api/%zz") is None)
}

///|
test "response_bytes exact framing" {
  let body = b"{\"a\":1}"
  assert_eq(
    response_bytes(200, false, false, body),
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}",
  )
  assert_eq(
    response_bytes(204, false, false, b""),
    b"HTTP/1.1 204 No Content\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n",
  )
  assert_eq(
    response_bytes(200, true, false, body),
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n",
  )
  assert_eq(
    response_bytes(422, false, true, body),
    b"HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 7\r\n\r\n{\"a\":1}",
  )
}

///|
test "parse_database_url challenge form and rejection cases" {
  let db = parse_database_url(
    "postgres://conduit:conduit@127.0.0.1:5432/conduit",
  )
  assert_eq(db.host, "127.0.0.1")
  assert_eq(db.port, 5432)
  assert_eq(db.user, "conduit")
  assert_eq(db.password, Some("conduit"))
  assert_eq(db.dbname, "conduit")
  // unsupported scheme rejected
  assert_true(
    (Ok(parse_database_url("mysql://u:p@h/db")) catch { e => Err(e) }) is Err(_),
  )
  // malformed percent-encoded password rejected
  assert_true(
    (Ok(parse_database_url("postgres://u:%zz@h/db")) catch { e => Err(e) })
    is Err(_),
  )
}

///|
async test "check_password seeded $2a hash" {
  // Actual bench/seed/seed.go constant (verification-only 2a->2b shim).
  let seed_hash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
  assert_true(check_password("password123", seed_hash))
  assert_true(!check_password("password124", seed_hash))
}

///|
async test "check_password 2a/2b/2y standard vector" {
  // Known bcrypt test vector (password = "password"), prefix substituted.
  for prefix in ["$2a$", "$2b$", "$2y$"] {
    let h = prefix + "05$abcdefghijklmnopqrstuuWG29KuyeAicPCJODk1zjyGvyQUU2awu"
    assert_true(check_password("password", h))
    assert_true(!check_password("wrong", h))
  }
}

///|
async test "check_password malformed, unsupported and overlong" {
  assert_true(!check_password("password", "not-a-hash"))
  assert_true(
    !check_password(
      "password", "$2x$05$abcdefghijklmnopqrstuuWG29KuyeAicPCJODk1zjyGvyQUU2awu",
    ),
  )
  // 73-byte password rejected even against a valid 2a hash
  let seed_hash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
  assert_true(!check_password("p".repeat(73), seed_hash))
}

///|
async test "check_password 72-byte utf8 round trip via 2a" {
  // Fixed salt + low cost in the unit test only; flip generated $2b to $2a
  // and verify both directions.
  let salt = b"0123456789abcdef"
  let pw = "é".repeat(36) // exactly 72 utf8 bytes
  let wrong = "é".repeat(35) + "x"
  match @bcrypt.hash_password(@utf8.encode(pw), salt, 4) {
    Ok(h2b) => {
      let h2a = "$2a$" + h2b[4:].to_owned()
      assert_true(check_password(pw, h2a))
      assert_true(!check_password(wrong, h2a))
    }
    Err(_) => assert_true(false)
  }
}

///|
test "env.rand returns 16 bytes" {
  match @env.rand(16) {
    Some(b) => assert_eq(b.length(), 16)
    None => assert_true(false)
  }
}

///|
async test "bcrypt generated hash has cost 10" {
  match hash_password("pw12345") {
    Some(h) => {
      assert_true(
        h.has_prefix("$2a$10$") ||
        h.has_prefix("$2b$10$") ||
        h.has_prefix("$2y$10$"),
      )
      match @bcrypt.cost(h) {
        Ok(c) => assert_eq(c, 10)
        Err(_) => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}
