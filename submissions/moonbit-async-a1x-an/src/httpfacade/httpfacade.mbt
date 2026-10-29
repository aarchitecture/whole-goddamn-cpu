///|
/// Minimal HTTP request/response facade matching the subset of
/// moonbitlang/async/http used by the unchanged business files
/// (@http.Request/.ServerConnection, Method, BodyData.text).
/// No WIT/native runtime inside this facade - the body reader is injected.

///|
pub(all) enum Method {
  Get
  Head
  Post
  Put
  Delete
  Other
}

///|
pub type Headers = Map[String, String]

///|
/// Transport-independent request metadata, including the query string.
pub struct Request {
  meth : Method
  path : String
  headers : Headers
}

///|
pub fn Request::new(
  meth : Method,
  path : String,
  headers : Headers,
) -> Request {
  { meth, path, headers }
}

///|
/// Owned body bytes, decoded as UTF-8 on demand.
pub struct BodyData {
  bytes : Bytes
}

///|
pub fn BodyData::text(self : BodyData) -> String raise {
  @utf8.decode(self.bytes[:])
}

///|
/// Connection handle carrying the injected body reader (the WIT handler
/// passes a closure that consumes the incoming request body stream).
pub struct ServerConnection {
  priv body_reader : async () -> Bytes raise
  priv mut cached : Bytes?
}

///|
pub fn ServerConnection::new(
  body_reader : async () -> Bytes raise,
) -> ServerConnection {
  { body_reader, cached: None }
}

///|
/// Read the whole request body exactly once; a second call returns the
/// cached bytes (business code never reads twice).
pub async fn ServerConnection::read_all(self : ServerConnection) -> BodyData raise {
  match self.cached {
    Some(b) => { bytes: b }
    None => {
      let b = (self.body_reader)()
      self.cached = Some(b)
      { bytes: b }
    }
  }
}
