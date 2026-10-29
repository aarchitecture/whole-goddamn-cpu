/// Vendored from hackwaly/bcrypt 0.1.0 (Apache-2.0). Private names are prefixed bc_.

///|
pub let min_cost = 4

///|
pub let max_cost = 31

///|
pub let salt_length = 16

///|
pub let hash_length = 60

///|
pub suberror PwhashError {
  InvalidCost(Int32)
  InvalidSaltLength(Int32)
  InvalidHashFormat
  UnsupportedVersion(String)
  InvalidBase64
} derive(Eq, Debug)

///|
pub impl Show for PwhashError with fn output(self, logger) {
  match self {
    InvalidCost(n) => {
      logger.write_string("InvalidCost(")
      logger.write_object(n)
      logger.write_string(")")
    }
    InvalidSaltLength(n) => {
      logger.write_string("InvalidSaltLength(")
      logger.write_object(n)
      logger.write_string(")")
    }
    InvalidHashFormat => logger.write_string("InvalidHashFormat")
    UnsupportedVersion(v) => {
      logger.write_string("UnsupportedVersion(")
      logger.write_string(v)
      logger.write_string(")")
    }
    InvalidBase64 => logger.write_string("InvalidBase64")
  }
}

///|
priv struct ParsedHash {
  minor : Char
  cost : Int32
  salt_text : String
  salt : Bytes
}

///|
pub async fn pwhash_hash_password(
  password : Bytes,
  salt : Bytes,
  cost : Int32,
) -> Result[String, PwhashError] {
  if cost < min_cost || cost > max_cost {
    Err(InvalidCost(cost))
  } else if salt.length() != salt_length {
    Err(InvalidSaltLength(salt.length()))
  } else {
    let salt_text = bc_bcrypt_base64_encode(salt[:], salt_length)
    let digest = bc_digest(password[:], salt[:], cost)
    let hash_text = bc_bcrypt_base64_encode(digest[:], 23)
    Ok("$2b$" + bc_two_digit(cost) + "$" + salt_text + hash_text)
  }
}

///|
pub async fn pwhash_verify(
  password : Bytes,
  hash : String,
) -> Result[Bool, PwhashError] {
  match parse_hash(hash) {
    Err(err) => Err(err)
    Ok(parsed) => {
      let digest = bc_digest(password[:], parsed.salt[:], parsed.cost)
      let recomputed = "$2" +
        parsed.minor.to_string() +
        "$" +
        bc_two_digit(parsed.cost) +
        "$" +
        parsed.salt_text +
        bc_bcrypt_base64_encode(digest[:], 23)
      Ok(bc_timing_safe_equal(hash, recomputed))
    }
  }
}

///|
pub fn pwhash_cost(hash : String) -> Result[Int32, PwhashError] {
  match parse_hash(hash) {
    Err(err) => Err(err)
    Ok(parsed) => Ok(parsed.cost)
  }
}

///|
fn parse_hash(hash : String) -> Result[ParsedHash, PwhashError] {
  if hash.length() != hash_length {
    Err(InvalidHashFormat)
  } else if hash[0].to_int() != '$'.to_int() ||
    hash[1].to_int() != '2'.to_int() ||
    hash[3].to_int() != '$'.to_int() ||
    hash[6].to_int() != '$'.to_int() {
    Err(InvalidHashFormat)
  } else {
    let minor = hash.get_char(2).unwrap()
    if minor != 'a' && minor != 'b' && minor != 'y' {
      Err(UnsupportedVersion("2" + minor.to_string()))
    } else if !bc_is_ascii_digit_code(hash[4].to_int()) ||
      !bc_is_ascii_digit_code(hash[5].to_int()) {
      Err(InvalidHashFormat)
    } else {
      let parsed_cost = (hash[4].to_int() - '0'.to_int()) * 10 +
        (hash[5].to_int() - '0'.to_int())
      if parsed_cost < min_cost || parsed_cost > max_cost {
        Err(InvalidCost(parsed_cost))
      } else {
        let salt_text = hash.unsafe_substring(start=7, end=29)
        match bc_bcrypt_base64_decode(salt_text, salt_length) {
          Err(_) => Err(InvalidBase64)
          Ok(salt) =>
            if !bc_bcrypt_base64_all_valid(
                hash.unsafe_substring(start=29, end=60),
              ) {
              Err(InvalidBase64)
            } else {
              Ok({ minor, cost: parsed_cost, salt_text, salt, })
            }
        }
      }
    }
  }
}

///|
fn bc_two_digit(n : Int32) -> String {
  let tens = n / 10 + '0'.to_int()
  let ones = n % 10 + '0'.to_int()
  String::from_array([tens.unsafe_to_char(), ones.unsafe_to_char()])
}

///|
fn bc_is_ascii_digit_code(code : Int32) -> Bool {
  code >= '0'.to_int() && code <= '9'.to_int()
}

///|
fn bc_timing_safe_equal(a : String, b : String) -> Bool {
  let mut diff = a.length() ^ b.length()
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    diff = diff | (a[i].to_int() ^ b[i].to_int())
  }
  diff == 0
}
