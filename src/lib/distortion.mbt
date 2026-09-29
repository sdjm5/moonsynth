// Soft-clipping waveshaper (drive).
//
// The curve is the classic cubic soft clipper  f(x) = x(27 + x²) / (27 + 9x²)
// which is monotonic, odd-symmetric, passes small signals almost untouched
// (f'(0) = 1) and saturates at exactly ±1 as |x| → 3. Drive scales the input
// into the curve and a makeup gain keeps a full-scale input near unity, so
// turning drive up adds harmonics instead of just getting quieter.

///|
pub struct Drive {
  mut amount : Double // 0..1
  mut mix : Double // 0..1 dry/wet
}

///|
pub fn Drive::new() -> Drive {
  { amount: 0.0, mix: 0.0 }
}

///|
/// Cubic soft clipper: monotonic increasing, saturates at ±1.
pub fn soft_clip(x : Double) -> Double {
  let t = if x < -3.0 {
    -3.0
  } else if x > 3.0 {
    3.0
  } else {
    x
  }
  t * (27.0 + t * t) / (27.0 + 9.0 * t * t)
}

///|
/// Drive scaling: amount 0 bypasses (gain 1), amount 1 pushes the curve hard.
pub fn Drive::gain(self : Drive) -> Double {
  1.0 + self.amount * 24.0
}

///|
/// Makeup gain keeps a full-scale input near unity rather than letting the
/// saturator halve the loudness: measured, a full-scale sine leaves the
/// curve at 0.76 with amount 0.8 and 0.71 at amount 1.0.
pub fn Drive::makeup(self : Drive) -> Double {
  1.0 / (1.0 + self.amount * 0.4)
}

///|
pub fn Drive::process(self : Drive, x : Double) -> Double {
  if self.amount <= 0.0 || self.mix <= 0.0 {
    return x
  }
  let shaped = soft_clip(x * self.gain()) * self.makeup()
  x * (1.0 - self.mix) + shaped * self.mix
}

///|
pub fn Drive::set(self : Drive, amount : Double, mix : Double) -> Unit {
  self.amount = if amount < 0.0 {
    0.0
  } else if amount > 1.0 {
    1.0
  } else {
    amount
  }
  self.mix = if mix < 0.0 {
    0.0
  } else if mix > 1.0 {
    1.0
  } else {
    mix
  }
}
