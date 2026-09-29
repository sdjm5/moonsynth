# moonsynth as a library, offline

`src/lib` is a portable MoonBit synthesis library: oscillators with PolyBLEP
antialiasing, a biquad filter, ADSR envelopes, ping-pong delay, Freeverb
reverb and a soft-clip drive, plus an 8-voice engine that wires them
together. `src/kernel` compiles it to a wasm module. This directory drives
that module from Node — no browser, no audio device, no GUI — and writes
16-bit WAV files you can play in anything.

## Build once

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm
```

## Render a tone

```
node examples/render.mjs sine   A4   2                    # 2 s of 440 Hz
node examples/render.mjs square C3   1.5 --drive 0.6      # driven square
node examples/render.mjs saw    A3   3   --reverb 0.9     # saw with a long tail
node examples/render.mjs tri    E4   2   --detune 12      # two detuned oscillators
node examples/render.mjs sine   432  2                    # a raw frequency, not a note
node examples/render.mjs --chord C4 3 major               # C E G
node examples/render.mjs --scale C4 0.3 minor             # eight notes in a row
```

Notes are scientific pitch (`A4`, `C#3`, `Eb5`) and are converted with equal
temperament; a bare number is treated as Hz and reached exactly, by picking
the nearest note and applying the remaining cents as oscillator detune.
Files land in `out/` unless `--out` says otherwise.

Options: `--drive`, `--reverb`, `--delay`, `--detune`, `--sr`, `--out`, and
`--wave` for the chord/scale modes. Chords: major, minor, maj7, min7, sus4,
power. Scales: major, minor, pentatonic.

## Verify what came out

```
node examples/test-render.mjs
```

This spawns the CLI, parses the WAV files back and measures them with a
single-bin DFT — the assertions are about the spectra of the actual files,
not about the code path that produced them. Current output:

```
16/16 checks passed
```

What it establishes, with the numbers it measured:

| waveform | measured spectrum | theory |
| --- | --- | --- |
| sine | f 0.346, 2f 8e-16, 3f 6e-7 | a sine has no harmonics |
| square | f 0.441, **2f 1e-16**, 3f 0.147, 5f 0.088 | odd harmonics only, 1/n: f/3 = 0.147, f/5 = 0.088 |
| saw | f 0.221, 2f 0.110, 3f 0.073, 5f 0.044 | every harmonic, 1/n: f/2 = 0.110, f/3 = 0.074, f/5 = 0.044 |
| triangle | f 0.281, 2f 0.003, 3f 0.031, 5f 0.011 | odd harmonics, 1/n²: f/9 = 0.031, f/25 = 0.011 |

The even harmonics of the square and triangle measure at machine epsilon
(1e-16), which is what the PolyBLEP correction is supposed to do: it removes
the aliasing of the discontinuities without introducing harmonics the ideal
waveform does not have. Pitch is checked by zero-crossing rate — A4 → 440.0
Hz, A5 → 880.0 Hz, C3 → 131.0 Hz, Eb5 → 622.0 Hz, 432 Hz → 432.00 Hz — and
the effects are checked by what they change: drive lifts the 3rd harmonic of
a pure sine from 6e-7 to 0.127, reverb stretches a 1 s note into a 2.64 s
file.

## Files

```
render.mjs        the CLI: note/frequency parsing, patch setup, block render, WAV out
test-render.mjs   end-to-end: spawn the CLI, decode the WAVs, measure the spectra
wav.mjs           16-bit PCM WAV encode/decode + rms, Goertzel, zero-crossing, tail length
```

## The demo track

```
node examples/demo.mjs                    # → out/demo.wav
node examples/demo.mjs docs/demo-music.wav
```

Builds a 14.5 s piece in four sections — a slow pad over Am–F–C–G, the same
progression arpeggiated up-down across two octaves, a driven square bass, and
a closing chord with the reverb tail left to ring — and prints each section's
measured level as it writes, so the file is checked while it is made rather
than assumed to be fine:

```
  pad (Am F C G)          4.32 s   rms 0.2296   peak 0.928
  arpeggio                      arp took 40 steps
  arpeggio (up-down x2)   4.24 s   rms 0.1785   peak 0.946
  bass (driven)           2.40 s   rms 0.3890   peak 0.785
  outro + reverb tail     3.50 s   rms 0.2178   peak 0.947
```

Those peaks are why the engine has an output stage. The first render of this
track measured a peak of **4.0** — eight voices, two oscillators each, a
reverb tank and a delay sum far past full scale, and the WAV encoder would
have flattened it into crunch. `src/lib/limiter.mbt` now bends the master bus
above 0.9 and approaches ±1 asymptotically; below the knee it is the identity
function, so nothing in the spectra table above changed.

## Arpeggiator flags

The CLI exposes the engine's arpeggiator, so an arpeggio is one command:

```
node examples/render.mjs sine A3 3 --arp --arp-mode updown --arp-oct 2 --arp-rate 10
node examples/render.mjs saw  C4 2 --arp --arp-mode random --arp-oct 3 --arp-gate 0.3
node examples/render.mjs --chord C4 4 minor --arp --arp-rate 6
```

`--arp-mode` takes `up`, `down`, `updown`, `random` or `played`; `--arp-rate`
is steps per second, `--arp-oct` the octave range, `--arp-gate` the note
length as a fraction of a step.

## One measurement trap

A single-bin DFT at the nominal frequency is the wrong tool for a detuned
pair. With `--detune 9` the two oscillators sit at f±9 cents — neither one is
*at* f — so the bin at f catches leakage and the reading depends on the pitch
(same patch, same gain: 0.158 for C3, 0.024 for G4). At `--detune 0` the same
four notes measure 0.2027, 0.2031, 0.2032, 0.2035 — identical, as they should
be. If you are measuring a note this engine played, either disable detune or
sum the energy around the expected partial instead of sampling one bin.
