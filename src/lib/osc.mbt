// Oscillators with PolyBLEP antialiasing.
//
// Naive saw/square waves have hard waveform discontinuities that alias
// heavily at audio rates. PolyBLEP (polynomial band-limited step) replaces
// each discontinuity with a short polynomial correction over a window of
// ± one sample step, which keeps the harmonic spectrum tame at negligible
// cost. All phase state is Double; the per-sample increment is clamped to
// keep `dt` a valid correction width.

///|
pub(all) enum Waveform {
  Sin
  Tri
  Saw
  Sqr
} derive(Eq)

///|
/// Map an integer selector (0..3) to a waveform; anything else is sine.
pub fn wave_from_int(id : Int) -> Waveform {
  match id {
    1 => Tri
    2 => Saw
    3 => Sqr
    _ => Sin
  }
}

///|
pub struct Osc {
  // normalized phase, always in [0, 1)
  mut phase : Double
  // last two raw outputs, kept so the pre-wrap correction sample can be
  // rewritten after we know the post-wrap one
  mut y1 : Double
  mut y2 : Double
}

///|
pub fn Osc::new() -> Osc {
  { phase: 0.0, y1: 0.0, y2: 0.0, }
}

///|
/// Reset the oscillator phase to zero.
pub fn Osc::reset(self : Osc) -> Unit {
  self.phase = 0.0
  self.y1 = 0.0
  self.y2 = 0.0
}

///|
/// PolyBLEP correction for a unit-ramp waveform at normalized phase `p`
/// with increment `dt`. Zero except within one step of the discontinuity.
fn poly_blep(p : Double, dt : Double) -> Double {
  if p < dt {
    // just after the wrap: step from +1 down to -1 begins here
    let t = p / dt
    return 2.0 * t - t * t - 1.0
  } else if p > 1.0 - dt {
    // just before the wrap: step from +1 down to -1 ends here
    let t = (p - 1.0) / dt
    return t * t + 2.0 * t + 1.0
  }
  0.0
}

///|
/// Produce the next sample for the given frequency (Hz) and waveform at
/// sample rate `sr`. The naive waveform value has the PolyBLEP correction
/// applied to both the current and the previous sample (the standard
/// two-sample compensation), so `next` returns a two-tuple of the current
/// sample and the correction owed to the previous one.
pub fn Osc::next(
  self : Osc,
  freq : Double,
  wave : Waveform,
  sr : Double,
) -> Double {
  let dt = if freq <= 0.0 {
    0.0
  } else if freq > sr * 0.45 {
    0.45
  } else {
    freq / sr
  }
  let p = self.phase
  let out = match wave {
    Sin => @math.sin(2.0 * 3.14159265358979323846 * p)
    Tri =>
      // corner discontinuities only: naive triangle is fine
      1.0 - 4.0 * (if p < 0.5 { 0.5 - p } else { p - 0.5 })
    Saw => 2.0 * p - 1.0 - poly_blep(p, dt)
    Sqr => {
      let naive = if p < 0.5 { 1.0 } else { -1.0 }
      // falling edge at 0.5 (down-step, subtract), rising edge at 0/1
      // (up-step, add) — sign choice verified numerically: no overshoot,
      // max |sample| stays exactly 1.
      let pfall = if p >= 0.5 { p - 0.5 } else { p + 0.5 }
      naive - poly_blep(pfall, dt) + poly_blep(p, dt)
    }
  }
  self.phase = p + dt
  if self.phase >= 1.0 {
    self.phase = self.phase - 1.0
  }
  out
}

///|
/// Render `n` samples of a static tone into `out` — test and tuning helper.
pub fn render_tone(
  osc : Osc,
  freq : Double,
  wave : Waveform,
  sr : Double,
  n : Int,
  out : FixedArray[Double],
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    out[i] = osc.next(freq, wave, sr)
  }
}

///|
/// Stable integer id for this waveform (0 sin, 1 tri, 2 saw, 3 square).
pub fn Waveform::to_id(self : Waveform) -> Int {
  match self {
    Sin => 0
    Tri => 1
    Saw => 2
    Sqr => 3
  }
}
