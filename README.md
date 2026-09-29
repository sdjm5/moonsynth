# moonsynth

A polyphonic browser **synthesizer** whose entire DSP core — oscillators,
filter, envelopes, delay, reverb, drive — is written in
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
                                  stereo out ── master ── reverb
```

Turn knobs, play the on-screen keyboard (or your computer keyboard), pick a
preset, and watch the scope. The page's **offline self-test** button renders
audio through the same engine headlessly and asserts the physics.

## Highlights

- **PolyBLEP oscillators** — naive saw/square transitions are corrected with a
  two-sample polynomial band-limited step. Measured: a square comes out with
  its even harmonics at machine epsilon and its odd harmonics at exactly 1/n
  (f/3 and f/5 to three decimals).
- **RBJ cookbook biquad** — low-pass / high-pass / band-pass with resonance,
  coefficients recomputed only on parameter changes.
- **Linear ADSR** per voice, with release rates captured at gate-off so
  parameter tweaks can't make a releasing voice click.
- **Ping-pong delay** — one impulse echoes left, right, left… with feedback.
- **Freeverb reverb** — eight damped comb filters into four series allpasses
  per channel, right-channel lines offset by 23 samples for a decorrelated
  stereo image; room size, damping, wet and width are live controls. Measured:
  it stretches a 1 s note into a 2.64 s tail.
- **Soft-clip drive** — the cubic clipper `x(27 + x²)/(27 + 9x²)`, with
  makeup that keeps a full-scale input near unity so drive adds harmonics
  instead of just losing loudness. Measured: it lifts a pure sine's third
  harmonic from 6e-7 to 0.127.
- **8-voice polyphony** with note retrigger, idle-voice reuse and
  oldest-voice stealing; PANIC hard-silences everything including the reverb
  tank.
- **Zero-allocation render path** — voices, scratch buffers, delay lines and
  reverb tanks are preallocated; the per-block render never allocates, so the
  wasm GC never interrupts the audio thread mid-block.

## Use it as a library, offline

`examples/` drives the wasm module from Node and writes playable WAV files —
no browser, no audio device:

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm

node examples/render.mjs sine A4 2                 # 2 s of 440 Hz
node examples/render.mjs square C3 1.5 --drive 0.6
node examples/render.mjs saw A3 3 --reverb 0.9
node examples/render.mjs sine 432 2                # a raw frequency, hit exactly
node examples/render.mjs --chord C4 3 major        # C E G
node examples/render.mjs --scale C4 0.3 minor      # eight notes in a row

node examples/test-render.mjs                      # 16/16 checks
```

Note names (`A4`, `C#3`, `Eb5`) are converted through equal temperament; a
bare number is treated as Hz and reached exactly by picking the nearest note
and applying the remainder as cents detune. See
[examples/README.md](examples/README.md) for the measured spectra table.

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
                8-voice engine (25 unit tests)
src/kernel/     wasm foreign_library: moon_init / note_on / note_off /
                set_param / panic / voice_count / render (linear-memory out)
web/            rack UI (18 knobs, 5 presets, keyboard, scope+spectrum,
                offline self-test), audio-worklet.js, zero-dependency server
examples/       Node CLI that renders WAV files + spectral verification
```

## Try it

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm
node web/server.mjs 8090
# open http://127.0.0.1:8090
```

Then: **▶ 启动音频** (browsers require one user gesture), pick a preset, and
play with `A W S E D F T G Y H U J K…` (`Z`/`X` shift octaves). Drag knobs
vertically; double-click a knob to reset it. Presets: Init Saw, Fat Bass,
Dreamy Pad (big reverb), Pluck, Acid 303 (driven).

## Performance

Rendering 10 seconds of stereo audio with all 8 voices sounding takes
~148 ms in Node (release build) — about **68× real time**. The per-block
render allocates nothing.

## Tests

- **DSP library**: `moon test` — **25 tests**. Closed-form checks where the
  math is exact (envelope timing, filter impulse response summing to 1, delay
  echoes landing on samples 50/100/150, reverb tail decay and stability at
  maximum room size, the shaper's odd/monotonic/saturating transfer curve) and
  statistical bounds where the subject is signal shape.
- **Offline renderer**: `node examples/test-render.mjs` — **16 checks** that
  spawn the CLI, decode the WAVs and measure their spectra against theory.
- **In-browser self-test** — offline render through the full worklet stack:
  attack RMS > 0.02, post-release RMS < 0.001, zero-crossing rate within
  230–290/s for a C4 sine.
- **Kernel**: `node web/test-kernel.mjs` — **10 checks** over the wasm
  boundary, including a real-time factor budget.

## Requirements

- MoonBit CLI (developed on 0.1.20260920) — `moon build --target wasm --release`
- Node.js 18+ for the dev server, the offline examples and the kernel tests
- Any modern browser with WebAudio + AudioWorklet for the rack

## License

[Apache-2.0](LICENSE)
