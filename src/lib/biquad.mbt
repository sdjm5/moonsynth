// RBJ audio-EQ-cookbook biquad filter (direct form I).
//
// One filter per synth (post voice mix). Coefficients are recomputed only
// when the type / cutoff / resonance change; `process` is a fixed
// five-multiply recursion.

///|
pub(all) enum FilterType {
  FLP
  FHP
  FBP
} derive(Eq)

///|
pub fn filter_from_int(id : Int) -> FilterType {
  match id {
    1 => FHP
    2 => FBP
    _ => FLP
  }
}

///|
pub struct Biquad {
  mut ftype : FilterType
  mut b0 : Double
  mut b1 : Double
  mut b2 : Double
  mut a1 : Double
  mut a2 : Double
  mut x1 : Double
  mut x2 : Double
  mut y1 : Double
  mut y2 : Double
}

///|
pub fn Biquad::new(ftype : FilterType) -> Biquad {
  let f = {
    ftype,
    b0: 1.0,
    b1: 0.0,
    b2: 0.0,
    a1: 0.0,
    a2: 0.0,
    x1: 0.0,
    x2: 0.0,
    y1: 0.0,
    y2: 0.0,
  }
  f.set(ftype, 20000.0, 0.7071, 44100.0)
  f
}

///|
/// Recompute the RBJ coefficients for the given cutoff (Hz) and resonance
/// Q. Cutoff is clamped to a stable range for the current sample rate.
pub fn Biquad::set(
  self : Biquad,
  ftype : FilterType,
  cutoff : Double,
  q : Double,
  sr : Double,
) -> Unit {
  let f0 = if cutoff < 20.0 {
    20.0
  } else if cutoff > sr * 0.45 {
    sr * 0.45
  } else {
    cutoff
  }
  let qq = if q < 0.05 { 0.05 } else if q > 20.0 { 20.0 } else { q }
  let w0 = 2.0 * 3.14159265358979323846 * f0 / sr
  let cs = @math.cos(w0)
  let sn = @math.sin(w0)
  let alpha = sn / (2.0 * qq)
  // RBJ cookbook, normalized by a0
  let a0 = 1.0 + alpha
  let (b0, b1, b2) = match ftype {
    FLP => ((1.0 - cs) / 2.0, 1.0 - cs, (1.0 - cs) / 2.0)
    FHP => ((1.0 + cs) / 2.0, -(1.0 + cs), (1.0 + cs) / 2.0)
    // constant 0 dB peak gain band pass
    FBP => (alpha, 0.0, -alpha)
  }
  self.ftype = ftype
  self.b0 = b0 / a0
  self.b1 = b1 / a0
  self.b2 = b2 / a0
  self.a1 = -2.0 * cs / a0
  self.a2 = (1.0 - alpha) / a0
}

///|
/// Process one sample through the direct-form-I recursion.
pub fn Biquad::process(self : Biquad, x : Double) -> Double {
  let y = self.b0 * x +
    self.b1 * self.x1 +
    self.b2 * self.x2 -
    self.a1 * self.y1 -
    self.a2 * self.y2
  self.x2 = self.x1
  self.x1 = x
  self.y2 = self.y1
  self.y1 = y
  y
}

///|
/// Clear the filter state (on panic).
pub fn Biquad::clear(self : Biquad) -> Unit {
  self.x1 = 0.0
  self.x2 = 0.0
  self.y1 = 0.0
  self.y2 = 0.0
}

///|
/// Stable integer id for this filter type (0 LP, 1 HP, 2 BP).
pub fn FilterType::to_id(self : FilterType) -> Int {
  match self {
    FLP => 0
    FHP => 1
    FBP => 2
  }
}
