// Linear ADSR envelope.
//
// Linear segments keep the math exact for unit tests; musically they sit
// fine behind a low-pass filter. Release always ramps from the level it
// started at, so shortening release while releasing cannot click upward.

///|
pub(all) struct Adsr {
  sr : Double
  mut attack : Double // seconds
  mut decay : Double
  mut sustain : Double // 0..1
  mut release : Double
  mut stage : Int // 0 idle, 1 attack, 2 decay, 3 sustain, 4 release
  mut level : Double
  mut rel_rate : Double // level per sample while releasing
}

///|
pub fn Adsr::new(sr : Double) -> Adsr {
  {
    sr,
    attack: 0.01,
    decay: 0.1,
    sustain: 0.7,
    release: 0.2,
    stage: 0,
    level: 0.0,
    rel_rate: 0.0,
  }
}

///|
pub fn Adsr::gate_on(self : Adsr) -> Unit {
  self.stage = 1
}

///|
pub fn Adsr::gate_off(self : Adsr) -> Unit {
  if self.stage > 0 {
    self.stage = 4
    let rl = if self.release <= 0.0 { 1.0 } else { self.release * self.sr }
    self.rel_rate = self.level / rl
  }
}

///|
pub fn Adsr::active(self : Adsr) -> Bool {
  self.stage != 0
}

///|
/// Hard-reset the envelope (voice steal / panic).
pub fn Adsr::kill(self : Adsr) -> Unit {
  self.stage = 0
  self.level = 0.0
}

///|
/// Advance one sample and return the envelope level.
pub fn Adsr::next(self : Adsr) -> Double {
  match self.stage {
    1 => {
      let step = if self.attack <= 0.0 {
        2.0 // instantly overflow the attack ramp
      } else {
        1.0 / (self.attack * self.sr)
      }
      self.level = self.level + step
      if self.level >= 1.0 {
        self.level = 1.0
        self.stage = 2
      }
      self.level
    }
    2 => {
      let step = if self.decay <= 0.0 {
        2.0
      } else {
        (1.0 - self.sustain) / (self.decay * self.sr)
      }
      self.level = self.level - step
      if self.level <= self.sustain {
        self.level = self.sustain
        self.stage = 3
      }
      self.level
    }
    3 => self.sustain
    4 => {
      self.level = self.level - self.rel_rate
      if self.level <= 0.0 {
        self.level = 0.0
        self.stage = 0
      }
      self.level
    }
    _ => 0.0
  }
}
