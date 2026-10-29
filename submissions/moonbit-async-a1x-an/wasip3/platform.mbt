///|
/// platform shim for future unchanged business code (env/rand/now).
/// Implemented on generated WASI 0.3 interfaces - no moonrun/core env.

///|
pub fn get_env_var(name : String) -> String? {
  for e in @environment.get_environment() {
    if e.0 == name {
      return Some(e.1)
    }
  }
  None
}

///|
pub fn rand(n : Int) -> Bytes? {
  let arr = @random.get_random_bytes(n.to_uint64())
  Some(Bytes::makei(arr.length(), fn(i) { arr[i] }))
}

///|
pub fn now() -> UInt64 {
  let i = @system_clock.now()
  i.seconds.to_uint64() * 1000UL + i.nanoseconds.to_uint64() / 1000000UL
}
