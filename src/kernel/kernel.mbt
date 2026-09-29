// Wasm boundary for the moonsynth engine.
//
// Audio flows out through the module's exported linear memory: the host
// (an AudioWorkletProcessor on the real-time audio thread) calls `render`
// with an agreed address, and the engine writes `2 * nframes` interleaved
// stereo f32 samples there. Control events (note on/off, parameter changes)
// cross as plain exported-function calls — no allocation, no copying, so
// the real-time thread never waits on the GC.

///|
extern "wasm" fn store_f32(addr : Int, v : Float) -> Unit =
  #|(func (param $addr i32) (param $v f32) (f32.store (local.get $addr) (local.get $v)))

///|
let engine : @ref.Ref[@lib.Synth?] = @ref.Ref(None)

///|
/// Create the engine for a given device sample rate.
#export_name("moon_init")
pub fn engine_init(sr : Int) -> Unit {
  engine.val = Some(@lib.Synth::new(sr.to_double()))
}

///|
#export_name("note_on")
pub fn note_on(note : Int, vel : Int) -> Unit {
  match engine.val {
    Some(s) => s.note_on(note, vel)
    None => ()
  }
}

///|
#export_name("note_off")
pub fn note_off(note : Int) -> Unit {
  match engine.val {
    Some(s) => s.note_off(note)
    None => ()
  }
}

///|
/// Set one parameter by id. Ids: 0 osc1_wave, 1 osc1_detune (cents),
/// 2 osc2_wave, 3 osc2_detune, 4 osc2_mix, 5 filter_type, 6 cutoff (Hz),
/// 7 resonance Q, 8 attack (s), 9 decay (s), 10 sustain, 11 release (s),
/// 12 delay_time (s), 13 delay_feedback, 14 delay_mix, 15 master gain,
/// 16 reverb_size, 17 reverb_damp, 18 reverb_mix, 19 reverb_width,
/// 20 drive_amount, 21 drive_mix.
#export_name("set_param")
pub fn set_param(id : Int, value : Float) -> Unit {
  match engine.val {
    Some(s) => ignore(s.set_param(id, value.to_double()))
    None => ()
  }
}

///|
/// Hard-stop all voices and clear filters and delay lines.
#export_name("panic")
pub fn panic_all() -> Unit {
  match engine.val {
    Some(s) => s.panic()
    None => ()
  }
}

///|
/// Number of voices currently sounding (gate held or releasing).
#export_name("voice_count")
pub fn voice_count() -> Int {
  match engine.val {
    Some(s) => s.active_voices()
    None => 0
  }
}

///|
/// Render `nframes` of interleaved stereo audio at `out_addr`.
#export_name("render")
pub fn render(out_addr : Int, nframes : Int) -> Unit {
  match engine.val {
    Some(s) => {
      let (l, r) = s.render(nframes)
      let mut a = out_addr
      for i = 0; i < nframes; i = i + 1 {
        store_f32(a, Float::from_double(l[i]))
        store_f32(a + 4, Float::from_double(r[i]))
        a = a + 8
      }
    }
    None => {
      // engine not initialized yet: emit silence rather than trap
      let mut a = out_addr
      for _i = 0; _i < nframes; _i = _i + 1 {
        store_f32(a, 0.0)
        store_f32(a + 4, 0.0)
        a = a + 8
      }
    }
  }
}
