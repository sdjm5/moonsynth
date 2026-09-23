// The polyphonic synth engine: parameter block, voice manager, and the
// block renderer the wasm kernel drives.
//
// Signal flow per voice:  osc1 + osc2 (detuned, mixed) -> ADSR amp
// summed across voices -> global biquad filter -> master gain
// -> ping-pong delay (stereo) -> out.
//
// Everything is preallocated: voices, scratch buffers, delay lines. The
// render path allocates nothing, so it never disturbs the GC while the
// audio thread is pulling blocks.

///|
pub struct Params {
  mut osc1_wave : Waveform
  mut osc1_detune : Double // cents
  mut osc2_wave : Waveform
  mut osc2_detune : Double
  mut osc2_mix : Double // 0..1 (1 = both oscs at half level)
  mut filter : FilterType
  mut cutoff : Double // Hz
  mut q : Double
  mut attack : Double
  mut decay : Double
  mut sustain : Double
  mut release : Double
  mut master : Double // 0..1
}

///|
pub struct Voice {
  mut note : Int
  mut gate : Bool
  mut vel : Double
  mut freq : Double
  mut age : Int
  osc1 : Osc
  osc2 : Osc
  env : Adsr
}

///|
pub struct Synth {
  sr : Double
  params : Params
  filter : Biquad
  delay : PingPong
  voices : Array[Voice]
  scratch_l : FixedArray[Double]
  scratch_r : FixedArray[Double]
  mut clock : Int
}

///|
pub const MAX_VOICES : Int = 8

///|
pub fn Synth::new(sr : Double) -> Synth {
  let params = {
    osc1_wave: Saw,
    osc1_detune: -7.0,
    osc2_wave: Sqr,
    osc2_detune: 7.0,
    osc2_mix: 0.5,
    filter: FLP,
    cutoff: 12000.0,
    q: 0.8,
    attack: 0.01,
    decay: 0.15,
    sustain: 0.6,
    release: 0.25,
    master: 0.7,
  }
  let voices : Array[Voice] = []
  for i = 0; i < MAX_VOICES; i = i + 1 {
    voices.push({
      note: -1,
      gate: false,
      vel: 0.0,
      freq: 0.0,
      age: 0,
      osc1: Osc::new(),
      osc2: Osc::new(),
      env: Adsr::new(sr),
    })
  }
  {
    sr,
    params,
    filter: Biquad::new(FLP),
    delay: PingPong::new(sr),
    voices,
    scratch_l: FixedArray::make(4096, 0.0),
    scratch_r: FixedArray::make(4096, 0.0),
    clock: 0,
  }
}

///|
pub fn note_freq(note : Int) -> Double {
  440.0 * @math.pow(2.0, (note - 69).to_double() / 12.0)
}

