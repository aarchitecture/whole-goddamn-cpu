// Shared helpers: integer/query/url parsing and JSON body field extraction.

///|
/// Accept only ASCII digits that fit in a non-negative Int64 (matches the Go
/// reference's parseUint).
fn parse_uint(s : StringView) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let mut n : Int64 = 0
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
    let d = (c.to_int() - '0'.to_int()).to_int64()
    if n > 922337203685477580L || (n == 922337203685477580L && d > 7) {
      return None
    }
    n = n * 10 + d
  }
  Some(n)
}

///|
fn hex_val(b : Byte) -> Int32 {
  match b {
    b'0'..<=b'9' => b.to_int() - b'0'.to_int()
    b'a'..<=b'f' => b.to_int() - b'a'.to_int() + 10
    b'A'..<=b'F' => b.to_int() - b'A'.to_int() + 10
    _ => -1
  }
}

///|
/// Percent-decode a URL component. When `plus_space` is true '+' decodes to
/// ' ' (application/x-www-form-urlencoded query semantics).
fn percent_decode(s : String, plus_space~ : Bool) -> String? {
  let raw = @utf8.encode(s)
  let out : Array[Byte] = []
  let mut i = 0
  while i < raw.length() {
    let b = raw[i]
    if b == '%'.to_int().to_byte() {
      if i + 2 >= raw.length() {
        return None
      }
      let hi = hex_val(raw[i + 1])
      let lo = hex_val(raw[i + 2])
      if hi < 0 || lo < 0 {
        return None
      }
      out.push((hi * 16 + lo).to_byte())
      i += 3
    } else if b == '+'.to_int().to_byte() && plus_space {
      out.push(' '.to_int().to_byte())
      i += 1
    } else {
      out.push(b)
      i += 1
    }
  }
  let bytes = Bytes::from_array(out)
  Some(@utf8.decode(bytes[:])) catch {
    _ => None
  }
}

///|
/// Split a request target into decoded path segments and first-wins decoded
/// query parameters. Returns None on malformed escapes.
fn split_target(target : String) -> (Array[String], Map[String, String])? {
  let (path, query) = match target.find("?") {
    Some(i) => (target[:i].to_owned(), target[i + 1:].to_owned())
    None => (target, "")
  }
  let segs : Array[String] = []
  for seg in path.split("/") {
    if seg.length() == 0 {
      continue
    }
    match percent_decode(seg.to_owned(), plus_space=false) {
      Some(s) => segs.push(s)
      None => return None
    }
  }
  let params : Map[String, String] = Map([])
  if query != "" {
    for pair in query.split("&") {
      let (k, v) = match pair.find("=") {
        Some(i) => (pair[:i], pair[i + 1:])
        None => (pair, "".to_string()[:])
      }
      match
        (
          percent_decode(k.to_owned(), plus_space=true),
          percent_decode(v.to_owned(), plus_space=true),
        ) {
        (Some(k), Some(v)) => if !params.contains(k) { params[k] = v }
        _ => ()
      }
    }
  }
  Some((segs, params))
}

///|
/// Parse `limit`/`offset` like the Go reference: limit defaults to 20 and
/// must be 1..=100, offset defaults to 0 and must be >= 0; a present parameter
/// (even empty) must be valid, first repeated value wins.
fn limit_offset(params : Map[String, String]) -> (Int64, Int64)? {
  let mut limit : Int64 = 20
  let mut offset : Int64 = 0
  match params.get("limit") {
    Some(v) =>
      match parse_uint(v[:]) {
        Some(n) if n >= 1 && n <= 100 => limit = n
        _ => return None
      }
    None => ()
  }
  match params.get("offset") {
    Some(v) =>
      match parse_uint(v[:]) {
        Some(n) => offset = n
        None => return None
      }
    None => ()
  }
  Some((limit, offset))
}

///|
/// Parse a JSON request body as `{"<key>": {...}}` and return the inner
/// object. Mirrors the Go readWrapper: top-level must be an object containing
/// the key, and the value must be an object.
fn read_wrapper(body : String, key : String) -> Map[String, Json]? {
  let top = @json.parse(body[:]) catch { _ => return None }
  guard top is Json::Object(obj) else { return None }
  match obj.get(key) {
    Some(Json::Object(inner)) => Some(inner)
    _ => None
  }
}

///|
/// Optional string field: absent or JSON null -> Ok(None); a JSON string ->
/// Ok(Some) unless empty and `non_empty`; anything else -> Err.
fn opt_string(
  m : Map[String, Json],
  key : String,
  non_empty~ : Bool,
) -> Result[String?, Unit] {
  match m.get(key) {
    None | Some(Json::Null) => Ok(None)
    Some(Json::String(s)) =>
      if non_empty && s == "" {
        Err(())
      } else {
        Ok(Some(s))
      }
    Some(_) => Err(())
  }
}

///|
/// Required non-empty string field.
fn req_string(m : Map[String, Json], key : String) -> String? {
  match opt_string(m, key, non_empty=true) {
    Ok(Some(s)) => Some(s)
    _ => None
  }
}

///|
/// Optional tagList field: absent or null -> Ok([]); an array of non-empty
/// strings -> Ok(items); anything else -> Err.
fn opt_tag_list(m : Map[String, Json]) -> Result[Array[String], Unit] {
  match m.get("tagList") {
    None | Some(Json::Null) => Ok([])
    Some(Json::Array(items)) => {
      let tags : Array[String] = []
      for it in items {
        match it {
          Json::String(s) if s != "" => tags.push(s)
          _ => return Err(())
        }
      }
      Ok(tags)
    }
    Some(_) => Err(())
  }
}
