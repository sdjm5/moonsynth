// Output stage: a soft-knee limiter on the master bus.
//
// Voices add up. Eight voices times two oscillators plus a reverb tank can
// push the master bus well past ±1, and a WAV encoder (or a sound card) will
// simply flatten anything beyond that — the demo track measured a peak of
// 4.0 before this existed, which is audible crunch.
//
// The limiter is deliberately transparent below the knee: nothing that fits
// inside 0.9 is touched at all, so normal playing, and every spectral
// measurement in the test suite, sees the signal unchanged. Above the knee
// the curve bends smoothly and approaches 1.0 asymptotically, so overload
// compresses instead of clipping.

///|
pub const LIMIT_KNEE : Double = 0.9

///|
/// Soft-knee limiter: identity for |x| <= knee, asymptotic to ±1 above it.
/// Continuous at the knee, monotonic everywhere.
pub fn soft_limit(x : Double, knee : Double) -> Double {
  let k = if knee < 0.0 {
    0.0
  } else if knee > 0.999 {
    0.999
  } else {
    knee
  }
  let a = x.abs()
  if a <= k {
    return x
  }
  let room = 1.0 - k
  let over = a - k
  let shaped = k + room * (over / (over + room))
  if x < 0.0 {
    -shaped
  } else {
    shaped
  }
}

///|
/// Master-bus limiter at the default knee.
pub fn master_limit(x : Double) -> Double {
  soft_limit(x, LIMIT_KNEE)
}
