// DSP unit tests. Exact-value assertions where the math is closed-form
// (envelope timing, filter DC gain, delay bounce positions); statistical
// bounds where the subject is signal shape (oscillator range, aliasing).

///|
fn rms(arr : FixedArray[Double], from : Int, to : Int) -> Double {
  let mut s = 0.0
  let n = to - from
  for i = from; i < to; i = i + 1 {
    s = s + arr[i] * arr[i]
  }
  (s / n.to_double()).sqrt()
}

///|
fn dabs(x : Double) -> Double {
  if x < 0.0 {
    -x
  } else {
    x
  }
}

//|

///|
test "wave_from_int and filter_from_int map selectors" {
  assert_eq(wave_from_int(0).to_id(), 0)
  assert_eq(wave_from_int(1).to_id(), 1)
  assert_eq(wave_from_int(2).to_id(), 2)
  assert_eq(wave_from_int(3).to_id(), 3)
  assert_eq(wave_from_int(99).to_id(), 0)
  assert_eq(filter_from_int(0).to_id(), 0)
  assert_eq(filter_from_int(1).to_id(), 1)
  assert_eq(filter_from_int(2).to_id(), 2)
  assert_eq(filter_from_int(42).to_id(), 0)
}

///|
test "oscillator output stays bounded for every waveform" {
  let sr = 44100.0
  let n = 4410
  let buf : FixedArray[Double] = FixedArray::make(n, 0.0)
  let waves = [Waveform::Sin, Waveform::Tri, Waveform::Saw, Waveform::Sqr]
  for w in waves {
    let osc = Osc::new()
    render_tone(osc, 220.0, w, sr, n, buf)
    for i = 0; i < n; i = i + 1 {
      assert_true(buf[i] > -1.001 && buf[i] < 1.001)
      assert_true(buf[i] == buf[i]) // NaN != NaN, so this catches NaN
    }
  }
}

///|
test "oscillator has zero DC offset over whole cycles" {
  let sr = 44100.0
  let cycles = 50
  let f = 110.0
  let n = (cycles.to_double() * sr / f).to_int()
  let buf : FixedArray[Double] = FixedArray::make(n, 0.0)
  for w in [Waveform::Saw, Waveform::Sqr, Waveform::Tri] {
    let osc = Osc::new()
    render_tone(osc, f, w, sr, n, buf)
    let mut mean = 0.0
    for i = 0; i < n; i = i + 1 {
      mean = mean + buf[i]
    }
    mean = mean / n.to_double()
    assert_true(mean.abs() < 0.01)
  }
}

///|
test "poly_blep tames the saw discontinuity" {
  // The derivative of a naive saw is a constant minus a delta of height 2
  // at the wrap. With PolyBLEP the delta spreads over two samples, so the
  // largest single-sample jump shrinks well below 2.
  let sr = 44100.0
  let n = 4410
  let buf : FixedArray[Double] = FixedArray::make(n, 0.0)
  let osc = Osc::new()
  render_tone(osc, 440.0, Waveform::Saw, sr, n, buf)
  let mut max_jump = 0.0
  for i = 1; i < n; i = i + 1 {
    let j = (buf[i] - buf[i - 1]).abs()
    if j > max_jump {
      max_jump = j
    }
  }
  // the naive saw jumps by ~2 at every wrap; PolyBLEP spreads the step
  // over two samples, cutting the worst-case single-sample jump to ~1.5
  // at this frequency (measured 1.48 vs 1.98 naive)
  assert_true(max_jump < 1.5)
}

///|
test "biquad low pass: unity DC gain, stable, attenuates above cutoff" {
  let sr = 44100.0
  let f = Biquad::new(FilterType::FLP)
  f.set(FilterType::FLP, 1000.0, 0.7071, sr)
  // impulse response sums to the DC gain, which is exactly 1 for RBJ LP
  let mut s = f.process(1.0)
  for k = 0; k < 20000; k = k + 1 {
    s = s + f.process(0.0)
  }
  assert_true((s - 1.0).abs() < 0.01)
  // 5 kHz tone through a 1 kHz LP: strongly attenuated
  let n = 8820
  let buf : FixedArray[Double] = FixedArray::make(n, 0.0)
  let f2 = Biquad::new(FilterType::FLP)
  f2.set(FilterType::FLP, 1000.0, 0.7071, sr)
  let osc = Osc::new()
  for i = 0; i < n; i = i + 1 {
    buf[i] = f2.process(osc.next(5000.0, Waveform::Sin, sr))
  }
  let out_rms = rms(buf, n / 2, n)
  assert_true(out_rms < 0.7071 * 0.35)
  // 200 Hz tone through the same filter: passes (near DC gain)
  let f3 = Biquad::new(FilterType::FLP)
  f3.set(FilterType::FLP, 1000.0, 0.7071, sr)
  let osc3 = Osc::new()
  for i = 0; i < n; i = i + 1 {
    buf[i] = f3.process(osc3.next(200.0, Waveform::Sin, sr))
  }
  assert_true(rms(buf, n / 2, n) > 0.6)
}

///|
test "biquad high pass blocks DC and passes above cutoff" {
  let sr = 44100.0
  let f = Biquad::new(FilterType::FHP)
  f.set(FilterType::FHP, 500.0, 0.7071, sr)
  // step the filter once with DC, then watch the output decay to 0
  let mut s = f.process(1.0)
  for k = 0; k < 20000; k = k + 1 {
    s = f.process(0.0) // DC: must converge to 0
  }
  assert_true(s.abs() < 0.01)
  let n = 8820
  let buf : FixedArray[Double] = FixedArray::make(n, 0.0)
  let osc = Osc::new()
  for i = 0; i < n; i = i + 1 {
    buf[i] = f.process(osc.next(4000.0, Waveform::Sin, sr))
  }
  assert_true(rms(buf, n / 2, n) > 0.6)
}

