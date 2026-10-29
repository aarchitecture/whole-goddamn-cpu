///|
struct FakeBatchBook {
  mut active : Bool
  queue : Array[Int32]
}

///|
fn FakeBatchBook::new() -> FakeBatchBook {
  { active: false, queue: [], }
}

///|
fn FakeBatchBook::enqueue(self : FakeBatchBook, n : Int32) -> Bool {
  let leader = !self.active
  self.active = true
  self.queue.push(n)
  leader
}

///|
fn FakeBatchBook::take(self : FakeBatchBook) -> Array[Int32] {
  let n = if self.queue.length() < 64 { self.queue.length() } else { 64 }
  let out = []
  for _ in 0..<n {
    out.push(self.queue.remove(0))
  }
  out
}

///|
test "batched coordinator one leader serves concurrent callers" {
  let b = FakeBatchBook::new()
  assert_true(b.enqueue(1))
  assert_true(!b.enqueue(2))
  assert_true(!b.enqueue(3))
  assert_eq(b.take(), [1, 2, 3])
}

///|
test "batched coordinator cap 64 leaves next batch" {
  let b = FakeBatchBook::new()
  for i in 0..<65 {
    ignore(b.enqueue(i))
  }
  assert_eq(b.take().length(), 64)
  assert_eq(b.queue.length(), 1)
}

///|
test "batched coordinator demux preserves ordinal order" {
  let b = FakeBatchBook::new()
  for i in 0..<8 {
    ignore(b.enqueue(i))
  }
  assert_eq(b.take(), [0, 1, 2, 3, 4, 5, 6, 7])
}

///|
test "batched coordinator cancelled queued member is removed" {
  let b = FakeBatchBook::new()
  ignore(b.enqueue(1))
  ignore(b.enqueue(2))
  ignore(b.enqueue(3))
  ignore(b.queue.remove(1))
  assert_eq(b.take(), [1, 3])
}
