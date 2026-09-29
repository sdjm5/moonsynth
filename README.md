# moonsynth

A polyphonic browser **synthesizer** whose entire DSP core — oscillators,
filter, envelopes, delay, reverb, drive, arpeggiator — is written in
[MoonBit](https://www.moonbitlang.com/) and compiled to WebAssembly,
rendered sample-by-sample on the real-time audio thread through an
`AudioWorklet`. The same library also runs offline from Node, with no
browser and no audio device.

![demo](docs/demo.png)

```text
signal flow (all inside the wasm module):

  osc1 ─┐
  osc2 ─┴─ voice mix ── ADSR ─┐
                              ├─ sum ── biquad ── drive ── ping-pong delay
  8 voices ──────────────────┘        (LP/HP/BP)              │
                                                              ▼
                       stereo out ── limiter ── master ── reverb
                            ▲
                     arpeggiator schedules the voices (sample-accurate)
```

Turn knobs, play the on-screen keyboard (or your computer keyboard, or a
MIDI keyboard), record a take, and watch the scope.

## Hear it

[`docs/demo-music.wav`](docs/demo-music.wav) is a 14.5 s piece rendered by
`node examples/demo.mjs` — a pad, an arpeggio over the same progression, a
driven bass line and a closing chord left to ring. No samples, no DAW, just
this engine.

## Highlights

- **PolyBLEP oscillators** — naive saw/square transitions are corrected with a
  two-sample polynomial band-limited step. Measured: a square comes out with
  its even harmonics at machine epsilon and its odd harmonics at exactly 1/n
  (f/3 and f/5 to three decimals).
- **RBJ cookbook biquad** — low-pass / high-pass / band-pass with resonance.
- **Linear ADSR** per voice, with release rates captured at gate-off so
  parameter tweaks can't make a releasing voice click.
- **Ping-pong delay** and **Freeverb reverb** (eight damped combs into four
  series allpasses per channel, 23-sample stereo spread). Measured: the
  reverb stretches a 1 s note into a 2.64 s tail.
- **Soft-clip drive** — the cubic clipper `x(27 + x²)/(27 + 9x²)`. Measured:
  it lifts a pure sine's third harmonic from 6e-7 to 0.127.
- **Arpeggiator inside the engine** — five modes (up, down, up-down, random,
  as-played), octave range 1–4, rate 0.5–40 steps/s, gate, latch. Steps are
  scheduled in the sample loop, so they land on exact sample boundaries
  instead of wherever a JavaScript timer fires.
- **Recording** — the worklet taps the engine output into buffers allocated
  once at startup, and hands back a 16-bit PCM WAV you can download.
- **MIDI input** — Web MIDI note on/off plus CC mapping (CC1 cutoff, CC74
  resonance, CC7 master, CC11 reverb wet, CC12 delay wet, CC13 drive).
- **Output stage that does not clip** — a soft-knee limiter, transparent
  below 0.9 and asymptotic to ±1 above it. It exists because the demo track
  measured a peak of 4.0 before it: eight voices, two oscillators each, a
  reverb tank and a delay add up fast.
- **8-voice polyphony** with note retrigger, idle-voice reuse and
  oldest-voice stealing; PANIC silences everything including the reverb tank.
- **Zero-allocation render path** — voices, scratch buffers, delay lines,
  reverb tanks and the arpeggiator pattern are all preallocated.

## Use it as a library, offline

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm

node examples/render.mjs sine A4 2                 # 2 s of 440 Hz
node examples/render.mjs square C3 1.5 --drive 0.6
node examples/render.mjs saw A3 3 --reverb 0.9
node examples/render.mjs sine A3 3 --arp --arp-mode updown --arp-oct 2
node examples/render.mjs sine 432 2                # a raw frequency, hit exactly
node examples/render.mjs --chord C4 3 major        # C E G
node examples/render.mjs --scale C4 0.3 minor      # eight notes in a row
node examples/demo.mjs                             # the demo track above

node examples/test-render.mjs                      # 21/21 checks
```

Note names (`A4`, `C#3`, `Eb5`) are converted through equal temperament; a
bare number is treated as Hz and reached exactly by picking the nearest note
and applying the remainder as cents detune. See
[examples/README.md](examples/README.md) for the measured spectra table and
for one measurement trap worth knowing about.

## The wasm ↔ AudioWorklet boundary

One lesson cost the project its first silent render: the AudioWorklet global
scope of some embedded Chromium builds **has no `fetch` and no `URL`**, so the
worklet cannot load the module itself. moonsynth instead compiles the bytes on
the main thread and ships them over the `MessagePort`; the worklet
instantiates with bare `WebAssembly`.

After that, audio crosses one shared region of the exported linear memory:
each `process()` call asks the engine to render a block of interleaved stereo
f32 samples at an agreed address, and the host copies it to the output
channels. Control events (note on/off, parameters) are plain exported-function
calls on the audio thread — no allocation, no copying, no locks.

Two more findings encoded in the code:

- `OfflineAudioContext` does **not pump the worklet's message queue
  mid-render** — control events must be delivered before `startRendering()`,
  or they never take effect.
- `init` is a reserved special function name in MoonBit; exported constructors
  need another name (`moon_init`).

## Layout

```
src/lib/        portable pure-MoonBit DSP: PolyBLEP oscillators, RBJ biquad,
                ADSR, ping-pong delay, Freeverb reverb, soft-clip drive,
                soft-knee limiter, arpeggiator, 8-voice engine (45 unit tests)
src/kernel/     wasm foreign_library: moon_init / note_on / note_off /
                set_param / panic / render / arp_steps / gated_count / ...
web/            rack UI (21 knobs, 6 presets, arpeggiator panel, recording,
                MIDI, keyboard, scope+spectrum), audio-worklet.js,
                zero-dependency server
examples/       shared engine driver, single-tone CLI, demo track builder,
                WAV helpers and the spectral verification suite
```

## Try it

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm
node web/server.mjs 8090
# open http://127.0.0.1:8090
```

Then: **▶ 启动音频** (browsers require one user gesture), pick a preset, and
play with `A W S E D F T G Y H U J K…` (`Z`/`X` shift octaves). Presets: Init
Saw, Fat Bass, Dreamy Pad, Pluck, Acid 303 (driven, arpeggiated), Arp Pluck.
Press **⏺ 录音** to capture a take as WAV, and **🎹 连接 MIDI** for a hardware
keyboard.

## Performance

Rendering 10 seconds of stereo audio with all 8 voices sounding takes
~148 ms in Node (release build) — about **68× real time**. The per-block
render allocates nothing.

## Tests

- **DSP library**: `moon test` — **45 tests**. Closed-form checks where the
  math is exact (envelope timing, filter impulse response summing to 1, delay
  echoes landing on samples 50/100/150, reverb decay and stability at maximum
  room size, the shaper's transfer curve, limiter transparency and bounding,
  arpeggiator pattern order/octaves/bounce/range) plus engine-level behavior.
- **Offline renderer**: `node examples/test-render.mjs` — **21 checks** that
  spawn the CLIs, decode the WAVs and measure them: waveform spectra against
  theory, equal-tempered pitch, drive and reverb effects, and the demo track
  (duration, no clipping, every section audible, the arpeggio reaching an
  octave the pad cannot).
- **In-browser self-test** — offline render through the full worklet stack.
- **Kernel**: `node web/test-kernel.mjs` — **10 checks** over the wasm
  boundary, including a real-time factor budget.

## Requirements

- MoonBit CLI (developed on 0.1.20260920) — `moon build --target wasm --release`
- Node.js 18+ for the dev server, the offline examples and the kernel tests
- Any modern browser with WebAudio + AudioWorklet for the rack

## License

[Apache-2.0](LICENSE)
