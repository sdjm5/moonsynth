// Arpeggiator tests: the pattern logic in isolation, then the scheduling
// behavior through the engine. A 1 kHz sample rate keeps the step math
// readable (10 steps/s = 100 samples per step).

///|
fn pattern_of(notes : Array[Int], mode : Int, octaves : Int) -> Array[Int] {
  let held : FixedArray[Int] = FixedArray::make(16, 0)
  for i = 0; i < notes.length(); i = i + 1 {
    held[i] = notes[i]
  }
  let out : FixedArray[Int] = FixedArray::make(64, 0)
  let n = build_pattern(held, notes.length(), mode, octaves, out)
  let result : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    result.push(out[i])
  }
  result
}

///|
test "pattern expands octaves upward for the up mode" {
  let p = pattern_of([60, 64, 67], ARP_UP, 1)
  assert_eq(p.length(), 3)
  assert_eq(p[0], 60)
  assert_eq(p[1], 64)
  assert_eq(p[2], 67)
  let p2 = pattern_of([60, 64, 67], ARP_UP, 2)
  assert_eq(p2.length(), 6)
  assert_eq(p2[3], 72)
  assert_eq(p2[5], 79)
}

///|
test "pattern descends from the top octave for the down mode" {
  let p = pattern_of([60, 64, 67], ARP_DOWN, 2)
  assert_eq(p.length(), 6)
  assert_eq(p[0], 79) // highest note of the top octave first
  assert_eq(p[1], 76)
  assert_eq(p[2], 72)
  assert_eq(p[3], 67)
  assert_eq(p[5], 60)
}

///|
test "octave count is clamped to 1..4" {
  assert_eq(pattern_of([60], ARP_UP, 0).length(), 1)
  assert_eq(pattern_of([60], ARP_UP, 9).length(), 4)
}

///|
test "next_index wraps for up and bounces for up-down" {
  // up: 0,1,2,0,...
  assert_eq(next_index(ARP_UP, 0, 3, 1, 0).0, 1)
  assert_eq(next_index(ARP_UP, 2, 3, 1, 0).0, 0)
  // up-down over three notes: 0 -> 1 -> 2 -> 1 -> 0 -> 1
  let (i1, d1) = next_index(ARP_UPDOWN, 0, 3, 1, 0)
  assert_eq(i1, 1)
  assert_eq(d1, 1)
  let (i2, d2) = next_index(ARP_UPDOWN, 1, 3, 1, 0)
  assert_eq(i2, 2)
  let (i3, d3) = next_index(ARP_UPDOWN, 2, 3, d2, 0)
  assert_eq(i3, 1)
  assert_eq(d3, -1)
  let (i4, d4) = next_index(ARP_UPDOWN, 1, 3, -1, 0)
  assert_eq(i4, 0)
  assert_eq(d4, -1)
  let (i5, d5) = next_index(ARP_UPDOWN, 0, 3, -1, 0)
  assert_eq(i5, 1) // reflected off the bottom
  assert_eq(d5, 1)
}

///|
test "next_index stays in range for every mode and count" {
  for count = 1; count <= 8; count = count + 1 {
    for mode = 0; mode < ARP_MODES; mode = mode + 1 {
      let mut index = 0
      let mut dir = 1
      for step = 0; step < 50; step = step + 1 {
        let (i, d) = next_index(mode, index, count, dir, step * 7919 + 13)
        assert_true(i >= 0 && i < count)
        index = i
        dir = d
      }
    }
  }
}

///|
test "random mode is deterministic for a given step value" {
  let a = next_index(ARP_RANDOM, 0, 5, 1, 42)
  let b = next_index(ARP_RANDOM, 0, 5, 1, 42)
  assert_eq(a.0, b.0)
}

// --- engine integration -----------------------------------------------------

///|
test "arpeggiator off keeps plain polyphonic behavior" {
  let synth = Synth::new(1000.0)
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  synth.note_on(67, 100)
  assert_eq(synth.active_voices(), 3)
  assert_eq(synth.arp_steps(), 0)
}

///|
test "arpeggiator on starts immediately and walks the held notes" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0)) // arp on
  ignore(synth.set_param(23, 10.0)) // 10 steps/s -> 100 samples per step
  ignore(synth.set_param(24, 0.0)) // up
  synth.note_on(60, 100)
  // the first step must fire on the key press, not a step later
  assert_eq(synth.arp_last_note(), 60)
  assert_eq(synth.active_voices(), 1)
  synth.note_on(64, 100)
  synth.note_on(67, 100)
  assert_eq(synth.held_count(), 3)
  let seq : Array[Int] = []
  for k = 0; k < 4; k = k + 1 {
    ignore(synth.render(100))
    seq.push(synth.arp_last_note())
  }
  assert_eq(seq[0], 60)
  assert_eq(seq[1], 64)
  assert_eq(seq[2], 67)
  assert_eq(seq[3], 60) // wrapped
}

