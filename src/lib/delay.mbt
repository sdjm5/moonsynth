// Mono-in, stereo-out ping-pong delay.
//
// Two circular buffers: buffer A's tap feeds the dry+echo mix and also (scaled
// by feedback) buffer B's input; buffer B's tap feeds the mix and feeds back
// into A. An input impulse therefore echoes left at t, right at 2t, left at
// 3t, ... — the classic ping-pong bounce.

///|
pub(all) struct PingPong {
  sr : Double
  a : FixedArray[Double] // left bounce buffer
  b : FixedArray[Double] // right bounce buffer
  mut w : Int // shared write index
  mut time : Double // seconds between bounces
  mut feedback : Double // 0..0.9
  mut mix : Double // wet fraction 0..1
}

///|
pub fn PingPong::new(sr : Double) -> PingPong {
  let n = (sr * 1.1 + 1.0).to_int() // supports times up to ~1 s
  {
    sr,
    a: FixedArray::make(n, 0.0),
    b: FixedArray::make(n, 0.0),
    w: 0,
    time: 0.25,
    feedback: 0.35,
    mix: 0.25,
  }
}

///|
fn tap(buf : FixedArray[Double], w : Int, n_total : Int, d : Int) -> Double {
  // read the sample written `d` samples ago
  let idx = w - d
  let idx2 = if idx < 0 { idx + n_total } else { idx }
  buf[idx2 % buf.length()]
}

///|
/// Process one dry sample; returns the stereo pair (left, right).
pub fn PingPong::process(self : PingPong, x : Double) -> (Double, Double) {
  let n = self.a.length()
  let d = (self.time * self.sr).to_int()
  let dd = if d < 1 { 1 } else if d >= n { n - 1 } else { d }
  let ra = tap(self.a, self.w, n, dd)
  let rb = tap(self.b, self.w, n, dd)
  // feedback chain: A -> B -> A
  let fa = if self.feedback < 0.0 {
    0.0
  } else if self.feedback > 0.9 {
    0.9
  } else {
    self.feedback
  }
  self.a[self.w] = x + fa * rb
  self.b[self.w] = fa * ra
  self.w = if self.w + 1 >= n { 0 } else { self.w + 1 }
  let wet_l = ra
  let wet_r = rb
  let dry = 1.0 - self.mix
  (x * dry + wet_l * self.mix, x * dry + wet_r * self.mix)
}

///|
pub fn PingPong::clear(self : PingPong) -> Unit {
  FixedArray::fill(self.a, 0.0)
  FixedArray::fill(self.b, 0.0)
  self.w = 0
}