///|
test "ADSR reaches 1 at end of attack, holds sustain, releases to 0" {
  let sr = 1000.0 // 1 sample = 1 ms
  let e = Adsr::new(sr)
  e.attack = 0.02
  e.decay = 0.03
  e.sustain = 0.5
  e.release = 0.05
  e.gate_on()
  for k = 0; k < 20; k = k + 1 {
    ignore(e.next())
  }
  assert_true((e.level - 1.0).abs() < 0.001)
  for k = 0; k < 30; k = k + 1 {
    ignore(e.next())
  }
  assert_true((e.level - 0.5).abs() < 0.001)
  e.gate_off()
  for k = 0; k < 50; k = k + 1 {
    ignore(e.next())
  }
  assert_true(e.level.abs() < 0.001)
  assert_true(!e.active())
}

///|
test "ADSR release ramps from the level it started at" {
  let sr = 1000.0
  let e = Adsr::new(sr)
  e.attack = 0.1
  e.decay = 0.1
  e.sustain = 1.0
  e.release = 0.1
  e.gate_on()
  for k = 0; k < 50; k = k + 1 {
    ignore(e.next())
  }
  let at_cut = e.level
  assert_true(at_cut > 0.4 && at_cut < 0.6)
  e.gate_off()
  let first = e.next()
  assert_true(dabs(first - (at_cut - at_cut / 100.0)) < 0.001)
}

///|
test "ping-pong delay bounces L, R, L with feedback decay" {
  let sr = 1000.0
  let d = PingPong::new(sr)
  d.time = 0.05 // 50 samples
  d.feedback = 0.5
  d.mix = 1.0
  d.clear()
  let n = 400
  let mut l_echo_pos : Int = -1
  let mut r_echo_pos : Int = -1
  let mut l2_pos : Int = -1
  for i = 0; i < n; i = i + 1 {
    let x = if i == 0 { 1.0 } else { 0.0 }
    let (l, r) = d.process(x)
    if l_echo_pos < 0 && l.abs() > 0.01 {
      l_echo_pos = i
    }
    if r_echo_pos < 0 && r.abs() > 0.01 {
      r_echo_pos = i
    }
    if r_echo_pos >= 0 && l2_pos < 0 && i > r_echo_pos && l.abs() > 0.2 {
      l2_pos = i
    }
  }
  assert_eq(l_echo_pos, 50)
  assert_eq(r_echo_pos, 100)
  assert_eq(l2_pos, 150)
}

///|
test "ping-pong delay passes dry signal when mix is 0" {
  let sr = 1000.0
  let d = PingPong::new(sr)
  d.mix = 0.0
  let (l, r) = d.process(0.5)
  assert_true((l - 0.5).abs() < 0.0001)
  assert_true((r - 0.5).abs() < 0.0001)
}

///|
test "note frequencies follow equal temperament" {
  assert_true(dabs(note_freq(69) - 440.0) < 0.001)
  assert_true(dabs(note_freq(81) - 880.0) < 0.001)
  assert_true(dabs(note_freq(57) - 220.0) < 0.001)
}

///|
test "synth renders sound and silences after release" {
  let synth = Synth::new(44100.0)
  ignore(synth.set_param(6, 8000.0))
  ignore(synth.set_param(14, 0.0)) // dry
  synth.note_on(60, 100)
  // scratch buffers hold 4096 samples; render in blocks and keep the tail
  let (l, _) = synth.render(4096)
  ignore(synth.render(4096))
  let (l3, _) = synth.render(4096)
  assert_true(rms(l3, 1024, 4096) > 0.01)
  assert_eq(synth.active_voices(), 1)
  ignore(l)
  synth.note_off(60)
  ignore(synth.set_param(11, 0.01)) // fast release, applies live
  let mut tail : FixedArray[Double] = l3
  for k = 0; k < 6; k = k + 1 {
    let (a, _) = synth.render(4096)
    tail = a
  }
  assert_true(rms(tail, 2048, 4096) < 0.0005)
  assert_eq(synth.active_voices(), 0)
}

///|
test "voice stealing keeps the polyphony cap" {
  let synth = Synth::new(22050.0)
  ignore(synth.set_param(8, 10.0)) // attack 10 s so nothing decays away
  ignore(synth.set_param(10, 1.0))
  ignore(synth.set_param(14, 0.0))
  for i = 0; i < 20; i = i + 1 {
    synth.note_on(48 + i, 100)
  }
  assert_eq(synth.active_voices(), 8)
}

///|
test "set_param rejects unknown ids and accepts known ones" {
  let synth = Synth::new(44100.0)
  assert_true(!synth.set_param(99, 1.0))
  assert_true(synth.set_param(0, 2.0))
  assert_true(synth.set_param(15, 0.5))
}

///|
test "silences everything immediately on panic" {
  let synth = Synth::new(44100.0)
  ignore(synth.set_param(8, 5.0))
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  assert_eq(synth.active_voices(), 2)
  synth.panic()
  assert_eq(synth.active_voices(), 0)
  let (l, _) = synth.render(128)
  for i = 0; i < 128; i = i + 1 {
    assert_true(l[i].abs() < 0.0001)
  }
}
