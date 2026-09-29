// Tests for the reverb and drive blocks, plus their place in the chain.
// The reverb is judged on measurable behavior (decay, decorrelation,
// passthrough) rather than taste; the shaper on its transfer curve.

///|
test "drive bypasses exactly at amount 0 or mix 0" {
  let d = Drive::new()
  assert_true(d.process(0.37) == 0.37)
  d.set(0.9, 0.0)
  assert_true(d.process(-0.42) == -0.42)
}

///|
test "soft clip is odd, monotonic and saturates at one" {
  // odd symmetry
  assert_true((soft_clip(1.3) + soft_clip(-1.3)).abs() < 0.0000001)
  // derivative at the origin is 1 (small signals pass through untouched)
  assert_true((soft_clip(0.001) - 0.001).abs() < 0.000001)
  // saturation
  assert_true(soft_clip(3.0) > 0.999)
  assert_true(soft_clip(100.0) <= 1.0)
  assert_true(soft_clip(100.0) >= 0.999)
  // monotonic across the useful range
  let mut prev = soft_clip(-4.0)
  let mut x = -4.0
  while x < 4.0 {
    x = x + 0.01
    let y = soft_clip(x)
    assert_true(y >= prev)
    prev = y
  }
}

///|
test "drive adds harmonics without running away" {
  let d = Drive::new()
  d.set(0.8, 1.0)
  // a loud sine through the shaper must stay bounded
  let sr = 44100.0
  let osc = Osc::new()
  let n = 4410
  let mut peak = 0.0
  for i = 0; i < n; i = i + 1 {
    let y = d.process(osc.next(220.0, Waveform::Sin, sr))
    if y.abs() > peak {
      peak = y.abs()
    }
  }
  assert_true(peak <= 1.0)
  assert_true(peak > 0.5)
  // and a quiet input gets louder (makeup more than compensates at mid level)
  let q = d.process(0.05)
  assert_true(q > 0.05)
}

///|
test "reverb is a passthrough at zero mix" {
  let rv = Reverb::new(44100.0)
  rv.mix = 0.0
  let (l, r) = rv.process(0.5, -0.25)
  assert_true(l == 0.5 && r == -0.25)
}

///|
test "reverb tail decays but outlives the input" {
  let sr = 44100.0
  let rv = Reverb::new(sr)
  rv.mix = 1.0
  rv.set_room(0.85, 0.2)
  // early tail right after a short burst
  let early = rv.tail_energy(sr, 64, 0.05)
  let late = rv.tail_energy(sr, 64, 0.7)
  assert_true(early > 0.000001) // something is ringing
  assert_true(late < early) // and it is decaying
  assert_true(late > 0.0) // but has not collapsed instantly
}

///|
test "reverb is stable at maximum room size" {
  let sr = 44100.0
  let rv = Reverb::new(sr)
  rv.mix = 1.0
  rv.set_room(1.0, 0.0) // feedback 0.98, no damping — the worst case
  for i = 0; i < 4000; i = i + 1 {
    ignore(rv.process(1.0, 1.0))
  }
  let mut peak = 0.0
  for i = 0; i < 200000; i = i + 1 {
    let (l, r) = rv.process(0.0, 0.0)
    if l.abs() > peak {
      peak = l.abs()
    }
    if r.abs() > peak {
      peak = r.abs()
    }
    assert_true(l == l && r == r) // never NaN
  }
  assert_true(peak < 100.0) // no runaway
}

///|
test "reverb stereo channels are decorrelated by the spread" {
  let sr = 44100.0
  let rv = Reverb::new(sr)
  rv.mix = 1.0
  rv.width = 1.0
  rv.set_room(0.7, 0.3)
  rv.clear()
  // feed a single impulse on both channels, then compare the tails
  ignore(rv.process(1.0, 1.0))
  let mut diff = 0.0
  let mut energy = 0.0
  for i = 0; i < 20000; i = i + 1 {
    let (l, r) = rv.process(0.0, 0.0)
    diff = diff + (l - r).abs()
    energy = energy + (l.abs() + r.abs())
  }
  assert_true(energy > 0.0)
  // identical channels would give diff == 0
  assert_true(diff > 0.01)
}

///|
test "reverb clear silences the tail" {
  let sr = 44100.0
  let rv = Reverb::new(sr)
  rv.mix = 1.0
  rv.set_room(0.9, 0.1)
  rv.clear()
  for i = 0; i < 1000; i = i + 1 {
    ignore(rv.process(1.0, 1.0))
  }
  rv.clear()
  for i = 0; i < 100; i = i + 1 {
    let (l, r) = rv.process(0.0, 0.0)
    assert_true(l.abs() < 0.0000001 && r.abs() < 0.0000001)
  }
}

///|
test "chain: reverb and drive are wired and controlled by their params" {
  let synth = Synth::new(44100.0)
  // new ids are recognized, unknown ones are not
  assert_true(synth.set_param(16, 0.7))
  assert_true(synth.set_param(21, 0.5))
  assert_true(!(synth.set_param(99, 1.0)))
  // dry engine: delay and reverb off, so silence after the note dies
  ignore(synth.set_param(6, 8000.0))
  ignore(synth.set_param(14, 0.0))
  synth.note_on(60, 100)
  ignore(synth.render(4096))
  synth.note_off(60)
  ignore(synth.set_param(11, 0.01))
  for k = 0; k < 8; k = k + 1 {
    ignore(synth.render(4096))
  }
  let (dry, _) = synth.render(4096)
  assert_true(rms(dry, 2048, 4096) < 0.0005)
  // with reverb wet, the tail is still audible long after the note ended
  ignore(synth.set_param(18, 0.9))
  ignore(synth.set_param(16, 0.9))
  synth.note_on(60, 100)
  ignore(synth.render(4096))
  synth.note_off(60)
  ignore(synth.set_param(11, 0.01))
  for k = 0; k < 8; k = k + 1 {
    ignore(synth.render(4096))
  }
  let (wet, _) = synth.render(4096)
  assert_true(rms(wet, 2048, 4096) > 0.0005)
}

///|
test "hard stop clears the reverb tank too" {
  let synth = Synth::new(44100.0)
  ignore(synth.set_param(18, 1.0))
  ignore(synth.set_param(16, 0.9))
  ignore(synth.set_param(14, 0.5))
  synth.note_on(60, 100)
  ignore(synth.render(4096))
  synth.panic()
  let (l, r) = synth.render(512)
  for i = 0; i < 512; i = i + 1 {
    assert_true(l[i].abs() < 0.0000001)
    assert_true(r[i].abs() < 0.0000001)
  }
}