///|
fn dclamp(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// Start (or retrigger) a note with velocity 0..127. Reuses a voice already
/// playing the note, then any idle voice, then steals the oldest one.
pub fn Synth::note_on(self : Synth, note : Int, vel : Int) -> Unit {
  if note < 0 || note > 127 {
    return
  }
  let vv = if vel < 1 { 1 } else if vel > 127 { 127 } else { vel }
  let mut found : Voice? = None
  for candidate in self.voices {
    if candidate.gate && candidate.note == note {
      found = Some(candidate)
      break
    }
  }
  if found is None {
    for candidate in self.voices {
      if !candidate.env.active() {
        found = Some(candidate)
        break
      }
    }
  }
  if found is None {
    // steal the oldest sounding voice
    let mut oldest : Voice = self.voices[0]
    for candidate in self.voices {
      if candidate.age < oldest.age {
        oldest = candidate
      }
    }
    found = Some(oldest)
  }
  match found {
    Some(voice) => {
      let p = self.params
      voice.note = note
      voice.gate = true
      voice.vel = vv.to_double() / 127.0
      voice.freq = note_freq(note)
      voice.age = self.clock
      self.clock = self.clock + 1
      voice.osc1.reset()
      voice.osc2.reset()
      voice.env.attack = p.attack
      voice.env.decay = p.decay
      voice.env.sustain = p.sustain
      voice.env.release = p.release
      voice.env.gate_on()
    }
    None => ()
  }
}

///|
/// Release every voice currently holding `note`.
pub fn Synth::note_off(self : Synth, note : Int) -> Unit {
  for v in self.voices {
    if v.note == note && v.gate {
      v.gate = false
      v.env.gate_off()
    }
  }
}

///|
/// Silence everything immediately.
pub fn Synth::panic(self : Synth) -> Unit {
  for v in self.voices {
    v.gate = false
    v.env.kill()
    v.note = -1
  }
  self.filter.clear()
  self.delay.clear()
}

///|
/// Number of voices currently sounding (gate held or releasing).
pub fn Synth::active_voices(self : Synth) -> Int {
  let mut n = 0
  for v in self.voices {
    if v.env.active() {
      n = n + 1
    }
  }
  n
}

///|
/// Apply one parameter by id (see the kernel export for the id table).
/// Returns true when the id was recognized.
pub fn Synth::set_param(self : Synth, id : Int, value : Double) -> Bool {
  let p = self.params
  match id {
    0 => p.osc1_wave = wave_from_int(value.to_int())
    1 => p.osc1_detune = value
    2 => p.osc2_wave = wave_from_int(value.to_int())
    3 => p.osc2_detune = value
    4 => p.osc2_mix = dclamp(value, 0.0, 1.0)
    5 => p.filter = filter_from_int(value.to_int())
    6 => p.cutoff = value
    7 => p.q = value
    8 => p.attack = value
    9 => p.decay = value
    10 => p.sustain = dclamp(value, 0.0, 1.0)
    11 => p.release = value
    12 => self.delay.time = value
    13 => self.delay.feedback = value
    14 => self.delay.mix = dclamp(value, 0.0, 1.0)
    15 => p.master = dclamp(value, 0.0, 1.0)
    _ => return false
  }
  if id == 5 || id == 6 || id == 7 {
    self.filter.set(p.filter, p.cutoff, p.q, self.sr)
  }
  // live envelope params apply to voices that are already sounding
  if id >= 8 && id <= 11 {
    for v in self.voices {
      v.env.attack = p.attack
      v.env.decay = p.decay
      v.env.sustain = p.sustain
      v.env.release = p.release
    }
  }
  true
}

///|
/// Render `n` frames of stereo audio into the preallocated scratch buffers.
/// Returns (left, right). `n` must not exceed 4096.
pub fn Synth::render(
  self : Synth,
  n : Int,
) -> (FixedArray[Double], FixedArray[Double]) {
  let p = self.params
  let nn = if n > 4096 { 4096 } else { n }
  let mix2 = p.osc2_mix
  let wet2 = mix2 * 0.5
  let dry2 = if mix2 >= 1.0 { 0.5 } else { 1.0 - mix2 * 0.5 }
  let sr = self.sr
  for i = 0; i < nn; i = i + 1 {
    let mut acc = 0.0
    for v in self.voices {
      let lvl = v.env.next()
      if lvl > 0.0 {
        let f1 = v.freq * @math.pow(2.0, p.osc1_detune / 1200.0)
        let f2 = v.freq * @math.pow(2.0, p.osc2_detune / 1200.0)
        let o1 = v.osc1.next(f1, p.osc1_wave, sr)
        let o2 = v.osc2.next(f2, p.osc2_wave, sr)
        let tone = o1 * dry2 + o2 * wet2
        acc = acc + tone * lvl * v.vel
      }
    }
    self.scratch_l[i] = acc
    self.scratch_r[i] = acc
  }
  // global filter + master
  for i = 0; i < nn; i = i + 1 {
    let y = self.filter.process(self.scratch_l[i]) * p.master
    self.scratch_l[i] = y
    self.scratch_r[i] = y
  }
  // stereo delay
  for i = 0; i < nn; i = i + 1 {
    let (l, r) = self.delay.process(self.scratch_l[i])
    self.scratch_l[i] = l
    self.scratch_r[i] = r
  }
  (self.scratch_l, self.scratch_r)
}
