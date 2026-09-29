// The polyphonic synth engine: parameter block, voice manager, and the
// block renderer the wasm kernel drives.
//
// Signal flow per voice:  osc1 + osc2 (detuned, mixed) -> ADSR amp
// summed across voices -> global biquad filter -> drive (soft clip)
// -> ping-pong delay -> reverb -> master gain -> out.
//
// Everything is preallocated: voices, scratch buffers, delay lines, reverb
// tanks. The render path allocates nothing, so it never disturbs the GC
// while the audio thread is pulling blocks.

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
  mut reverb_size : Double // 0..1
  mut reverb_damp : Double // 0..1
  mut reverb_mix : Double // 0..1 wet
  mut reverb_width : Double // 0..1 stereo
  mut drive : Double // 0..1
  mut drive_mix : Double // 0..1
  mut arp_on : Double // 0 or 1
  mut arp_rate : Double // steps per second
  mut arp_mode : Double // ARP_* constants
  mut arp_octaves : Double
  mut arp_gate : Double // note length as a fraction of a step
  mut arp_latch : Double // 0 or 1
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
  drive : Drive
  delay : PingPong
  reverb : Reverb
  voices : Array[Voice]
  scratch_l : FixedArray[Double]
  scratch_r : FixedArray[Double]
  mut clock : Int
  // --- arpeggiator ---
  held : FixedArray[Int] // keys currently down, in press order
  held_sorted : FixedArray[Int] // the same keys in ascending order
  mut held_n : Int
  arp_pattern : FixedArray[Int] // expanded pattern (held × octaves)
  mut arp_pattern_n : Int
  mut arp_index : Int
  mut arp_dir : Int
  mut arp_countdown : Int // samples until the next step
  mut arp_gate_left : Int // samples until the current note releases
  mut arp_note : Int // note the arp is currently sounding, -1 none
  mut arp_last_note : Int // last note the arp triggered (observability)
  mut arp_steps : Int // steps taken since the last reset
  mut rng : Int // xorshift state for the random arp mode
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
    reverb_size: 0.5,
    reverb_damp: 0.3,
    reverb_mix: 0.0, // reverb off until a patch asks for it
    reverb_width: 0.8,
    drive: 0.0,
    drive_mix: 0.0,
    arp_on: 0.0,
    arp_rate: 8.0,
    arp_mode: 0.0,
    arp_octaves: 1.0,
    arp_gate: 0.6,
    arp_latch: 0.0,
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
    drive: Drive::new(),
    delay: PingPong::new(sr),
    reverb: Reverb::new(sr),
    voices,
    scratch_l: FixedArray::make(4096, 0.0),
    scratch_r: FixedArray::make(4096, 0.0),
    clock: 0,
    held: FixedArray::make(16, 0),
    held_sorted: FixedArray::make(16, 0),
    held_n: 0,
    arp_pattern: FixedArray::make(64, 0),
    arp_pattern_n: 0,
    arp_index: 0,
    arp_dir: 1,
    arp_countdown: 0,
    arp_gate_left: 0,
    arp_note: -1,
    arp_last_note: -1,
    arp_steps: 0,
    rng: 0x9E3779B9,
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
/// This is the raw voice trigger; the arpeggiator calls it directly.
pub fn Synth::voice_on(self : Synth, note : Int, vel : Int) -> Unit {
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
/// Release every voice currently holding `note` (raw form, used by the
/// arpeggiator).
pub fn Synth::voice_off(self : Synth, note : Int) -> Unit {
  for v in self.voices {
    if v.note == note && v.gate {
      v.gate = false
      v.env.gate_off()
    }
  }
}

// --- arpeggiator ------------------------------------------------------------

///|
fn Synth::arp_enabled(self : Synth) -> Bool {
  self.params.arp_on >= 0.5
}

///|
/// One step of the pattern, starting the next note and releasing the previous
/// one. Allocation-free: the pattern was expanded on the last key event.
fn Synth::arp_trigger(self : Synth) -> Unit {
  if self.arp_note >= 0 {
    self.voice_off(self.arp_note)
    self.arp_note = -1
  }
  if self.arp_pattern_n == 0 {
    return
  }
  let p = self.params
  let (ni, nd) = next_index(
    p.arp_mode.to_int(),
    self.arp_index,
    self.arp_pattern_n,
    self.arp_dir,
    self.next_rand(),
  )
  self.arp_index = ni
  self.arp_dir = nd
  let note = self.arp_pattern[ni]
  self.voice_on(note, 100)
  self.arp_note = note
  self.arp_last_note = note
  self.arp_steps = self.arp_steps + 1
  // the step clock and the gate both start counting from this sample
  self.arp_countdown = self.arp_step_samples()
  self.arp_gate_left = (self.arp_countdown.to_double() * p.arp_gate).to_int()
}

///|
/// Begin a fresh run: `arp_index` sits one before the pattern so the first
/// trigger plays its first note (next_index advances before it sounds).
fn Synth::arp_restart(self : Synth) -> Unit {
  self.arp_rebuild()
  self.arp_index = -1
  self.arp_dir = 1
  self.arp_trigger()
}

///|
/// Samples between steps, from the rate parameter (clamped to 0.5..40 Hz).
fn Synth::arp_step_samples(self : Synth) -> Int {
  let r = dclamp(self.params.arp_rate, 0.5, 40.0)
  let n = (self.sr / r).to_int()
  if n < 1 {
    1
  } else {
    n
  }
}

///|
fn Synth::arp_rebuild(self : Synth) -> Unit {
  let p = self.params
  let mode = p.arp_mode.to_int()
  // as-played keeps key-press order; every other mode walks ascending
  let src = if mode == ARP_AS_PLAYED { self.held } else { self.held_sorted }
  self.arp_pattern_n = build_pattern(src, self.held_n, mode, p.arp_octaves.to_int(), self.arp_pattern)
  // a rebuilt pattern may be shorter than where we were
  if self.arp_index >= self.arp_pattern_n {
    self.arp_index = -1
  }
}

///|
/// Keep the held-key lists sorted. Insertion sort over at most 16 keys, and
/// only ever called from a key event — never from the render path.
fn Synth::held_resort(self : Synth) -> Unit {
  for i = 0; i < self.held_n; i = i + 1 {
    self.held_sorted[i] = self.held[i]
  }
  let mut i = 1
  while i < self.held_n {
    let key = self.held_sorted[i]
    let mut j = i - 1
    while j >= 0 && self.held_sorted[j] > key {
      self.held_sorted[j + 1] = self.held_sorted[j]
      j = j - 1
    }
    self.held_sorted[j + 1] = key
    i = i + 1
  }
}

///|
fn Synth::held_add(self : Synth, note : Int) -> Unit {
  for i = 0; i < self.held_n; i = i + 1 {
    if self.held[i] == note {
      return
    }
  }
  if self.held_n >= 16 {
    return
  }
  self.held[self.held_n] = note
  self.held_n = self.held_n + 1
  self.held_resort()
}

///|
fn Synth::held_remove(self : Synth, note : Int) -> Unit {
  let mut w = 0
  for r = 0; r < self.held_n; r = r + 1 {
    if self.held[r] != note {
      self.held[w] = self.held[r]
      w = w + 1
    }
  }
  self.held_n = w
  self.held_resort()
}

///|
fn Synth::next_rand(self : Synth) -> Int {
  let mut x = self.rng
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.rng = x
  x & 0x7FFFFFFF
}

///|
/// Seed the arpeggiator's PRNG (random mode is deterministic under a seed).
pub fn Synth::seed(self : Synth, s : Int) -> Unit {
  self.rng = if s == 0 { 0x9E3779B9 } else { s }
}

///|
/// Key down. With the arpeggiator off this is a plain voice trigger; with it
/// on the key joins the held set and the first step fires immediately so the
/// note does not wait a full step to sound.
///
/// Keys are tracked either way, so switching the arpeggiator on mid-hold
/// hands the notes over instead of finding an empty pattern.
pub fn Synth::note_on(self : Synth, note : Int, vel : Int) -> Unit {
  if note < 0 || note > 127 {
    return
  }
  let was_empty = self.held_n == 0
  self.held_add(note)
  if !self.arp_enabled() {
    self.arp_rebuild() // keep the pattern ready for a hand-over
    self.voice_on(note, vel)
    return
  }
  if was_empty {
    self.arp_restart()
  } else {
    self.arp_rebuild()
  }
}

///|
/// Key up. With the arpeggiator on, the key leaves the held set (unless
/// latch is on) and an empty set releases the sounding arp note.
pub fn Synth::note_off(self : Synth, note : Int) -> Unit {
  if !self.arp_enabled() {
    self.held_remove(note)
    self.arp_rebuild()
    self.voice_off(note)
    return
  }
  if self.params.arp_latch < 0.5 {
    self.held_remove(note)
    self.arp_rebuild()
  }
  if self.held_n == 0 && self.arp_note >= 0 {
    self.voice_off(self.arp_note)
    self.arp_note = -1
  }
}

///|
/// Last note the arpeggiator triggered (-1 before the first step). Exposed so
/// hosts and tests can observe the sequence.
pub fn Synth::arp_last_note(self : Synth) -> Int {
  self.arp_last_note
}

///|
/// Steps taken since the last reset — the arpeggiator's odometer.
pub fn Synth::arp_steps(self : Synth) -> Int {
  self.arp_steps
}

///|
/// Number of keys currently held (latch included).
pub fn Synth::held_count(self : Synth) -> Int {
  self.held_n
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
  self.reverb.clear()
  self.held_n = 0
  self.arp_pattern_n = 0
  self.arp_note = -1
  self.arp_index = -1
  self.arp_dir = 1
  self.arp_countdown = 0
  self.arp_gate_left = 0
}

///
/// Number of voices with their gate still held — arpeggiator hosts and
/// tests care about this separately from release tails.
pub fn Synth::gated_voices(self : Synth) -> Int {
  let mut n = 0
  for v in self.voices {
    if v.gate {
      n = n + 1
    }
  }
  n
}

///
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
    16 => p.reverb_size = dclamp(value, 0.0, 1.0)
    17 => p.reverb_damp = dclamp(value, 0.0, 1.0)
    18 => p.reverb_mix = dclamp(value, 0.0, 1.0)
    19 => p.reverb_width = dclamp(value, 0.0, 1.0)
    20 => p.drive = dclamp(value, 0.0, 1.0)
    21 => p.drive_mix = dclamp(value, 0.0, 1.0)
    22 => {
      let on = value >= 0.5
      let was = p.arp_on >= 0.5
      p.arp_on = if on { 1.0 } else { 0.0 }
      if on && !was {
        // switching the arp on: hand the held keys over to it and sound the
        // first step straight away
        for v in self.voices {
          if v.gate {
            v.gate = false
            v.env.gate_off()
          }
        }
        self.arp_note = -1
        if self.held_n > 0 {
          self.arp_restart()
        } else {
          self.arp_rebuild()
          self.arp_index = -1
          self.arp_dir = 1
          self.arp_countdown = 0
        }
      } else if !on && was {
        // switching it off: stop stepping and let the held keys sound plainly
        if self.arp_note >= 0 {
          self.voice_off(self.arp_note)
          self.arp_note = -1
        }
        for i = 0; i < self.held_n; i = i + 1 {
          self.voice_on(self.held[i], 100)
        }
      }
    }
    23 => p.arp_rate = dclamp(value, 0.5, 40.0)
    24 => {
      p.arp_mode = dclamp(value, 0.0, (ARP_MODES - 1).to_double())
      self.arp_rebuild()
    }
    25 => {
      p.arp_octaves = dclamp(value, 1.0, 4.0)
      self.arp_rebuild()
    }
    26 => p.arp_gate = dclamp(value, 0.05, 1.0)
    27 => p.arp_latch = if value >= 0.5 { 1.0 } else { 0.0 }
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
  if id == 16 || id == 17 {
    self.reverb.set_room(p.reverb_size, p.reverb_damp)
  }
  if id == 18 {
    self.reverb.mix = p.reverb_mix
  }
  if id == 19 {
    self.reverb.width = p.reverb_width
  }
  if id == 20 || id == 21 {
    self.drive.set(p.drive, p.drive_mix)
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
  let arp = self.arp_enabled()
  for i = 0; i < nn; i = i + 1 {
    // The arpeggiator is scheduled here, inside the sample loop, so steps land
    // on exact sample boundaries rather than on host-timer jitter.
    if arp {
      if self.arp_countdown <= 0 {
        self.arp_trigger()
        self.arp_countdown = self.arp_step_samples()
      }
      self.arp_countdown = self.arp_countdown - 1
      if self.arp_gate_left > 0 {
        self.arp_gate_left = self.arp_gate_left - 1
        if self.arp_gate_left == 0 && self.arp_note >= 0 {
          self.voice_off(self.arp_note)
        }
      }
    }
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
  // global filter -> drive
  for i = 0; i < nn; i = i + 1 {
    let y = self.drive.process(self.filter.process(self.scratch_l[i]))
    self.scratch_l[i] = y
    self.scratch_r[i] = y
  }
  // stereo delay
  for i = 0; i < nn; i = i + 1 {
    let (l, r) = self.delay.process(self.scratch_l[i])
    self.scratch_l[i] = l
    self.scratch_r[i] = r
  }
  // reverb
  for i = 0; i < nn; i = i + 1 {
    let (l, r) = self.reverb.process(self.scratch_l[i], self.scratch_r[i])
    self.scratch_l[i] = l
    self.scratch_r[i] = r
  }
  // master gain, then the output stage: a voiced-up synth plus a reverb
  // tank overshoots ±1 easily, so the master bus is softly limited rather
  // than left to clip in whatever writes the samples out
  let m = p.master
  for i = 0; i < nn; i = i + 1 {
    self.scratch_l[i] = master_limit(self.scratch_l[i] * m)
    self.scratch_r[i] = master_limit(self.scratch_r[i] * m)
  }
  (self.scratch_l, self.scratch_r)
}
