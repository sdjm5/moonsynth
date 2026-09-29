// Freeverb-style reverb.
//
// Eight damped comb filters in parallel feed four series allpass filters,
// once per channel; the right channel's delay lines are offset by a handful
// of samples so the two channels decorrelate into a wide stereo image. This
// is Jezar's public-domain Freeverb topology, rewritten from the published
// tunings; the damping low-pass inside each comb is what keeps the tail from
// turning metallic.

///|
/// Comb tunings in samples at 44.1 kHz (Freeverb's published set), and the
/// allpass tunings, plus the right-channel offset that creates the stereo
/// spread.
let comb_tuning : FixedArray[Int] = FixedArray::from_array([
  1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617,
])

///|
let allpass_tuning : FixedArray[Int] = FixedArray::from_array([556, 441, 341, 225])

///|
let stereo_spread : Int = 23

///|
pub struct Comb {
  buf : FixedArray[Double]
  n : Int
  mut idx : Int
  mut store : Double // one-pole damping state
  mut feedback : Double
  mut damp : Double
}

///|
pub fn Comb::new(len : Int) -> Comb {
  { buf: FixedArray::make(len, 0.0), n: len, idx: 0, store: 0.0, feedback: 0.84, damp: 0.2 }
}

///|
pub fn Comb::process(self : Comb, input : Double) -> Double {
  let out = self.buf[self.idx]
  // damped feedback: low-pass the recirculated signal
  self.store = out * (1.0 - self.damp) + self.store * self.damp
  self.buf[self.idx] = input + self.store * self.feedback
  self.idx = self.idx + 1
  if self.idx >= self.n {
    self.idx = 0
  }
  out
}

///|
pub struct Allpass {
  buf : FixedArray[Double]
  n : Int
  mut idx : Int
}

///|
pub fn Allpass::new(len : Int) -> Allpass {
  { buf: FixedArray::make(len, 0.0), n: len, idx: 0 }
}

///|
pub fn Allpass::process(self : Allpass, input : Double) -> Double {
  let bufout = self.buf[self.idx]
  let out = -input + bufout
  self.buf[self.idx] = input + bufout * 0.5
  self.idx = self.idx + 1
  if self.idx >= self.n {
    self.idx = 0
  }
  out
}

///|
pub(all) struct Reverb {
  combs_l : Array[Comb]
  combs_r : Array[Comb]
  ap_l : Array[Allpass]
  ap_r : Array[Allpass]
  mut size : Double // room size 0..1 → comb feedback 0.70..0.98
  mut damp : Double // 0..1
  mut mix : Double // wet fraction 0..1
  mut width : Double // stereo width 0..1
  gain : Double // input gain into the tank
}

///|
pub fn Reverb::new(sr : Double) -> Reverb {
  let k = sr / 44100.0
  let combs_l : Array[Comb] = []
  let combs_r : Array[Comb] = []
  for t in comb_tuning {
    let n = (t.to_double() * k).to_int()
    combs_l.push(Comb::new(n))
    combs_r.push(Comb::new(n + stereo_spread))
  }
  let ap_l : Array[Allpass] = []
  let ap_r : Array[Allpass] = []
  for t in allpass_tuning {
    let n = (t.to_double() * k).to_int()
    ap_l.push(Allpass::new(n))
    ap_r.push(Allpass::new(n + stereo_spread))
  }
  let r = {
    combs_l,
    combs_r,
    ap_l,
    ap_r,
    size: 0.5,
    damp: 0.3,
    mix: 0.0, // off until a patch asks for it (matches Params::reverb_mix)
    width: 0.8,
    gain: 0.015,
  }
  r.set_room(0.5, 0.3)
  r
}

///|
/// Room size and damping take effect immediately on every comb.
pub fn Reverb::set_room(self : Reverb, size : Double, damp : Double) -> Unit {
  let s = dclamp(size, 0.0, 1.0)
  let d = dclamp(damp, 0.0, 1.0)
  self.size = s
  self.damp = d
  let fb = 0.70 + s * 0.28
  for c in self.combs_l {
    c.feedback = fb
    c.damp = d * 0.4
  }
  for c in self.combs_r {
    c.feedback = fb
    c.damp = d * 0.4
  }
}

///|
/// Process one stereo frame. Returns (left, right).
pub fn Reverb::process(self : Reverb, l : Double, r : Double) -> (Double, Double) {
  if self.mix <= 0.0 {
    return (l, r)
  }
  let input = (l + r) * self.gain
  let mut wet_l = 0.0
  let mut wet_r = 0.0
  for c in self.combs_l {
    wet_l = wet_l + c.process(input)
  }
  for c in self.combs_r {
    wet_r = wet_r + c.process(input)
  }
  for a in self.ap_l {
    wet_l = a.process(wet_l)
  }
  for a in self.ap_r {
    wet_r = a.process(wet_r)
  }
  // constant-power-ish wet/dry with stereo width
  let wet1 = self.mix * (self.width / 2.0 + 0.5)
  let wet2 = self.mix * ((1.0 - self.width) / 2.0)
  let dry = 1.0 - self.mix
  (l * dry + wet_l * wet1 + wet_r * wet2, r * dry + wet_r * wet1 + wet_l * wet2)
}

///|
/// Clear all delay lines (panic).
pub fn Reverb::clear(self : Reverb) -> Unit {
  for c in self.combs_l {
    FixedArray::fill(c.buf, 0.0)
    c.store = 0.0
    c.idx = 0
  }
  for c in self.combs_r {
    FixedArray::fill(c.buf, 0.0)
    c.store = 0.0
    c.idx = 0
  }
  for a in self.ap_l {
    FixedArray::fill(a.buf, 0.0)
    a.idx = 0
  }
  for a in self.ap_r {
    FixedArray::fill(a.buf, 0.0)
    a.idx = 0
  }
}

///|
/// Tail energy estimate for tests: process a burst and measure how much
/// signal is still ringing `seconds` later.
pub fn Reverb::tail_energy(self : Reverb, sr : Double, burst : Int, seconds : Double) -> Double {
  self.clear()
  for i = 0; i < burst; i = i + 1 {
    ignore(self.process(1.0, 1.0))
  }
  let skip = (sr * seconds).to_int()
  for _i = 0; _i < skip; _i = _i + 1 {
    ignore(self.process(0.0, 0.0))
  }
  let mut acc = 0.0
  for i = 0; i < 2000; i = i + 1 {
    let (l, r) = self.process(0.0, 0.0)
    acc = acc + (l * l + r * r) * 0.5
  }
  acc / 2000.0
}