///|
test "arpeggiator steps at the requested rate" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  synth.note_on(60, 100)
  ignore(synth.render(1000)) // one second
  // the initial trigger plus one per 100 samples
  assert_eq(synth.arp_steps(), 10)
}

///|
test "octave range repeats the held notes higher" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  ignore(synth.set_param(25, 2.0)) // two octaves
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  let seq : Array[Int] = []
  for k = 0; k < 4; k = k + 1 {
    ignore(synth.render(100))
    seq.push(synth.arp_last_note())
  }
  assert_eq(seq[0], 60)
  assert_eq(seq[1], 64)
  assert_eq(seq[2], 72) // second octave
  assert_eq(seq[3], 76)
}

///|
test "notes sort ascending regardless of press order" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  // press them scrambled: the walk must still be the sorted cycle 60,64,67
  synth.note_on(64, 100)
  synth.note_on(60, 100)
  synth.note_on(67, 100)
  ignore(synth.render(100)) // let the first step boundary pass
  let seq : Array[Int] = []
  for k = 0; k < 3; k = k + 1 {
    ignore(synth.render(100))
    seq.push(synth.arp_last_note())
  }
  assert_eq(seq[0], 64)
  assert_eq(seq[1], 67)
  assert_eq(seq[2], 60) // wrapped back to the lowest
}

///|
test "latch keeps the pattern running after the keys are released" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  ignore(synth.set_param(27, 1.0)) // latch
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  ignore(synth.render(100))
  synth.note_off(60)
  synth.note_off(64)
  assert_eq(synth.held_count(), 2) // still latched
  let before = synth.arp_steps()
  ignore(synth.render(500))
  assert_true(synth.arp_steps() > before)
}

///|
test "releasing every key stops the arpeggiator without latch" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  ignore(synth.render(200))
  synth.note_off(60)
  synth.note_off(64)
  assert_eq(synth.held_count(), 0)
  // the last note is released and nothing new is scheduled
  ignore(synth.render(50))
  ignore(synth.set_param(11, 0.02)) // fast release
  ignore(synth.render(2000))
  let (l, _) = synth.render(200)
  assert_true(rms(l, 0, 200) < 0.001)
}

///|
test "switching the arpeggiator on hands held keys over to it" {
  let synth = Synth::new(1000.0)
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  assert_eq(synth.active_voices(), 2)
  ignore(synth.set_param(22, 1.0))
  // the two held keys become the pattern, one voice at a time (the
  // handed-over voices are still releasing, so count gates not actives)
  assert_eq(synth.arp_last_note(), 60)
  ignore(synth.render(400))
  assert_eq(synth.gated_voices(), 1)
}

///|
test "switching the arpeggiator off returns to plain holding" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 10.0))
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  ignore(synth.render(200))
  ignore(synth.set_param(22, 0.0))
  // both held keys are gated again (release tails from the arp may still ring)
  assert_eq(synth.gated_voices(), 2)
  assert_eq(synth.held_count(), 2)
}

///|
test "velocity and gate: a short gate releases before the next step" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  ignore(synth.set_param(23, 5.0)) // 200 samples per step
  ignore(synth.set_param(26, 0.25)) // gate: 50 samples
  synth.note_on(60, 100)
  // step, then render past the gate but not past the step
  ignore(synth.render(120))
  // the voice is releasing (envelope still active) but the gate closed
  assert_true(synth.arp_steps() == 1)
  ignore(synth.render(120)) // crosses the 200-sample boundary
  assert_eq(synth.arp_steps(), 2)
}

///|
test "hard stop clears held keys and the arpeggiator" {
  let synth = Synth::new(1000.0)
  ignore(synth.set_param(22, 1.0))
  synth.note_on(60, 100)
  synth.note_on(64, 100)
  assert_eq(synth.held_count(), 2)
  synth.panic()
  assert_eq(synth.held_count(), 0)
  assert_eq(synth.active_voices(), 0)
  let before = synth.arp_steps()
  ignore(synth.render(500))
  assert_eq(synth.arp_steps(), before) // nothing left to step
}
